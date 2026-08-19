package api

import (
	"fmt"
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
	requireTestDB()
	code := m.Run()
	// The two-server tests create a second database on the same Postgres. Dropped here
	// rather than in a t.Cleanup because its pool is shared by every test that asked for
	// one - and dropped even when the run failed, so a red suite never leaves a stray
	// database behind for the next one to inherit. os.Exit skips deferred functions, so
	// this cannot be a defer.
	dropSecondTestDB()
	os.Exit(code)
}

// skipOptOutEnv lets a machine with no Postgres run what it can, deliberately.
const skipOptOutEnv = "CHECKIN_SKIP_DB_TESTS"

// requireTestDB refuses to run this package as a no-op.
//
// Most tests here need a database and skip themselves without one (see harness_test.go).
// A t.Skip is invisible without -v, and `go test` discards a passing package's output
// entirely, so a plain `go test ./...` printed a reassuring "ok" while the large majority of
// the suite never executed. That is not hypothetical: a real scan-order bug survived a full
// local run that way during development, and was caught only by hand against a live server.
//
// So the skip has to be chosen rather than defaulted. Either point the tests at a database,
// or say out loud that you are running without one. CI always sets TESTDB_URL, so this only
// ever fires on a developer machine.
func requireTestDB() {
	if os.Getenv(testDBEnv) != "" || os.Getenv(skipOptOutEnv) != "" {
		return
	}
	fmt.Fprintf(os.Stderr, `
%[1]s is not set, so the DB-backed handler tests would SKIP - and a skipped
suite still prints "ok", which is how a real bug once slipped through a clean local run.

Run the full suite (starts a throwaway Postgres in Docker, then removes it):

    server/scripts/test.sh

Or, to run only the pure-unit tests and accept that the rest are not running:

    %[2]s=1 go test ./...
`, testDBEnv, skipOptOutEnv)
	os.Exit(1)
}
