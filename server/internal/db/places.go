package db

import (
	"context"
	"encoding/json"
	"math"
	"sort"
	"time"

	"github.com/nc1107/check-in/server/internal/gazetteer"
)

// Place is one distinct location across a group's eligible check-ins - display string,
// resolved coordinates, aggregate stats, and whether it reads as the group's own home
// area - for the Memories hub's "Places" entry. See PlacesForViewer for the underlying
// eligibility and aggregation, and buildPlaces for exactly how (and in what priority
// order) a place's coordinates get resolved.
type Place struct {
	Location string `json:"location"`

	// Lat/Lng are nil when nothing - not a stored post coordinate, not the gazetteer,
	// not even a population-only guess - could turn Location into coordinates: too small
	// a place for the embedded dataset's population/capital-status bar, an unrecognised
	// country name, or a malformed string. A place with nil coordinates still belongs in
	// the list (see PlacesForViewer's own doc comment) - it just can't be plotted once a
	// map view exists.
	Lat *float64 `json:"lat"`
	Lng *float64 `json:"lng"`

	// CoordsGuessed is true only when Lat/Lng came from buildPlaces' own last-resort
	// path: an ambiguous gazetteer name (more than one real city with that name in that
	// country) resolved by population alone because the group had no anchor at all yet
	// to disambiguate by proximity to (see buildPlaces' own doc comment). False for every
	// other case - a stored post coordinate, an unambiguous gazetteer match, or an
	// ambiguous one resolved by proximity to a real anchor - all of which are grounded in
	// something the group itself did, not a population-only shot in the dark.
	CoordsGuessed bool `json:"coordsGuessed,omitempty"`

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
// check-ins, most-check-ins-first (see buildPlaces for the ranking rule and the
// coordinate-resolution priority order).
//
// Eligible posts: the same predicate RandomMemory, EventsForViewer and Timeline already
// share (active author, not blocked by the viewer, kind <> 'recap'), plus the location
// requirement EventsForViewer also applies - a place with no location can't be a place.
//
// A place that can't be resolved to coordinates at all (see buildPlaces) is still
// returned, with Lat/Lng nil - dropping it, or worse, guessing at coordinates, would be
// actively worse than an honest "we don't know where this is" the client can render.
//
// One query, not one per place: every eligible, location-bearing row is fetched in a
// single statement (the same tradeoff RandomMemory's, Timeline's and EventsForViewer's own
// doc comments already make for a friend group's post table - dozens to low thousands of
// rows) and the grouping/aggregation/resolution pipeline runs over it in Go (see
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
		          ORDER BY pm.position LIMIT 1),
		       p.lat, p.lng
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
			&r.Location, &r.CreatedAt, &r.LikeCount, &r.PhotoCount, &r.CoverMediaID,
			&r.Lat, &r.Lng); err != nil {
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
// group's stats, resolves coordinates, and orders the result. A pure function of the
// fetched rows and the current time - no database, no HTTP - the same reasoning
// detectEvents' and bucketTimeline's own doc comments give for their own pure aggregation
// functions.
//
// COORDINATE RESOLUTION runs in strict priority order, because a bare "City, Country"
// string is frequently ambiguous (there are four real, populous US Richmonds, four
// Arlingtons, two Great Fallses) and the wrong tiebreak is actively dangerous - it was
// this package's own first version's bug: ranking every ambiguous candidate by
// population alone silently resolved a Washington-area group's "Arlington, United
// States" to Arlington, TEXAS (the largest Arlington on Earth) and its "Great Falls,
// United States" to Great Falls, MONTANA, both roughly a thousand-plus miles from where
// the group actually was - wrong enough that shipping it would have been worse than
// shipping no map at all. The fix is to prefer signal the GROUP ITSELF already
// established over anything population-only:
//
//  1. A post's own STORED coordinates (posts.lat/lng, captured from the poster's device
//     at the moment of a real check-in) are ground truth - see averageStoredCoords. Any
//     place with at least one such post uses their average and never touches the
//     gazetteer at all. This is also self-correcting over time: as coordinate capture
//     (which only shipped alongside this feature) becomes the norm, more and more of a
//     group's history resolves this way and needs no disambiguation at all.
//  2. For a place with no stored coordinates, the gazetteer is asked for every candidate
//     city sharing that name in that country (gazetteer.Candidates). A name with exactly
//     one real candidate is unambiguous - there's nothing to disambiguate - and that
//     candidate's coordinates are used directly.
//  3. Every place resolved by (1) or (2) becomes an ANCHOR: real evidence of roughly
//     where this group's places actually are. Their plain centroid (see centroidOf) is
//     what every AMBIGUOUS name (more than one gazetteer candidate) is then resolved
//     against: the candidate nearest that centroid (see nearestCandidate) wins, on the
//     premise that a group's own other, unambiguous places are a far better predictor of
//     which same-named city they meant than that name's population is. This is what
//     correctly separates Arlington, VA (a few miles from a Washington-area group's own
//     Baltimore/Silver Spring/Bethesda anchors) from Arlington, TX (a thousand miles
//     away and irrelevant to this group), without EVER hardcoding "Washington" or
//     "Virginia" anywhere in this file - the exact same logic sends a Texas-anchored
//     group's own "Arlington, United States" to Arlington, TX instead. See
//     places_test.go's own proximity tests for both directions.
//  4. Only when a group has NO anchor at all yet (every place resolved so far is either
//     nil or itself still pending - e.g. a brand-new group whose very first located
//     check-in is already an ambiguous name) does an ambiguous place fall back to
//     population, exactly as gazetteer.Resolve would - and that place is marked
//     CoordsGuessed so a caller can tell "the group told us" from "we had nothing to go
//     on and guessed".
//
// This resolution is NOT iterative: anchors are collected in one pass (stored
// coordinates and unambiguous gazetteer matches only), then every ambiguous place is
// resolved in a second pass against that one fixed centroid - an ambiguous place's own
// resolution never feeds back in to sharpen the centroid for another ambiguous place
// resolved later in the same call. In practice this is not a real limitation: a group's
// unambiguous places (their everyday Baltimores and Bethesdas) vastly outnumber the
// handful of ambiguous ones on any real history, so the centroid is already well-formed
// before a single ambiguous place needs it.
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

	// pendingPlace is one place whose resolution depends on the anchor centroid - not
	// knowable until every OTHER place's own (anchor-eligible) resolution is in.
	type pendingPlace struct {
		index      int
		candidates []gazetteer.Candidate
	}

	places := make([]Place, len(order))
	var anchors []placeCoord
	var pending []pendingPlace

	for i, key := range order {
		groupRows := groups[key].rows
		p := buildPlaceStats(groupRows, homeArea[key])

		if lat, lng, ok := averageStoredCoords(groupRows); ok {
			p.Lat, p.Lng = floatPtr(lat), floatPtr(lng)
			anchors = append(anchors, placeCoord{lat: lat, lng: lng})
			places[i] = p
			continue
		}

		candidates := gazetteer.Candidates(p.Location)
		switch len(candidates) {
		case 0:
			places[i] = p // stays unresolved: nil lat/lng
		case 1:
			p.Lat, p.Lng = floatPtr(candidates[0].Lat), floatPtr(candidates[0].Lng)
			anchors = append(anchors, placeCoord{lat: candidates[0].Lat, lng: candidates[0].Lng})
			places[i] = p
		default:
			places[i] = p
			pending = append(pending, pendingPlace{index: i, candidates: candidates})
		}
	}

	if len(pending) > 0 {
		haveAnchor := len(anchors) > 0
		var center placeCoord
		if haveAnchor {
			center = centroidOf(anchors)
		}
		for _, pl := range pending {
			var chosen gazetteer.Candidate
			guessed := false
			if haveAnchor {
				chosen = nearestCandidate(pl.candidates, center)
			} else {
				chosen = mostPopulousCandidate(pl.candidates)
				guessed = true
			}
			places[pl.index].Lat = floatPtr(chosen.Lat)
			places[pl.index].Lng = floatPtr(chosen.Lng)
			places[pl.index].CoordsGuessed = guessed
		}
	}

	sort.Slice(places, func(i, j int) bool { return placeOutranks(places[i], places[j]) })
	return places
}

// buildPlaceStats aggregates one place's own rows into everything EXCEPT its
// coordinates: postCount, photoCount, posterCount, firstSeen, lastSeen, cover, and
// homeArea. Coordinates are resolved separately, across every place at once, by
// buildPlaces itself - an ambiguous gazetteer match can only be disambiguated once every
// OTHER place's own resolution is known, which one place's own rows alone could never
// tell it (see buildPlaces' own doc comment).
func buildPlaceStats(rows []eventPostRow, homeArea bool) Place {
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

	return Place{
		Location:     displayLocation(rows),
		PostCount:    len(rows),
		PhotoCount:   photoCount,
		PosterCount:  len(posters),
		FirstSeen:    firstSeen,
		LastSeen:     lastSeen,
		CoverMediaID: coverMediaID,
		HomeArea:     homeArea,
	}
}

// placeCoord is a bare lat/lng pair - the shape every step of buildPlaces' coordinate
// resolution (stored-post averages, gazetteer candidates, the anchor centroid) is
// compared and averaged in.
type placeCoord struct {
	lat, lng float64
}

func floatPtr(f float64) *float64 { return &f }

// averageStoredCoords returns the mean of every non-nil (Lat, Lng) pair among rows, or
// ok=false when none of them carry stored coordinates at all. This is priority one for a
// place's own coordinates (see buildPlaces' own doc comment): a post's stored lat/lng is
// ground truth from an actual device at an actual check-in - strictly better evidence
// than anything the offline gazetteer could infer from the place's NAME alone - and
// averaging several such posts (rather than picking just one) smooths out ordinary GPS
// noise between separate visits to the same real place.
func averageStoredCoords(rows []eventPostRow) (lat, lng float64, ok bool) {
	var sumLat, sumLng float64
	var n int
	for _, r := range rows {
		if r.Lat == nil || r.Lng == nil {
			continue
		}
		sumLat += *r.Lat
		sumLng += *r.Lng
		n++
	}
	if n == 0 {
		return 0, 0, false
	}
	return sumLat / float64(n), sumLng / float64(n), true
}

// centroidOf is the plain arithmetic mean of every anchor coordinate - the group's own
// rough "center of gravity" that an ambiguous gazetteer name is disambiguated against
// (see nearestCandidate). Not a true spherical centroid: for the scale a single group's
// own history actually spans - even a handful of far-flung vacations averaged in
// alongside dozens of everyday hometown places barely moves the mean - the difference
// from a proper geodesic centroid is immaterial, and a plain mean keeps this trivially
// testable and dependency-free. Callers must not call this with an empty slice; see
// buildPlaces' own haveAnchor guard.
func centroidOf(coords []placeCoord) placeCoord {
	var sumLat, sumLng float64
	for _, c := range coords {
		sumLat += c.lat
		sumLng += c.lng
	}
	n := float64(len(coords))
	return placeCoord{lat: sumLat / n, lng: sumLng / n}
}

// haversineKm is the great-circle distance between two points in kilometers, Earth
// modeled as a sphere - more than precise enough for telling apart two same-named cities
// that are, in every real case this exists for, hundreds or thousands of kilometers
// apart.
func haversineKm(a, b placeCoord) float64 {
	const earthRadiusKm = 6371.0
	lat1, lat2 := a.lat*math.Pi/180, b.lat*math.Pi/180
	dLat := (b.lat - a.lat) * math.Pi / 180
	dLng := (b.lng - a.lng) * math.Pi / 180
	h := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1)*math.Cos(lat2)*math.Sin(dLng/2)*math.Sin(dLng/2)
	return 2 * earthRadiusKm * math.Asin(math.Sqrt(h))
}

// nearestCandidate picks the candidate closest to target (see haversineKm), ties broken
// toward the earlier entry in candidates for determinism. This is buildPlaces' preferred
// disambiguation whenever the group has ANY anchor at all: among several real cities
// sharing one name, the one nearest to where the group is otherwise confidently known to
// be is overwhelmingly more likely to be the one they actually meant than that name's
// single biggest city worldwide (mostPopulousCandidate's own, cruder rule, kept only as
// the last resort - see buildPlaces). Callers must not call this with an empty slice.
func nearestCandidate(candidates []gazetteer.Candidate, target placeCoord) gazetteer.Candidate {
	best := candidates[0]
	bestDist := haversineKm(placeCoord{lat: best.Lat, lng: best.Lng}, target)
	for _, c := range candidates[1:] {
		d := haversineKm(placeCoord{lat: c.Lat, lng: c.Lng}, target)
		if d < bestDist {
			best, bestDist = c, d
		}
	}
	return best
}

// mostPopulousCandidate is buildPlaces' last-resort disambiguation, reached only when a
// group has no anchor at all yet to disambiguate an ambiguous name by proximity to (e.g.
// a brand-new group whose very first located check-in already happens to be an ambiguous
// name). The same population tiebreak gazetteer.Resolve applies on its own; buildPlaces
// marks a place resolved this way as CoordsGuessed so a caller can tell a
// proximity-informed pick from a genuine population-only guess. Callers must not call
// this with an empty slice.
func mostPopulousCandidate(candidates []gazetteer.Candidate) gazetteer.Candidate {
	best := candidates[0]
	for _, c := range candidates[1:] {
		if c.Population > best.Population {
			best = c
		}
	}
	return best
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
