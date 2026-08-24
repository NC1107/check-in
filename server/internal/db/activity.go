package db

// The activity log is what happened *about you*: comments on your check-ins, replies to
// your comments, and likes on your check-ins. It is derived from the rows that already
// exist rather than written to a table of its own at notify time.
//
// That choice is what makes it useful the day it ships - a member's whole history is
// already there - and it removes a second source of truth that could drift: a deleted post
// takes its activity with it through the foreign keys, with no orphan row left describing
// something that is no longer there.
//
// The three branches deliberately mirror the three push queries in queries.go
// (TokensForReply, TokensForCommentReply, TokensForLike) predicate for predicate, so this
// list is by construction "everything that would have been pushed to me". Two differences
// are intentional:
//
//   - The notify_replies / notify_likes opt-outs are NOT applied. Muting likes should stop
//     the buzzing, not erase likes from your own history.
//   - The digest_enabled branch is not applied either, for the same reason.
//
// What is kept is the visibility rule every viewer-facing query here uses: the actor must
// still be active, and must not be someone the viewer has blocked (see PostVisible).

import (
	"context"
	"strconv"
	"strings"
	"time"
)

// Activity kinds, as sent to the app. A "comment" is on your check-in; a "reply" is on your
// comment. They are separate because they read differently and because a reply carries you
// to a different place in the thread.
const (
	ActivityComment = "comment"
	ActivityReply   = "reply"
	ActivityLike    = "like"
)

// ActivityItem is one line of the activity list.
type ActivityItem struct {
	Kind   string `json:"kind"`
	PostID int64  `json:"postId"`

	// CommentID is the comment this item is about, so a tap can land on that comment rather
	// than the top of the thread. Absent on a like, which is about the post itself.
	CommentID *int64 `json:"commentId,omitempty"`

	ActorID      int64  `json:"actorId"`
	ActorName    string `json:"actorName"`
	ActorPhotoID *int64 `json:"actorPhotoId,omitempty"`

	// Preview is the comment's text, or "GIF" for a gif-only comment - the same fallback
	// Comment.PreviewBody applies. Empty for a like.
	Preview string `json:"preview,omitempty"`

	CreatedAt time.Time `json:"createdAt"`
}

// ActivityQuery is one page of a member's activity. A struct rather than a parameter list
// for the same reason FeedQuery is one: the fields are easy to transpose at a call site.
type ActivityQuery struct {
	ViewerID int64

	// Cursor is the position to continue from, taken verbatim from a previous page's
	// NextCursor. Empty for the first page. Opaque on purpose: what makes a position unique
	// here took two attempts to get right, and the app should not have to be told.
	Cursor string

	Limit int
}

// ActivityCursor is one item's position in the list.
//
// All three parts are needed. Time alone is not unique: a comment and a like can land in the
// same instant. Time plus the row id is not unique either, and that is the trap - comments
// and likes have separate identity sequences, so the first comment and the first like are
// BOTH row 1, and two items that tie on time can tie on id as well. Adding the kind is what
// makes the ordering total, because within one kind the row id is unique.
//
// A total order matters because without it Postgres may put tied rows either way round on
// the two sides of a page boundary, which silently drops one item and repeats another.
type ActivityCursor struct {
	CreatedAt time.Time
	Kind      string
	SourceID  int64
}

// String renders a cursor for the wire. The separator is safe because Kind is one of three
// literals this package writes, never anything a client supplied.
func (c ActivityCursor) String() string {
	return c.CreatedAt.UTC().Format(time.RFC3339Nano) + "|" + c.Kind + "|" +
		strconv.FormatInt(c.SourceID, 10)
}

// ParseActivityCursor reads a cursor back. A malformed one yields ok=false, and callers
// treat that as "start from the beginning" rather than as an error: a stale or hand-edited
// cursor should show the newest activity, not fail the request.
func ParseActivityCursor(raw string) (ActivityCursor, bool) {
	parts := strings.Split(raw, "|")
	if len(parts) != 3 {
		return ActivityCursor{}, false
	}
	at, err := time.Parse(time.RFC3339Nano, parts[0])
	if err != nil {
		return ActivityCursor{}, false
	}
	id, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return ActivityCursor{}, false
	}
	return ActivityCursor{CreatedAt: at, Kind: parts[1], SourceID: id}, true
}

// activityItemsCTE is the derived list, shared verbatim by the page query and the unread
// count so the two can never disagree about what counts as activity. $1 is the viewer.
//
// source_id is the underlying comments/likes row id. It is not sent to the app; it exists
// so the ordering is total. Two items can share a created_at (a like and a comment landing
// in the same instant), and without a tiebreak Postgres is free to order them either way,
// which would let a page boundary drop one item and repeat another.
const activityItemsCTE = `
	items AS (
		-- Someone commented on my check-in. Mirrors TokensForReply.
		SELECT 'comment' AS kind, c.post_id, c.id AS comment_id, c.id AS source_id,
		       c.user_id AS actor_id, u.name AS actor_name, u.profile_media_id,
		       c.body, c.media_id, c.created_at
		FROM comments c
		JOIN posts p ON p.id = c.post_id
		JOIN users u ON u.id = c.user_id
		WHERE p.author_id = $1 AND c.user_id <> $1 AND u.status = 'active'
		  AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)

		UNION ALL

		-- Someone replied to my comment. Mirrors TokensForCommentReply, including its
		-- p.author_id <> $1: a reply to my comment on my OWN check-in is already covered by
		-- the branch above, and listing it twice is exactly the double-buzz that query
		-- exists to avoid.
		SELECT 'reply', c.post_id, c.id, c.id,
		       c.user_id, u.name, u.profile_media_id,
		       c.body, c.media_id, c.created_at
		FROM comments c
		JOIN comments pc ON pc.id = c.parent_comment_id
		JOIN posts p ON p.id = c.post_id
		JOIN users u ON u.id = c.user_id
		WHERE pc.user_id = $1 AND c.user_id <> $1 AND p.author_id <> $1
		  AND u.status = 'active'
		  AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)

		UNION ALL

		-- Someone liked my check-in. Mirrors TokensForLike. A like is about the post, so it
		-- carries no comment id and nothing to preview.
		SELECT 'like', l.post_id, NULL::bigint, l.id,
		       l.user_id, u.name, u.profile_media_id,
		       ''::text, NULL::bigint, l.created_at
		FROM likes l
		JOIN posts p ON p.id = l.post_id
		JOIN users u ON u.id = l.user_id
		WHERE p.author_id = $1 AND l.user_id <> $1 AND u.status = 'active'
		  AND l.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)
	)`

// activityMaxLimit bounds one page however large a client asks for, so a hand-made request
// cannot ask the server to materialise an entire group's history in one response.
const activityMaxLimit = 100

// Activity returns one page of the viewer's activity, newest first, and the cursor to
// continue from. The cursor is empty when the page reached the end of the list.
//
// The row-wise comparison against the cursor is what pairs with the ORDER BY: comparing the
// whole (created_at, kind, source_id) tuple at once is exactly "everything that sorts after
// this item", which a chain of ORs on the same three columns gets wrong in ways that only
// show up on a tie.
func (d *DB) Activity(ctx context.Context, q ActivityQuery) ([]ActivityItem, string, error) {
	limit := q.Limit
	if limit <= 0 || limit > activityMaxLimit {
		limit = activityMaxLimit
	}
	var (
		at   *time.Time
		kind string
		id   int64
	)
	if c, ok := ParseActivityCursor(q.Cursor); ok {
		at, kind, id = &c.CreatedAt, c.Kind, c.SourceID
	}
	rows, err := d.Pool.Query(ctx, `
		WITH`+activityItemsCTE+`
		SELECT kind, post_id, comment_id, source_id, actor_id, actor_name, profile_media_id,
		       body, media_id, created_at
		FROM items
		WHERE $2::timestamptz IS NULL
		   OR (created_at, kind, source_id) < ($2, $3::text, $4::bigint)
		ORDER BY created_at DESC, kind DESC, source_id DESC
		LIMIT $5`, q.ViewerID, at, kind, id, limit)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()

	var (
		items []ActivityItem
		next  ActivityCursor
	)
	for rows.Next() {
		var (
			it       ActivityItem
			sourceID int64
			body     string
			mediaID  *int64
		)
		if err := rows.Scan(&it.Kind, &it.PostID, &it.CommentID, &sourceID, &it.ActorID,
			&it.ActorName, &it.ActorPhotoID, &body, &mediaID, &it.CreatedAt); err != nil {
			return nil, "", err
		}
		it.Preview = activityPreview(it.Kind, body, mediaID)
		items = append(items, it)
		next = ActivityCursor{CreatedAt: it.CreatedAt, Kind: it.Kind, SourceID: sourceID}
	}
	if err := rows.Err(); err != nil {
		return nil, "", err
	}
	// A short page is the end of the list. Handing back a cursor there would have the app
	// make one more request that can only ever come back empty.
	if len(items) < limit {
		return items, "", nil
	}
	return items, next.String(), nil
}

// activityPreview is the line of content shown under an activity row: the comment's text,
// or "GIF" when a gif-only comment has no text to show. A like has no content of its own.
func activityPreview(kind, body string, mediaID *int64) string {
	if kind == ActivityLike {
		return ""
	}
	if body == "" && mediaID != nil {
		return "GIF"
	}
	return body
}

// UnreadActivity counts the items the viewer has not seen: everything newer than the marker
// their last visit to the activity list left behind.
func (d *DB) UnreadActivity(ctx context.Context, viewerID int64) (int, error) {
	var n int
	err := d.Pool.QueryRow(ctx, `
		WITH`+activityItemsCTE+`
		SELECT count(*) FROM items
		WHERE created_at > (SELECT activity_seen_at FROM users WHERE id = $1)`,
		viewerID).Scan(&n)
	return n, err
}

// MarkActivitySeen moves the viewer's marker to now, clearing their unread count.
//
// The marker cannot move backwards, and does not need a guard saying so: it is only ever set
// to the server's own now(), never to a timestamp a client supplied, so two devices reporting
// a visit out of order still both write a time later than whatever was there.
func (d *DB) MarkActivitySeen(ctx context.Context, viewerID int64) error {
	_, err := d.Pool.Exec(ctx,
		`UPDATE users SET activity_seen_at = now() WHERE id = $1`, viewerID)
	return err
}
