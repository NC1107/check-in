package api

import (
	"testing"
	"time"
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
