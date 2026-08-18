package db

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// memoryRecencyFloor is the minimum age a post must have to surface as a random memory. The
// whole point of "Random Memory" is looking back - a check-in from three days ago is just
// this week's feed, not a memory yet, so anything younger than this is excluded regardless
// of how little history the group has.
const memoryRecencyFloor = 14 * 24 * time.Hour

// RandomMemory returns one uniformly-random eligible post from the group's history, or
// ok=false when nothing qualifies (a brand-new group, or one where everything eligible has
// since been blocked or removed) - the caller renders that as an honest empty state, not an
// error.
//
// Eligible: active author, not blocked by viewer, kind <> 'recap' (a recap is a summary of a
// period, not a memory of a moment), and older than memoryRecencyFloor.
//
// Selection is ORDER BY random() LIMIT 1 over the filtered set: one statement per attempt,
// no id list ever loaded into Go. That is O(eligible rows) of work inside Postgres per call,
// which is the right tradeoff for a friend group's post table (dozens to low thousands of
// rows) - it is deliberately not the right tradeoff once a table is large enough that a full
// scan for one random row gets expensive, at which point this would need to move to sampling
// (e.g. TABLESAMPLE, or picking a random offset against a maintained eligible-row count)
// instead.
//
// Two attempts, not one: the first is restricted to posts carrying media, and only falls
// through to every eligible post (including text-only) when that pool is empty. That is what
// gives media priority without ever returning nothing when the group's history is text-only.
func (d *DB) RandomMemory(ctx context.Context, viewerID int64) (Post, bool, error) {
	p, ok, err := d.randomMemoryFrom(ctx, viewerID, true)
	if err != nil || ok {
		return p, ok, err
	}
	return d.randomMemoryFrom(ctx, viewerID, false)
}

func (d *DB) randomMemoryFrom(ctx context.Context, viewerID int64, requireMedia bool) (Post, bool, error) {
	var p Post
	var preview, media, people, recap []byte
	floor := time.Now().Add(-memoryRecencyFloor)
	err := d.Pool.QueryRow(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at, p.cross_post_id, p.lat, p.lng,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
		        AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
		        AND c.cross_comment_id IS NOT NULL
		        AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+postPeopleExpr+recapExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE u.status = 'active'
		  AND p.kind <> 'recap'
		  AND p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)
		  AND p.created_at < $2
		  AND ($3::bool = FALSE OR EXISTS (SELECT 1 FROM post_media pm WHERE pm.post_id = p.id))
		ORDER BY random()
		LIMIT 1`,
		viewerID, floor, requireMedia,
	).Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt, &p.CrossPostID, &p.Lat, &p.Lng,
		&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.SharedCommentCount, &p.LikedByViewer, &preview, &media, &people, &recap)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, false, nil
	}
	if err != nil {
		return p, false, err
	}
	if len(preview) > 0 {
		_ = json.Unmarshal(preview, &p.CommentsPreview)
	}
	if len(people) > 0 {
		_ = json.Unmarshal(people, &p.People)
	}
	p.applyMedia(media)
	p.applyRecap(recap)
	return p, true, nil
}
