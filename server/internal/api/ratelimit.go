package api

import (
	"sync"
	"time"
)

// rateLimiter is a tiny in-memory token bucket keyed by an arbitrary string (usually
// client IP). It is sufficient for a small self-hosted server; for multi-instance
// deployments this would move to a shared store.
type rateLimiter struct {
	mu        sync.Mutex
	buckets   map[string]*bucket
	rate      float64 // tokens per second
	burst     float64
	lastEvict time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

// evictInterval is how often idle buckets are swept. Driven by elapsed time rather than a
// call counter so an idle server still releases memory.
const evictInterval = 5 * time.Minute

func newRateLimiter(perMinute, burst int) *rateLimiter {
	return &rateLimiter{
		buckets:   make(map[string]*bucket),
		rate:      float64(perMinute) / 60.0,
		burst:     float64(burst),
		lastEvict: time.Now(),
	}
}

// allow reports whether an action for key may proceed, consuming one token if so.
func (r *rateLimiter) allow(key string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	// Periodically evict idle buckets to bound memory usage. Time-based so this still
	// happens on a server that goes idle after a burst.
	if now.Sub(r.lastEvict) > evictInterval {
		r.evictIdle(now)
		r.lastEvict = now
	}
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

// contentLimits throttles what an authenticated member can create. Keyed per user rather
// than per IP, because these routes are authenticated and a household or an office behind
// one address must not share a posting budget. Each action gets its own bucket, so a
// photo-heavy check-in cannot spend the allowance for commenting.
//
// The numbers stop automation, not people: they sit far above what the app produces from
// someone tapping. The burst is the part that matters for normal use, so each is sized to
// clear the largest single legitimate action that reaches that endpoint - see
// newContentLimits. A drained bucket refills continuously, so a member who hits one is
// slowed for a few seconds rather than locked out for a minute.
//
// The buckets live in this process. A member in several groups is talking to a different
// server for each, so a per-user-per-server budget is what the deployment can express, and
// it is also what makes sense: one group's activity should not throttle another's.
type contentLimits struct {
	posts    *rateLimiter
	comments *rateLimiter
	likes    *rateLimiter
	media    *rateLimiter
	gifs     *rateLimiter
}

// mediaBurst is the media allowance, and 20 is a requirement rather than a preference: a
// check-in with the maximum ten attachments, all clips, is twenty requests - each clip, then
// its poster frame - and anything smaller would reject a post the app let the member build.
const mediaBurst = 20

func newContentLimits() contentLimits {
	return contentLimits{
		// One check-in is one request. Sharing to several groups hits several servers, so
		// this counts one per group either way.
		posts: newRateLimiter(30, 10),
		// A conversation, not a script.
		comments: newRateLimiter(60, 20),
		// Scrolling back through a feed liking as you go is ordinary use, so the burst is
		// the most generous of the four.
		likes: newRateLimiter(60, 30),
		media: newRateLimiter(30, mediaBurst),
		// Search-as-you-type protection: the client debounces too, but a burst has to clear
		// a few quick keystrokes before the debounce catches up.
		gifs: newRateLimiter(30, 15),
	}
}

// evictIdle removes buckets that haven't been accessed in 10 minutes.
// Must be called with r.mu held.
func (r *rateLimiter) evictIdle(now time.Time) {
	cutoff := now.Add(-10 * time.Minute)
	for k, b := range r.buckets {
		if b.last.Before(cutoff) {
			delete(r.buckets, k)
		}
	}
}
