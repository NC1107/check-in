// Package gazetteertest points the gazetteer package at its own small, committed test
// fixture (see ../data/testdata/fixture.bin and make_fixture.py's own doc comment for
// exactly what it covers and why) instead of the real, several-million-row dataset - which
// is never committed to this repo at all (fetched and packed at Docker build time, see
// ../data/SOURCE.md), so a clean CI checkout has no dataset for gazetteer.Candidates/
// Resolve to answer real coordinates from without this.
//
// Every package whose tests exercise gazetteer resolution - this package's own sibling
// gazetteer_test.go, internal/db, internal/api - calls UseFixture from a TestMain, once,
// before any test in that package's binary runs, so the resolution rules (proximity,
// anchors, aliases, tiering, population dominance) are always exercised in CI regardless
// of whether a developer has also run fetch_and_pack.sh locally. Kept as its own tiny
// package rather than an exported function on gazetteer itself, so gazetteer's own public
// API surface - what a real caller like internal/db actually depends on - carries no
// test-only concern at all.
package gazetteertest

import (
	"path/filepath"
	"runtime"

	"github.com/nc1107/check-in/server/internal/gazetteer"
)

// FixturePath is the committed test fixture's own absolute path, resolved relative to this
// source file's own location (not the process's working directory, which differs between
// `go test`, a local `go run`, and CI) - the same reasoning gazetteer.go's own
// defaultDataDir already documents.
func FixturePath() string {
	_, thisFile, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(thisFile), "..", "data", "testdata", "fixture.bin")
}

// UseFixture points every future gazetteer.Candidates/Resolve call, for the rest of this
// process, at the committed fixture instead of gazetteer's own default data path. Call
// this once, from a TestMain, before m.Run() - gazetteer's own lazy sync.Once init means a
// call after the first real query would silently do nothing (see
// gazetteer.SetDataPath's own doc comment), and a bare `go test` invocation (no TestMain
// intervention at all) would otherwise fall through to whatever - if anything - happens to
// be sitting at the real default path, which is exactly the "only passes on a machine that
// happens to have the full dataset built locally" failure mode this package exists to
// close off. Safe to call even when a real, full dataset also happens to be present
// locally: the fixture always wins for a test binary that calls this, so test behavior
// never depends on what a given machine happens to have lying around.
func UseFixture() {
	gazetteer.SetDataPath(FixturePath())
}
