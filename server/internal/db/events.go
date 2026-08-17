package db

import (
	"context"
	"time"
)

// defaultEventsLimit is what GET /api/memories/events returns when the caller doesn't ask
// for a specific count; maxEventsLimit is the hard ceiling regardless of what's requested,
// so a client can't force this endpoint into scanning and clustering a group's entire
// history in one request.
const (
	defaultEventsLimit = 20
	maxEventsLimit     = 50
)

// EventsForViewer detects "You Were There" group events for the viewer's group: vacations
// and gatherings reconstructed from clusters of check-ins at the same place by two or more
// distinct authors - see detectEvents for the whole algorithm, which this only fetches
// rows for and calls.
//
// Eligible posts: active author, not blocked by the viewer, kind <> 'recap', and carrying
// a location - the same predicate RandomMemory and the feed already use (see this
// package's memories.go and queries.go), plus the location requirement an event needs to
// exist at all. Fetches every eligible row rather than paging: this is the same tradeoff
// RandomMemory's own doc comment already makes for a friend group's post table (dozens to
// low thousands of rows) - the right one here too, and not the right one once a table is
// large enough that a full scan gets expensive, at which point this would need to move to
// a narrower lookback window or a materialized rollup instead.
func (d *DB) EventsForViewer(ctx context.Context, viewerID int64, limit int) ([]Event, error) {
	if limit <= 0 {
		limit = defaultEventsLimit
	}
	if limit > maxEventsLimit {
		limit = maxEventsLimit
	}

	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, u.name, u.profile_media_id, p.location, p.created_at,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM post_media pm JOIN media m ON m.id = pm.media_id
		          WHERE pm.post_id = p.id AND m.mime LIKE 'image/%'),
		       (SELECT pm.media_id FROM post_media pm JOIN media m ON m.id = pm.media_id
		          WHERE pm.post_id = p.id AND m.mime LIKE 'image/%'
		          ORDER BY pm.position LIMIT 1)
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE u.status = 'active'
		  AND p.kind <> 'recap'
		  AND p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)
		  AND p.location IS NOT NULL AND p.location <> ''
		ORDER BY p.created_at ASC`,
		viewerID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var eligible []eventPostRow
	for rows.Next() {
		var r eventPostRow
		if err := rows.Scan(&r.PostID, &r.AuthorID, &r.AuthorName, &r.AuthorPhotoID,
			&r.Location, &r.CreatedAt, &r.LikeCount, &r.PhotoCount, &r.CoverMediaID); err != nil {
			return nil, err
		}
		eligible = append(eligible, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	events := detectEvents(eligible, time.Now())
	if len(events) > limit {
		events = events[:limit]
	}
	return events, nil
}
