package db

import (
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/gazetteer"
)

// plNow mirrors events_cluster_test.go's evNow: a fixed "current time" so home-area
// window math is exact and doesn't depend on when the suite runs.
var plNow = time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)

func plDay(daysAgo int, hour int) time.Time {
	d := plNow.AddDate(0, 0, -daysAgo)
	return time.Date(d.Year(), d.Month(), d.Day(), hour, 0, 0, 0, time.UTC)
}

// plRow builds an eventPostRow with every field buildPlace/buildPlaces reads - evRow
// (events_cluster_test.go) only sets the subset detectEvents itself needs.
func plRow(postID, authorID int64, loc string, when time.Time, likeCount, photoCount int, cover *int64) eventPostRow {
	return eventPostRow{
		PostID:       postID,
		AuthorID:     authorID,
		AuthorName:   "Author",
		Location:     loc,
		CreatedAt:    when,
		LikeCount:    likeCount,
		PhotoCount:   photoCount,
		CoverMediaID: cover,
	}
}

// mid (test helper for a *int64 literal) already exists package-wide - see
// recap_select_test.go.

// plRowCoord builds a minimal eventPostRow carrying a stored (Lat, Lng) - the anchor rows
// the proximity-disambiguation tests below use to plant a group's own confidently-known
// locations as ground truth, independent of which gazetteer entries happen to be
// unambiguous.
func plRowCoord(postID, authorID int64, loc string, when time.Time, lat, lng float64) eventPostRow {
	la, ln := lat, lng
	return eventPostRow{
		PostID:     postID,
		AuthorID:   authorID,
		AuthorName: "Author",
		Location:   loc,
		CreatedAt:  when,
		Lat:        &la,
		Lng:        &ln,
	}
}

// plCandidates builds the candidatesByLocation map buildPlaces now takes as an explicit
// parameter (see its own doc comment for why it no longer calls the gazetteer package
// itself) - one real gazetteer.Candidates lookup per distinct location among rows, the
// same "one representative raw string per normalized location" shape
// db.resolvePlaceCandidates uses in production, just without a database cache in front of
// it, since there's no database in these tests at all. Tests exercising a genuinely
// fictional location (e.g. "Somewhere, Nowhereland") get exactly what the real gazetteer
// says about it - nil - the same honest "no candidates" buildPlaces must handle either way.
func plCandidates(rows []eventPostRow) map[string][]gazetteer.Candidate {
	result := make(map[string][]gazetteer.Candidate, len(rows))
	for _, r := range rows {
		key := normalizeLocation(r.Location)
		if _, ok := result[key]; !ok {
			result[key] = gazetteer.Candidates(r.Location)
		}
	}
	return result
}

func placesByLocation(places []Place) map[string]Place {
	m := make(map[string]Place, len(places))
	for _, p := range places {
		m[p.Location] = p
	}
	return m
}

// nearlyEqual compares floats within a hundredth of a degree (~1km) - enough to catch a
// wrong-city-sized error while not being brittle to floating-point summation order in
// centroidOf/averageStoredCoords.
func nearlyEqual(a, b float64) bool {
	d := a - b
	if d < 0 {
		d = -d
	}
	return d < 0.01
}

// The real GeoNames coordinates this dataset's own ambiguous "Arlington, United States"
// and "Great Falls, United States" candidates carry (see gazetteer_test.go's own
// TestCandidatesReturnsAllMatchesNotJustOne) - used below as the EXPECTED answer in each
// direction, never as a shortcut: these tests exist to prove buildPlaces reaches the
// right one of several real candidates by proximity to the group's own other places, not
// to hand-code an exception for these two names specifically. arlingtonMD (a real
// neighborhood inside Baltimore City itself) and greatFallsMD (a real locality on the
// Maryland side of the Potomac, a couple km from Great Falls, VA) only exist as
// candidates at all because this dataset carries every GeoNames place regardless of
// population (see gazetteer's own doc comment) - the old, population-floored dataset
// never offered either as an option.
var (
	arlingtonVA  = placeCoord{lat: 38.88101, lng: -77.10428}
	arlingtonMD  = placeCoord{lat: 39.34857, lng: -76.68324}
	arlingtonTX  = placeCoord{lat: 32.73569, lng: -97.10807}
	greatFallsMD = placeCoord{lat: 39.00233, lng: -77.24609}
)

// TestBuildPlacesStoredCoordinatesWinOverGazetteer pins priority one: a post's own
// stored coordinate is used outright, never merely as a nudge to (or a confirmation of)
// whatever the gazetteer would have said. The stored value here is deliberately far from
// Lisbon's real coordinates so a passing test can only mean the stored value was
// actually used.
func TestBuildPlacesStoredCoordinatesWinOverGazetteer(t *testing.T) {
	rows := []eventPostRow{
		plRowCoord(1, 1, "Lisbon, Portugal", plDay(5, 9), 10.0, 10.0),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	if len(places) != 1 {
		t.Fatalf("got %d places, want 1", len(places))
	}
	p := places[0]
	if p.Lat == nil || p.Lng == nil {
		t.Fatal("lat/lng = nil, want the stored coordinate")
	}
	if *p.Lat != 10.0 || *p.Lng != 10.0 {
		t.Errorf("got (%v, %v), want the stored (10, 10) - not Lisbon's real gazetteer "+
			"coordinates (38.72509, -9.1498). A post's own stored coordinate must win outright",
			*p.Lat, *p.Lng)
	}
	if p.CoordsGuessed {
		t.Error("CoordsGuessed = true, want false - a stored coordinate is ground truth, not a guess")
	}
}

// TestBuildPlacesAveragesMultipleStoredCoordinates pins that several posts at the same
// place average their stored coordinates rather than one arbitrarily winning.
func TestBuildPlacesAveragesMultipleStoredCoordinates(t *testing.T) {
	rows := []eventPostRow{
		plRowCoord(1, 1, "Somewhere, Nowhereland", plDay(5, 9), 10.0, 20.0),
		plRowCoord(2, 1, "Somewhere, Nowhereland", plDay(4, 9), 12.0, 22.0),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	p := places[0]
	if p.Lat == nil || p.Lng == nil {
		t.Fatal("lat/lng = nil, want the averaged stored coordinate")
	}
	if !nearlyEqual(*p.Lat, 11.0) || !nearlyEqual(*p.Lng, 21.0) {
		t.Errorf("got (%v, %v), want the average (11, 21)", *p.Lat, *p.Lng)
	}
}

// TestBuildPlacesDisambiguatesAmbiguousNamesByProximityToDCAnchors is the direct
// regression test for the original defect: ranking Arlington/Great Falls candidates by
// population alone resolved a Washington-area group's own check-ins to Arlington, TEXAS
// and Great Falls, MONTANA - each over a thousand miles from where the group actually
// was. The group's own confidently-known DC-area locations are planted here as STORED
// coordinates (priority one), so this test is independent of which gazetteer entries
// happen to be unambiguous; Arlington and Great Falls themselves carry no stored
// coordinates of their own, so their resolution comes entirely from the gazetteer plus
// proximity to those anchors.
func TestBuildPlacesDisambiguatesAmbiguousNamesByProximityToDCAnchors(t *testing.T) {
	rows := []eventPostRow{
		plRowCoord(1, 1, "Baltimore, United States", plDay(30, 9), 39.29038, -76.61219),
		plRowCoord(2, 1, "Silver Spring, United States", plDay(25, 9), 38.99067, -77.02609),
		plRowCoord(3, 1, "Bethesda, United States", plDay(20, 9), 38.98067, -77.10026),
		plRow(4, 1, "Arlington, United States", plDay(10, 9), 0, 0, nil),
		plRow(5, 1, "Great Falls, United States", plDay(5, 9), 0, 0, nil),
	}
	byLoc := placesByLocation(buildPlaces(rows, plNow, plCandidates(rows)))

	arl := byLoc["Arlington, United States"]
	if arl.Lat == nil || arl.Lng == nil {
		t.Fatal("Arlington did not resolve at all")
	}
	if !nearlyEqual(*arl.Lat, arlingtonVA.lat) || !nearlyEqual(*arl.Lng, arlingtonVA.lng) {
		t.Errorf("Arlington resolved to (%v, %v), want Arlington, VA (%v, %v) - a DC-anchored "+
			"group's Arlington is Virginia's, not the more populous Texas one",
			*arl.Lat, *arl.Lng, arlingtonVA.lat, arlingtonVA.lng)
	}
	if arl.CoordsGuessed {
		t.Error("Arlington.CoordsGuessed = true, want false - resolved by real anchor proximity, not a guess")
	}

	gf := byLoc["Great Falls, United States"]
	if gf.Lat == nil || gf.Lng == nil {
		t.Fatal("Great Falls did not resolve at all")
	}
	if !nearlyEqual(*gf.Lat, greatFallsMD.lat) || !nearlyEqual(*gf.Lng, greatFallsMD.lng) {
		t.Errorf("Great Falls resolved to (%v, %v), want the DC-area Great Falls (%v, %v) - a "+
			"DC-anchored group's Great Falls is the one on the Potomac, not the more populous Montana one",
			*gf.Lat, *gf.Lng, greatFallsMD.lat, greatFallsMD.lng)
	}
	if gf.CoordsGuessed {
		t.Error("Great Falls.CoordsGuessed = true, want false - resolved by real anchor proximity, not a guess")
	}
}

// TestBuildPlacesDisambiguatesArlingtonToTexasWhenAnchoredThere proves the disambiguation
// is genuine PROXIMITY logic, not a hardcoded "Arlington means Virginia" exception: the
// exact same buildPlaces code, given a group anchored near Dallas/Fort Worth instead,
// must send "Arlington, United States" to Arlington, TEXAS.
func TestBuildPlacesDisambiguatesArlingtonToTexasWhenAnchoredThere(t *testing.T) {
	rows := []eventPostRow{
		plRowCoord(1, 1, "Dallas, United States", plDay(30, 9), 32.77670, -96.79700),
		plRowCoord(2, 1, "Fort Worth, United States", plDay(25, 9), 32.75550, -97.33080),
		plRow(3, 1, "Arlington, United States", plDay(10, 9), 0, 0, nil),
	}
	byLoc := placesByLocation(buildPlaces(rows, plNow, plCandidates(rows)))

	arl := byLoc["Arlington, United States"]
	if arl.Lat == nil || arl.Lng == nil {
		t.Fatal("Arlington did not resolve at all")
	}
	if !nearlyEqual(*arl.Lat, arlingtonTX.lat) || !nearlyEqual(*arl.Lng, arlingtonTX.lng) {
		t.Errorf("Arlington resolved to (%v, %v), want Arlington, TX (%v, %v) - the SAME "+
			"disambiguation logic must send a Texas-anchored group's Arlington to Texas; "+
			"landing anywhere else would mean this is hardcoding Virginia, not doing proximity",
			*arl.Lat, *arl.Lng, arlingtonTX.lat, arlingtonTX.lng)
	}
}

// TestBuildPlacesUnambiguousGazetteerMatchBecomesAnchor pins the other anchor source
// buildPlaces' own doc comment names: a place with no stored coordinate at all can still
// anchor another ambiguous place's resolution, purely off the gazetteer. Baltimore no
// longer has exactly one United States candidate (this dataset's own population-agnostic
// coverage also surfaces several unrelated, tiny, same-named crossroads elsewhere in the
// country - see gazetteer's own doc comment), but its real Baltimore, MD candidate still
// overwhelmingly dominates every one of them by population (see anchorCandidate), which
// is what lets it anchor here with nothing else in the group's history to check that
// dominance against. Arlington's correct resolution here can only have come from Baltimore
// doing anchor duty - and, fittingly, resolves to Arlington, MD, a real neighborhood
// inside Baltimore City itself and closer to it than either of the other real US
// Arlingtons (VA or TX).
func TestBuildPlacesUnambiguousGazetteerMatchBecomesAnchor(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Baltimore, United States", plDay(30, 9), 0, 0, nil),
		plRow(2, 1, "Arlington, United States", plDay(10, 9), 0, 0, nil),
	}
	byLoc := placesByLocation(buildPlaces(rows, plNow, plCandidates(rows)))

	arl := byLoc["Arlington, United States"]
	if arl.Lat == nil || arl.Lng == nil {
		t.Fatal("Arlington did not resolve at all")
	}
	if !nearlyEqual(*arl.Lat, arlingtonMD.lat) || !nearlyEqual(*arl.Lng, arlingtonMD.lng) {
		t.Errorf("Arlington resolved to (%v, %v), want Arlington, MD - Baltimore's own "+
			"dominant gazetteer match must be usable as an anchor on its own, with zero "+
			"stored coordinates anywhere in the group's history", *arl.Lat, *arl.Lng)
	}
}

// TestBuildPlacesFallsBackToPopulationWithNoAnchorAtAll pins the documented last resort:
// a brand-new group whose very first (and only) located check-in is already an ambiguous
// name has nothing to disambiguate by proximity to, so population is the only signal
// left - and the result is marked CoordsGuessed so a caller can tell this case apart from
// every other, anchor-informed resolution.
func TestBuildPlacesFallsBackToPopulationWithNoAnchorAtAll(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Arlington, United States", plDay(1, 9), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	if len(places) != 1 {
		t.Fatalf("got %d places, want 1", len(places))
	}
	p := places[0]
	if p.Lat == nil || p.Lng == nil {
		t.Fatal("lat/lng = nil, want a population-fallback resolution")
	}
	if !nearlyEqual(*p.Lat, arlingtonTX.lat) || !nearlyEqual(*p.Lng, arlingtonTX.lng) {
		t.Errorf("got (%v, %v), want Arlington, TX (%v, %v, the most populous candidate) - the "+
			"only defensible answer with zero anchors to disambiguate by",
			*p.Lat, *p.Lng, arlingtonTX.lat, arlingtonTX.lng)
	}
	if !p.CoordsGuessed {
		t.Error("CoordsGuessed = false, want true - this was a population-only guess with no anchor at all")
	}
}

// TestBuildPlacesResolvesOceanCityToMarylandByProximity is the direct regression test for
// this dataset's own upgrade (see gazetteer_test.go's
// TestResolveNoLongerDropsSmallRealTowns): Ocean City, MD (~7,000 year-round residents, no
// admin-seat status) used to fall below the embedded dataset's old population/capital bar
// entirely and stay unresolved even with a real anchor (Baltimore) elsewhere in the same
// group's history. It's real, this dataset now carries it alongside several other
// same-named US towns (Ocean City, NJ chief among them - larger, and the one Resolve's own
// population-only tiebreak would pick), and a Baltimore-anchored group's own proximity
// disambiguation must land on the Maryland one, not the merely more populous New Jersey
// one two states away.
func TestBuildPlacesResolvesOceanCityToMarylandByProximity(t *testing.T) {
	rows := []eventPostRow{
		plRowCoord(1, 1, "Baltimore, United States", plDay(30, 9), 39.29038, -76.61219),
		plRow(2, 1, "Ocean City, United States", plDay(5, 9), 0, 1, mid(1)),
	}
	byLoc := placesByLocation(buildPlaces(rows, plNow, plCandidates(rows)))
	oc := byLoc["Ocean City, United States"]
	if oc.Lat == nil || oc.Lng == nil {
		t.Fatal("Ocean City did not resolve at all")
	}
	const oceanCityMDLat, oceanCityMDLng = 38.3365, -75.08491
	if !nearlyEqual(*oc.Lat, oceanCityMDLat) || !nearlyEqual(*oc.Lng, oceanCityMDLng) {
		t.Errorf("Ocean City resolved to (%v, %v), want Ocean City, MD (%v, %v) - a "+
			"Baltimore-anchored group's Ocean City is Maryland's, not the more populous New Jersey one",
			*oc.Lat, *oc.Lng, oceanCityMDLat, oceanCityMDLng)
	}
	if oc.CoordsGuessed {
		t.Error("CoordsGuessed = true, want false - resolved by real anchor proximity, not a guess")
	}
}

// TestBuildPlacesAggregatesOnePlace pins the core aggregation: post/photo/poster counts,
// first/last seen, and the display string picked from the group's own rows.
func TestBuildPlacesAggregatesOnePlace(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Lisbon, Portugal", plDay(10, 9), 2, 1, mid(101)),
		plRow(2, 2, "Lisbon, Portugal", plDay(5, 9), 5, 2, mid(102)),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	if len(places) != 1 {
		t.Fatalf("got %d places, want 1", len(places))
	}
	p := places[0]
	if p.Location != "Lisbon, Portugal" {
		t.Errorf("location = %q, want %q", p.Location, "Lisbon, Portugal")
	}
	if p.PostCount != 2 {
		t.Errorf("postCount = %d, want 2", p.PostCount)
	}
	if p.PhotoCount != 3 {
		t.Errorf("photoCount = %d, want 3 (1+2)", p.PhotoCount)
	}
	if p.PosterCount != 2 {
		t.Errorf("posterCount = %d, want 2 distinct authors", p.PosterCount)
	}
	if !p.FirstSeen.Equal(plDay(10, 9)) {
		t.Errorf("firstSeen = %v, want %v", p.FirstSeen, plDay(10, 9))
	}
	if !p.LastSeen.Equal(plDay(5, 9)) {
		t.Errorf("lastSeen = %v, want %v", p.LastSeen, plDay(5, 9))
	}
}

// TestBuildPlacesCoverPicksMostLikedTieBreaksLowerPostID pins the same cover-pick
// convention buildEvent uses: highest like count wins, a tie breaks toward the earlier
// post id.
func TestBuildPlacesCoverPicksMostLikedTieBreaksLowerPostID(t *testing.T) {
	rows := []eventPostRow{
		plRow(5, 1, "Denver, United States", plDay(3, 9), 3, 1, mid(500)),
		plRow(2, 1, "Denver, United States", plDay(2, 9), 3, 1, mid(200)), // same likes, lower id
		plRow(9, 1, "Denver, United States", plDay(1, 9), 1, 1, mid(900)), // fewer likes
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	if len(places) != 1 {
		t.Fatalf("got %d places, want 1", len(places))
	}
	if places[0].CoverMediaID == nil || *places[0].CoverMediaID != 200 {
		t.Errorf("coverMediaId = %v, want 200 (tied top likes, lower post id)", places[0].CoverMediaID)
	}
}

// TestBuildPlacesCoverNilWhenNothingHasAPhoto pins that an all-text place carries no
// cover rather than a zero-value media id.
func TestBuildPlacesCoverNilWhenNothingHasAPhoto(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Denver, United States", plDay(3, 9), 3, 0, nil),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	if places[0].CoverMediaID != nil {
		t.Errorf("coverMediaId = %v, want nil - no row here carried a photo", places[0].CoverMediaID)
	}
}

// TestBuildPlacesOrdersByPostCountDesc pins the primary ranking rule: most check-ins
// first.
func TestBuildPlacesOrdersByPostCountDesc(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Denver, United States", plDay(10, 9), 0, 0, nil),
		plRow(2, 1, "Lisbon, Portugal", plDay(9, 9), 0, 0, nil),
		plRow(3, 2, "Lisbon, Portugal", plDay(8, 9), 0, 0, nil),
		plRow(4, 3, "Lisbon, Portugal", plDay(7, 9), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	if len(places) != 2 {
		t.Fatalf("got %d places, want 2", len(places))
	}
	if places[0].Location != "Lisbon, Portugal" || places[0].PostCount != 3 {
		t.Errorf("first place = %q (count %d), want Lisbon, Portugal with 3 posts",
			places[0].Location, places[0].PostCount)
	}
	if places[1].Location != "Denver, United States" || places[1].PostCount != 1 {
		t.Errorf("second place = %q (count %d), want Denver, United States with 1 post",
			places[1].Location, places[1].PostCount)
	}
}

// TestBuildPlacesTieBreaksByLastSeenThenLocation pins the deterministic tiebreak below
// post count: more recent activity first, then the display string.
func TestBuildPlacesTieBreaksByLastSeenThenLocation(t *testing.T) {
	rows := []eventPostRow{
		// Both places have exactly 1 post - Denver's is more recent.
		plRow(1, 1, "Lisbon, Portugal", plDay(20, 9), 0, 0, nil),
		plRow(2, 1, "Denver, United States", plDay(5, 9), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	if places[0].Location != "Denver, United States" {
		t.Errorf("first place = %q, want Denver, United States (more recent lastSeen)", places[0].Location)
	}

	// Same post count, same lastSeen instant - falls back to the display string.
	same := plDay(1, 9)
	tied := []eventPostRow{
		plRow(1, 1, "Zurich, Switzerland", same, 0, 0, nil),
		plRow(2, 1, "Austin, United States", same, 0, 0, nil),
	}
	tiedPlaces := buildPlaces(tied, plNow, plCandidates(tied))
	if tiedPlaces[0].Location != "Austin, United States" {
		t.Errorf("first place = %q, want Austin, United States (alphabetically first)", tiedPlaces[0].Location)
	}
}

// TestBuildPlacesReusesHomeAreaLogic pins that HomeArea is computed by
// computeHomeArea - the same events_cluster.go logic EventsForViewer's own trip/gathering
// detection already relies on - not a second, independently-tuned definition.
func TestBuildPlacesReusesHomeAreaLogic(t *testing.T) {
	// Three separate episodes across two distinct members clears computeHomeArea's own
	// bar (homeAreaMinEpisodes=3, homeAreaMinMembers=2) - see events_cluster.go.
	rows := []eventPostRow{
		plRow(1, 1, "Austin, United States", plDay(150, 9), 0, 0, nil),
		plRow(2, 2, "Austin, United States", plDay(150, 10), 0, 0, nil),
		plRow(3, 1, "Austin, United States", plDay(100, 9), 0, 0, nil),
		plRow(4, 2, "Austin, United States", plDay(100, 10), 0, 0, nil),
		plRow(5, 1, "Austin, United States", plDay(50, 9), 0, 0, nil),
		plRow(6, 2, "Austin, United States", plDay(50, 10), 0, 0, nil),
		// A one-off vacation elsewhere: one episode, must not read as home area.
		plRow(7, 1, "Lisbon, Portugal", plDay(30, 9), 0, 0, nil),
		plRow(8, 2, "Lisbon, Portugal", plDay(30, 10), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	byLoc := map[string]Place{}
	for _, p := range places {
		byLoc[p.Location] = p
	}
	if !byLoc["Austin, United States"].HomeArea {
		t.Error("Austin should read as home area - 3 separate episodes, 2 distinct members")
	}
	if byLoc["Lisbon, Portugal"].HomeArea {
		t.Error("Lisbon should NOT read as home area - a single one-off vacation episode")
	}
}

// TestBuildPlacesResolvesRealCoordinates pins that a place the embedded gazetteer
// recognizes carries real, non-nil coordinates - not a stub or a zero value standing in
// for "resolved".
func TestBuildPlacesResolvesRealCoordinates(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Lisbon, Portugal", plDay(1, 9), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	p := places[0]
	if p.Lat == nil || p.Lng == nil {
		t.Fatal("lat/lng = nil, want Lisbon's real coordinates")
	}
	if *p.Lat != 38.72509 || *p.Lng != -9.1498 {
		t.Errorf("got (%v, %v), want Lisbon's real GeoNames coordinates", *p.Lat, *p.Lng)
	}
}

// TestBuildPlacesUnresolvablePlaceKeepsNilCoordinatesNotDropped pins the CRITICAL
// HONESTY contract at the db layer: a place the gazetteer can't resolve still appears in
// the list, with nil coordinates - never dropped, never guessed at.
func TestBuildPlacesUnresolvablePlaceKeepsNilCoordinatesNotDropped(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Nowhereville, Fictionland", plDay(1, 9), 0, 1, mid(1)),
	}
	places := buildPlaces(rows, plNow, plCandidates(rows))
	if len(places) != 1 {
		t.Fatalf("got %d places, want 1 - an unresolvable place must still be returned", len(places))
	}
	if places[0].Lat != nil || places[0].Lng != nil {
		t.Errorf("lat/lng = (%v, %v), want (nil, nil) - this dataset has no such place", places[0].Lat, places[0].Lng)
	}
	if places[0].PostCount != 1 {
		t.Errorf("postCount = %d, want 1 - the place's stats must still be aggregated normally", places[0].PostCount)
	}
}

// TestBuildPlacesEmptyInputReturnsEmptyNotNilPanic pins that a fresh group with no
// eligible rows produces an empty (not nil-panicking) result.
func TestBuildPlacesEmptyInputReturnsEmptyNotNilPanic(t *testing.T) {
	places := buildPlaces(nil, plNow, nil)
	if len(places) != 0 {
		t.Errorf("got %d places for no rows, want 0", len(places))
	}
}

// TestBuildPlacesResolvesTheFounderGroupsRealPlaces replays one real self-hosted group's
// own Places history end to end - the exact ten locations and post counts the founder
// reported from a live device, run through the actual buildPlaces pipeline (gazetteer
// lookup, anchor collection, proximity disambiguation) rather than any one step of it in
// isolation. Before this dataset's own upgrade, five of these (Mathias, Poolesville,
// Boyds, Dickerson, Moorefield) came back completely unplaced, and White Plains resolved
// to White Plains, NEW YORK - a real dot, just roughly 350km from the rest of this same
// group - because White Plains, MARYLAND (twenty minutes from Gaithersburg) had no row at
// all to be considered. Every expected coordinate below is the real place the founder
// confirmed on device, or (for the five that used to be unplaced, and for White Plains'
// corrected state) the real GeoNames coordinate for the actual Maryland/West Virginia town
// - see gazetteer_test.go's own TestCandidatesResolvesTheFounderGroupsRealPlaces for the
// same ten strings pinned one level down, against the gazetteer alone.
// plFounderGroupWant is the ten real locations (and post counts) TestBuildPlacesResolves
// TheFounderGroupsRealPlaces replays, and the real coordinate each must resolve to - see
// that test's own doc comment.
type plFounderGroupWant struct {
	location         string
	postCount        int
	wantLat, wantLng float64
}

func plFounderGroupWants() []plFounderGroupWant {
	return []plFounderGroupWant{
		{"Gaithersburg, United States", 25, 39.14344, -77.20137},
		{"Mathias, United States", 9, 38.87789, -78.86614},
		{"Washington, United States", 3, 38.89511, -77.03637},
		{"Columbia, United States", 3, 39.24038, -76.83942},
		{"Poolesville, United States", 2, 39.14594, -77.41693},
		{"Boyds, United States", 1, 39.18372, -77.31276},
		{"Dickerson, United States", 1, 39.2201, -77.42415},
		{"Moorefield, United States", 1, 39.06233, -78.96947},
		{"Rockville, United States", 1, 39.084, -77.15276},
		// Charles County, MD - not White Plains, NY (41.03399, -73.76291), which is the
		// wrong dot this exact group used to get; see this test's own doc comment.
		{"White Plains, United States", 1, 38.5904, -76.94025},
	}
}

// plFounderGroupRows expands want into postCount rows per location, oldest-location-first,
// mirroring one real self-hosted group's own posting history.
func plFounderGroupRows(want []plFounderGroupWant) []eventPostRow {
	var rows []eventPostRow
	postID := int64(1)
	for _, w := range want {
		for i := 0; i < w.postCount; i++ {
			rows = append(rows, plRow(postID, 1, w.location, plDay(60-int(postID), 9), 0, 0, nil))
			postID++
		}
	}
	return rows
}

// assertFounderPlace pins one want entry against buildPlaces' actual output for it - the
// per-place assertions TestBuildPlacesResolvesTheFounderGroupsRealPlaces runs inside its
// own t.Run subtests.
func assertFounderPlace(t *testing.T, byLoc map[string]Place, w plFounderGroupWant) {
	t.Helper()
	p, ok := byLoc[w.location]
	if !ok {
		t.Fatalf("place %q missing from buildPlaces output entirely", w.location)
	}
	if p.PostCount != w.postCount {
		t.Errorf("postCount = %d, want %d", p.PostCount, w.postCount)
	}
	if p.Lat == nil || p.Lng == nil {
		t.Fatalf("lat/lng = nil, want (%v, %v) - this place must now resolve", w.wantLat, w.wantLng)
	}
	if !nearlyEqual(*p.Lat, w.wantLat) || !nearlyEqual(*p.Lng, w.wantLng) {
		t.Errorf("resolved to (%v, %v), want (%v, %v)", *p.Lat, *p.Lng, w.wantLat, w.wantLng)
	}
}

func TestBuildPlacesResolvesTheFounderGroupsRealPlaces(t *testing.T) {
	want := plFounderGroupWants()
	rows := plFounderGroupRows(want)

	byLoc := placesByLocation(buildPlaces(rows, plNow, plCandidates(rows)))
	for _, w := range want {
		t.Run(w.location, func(t *testing.T) {
			assertFounderPlace(t, byLoc, w)
		})
	}
}

// TestAnchorCandidateDominanceRatio pins anchorCandidate's own boundary math directly,
// independent of any real gazetteer lookup - see its doc comment for the real-world
// numbers (Washington/Baltimore vs Boyds/Arlington/Great Falls) this ratio has to
// separate.
func TestAnchorCandidateDominanceRatio(t *testing.T) {
	cand := func(lat float64, population int) gazetteer.Candidate {
		return gazetteer.Candidate{Lat: lat, Lng: 0, Population: population}
	}
	cases := []struct {
		name       string
		candidates []gazetteer.Candidate
		wantOK     bool
		wantLat    float64
	}{
		{
			name:       "exactly at the ratio boundary qualifies",
			candidates: []gazetteer.Candidate{cand(1, 1000), cand(2, 100)}, // 10x exactly
			wantOK:     true,
			wantLat:    1,
		},
		{
			name:       "just under the ratio boundary does not qualify",
			candidates: []gazetteer.Candidate{cand(1, 999), cand(2, 100)}, // 9.99x
			wantOK:     false,
		},
		{
			name:       "every candidate at zero population never qualifies",
			candidates: []gazetteer.Candidate{cand(1, 0), cand(2, 0), cand(3, 0)},
			wantOK:     false,
		},
		{
			name: "one nonzero candidate below the absolute floor does not auto-qualify " +
				"(the Boyds, WA shape - a real but tiny population with nothing to meaningfully compare it to)",
			candidates: []gazetteer.Candidate{cand(1, 0), cand(2, 34), cand(3, 0), cand(4, 0)},
			wantOK:     false,
		},
		{
			name: "one nonzero candidate clearing the absolute floor auto-qualifies " +
				"(the Silver Spring, MD shape - a real substantial town with no rival to compute a ratio against at all)",
			candidates: []gazetteer.Candidate{cand(1, 71452), cand(2, 0), cand(3, 0)},
			wantOK:     true,
			wantLat:    1,
		},
		{
			name:       "an overwhelming real-world-shaped dominance qualifies (Washington, DC vs the next US Washington)",
			candidates: []gazetteer.Candidate{cand(1, 689545), cand(2, 24299)},
			wantOK:     true,
			wantLat:    1,
		},
		{
			name:       "a merely larger, non-dominant candidate does not qualify (Arlington, TX vs VA)",
			candidates: []gazetteer.Candidate{cand(1, 388125), cand(2, 208000)},
			wantOK:     false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := anchorCandidate(c.candidates)
			if ok != c.wantOK {
				t.Fatalf("ok = %v, want %v", ok, c.wantOK)
			}
			if ok && got.Lat != c.wantLat {
				t.Errorf("got lat %v, want %v", got.Lat, c.wantLat)
			}
		})
	}
}
