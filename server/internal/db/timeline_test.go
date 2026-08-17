package db

import (
	"reflect"
	"testing"
	"time"
)

func i64p(v int64) *int64 { return &v }

// TestBucketTimelineLocalMidnightBoundary pins the whole point of MONTH BUCKETING: two
// posts an hour apart, straddling local midnight on the last day of a month, land in
// different months when time.Local is a zone with a positive UTC offset (so the local
// evening posts sits well before UTC midnight, but the local midnight rollover has already
// happened) - a raw-UTC bucketing would put both in the same UTC calendar day/month and
// silently lump the second post into the wrong bucket.
func TestBucketTimelineLocalMidnightBoundary(t *testing.T) {
	loc, err := time.LoadLocation("Asia/Tokyo") // UTC+9, no DST - a stable fixture
	if err != nil {
		t.Skipf("tzdata unavailable: %v", err)
	}
	restore := setTestLocal(loc)
	defer restore()

	// 22:30 local July 31 → 13:30 UTC July 31 (still July in UTC too, so this pins the
	// "convert before bucketing" behavior generally, not just the exact boundary).
	beforeMidnight := time.Date(2026, time.July, 31, 13, 30, 0, 0, time.UTC)
	// 00:30 local August 1 → 15:30 UTC July 31 - still July 31 in UTC, which is exactly the
	// case a naive UTC bucketing would get wrong: this post is already August for anyone in
	// this time zone.
	afterMidnight := time.Date(2026, time.July, 31, 15, 30, 0, 0, time.UTC)

	rows := []timelinePostRow{
		{PostID: 1, AuthorID: 1, CreatedAt: beforeMidnight},
		{PostID: 2, AuthorID: 1, CreatedAt: afterMidnight},
	}
	months := bucketTimeline(rows)
	if len(months) != 2 {
		t.Fatalf("got %d months, want 2 (July and August); months: %+v", len(months), months)
	}
	// Newest first.
	if months[0].Year != 2026 || months[0].Month != 8 {
		t.Errorf("months[0] = %d-%02d, want 2026-08 (newest first)", months[0].Year, months[0].Month)
	}
	if months[1].Year != 2026 || months[1].Month != 7 {
		t.Errorf("months[1] = %d-%02d, want 2026-07", months[1].Year, months[1].Month)
	}
	if months[0].PostCount != 1 || months[1].PostCount != 1 {
		t.Errorf("post counts = %d, %d, want 1 and 1 - the local-midnight post must not double up "+
			"in either bucket", months[0].PostCount, months[1].PostCount)
	}
}

// TestBucketTimelineYearBoundary pins the year rollover: a post just before and just after
// local New Year's midnight land in December of one year and January of the next,
// respectively, not the same bucket.
func TestBucketTimelineYearBoundary(t *testing.T) {
	loc, err := time.LoadLocation("Asia/Tokyo")
	if err != nil {
		t.Skipf("tzdata unavailable: %v", err)
	}
	restore := setTestLocal(loc)
	defer restore()

	// 23:00 local Dec 31 2026 → 14:00 UTC Dec 31 2026.
	dec := time.Date(2026, time.December, 31, 14, 0, 0, 0, time.UTC)
	// 01:00 local Jan 1 2027 → 16:00 UTC Dec 31 2026 - still Dec 31 in UTC.
	jan := time.Date(2026, time.December, 31, 16, 0, 0, 0, time.UTC)

	rows := []timelinePostRow{
		{PostID: 1, AuthorID: 1, CreatedAt: dec},
		{PostID: 2, AuthorID: 1, CreatedAt: jan},
	}
	months := bucketTimeline(rows)
	if len(months) != 2 {
		t.Fatalf("got %d months, want 2 (Dec 2026 and Jan 2027); months: %+v", len(months), months)
	}
	if months[0].Year != 2027 || months[0].Month != 1 {
		t.Errorf("months[0] = %d-%02d, want 2027-01 (newest first, across the year boundary)",
			months[0].Year, months[0].Month)
	}
	if months[1].Year != 2026 || months[1].Month != 12 {
		t.Errorf("months[1] = %d-%02d, want 2026-12", months[1].Year, months[1].Month)
	}
}

// TestBuildTimelineMonthStats pins the per-month aggregation: post/photo/clip/place/poster
// counts all computed correctly over a mixed run.
func TestBuildTimelineMonthStats(t *testing.T) {
	k := timelineKey{year: 2026, month: 8}
	run := []timelinePostRow{
		{PostID: 1, AuthorID: 1, Location: "Lisbon, Portugal", PhotoCount: 2, ClipCount: 0, LikeCount: 3, CoverMediaID: i64p(101)},
		{PostID: 2, AuthorID: 2, Location: "Lisbon, Portugal", PhotoCount: 1, ClipCount: 1, LikeCount: 5, CoverMediaID: i64p(102)},
		{PostID: 3, AuthorID: 1, Location: "Porto, Portugal", PhotoCount: 0, ClipCount: 0, LikeCount: 0},
		{PostID: 4, AuthorID: 3, Location: "", PhotoCount: 1, ClipCount: 0, LikeCount: 1, CoverMediaID: i64p(104)},
	}
	m := buildTimelineMonth(k, run)
	if m.PostCount != 4 {
		t.Errorf("postCount = %d, want 4", m.PostCount)
	}
	if m.PhotoCount != 4 {
		t.Errorf("photoCount = %d, want 4 (2+1+0+1)", m.PhotoCount)
	}
	if m.ClipCount != 1 {
		t.Errorf("clipCount = %d, want 1", m.ClipCount)
	}
	if m.PlaceCount != 2 {
		t.Errorf("placeCount = %d, want 2 (Lisbon, Porto - the empty location must not count as a "+
			"place)", m.PlaceCount)
	}
	if m.PosterCount != 3 {
		t.Errorf("posterCount = %d, want 3 distinct authors", m.PosterCount)
	}
}

// TestBuildTimelineMonthCoverOrdering pins the cover-pick rule: most-liked first, ties
// broken toward the earlier post id, capped at timelineCoverCap, and a post with no image
// never contributes a slot.
func TestBuildTimelineMonthCoverOrdering(t *testing.T) {
	k := timelineKey{year: 2026, month: 8}
	run := []timelinePostRow{
		{PostID: 1, AuthorID: 1, LikeCount: 1, CoverMediaID: i64p(11)},
		{PostID: 2, AuthorID: 1, LikeCount: 9, CoverMediaID: i64p(12)},
		{PostID: 3, AuthorID: 1, LikeCount: 9, CoverMediaID: i64p(13)}, // ties post 2 on likes
		{PostID: 4, AuthorID: 1, LikeCount: 5},                         // no image: contributes no cover
		{PostID: 5, AuthorID: 1, LikeCount: 3, CoverMediaID: i64p(15)},
		{PostID: 6, AuthorID: 1, LikeCount: 2, CoverMediaID: i64p(16)},
	}
	m := buildTimelineMonth(k, run)
	want := []int64{12, 13, 15, 16, 11} // 9(id2) before 9(id3) on the id tiebreak, then desc likes
	if !reflect.DeepEqual(m.CoverMediaIDs, want) {
		t.Errorf("coverMediaIds = %v, want %v", m.CoverMediaIDs, want)
	}
}

// TestBuildTimelineMonthCoverCap pins the hard cap: more eligible covers than
// timelineCoverCap still returns only the top timelineCoverCap.
func TestBuildTimelineMonthCoverCap(t *testing.T) {
	k := timelineKey{year: 2026, month: 8}
	var run []timelinePostRow
	for i := int64(1); i <= 8; i++ {
		run = append(run, timelinePostRow{PostID: i, AuthorID: 1, LikeCount: int(i), CoverMediaID: i64p(i * 100)})
	}
	m := buildTimelineMonth(k, run)
	if len(m.CoverMediaIDs) != timelineCoverCap {
		t.Fatalf("len(coverMediaIds) = %d, want %d", len(m.CoverMediaIDs), timelineCoverCap)
	}
	if m.CoverMediaIDs[0] != 800 {
		t.Errorf("coverMediaIds[0] = %d, want 800 (post 8's cover, the most-liked)", m.CoverMediaIDs[0])
	}
}

// TestBucketTimelineOmitsEmptyMonths pins that a month with no eligible rows never appears
// at all - there is no zeroed placeholder for the client to render.
func TestBucketTimelineOmitsEmptyMonths(t *testing.T) {
	loc, err := time.LoadLocation("UTC")
	if err != nil {
		t.Fatalf("load UTC: %v", err)
	}
	restore := setTestLocal(loc)
	defer restore()

	rows := []timelinePostRow{
		{PostID: 1, AuthorID: 1, CreatedAt: time.Date(2026, time.August, 15, 12, 0, 0, 0, time.UTC)},
	}
	months := bucketTimeline(rows)
	if len(months) != 1 {
		t.Fatalf("got %d months, want exactly 1 - no June/July placeholder for the gap", len(months))
	}
	if months[0].Month != 8 {
		t.Errorf("month = %d, want 8", months[0].Month)
	}

	// The empty-input case too: no rows at all → no months, not a nil-vs-empty-slice trap
	// for the handler's json envelope.
	if got := bucketTimeline(nil); len(got) != 0 {
		t.Errorf("bucketTimeline(nil) = %+v, want empty", got)
	}
}

// setTestLocal swaps time.Local for the duration of a test and returns a restore func.
// bucketTimeline (and TimelineMonthPosts) deliberately read the package-level time.Local
// rather than taking a *time.Location parameter, mirroring how the real server picks it up
// once at process start from the TZ environment variable - so a test that wants to pin a
// specific zone has to swap the same package variable the production code reads.
func setTestLocal(loc *time.Location) (restore func()) {
	prev := time.Local
	time.Local = loc
	return func() { time.Local = prev }
}
