package api

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// sessionExpiry reads the stored expiry of the actor's session straight from the table, since
// the API deliberately never reports it after login.
func (h *harness) sessionExpiry(a actor) time.Time {
	h.t.Helper()
	var exp time.Time
	err := h.db.Pool.QueryRow(context.Background(),
		`SELECT expires_at FROM sessions WHERE user_id = $1`, a.ID).Scan(&exp)
	if err != nil {
		h.t.Fatalf("read session expiry: %v", err)
	}
	return exp
}

func (h *harness) setSessionExpiry(a actor, exp time.Time) {
	h.t.Helper()
	if _, err := h.db.Pool.Exec(context.Background(),
		`UPDATE sessions SET expires_at = $2 WHERE user_id = $1`, a.ID, exp); err != nil {
		h.t.Fatalf("set session expiry: %v", err)
	}
}

// A member who keeps using the app must not be signed out when the login-time TTL runs out.
func TestActiveSessionSurvivesTTL(t *testing.T) {
	h := newHarness(t)
	a := h.admin("Ada")

	// Nearly at the end of the TTL window, as a month-old login would be.
	h.setSessionExpiry(a, time.Now().Add(5*time.Minute))
	h.get("/api/me", a.Token).expect(http.StatusOK)

	if got := h.sessionExpiry(a); time.Until(got) < 50*time.Minute {
		t.Fatalf("an actively used session must have its expiry pushed out, but it still ends in %v", time.Until(got))
	}
}

// Extension is throttled: a fresh session is not rewritten on every request.
func TestSessionExpiryNotRewrittenWhenFresh(t *testing.T) {
	h := newHarness(t)
	a := h.admin("Ada")

	before := h.sessionExpiry(a)
	h.get("/api/me", a.Token).expect(http.StatusOK)
	if after := h.sessionExpiry(a); !after.Equal(before) {
		t.Fatalf("a fresh session should not be rewritten, expiry moved from %v to %v", before, after)
	}
}

// A session left idle past its TTL still dies and is not revived by the attempt.
func TestIdleSessionStillExpires(t *testing.T) {
	h := newHarness(t)
	a := h.admin("Ada")

	h.setSessionExpiry(a, time.Now().Add(-time.Minute))
	h.get("/api/me", a.Token).expect(http.StatusUnauthorized)

	if got := h.sessionExpiry(a); got.After(time.Now()) {
		t.Fatalf("an expired session must not be revived, expiry is now %v", got)
	}
}
