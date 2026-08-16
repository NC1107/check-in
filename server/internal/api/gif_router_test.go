package api

import (
	"net/http"
	"testing"
)

// The unit tests in gif_handlers_test.go call handleGifSearch directly, bypassing chi's
// middleware chain entirely - so the rate limiter wired onto the route in Router() has never
// actually been exercised through a real request. This drives the real route, through the
// real router, repeatedly, the same way TestRateLimitUserKeysOnTheMember exercises
// rateLimitUser directly.
//
// No Klipy key is configured, so every request 503s before the middleware even matters -
// which is fine: rateLimitUser runs ahead of the handler body and consumes a token
// regardless of what the handler goes on to do with the request.
func TestGifSearchRouteIsRateLimited(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	burst := int(newContentLimits().gifs.burst)
	for i := 0; i < burst; i++ {
		h.get("/api/gifs/search", admin.Token).expect(http.StatusServiceUnavailable)
	}
	res := h.get("/api/gifs/search", admin.Token)
	if res.Status != http.StatusTooManyRequests {
		t.Fatalf("status past the burst = %d, want 429; body: %s", res.Status, res.Body)
	}
}
