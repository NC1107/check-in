package api

import (
	"os"
	"testing"

	"github.com/nc1107/check-in/server/internal/gazetteer/gazetteertest"
)

// TestMain points every test in this package at the gazetteer's small, committed test
// fixture (see gazetteertest's own doc comment) rather than the real dataset, which is
// never committed to this repo and so is never present on a clean CI checkout - several
// tests here (places_handlers_test.go in particular) go through the real HTTP handler ->
// db.PlacesForViewer -> gazetteer.Candidates path with a real "City, Country" location
// string and no stored coordinates, and without this would silently resolve to nothing at
// all in CI.
func TestMain(m *testing.M) {
	gazetteertest.UseFixture()
	os.Exit(m.Run())
}
