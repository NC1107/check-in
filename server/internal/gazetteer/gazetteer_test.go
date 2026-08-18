package gazetteer

import "testing"

// TestResolveKnownCity pins the happy path against real GeoNames data: Lisbon's own
// stored coordinates, not an approximation.
func TestResolveKnownCity(t *testing.T) {
	lat, lng, ok := Resolve("Lisbon, Portugal")
	if !ok {
		t.Fatal("ok = false, want true - Lisbon is a national capital, comfortably above cities15000's bar")
	}
	// GeoNames' own reported coordinates for Lisbon (geonameid 2267057) - not rounded or
	// otherwise transformed, so this pins that Resolve returns the dataset's real value.
	if lat != 38.72509 || lng != -9.1498 {
		t.Errorf("got (%v, %v), want (38.72509, -9.1498)", lat, lng)
	}
}

// TestResolveCaseAndWhitespaceVariance pins that the same fold rule
// db.normalizeLocation applies to event clustering also lets this package match a
// location string an on-device reverse geocoder rendered with different casing or extra
// internal whitespace - see normalizeKey's own doc comment for why this has to hold.
func TestResolveCaseAndWhitespaceVariance(t *testing.T) {
	want := struct{ lat, lng float64 }{38.72509, -9.1498}
	variants := []string{
		"Lisbon, Portugal",
		"lisbon, portugal",
		"LISBON, PORTUGAL",
		"  Lisbon ,  Portugal  ",
		"Lisbon,   Portugal",
	}
	for _, v := range variants {
		lat, lng, ok := Resolve(v)
		if !ok {
			t.Errorf("Resolve(%q): ok = false, want true", v)
			continue
		}
		if lat != want.lat || lng != want.lng {
			t.Errorf("Resolve(%q) = (%v, %v), want (%v, %v)", v, lat, lng, want.lat, want.lng)
		}
	}
}

// TestResolveFullCountryName pins that country matching works off the full English name
// a post actually carries ("United States"), not an ISO code - the client and the
// content it reverse-geocodes never produce "US".
func TestResolveFullCountryName(t *testing.T) {
	lat, lng, ok := Resolve("Denver, United States")
	if !ok {
		t.Fatal("ok = false, want true")
	}
	if lat != 39.73915 || lng != -104.9847 {
		t.Errorf("got (%v, %v), want Denver's real GeoNames coordinates", lat, lng)
	}

	// An ISO code where the country name belongs must NOT match - proves this isn't
	// silently falling back to code matching.
	if _, _, ok := Resolve("Denver, US"); ok {
		t.Error(`Resolve("Denver, US") resolved - country matching must require the full name, not the ISO code`)
	}
}

// TestResolveUnknownCountry pins that a country name outside the embedded table (a typo,
// or a country this build's dataset genuinely has no entry for) reports ok=false rather
// than guessing at a country to search within.
func TestResolveUnknownCountry(t *testing.T) {
	if _, _, ok := Resolve("Anytown, Neverland"); ok {
		t.Error("ok = true for an unknown country, want false")
	}
}

// TestResolveNoLongerDropsSmallRealTowns is the direct regression test for this
// package's own dataset upgrade: Ocean City, MD (~7,000 year-round residents, no
// admin-seat status) used to be a real example, straight from this app's own data, of a
// place cities15000's population/capital bar silently dropped - see data/SOURCE.md for
// exactly why any population floor at all has that problem, worldwide, not just for this
// one town. It's real and it now resolves. Resolve's own population-only tiebreak (see
// its doc comment for why that's the deliberately crude baseline, not what production
// disambiguation actually uses) doesn't promise MD's Ocean City specifically out of the
// several same-named real US towns this dataset now also carries - only that SOME real
// coordinate comes back, not ok=false. See places_test.go's own
// TestBuildPlacesResolvesOceanCityToMarylandByProximity for the proximity-aware
// resolution a real group's history actually gets.
func TestResolveNoLongerDropsSmallRealTowns(t *testing.T) {
	lat, lng, ok := Resolve("Ocean City, United States")
	if !ok {
		t.Fatal("ok = false, want true - this dataset no longer has a population floor that drops real small towns")
	}
	if lat == 0 && lng == 0 {
		t.Error("lat=lng=0, want a real coordinate")
	}
}

// TestResolveUnresolvablePlaceReturnsFalseNotAGuess is the CRITICAL HONESTY contract:
// a location this dataset genuinely has no row for at all (not merely small - this
// package's dataset carries every GeoNames populated place regardless of population, see
// data/SOURCE.md - but a wholly fictional name still has nothing to match) must come back
// ok=false, never a fabricated or nearest-neighbor-guessed coordinate.
func TestResolveUnresolvablePlaceReturnsFalseNotAGuess(t *testing.T) {
	lat, lng, ok := Resolve("Quixnorpplestead, United States")
	if ok {
		t.Fatalf("ok = true (lat=%v, lng=%v), want false - this is not a real place", lat, lng)
	}
	if lat != 0 || lng != 0 {
		t.Errorf("lat=%v lng=%v on ok=false, want the zero value - callers must never read these", lat, lng)
	}
}

// TestResolveNoCommaReturnsFalse pins that a malformed (comma-less) location string -
// never produced by the app, but not something this package should ever be handed a
// panic by - fails closed rather than guessing at a split point.
func TestResolveNoCommaReturnsFalse(t *testing.T) {
	if _, _, ok := Resolve("Nowhere"); ok {
		t.Error("ok = true for a location with no comma, want false")
	}
	if _, _, ok := Resolve(""); ok {
		t.Error("ok = true for an empty location, want false")
	}
}

// TestResolveAmbiguousCityPicksLargerPopulation pins the deterministic disambiguation
// rule Resolve's own doc comment documents: more than one same-named, same-country place
// (Arlington, VA and Arlington, TX both being "Arlington, United States") breaks toward
// the larger population every time, not map iteration order.
func TestResolveAmbiguousCityPicksLargerPopulation(t *testing.T) {
	lat, lng, ok := Resolve("Arlington, United States")
	if !ok {
		t.Fatal("ok = false, want true")
	}
	// Arlington, TX (geonameid 4671654, pop ~388k) outpopulates Arlington, VA
	// (~208k) in this dataset - the tiebreak must land on TX's coordinates.
	if lat != 32.73569 || lng != -97.10807 {
		t.Errorf("got (%v, %v), want Arlington, TX's coordinates (the larger of the two real US Arlingtons)", lat, lng)
	}
}

// TestResolvePrefersOwnNameOverAlternateName pins that a row's own GeoNames name always
// outranks another row's mere alternate name, regardless of population - see Resolve's
// own doc comment for the Paterson/Great Falls example this guards against directly.
func TestResolvePrefersOwnNameOverAlternateName(t *testing.T) {
	lat, lng, ok := Resolve("Great Falls, United States")
	if !ok {
		t.Fatal("ok = false, want true")
	}
	// Great Falls, MT (pop ~59,638) is itself PRIMARILY named "Great Falls" and
	// outpopulates the other real Great Falls (VA, ~15,427) - both are legitimate
	// primary-tier matches. Paterson, NJ (pop ~147,754, built around a waterfall
	// historically called "the Great Falls") carries "Great Falls" only as an alternate
	// name in the real GeoNames data and must never win despite its larger population.
	if lat != 47.50024 || lng != -111.30081 {
		t.Errorf("got (%v, %v), want Great Falls, MT - not Paterson, NJ's alternate-name match", lat, lng)
	}
}

// TestResolveAliasFallback pins that a common English exonym GeoNames files only under
// alternatenames (never as a row's own name) still resolves - "New York" is the row
// GeoNames calls "New York City". This also exercises Candidates' own
// all-primary-candidates-are-zero-population merge (see its doc comment): this dataset's
// population-agnostic coverage means the US now has several genuine, unrelated,
// population-0 rural crossroads literally named "New York" - without that merge, their
// existence in the PRIMARY tier would silently block New York City's own alias match from
// ever being considered at all, which would have made this exact test fail.
func TestResolveAliasFallback(t *testing.T) {
	lat, lng, ok := Resolve("New York, United States")
	if !ok {
		t.Fatal("ok = false, want true - New York City carries \"New York\" as an alternate name")
	}
	if lat != 40.71427 || lng != -74.00597 {
		t.Errorf("got (%v, %v), want New York City's coordinates", lat, lng)
	}
}

// TestCandidatesMergesAliasWhenEveryPrimaryCandidateIsZeroPopulation pins the merge rule
// itself directly (see Candidates' own doc comment), independent of Resolve's population
// tiebreak: New York City (reachable here only via its "New York" alias) must actually be
// present in the candidate SET, not merely happen to win some other test's tiebreak.
func TestCandidatesMergesAliasWhenEveryPrimaryCandidateIsZeroPopulation(t *testing.T) {
	got := Candidates("New York, United States")
	var haveNYC bool
	for _, c := range got {
		if c.Lat == 40.71427 && c.Lng == -74.00597 {
			haveNYC = true
		}
	}
	if !haveNYC {
		t.Error("candidates missing New York City (40.71427, -74.00597) - the alias tier must be merged in " +
			"when every primary-tier \"New York\" is an unrelated, population-0 rural crossroads")
	}
}

// TestCandidatesNeverMergesAliasWhenAPrimaryCandidateHasPopulation is
// TestResolvePrefersOwnNameOverAlternateName's own counterpart at the Candidates level:
// Great Falls, MT carries a real, nonzero population as a PRIMARY match, so Paterson, NJ's
// merely-historical "Great Falls" alias must never even enter the candidate set, no matter
// how much larger Paterson's own population is.
func TestCandidatesNeverMergesAliasWhenAPrimaryCandidateHasPopulation(t *testing.T) {
	got := Candidates("Great Falls, United States")
	const patersonLat, patersonLng = 40.91677, -74.17181
	for _, c := range got {
		if c.Lat == patersonLat && c.Lng == patersonLng {
			t.Error("candidates include Paterson, NJ's merely historical \"Great Falls\" alias - " +
				"Great Falls, MT's own nonzero population must keep the primary tier exclusive")
		}
	}
}

// TestCandidatesReturnsAllMatchesNotJustOne pins the API db.buildPlaces actually calls:
// every real candidate for an ambiguous name, not Resolve's own population-reduced
// single winner - db.buildPlaces needs the full set to disambiguate by proximity to the
// group's own other places instead. This dataset carries every GeoNames-listed US place
// named Arlington regardless of population (see data/SOURCE.md), not just the handful
// large enough for the old cities15000 export - the count below is real, not a round
// number, and is expected to grow again if the embedded dataset is ever regenerated from
// a newer GeoNames export; what this test actually pins is that VA's and TX's real
// Arlingtons are always among whatever the full count turns out to be.
func TestCandidatesReturnsAllMatchesNotJustOne(t *testing.T) {
	got := Candidates("Arlington, United States")
	if len(got) < 2 {
		t.Fatalf("got %d candidates, want at least the real VA and TX Arlingtons", len(got))
	}
	var haveVA, haveTX bool
	for _, c := range got {
		if c.Lat == 38.88101 && c.Lng == -77.10428 {
			haveVA = true
		}
		if c.Lat == 32.73569 && c.Lng == -97.10807 {
			haveTX = true
		}
	}
	if !haveVA {
		t.Error("candidates missing Arlington, VA (38.88101, -77.10428)")
	}
	if !haveTX {
		t.Error("candidates missing Arlington, TX (32.73569, -97.10807)")
	}
}

// TestCandidatesNoLongerReturnsNilForSmallRealTowns mirrors
// TestResolveNoLongerDropsSmallRealTowns for the new API: Ocean City, MD used to come
// back nil under cities15000's population floor; this dataset has no such floor (see
// data/SOURCE.md) and returns real candidates instead.
func TestCandidatesNoLongerReturnsNilForSmallRealTowns(t *testing.T) {
	if Candidates("Ocean City, United States") == nil {
		t.Error("got nil, want real candidates - this dataset no longer has a population floor that drops real small towns")
	}
}

// TestCandidatesUnresolvablePlaceReturnsNil mirrors
// TestResolveUnresolvablePlaceReturnsFalseNotAGuess for the new API: no match is nil,
// not a fabricated single-element slice.
func TestCandidatesUnresolvablePlaceReturnsNil(t *testing.T) {
	if got := Candidates("Quixnorpplestead, United States"); got != nil {
		t.Errorf("got %v, want nil - this is not a real place", got)
	}
}

// TestCandidatesSingleMatchIsUnambiguous pins the other case db.buildPlaces relies on:
// a place with exactly one real-world candidate for its name+country comes back as a
// single-element slice, which is what buildPlaces treats as unambiguous enough to anchor
// on.
func TestCandidatesSingleMatchIsUnambiguous(t *testing.T) {
	got := Candidates("Lisbon, Portugal")
	if len(got) != 1 {
		t.Fatalf("got %d candidates, want 1", len(got))
	}
	if got[0].Lat != 38.72509 || got[0].Lng != -9.1498 {
		t.Errorf("got (%v, %v), want Lisbon's real GeoNames coordinates", got[0].Lat, got[0].Lng)
	}
}

// TestNormalizeKeyFoldsCaseAndWhitespace pins the fold rule itself in isolation from any
// dataset lookup.
func TestNormalizeKeyFoldsCaseAndWhitespace(t *testing.T) {
	cases := map[string]string{
		"Lisbon":          "lisbon",
		"  Lisbon  ":      "lisbon",
		"New   York":      "new york",
		"NEW\tYORK":       "new york",
		"":                "",
		"Great Falls, US": "great falls, us",
	}
	for in, want := range cases {
		if got := normalizeKey(in); got != want {
			t.Errorf("normalizeKey(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestCandidatesResolvesTheFounderGroupsRealPlaces is a table-driven regression test
// against the actual evidence this dataset upgrade was built to fix - ten real "City,
// Country" strings pulled from one real self-hosted group's own check-in history (see
// data/SOURCE.md). Five of them (Mathias, Poolesville, Boyds, Dickerson, Moorefield) came
// back with zero candidates at all under cities15000's population floor; White Plains
// resolved, but only ever to White Plains, NEW YORK, because White Plains, MARYLAND -
// twenty minutes from the rest of this same group - had no row at all for the proximity
// disambiguation in db/places.go to even consider. This test only pins that the CORRECT
// town's real coordinates are somewhere in the candidate set for each string; see
// places_test.go's own TestBuildPlacesResolvesTheFounderGroupsRealPlaces for the full
// proximity-aware pipeline actually picking each one out from the rest.
func TestCandidatesResolvesTheFounderGroupsRealPlaces(t *testing.T) {
	cases := []struct {
		location         string
		wantLat, wantLng float64
	}{
		{"Gaithersburg, United States", 39.14344, -77.20137},
		{"Mathias, United States", 38.87789, -78.86614},
		{"Washington, United States", 38.89511, -77.03637},
		{"Columbia, United States", 39.24038, -76.83942},
		{"Poolesville, United States", 39.14594, -77.41693},
		{"Boyds, United States", 39.18372, -77.31276},
		{"Dickerson, United States", 39.2201, -77.42415},
		{"Moorefield, United States", 39.06233, -78.96947},
		{"Rockville, United States", 39.084, -77.15276},
		// White Plains, Charles County, MD - not White Plains, NY (41.03399, -73.76291),
		// which is the wrong dot the old dataset produced (see this test's own doc
		// comment).
		{"White Plains, United States", 38.5904, -76.94025},
	}
	for _, c := range cases {
		t.Run(c.location, func(t *testing.T) {
			got := Candidates(c.location)
			if got == nil {
				t.Fatalf("Candidates(%q) = nil, want at least one candidate", c.location)
			}
			for _, cand := range got {
				if cand.Lat == c.wantLat && cand.Lng == c.wantLng {
					return
				}
			}
			t.Errorf("Candidates(%q) missing (%v, %v)", c.location, c.wantLat, c.wantLng)
		})
	}
}
