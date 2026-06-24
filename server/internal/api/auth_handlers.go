package api

import (
	"net/http"
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
	if err := decodeJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	phone := auth.NormalizePhone(req.Phone)
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
		writeJSON(w, http.StatusOK, map[string]any{"allowed": true, "isFirstAdmin": true})
		return
	}
	allowed, used, err := s.db.PhoneAllowed(r.Context(), phone)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"allowed":      allowed && !used,
		"isFirstAdmin": false,
	})
}

type signupReq struct {
	Phone    string `json:"phone"`
	Name     string `json:"name"`
	Birthday string `json:"birthday"` // YYYY-MM-DD
	Password string `json:"password"`
	MediaID  *int64 `json:"mediaId,omitempty"` // optional pre-uploaded profile picture
}

// handleSignup registers a new user. The first signup on a fresh server becomes the
// admin (bypassing the allowlist, which is empty); subsequent signups require the
// normalized phone to be on the allowlist and unused.
func (s *Server) handleSignup(w http.ResponseWriter, r *http.Request) {
	var req signupReq
	if err := decodeJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	phone := auth.NormalizePhone(req.Phone)
	if phone == "" || req.Name == "" || len(req.Password) < 6 {
		writeErr(w, http.StatusBadRequest, "phone, name and a 6+ char password are required")
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

	user, err := s.db.CreateUser(r.Context(), phone, req.Name, birthday, req.MediaID, hash, isAdmin)
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
	if err := decodeJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	phone := auth.NormalizePhone(req.Phone)
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
