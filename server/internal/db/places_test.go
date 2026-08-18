package db

import (
	"testing"
	"time"
)

// plNow mirrors events_cluster_test.go's evNow: a fixed "current time" so home-area
// window math is exact and doesn't depend on when the suite runs.
var plNow = time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)

func plDay(daysAgo int, hour int) time.Time {
	d := plNow.AddDate(0, 0, -daysAgo)
	return time.Date(d.Year(), d.Month(), d.Day(), hour, 0, 0, 0, time.UTC)
}

// plRow builds an eventPostRow with every field buildPlace/buildPlaces reads - evRow
// (events_cluster_test.go) only sets the subset detectEvents itself needs.
func plRow(postID, authorID int64, loc string, when time.Time, likeCount, photoCount int, cover *int64) eventPostRow {
	return eventPostRow{
		PostID:       postID,
		AuthorID:     authorID,
		AuthorName:   "Author",
		Location:     loc,
		CreatedAt:    when,
		LikeCount:    likeCount,
		PhotoCount:   photoCount,
		CoverMediaID: cover,
	}
}

// mid (test helper for a *int64 literal) already exists package-wide - see
// recap_select_test.go.

// TestBuildPlacesAggregatesOnePlace pins the core aggregation: post/photo/poster counts,
// first/last seen, and the display string picked from the group's own rows.
func TestBuildPlacesAggregatesOnePlace(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Lisbon, Portugal", plDay(10, 9), 2, 1, mid(101)),
		plRow(2, 2, "Lisbon, Portugal", plDay(5, 9), 5, 2, mid(102)),
	}
	places := buildPlaces(rows, plNow)
	if len(places) != 1 {
		t.Fatalf("got %d places, want 1", len(places))
	}
	p := places[0]
	if p.Location != "Lisbon, Portugal" {
		t.Errorf("location = %q, want %q", p.Location, "Lisbon, Portugal")
	}
	if p.PostCount != 2 {
		t.Errorf("postCount = %d, want 2", p.PostCount)
	}
	if p.PhotoCount != 3 {
		t.Errorf("photoCount = %d, want 3 (1+2)", p.PhotoCount)
	}
	if p.PosterCount != 2 {
		t.Errorf("posterCount = %d, want 2 distinct authors", p.PosterCount)
	}
	if !p.FirstSeen.Equal(plDay(10, 9)) {
		t.Errorf("firstSeen = %v, want %v", p.FirstSeen, plDay(10, 9))
	}
	if !p.LastSeen.Equal(plDay(5, 9)) {
		t.Errorf("lastSeen = %v, want %v", p.LastSeen, plDay(5, 9))
	}
}

// TestBuildPlacesCoverPicksMostLikedTieBreaksLowerPostID pins the same cover-pick
// convention buildEvent uses: highest like count wins, a tie breaks toward the earlier
// post id.
func TestBuildPlacesCoverPicksMostLikedTieBreaksLowerPostID(t *testing.T) {
	rows := []eventPostRow{
		plRow(5, 1, "Denver, United States", plDay(3, 9), 3, 1, mid(500)),
		plRow(2, 1, "Denver, United States", plDay(2, 9), 3, 1, mid(200)), // same likes, lower id
		plRow(9, 1, "Denver, United States", plDay(1, 9), 1, 1, mid(900)), // fewer likes
	}
	places := buildPlaces(rows, plNow)
	if len(places) != 1 {
		t.Fatalf("got %d places, want 1", len(places))
	}
	if places[0].CoverMediaID == nil || *places[0].CoverMediaID != 200 {
		t.Errorf("coverMediaId = %v, want 200 (tied top likes, lower post id)", places[0].CoverMediaID)
	}
}

// TestBuildPlacesCoverNilWhenNothingHasAPhoto pins that an all-text place carries no
// cover rather than a zero-value media id.
func TestBuildPlacesCoverNilWhenNothingHasAPhoto(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Denver, United States", plDay(3, 9), 3, 0, nil),
	}
	places := buildPlaces(rows, plNow)
	if places[0].CoverMediaID != nil {
		t.Errorf("coverMediaId = %v, want nil - no row here carried a photo", places[0].CoverMediaID)
	}
}

// TestBuildPlacesOrdersByPostCountDesc pins the primary ranking rule: most check-ins
// first.
func TestBuildPlacesOrdersByPostCountDesc(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Denver, United States", plDay(10, 9), 0, 0, nil),
		plRow(2, 1, "Lisbon, Portugal", plDay(9, 9), 0, 0, nil),
		plRow(3, 2, "Lisbon, Portugal", plDay(8, 9), 0, 0, nil),
		plRow(4, 3, "Lisbon, Portugal", plDay(7, 9), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow)
	if len(places) != 2 {
		t.Fatalf("got %d places, want 2", len(places))
	}
	if places[0].Location != "Lisbon, Portugal" || places[0].PostCount != 3 {
		t.Errorf("first place = %q (count %d), want Lisbon, Portugal with 3 posts",
			places[0].Location, places[0].PostCount)
	}
	if places[1].Location != "Denver, United States" || places[1].PostCount != 1 {
		t.Errorf("second place = %q (count %d), want Denver, United States with 1 post",
			places[1].Location, places[1].PostCount)
	}
}

// TestBuildPlacesTieBreaksByLastSeenThenLocation pins the deterministic tiebreak below
// post count: more recent activity first, then the display string.
func TestBuildPlacesTieBreaksByLastSeenThenLocation(t *testing.T) {
	rows := []eventPostRow{
		// Both places have exactly 1 post - Denver's is more recent.
		plRow(1, 1, "Lisbon, Portugal", plDay(20, 9), 0, 0, nil),
		plRow(2, 1, "Denver, United States", plDay(5, 9), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow)
	if places[0].Location != "Denver, United States" {
		t.Errorf("first place = %q, want Denver, United States (more recent lastSeen)", places[0].Location)
	}

	// Same post count, same lastSeen instant - falls back to the display string.
	same := plDay(1, 9)
	tied := []eventPostRow{
		plRow(1, 1, "Zurich, Switzerland", same, 0, 0, nil),
		plRow(2, 1, "Austin, United States", same, 0, 0, nil),
	}
	tiedPlaces := buildPlaces(tied, plNow)
	if tiedPlaces[0].Location != "Austin, United States" {
		t.Errorf("first place = %q, want Austin, United States (alphabetically first)", tiedPlaces[0].Location)
	}
}

// TestBuildPlacesReusesHomeAreaLogic pins that HomeArea is computed by
// computeHomeArea - the same events_cluster.go logic EventsForViewer's own trip/gathering
// detection already relies on - not a second, independently-tuned definition.
func TestBuildPlacesReusesHomeAreaLogic(t *testing.T) {
	// Three separate episodes across two distinct members clears computeHomeArea's own
	// bar (homeAreaMinEpisodes=3, homeAreaMinMembers=2) - see events_cluster.go.
	rows := []eventPostRow{
		plRow(1, 1, "Austin, United States", plDay(150, 9), 0, 0, nil),
		plRow(2, 2, "Austin, United States", plDay(150, 10), 0, 0, nil),
		plRow(3, 1, "Austin, United States", plDay(100, 9), 0, 0, nil),
		plRow(4, 2, "Austin, United States", plDay(100, 10), 0, 0, nil),
		plRow(5, 1, "Austin, United States", plDay(50, 9), 0, 0, nil),
		plRow(6, 2, "Austin, United States", plDay(50, 10), 0, 0, nil),
		// A one-off vacation elsewhere: one episode, must not read as home area.
		plRow(7, 1, "Lisbon, Portugal", plDay(30, 9), 0, 0, nil),
		plRow(8, 2, "Lisbon, Portugal", plDay(30, 10), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow)
	byLoc := map[string]Place{}
	for _, p := range places {
		byLoc[p.Location] = p
	}
	if !byLoc["Austin, United States"].HomeArea {
		t.Error("Austin should read as home area - 3 separate episodes, 2 distinct members")
	}
	if byLoc["Lisbon, Portugal"].HomeArea {
		t.Error("Lisbon should NOT read as home area - a single one-off vacation episode")
	}
}

// TestBuildPlacesResolvesRealCoordinates pins that a place the embedded gazetteer
// recognizes carries real, non-nil coordinates - not a stub or a zero value standing in
// for "resolved".
func TestBuildPlacesResolvesRealCoordinates(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Lisbon, Portugal", plDay(1, 9), 0, 0, nil),
	}
	places := buildPlaces(rows, plNow)
	p := places[0]
	if p.Lat == nil || p.Lng == nil {
		t.Fatal("lat/lng = nil, want Lisbon's real coordinates")
	}
	if *p.Lat != 38.72509 || *p.Lng != -9.1498 {
		t.Errorf("got (%v, %v), want Lisbon's real GeoNames coordinates", *p.Lat, *p.Lng)
	}
}

// TestBuildPlacesUnresolvablePlaceKeepsNilCoordinatesNotDropped pins the CRITICAL
// HONESTY contract at the db layer: a place the gazetteer can't resolve still appears in
// the list, with nil coordinates - never dropped, never guessed at.
func TestBuildPlacesUnresolvablePlaceKeepsNilCoordinatesNotDropped(t *testing.T) {
	rows := []eventPostRow{
		plRow(1, 1, "Nowhereville, Fictionland", plDay(1, 9), 0, 1, mid(1)),
	}
	places := buildPlaces(rows, plNow)
	if len(places) != 1 {
		t.Fatalf("got %d places, want 1 - an unresolvable place must still be returned", len(places))
	}
	if places[0].Lat != nil || places[0].Lng != nil {
		t.Errorf("lat/lng = (%v, %v), want (nil, nil) - this dataset has no such place", places[0].Lat, places[0].Lng)
	}
	if places[0].PostCount != 1 {
		t.Errorf("postCount = %d, want 1 - the place's stats must still be aggregated normally", places[0].PostCount)
	}
}

// TestBuildPlacesEmptyInputReturnsEmptyNotNilPanic pins that a fresh group with no
// eligible rows produces an empty (not nil-panicking) result.
func TestBuildPlacesEmptyInputReturnsEmptyNotNilPanic(t *testing.T) {
	places := buildPlaces(nil, plNow)
	if len(places) != 0 {
		t.Errorf("got %d places for no rows, want 0", len(places))
	}
}
