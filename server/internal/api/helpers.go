package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/nc1107/check-in/server/internal/auth"
	"github.com/nc1107/check-in/server/internal/db"
)

type ctxKey string

const userCtxKey ctxKey = "user"
const tokenCtxKey ctxKey = "token"

// writeJSON sends a JSON response with the given status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeErr sends a JSON error envelope.
func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// decodeJSON parses a JSON request body into v, capping the body size.
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// userFrom returns the authenticated user attached by requireAuth.
func userFrom(r *http.Request) db.User {
	u, _ := r.Context().Value(userCtxKey).(db.User)
	return u
}

func tokenFrom(r *http.Request) string {
	t, _ := r.Context().Value(tokenCtxKey).(string)
	return t
}

// pathInt parses a numeric URL parameter.
func pathInt(r *http.Request, name string) (int64, error) {
	return strconv.ParseInt(chi.URLParam(r, name), 10, 64)
}

// requireAuth validates the bearer token and attaches the user to the context.
func (s *Server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		token := strings.TrimPrefix(header, "Bearer ")
		if token == "" || token == header {
			writeErr(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		user, err := s.db.UserForToken(r.Context(), auth.HashToken(token))
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "invalid or expired session")
			return
		}
		ctx := context.WithValue(r.Context(), userCtxKey, user)
		ctx = context.WithValue(ctx, tokenCtxKey, token)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// requireAdmin ensures the authenticated user is the admin.
func (s *Server) requireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !userFrom(r).IsAdmin {
			writeErr(w, http.StatusForbidden, "admin only")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// rateLimitAuth throttles unauthenticated auth endpoints by client IP.
func (s *Server) rateLimitAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.authLim.allow(r.RemoteAddr) {
			writeErr(w, http.StatusTooManyRequests, "too many attempts, slow down")
			return
		}
		next.ServeHTTP(w, r)
	})
}
