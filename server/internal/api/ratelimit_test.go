package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

func TestRateLimiterBurstThenDeny(t *testing.T) {
	rl := newRateLimiter(60, 3) // 1 token/sec, burst 3
	for i := 0; i < 3; i++ {
		if !rl.allow("ip") {
			t.Fatalf("burst token %d should be allowed", i)
		}
	}
	if rl.allow("ip") {
		t.Fatal("expected denial once the burst is exhausted")
	}
	if !rl.allow("other-ip") {
		t.Fatal("a different key must have its own bucket")
	}
}

func TestRateLimiterRecoversOverTime(t *testing.T) {
	rl := newRateLimiter(60, 2) // 1 token/sec, burst 2
	rl.allow("ip")
	rl.allow("ip")
	if rl.allow("ip") {
		t.Fatal("bucket should be empty")
	}
	// Simulate ~2 seconds elapsing so two tokens refill.
	rl.buckets["ip"].last = time.Now().Add(-2 * time.Second)
	if !rl.allow("ip") {
		t.Fatal("token should have refilled after time passed")
	}
}

// The content limiter keys on the member, not the address. Two people on the same home
// wi-fi, or a whole office behind one address, each get their own allowance.
func TestRateLimitUserKeysOnTheMember(t *testing.T) {
	s := &Server{content: contentLimits{posts: newRateLimiter(60, 2)}}
	handler := s.rateLimitUser(s.content.posts)(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
	}))
	post := func(userID int64) int {
		r := httptest.NewRequest(http.MethodPost, "/api/posts", nil)
		r.RemoteAddr = "203.0.113.7:44321" // one address for everyone
		r = r.WithContext(context.WithValue(r.Context(), userCtxKey, db.User{ID: userID}))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w.Code
	}

	for i := 0; i < 2; i++ {
		if got := post(7); got != http.StatusCreated {
			t.Fatalf("burst request %d = %d, want 201", i, got)
		}
	}
	if got := post(7); got != http.StatusTooManyRequests {
		t.Errorf("status past the burst = %d, want 429", got)
	}
	if got := post(8); got != http.StatusCreated {
		t.Errorf("another member from the same address = %d, want 201", got)
	}
}

// Each burst has to clear the largest single action that reaches its endpoint, or the limiter
// rejects something the app itself let the member build.
func TestContentBurstsClearOneWholeCheckIn(t *testing.T) {
	limits := newContentLimits()
	// Ten attachments is the cap handleCreatePost enforces; as clips that is an upload and a
	// poster each.
	if limits.media.burst < 20 {
		t.Errorf("media burst = %v, want at least 20 - a ten-clip check-in is that many requests",
			limits.media.burst)
	}
	if limits.posts.burst < 1 || limits.comments.burst < 1 || limits.likes.burst < 1 {
		t.Error("every content bucket must allow at least one action")
	}
}
