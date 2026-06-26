package api

import (
	"errors"
	"net/http"
	"time"

	"github.com/nc1107/check-in/server/internal/auth"
	"github.com/nc1107/check-in/server/internal/db"
)

type uploadContactsReq struct {
	// Phones is the list of raw phone numbers from the admin's contacts. They are
	// normalized server-side before being stored on the allowlist.
	Phones []string `json:"phones"`
}

// handleUploadContacts adds the admin's contact phone numbers to the allowlist. This is
// how the admin controls who is allowed to sign up — the phone number itself is the
// access code.
func (s *Server) handleUploadContacts(w http.ResponseWriter, r *http.Request) {
	var req uploadContactsReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.Phones) == 0 {
		writeErr(w, http.StatusBadRequest, "no phone numbers provided")
		return
	}

	// Normalize and de-duplicate.
	seen := make(map[string]struct{}, len(req.Phones))
	normalized := make([]string, 0, len(req.Phones))
	for _, p := range req.Phones {
		n := auth.NormalizePhone(p, s.cfg.DefaultCountryCode)
		if n == "" {
			continue
		}
		if _, ok := seen[n]; ok {
			continue
		}
		seen[n] = struct{}{}
		normalized = append(normalized, n)
	}

	added, err := s.db.AddAllowedPhones(r.Context(), normalized, userFrom(r).ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not store contacts")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"received": len(req.Phones),
		"valid":    len(normalized),
		"added":    added,
	})
}

// handleAdminListAllowed returns the invite list (allowlist) so the admin can see who
// can sign up and which numbers have already joined.
func (s *Server) handleAdminListAllowed(w http.ResponseWriter, r *http.Request) {
	allowed, err := s.db.ListAllowedPhones(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	if allowed == nil {
		allowed = []db.AllowedPhone{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"invites": allowed})
}

type removeAllowedReq struct {
	Phone string `json:"phone"`
}

// handleAdminRemoveAllowed removes a number from the invite list. This only affects
// pending invites — someone who already signed up keeps their account (revoke them from
// the members list instead).
func (s *Server) handleAdminRemoveAllowed(w http.ResponseWriter, r *http.Request) {
	var req removeAllowedReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	phone := auth.NormalizePhone(req.Phone, s.cfg.DefaultCountryCode)
	if phone == "" {
		writeErr(w, http.StatusBadRequest, "phone required")
		return
	}
	err := s.db.RemoveAllowedPhone(r.Context(), phone)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "that number isn't on the invite list")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminListUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.db.ListAllUsers(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

// handleAdminRevokeUser disables a user account (soft delete) so they can no longer log
// in. The admin cannot revoke themselves.
func (s *Server) handleAdminRevokeUser(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	if id == userFrom(r).ID {
		writeErr(w, http.StatusBadRequest, "you cannot revoke yourself")
		return
	}
	err = s.db.SetUserStatus(r.Context(), id, "revoked")
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "user not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	// Invalidate all existing sessions so the revoked user is kicked immediately.
	_ = s.db.DeleteUserSessions(r.Context(), id)
	w.WriteHeader(http.StatusNoContent)
}

// handleAdminIssueResetCode generates a single-use recovery code for a member. The admin
// relays it out-of-band (in person / text); the member redeems it via
// /api/auth/reset-password within 24 hours to set a new password.
func (s *Server) handleAdminIssueResetCode(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	user, err := s.db.GetUser(r.Context(), id)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "user not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	code, err := auth.NewResetCode()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	hash, err := auth.HashPassword(code)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	expires := time.Now().Add(24 * time.Hour)
	if err := s.db.SetResetCode(r.Context(), id, hash, expires); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"code":      code,
		"name":      user.Name,
		"expiresAt": expires,
	})
}
