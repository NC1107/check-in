package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/nc1107/check-in/server/internal/config"
)

// checkPhone posts to the rate-limited /api/auth/check-phone with a distinct phone per call
// (the endpoint doesn't care whether the number means anything) and whatever request edits
// the test wants to layer on (e.g. a spoofed header), returning the status code.
func (h *harness) checkPhone(edits ...func(*http.Request)) int {
	h.t.Helper()
	raw, err := json.Marshal(map[string]any{"phone": h.nextPhone()})
	if err != nil {
		h.t.Fatalf("encode body: %v", err)
	}
	allEdits := append([]func(*http.Request){
		func(r *http.Request) { r.Header.Set("Content-Type", "application/json") },
	}, edits...)
	return h.do(http.MethodPost, "/api/auth/check-phone", "", bytes.NewReader(raw), allEdits...).Status
}

// CRITICAL 3 of the pre-submission audit: rateLimitAuth used to key its bucket on the
// client-supplied X-Real-IP header outright. Nothing between an internet caller and this
// server ever strips or overwrites that header (Caddy's reverse_proxy only ever adds
// X-Forwarded-For unless told otherwise), so a caller sending a fresh X-Real-IP on every
// request minted a fresh, always-empty bucket every time - confirmed against production,
// where 60 rapid /api/auth/check-phone calls, and 14 more each with a different spoofed
// X-Real-IP, all returned 200.
//
// The fix stops reading X-Real-IP at all. This proves that: every request below shares one
// bucket (RemoteAddr, since none of them carry a trusted X-Forwarded-For hop either) no
// matter what X-Real-IP claims, so the burst is exhausted on schedule and the 11th request
// - not some later one an attacker could keep pushing out by relabeling itself - is the
// first to be throttled.
func TestAuthRateLimitIgnoresSpoofedXRealIP(t *testing.T) {
	h := newHarness(t)
	burst := h.srv.authLim.burst // 10, per newRateLimiter(20, 10) in server.go

	for i := 0; i < int(burst); i++ {
		spoofedIP := "203.0.113." + itoa(int64(i))
		got := h.checkPhone(func(r *http.Request) {
			r.Header.Set("X-Real-IP", spoofedIP)
		})
		if got != http.StatusOK {
			t.Fatalf("request %d (X-Real-IP=%s) = %d, want 200 - still inside the burst", i, spoofedIP, got)
		}
	}

	// One more, with yet another spoofed X-Real-IP: if the header still influenced the
	// bucket key this would look like a brand new caller and succeed. It must not.
	got := h.checkPhone(func(r *http.Request) {
		r.Header.Set("X-Real-IP", "198.51.100.77")
	})
	if got != http.StatusTooManyRequests {
		t.Errorf("request past the burst (fresh spoofed X-Real-IP) = %d, want 429 - "+
			"the header must not be able to mint a new bucket", got)
	}
}

// The other half of the same header: an attacker-controlled entry prepended to
// X-Forwarded-For ahead of the position the real reverse proxy fills. The default
// TrustedProxyHops (1, matching the standard Caddy deployment - see its doc comment) trusts
// exactly the rightmost entry, so whatever a caller puts to the left of it (their own
// attempt to impersonate an earlier hop) must be ignored, and every request below must
// still land in one bucket despite each carrying a different value there.
func TestAuthRateLimitIgnoresUntrustedXFFHop(t *testing.T) {
	h := newHarness(t)
	burst := h.srv.authLim.burst

	for i := 0; i < int(burst); i++ {
		attackerHop := "203.0.113." + itoa(int64(i)) // varies every request, attacker-controlled
		got := h.checkPhone(func(r *http.Request) {
			// "<attacker-controlled>, <what the real Caddy hop actually appended>" - only
			// the rightmost, fixed entry may legitimately move the bucket.
			r.Header.Set("X-Forwarded-For", attackerHop+", 10.0.0.5")
		})
		if got != http.StatusOK {
			t.Fatalf("request %d = %d, want 200 - still inside the burst", i, got)
		}
	}

	got := h.checkPhone(func(r *http.Request) {
		r.Header.Set("X-Forwarded-For", "198.51.100.200, 10.0.0.5")
	})
	if got != http.StatusTooManyRequests {
		t.Errorf("request past the burst (fresh untrusted hop, same trusted hop) = %d, want 429", got)
	}
}

// Configuring more than one trusted hop (a host fronting Caddy with their own proxy)
// trusts the position that many hops back from the server - not the rightmost entry, and
// not the leftmost either. This pins that TrustedProxyHops actually changes which position
// is read, using a synthetic 3-entry chain: [attacker's own claim, the outer proxy's
// addition, Caddy's addition]. With TrustedProxyHops = 2 the outer proxy's entry (the
// second-from-right) is what's trusted - varying it must move the bucket even though the
// rightmost (Caddy's) entry stays fixed, and varying the leftmost (the attacker's own
// claim) must not.
func TestAuthRateLimitHonoursConfiguredHopCount(t *testing.T) {
	h := newHarnessWithConfig(t, func(cfg *config.Config) { cfg.TrustedProxyHops = 2 })

	first := h.checkPhone(func(r *http.Request) {
		r.Header.Set("X-Forwarded-For", "203.0.113.1, 10.0.0.9, 10.0.0.5")
	})
	if first != http.StatusOK {
		t.Fatalf("first request = %d, want 200", first)
	}

	t.Run("varying the untrusted leftmost claim shares the same bucket", func(t *testing.T) {
		got := h.checkPhone(func(r *http.Request) {
			r.Header.Set("X-Forwarded-For", "203.0.113.99, 10.0.0.9, 10.0.0.5")
		})
		if got != http.StatusOK {
			t.Errorf("status = %d, want 200 (still one caller by the trusted hop's own entry)", got)
		}
	})

	t.Run("varying the trusted second-from-right hop is a different caller", func(t *testing.T) {
		got := h.checkPhone(func(r *http.Request) {
			r.Header.Set("X-Forwarded-For", "203.0.113.1, 10.0.0.200, 10.0.0.5")
		})
		if got != http.StatusOK {
			t.Errorf("status = %d, want 200 (a genuinely different trusted-hop entry is a new bucket)", got)
		}
	})
}

// Sanity check the fix didn't also break the limiter altogether: with nothing at all
// distinguishing callers (the default harness has no proxy chain), repeated calls still
// share the RemoteAddr bucket and 429 once the burst is spent.
func TestAuthRateLimitEngagesPastBurst(t *testing.T) {
	h := newHarness(t)
	burst := h.srv.authLim.burst

	for i := 0; i < int(burst); i++ {
		if got := h.checkPhone(); got != http.StatusOK {
			t.Fatalf("request %d = %d, want 200", i, got)
		}
	}
	if got := h.checkPhone(); got != http.StatusTooManyRequests {
		t.Errorf("request past the burst = %d, want 429", got)
	}
}
