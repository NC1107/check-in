package api

import (
	"context"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

type placesResp struct {
	Places []db.Place `json:"places"`
}

func (h *harness) places(token string) placesResp {
	h.t.Helper()
	var got placesResp
	h.get("/api/memories/places", token).expect(http.StatusOK).decode(&got)
	return got
}

// TestPlacesReturnsDistinctLocations pins the happy path: two check-ins at the same real
// place collapse into one Place with the right aggregate counts.
func TestPlacesReturnsDistinctLocations(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-10*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-5*24*time.Hour))

	got := h.places(admin.Token)
	if len(got.Places) != 1 {
		t.Fatalf("got %d places, want 1", len(got.Places))
	}
	p := got.Places[0]
	if p.Location != "Lisbon, Portugal" {
		t.Errorf("location = %q, want Lisbon, Portugal", p.Location)
	}
	if p.PostCount != 2 {
		t.Errorf("postCount = %d, want 2", p.PostCount)
	}
	if p.PosterCount != 2 {
		t.Errorf("posterCount = %d, want 2", p.PosterCount)
	}
	if p.PhotoCount != 2 {
		t.Errorf("photoCount = %d, want 2 (both check-ins carried one photo each)", p.PhotoCount)
	}
	if p.CoverMediaID == nil {
		t.Error("coverMediaId = nil, want a cover - both posts carried a photo")
	}
}

// TestPlacesDisambiguatesArlingtonAndGreatFallsForADCGroup is the end-to-end regression
// test for the original defect, through the real HTTP round trip: a Washington-area
// group's own everyday check-ins (Baltimore, Silver Spring, Bethesda - each either
// unambiguous or population-dominant in the gazetteer, see buildPlaces' own doc comment)
// must anchor "Arlington, United States" and "Great Falls, United States" to real
// DC-area coordinates, not the more populous Arlington, Texas or Great Falls, Montana a
// population-only tiebreak would have picked.
func TestPlacesDisambiguatesArlingtonAndGreatFallsForADCGroup(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	now := time.Now()

	h.eventPost(admin, "Baltimore, United States", now.Add(-30*24*time.Hour))
	h.eventPost(admin, "Silver Spring, United States", now.Add(-25*24*time.Hour))
	h.eventPost(admin, "Bethesda, United States", now.Add(-20*24*time.Hour))
	h.eventPost(admin, "Arlington, United States", now.Add(-10*24*time.Hour))
	h.eventPost(admin, "Great Falls, United States", now.Add(-5*24*time.Hour))

	got := h.places(admin.Token)
	byLoc := make(map[string]db.Place, len(got.Places))
	for _, p := range got.Places {
		byLoc[p.Location] = p
	}

	arl := byLoc["Arlington, United States"]
	if arl.Lat == nil || arl.Lng == nil {
		t.Fatal("Arlington did not resolve")
	}
	if !nearlyEqualF(*arl.Lat, 38.88101) || !nearlyEqualF(*arl.Lng, -77.10428) {
		t.Errorf("Arlington = (%v, %v), want Arlington, VA (38.88101, -77.10428) - not the "+
			"more populous Arlington, TX (32.73569, -97.10807)", *arl.Lat, *arl.Lng)
	}

	gf := byLoc["Great Falls, United States"]
	if gf.Lat == nil || gf.Lng == nil {
		t.Fatal("Great Falls did not resolve")
	}
	// The DC-area Great Falls, on the Maryland side of the Potomac - a real GeoNames place
	// this dataset's own population-agnostic coverage now also carries alongside Great
	// Falls, VA (see gazetteer's own doc comment), and the one this anchor set actually
	// lands nearest.
	if !nearlyEqualF(*gf.Lat, 39.00233) || !nearlyEqualF(*gf.Lng, -77.24609) {
		t.Errorf("Great Falls = (%v, %v), want the DC-area Great Falls (39.00233, -77.24609) - not the "+
			"more populous Great Falls, MT (47.50024, -111.30081)", *gf.Lat, *gf.Lng)
	}
}

func nearlyEqualF(a, b float64) bool {
	d := a - b
	if d < 0 {
		d = -d
	}
	return d < 0.01
}

// TestPlacesResolvesRealCoordinates pins that a real, GeoNames-recognized place comes
// back with actual coordinates through the full HTTP round trip, not just at the pure
// buildPlaces layer.
func TestPlacesResolvesRealCoordinates(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.eventPost(admin, "Lisbon, Portugal", time.Now().Add(-3*24*time.Hour))

	got := h.places(admin.Token)
	if len(got.Places) != 1 {
		t.Fatalf("got %d places, want 1", len(got.Places))
	}
	p := got.Places[0]
	if p.Lat == nil || p.Lng == nil {
		t.Fatal("lat/lng = nil, want Lisbon's real coordinates")
	}
	if *p.Lat != 38.72509 || *p.Lng != -9.1498 {
		t.Errorf("got (%v, %v), want Lisbon's real GeoNames coordinates", *p.Lat, *p.Lng)
	}
}

// TestPlacesUnresolvablePlaceStillReturnedWithNilCoordinates pins the CRITICAL HONESTY
// contract at the wire level: a place the embedded gazetteer has no row for still comes
// back in the list, with lat/lng absent - never dropped, never a guessed pair of
// coordinates.
func TestPlacesUnresolvablePlaceStillReturnedWithNilCoordinates(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.eventPost(admin, "Nowhereville, Fictionland", time.Now().Add(-3*24*time.Hour))

	var env struct {
		Places []map[string]any `json:"places"`
	}
	h.get("/api/memories/places", admin.Token).expect(http.StatusOK).decode(&env)
	if len(env.Places) != 1 {
		t.Fatalf("got %d places, want 1 - an unresolvable place must still be listed", len(env.Places))
	}
	place := env.Places[0]
	if place["location"] != "Nowhereville, Fictionland" {
		t.Errorf("location = %v, want Nowhereville, Fictionland", place["location"])
	}
	if place["lat"] != nil {
		t.Errorf("lat = %v, want null - this dataset has no such place", place["lat"])
	}
	if place["lng"] != nil {
		t.Errorf("lng = %v, want null - this dataset has no such place", place["lng"])
	}
}

// TestPlacesExcludesRecapPosts pins the kind <> 'recap' predicate, exactly like the
// sibling events/timeline/forgotten endpoints.
func TestPlacesExcludesRecapPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-5*24*time.Hour))
	seedEventRecapPost(t, h, admin.ID, "Lisbon, Portugal", now.Add(-3*24*time.Hour))

	got := h.places(admin.Token)
	if len(got.Places) != 1 {
		t.Fatalf("got %d places, want 1", len(got.Places))
	}
	if got.Places[0].PostCount != 1 {
		t.Errorf("postCount = %d, want 1 - the recap post must not count", got.Places[0].PostCount)
	}
}

// TestPlacesExcludesBlockedAuthors pins that blocking a member removes their check-ins
// from the places pool too, exactly as it already does for the feed, RandomMemory and
// events.
func TestPlacesExcludesBlockedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-10*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-5*24*time.Hour))

	if got := h.places(admin.Token); got.Places[0].PostCount != 2 {
		t.Fatalf("postCount before blocking = %d, want 2", got.Places[0].PostCount)
	}

	h.post("/api/me/blocks/"+itoa(member.ID), admin.Token, nil).expect(http.StatusNoContent)

	got := h.places(admin.Token)
	if len(got.Places) != 1 {
		t.Fatalf("got %d places after blocking, want 1", len(got.Places))
	}
	if got.Places[0].PostCount != 1 {
		t.Errorf("postCount after blocking = %d, want 1 - the blocked member's check-in must "+
			"no longer count", got.Places[0].PostCount)
	}
}

// TestPlacesExcludesRevokedAuthors pins the other half of the author filter: a member an
// admin has since revoked takes their check-ins out of the pool too.
func TestPlacesExcludesRevokedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-10*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-5*24*time.Hour))

	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	got := h.places(admin.Token)
	if len(got.Places) != 1 {
		t.Fatalf("got %d places, want 1", len(got.Places))
	}
	if got.Places[0].PostCount != 1 {
		t.Errorf("postCount = %d, want 1 - the revoked member's check-in must no longer count",
			got.Places[0].PostCount)
	}
}

// TestPlacesEmptyResultForFreshGroup pins the clean-empty-result contract: 200 with
// places: [], never a 500 or an error envelope, for a group with no history at all.
func TestPlacesEmptyResultForFreshGroup(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	res := h.get("/api/memories/places", admin.Token)
	res.expect(http.StatusOK)
	var env struct {
		Places []db.Place `json:"places"`
	}
	res.decode(&env)
	if env.Places == nil {
		t.Fatal("places = nil, want an empty array (JSON []), not null")
	}
	if len(env.Places) != 0 {
		t.Fatalf("places = %+v, want none for a brand-new group with no history", env.Places)
	}
}

// TestPlacesAnyMemberMayCall pins that the endpoint is not admin-gated, the same as
// RandomMemory and events.
func TestPlacesAnyMemberMayCall(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	h.eventPost(member, "Lisbon, Portugal", time.Now().Add(-5*24*time.Hour))

	got := h.places(member.Token)
	if len(got.Places) != 1 {
		t.Fatalf("got %d places for a non-admin member, want 1 - the endpoint must not be "+
			"admin-only", len(got.Places))
	}
	_ = admin
}

// TestPlacesRequiresAuth pins that the route sits under requireAuth: no token, no answer.
func TestPlacesRequiresAuth(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	res := h.get("/api/memories/places", "")
	if res.Status != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 without a bearer token", res.Status)
	}
}

// TestPlacesRouteIsRateLimited drives the real route through the real router, the same
// way TestEventsRouteIsRateLimited exercises the sibling memories route.
func TestPlacesRouteIsRateLimited(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	burst := int(newContentLimits().places.burst)
	for i := 0; i < burst; i++ {
		h.get("/api/memories/places", admin.Token).expect(http.StatusOK)
	}
	res := h.get("/api/memories/places", admin.Token)
	if res.Status != http.StatusTooManyRequests {
		t.Fatalf("status past the burst = %d, want 429; body: %s", res.Status, res.Body)
	}
}

// TestServerInfoAdvertisesPlaces pins the capability flag a client gates the "Places" hub
// entry on - hidden entirely for a server old enough to 404 the route.
func TestServerInfoAdvertisesPlaces(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	var info map[string]any
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
	if v, _ := info["places"].(bool); !v {
		t.Errorf(`server-info["places"] = %v, want true`, info["places"])
	}
}

// TestPlacePostsReturnsThatPlacesOwnCheckIns pins the tap-through: opening a place
// returns exactly its own eligible check-ins, serialized like the feed.
func TestPlacePostsReturnsThatPlacesOwnCheckIns(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-10*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-5*24*time.Hour))
	h.eventPost(admin, "Denver, United States", now.Add(-3*24*time.Hour))

	var got struct {
		Posts   []db.Post `json:"posts"`
		HasMore bool      `json:"hasMore"`
	}
	h.get("/api/memories/places/photos?location="+url.QueryEscape("Lisbon, Portugal"), admin.Token).
		expect(http.StatusOK).decode(&got)
	if len(got.Posts) != 2 {
		t.Fatalf("got %d posts, want 2 (only Lisbon's own check-ins)", len(got.Posts))
	}
	if got.HasMore {
		t.Error("hasMore = true, want false - well under the cap")
	}
	for _, p := range got.Posts {
		if p.Location == nil || *p.Location != "Lisbon, Portugal" {
			t.Errorf("post %d location = %v, want Lisbon, Portugal", p.ID, p.Location)
		}
	}
}

// TestPlacePostsMatchesCaseAndWhitespaceVariants pins that PostsForPlace's normalized
// matching (not literal string equality) picks up a location string an on-device
// reverse geocoder rendered slightly differently across two members' phones - the exact
// reason PlacesForViewer itself groups by normalizeLocation rather than the raw string.
func TestPlacePostsMatchesCaseAndWhitespaceVariants(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-10*24*time.Hour))
	h.eventPost(member, "lisbon,  portugal", now.Add(-5*24*time.Hour))

	got := h.places(admin.Token)
	if len(got.Places) != 1 {
		t.Fatalf("got %d places, want 1 (both fold to the same place)", len(got.Places))
	}
	display := got.Places[0].Location

	var posts struct {
		Posts []db.Post `json:"posts"`
	}
	h.get("/api/memories/places/photos?location="+url.QueryEscape(display), admin.Token).
		expect(http.StatusOK).decode(&posts)
	if len(posts.Posts) != 2 {
		t.Fatalf("got %d posts, want 2 - both case/whitespace variants must match", len(posts.Posts))
	}
}

// TestPlacePostsMissingLocationIs400 pins that an absent location query param 400s
// outright rather than reaching the database.
func TestPlacePostsMissingLocationIs400(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	res := h.get("/api/memories/places/photos", admin.Token)
	if res.Status != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 with no location", res.Status)
	}
}

// TestPlacePostsUnknownLocationIsEmpty pins the honest-empty-state contract: a
// well-formed request for a place with no matching posts returns an empty array, not an
// error.
func TestPlacePostsUnknownLocationIsEmpty(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	var got struct {
		Posts []db.Post `json:"posts"`
	}
	h.get("/api/memories/places/photos?location="+url.QueryEscape("Nowhere, Nowhereland"), admin.Token).
		expect(http.StatusOK).decode(&got)
	if len(got.Posts) != 0 {
		t.Fatalf("got %d posts, want 0", len(got.Posts))
	}
}

// TestPlacesWireShapeHasTheKeysTheClientReads asserts the JSON keys the client's places
// view actually reads are present.
func TestPlacesWireShapeHasTheKeysTheClientReads(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.eventPost(admin, "Lisbon, Portugal", time.Now().Add(-5*24*time.Hour))

	var env struct {
		Places []map[string]any `json:"places"`
	}
	h.get("/api/memories/places", admin.Token).expect(http.StatusOK).decode(&env)
	if len(env.Places) != 1 {
		t.Fatalf("got %d places, want 1", len(env.Places))
	}
	place := env.Places[0]
	for _, key := range []string{
		"location", "lat", "lng", "postCount", "photoCount", "posterCount",
		"firstSeen", "lastSeen", "homeArea",
	} {
		if _, ok := place[key]; !ok {
			t.Errorf("place JSON missing key %q: %v", key, place)
		}
	}
	if _, ok := place["coverMediaId"]; !ok {
		t.Errorf("coverMediaId missing - the post carried a photo, so this must be present")
	}
}

// TestPlacesCachesGazetteerResolutionAndConsultsItNotJustWritesIt is the direct regression
// test for db.candidatesCached: the places gazetteer now lives on disk, not in RAM (see
// internal/gazetteer's own doc comment), and gazetteer_cache is what makes that disk read's
// latency irrelevant by only ever paying it once per distinct location. Writing to the
// cache alone would not prove it's actually being READ before falling through to a fresh
// disk lookup - so this seeds a deliberately WRONG cached answer after the real first
// resolution and asserts a second call returns that wrong answer, not the real one a fresh
// gazetteer lookup would give. That's the only way a test can tell "the cache is consulted
// first" apart from "the cache is just an audit trail written alongside every lookup".
func TestPlacesCachesGazetteerResolutionAndConsultsItNotJustWritesIt(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.eventPost(admin, "Lisbon, Portugal", time.Now().Add(-10*24*time.Hour))

	first := h.places(admin.Token)
	lisbon := first.Places[0]
	if lisbon.Lat == nil || *lisbon.Lat != 38.72509 || lisbon.Lng == nil || *lisbon.Lng != -9.1498 {
		t.Fatalf("first resolution = (%v, %v), want Lisbon's real gazetteer coordinates",
			lisbon.Lat, lisbon.Lng)
	}

	var cachedCount int
	if err := h.db.Pool.QueryRow(context.Background(),
		`SELECT count(*) FROM gazetteer_cache WHERE normalized_location = $1`, "lisbon, portugal",
	).Scan(&cachedCount); err != nil {
		t.Fatalf("check cache row: %v", err)
	}
	if cachedCount != 1 {
		t.Fatalf("gazetteer_cache rows for lisbon, portugal = %d, want 1 after the first resolution",
			cachedCount)
	}

	if _, err := h.db.Pool.Exec(context.Background(),
		`UPDATE gazetteer_cache SET candidates = $1 WHERE normalized_location = $2`,
		`[{"Lat":10,"Lng":20,"Population":1}]`, "lisbon, portugal",
	); err != nil {
		t.Fatalf("seed a deliberately wrong cached answer: %v", err)
	}

	second := h.places(admin.Token)
	lisbon2 := second.Places[0]
	if lisbon2.Lat == nil || *lisbon2.Lat != 10 || lisbon2.Lng == nil || *lisbon2.Lng != 20 {
		t.Errorf("second resolution = (%v, %v), want the deliberately-wrong cached (10, 20) - "+
			"the cache must be consulted before the gazetteer file, not merely written to",
			lisbon2.Lat, lisbon2.Lng)
	}
}

// TestPlacesCachesNegativeGazetteerResolution proves an unresolvable location's "no
// candidates" answer is cached too, exactly as a real one is - db.candidatesCached's own
// doc comment calls this out specifically: without it, a group's one typo'd or genuinely
// unresolvable historical location would re-scan the on-disk gazetteer file on every single
// future call to Places, forever, since a miss is the one case naively easy to forget to
// cache.
func TestPlacesCachesNegativeGazetteerResolution(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.eventPost(admin, "Nowhereville, Fictionland", time.Now().Add(-10*24*time.Hour))

	got := h.places(admin.Token)
	if len(got.Places) != 1 || got.Places[0].Lat != nil || got.Places[0].Lng != nil {
		t.Fatalf("got %+v, want one place with nil coordinates - this location cannot resolve",
			got.Places)
	}

	var payload []byte
	err := h.db.Pool.QueryRow(context.Background(),
		`SELECT candidates FROM gazetteer_cache WHERE normalized_location = $1`,
		"nowhereville, fictionland",
	).Scan(&payload)
	if err != nil {
		t.Fatalf("read cache row: %v", err)
	}
	if string(payload) != "null" {
		t.Errorf("cached candidates = %s, want the JSON null a nil []gazetteer.Candidate marshals "+
			"to - the negative result itself, not merely the absence of a row", payload)
	}
}
