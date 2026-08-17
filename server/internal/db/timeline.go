package db

import (
	"context"
	"encoding/json"
	"sort"
	"time"
)

// maxTimelineMonthPosts bounds how many posts GET /api/memories/timeline/{year}/{month}
// returns for one month, newest first. Sized well above what a single month of an active
// friend group produces (a check-in a day per member, times a dozen members, is still
// under 400/month) while keeping the query and the response bounded regardless of how much
// history a group has piled into one calendar month.
const maxTimelineMonthPosts = 200

// timelineCoverCap is how many cover photos each month in the list carries - a strip, not
// a gallery. See Timeline's own doc comment for how they're picked.
const timelineCoverCap = 5

// TimelineMonth is one month of a group's history for the "Your months" browse: how much
// happened, and a handful of its best photos. Months with nothing eligible in them are
// never returned (see Timeline) - the client never has to render a zeroed card.
type TimelineMonth struct {
	Year  int `json:"year"`
	Month int `json:"month"` // 1-12

	PostCount  int `json:"postCount"`
	PhotoCount int `json:"photoCount"`
	ClipCount  int `json:"clipCount"`

	// PlaceCount is the number of distinct non-empty location strings posted this month -
	// the plain, unfolded string a post carries. Unlike the events feature's
	// normalizeLocation, this is a simple "how many different places" count for a stat
	// line, not a clustering key that has to survive OS/locale formatting differences.
	PlaceCount int `json:"placeCount"`

	// PosterCount is the number of distinct authors who posted this month.
	PosterCount int `json:"posterCount"`

	// CoverMediaIDs is up to timelineCoverCap of the month's most-liked photos (a post with
	// no image never contributes one), most-liked first, ties broken toward the earlier
	// post id for a deterministic pick - the same tiebreak buildEvent's own cover selection
	// (events_cluster.go) uses. A cover id can point at media whose post has since been
	// deleted by the time the client renders it; that's the client's own problem to degrade
	// around (a broken-image placeholder), not something recomputed here on every read.
	CoverMediaIDs []int64 `json:"coverMediaIds"`
}

// timelinePostRow is one eligible post considered for the timeline, already filtered to the
// same eligibility RandomMemory and EventsForViewer use (active author, not blocked by the
// viewer, kind <> 'recap') - see Timeline's own doc comment for why there is deliberately no
// recency floor here, unlike RandomMemory's.
type timelinePostRow struct {
	PostID       int64
	AuthorID     int64
	Location     string
	CreatedAt    time.Time
	PhotoCount   int
	ClipCount    int
	LikeCount    int
	CoverMediaID *int64
}

// Timeline returns the group's history bucketed into calendar months, newest first - "the
// group's life, month by month". Eligible posts are exactly what RandomMemory and
// EventsForViewer already use (active author, not blocked by the viewer, kind <> 'recap'),
// with NO recency floor: unlike a "memory", which only means something once it's aged a
// couple of weeks, the current month legitimately belongs on its own timeline as it happens.
//
// MONTH BUCKETING: a post's month is its created_at converted to the server PROCESS's own
// local time zone (time.Local), not raw UTC. Go resolves time.Local exactly once, at
// startup, from the standard TZ environment variable (falling back to /etc/localtime) - the
// same mechanism docker-compose.yml's server service already relies on implicitly for its
// own logs. Without this, a check-in made at 9pm local on the 31st could land in the
// UTC calendar's next month, which is not the month a member who was there would recognize
// it as. This is a simpler, server-wide notion of "local" than recap.go's own monthly
// cadence (which honors a per-group admin-configured offset for scheduling a digest send
// at a specific wall-clock hour) - deliberately so, since a timeline has no per-viewer or
// per-group "local" to honor, only "what month did this actually happen in".
//
// One query, not one per month: every eligible row is fetched in a single statement (the
// same tradeoff RandomMemory's and EventsForViewer's own doc comments make - right-sized
// for a friend group's post table, dozens to low thousands of rows) and the whole bucket/
// rank/cover-pick pipeline runs over it in Go (see bucketTimeline), so it's directly
// unit-testable without a database. That stops being the right tradeoff once a group's full
// history is large enough that re-scanning every eligible post on every open of "Your
// months" gets expensive - at that point this would need a maintained per-month rollup
// table instead of a live aggregation.
func (d *DB) Timeline(ctx context.Context, viewerID int64) ([]TimelineMonth, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, COALESCE(p.location, ''), p.created_at,
		       (SELECT count(*) FROM post_media pm JOIN media m ON m.id = pm.media_id
		          WHERE pm.post_id = p.id AND m.mime LIKE 'image/%'),
		       (SELECT count(*) FROM post_media pm JOIN media m ON m.id = pm.media_id
		          WHERE pm.post_id = p.id AND m.mime LIKE 'video/%'),
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT pm.media_id FROM post_media pm JOIN media m ON m.id = pm.media_id
		          WHERE pm.post_id = p.id AND m.mime LIKE 'image/%'
		          ORDER BY pm.position LIMIT 1)
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE u.status = 'active'
		  AND p.kind <> 'recap'
		  AND p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)
		ORDER BY p.created_at ASC`,
		viewerID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var eligible []timelinePostRow
	for rows.Next() {
		var r timelinePostRow
		if err := rows.Scan(&r.PostID, &r.AuthorID, &r.Location, &r.CreatedAt,
			&r.PhotoCount, &r.ClipCount, &r.LikeCount, &r.CoverMediaID); err != nil {
			return nil, err
		}
		eligible = append(eligible, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	return bucketTimeline(eligible), nil
}

// timelineKey is a calendar (year, month) bucket in the server's local time zone (see
// Timeline's own doc comment).
type timelineKey struct {
	year  int
	month int
}

// bucketTimeline groups eligible rows into calendar months and computes each month's stats
// and cover picks. A pure function of the fetched rows, so the bucketing rule itself is
// directly unit-testable without a database - the same reasoning detectEvents' own doc
// comment gives for events. Months are omitted entirely when nothing landed in them (there
// is nothing to omit-with-zeroes: a map only ever gains an entry when a row lands in it).
func bucketTimeline(rows []timelinePostRow) []TimelineMonth {
	buckets := make(map[timelineKey][]timelinePostRow, 12)
	for _, r := range rows {
		local := r.CreatedAt.In(time.Local)
		k := timelineKey{year: local.Year(), month: int(local.Month())}
		buckets[k] = append(buckets[k], r)
	}

	months := make([]TimelineMonth, 0, len(buckets))
	for k, run := range buckets {
		months = append(months, buildTimelineMonth(k, run))
	}
	sort.Slice(months, func(i, j int) bool {
		if months[i].Year != months[j].Year {
			return months[i].Year > months[j].Year
		}
		return months[i].Month > months[j].Month
	})
	return months
}

// buildTimelineMonth computes one month's stats and cover picks from its posts.
func buildTimelineMonth(k timelineKey, run []timelinePostRow) TimelineMonth {
	places := make(map[string]bool)
	posters := make(map[int64]bool)
	photoCount, clipCount := 0, 0

	type cover struct {
		mediaID   int64
		likeCount int
		postID    int64
	}
	var covers []cover

	for _, r := range run {
		photoCount += r.PhotoCount
		clipCount += r.ClipCount
		posters[r.AuthorID] = true
		if r.Location != "" {
			places[r.Location] = true
		}
		if r.CoverMediaID != nil {
			covers = append(covers, cover{mediaID: *r.CoverMediaID, likeCount: r.LikeCount, postID: r.PostID})
		}
	}

	sort.Slice(covers, func(i, j int) bool {
		if covers[i].likeCount != covers[j].likeCount {
			return covers[i].likeCount > covers[j].likeCount
		}
		return covers[i].postID < covers[j].postID
	})
	if len(covers) > timelineCoverCap {
		covers = covers[:timelineCoverCap]
	}
	coverIDs := make([]int64, len(covers))
	for i, c := range covers {
		coverIDs[i] = c.mediaID
	}

	return TimelineMonth{
		Year:          k.year,
		Month:         k.month,
		PostCount:     len(run),
		PhotoCount:    photoCount,
		ClipCount:     clipCount,
		PlaceCount:    len(places),
		PosterCount:   len(posters),
		CoverMediaIDs: coverIDs,
	}
}

// TimelineMonthPosts returns one calendar month's eligible posts, newest first, serialized
// exactly like a feed post (reuses the same column list and shared SELECT fragments as
// Feed/GetPost/RandomMemory in queries.go) - the client's Post model needs no special case
// for where these came from. Capped at maxTimelineMonthPosts.
//
// year/month are trusted to already be a valid calendar month - the api package's
// validTimelineMonth rejects anything else (non-numeric, month outside 1-12, an absurd
// year) before a request ever reaches this far, so a bad pair here would just mean a
// caller bypassed that guard, not a scan this function needs to defend against itself.
//
// Bucketing uses the same server-local month boundaries as Timeline (see its doc comment
// for the time-zone convention): [start, end) is computed against time.Local, then compared
// as an absolute instant (timestamptz vs. timestamptz), so the boundary is correct
// regardless of the database session's own time zone setting.
func (d *DB) TimelineMonthPosts(ctx context.Context, viewerID int64, year, month int) ([]Post, error) {
	start := time.Date(year, time.Month(month), 1, 0, 0, 0, 0, time.Local)
	end := start.AddDate(0, 1, 0)

	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at, p.cross_post_id, p.lat, p.lng,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
		        AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+postPeopleExpr+recapExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE u.status = 'active'
		  AND p.kind <> 'recap'
		  AND p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)
		  AND p.created_at >= $2 AND p.created_at < $3
		ORDER BY p.created_at DESC, p.id DESC
		LIMIT $4`,
		viewerID, start, end, maxTimelineMonthPosts,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var posts []Post
	for rows.Next() {
		var p Post
		var preview, media, people, recap []byte
		if err := rows.Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt, &p.CrossPostID, &p.Lat, &p.Lng,
			&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview, &media, &people, &recap); err != nil {
			return nil, err
		}
		if len(preview) > 0 {
			_ = json.Unmarshal(preview, &p.CommentsPreview)
		}
		if len(people) > 0 {
			_ = json.Unmarshal(people, &p.People)
		}
		p.applyMedia(media)
		p.applyRecap(recap)
		posts = append(posts, p)
	}
	return posts, rows.Err()
}
