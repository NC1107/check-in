package api

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/nc1107/check-in/server/internal/auth"
	"github.com/nc1107/check-in/server/internal/db"
)

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleServerInfo lets the app discover the server name and whether an admin exists
// yet (so it can show first-admin setup vs. normal signup/login).
func (s *Server) handleServerInfo(w http.ResponseWriter, r *http.Request) {
	initialized, err := s.db.ServerInitialized(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":        s.cfg.ServerName,
		"initialized": initialized,
	})
}

type checkPhoneReq struct {
	Phone string `json:"phone"`
}

// handleCheckPhone reports whether a phone may sign up. The first user (before any
// admin exists) may always sign up and becomes the admin; everyone else must be on the
// allowlist and not already used.
func (s *Server) handleCheckPhone(w http.ResponseWriter, r *http.Request) {
	var req checkPhoneReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	if phone == "" {
		writeErr(w, http.StatusBadRequest, "phone required")
		return
	}
	initialized, err := s.db.ServerInitialized(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
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
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	allowed, used, err := s.db.PhoneAllowed(r.Context(), phone)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"allowed":      allowed && !used, // may still claim an invite (sign up)
		"registered":   registered,       // already has an account (log in)
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
	MediaID     *int64 `json:"mediaId,omitempty"` // optional pre-uploaded profile picture
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
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	name := req.displayName()
	if phone == "" || name == "" || len(req.Password) < 8 {
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

	initialized, err := s.db.ServerInitialized(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}

	isAdmin := false
	if !initialized {
		// First ever user → admin.
		isAdmin = true
	} else {
		allowed, used, err := s.db.PhoneAllowed(r.Context(), phone)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "server error")
			return
		}
		if !allowed {
			writeErr(w, http.StatusForbidden, "this phone number is not on the invite list")
			return
		}
		if used {
			writeErr(w, http.StatusConflict, "this phone number has already been registered")
			return
		}
	}

	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}

	user, err := s.db.CreateUser(r.Context(), phone, name,
		strings.TrimSpace(req.FirstName), strings.TrimSpace(req.LastName),
		birthday, req.MediaID, hash, isAdmin)
	if err != nil {
		writeErr(w, http.StatusConflict, "could not create account (phone may already exist)")
		return
	}

	if isAdmin {
		if err := s.db.MarkInitialized(r.Context()); err != nil {
			writeErr(w, http.StatusInternalServerError, "server error")
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
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	user, hash, err := s.db.GetUserByPhone(r.Context(), phone)
	if err != nil || !auth.VerifyPassword(req.Password, hash) {
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
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.NewPassword) < 8 {
		writeErr(w, http.StatusBadRequest, "password must be at least 8 characters")
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	userID, codeHash, expires, err := s.db.ResetCode(r.Context(), phone)
	if err != nil || time.Now().After(expires) ||
		!auth.VerifyPassword(auth.NormalizeResetCode(req.Code), codeHash) {
		writeErr(w, http.StatusBadRequest, "invalid or expired reset code")
		return
	}
	newHash, err := auth.HashPassword(req.NewPassword)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	if err := s.db.SetPasswordAndClearReset(r.Context(), userID, newHash); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	// Sign out everywhere, then log this device in fresh.
	_ = s.db.DeleteUserSessions(r.Context(), userID)
	user, err := s.db.GetUser(r.Context(), userID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	s.issueSession(w, r, user)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if err := s.db.DeleteSession(r.Context(), auth.HashToken(tokenFrom(r))); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
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
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	me := userFrom(r)
	name := strings.TrimSpace(req.Name)
	if name == "" || len(name) > 100 {
		writeErr(w, http.StatusBadRequest, "name must be 1–100 characters")
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
		writeErr(w, http.StatusInternalServerError, "server error")
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
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	u := userFrom(r)
	media, err := s.db.GetMedia(r.Context(), req.MediaID)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "media not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	if media.OwnerID == nil || *media.OwnerID != u.ID {
		writeErr(w, http.StatusForbidden, "that image isn't yours")
		return
	}
	if err := s.db.SetUserProfileMedia(r.Context(), u.ID, req.MediaID); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	updated, err := s.db.GetUser(r.Context(), u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

// issueSession creates a session token and returns it with the user.
func (s *Server) issueSession(w http.ResponseWriter, r *http.Request, user db.User) {
	token, hash, err := auth.NewToken()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	expires := time.Now().Add(s.cfg.SessionTTL)
	if err := s.db.CreateSession(r.Context(), user.ID, hash, expires); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token":     token,
		"expiresAt": expires,
		"user":      user,
	})
}
