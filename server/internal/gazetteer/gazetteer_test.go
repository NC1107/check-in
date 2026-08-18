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

// TestResolveUnresolvablePlaceReturnsFalseNotAGuess is the CRITICAL HONESTY contract:
// a real place string this dataset simply has no row for - too small for cities15000's
// population/capital bar - must come back ok=false, never a fabricated or
// nearest-neighbor-guessed coordinate. Ocean City, MD (~7,000 year-round residents, no
// admin-seat status) is a real example from this app's own data that falls below that
// bar; see data/SOURCE.md.
func TestResolveUnresolvablePlaceReturnsFalseNotAGuess(t *testing.T) {
	lat, lng, ok := Resolve("Ocean City, United States")
	if ok {
		t.Fatalf("ok = true (lat=%v, lng=%v), want false - this dataset has no row for Ocean City, MD", lat, lng)
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
// GeoNames calls "New York City".
func TestResolveAliasFallback(t *testing.T) {
	lat, lng, ok := Resolve("New York, United States")
	if !ok {
		t.Fatal("ok = false, want true - New York City carries \"New York\" as an alternate name")
	}
	if lat != 40.71427 || lng != -74.00597 {
		t.Errorf("got (%v, %v), want New York City's coordinates", lat, lng)
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
