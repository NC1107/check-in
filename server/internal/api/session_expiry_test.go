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

func (h *harness) setSessionCreatedAt(a actor, created time.Time) {
	h.t.Helper()
	if _, err := h.db.Pool.Exec(context.Background(),
		`UPDATE sessions SET created_at = $2 WHERE user_id = $1`, a.ID, created); err != nil {
		h.t.Fatalf("set session created_at: %v", err)
	}
}

// The harness runs a 1h TTL, so the slide gap is TTL/10 = 6m and a session is rewritten once
// its expiry is more than 6m behind now+TTL. The harness's absolute cap is 24h.
func TestSessionSlideThrottleBoundary(t *testing.T) {
	h := newHarness(t)
	a := h.admin("Ada")

	stale := time.Now().Add(53 * time.Minute) // 7m behind now+TTL: moves
	h.setSessionExpiry(a, stale)
	h.get("/api/me", a.Token).expect(http.StatusOK)
	if got := h.sessionExpiry(a); !got.After(stale.Add(5 * time.Minute)) {
		t.Fatalf("a session 7m behind should have been extended, expiry is %v", got)
	}

	fresh := time.Now().Add(55 * time.Minute) // 5m behind now+TTL: stays
	h.setSessionExpiry(a, fresh)
	h.get("/api/me", a.Token).expect(http.StatusOK)
	if got := h.sessionExpiry(a); got.Sub(fresh).Abs() > time.Millisecond {
		t.Fatalf("a session 5m behind should not be rewritten, expiry moved from %v to %v", fresh, got)
	}
}

func TestFailedAuthSlidesNothing(t *testing.T) {
	h := newHarness(t)
	a := h.admin("Ada")

	nearEnd := time.Now().Add(5 * time.Minute)
	h.setSessionExpiry(a, nearEnd)
	h.get("/api/me", "not-a-real-token").expect(http.StatusUnauthorized)
	h.get("/api/me", "").expect(http.StatusUnauthorized)

	if got := h.sessionExpiry(a); got.Sub(nearEnd).Abs() > time.Millisecond {
		t.Fatalf("a rejected request must not touch any session, expiry moved from %v to %v", nearEnd, got)
	}
}

// Sliding must not turn a session into an immortal one: past the absolute cap it dies even
// though its sliding expiry is still in the future.
func TestSessionDiesAtAbsoluteCap(t *testing.T) {
	h := newHarness(t)
	a := h.admin("Ada")

	h.setSessionCreatedAt(a, time.Now().Add(-25*time.Hour))
	h.setSessionExpiry(a, time.Now().Add(30*time.Minute))
	h.get("/api/me", a.Token).expect(http.StatusUnauthorized)
}

func TestExtensionNeverPassesAbsoluteCap(t *testing.T) {
	h := newHarness(t)
	a := h.admin("Ada")

	created := time.Now().Add(-23*time.Hour - 30*time.Minute)
	h.setSessionCreatedAt(a, created)
	h.setSessionExpiry(a, time.Now().Add(5*time.Minute))
	h.get("/api/me", a.Token).expect(http.StatusOK)

	limit := created.Add(24 * time.Hour)
	got := h.sessionExpiry(a)
	if got.After(limit.Add(time.Second)) {
		t.Fatalf("expiry %v passed the absolute cap %v", got, limit)
	}
	if time.Until(got) < 25*time.Minute {
		t.Fatalf("the session should still have been extended up to the cap, expiry is %v", got)
	}
}
