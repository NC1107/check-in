// package gazetteer_test (external), not gazetteer: gazetteertest itself imports the plain
// gazetteer package, so a TestMain needing gazetteertest can't live in an internal test
// file (package gazetteer) without creating an import cycle - see gazetteer_test.go for
// this package's own internal-access tests, which don't have that constraint since they
// need no import of gazetteertest themselves. Go happily runs both an internal and an
// external test file's tests in the same `go test` invocation and binary, with TestMain
// (there can only be one) living in either.
package gazetteer_test

import (
	"os"
	"testing"

	"github.com/nc1107/check-in/server/internal/gazetteer/gazetteertest"
)

// TestMain points every test in this package at the small, committed test fixture (see
// gazetteertest's own doc comment) rather than the real dataset, which is never committed
// to this repo and so is never present on a clean CI checkout - see
// data/testdata/make_fixture.py for exactly what that fixture covers and why.
func TestMain(m *testing.M) {
	gazetteertest.UseFixture()
	os.Exit(m.Run())
}
