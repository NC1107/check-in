package api

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

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
func decodeJSON(w http.ResponseWriter, r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
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
//
// The key comes from middleware.GetClientIP, which Router's
// middleware.ClientIPFromXFFTrustedProxies populates from the position in the merged
// X-Forwarded-For chain that only a trusted reverse proxy could have written - never a
// header a caller can just set themselves. That matters here specifically: this group is
// the one auth-rate-limited path unauthenticated callers can hit directly, so it's the one
// an attacker actually controls the request headers of. (rateLimitUser doesn't have this
// problem - it keys on the authenticated user id, not an address at all.)
//
// The previous version keyed on the client-supplied X-Real-IP outright, on the theory that
// Caddy sets it - it doesn't; Caddy's reverse_proxy only ever adds X-Forwarded-For unless
// told otherwise, so that header reached this handler exactly as a caller sent it. A
// production check against /api/auth/check-phone confirmed the result: 60 rapid requests
// all succeeded, and so did 14 more with a fresh X-Real-IP on each one - every request
// minted its own always-empty bucket.
//
// RemoteAddr is the fallback for a request with no trusted-proxy chain at all (local dev
// with no Caddy in front, or the harness's own httptest requests) - the raw TCP peer, which
// can't be spoofed.
func (s *Server) rateLimitAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := middleware.GetClientIP(r.Context())
		if ip == "" {
			ip, _, _ = net.SplitHostPort(r.RemoteAddr)
			if ip == "" {
				ip = r.RemoteAddr
			}
		}
		if !s.authLim.allow(ip) {
			writeErr(w, http.StatusTooManyRequests, "too many attempts, slow down")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// rateLimitUser throttles a content route by the member making the request. Mount it inside
// the requireAuth group: the user it keys on is the one that middleware attached, and
// outside it every request would share the zero-id bucket.
func (s *Server) rateLimitUser(lim *rateLimiter) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !lim.allow(strconv.FormatInt(userFrom(r).ID, 10)) {
				writeErr(w, http.StatusTooManyRequests, "too many requests, slow down")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// Shared response messages.
//
// Defined once because each of these is written from a dozen or more handlers, and a client
// reading them cannot tell "server error" from "Server error" apart from noticing the
// inconsistency. Naming them also makes every site that can produce one greppable, which
// matters most for the internal-error case: it is the one a member can do nothing about, so
// its wording should never quietly diverge between endpoints.
const (
	msgServerError  = "server error"
	msgInvalidID    = "invalid id"
	msgInvalidBody  = "invalid body"
	msgInvalidForm  = "invalid form"
	msgPostNotFound = "post not found"
)
