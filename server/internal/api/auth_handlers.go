package api

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/nc1107/check-in/server/internal/auth"
	"github.com/nc1107/check-in/server/internal/db"
)

// dummyPasswordHash is a valid argon2id hash (same params as real passwords) that
// handleLogin verifies against when a phone is unknown, so a missing account and a wrong
// password take the same time and a number's membership can't be probed by timing.
var dummyPasswordHash, _ = auth.HashPassword("timing-equalizer-not-a-real-password")

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	// Verify the DB is actually reachable so the container healthcheck (and watchtower's
	// rollback) treats a DB-disconnected server as unhealthy rather than "ok".
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.db.Pool.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleServerInfo lets the app discover the server name and whether an admin exists
// yet (so it can show first-admin setup vs. normal signup/login).
func (s *Server) handleServerInfo(w http.ResponseWriter, r *http.Request) {
	initialized, err := s.db.ServerInitialized(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	resp := map[string]any{
		"name":        s.serverName(r.Context()),
		"color":       s.serverColor(r.Context()),
		"initialized": initialized,
		"publicUrl":   s.cfg.PublicURL,
		// What this server will accept an upload of. A client uses it to hide the video
		// option against a self-hosted server that has not been updated yet; older clients
		// ignore the key.
		"mediaTypes": []string{"image", "gif", "video"},
		// Whether the Klipy gif-search proxy is usable, i.e. a key is configured. A client
		// hides the gif picker entry point rather than opening a picker that 503s on every
		// search.
		"gifSearch": s.cfg.KlipyKey != "",
		// Always true from this server version on. The field's absence, not its value, is
		// what an older server speaks: it predates comment media and 400s a comment create
		// carrying mediaId (DisallowUnknownFields), so the client gates sending mediaId on
		// this key being present at all, not on it being true.
		"commentMedia": true,
		// crossComments is the capability signal for addComment's own crossCommentId. A
		// server predating it rejects unknown JSON fields (DisallowUnknownFields), so a
		// client must only send that field once it has seen this key - otherwise commenting
		// on a cross-posted check-in would 400 against any group not yet updated.
		"crossComments": true,
		// recap is this server's capability signal for the whole recap feature: lat/lng in
		// createPost, and the recapCadence/recapWeekday/recapHour/recapOffset fields below
		// and on PATCH /api/admin/server. This server rejects unknown JSON fields
		// (DisallowUnknownFields), so a client must only send any of them once it has seen
		// this flag - otherwise a new client would 400 every post against an old server.
		"recap": true,
		// titles is this server's capability signal for the on-demand recap endpoint's
		// bestowTitles field: a server predating it rejects unknown JSON fields
		// (DisallowUnknownFields), so a client must only ever send bestowTitles once this is
		// true - and even then, only when true (never as an explicit false) so the same
		// omit-unless-true rule that guards every other capability-gated field here holds.
		"titles": true,
		// memories is the capability signal for GET /api/memories/random. A server predating
		// it doesn't have the route at all (a client that asked would just 404), so the app
		// gates showing the Memories entry point on this being true rather than probing the
		// endpoint and hiding it after a failed request.
		"memories": true,
		// events is the capability signal for GET /api/memories/events, the "You were
		// there" group-event hub entry. Same story as memories: a server predating it has
		// no such route at all, so the client gates showing that entry on this being true
		// rather than probing the endpoint and hiding it after a 404.
		"events": true,
		// timeline is the capability signal for GET /api/memories/timeline and
		// /api/memories/timeline/{year}/{month}, the "Your months" hub entry. Same story
		// as memories and events: a server predating it has no such routes at all, so the
		// client gates showing that entry on this being true rather than probing and
		// hiding it after a 404.
		"timeline": true,
		// forgotten is the capability signal for GET /api/memories/forgotten, the "Forgotten
		// photos" hub entry. Same story as memories/events/timeline: a server predating it
		// has no such route at all, so the client hides that hub entry rather than opening a
		// view that can never load anything. Independent of the other three.
		"forgotten": true,
		// places is the capability signal for GET /api/memories/places, the "Places" hub
		// entry. Same story as memories/events/timeline/forgotten: a server predating it
		// has no such route at all, so the client hides that hub entry rather than opening
		// a list that can never load anything. Independent of the other four.
		"places": true,
	}
	if settings, err := s.db.GetRecapSettings(r.Context()); err == nil {
		resp["recapCadence"] = settings.Cadence
		resp["recapWeekday"] = settings.Weekday
		resp["recapHour"] = settings.Hour
		resp["recapOffset"] = settings.Offset
	}
	writeJSON(w, http.StatusOK, resp)
}

// serverName is the group's current display name: the admin-set value in the database,
// falling back to the configured env name if the row can't be read.
func (s *Server) serverName(ctx context.Context) string {
	name, err := s.db.GetServerName(ctx)
	if err != nil || name == "" {
		return s.cfg.ServerName
	}
	return name
}

// serverColor is the group's admin-set palette color id, or "" when none is set.
func (s *Server) serverColor(ctx context.Context) string {
	color, err := s.db.GetServerColor(ctx)
	if err != nil {
		return ""
	}
	return color
}

// validServerName trims and bounds a proposed group name (1–40 runes), returning the
// cleaned value and whether it's acceptable.
func validServerName(raw string) (string, bool) {
	name := strings.TrimSpace(raw)
	if name == "" || utf8.RuneCountInString(name) > 40 {
		return "", false
	}
	return name, true
}

// groupColorHex is the fixed palette of admin-selectable group colors, keyed by the id the
// API speaks. The client renders the same ids and the same values
// (app/lib/theme/group_color.dart); the two must stay in sync. The hex is only needed by
// the /join page, which has no client to ask.
var groupColorHex = map[string]string{
	"coral": "#FF7A66", "gold": "#E5B93C", "lime": "#93D845", "cyan": "#34C6D8",
	"indigo": "#7C83FF", "magenta": "#E668C8", "orange": "#F58A3C", "steel": "#8FA0B5",
}

// validGroupColor accepts an empty string (clear, back to the automatic color) or a known
// palette id, returning the cleaned value and whether it's acceptable.
func validGroupColor(raw string) (string, bool) {
	c := strings.TrimSpace(raw)
	if c == "" {
		return "", true
	}
	if _, ok := groupColorHex[c]; ok {
		return c, true
	}
	return "", false
}

// validRecapCadence accepts the three standing-cadence values the scheduler understands.
func validRecapCadence(raw string) bool {
	switch raw {
	case "off", "weekly", "monthly":
		return true
	default:
		return false
	}
}

// recapPatch is the recap half of an update-server request: every field optional, each
// validated against the same bounds the scheduler assumes.
type recapPatch struct {
	cadence *string
	weekday *int
	hour    *int
	offset  *int
}

// present reports whether the request touched the recap settings at all, which is what
// decides between leaving them alone and reading-modifying-writing them.
func (p recapPatch) present() bool {
	return p.cadence != nil || p.weekday != nil || p.hour != nil || p.offset != nil
}

// applyTo returns settings with whichever fields were sent applied, or the message for the
// first one that failed validation. Pure, so the bounds are testable without a database.
func (p recapPatch) applyTo(settings db.RecapSettings) (db.RecapSettings, string) {
	if p.cadence != nil {
		if !validRecapCadence(*p.cadence) {
			return settings, "recapCadence must be 'off', 'weekly' or 'monthly'"
		}
		settings.Cadence = *p.cadence
	}
	if p.weekday != nil {
		if *p.weekday < 1 || *p.weekday > 7 {
			return settings, "recapWeekday must be 1-7 (ISO, 1=Monday)"
		}
		settings.Weekday = *p.weekday
	}
	if p.hour != nil {
		if *p.hour < 0 || *p.hour > 23 {
			return settings, "recapHour must be 0-23"
		}
		settings.Hour = *p.hour
	}
	if p.offset != nil {
		// Real UTC offsets span -12:00 to +14:00, same bound as NotifyPrefs.Normalize.
		if *p.offset < -12*60 || *p.offset > 14*60 {
			return settings, "recapOffset must be a plausible UTC offset in minutes"
		}
		settings.Offset = *p.offset
	}
	return settings, ""
}

// handleUpdateServer lets an admin change the group's shared settings - name, color, and
// the standing recap cadence - for everyone at once. Every field is optional; whichever is
// present is validated and applied. Responds with the current values of all of them.
func (s *Server) handleUpdateServer(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name  *string `json:"name"`
		Color *string `json:"color"`
		// Recap settings mirror the digest hour/offset shape (0013): a cadence, a
		// group-local hour (and, for weekly, an ISO weekday), and the UTC offset the app
		// refreshes on launch so a DST shift self-corrects.
		RecapCadence *string `json:"recapCadence"`
		RecapWeekday *int    `json:"recapWeekday"`
		RecapHour    *int    `json:"recapHour"`
		RecapOffset  *int    `json:"recapOffset"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	if req.Name == nil && req.Color == nil && req.RecapCadence == nil &&
		req.RecapWeekday == nil && req.RecapHour == nil && req.RecapOffset == nil {
		writeErr(w, http.StatusBadRequest, "nothing to update")
		return
	}
	if req.Name != nil {
		name, ok := validServerName(*req.Name)
		if !ok {
			writeErr(w, http.StatusBadRequest, "name must be 1-40 characters")
			return
		}
		if err := s.db.SetServerName(r.Context(), name); err != nil {
			writeErr(w, http.StatusInternalServerError, msgServerError)
			return
		}
	}
	if req.Color != nil {
		color, ok := validGroupColor(*req.Color)
		if !ok {
			writeErr(w, http.StatusBadRequest, "invalid color")
			return
		}
		if err := s.db.SetServerColor(r.Context(), color); err != nil {
			writeErr(w, http.StatusInternalServerError, msgServerError)
			return
		}
	}
	if patch := (recapPatch{req.RecapCadence, req.RecapWeekday, req.RecapHour, req.RecapOffset}); patch.present() {
		settings, err := s.db.GetRecapSettings(r.Context())
		if err != nil {
			writeErr(w, http.StatusInternalServerError, msgServerError)
			return
		}
		settings, msg := patch.applyTo(settings)
		if msg != "" {
			writeErr(w, http.StatusBadRequest, msg)
			return
		}
		if err := s.db.SetRecapSettings(r.Context(), settings.Cadence, settings.Weekday, settings.Hour, settings.Offset); err != nil {
			writeErr(w, http.StatusInternalServerError, msgServerError)
			return
		}
	}

	resp := map[string]any{
		"name":  s.serverName(r.Context()),
		"color": s.serverColor(r.Context()),
	}
	if settings, err := s.db.GetRecapSettings(r.Context()); err == nil {
		resp["recapCadence"] = settings.Cadence
		resp["recapWeekday"] = settings.Weekday
		resp["recapHour"] = settings.Hour
		resp["recapOffset"] = settings.Offset
	}
	writeJSON(w, http.StatusOK, resp)
}

type checkPhoneReq struct {
	Phone string `json:"phone"`
}

// inviteState is what an invited phone may do next: nothing, sign up, or log in.
type inviteState int

const (
	inviteNone    inviteState = iota // not on the allowlist - may not sign up
	inviteOpen                       // invited and unclaimed - may sign up
	inviteClaimed                    // an account already holds this number - log in instead
)

// inviteStateFor derives what a phone may do from its allowlist row and whether an account
// holds the number. The users table - not allowed_phones.used - decides whether an invite is
// claimed: deleting an account deletes its invite row (see DeleteAccount), so a used invite
// with no account behind it is stale, left over from a user row removed out of band. Reading
// the flag as gospel would dead-end an invited number forever behind an "already registered"
// error that is false and that no admin screen can clear (the invite list only offers Remove
// on pending rows).
func inviteStateFor(allowed, registered bool) inviteState {
	switch {
	case !allowed:
		return inviteNone
	case registered:
		return inviteClaimed
	default:
		return inviteOpen
	}
}

// invite looks up the [inviteState] for an already-normalized phone.
func (s *Server) invite(ctx context.Context, phone string) (inviteState, error) {
	allowed, _, err := s.db.PhoneAllowed(ctx, phone)
	if err != nil {
		return inviteNone, err
	}
	registered, err := s.db.PhoneRegistered(ctx, phone)
	if err != nil {
		return inviteNone, err
	}
	return inviteStateFor(allowed, registered), nil
}

// handleCheckPhone reports whether a phone may sign up. The first user (before any
// admin exists) may always sign up and becomes the admin; everyone else must be on the
// allowlist with an unclaimed invite.
func (s *Server) handleCheckPhone(w http.ResponseWriter, r *http.Request) {
	var req checkPhoneReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	if phone == "" {
		writeErr(w, http.StatusBadRequest, "phone required")
		return
	}
	initialized, err := s.db.ServerInitialized(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if !initialized {
		writeJSON(w, http.StatusOK, map[string]any{
			"allowed": true, "registered": false, "isFirstAdmin": true,
		})
		return
	}
	// An existing account → the caller should log in, not sign up. This includes the
	// host, whose number is never on the allowlist.
	registered, err := s.db.PhoneRegistered(r.Context(), phone)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	allowed, _, err := s.db.PhoneAllowed(r.Context(), phone)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"allowed":      inviteStateFor(allowed, registered) == inviteOpen, // may sign up
		"registered":   registered,                                        // already has an account (log in)
		"isFirstAdmin": false,
	})
}

type signupReq struct {
	Phone string `json:"phone"`
	// Name is a legacy single-field display name kept for older clients. Newer clients
	// send FirstName/LastName and an optional DisplayName instead.
	Name        string `json:"name"`
	FirstName   string `json:"firstName"`
	LastName    string `json:"lastName"`
	DisplayName string `json:"displayName"` // optional override; defaults to the full name
	Birthday    string `json:"birthday"`    // YYYY-MM-DD
	Password    string `json:"password"`
	MediaID     *int64 `json:"mediaId,omitempty"` // rejected if set; kept so old payloads still parse
}

// displayName derives the public-facing name from a signup request: an explicit display
// name wins, then the full "first last", then a legacy single name field.
func (r signupReq) displayName() string {
	if d := strings.TrimSpace(r.DisplayName); d != "" {
		return d
	}
	if full := strings.TrimSpace(strings.TrimSpace(r.FirstName) + " " + strings.TrimSpace(r.LastName)); full != "" {
		return full
	}
	return strings.TrimSpace(r.Name)
}

// handleSignup registers a new user. The first signup on a fresh server becomes the
// admin (bypassing the allowlist, which is empty); subsequent signups require the
// normalized phone to be on the allowlist and unused.
func (s *Server) handleSignup(w http.ResponseWriter, r *http.Request) {
	var req signupReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	name := req.displayName()
	password := auth.NormalizePassword(req.Password)
	if phone == "" || name == "" || len(password) < 8 {
		writeErr(w, http.StatusBadRequest, "phone, name and an 8+ char password are required")
		return
	}
	if len(name) > 100 {
		writeErr(w, http.StatusBadRequest, "name too long (max 100 characters)")
		return
	}
	birthday, err := time.Parse("2006-01-02", req.Birthday)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "birthday must be YYYY-MM-DD")
		return
	}
	if birthday.Year() < 1900 || birthday.After(time.Now()) {
		writeErr(w, http.StatusBadRequest, "birthday is not a valid date")
		return
	}

	initialized, err := s.db.ServerInitialized(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}

	isAdmin := false
	if !initialized {
		// First ever user → admin.
		isAdmin = true
	} else {
		state, err := s.invite(r.Context(), phone)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, msgServerError)
			return
		}
		switch state {
		case inviteNone:
			writeErr(w, http.StatusForbidden, "this phone number is not on the invite list")
			return
		case inviteClaimed:
			writeErr(w, http.StatusConflict, "this phone number has already been registered")
			return
		case inviteOpen:
		}
	}

	// A signup can never legitimately reference media: uploading requires a session, and
	// the account does not exist yet, so any id arriving here is by definition somebody
	// else's file - accepting it would let a brand-new member claim another member's
	// upload as their avatar, which the profile-photo visibility rule then shows to the
	// whole group. The apps have never sent this field; the photo is uploaded right after
	// signup with the fresh token instead.
	if req.MediaID != nil {
		writeErr(w, http.StatusBadRequest, "attach the profile photo after signing up")
		return
	}

	hash, err := auth.HashPassword(password)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}

	user, err := s.db.CreateUser(r.Context(), db.NewUser{
		Phone:        phone,
		Name:         name,
		FirstName:    strings.TrimSpace(req.FirstName),
		LastName:     strings.TrimSpace(req.LastName),
		Birthday:     birthday,
		PasswordHash: hash,
		IsAdmin:      isAdmin,
	})
	if err != nil {
		writeErr(w, http.StatusConflict, "could not create account (phone may already exist)")
		return
	}

	if isAdmin {
		if err := s.db.MarkInitialized(r.Context()); err != nil {
			writeErr(w, http.StatusInternalServerError, msgServerError)
			return
		}
	} else {
		_ = s.db.MarkPhoneUsed(r.Context(), phone)
	}

	s.issueSession(w, r, user)
}

type loginReq struct {
	Phone    string `json:"phone"`
	Password string `json:"password"`
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	password := auth.NormalizePassword(req.Password)
	user, hash, err := s.db.GetUserByPhone(r.Context(), phone)
	if err != nil {
		// Unknown phone: still run a password verification against a fixed dummy hash so
		// the response time matches the "wrong password" path. Otherwise the timing
		// difference would reveal whether a number is a member (an enumeration oracle in
		// an invite-only app).
		auth.VerifyPassword(password, dummyPasswordHash)
		writeErr(w, http.StatusUnauthorized, "incorrect phone or password")
		return
	}
	if !auth.VerifyPassword(password, hash) {
		writeErr(w, http.StatusUnauthorized, "incorrect phone or password")
		return
	}
	if user.Status != "active" {
		writeErr(w, http.StatusForbidden, "this account has been disabled")
		return
	}
	s.issueSession(w, r, user)
}

type resetPasswordReq struct {
	Phone       string `json:"phone"`
	Code        string `json:"code"`
	NewPassword string `json:"newPassword"`
}

// handleResetPassword lets a member redeem a host-issued reset code to set a new password,
// logging the device in on success. In the rate-limited auth group.
func (s *Server) handleResetPassword(w http.ResponseWriter, r *http.Request) {
	var req resetPasswordReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	newPassword := auth.NormalizePassword(req.NewPassword)
	if len(newPassword) < 8 {
		writeErr(w, http.StatusBadRequest, "password must be at least 8 characters")
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	userID, codeHash, expires, attempts, err := s.db.ResetCode(r.Context(), phone)
	// A short host-issued code needs a guess limit: lock it after maxResetAttempts wrong
	// tries so it can't be brute-forced within its window (the host re-issues a new one).
	const maxResetAttempts = 5
	if err != nil || time.Now().After(expires) || attempts >= maxResetAttempts {
		writeErr(w, http.StatusBadRequest, "invalid or expired reset code")
		return
	}
	if !auth.VerifyPassword(auth.NormalizeResetCode(req.Code), codeHash) {
		_ = s.db.BumpResetAttempt(r.Context(), userID, maxResetAttempts)
		writeErr(w, http.StatusBadRequest, "invalid or expired reset code")
		return
	}
	newHash, err := auth.HashPassword(newPassword)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if err := s.db.SetPasswordAndClearReset(r.Context(), userID, newHash); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	// Sign out everywhere, then log this device in fresh.
	_ = s.db.DeleteUserSessions(r.Context(), userID)
	user, err := s.db.GetUser(r.Context(), userID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	s.issueSession(w, r, user)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if err := s.db.DeleteSession(r.Context(), auth.HashToken(tokenFrom(r))); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, userFrom(r))
}

type updateMeReq struct {
	Name      string `json:"name"`      // display name
	FirstName string `json:"firstName"` // optional; preserved if omitted
	LastName  string `json:"lastName"`  // optional; preserved if omitted
}

// handleUpdateMe updates the authenticated user's display name and, optionally, their
// first/last name. Omitted name parts keep their current value.
func (s *Server) handleUpdateMe(w http.ResponseWriter, r *http.Request) {
	var req updateMeReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	me := userFrom(r)
	name := strings.TrimSpace(req.Name)
	if name == "" || len(name) > 100 {
		writeErr(w, http.StatusBadRequest, "name must be 1-100 characters")
		return
	}
	// Treat empty first/last as "leave unchanged" so older clients (display name only)
	// don't wipe the legal name.
	first, last := strings.TrimSpace(req.FirstName), strings.TrimSpace(req.LastName)
	if first == "" {
		first = me.FirstName
	}
	if last == "" {
		last = me.LastName
	}
	if len(first) > 100 || len(last) > 100 {
		writeErr(w, http.StatusBadRequest, "name too long (max 100 characters)")
		return
	}
	user, err := s.db.UpdateUserProfile(r.Context(), me.ID, name, first, last)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, user)
}

type setPhotoReq struct {
	MediaID int64 `json:"mediaId"`
}

// handleSetProfilePhoto sets the authenticated user's profile picture to a media item
// they own. This lets signup attach a photo after the account (and token) exist, since
// media upload itself requires auth.
func (s *Server) handleSetProfilePhoto(w http.ResponseWriter, r *http.Request) {
	var req setPhotoReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	u := userFrom(r)
	media, err := s.db.GetMedia(r.Context(), req.MediaID)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "media not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if media.OwnerID == nil || *media.OwnerID != u.ID {
		writeErr(w, http.StatusForbidden, "that image isn't yours")
		return
	}
	if !isImage(media.Mime) {
		writeErr(w, http.StatusBadRequest, "a profile photo has to be an image")
		return
	}
	if err := s.db.SetUserProfileMedia(r.Context(), u.ID, req.MediaID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	updated, err := s.db.GetUser(r.Context(), u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

// issueSession creates a session token and returns it with the user.
func (s *Server) issueSession(w http.ResponseWriter, r *http.Request, user db.User) {
	token, hash, err := auth.NewToken()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	expires := time.Now().Add(s.cfg.SessionTTL)
	if err := s.db.CreateSession(r.Context(), user.ID, hash, expires); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token":     token,
		"expiresAt": expires,
		"user":      user,
	})
}
