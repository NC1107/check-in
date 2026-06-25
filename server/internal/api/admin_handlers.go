package api

import (
	"errors"
	"net/http"

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
