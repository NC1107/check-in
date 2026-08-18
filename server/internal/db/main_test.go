package db

import (
	"os"
	"testing"

	"github.com/nc1107/check-in/server/internal/gazetteer/gazetteertest"
)

// TestMain points every test in this package at the gazetteer's small, committed test
// fixture (see gazetteertest's own doc comment) rather than the real dataset, which is
// never committed to this repo and so is never present on a clean CI checkout -
// places_test.go's own plCandidates helper calls the real gazetteer.Candidates for every
// location a test uses, and without this, every one of those calls would silently answer
// "no match" in CI.
func TestMain(m *testing.M) {
	gazetteertest.UseFixture()
	os.Exit(m.Run())
}
