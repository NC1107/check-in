package db

import (
	"testing"
	"time"
)

// The cursor is opaque to the app, which means the server is the only thing that can get it
// wrong. A malformed one has to mean "start from the newest" rather than fail the request:
// it reaches us from a stale page, a hand-edited URL, or a client that kept a cursor across
// an upgrade, and none of those should leave a member looking at an error instead of their
// activity.
func TestActivityCursorRoundTrips(t *testing.T) {
	want := ActivityCursor{
		CreatedAt: time.Date(2026, 5, 1, 12, 30, 45, 123456000, time.UTC),
		Kind:      ActivityReply,
		SourceID:  4211,
	}
	got, ok := ParseActivityCursor(want.String())
	if !ok {
		t.Fatalf("a cursor this package produced did not parse: %q", want.String())
	}
	if !got.CreatedAt.Equal(want.CreatedAt) || got.Kind != want.Kind || got.SourceID != want.SourceID {
		t.Errorf("round trip = %+v, want %+v", got, want)
	}
}

// Sub-second precision has to survive, or two items in the same second become a tie the
// cursor cannot break and paging across them skips or repeats one.
func TestActivityCursorKeepsSubSecondPrecision(t *testing.T) {
	at := time.Date(2026, 5, 1, 12, 30, 45, 987654321, time.UTC)
	got, ok := ParseActivityCursor(ActivityCursor{CreatedAt: at, Kind: ActivityLike, SourceID: 1}.String())
	if !ok {
		t.Fatal("did not parse")
	}
	if !got.CreatedAt.Equal(at) {
		t.Errorf("createdAt = %v, want %v - nanoseconds were lost", got.CreatedAt, at)
	}
}

func TestParseActivityCursorRejectsRubbish(t *testing.T) {
	for _, raw := range []string{
		"",
		"garbage",
		"2026-05-01T12:00:00Z",                 // no kind, no id
		"2026-05-01T12:00:00Z|comment",         // no id
		"notatime|comment|5",                   // unparseable time
		"2026-05-01T12:00:00Z|comment|notanid", // unparseable id
		"2026-05-01T12:00:00Z|comment|5|extra", // too many parts
	} {
		if _, ok := ParseActivityCursor(raw); ok {
			t.Errorf("ParseActivityCursor(%q) reported success; a caller would then page "+
				"from a position it invented", raw)
		}
	}
}

// A cursor is a position, not a query: whatever is in the kind field is compared, never
// interpolated. This pins that a hostile value is simply a kind that matches nothing.
func TestParseActivityCursorTreatsKindAsData(t *testing.T) {
	got, ok := ParseActivityCursor("2026-05-01T12:00:00Z|' OR 1=1 --|5")
	if !ok {
		t.Fatal("a well-formed cursor with an odd kind should still parse")
	}
	if got.Kind != "' OR 1=1 --" {
		t.Errorf("kind = %q, want it carried through verbatim as data", got.Kind)
	}
}
