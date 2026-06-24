package api

import (
	"sync"
	"time"
)

// rateLimiter is a tiny in-memory token bucket keyed by an arbitrary string (usually
// client IP). It is sufficient for a small self-hosted server; for multi-instance
// deployments this would move to a shared store.
type rateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	rate    float64 // tokens per second
	burst   float64
}

type bucket struct {
	tokens float64
	last   time.Time
}

func newRateLimiter(perMinute, burst int) *rateLimiter {
	return &rateLimiter{
		buckets: make(map[string]*bucket),
		rate:    float64(perMinute) / 60.0,
		burst:   float64(burst),
	}
}

// allow reports whether an action for key may proceed, consuming one token if so.
func (r *rateLimiter) allow(key string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	b, ok := r.buckets[key]
	if !ok {
		r.buckets[key] = &bucket{tokens: r.burst - 1, last: now}
		return true
	}
	b.tokens += now.Sub(b.last).Seconds() * r.rate
	if b.tokens > r.burst {
		b.tokens = r.burst
	}
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}
