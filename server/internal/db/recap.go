package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// recapMinPosts and recapMinPosters are the quality bar a period must clear before a
// recap is generated at all: fewer than this and there's nothing worth a deck for. Mirrors
// runDigest's "say nothing rather than push 0 new check-ins" philosophy - a recap is never
// posted for an empty or near-empty period.
const (
	recapMinPosts   = 3
	recapMinPosters = 2
)

// ErrRecapEmpty is returned by BuildRecap when the period doesn't clear the quality bar.
// Callers (the scheduler, the on-demand handler) must treat it as "nothing to post", not
// as a failure.
var ErrRecapEmpty = errors.New("recap: not enough activity in this period")

// RecapSpec describes one recap to generate: the period it covers, which panels to
// include, its cadence, and whether the scheduler or an admin is asking for it.
type RecapSpec struct {
	PeriodStart, PeriodEnd time.Time
	Panels                 []string // "collage" | "awards" in v1, sorted
	Cadence                string   // weekly | monthly | custom
	Origin                 string   // scheduled | manual
}

// RecapSettings is the group's standing recap configuration, mirroring the digest
// hour/offset precedent in 0013: the host picks a local hour (and, for weekly, a
// weekday); the app refreshes Offset on launch so a DST shift self-corrects.
type RecapSettings struct {
	Cadence string    `json:"cadence"` // off | weekly | monthly
	Weekday int       `json:"weekday"` // ISO, 1=Mon..7=Sun; weekly only
	Hour    int       `json:"hour"`    // 0-23, group-local
	Offset  int       `json:"offset"`  // minutes east of UTC
	Since   time.Time `json:"since"`   // backfill guard; not client-settable
}

// GetRecapSettings returns the group's standing recap configuration.
func (d *DB) GetRecapSettings(ctx context.Context) (RecapSettings, error) {
	var s RecapSettings
	err := d.Pool.QueryRow(ctx, `
		SELECT recap_cadence, recap_weekday, recap_hour, recap_offset, recap_since
		FROM server_config WHERE id = 1`,
	).Scan(&s.Cadence, &s.Weekday, &s.Hour, &s.Offset, &s.Since)
	return s, err
}

// SetRecapSettings updates the group's standing recap configuration. recap_since (the
// backfill guard) is deliberately not settable here - it is stamped once, when the
// feature is first configured on a server, by the migration's default.
func (d *DB) SetRecapSettings(ctx context.Context, cadence string, weekday, hour, offset int) error {
	_, err := d.Pool.Exec(ctx, `
		UPDATE server_config
		SET recap_cadence = $1, recap_weekday = $2, recap_hour = $3, recap_offset = $4
		WHERE id = 1`, cadence, weekday, hour, offset)
	return err
}

// BuildRecap gathers a period's activity and assembles the recap payload: the ranked
// collage and/or the awards panel, whichever spec.Panels asks for. Returns ErrRecapEmpty
// when the period doesn't clear the quality bar.
func (d *DB) BuildRecap(ctx context.Context, spec RecapSpec) (RecapPayload, error) {
	groupName, err := d.GetServerName(ctx)
	if err != nil {
		return RecapPayload{}, fmt.Errorf("group name: %w", err)
	}
	groupColor, err := d.GetServerColor(ctx)
	if err != nil {
		return RecapPayload{}, fmt.Errorf("group color: %w", err)
	}
	memberCount, err := d.activeMemberCount(ctx)
	if err != nil {
		return RecapPayload{}, fmt.Errorf("member count: %w", err)
	}
	candidates, err := d.recapCandidates(ctx, spec.PeriodStart, spec.PeriodEnd)
	if err != nil {
		return RecapPayload{}, fmt.Errorf("candidates: %w", err)
	}

	posters := make(map[int64]struct{}, len(candidates))
	for _, c := range candidates {
		posters[c.AuthorID] = struct{}{}
	}
	if len(candidates) < recapMinPosts || len(posters) < recapMinPosters {
		return RecapPayload{}, ErrRecapEmpty
	}

	payload := RecapPayload{
		V: 1,
		Period: RecapPeriod{
			Start:   spec.PeriodStart,
			End:     spec.PeriodEnd,
			Label:   recapPeriodLabel(spec.Cadence, spec.PeriodStart, spec.PeriodEnd),
			Cadence: spec.Cadence,
		},
		Group: RecapGroup{Name: groupName, Color: groupColor},
		Stats: recapStats(candidates, memberCount),
	}

	for _, panel := range spec.Panels {
		switch panel {
		case "collage":
			if cards := selectCollageCards(candidates, memberCount, spec.Cadence); len(cards) > 0 {
				payload.Panels = append(payload.Panels, RecapPanel{Type: "collage", Title: "The Wall", Cards: cards})
			}
		case "awards":
			awardCandidates, err := d.recapAwardCandidates(ctx, spec.PeriodStart, spec.PeriodEnd, candidates)
			if err != nil {
				return RecapPayload{}, fmt.Errorf("award candidates: %w", err)
			}
			if awards := selectAwards(awardCandidates); len(awards) > 0 {
				payload.Panels = append(payload.Panels, RecapPanel{Type: "awards", Title: "Awards Night", Awards: awards})
			}
		}
	}
	return payload, nil
}

// recapPeriodLabel renders the period as "Aug 10-16" (weekly, or custom within one month),
// "Jul 28 - Aug 3" (custom spanning two months) or "August 2026" (monthly). end is
// exclusive, so the period's last day is the one just before it.
func recapPeriodLabel(cadence string, start, end time.Time) string {
	last := end.AddDate(0, 0, -1)
	if cadence == "monthly" {
		return last.Format("January 2006")
	}
	if start.Month() == last.Month() && start.Year() == last.Year() {
		return fmt.Sprintf("%s %d-%d", start.Format("Jan"), start.Day(), last.Day())
	}
	return fmt.Sprintf("%s %d - %s %d", start.Format("Jan"), start.Day(), last.Format("Jan"), last.Day())
}

// recapStats summarises a period's candidates into the at-a-glance numbers shown before
// the deck (and used to write the fallback body text for a client too old to render it).
func recapStats(candidates []recapCandidate, memberCount int) RecapStats {
	stats := RecapStats{Posts: len(candidates), Members: memberCount}
	places := make(map[string]struct{})
	posters := make(map[int64]struct{})
	for _, c := range candidates {
		stats.Likes += c.LikeCount
		stats.Comments += c.CommentCount
		posters[c.AuthorID] = struct{}{}
		if c.MediaID != nil {
			if strings.HasPrefix(c.Mime, "video/") {
				stats.Clips++
			} else {
				stats.Photos++
			}
		}
		if c.Location != "" {
			places[c.Location] = struct{}{}
		}
	}
	stats.Places = len(places)
	stats.Posters = len(posters)
	return stats
}

// activeMemberCount is how many active members the group currently has - the everyone-
// included guarantee's target size, and the collage cap's floor.
func (d *DB) activeMemberCount(ctx context.Context) (int, error) {
	var n int
	err := d.Pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE status = 'active'`).Scan(&n)
	return n, err
}

// recapCandidates returns every post in [start, end) eligible for the collage: from an
// active author, never a previous recap, with its engagement counts and (if any) its
// first attachment - the one the collage card renders.
func (d *DB) recapCandidates(ctx context.Context, start, end time.Time) ([]recapCandidate, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, u.name, u.profile_media_id, p.body, p.location, p.created_at,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id),
		       pm.media_id, m.mime, m.width, m.height, m.duration_ms,
		       COALESCE(m.poster_path, '') <> ''
		FROM posts p
		JOIN users u ON u.id = p.author_id
		LEFT JOIN LATERAL (
			SELECT media_id FROM post_media WHERE post_id = p.id ORDER BY position LIMIT 1
		) pm ON true
		LEFT JOIN media m ON m.id = pm.media_id
		WHERE p.kind <> 'recap' AND u.status = 'active'
		  AND p.created_at >= $1 AND p.created_at < $2`, start, end)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []recapCandidate
	for rows.Next() {
		var c recapCandidate
		var location *string
		var mime *string
		var width, height, durationMs *int
		if err := rows.Scan(&c.PostID, &c.AuthorID, &c.AuthorName, &c.AuthorPhotoID, &c.Body, &location, &c.CreatedAt,
			&c.LikeCount, &c.CommentCount, &c.MediaID, &mime, &width, &height, &durationMs, &c.HasPoster); err != nil {
			return nil, err
		}
		if location != nil {
			c.Location = *location
		}
		if mime != nil {
			c.Mime = *mime
		}
		if width != nil {
			c.Width = *width
		}
		if height != nil {
			c.Height = *height
		}
		if durationMs != nil {
			c.DurationMs = *durationMs
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// recapMember is an active member's identity, for members who qualify for an award
// without necessarily having posted (Chatterbox, Biggest Fan, Most Tagged all reward
// activity on OTHER members' posts).
type recapMember struct {
	ID      int64
	Name    string
	PhotoID *int64
}

func (d *DB) activeMembers(ctx context.Context) ([]recapMember, error) {
	rows, err := d.Pool.Query(ctx, `SELECT id, name, profile_media_id FROM users WHERE status = 'active'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []recapMember
	for rows.Next() {
		var m recapMember
		if err := rows.Scan(&m.ID, &m.Name, &m.PhotoID); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// recapCountByUser runs a `SELECT user_id, count(*) ... GROUP BY user_id`-shaped query and
// returns it as a map, for the three Awards Night metrics that count activity on OTHER
// members' posts (comments written, likes given, times tagged).
func (d *DB) recapCountByUser(ctx context.Context, query string, args ...any) (map[int64]int, error) {
	rows, err := d.Pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[int64]int)
	for rows.Next() {
		var id int64
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return nil, err
		}
		out[id] = n
	}
	return out, rows.Err()
}

// memberActivity accumulates one member's own-post activity across the period, from which
// most of Awards Night's per-post superlatives (Most Loved, Night Owl, Early Bird, Most
// Travelled, Quiet Achiever, Longest Thread) are derived.
type memberActivity struct {
	postCount     int
	likesReceived int
	places        map[string]struct{}
	mostLiked     *recapCandidate // highest LikeCount
	longestThread *recapCandidate // highest CommentCount
	nightOwl      *recapCandidate // latest time-of-day (UTC minute-of-day)
	earlyBird     *recapCandidate // earliest time-of-day
}

// minuteOfDay is a post's UTC time-of-day in minutes (0-1439), used to judge Night Owl and
// Early Bird. Per-member local time isn't tracked for posts (unlike the digest hour), so
// this is a deliberate v1 simplification - accurate for a group that shares a timezone,
// approximate otherwise.
func minuteOfDay(t time.Time) int {
	t = t.UTC()
	return t.Hour()*60 + t.Minute()
}

// recapAwardCandidates turns a period's candidates plus three activity-on-others queries
// into one awardCandidate per active member, ready for selectAwards to judge.
func (d *DB) recapAwardCandidates(ctx context.Context, start, end time.Time, candidates []recapCandidate) ([]awardCandidate, error) {
	members, err := d.activeMembers(ctx)
	if err != nil {
		return nil, err
	}
	commentsWritten, err := d.recapCountByUser(ctx, `
		SELECT c.user_id, count(*) FROM comments c JOIN users u ON u.id = c.user_id
		WHERE u.status = 'active' AND c.created_at >= $1 AND c.created_at < $2
		GROUP BY c.user_id`, start, end)
	if err != nil {
		return nil, err
	}
	likesGiven, err := d.recapCountByUser(ctx, `
		SELECT l.user_id, count(*) FROM likes l JOIN users u ON u.id = l.user_id
		WHERE u.status = 'active' AND l.created_at >= $1 AND l.created_at < $2
		GROUP BY l.user_id`, start, end)
	if err != nil {
		return nil, err
	}
	timesTagged, err := d.recapCountByUser(ctx, `
		SELECT pp.user_id, count(*) FROM post_people pp
		JOIN posts p ON p.id = pp.post_id
		JOIN users u ON u.id = pp.user_id
		WHERE u.status = 'active' AND p.created_at >= $1 AND p.created_at < $2
		  AND p.author_id <> pp.user_id
		GROUP BY pp.user_id`, start, end)
	if err != nil {
		return nil, err
	}

	agg := make(map[int64]*memberActivity, len(members))
	for _, m := range members {
		agg[m.ID] = &memberActivity{places: make(map[string]struct{})}
	}
	for _, c := range candidates {
		a, ok := agg[c.AuthorID]
		if !ok {
			continue // author isn't active any more; recapCandidates already excludes them
		}
		a.postCount++
		a.likesReceived += c.LikeCount
		if c.Location != "" {
			a.places[c.Location] = struct{}{}
		}
		if a.mostLiked == nil || c.LikeCount > a.mostLiked.LikeCount ||
			(c.LikeCount == a.mostLiked.LikeCount && candidateOutranks(c, *a.mostLiked)) {
			cc := c
			a.mostLiked = &cc
		}
		if a.longestThread == nil || c.CommentCount > a.longestThread.CommentCount ||
			(c.CommentCount == a.longestThread.CommentCount && candidateOutranks(c, *a.longestThread)) {
			cc := c
			a.longestThread = &cc
		}
		if a.nightOwl == nil || minuteOfDay(c.CreatedAt) > minuteOfDay(a.nightOwl.CreatedAt) {
			cc := c
			a.nightOwl = &cc
		}
		if a.earlyBird == nil || minuteOfDay(c.CreatedAt) < minuteOfDay(a.earlyBird.CreatedAt) {
			cc := c
			a.earlyBird = &cc
		}
	}

	// Quiet Achiever's pool is posting members at or below the average post count, so a
	// member who checked in constantly can't win it on volume alone - it rewards a small,
	// well-received contribution, not a large mediocre one.
	var totalPosts, postingMembers int
	for _, a := range agg {
		if a.postCount > 0 {
			totalPosts += a.postCount
			postingMembers++
		}
	}
	avgPosts := 0.0
	if postingMembers > 0 {
		avgPosts = float64(totalPosts) / float64(postingMembers)
	}

	out := make([]awardCandidate, 0, len(members))
	for _, m := range members {
		a := agg[m.ID]
		c := awardCandidate{UserID: m.ID, UserName: m.Name, UserPhotoID: m.PhotoID}

		if a.mostLiked != nil && a.mostLiked.LikeCount > 0 {
			c.MostLiked = awardEntry{
				Qualifies: true, Value: a.mostLiked.LikeCount,
				DisplayValue: pluralize(a.mostLiked.LikeCount, "like"),
				PostID:       a.mostLiked.PostID, MediaID: a.mostLiked.MediaID,
			}
		}
		if a.nightOwl != nil {
			c.NightOwl = awardEntry{
				Qualifies: true, Value: minuteOfDay(a.nightOwl.CreatedAt),
				DisplayValue: a.nightOwl.CreatedAt.UTC().Format("3:04 PM"),
				PostID:       a.nightOwl.PostID, MediaID: a.nightOwl.MediaID,
			}
		}
		if a.earlyBird != nil {
			// Inverted so "higher Value wins" (selectAwards' one ranking rule) means
			// earliest, matching every other award's convention.
			c.EarlyBird = awardEntry{
				Qualifies: true, Value: 1440 - minuteOfDay(a.earlyBird.CreatedAt),
				DisplayValue: a.earlyBird.CreatedAt.UTC().Format("3:04 PM"),
				PostID:       a.earlyBird.PostID, MediaID: a.earlyBird.MediaID,
			}
		}
		if len(a.places) > 0 {
			c.MostTravelled = awardEntry{
				Qualifies: true, Value: len(a.places),
				DisplayValue: pluralize(len(a.places), "place"),
			}
		}
		if n := commentsWritten[m.ID]; n > 0 {
			c.Chatterbox = awardEntry{Qualifies: true, Value: n, DisplayValue: pluralize(n, "comment")}
		}
		if n := likesGiven[m.ID]; n > 0 {
			c.BiggestFan = awardEntry{Qualifies: true, Value: n, DisplayValue: fmt.Sprintf("%d likes given", n)}
		}
		if a.postCount > 0 && float64(a.postCount) <= avgPosts {
			avgLikes := float64(a.likesReceived) / float64(a.postCount)
			c.QuietAchiever = awardEntry{
				Qualifies: true, Value: int(avgLikes*100 + 0.5),
				DisplayValue: fmt.Sprintf("%.1f likes/post", avgLikes),
			}
		}
		if n := timesTagged[m.ID]; n > 0 {
			c.MostTagged = awardEntry{Qualifies: true, Value: n, DisplayValue: pluralize(n, "tag")}
		}
		if a.longestThread != nil && a.longestThread.CommentCount > 0 {
			c.LongestThread = awardEntry{
				Qualifies: true, Value: a.longestThread.CommentCount,
				DisplayValue: pluralize(a.longestThread.CommentCount, "comment"),
				PostID:       a.longestThread.PostID, MediaID: a.longestThread.MediaID,
			}
		}
		out = append(out, c)
	}
	return out, nil
}

// recapBody writes the caption a client too old to render panels ever sees - the entire
// value it gets from the feature, so it names what happened rather than nagging: "Your
// week in Ridgeway Family - 23 check-ins, 7 places, all 6 of you. Update Check-In to see
// the recap."
func recapBody(groupName string, stats RecapStats) string {
	who := fmt.Sprintf("%d of you", stats.Posters)
	if stats.Posters > 0 && stats.Posters == stats.Members {
		who = "all " + who
	}
	return fmt.Sprintf("Your recap in %s - %s, %s, %s. Update Check-In to see the recap.",
		groupName, pluralize(stats.Posts, "check-in"), pluralize(stats.Places, "place"), who)
}

// AdminUserID returns the group's admin, for attributing a scheduled recap post to
// someone (posts.author_id has no system-user escape hatch). When more than one admin
// exists, the lowest id - the founding admin - wins, so attribution is stable rather than
// arbitrary across ticks.
func (d *DB) AdminUserID(ctx context.Context) (int64, error) {
	var id int64
	err := d.Pool.QueryRow(ctx, `
		SELECT id FROM users WHERE is_admin = TRUE AND status = 'active' ORDER BY id LIMIT 1`,
	).Scan(&id)
	return id, err
}

// RecapExistsForPeriod is a cheap existence check the scheduler runs before the heavier
// BuildRecap work, so an hour's worth of ticks after the first successful one don't
// recompute a recap only to have CreateRecapPost's advisory lock discard it.
func (d *DB) RecapExistsForPeriod(ctx context.Context, cadence string, periodStart time.Time) (bool, error) {
	var exists bool
	err := d.Pool.QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM recaps WHERE cadence = $1 AND period_start = $2 AND origin = 'scheduled')`,
		cadence, periodStart).Scan(&exists)
	return exists, err
}

// TokensForAllActive returns every active member's device tokens, for the recap push -
// which has no opt-out yet (v1.5 adds NotifyPrefs.recap) and fires independently of each
// member's digest window.
func (d *DB) TokensForAllActive(ctx context.Context) ([]string, error) {
	return d.scanTokens(ctx, `
		SELECT dt.token FROM device_tokens dt JOIN users u ON u.id = dt.user_id
		WHERE u.status = 'active'`)
}

// FindManualRecap returns the post id of an existing manual recap for the exact same
// period and panel set, so the on-demand endpoint can offer to replace it instead of
// silently duplicating. panels must already be sorted (see sortedPanels) - the recaps
// table stores them that way so this comparison is order-independent.
func (d *DB) FindManualRecap(ctx context.Context, start, end time.Time, panels []string) (int64, bool, error) {
	var postID int64
	err := d.Pool.QueryRow(ctx, `
		SELECT post_id FROM recaps
		WHERE origin = 'manual' AND period_start = $1 AND period_end = $2 AND panels = $3
		ORDER BY created_at DESC LIMIT 1`, start, end, panels).Scan(&postID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return postID, true, nil
}

// CreateRecapPost writes a recap post (kind = 'recap', authored by the group admin, no
// media) and its recaps row in one transaction.
//
// A Postgres advisory lock, scoped to whatever makes a recap unique for its origin - see
// recapLockKey - serializes every concurrent attempt at the exact same recap: two
// scheduler ticks, two processes, or two identical on-demand requests landing at once. The
// existence check that decides whether to insert runs inside that same lock, in the same
// transaction as the insert - closing the gap a separate pre-check (FindManualRecap, or the
// scheduler's RecapExistsForPeriod) followed by a separate insert would otherwise leave
// open. The recaps table's partial unique index (scheduled origin only) is a hard backstop
// in case the lock is ever bypassed.
//
// inserted is false when a duplicate already exists and replacePostID is nil; conflictID
// is that existing post's id for a manual recap (0 for scheduled, which has no replace
// flow - the scheduler just skips). replacePostID, when non-nil, deletes that post first
// (its recaps row cascades) so a replace is delete-then-insert in one transaction, never a
// moment with both or neither. A replace never re-pushes - see the caller.
func (d *DB) CreateRecapPost(ctx context.Context, adminID int64, spec RecapSpec, payload RecapPayload, replacePostID *int64) (postID int64, inserted bool, conflictID int64, err error) {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return 0, false, 0, err
	}
	defer tx.Rollback(ctx)

	panels := sortedPanelTypes(payload.Panels)
	lockKey := recapLockKey(spec, panels)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, lockKey); err != nil {
		return 0, false, 0, err
	}

	if spec.Origin == "scheduled" {
		var exists bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS(SELECT 1 FROM recaps WHERE cadence = $1 AND period_start = $2 AND origin = 'scheduled')`,
			spec.Cadence, spec.PeriodStart).Scan(&exists); err != nil {
			return 0, false, 0, err
		}
		if exists {
			return 0, false, 0, nil
		}
	} else {
		var existingID int64
		err := tx.QueryRow(ctx, `
			SELECT post_id FROM recaps
			WHERE origin = 'manual' AND period_start = $1 AND period_end = $2 AND panels = $3
			ORDER BY created_at DESC LIMIT 1`, spec.PeriodStart, spec.PeriodEnd, panels).Scan(&existingID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return 0, false, 0, err
		}
		if err == nil && replacePostID == nil {
			return 0, false, existingID, nil
		}
	}

	if replacePostID != nil {
		if _, err := tx.Exec(ctx, `DELETE FROM posts WHERE id = $1`, *replacePostID); err != nil {
			return 0, false, 0, err
		}
	}

	body := recapBody(payload.Group.Name, payload.Stats)
	if err := tx.QueryRow(ctx, `
		INSERT INTO posts (author_id, kind, body) VALUES ($1, 'recap', $2)
		RETURNING id`, adminID, body).Scan(&postID); err != nil {
		return 0, false, 0, err
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return 0, false, 0, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO recaps (post_id, cadence, origin, period_start, period_end, panels, payload)
		VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		postID, spec.Cadence, spec.Origin, spec.PeriodStart, spec.PeriodEnd, panels, payloadJSON); err != nil {
		return 0, false, 0, err
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, false, 0, err
	}
	return postID, true, 0, nil
}

// recapLockKey scopes CreateRecapPost's advisory lock to what makes a recap unique for its
// origin: (cadence, periodStart) for a scheduled recap - panels never vary for it, see
// recapV1Panels - or (periodStart, periodEnd, panels) for a manual one, matching
// FindManualRecap's own uniqueness criteria exactly, so both take the same lock for the
// same recap.
func recapLockKey(spec RecapSpec, sortedPanels []string) string {
	if spec.Origin == "scheduled" {
		return fmt.Sprintf("recap:scheduled:%s:%s", spec.Cadence, spec.PeriodStart.UTC().Format(time.RFC3339))
	}
	return fmt.Sprintf("recap:manual:%s:%s:%s",
		spec.PeriodStart.UTC().Format(time.RFC3339),
		spec.PeriodEnd.UTC().Format(time.RFC3339),
		strings.Join(sortedPanels, ","))
}

// sortedPanelTypes extracts and sorts a payload's panel types, for storage in recaps.panels
// - keeping it order-independent is what lets FindManualRecap compare "same panels" as a
// set rather than caring which order they were requested in.
func sortedPanelTypes(panels []RecapPanel) []string {
	out := make([]string, len(panels))
	for i, p := range panels {
		out[i] = p.Type
	}
	sort.Strings(out)
	return out
}
