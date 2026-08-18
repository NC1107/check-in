package db

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// forgottenAgeFloor is the minimum age a post must have to ever be considered "forgotten".
// RandomMemory's 14-day floor exists only to keep this week's feed out of "look back" - it
// says nothing about neglect. "Forgotten" is a stronger claim: the founder's brief is once-a-
// month surfacing of things nobody has revisited in a long time, so the floor has to read as
// genuinely old, not merely "not brand new". 90 days (about three months) is picked as that
// line: short enough that even a young, active group reaches it within its first season, long
// enough that it can't be mistaken for last month's catch-up browsing. It is deliberately
// ~6.4x RandomMemory's own floor rather than some small multiple of it - the two features are
// answering different questions ("something from our history" vs. "something we've actually
// stopped looking at") and sharing a floor would blur that distinction away.
const forgottenAgeFloor = 90 * 24 * time.Hour

// forgottenEngagementCeiling is the most total engagement (likes plus non-blocked comments) a
// post may carry and still count as forgotten. Zero-only was considered and rejected: a small
// group (a handful of members, the common case for a self-hosted install) can easily have a
// photo that caught exactly one stray like from one friend scrolling past, and that photo is
// still, in every meaningful sense, a thing nobody has actually revisited - the founder's own
// framing is "nobody has interacted with in a long time", not "literally zero interactions
// ever". Requiring strict zero would systematically exclude a group's most common case of
// neglect (a little, long-forgotten attention) and only ever surface posts that got no
// attention at all, which is a narrower and less interesting pool than the feature intends.
// 2 is chosen as a ceiling that still reads as "basically ignored" for any group size: even a
// tiny group's "everybody liked this" looks nothing like 1-2 total touches, so this can't
// accidentally let a genuinely popular check-in back in.
const forgottenEngagementCeiling = 2

// forgottenCandidateWindow bounds how many of the qualifying pool's least-engaged, oldest rows
// ForgottenPhoto shuffles across for its final pick - see the function's own doc comment for
// why the shuffle is deliberately narrowed to this shortlist rather than applied across the
// whole qualifying set the way RandomMemory's is.
const forgottenCandidateWindow = 20

// forgottenPhotoEligible is the qualifying rule for a "forgotten photo" as a plain function of
// a candidate's own facts, independent of SQL: it must carry media, be older than
// forgottenAgeFloor, and carry no more than forgottenEngagementCeiling combined likes and
// comments. ForgottenPhoto's query applies exactly this rule as a WHERE clause (has-media via
// EXISTS on post_media, age via created_at < floor, engagement via the summed likes+comments
// subquery) - this function exists so the rule itself is pinned and exercised directly in a
// unit test, without standing up Postgres for every edge case (the floor's exact boundary, the
// ceiling's exact boundary, a media-less post that is otherwise perfectly qualified).
func forgottenPhotoEligible(hasMedia bool, createdAt, now time.Time, likeCount, commentCount int) bool {
	if !hasMedia {
		return false
	}
	// <=, not <: the SQL's own age check is `p.created_at < floor` (floor = now - the age
	// floor), which excludes a post sitting exactly on the boundary just as strictly - so a
	// post whose age reads as precisely forgottenAgeFloor is one tick shy of old enough in
	// both places, not a coin flip between them.
	if now.Sub(createdAt) <= forgottenAgeFloor {
		return false
	}
	return likeCount+commentCount <= forgottenEngagementCeiling
}

// ForgottenPhoto returns one eligible "forgotten photo" from the group's history, or ok=false
// when nothing qualifies (a young group, or one where every old, quiet post has since been
// blocked, removed, or - now that someone finally noticed it - liked back into popularity) -
// the caller renders that as an honest empty state, not an error, the same contract
// RandomMemory already gives the client for its own empty case.
//
// Eligible: the same author/block/kind predicate RandomMemory, EventsForViewer and Timeline
// already share (active author, not blocked by the viewer, kind <> 'recap' - see this
// package's memories.go for why that trio is the shared baseline every Memories-surface query
// reuses rather than re-derives), plus three more specific to what "forgotten" means here (see
// forgottenAgeFloor, forgottenEngagementCeiling, and forgottenPhotoEligible's own doc comments
// for what each is and why):
//   - carries at least one attachment (post_media row) - this is "forgotten PHOTOS", not
//     forgotten text, so a caption-only post never qualifies regardless of age or engagement;
//   - older than forgottenAgeFloor;
//   - total engagement (likes plus comments from authors the viewer hasn't blocked) at or
//     under forgottenEngagementCeiling.
//
// SELECTION: prefer least-engaged and oldest, but not deterministically - a member mashing
// "Another" every month for a year must not always land on the exact same photo forever. The
// query is two stages: a `shortlist` CTE first ranks the whole qualifying pool by
// (engagement ASC, created_at ASC) and takes the top forgottenCandidateWindow - literally the
// most-forgotten rows that exist - then the outer query does ORDER BY random() LIMIT 1 across
// just that shortlist. This deliberately differs from RandomMemory's own ORDER BY random(),
// which shuffles the ENTIRE eligible pool with no preference at all: doing that here would
// directly contradict "prefer least-engaged and oldest" - a group with a thousand quietly-
// eligible posts and one truly neglected outlier would surface the outlier only 1-in-1000 of
// the time, which does not read as "forgotten" to the person tapping "Another". Narrowing to a
// bounded shortlist first, then shuffling only within it, is what lets both halves of the
// brief hold at once: every result the shortlist could produce is genuinely among the most
// forgotten in the group, and repeated calls still vary rather than pinning to one photo
// forever.
//
// COST: the `candidates` CTE scans every row matching the base eligibility predicate to
// compute its engagement sum - the same O(eligible rows) tradeoff RandomMemory's own doc
// comment already makes, and the right one for the same reason: a friend group's post table is
// dozens to low thousands of rows, not a workload this needs to defend against at scale. It
// stops being the right tradeoff at the same point RandomMemory's comment already names - a
// table large enough that a full scan for one call gets expensive - and would need the same
// remedy (a maintained rollup of engagement/eligibility, rather than recomputing it live on
// every read).
func (d *DB) ForgottenPhoto(ctx context.Context, viewerID int64) (Post, bool, error) {
	var p Post
	var preview, media, people, recap []byte
	floor := time.Now().Add(-forgottenAgeFloor)
	err := d.Pool.QueryRow(ctx, `
		WITH candidates AS (
			SELECT p.id, p.created_at,
			       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) +
			       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
			          AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)) AS engagement
			FROM posts p
			JOIN users u ON u.id = p.author_id
			WHERE u.status = 'active'
			  AND p.kind <> 'recap'
			  AND p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)
			  AND p.created_at < $2
			  AND EXISTS (SELECT 1 FROM post_media pm WHERE pm.post_id = p.id)
		), shortlist AS (
			SELECT id FROM candidates
			WHERE engagement <= $3
			ORDER BY engagement ASC, created_at ASC
			LIMIT $4
		)
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
		JOIN shortlist s ON s.id = p.id
		ORDER BY random()
		LIMIT 1`,
		viewerID, floor, forgottenEngagementCeiling, forgottenCandidateWindow,
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
