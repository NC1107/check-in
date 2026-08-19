package db

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"

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
// rows) and the grouping/aggregation pipeline runs over it in Go (see buildPlaces), so
// that pipeline is directly unit-testable without a database. That stops being the right
// tradeoff at the same point those comments already name: once a group's history is large
// enough that re-scanning every eligible row on every open of "Places" gets expensive, at
// which point this would need a maintained per-place rollup instead of a live aggregation.
//
// Gazetteer resolution itself happens HERE, not inside buildPlaces (see that function's
// own doc comment for why it has to stay a pure, DB-free function of its inputs) - one
// pre-pass, resolvePlaceCandidates, resolves every distinct location this call's own rows
// could need through the (now disk-backed, see the gazetteer package's own doc comment)
// gazetteer, checking gazetteer_cache first so the SAME distinct string is only ever read
// off disk once, ever, no matter how many times any viewer opens Places afterward.
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

	candidatesByLocation, err := d.resolvePlaceCandidates(ctx, eligible)
	if err != nil {
		return nil, err
	}

	return buildPlaces(eligible, time.Now(), candidatesByLocation), nil
}

// resolvePlaceCandidates resolves every distinct location among rows through the
// gazetteer, keyed by normalizeLocation - the map buildPlaces reads instead of calling the
// gazetteer package itself (see its own doc comment). One representative raw string per
// normalized location is enough: gazetteer.Candidates re-normalizes internally too, so two
// rows whose raw strings differ only by the casing/whitespace variance normalizeLocation
// already folds resolve identically either way.
//
// Every resolution is cached in gazetteer_cache (see migrations/0022_gazetteer_cache.sql),
// including a negative one (a location with no real candidates at all) - a self-hosted
// group has "ten to fifty distinct [location] strings, ever" (new check-ins have carried
// their own captured coordinates and never touch the gazetteer at all since the client
// started sending them), so after the first viewer's first open of Places, every one of
// them is answered from this table and the disk-backed gazetteer file is never read again
// for that group.
func (d *DB) resolvePlaceCandidates(ctx context.Context, rows []eventPostRow) (map[string][]gazetteer.Candidate, error) {
	representative := make(map[string]string, len(rows))
	for _, r := range rows {
		key := normalizeLocation(r.Location)
		if _, ok := representative[key]; !ok {
			representative[key] = r.Location
		}
	}

	result := make(map[string][]gazetteer.Candidate, len(representative))
	for key, raw := range representative {
		candidates, err := d.candidatesCached(ctx, key, raw)
		if err != nil {
			return nil, err
		}
		result[key] = candidates
	}
	return result, nil
}

// candidatesCached is resolvePlaceCandidates' own per-location cache lookup: a hit
// answers straight from gazetteer_cache with no disk read of the gazetteer file at all; a
// miss pays that (rare, one-time) disk read and writes the answer back for next time -
// including when the answer is "no candidates at all", so an unresolvable string never
// re-scans the file on every future call either.
//
// ON CONFLICT DO NOTHING rather than an upsert: two viewers racing to resolve the same
// brand-new location at once would both compute the identical, deterministic answer from
// the same on-disk file, so whichever INSERT lands first is correct and the other's is a
// harmless no-op - there is nothing here that ever needs overwriting.
func (d *DB) candidatesCached(ctx context.Context, normalizedKey, rawLocation string) ([]gazetteer.Candidate, error) {
	var payload []byte
	err := d.Pool.QueryRow(ctx,
		`SELECT candidates FROM gazetteer_cache WHERE normalized_location = $1`, normalizedKey,
	).Scan(&payload)
	if err == nil {
		var candidates []gazetteer.Candidate
		if err := json.Unmarshal(payload, &candidates); err != nil {
			return nil, err
		}
		return candidates, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}

	candidates := gazetteer.Candidates(rawLocation)
	payload, err = json.Marshal(candidates)
	if err != nil {
		return nil, err
	}
	if _, err := d.Pool.Exec(ctx,
		`INSERT INTO gazetteer_cache (normalized_location, candidates) VALUES ($1, $2)
		 ON CONFLICT (normalized_location) DO NOTHING`,
		normalizedKey, payload,
	); err != nil {
		return nil, err
	}
	return candidates, nil
}

// buildPlaces groups rows (already filtered to the shared eligibility predicate - see
// PlacesForViewer) by normalizeLocation (the same case/whitespace fold detectEvents uses,
// so the two features never fragment the same real place differently), aggregates each
// group's stats, resolves coordinates, and orders the result. A pure function of the
// fetched rows, the current time, and candidatesByLocation - no database, no HTTP, no
// gazetteer package call of its own - the same reasoning detectEvents' and
// bucketTimeline's own doc comments give for their own pure aggregation functions.
//
// candidatesByLocation is keyed by normalizeLocation and must already carry an entry
// (possibly a nil/empty slice, for an unresolvable location) for every distinct location
// among rows - see PlacesForViewer's own resolvePlaceCandidates, the only real caller,
// which resolves it through a persistent cache in front of the gazetteer rather than
// having this function reach out to gazetteer.Candidates itself: that package is now
// backed by an on-disk file rather than an in-memory index (see its own doc comment for
// why), and a pure function that might do a disk read per place, with no cache and no way
// to test it without a real data file, is exactly what this signature avoids. A location
// missing from the map entirely (which resolvePlaceCandidates should never actually
// produce) is treated the same as an explicit empty slice - unresolved, not a panic.
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
//     where this group's places actually are. A place with more than one candidate, but
//     where one candidate overwhelmingly DOMINATES the rest by population (see
//     anchorCandidate) AND - once pass (1)/(2) anchors exist at all - is also near their
//     centroid, joins them as an anchor too. Population dominance alone is never
//     sufficient: this dataset's own population-agnostic coverage (see the gazetteer
//     package's own doc comment) means a formerly-unambiguous match like "Washington,
//     United States" now comes back with three dozen-plus candidates, most of them
//     unrelated tiny rural crossroads, so trusting raw dominance with no proximity check
//     at all would just as readily anchor a DC-anchored group's own "White Plains, United
//     States" to White Plains, NEW YORK (dominant by an even wider margin, but nowhere
//     near this group) as it correctly anchors "Washington" to the real capital.
//  4. Every remaining AMBIGUOUS name (no single dominant-and-nearby candidate) is resolved
//     against the plain centroid (see centroidOf) of every anchor passes (1)-(3) produced
//     between them: the candidate nearest that centroid (see nearestCandidate) wins, on
//     the premise that a group's own other, unambiguous places are a far better predictor
//     of which same-named city they meant than that name's population is. This is what
//     correctly separates Arlington, VA (a few miles from a Washington-area group's own
//     Baltimore/Silver Spring/Bethesda anchors) from Arlington, TX (a thousand miles
//     away and irrelevant to this group), without EVER hardcoding "Washington" or
//     "Virginia" anywhere in this file - the exact same logic sends a Texas-anchored
//     group's own "Arlington, United States" to Arlington, TX instead. See
//     places_test.go's own proximity tests for both directions.
//  5. Only when a group has NO anchor at all (every place resolved so far is either nil
//     or itself still pending - e.g. a brand-new group whose very first located check-in
//     is already an ambiguous name) does an ambiguous place fall back to population,
//     exactly as gazetteer.Resolve would - and that place is marked CoordsGuessed so a
//     caller can tell "the group told us" from "we had nothing to go on and guessed".
//
// This resolution is NOT fully iterative, but it is two rounds deep rather than one:
// pass (1)/(2)'s stored-coordinate and unambiguous-match anchors are collected first,
// pass (3)'s dominance-qualified anchors are added on top of THOSE (checked against them,
// never against each other), and only then does pass (4) resolve every remaining
// ambiguous place against the combined result. An ambiguous place's own resolution never
// feeds back in to sharpen the centroid for another ambiguous place resolved later in the
// same call - in practice this is not a real limitation: a group's unambiguous places
// (their everyday Baltimores and Bethesdas) vastly outnumber the handful of ambiguous ones
// on any real history, so the centroid is already well-formed before a single ambiguous
// place needs it.
//
// Ordering is most check-ins first - the plainest reading of "a place that matters to
// this group" for a first list view with no map to lay places out spatially yet - tied
// second by most recent activity (a place the group hasn't been back to in years reads as
// less current than one with the same count but a recent visit), then the display string,
// for full determinism independent of Go's unspecified map iteration order (the same
// convention eventOutranks documents for events).
func buildPlaces(rows []eventPostRow, now time.Time, candidatesByLocation map[string][]gazetteer.Candidate) []Place {
	homeArea := computeHomeArea(rows, now)
	order, groups := groupPlaceRows(rows)

	places := make([]Place, len(order))
	anchors, pending := resolvePlacesPassOne(places, order, groups, homeArea, candidatesByLocation)
	anchors, pending = resolvePlacesPassTwo(places, anchors, pending)
	resolvePlacesPassThree(places, anchors, pending)

	sort.Slice(places, func(i, j int) bool { return placeOutranks(places[i], places[j]) })
	return places
}

// groupPlaceRows groups rows by normalizeLocation (the same case/whitespace fold
// detectEvents uses, so the two features never fragment the same real place differently),
// returning each distinct key in first-seen order - the order buildPlaces' resulting
// places slice is built in, before the final sort - alongside every row that normalized
// to it.
func groupPlaceRows(rows []eventPostRow) (order []string, groups map[string][]eventPostRow) {
	groups = make(map[string][]eventPostRow)
	for _, r := range rows {
		key := normalizeLocation(r.Location)
		if _, ok := groups[key]; !ok {
			order = append(order, key)
		}
		groups[key] = append(groups[key], r)
	}
	return order, groups
}

// pendingPlace is one place whose resolution depends on the anchor centroid - not knowable
// until every OTHER place's own (anchor-eligible) resolution is in.
type pendingPlace struct {
	index      int
	candidates []gazetteer.Candidate
}

// resolvePlacesPassOne is buildPlaces' first pass over each distinct place (see that
// function's own doc comment, priority steps 1-2): a post's own STORED coordinates
// (posts.lat/lng, captured from the poster's device at the moment of a real check-in) are
// ground truth - see averageStoredCoords. Any place with at least one such post uses their
// average and never touches the gazetteer at all. For a place with no stored coordinates,
// the gazetteer is asked for every candidate city sharing that name in that country
// (gazetteer.Candidates). A name with exactly one real candidate is unambiguous - there's
// nothing to disambiguate - and that candidate's coordinates are used directly. Every
// place resolved either way becomes an ANCHOR: real evidence of roughly where this group's
// places actually are. places must already be sized to len(order); this fills in every
// index's Place (stats always, coordinates when resolvable here) and reports every place
// still unresolved as pending, for resolvePlacesPassTwo and resolvePlacesPassThree.
func resolvePlacesPassOne(places []Place, order []string, groups map[string][]eventPostRow, homeArea map[string]bool, candidatesByLocation map[string][]gazetteer.Candidate) (anchors []placeCoord, pending []pendingPlace) {
	for i, key := range order {
		groupRows := groups[key]
		p := buildPlaceStats(groupRows, homeArea[key])

		if lat, lng, ok := averageStoredCoords(groupRows); ok {
			p.Lat, p.Lng = floatPtr(lat), floatPtr(lng)
			anchors = append(anchors, placeCoord{lat: lat, lng: lng})
			places[i] = p
			continue
		}

		candidates := candidatesByLocation[key]
		if len(candidates) == 0 {
			places[i] = p // stays unresolved: nil lat/lng
			continue
		}
		if len(candidates) == 1 {
			p.Lat, p.Lng = floatPtr(candidates[0].Lat), floatPtr(candidates[0].Lng)
			anchors = append(anchors, placeCoord{lat: candidates[0].Lat, lng: candidates[0].Lng})
			places[i] = p
			continue
		}
		places[i] = p
		pending = append(pending, pendingPlace{index: i, candidates: candidates})
	}
	return anchors, pending
}

// resolvePlacesPassTwo is buildPlaces' second pass (see that function's own doc comment,
// priority step 3): a place whose candidates dominance-qualify (anchorCandidate) is
// trusted as an anchor too, on top of pass one's stored-coordinate and unambiguous-match
// anchors - but only once checked against them, not unconditionally. Every real GeoNames
// place sharing that name in that country is a genuine candidate for what a DOMINANCE-only
// check can't tell apart on its own: Washington, DC (dominant among US "Washington"s by
// ~28x) is also close to a DC-anchored group's other places, but White Plains, NEW YORK
// (dominant among US "White Plains" by more than that) is not close to THIS group's -
// population dominance alone can't distinguish the two shapes, only checking the candidate
// against real anchor evidence already in hand can. So: when pass one already produced at
// least one anchor, a dominance-qualified candidate is trusted only when it's also within
// kAnchorDominanceMaxDistanceKm of pass one's own centroid - close enough to read as "the
// same regional area this group is actually in", not merely "the biggest place with this
// name anywhere in the country". A dominance-qualified candidate that fails that check, or
// a place that never dominance-qualifies at all, stays pending for pass three's ordinary
// nearest-to-the-FULL-centroid disambiguation instead - which is what correctly sends
// White Plains to Maryland once Washington's own anchor (added here) has made that fuller
// centroid available.
//
// When pass one produced NO anchor at all yet, there is nothing to check a dominant
// candidate against - it's trusted outright, exactly as an unambiguous match would be (see
// TestBuildPlacesUnambiguousGazetteerMatchBecomesAnchor's own Baltimore/Arlington pair,
// where Baltimore's dominant match must anchor Arlington's resolution with no other anchor
// anywhere in the group's history).
func resolvePlacesPassTwo(places []Place, anchors []placeCoord, pending []pendingPlace) ([]placeCoord, []pendingPlace) {
	if len(pending) == 0 {
		return anchors, pending
	}
	center, haveCenter := placeCoord{}, len(anchors) > 0
	if haveCenter {
		center = centroidOf(anchors)
	}
	var stillPending []pendingPlace
	for _, pl := range pending {
		dominant, ok := anchorCandidate(pl.candidates)
		if ok && haveCenter {
			ok = haversineKm(placeCoord{lat: dominant.Lat, lng: dominant.Lng}, center) <= kAnchorDominanceMaxDistanceKm
		}
		if !ok {
			stillPending = append(stillPending, pl)
			continue
		}
		places[pl.index].Lat = floatPtr(dominant.Lat)
		places[pl.index].Lng = floatPtr(dominant.Lng)
		anchors = append(anchors, placeCoord{lat: dominant.Lat, lng: dominant.Lng})
	}
	return anchors, stillPending
}

// resolvePlacesPassThree is buildPlaces' third and final pass (see that function's own doc
// comment, priority steps 4-5): whatever remains - genuinely ambiguous names with no
// single candidate either unique or dominant enough for passes one/two - resolved by
// proximity to whatever anchor centroid those two passes produced between them, or (if
// they produced none at all) by population alone as the documented last resort, marking
// that place CoordsGuessed so a caller can tell "the group told us" from "we had nothing
// to go on and guessed".
func resolvePlacesPassThree(places []Place, anchors []placeCoord, pending []pendingPlace) {
	if len(pending) == 0 {
		return
	}
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

// kAnchorDominanceRatio is how many times larger the most populous candidate for an
// otherwise-ambiguous name must be than the runner-up before anchorCandidate trusts it as
// an anchor outright, exactly as if it had been the only candidate at all - see
// anchorCandidate's own doc comment for why this exists and the real numbers it has to
// cleanly separate.
const kAnchorDominanceRatio = 10

// kAnchorDominanceMaxDistanceKm is how close a dominance-qualified candidate (see
// anchorCandidate) has to be to pass one's own anchor centroid before buildPlaces' second
// pass trusts it as an anchor too - see that pass's own doc comment for the Washington/
// White Plains contrast this exists to draw: both dominate their own same-named
// candidates by a wide margin, but only one of them is actually near a DC-anchored group's
// other places. Washington, DC sits about 90km from a Gaithersburg/Mathias-anchored
// centroid; White Plains, NY sits well over 400km from the same one - a wide enough gap
// that the exact value here isn't fragile, chosen as roughly "the same metro/regional
// area", generous enough to cover a group's own places being spread across a couple of
// neighboring counties without being so wide it would also cover a same-named place one
// state over.
const kAnchorDominanceMaxDistanceKm = 200.0

// kAnchorDominanceMinPopulation is the absolute floor anchorCandidate requires of a
// candidate that has literally nothing else to compare its population against - every
// OTHER same-named candidate in its country is unreported/zero (see anchorCandidate's own
// doc comment for why that's the common shape, not a rare edge case, in this dataset). A
// real DC-area suburb like Silver Spring, MD (pop 71,452, with every other US "Silver
// Spring" at population 0) still needs to qualify here - it has no meaningfully-populated
// rival to compute a ratio against at all - while Boyds, WA (pop 34, likewise the only
// nonzero candidate among four) must not: a population in the tens of thousands is
// unambiguously a real, established town: a population of 34 is not meaningfully
// different from the zeros around it and carries no real signal either way.
const kAnchorDominanceMinPopulation = 1000

// anchorCandidate reports whether one candidate among an AMBIGUOUS place's own
// candidates (candidates must have at least 2 entries - a single-candidate match anchors
// directly in buildPlaces' first pass, never through here) so overwhelmingly dominates
// every other same-named place in its country by population that buildPlaces' second pass
// can consider trusting it as an anchor, subject to that pass's own proximity check on
// top - see its doc comment for why dominance ALONE is never sufficient by itself.
//
// This exists because population-agnostic coverage cuts both ways: it's what makes
// Mathias, WV or Poolesville, MD resolvable at all, but it also means a formerly
// UNAMBIGUOUS match - "Washington, United States" used to have exactly one candidate
// (the capital) under the old population-floored dataset - now comes back with three
// dozen-plus candidates, because GeoNames also lists a couple dozen unrelated, tiny,
// same-named rural crossroads elsewhere in the country.
//
// The ratio has to cleanly separate "one real candidate obviously dwarfs the rest" from
// "genuinely comparable same-named cities, which must still wait for real proximity
// evidence" (the Arlington, VA/TX and Great Falls, MT/VA cases nearestCandidate exists
// for). It does, by a wide margin, on the real GeoNames numbers: Washington, DC
// (pop 689,545) outnumbers the next US "Washington" (Washington, UT, ~24,300) by roughly
// 28x, and Baltimore, MD (pop 585,708) outnumbers the next (Baltimore, OH, ~2,970) by
// roughly 197x - both comfortably clear kAnchorDominanceRatio. Arlington, TX/VA (~1.9x)
// and Great Falls, MT/VA (~3.9x) never clear it, so this never even offers either of THOSE
// as a candidate anchor; they still need a real anchor elsewhere to disambiguate by
// proximity, exactly as places_test.go's own Arlington/Great Falls tests already pin.
func anchorCandidate(candidates []gazetteer.Candidate) (gazetteer.Candidate, bool) {
	bestIdx := 0
	for i, c := range candidates {
		if c.Population > candidates[bestIdx].Population {
			bestIdx = i
		}
	}
	best := candidates[bestIdx]
	if best.Population == 0 {
		return gazetteer.Candidate{}, false
	}
	secondBest := 0
	for i, c := range candidates {
		if i != bestIdx && c.Population > secondBest {
			secondBest = c.Population
		}
	}
	// secondBest == 0 (every OTHER candidate's population is unreported/zero, real GeoNames
	// data for the great majority of small hamlets - see gazetteer's own doc comment) has
	// no ratio to compute at all, so it falls back to kAnchorDominanceMinPopulation's own
	// absolute floor instead - see that constant's own doc comment for why an ordinary
	// small-town-scale population still needs that floor to tell Silver Spring, MD (a
	// real, substantial place) apart from Boyds, WA (a real but barely-populated one),
	// when both happen to be the only nonzero candidate for their name.
	var dominant bool
	if secondBest > 0 {
		dominant = best.Population >= secondBest*kAnchorDominanceRatio
	} else {
		dominant = best.Population >= kAnchorDominanceMinPopulation
	}
	if !dominant {
		return gazetteer.Candidate{}, false
	}
	return best, true
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
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
		        AND c.cross_comment_id IS NOT NULL
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
		p, err := scanPost(full)
		if err != nil {
			return nil, false, err
		}
		posts = append(posts, p)
	}
	if err := full.Err(); err != nil {
		return nil, false, err
	}
	return posts, hasMore, nil
}
