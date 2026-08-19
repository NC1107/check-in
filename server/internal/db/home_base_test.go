package db

import (
	"testing"
	"time"
)

// bestHomeLocation's tiebreak had no coverage: inverting it to prefer the largest key left
// the suite green. It exists so the result cannot depend on Go's unspecified map iteration
// order, which is exactly the kind of rule that has to be pinned rather than assumed.

func daySet(days ...int) map[time.Time]bool {
	set := make(map[time.Time]bool, len(days))
	for _, d := range days {
		set[time.Date(2026, 3, d, 0, 0, 0, 0, time.UTC)] = true
	}
	return set
}

func TestBestHomeLocationPicksMostDistinctDays(t *testing.T) {
	loc, n := bestHomeLocation(map[string]map[time.Time]bool{
		"denver":    daySet(1, 2, 3),
		"baltimore": daySet(1, 2, 3, 4, 5),
	})
	if loc != "baltimore" || n != 5 {
		t.Errorf("got (%q, %d), want (\"baltimore\", 5)", loc, n)
	}
}

// A tie must resolve to the lexicographically smallest key, every time, whatever order the
// map happens to be walked in.
func TestBestHomeLocationTieBreaksToSmallestKey(t *testing.T) {
	byLoc := map[string]map[time.Time]bool{
		"denver":    daySet(1, 2, 3),
		"baltimore": daySet(4, 5, 6),
		"chicago":   daySet(7, 8, 9),
	}
	for i := 0; i < 50; i++ {
		loc, n := bestHomeLocation(byLoc)
		if loc != "baltimore" || n != 3 {
			t.Fatalf("run %d got (%q, %d), want (\"baltimore\", 3)", i, loc, n)
		}
	}
}

// Below homeBaseMinDays nothing is a home base, so a place visited once or twice never
// gets treated as where someone lives.
func TestBestHomeLocationRequiresMinimumDays(t *testing.T) {
	for _, tc := range []struct {
		days      int
		qualifies bool
	}{{1, false}, {2, false}, {3, true}, {9, true}} {
		set := make(map[time.Time]bool)
		for d := 1; d <= tc.days; d++ {
			set[time.Date(2026, 3, d, 0, 0, 0, 0, time.UTC)] = true
		}
		_, n := bestHomeLocation(map[string]map[time.Time]bool{"denver": set})
		if got := n > 0; got != tc.qualifies {
			t.Errorf("%d distinct days: qualifies = %v, want %v", tc.days, got, tc.qualifies)
		}
	}
}

func TestBestHomeLocationEmpty(t *testing.T) {
	if _, n := bestHomeLocation(map[string]map[time.Time]bool{}); n != 0 {
		t.Errorf("count = %d, want 0", n)
	}
}

// Distinct days, not post count - one busy afternoon must not look like living somewhere.
func TestTallyDaysCountsDistinctDaysNotPosts(t *testing.T) {
	day := time.Date(2026, 3, 10, 0, 0, 0, 0, time.UTC)
	rows := []eventPostRow{
		{AuthorID: 1, Location: "Denver", CreatedAt: day.Add(9 * time.Hour)},
		{AuthorID: 1, Location: "Denver", CreatedAt: day.Add(13 * time.Hour)},
		{AuthorID: 1, Location: "Denver", CreatedAt: day.Add(20 * time.Hour)},
	}
	got := tallyDaysByAuthorLocation(rows, day.AddDate(0, -6, 0))
	if n := len(got[1][normalizeLocation("Denver")]); n != 1 {
		t.Errorf("distinct days = %d, want 1 from three posts on one day", n)
	}
}

// Rows older than the cutoff are ignored, so somewhere lived last year does not stay home.
func TestTallyDaysIgnoresRowsBeforeCutoff(t *testing.T) {
	cutoff := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
	rows := []eventPostRow{
		{AuthorID: 1, Location: "Denver", CreatedAt: cutoff.AddDate(0, 0, -1)},
		{AuthorID: 1, Location: "Denver", CreatedAt: cutoff.AddDate(0, 0, 5)},
	}
	got := tallyDaysByAuthorLocation(rows, cutoff)
	if n := len(got[1][normalizeLocation("Denver")]); n != 1 {
		t.Errorf("distinct days = %d, want 1 (the older row is outside the window)", n)
	}
}

// mostCommonKey is the one place this file's deterministic-tiebreak convention lives, used
// by both bestHomeLocation and displayLocation.
func TestMostCommonKey(t *testing.T) {
	got, n := mostCommonKey(map[string]int{"a": 1, "b": 5, "c": 3})
	if got != "b" || n != 5 {
		t.Errorf("got (%q, %d), want (\"b\", 5)", got, n)
	}
	if _, n := mostCommonKey(map[string]int{}); n != 0 {
		t.Errorf("empty map count = %d, want 0", n)
	}
}

func TestMostCommonKeyTieIsStable(t *testing.T) {
	counts := map[string]int{"denver": 2, "baltimore": 2, "chicago": 2}
	for i := 0; i < 50; i++ {
		if got, _ := mostCommonKey(counts); got != "baltimore" {
			t.Fatalf("run %d got %q, want \"baltimore\" (smallest key)", i, got)
		}
	}
}

// displayLocation shows the most common ORIGINAL string even though rows were grouped by
// the case-folded key, so members see the shape they actually typed.
func TestDisplayLocationPicksMostCommonOriginal(t *testing.T) {
	run := []eventPostRow{
		{Location: "Lisbon, Portugal"},
		{Location: "Lisbon, Portugal"},
		{Location: "lisbon, portugal"},
	}
	if got := displayLocation(run); got != "Lisbon, Portugal" {
		t.Errorf("displayLocation = %q, want \"Lisbon, Portugal\"", got)
	}
}

func TestDisplayLocationTieIsStable(t *testing.T) {
	run := []eventPostRow{{Location: "Ocean City"}, {Location: "Great Falls"}}
	for i := 0; i < 50; i++ {
		if got := displayLocation(run); got != "Great Falls" {
			t.Fatalf("run %d got %q, want \"Great Falls\" (smallest key)", i, got)
		}
	}
}
