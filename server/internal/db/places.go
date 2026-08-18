package db

import (
	"context"
	"encoding/json"
	"sort"
	"time"

	"github.com/nc1107/check-in/server/internal/gazetteer"
)

// Place is one distinct location across a group's eligible check-ins - display string,
// resolved coordinates, aggregate stats, and whether it reads as the group's own home
// area - for the Memories hub's "Places" entry. See PlacesForViewer for the underlying
// eligibility and aggregation, and gazetteer.Resolve for what "resolved" means and why
// most of a group's early history will legitimately carry nil Lat/Lng: coordinate capture
// only shipped alongside this feature, so no post older than today carries a stored
// lat/lng of its own, and the offline gazetteer only ever covers real GeoNames rows,
// never a guess.
type Place struct {
	Location string `json:"location"`

	// Lat/Lng are nil when gazetteer.Resolve couldn't turn Location into coordinates -
	// too small a place for the embedded dataset's population/capital-status bar, an
	// unrecognised country name, or a malformed string. A place with nil coordinates
	// still belongs in the list (see PlacesForViewer's own doc comment) - it just can't
	// be plotted once a map view exists.
	Lat *float64 `json:"lat"`
	Lng *float64 `json:"lng"`

	PostCount   int `json:"postCount"`
	PhotoCount  int `json:"photoCount"`
	PosterCount int `json:"posterCount"`

	FirstSeen time.Time `json:"firstSeen"`
	LastSeen  time.Time `json:"lastSeen"`

	// CoverMediaID is the most-liked photo posted at this place (ties broken toward the
	// earlier post id - the same convention buildEvent's own cover pick uses, see
	// events_cluster.go), or nil when nothing at this place carries a photo at all.
	CoverMediaID *int64 `json:"coverMediaId,omitempty"`

	// HomeArea is true when this place is part of the group's own collective home
	// turf - see computeHomeArea (events_cluster.go), reused here rather than
	// re-derived, so "home" never means two different things depending on which
	// Memories view is asking.
	HomeArea bool `json:"homeArea"`
}

// PlacesForViewer returns every distinct location across the viewer's eligible
// check-ins, most-check-ins-first (see buildPlaces for the ranking rule), resolving each
// to coordinates via the embedded gazetteer where possible.
//
// Eligible posts: the same predicate RandomMemory, EventsForViewer and Timeline already
// share (active author, not blocked by the viewer, kind <> 'recap'), plus the location
// requirement EventsForViewer also applies - a place with no location can't be a place.
//
// A place this dataset can't resolve to coordinates (see gazetteer.Resolve) is still
// returned, with Lat/Lng nil - dropping it, or worse, guessing at coordinates, would be
// actively worse than an honest "we don't know where this is" the client can render:
// resolution coverage only ever improves as the embedded dataset is updated, and a
// silently-dropped place would just vanish from the list rather than reappearing once it
// does.
//
// One query, not one per place: every eligible, location-bearing row is fetched in a
// single statement (the same tradeoff RandomMemory's, Timeline's and EventsForViewer's own
// doc comments already make for a friend group's post table - dozens to low thousands of
// rows) and the grouping/aggregation/gazetteer-resolution pipeline runs over it in Go (see
// buildPlaces), so it's directly unit-testable without a database. That stops being the
// right tradeoff at the same point those comments already name: once a group's history is
// large enough that re-scanning every eligible row on every open of "Places" gets
// expensive, at which point this would need a maintained per-place rollup instead of a
// live aggregation.
func (d *DB) PlacesForViewer(ctx context.Context, viewerID int64) ([]Place, error) {
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

	return buildPlaces(eligible, time.Now()), nil
}

// buildPlaces groups rows (already filtered to the shared eligibility predicate - see
// PlacesForViewer) by normalizeLocation (the same case/whitespace fold detectEvents uses,
// so the two features never fragment the same real place differently), aggregates each
// group's stats, resolves coordinates via the embedded gazetteer, and orders the result.
// A pure function of the fetched rows and the current time - no database, no HTTP, no
// gazetteer state beyond the package-level embedded dataset - the same reasoning
// detectEvents' and bucketTimeline's own doc comments give for their own pure aggregation
// functions.
//
// Ordering is most check-ins first - the plainest reading of "a place that matters to
// this group" for a first list view with no map to lay places out spatially yet - tied
// second by most recent activity (a place the group hasn't been back to in years reads as
// less current than one with the same count but a recent visit), then the display string,
// for full determinism independent of Go's unspecified map iteration order (the same
// convention eventOutranks documents for events).
func buildPlaces(rows []eventPostRow, now time.Time) []Place {
	homeArea := computeHomeArea(rows, now)

	type group struct {
		rows []eventPostRow
	}
	groups := make(map[string]*group)
	var order []string // first-seen order of each normalized key; sorted properly below
	for _, r := range rows {
		key := normalizeLocation(r.Location)
		g := groups[key]
		if g == nil {
			g = &group{}
			groups[key] = g
			order = append(order, key)
		}
		g.rows = append(g.rows, r)
	}

	places := make([]Place, 0, len(order))
	for _, key := range order {
		places = append(places, buildPlace(groups[key].rows, homeArea[key]))
	}

	sort.Slice(places, func(i, j int) bool { return placeOutranks(places[i], places[j]) })
	return places
}

// buildPlace aggregates one place's own rows into the client-facing summary.
func buildPlace(rows []eventPostRow, homeArea bool) Place {
	posters := make(map[int64]bool, len(rows))
	photoCount := 0
	var coverMediaID *int64
	var coverPost eventPostRow
	haveCover := false
	firstSeen, lastSeen := rows[0].CreatedAt, rows[0].CreatedAt

	for _, r := range rows {
		posters[r.AuthorID] = true
		photoCount += r.PhotoCount
		if r.CreatedAt.Before(firstSeen) {
			firstSeen = r.CreatedAt
		}
		if r.CreatedAt.After(lastSeen) {
			lastSeen = r.CreatedAt
		}
		if r.CoverMediaID != nil {
			if !haveCover || r.LikeCount > coverPost.LikeCount ||
				(r.LikeCount == coverPost.LikeCount && r.PostID < coverPost.PostID) {
				coverMediaID = r.CoverMediaID
				coverPost = r
				haveCover = true
			}
		}
	}

	location := displayLocation(rows)
	var lat, lng *float64
	if resolvedLat, resolvedLng, ok := gazetteer.Resolve(location); ok {
		lat, lng = &resolvedLat, &resolvedLng
	}

	return Place{
		Location:     location,
		Lat:          lat,
		Lng:          lng,
		PostCount:    len(rows),
		PhotoCount:   photoCount,
		PosterCount:  len(posters),
		FirstSeen:    firstSeen,
		LastSeen:     lastSeen,
		CoverMediaID: coverMediaID,
		HomeArea:     homeArea,
	}
}

// placeOutranks reports whether a ranks strictly ahead of b - see buildPlaces' own doc
// comment for the ranking rule.
func placeOutranks(a, b Place) bool {
	if a.PostCount != b.PostCount {
		return a.PostCount > b.PostCount
	}
	if !a.LastSeen.Equal(b.LastSeen) {
		return a.LastSeen.After(b.LastSeen)
	}
	return a.Location < b.Location
}

// maxPlacePosts bounds how many posts GET /api/memories/places/photos returns for one
// place, newest first - the same cap, and the same reasoning, as
// maxTimelineMonthPosts (timeline.go): sized well above what a real group produces
// even at a group's own home area (which, unlike a trip/gathering cluster, has no
// natural upper bound of its own), while keeping the query and the response bounded
// regardless of how much history has piled up at one place. See PostsForPlace's own
// doc comment for how a place that actually exceeds this is reported rather than
// silently truncated.
const maxPlacePosts = 200

// PostsForPlace returns one place's own eligible check-ins, newest first, serialized
// exactly like the feed (reusing the same column list and shared SELECT fragments as
// Feed/GetPost/RandomMemory in queries.go) - the client's existing Post model and shared
// photo grid need no special case for where these came from.
//
// location is matched by normalizeLocation, not literal string equality - the same fold
// PlacesForViewer's own grouping uses (see buildPlaces), so a place whose underlying rows
// are not all byte-identical (an on-device reverse geocoder rendering the same real place
// with different casing or spacing across two members' phones) still returns every row
// buildPlaces counted toward that place's own stats, not just the ones matching whichever
// single string happened to be picked as its display value. Matching against the full
// eligible pool (rather than a WHERE p.location = $2 the database could index) is the
// same O(eligible rows) tradeoff PlacesForViewer's own cost comment already makes and
// accepts for a friend group's post table; the same remedy that comment names (a
// maintained rollup) would also be what this query needs once that stops being true.
//
// Capped at maxPlacePosts; hasMore reports whether the place actually had more than
// that - the caller MUST surface this (see the api package's handlePlacePosts and the
// client's place-detail header, which sizes its own "N check-ins" off exactly what was
// returned, the same way the timeline month detail already does off
// TimelineMonthPosts' own hasMore) rather than trusting the places LIST endpoint's own
// PostCount, which is an unbounded aggregate that can legitimately exceed this.
func (d *DB) PostsForPlace(ctx context.Context, viewerID int64, location string) (posts []Post, hasMore bool, err error) {
	target := normalizeLocation(location)
	if target == "" {
		return nil, false, nil
	}

	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.location, p.created_at
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE u.status = 'active'
		  AND p.kind <> 'recap'
		  AND p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)
		  AND p.location IS NOT NULL AND p.location <> ''`,
		viewerID,
	)
	if err != nil {
		return nil, false, err
	}
	type idAndTime struct {
		id      int64
		created time.Time
	}
	var matched []idAndTime
	for rows.Next() {
		var id int64
		var loc string
		var created time.Time
		if err := rows.Scan(&id, &loc, &created); err != nil {
			rows.Close()
			return nil, false, err
		}
		if normalizeLocation(loc) == target {
			matched = append(matched, idAndTime{id: id, created: created})
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	if len(matched) == 0 {
		return nil, false, nil
	}

	sort.Slice(matched, func(i, j int) bool {
		if !matched[i].created.Equal(matched[j].created) {
			return matched[i].created.After(matched[j].created)
		}
		return matched[i].id > matched[j].id
	})
	if len(matched) > maxPlacePosts {
		matched = matched[:maxPlacePosts]
		hasMore = true
	}
	ids := make([]int64, len(matched))
	for i, m := range matched {
		ids[i] = m.id
	}

	full, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at, p.cross_post_id, p.lat, p.lng,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
		        AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+postPeopleExpr+recapExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE p.id = ANY($2::bigint[])
		ORDER BY p.created_at DESC, p.id DESC`,
		viewerID, ids,
	)
	if err != nil {
		return nil, false, err
	}
	defer full.Close()
	for full.Next() {
		var p Post
		var preview, media, people, recap []byte
		if err := full.Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt, &p.CrossPostID, &p.Lat, &p.Lng,
			&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview, &media, &people, &recap); err != nil {
			return nil, false, err
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
	if err := full.Err(); err != nil {
		return nil, false, err
	}
	return posts, hasMore, nil
}
