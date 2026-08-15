package api

import (
	"context"
	"fmt"
	"log"
	"time"
)

// digestTick is how often the scheduler looks for members whose digest hour has arrived.
// Members choose an hour, not a minute, so a tick well inside the hour is enough - and the
// "at most one in 20 hours" rule in DigestTargets means a late or repeated tick can't
// double-send.
const digestTick = 10 * time.Minute

// StartDigestScheduler runs the daily-summary loop until [ctx] is cancelled. It's a no-op
// when push isn't configured, so local and test servers don't spin a pointless goroutine.
func (s *Server) StartDigestScheduler(ctx context.Context) {
	if s.push == nil {
		return
	}
	go func() {
		t := time.NewTicker(digestTick)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				s.runDigest(ctx)
			}
		}
	}()
}

// runDigest sends each due member one summary of what they missed. A member is marked as
// sent even when there was nothing to report, so the window advances and they aren't
// re-examined for the rest of the hour.
//
// It runs off the request path, outside chi's Recoverer, so a panic here would take down
// the process: recover, and bound the work so a slow FCM call can't wedge the ticker.
func (s *Server) runDigest(ctx context.Context) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("runDigest: recovered: %v", rec)
		}
	}()
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	targets, err := s.db.DigestTargets(ctx)
	if err != nil {
		log.Printf("runDigest: targets: %v", err)
		return
	}
	name := s.serverName(ctx)
	for _, t := range targets {
		if ctx.Err() != nil {
			return // shutting down; the rest keep their window and go out next tick
		}
		n, err := s.db.CountPostsSince(ctx, t.UserID, t.Since)
		if err != nil {
			log.Printf("runDigest: count for user %d: %v", t.UserID, err)
			continue // leave the window intact so they're retried, rather than skipped silently
		}
		// Mark first: a duplicate summary is worse than a missed one, and a send that fails
		// after this point is simply rolled into tomorrow's count.
		if err := s.db.MarkDigestSent(ctx, t.UserID); err != nil {
			log.Printf("runDigest: mark for user %d: %v", t.UserID, err)
			continue
		}
		if n == 0 {
			continue // nothing missed: say nothing rather than push "0 new check-ins"
		}
		tokens, err := s.db.TokensForUser(ctx, t.UserID)
		if err != nil || len(tokens) == 0 {
			continue
		}
		s.push.Send(ctx, tokens, name, digestBody(n), map[string]string{"type": "digest"}, noCollapse)
	}
}

// digestBody is the one line a member sees: how much they missed, not who posted it.
func digestBody(n int) string {
	if n == 1 {
		return "1 new check-in while you were away"
	}
	return fmt.Sprintf("%d new check-ins while you were away", n)
}
