package db

import (
	"testing"
	"time"
)

// evNow is the "current time" every test in this file computes home bases and windows
// against - fixed so trailing-6-months and 3-day-window math is exact and doesn't depend
// on when the suite happens to run.
var evNow = time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)

// evDay returns evNow's date minus daysAgo days, at the given hour - the building block
// every test below uses to place a post a known number of days before "now".
func evDay(daysAgo int, hour int) time.Time {
	d := evNow.AddDate(0, 0, -daysAgo)
	return time.Date(d.Year(), d.Month(), d.Day(), hour, 0, 0, 0, time.UTC)
}

func evRow(postID, authorID int64, name, loc string, when time.Time) eventPostRow {
	return eventPostRow{
		PostID:     postID,
		AuthorID:   authorID,
		AuthorName: name,
		Location:   loc,
		CreatedAt:  when,
	}
}

// ---- computeHomeBases ----

func TestComputeHomeBasesModalLocationWithinWindow(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(10, 9)),
		evRow(2, 1, "Ada", "Austin, USA", evDay(20, 9)),
		evRow(3, 1, "Ada", "Austin, USA", evDay(25, 9)),
		evRow(4, 1, "Ada", "Denver, USA", evDay(30, 9)),
		evRow(5, 1, "Ada", "Denver, USA", evDay(35, 9)),
	}
	got := computeHomeBases(rows, evNow)
	if got[1] != "austin, usa" {
		t.Errorf("home base = %q, want austin, usa (normalized) - 3 distinct days there vs 2 "+
			"in Denver", got[1])
	}
}

func TestComputeHomeBasesIgnoresPostsOutsideTrailingSixMonths(t *testing.T) {
	rows := []eventPostRow{
		// Three distinct days in Denver, but all more than 6 months ago.
		evRow(1, 1, "Ada", "Denver, USA", evDay(200, 9)),
		evRow(2, 1, "Ada", "Denver, USA", evDay(210, 9)),
		evRow(3, 1, "Ada", "Denver, USA", evDay(220, 9)),
		// Three recent distinct days in Austin.
		evRow(4, 1, "Ada", "Austin, USA", evDay(5, 9)),
		evRow(5, 1, "Ada", "Austin, USA", evDay(15, 9)),
		evRow(6, 1, "Ada", "Austin, USA", evDay(25, 9)),
	}
	got := computeHomeBases(rows, evNow)
	if got[1] != "austin, usa" {
		t.Errorf("home base = %q, want austin, usa (normalized) - the Denver posts are "+
			"outside the trailing 6 months and must not count", got[1])
	}
}

func TestComputeHomeBasesNoRecentHistoryMeansNoEntry(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Denver, USA", evDay(400, 9)),
	}
	got := computeHomeBases(rows, evNow)
	if _, ok := got[1]; ok {
		t.Errorf("author with no posts in the trailing 6 months must have no home base entry")
	}
}

func TestComputeHomeBasesTieBreaksLexicallySmallest(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Zurich, CH", evDay(1, 9)),
		evRow(2, 1, "Ada", "Zurich, CH", evDay(2, 9)),
		evRow(3, 1, "Ada", "Zurich, CH", evDay(3, 9)),
		evRow(4, 1, "Ada", "Austin, USA", evDay(11, 9)),
		evRow(5, 1, "Ada", "Austin, USA", evDay(12, 9)),
		evRow(6, 1, "Ada", "Austin, USA", evDay(13, 9)),
	}
	got := computeHomeBases(rows, evNow)
	if got[1] != "austin, usa" {
		t.Errorf("home base = %q, want the lexically smaller of the tied normalized "+
			"locations (austin, usa)", got[1])
	}
}

// TestComputeHomeBasesRequiresMultipleDistinctDaysAsEvidence pins homeBaseMinDays
// directly: a place visited on only one or two distinct days never counts as home turf,
// no matter how many posts happened to land there, because otherwise a location would
// count as "home" without ever having shown a repeating pattern.
func TestComputeHomeBasesRequiresMultipleDistinctDaysAsEvidence(t *testing.T) {
	rows := []eventPostRow{
		// Two distinct days, several posts each - still short of the 3-day bar.
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(1, 8)),
		evRow(2, 1, "Ada", "Lisbon, Portugal", evDay(1, 14)),
		evRow(3, 1, "Ada", "Lisbon, Portugal", evDay(2, 9)),
	}
	got := computeHomeBases(rows, evNow)
	if _, ok := got[1]; ok {
		t.Errorf("home base = %q, want no entry - only 2 distinct days is short of "+
			"homeBaseMinDays", got[1])
	}
}

// ---- detectTrips ----

func TestDetectTripsTwoAwayAuthorsQualify(t *testing.T) {
	homeBase := map[int64]string{1: "austin, usa", 2: "denver, usa"}
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(5, 9)),
		evRow(2, 2, "Bea", "Lisbon, Portugal", evDay(5, 14)),
	}
	events, consumed := detectTrips(rows, homeBase)
	if len(events) != 1 {
		t.Fatalf("got %d trip events, want 1", len(events))
	}
	ev := events[0]
	if ev.Kind != EventKindTrip {
		t.Errorf("kind = %q, want trip", ev.Kind)
	}
	if ev.Place != "Lisbon, Portugal" {
		t.Errorf("place = %q, want Lisbon, Portugal", ev.Place)
	}
	if len(ev.Participants) != 2 {
		t.Errorf("participants = %d, want 2", len(ev.Participants))
	}
	if !consumed[1] || !consumed[2] {
		t.Errorf("both posts must be marked consumed so the gathering pass skips them")
	}
}

func TestDetectTripsOneAwayAuthorDoesNotQualify(t *testing.T) {
	// Bea is away in Lisbon, but Ada (whose own home base IS Lisbon - she lives there) is
	// the only other author. Only one genuinely away author: not enough for a trip.
	homeBase := map[int64]string{1: "lisbon, portugal", 2: "denver, usa"}
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(5, 9)),
		evRow(2, 2, "Bea", "Lisbon, Portugal", evDay(5, 14)),
	}
	events, consumed := detectTrips(rows, homeBase)
	if len(events) != 0 {
		t.Fatalf("got %d trip events, want 0 - only one author is actually away", len(events))
	}
	if len(consumed) != 0 {
		t.Errorf("a disqualified run must not consume any posts")
	}
}

func TestDetectTripsALocalHostDoesNotDisqualifyAGenuineTrip(t *testing.T) {
	// Ada lives in Lisbon and tags along/hosts; Bea and Cid are both genuinely away. Two
	// away authors is enough, regardless of Ada also being in the photos.
	homeBase := map[int64]string{1: "lisbon, portugal", 2: "denver, usa", 3: "austin, usa"}
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(5, 9)),
		evRow(2, 2, "Bea", "Lisbon, Portugal", evDay(5, 14)),
		evRow(3, 3, "Cid", "Lisbon, Portugal", evDay(6, 9)),
	}
	events, _ := detectTrips(rows, homeBase)
	if len(events) != 1 {
		t.Fatalf("got %d trip events, want 1", len(events))
	}
	if len(events[0].Participants) != 3 {
		t.Errorf("participants = %d, want 3 - the local host still shows up in the roster",
			len(events[0].Participants))
	}
}

func TestDetectTripsMergesAWeekOfAdjacentDaysIntoOneEvent(t *testing.T) {
	homeBase := map[int64]string{1: "austin, usa", 2: "denver, usa"}
	var rows []eventPostRow
	for day := 0; day < 7; day++ {
		rows = append(rows,
			evRow(int64(day*2+1), 1, "Ada", "Lisbon, Portugal", evDay(20-day, 9)),
			evRow(int64(day*2+2), 2, "Bea", "Lisbon, Portugal", evDay(20-day, 15)))
	}
	events, _ := detectTrips(rows, homeBase)
	if len(events) != 1 {
		t.Fatalf("got %d trip events for a week in Lisbon, want exactly 1 (a week in Lisbon "+
			"is one event, not seven)", len(events))
	}
	if len(events[0].PostIDs) != 14 {
		t.Errorf("post count = %d, want all 14 posts merged into the one event",
			len(events[0].PostIDs))
	}
}

func TestDetectTripsSplitsWhenTheGapExceedsTheWindow(t *testing.T) {
	homeBase := map[int64]string{1: "austin, usa", 2: "denver, usa"}
	rows := []eventPostRow{
		// A trip early in the month...
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(30, 9)),
		evRow(2, 2, "Bea", "Lisbon, Portugal", evDay(29, 9)),
		// ...and an unrelated one much later - a 20-day gap, well past the 3-day window.
		evRow(3, 1, "Ada", "Lisbon, Portugal", evDay(5, 9)),
		evRow(4, 2, "Bea", "Lisbon, Portugal", evDay(4, 9)),
	}
	events, _ := detectTrips(rows, homeBase)
	if len(events) != 2 {
		t.Fatalf("got %d trip events, want 2 - the two visits are 20 days apart, well past "+
			"the 3-day merge window", len(events))
	}
}

func TestDetectTripsExactlyThreeDayGapStillMerges(t *testing.T) {
	homeBase := map[int64]string{1: "austin, usa", 2: "denver, usa"}
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(10, 9)),
		evRow(2, 2, "Bea", "Lisbon, Portugal", evDay(7, 9)), // exactly 3 days later
	}
	events, _ := detectTrips(rows, homeBase)
	if len(events) != 1 {
		t.Fatalf("got %d trip events, want 1 - a gap of exactly 3 days is within the window",
			len(events))
	}
}

func TestDetectTripsDifferentPlacesNeverMerge(t *testing.T) {
	homeBase := map[int64]string{1: "austin, usa", 2: "denver, usa"}
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(5, 9)),
		evRow(2, 2, "Bea", "Porto, Portugal", evDay(5, 10)),
	}
	events, _ := detectTrips(rows, homeBase)
	if len(events) != 0 {
		t.Fatalf("got %d trip events, want 0 - two different places, one author each, "+
			"never forms a trip", len(events))
	}
}

// ---- detectGatherings ----

func TestDetectGatheringsMeetsBarAtHomeTurf(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(3, 18)),
		evRow(2, 2, "Bea", "Austin, USA", evDay(3, 19)),
		evRow(3, 3, "Cid", "Austin, USA", evDay(3, 20)),
	}
	events := detectGatherings(rows, map[int64]bool{})
	if len(events) != 1 {
		t.Fatalf("got %d gathering events, want 1", len(events))
	}
	if events[0].Kind != EventKindGathering {
		t.Errorf("kind = %q, want gathering", events[0].Kind)
	}
	if !events[0].StartDate.Equal(events[0].EndDate) {
		t.Errorf("a gathering must be a single day: start=%v end=%v",
			events[0].StartDate, events[0].EndDate)
	}
}

func TestDetectGatheringsBelowPostCountDoesNotQualify(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(3, 18)),
		evRow(2, 2, "Bea", "Austin, USA", evDay(3, 19)),
	}
	events := detectGatherings(rows, map[int64]bool{})
	if len(events) != 0 {
		t.Fatalf("got %d gathering events, want 0 - only 2 posts, below the 3-post bar",
			len(events))
	}
}

func TestDetectGatheringsBelowAuthorCountDoesNotQualify(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(3, 8)),
		evRow(2, 1, "Ada", "Austin, USA", evDay(3, 12)),
		evRow(3, 1, "Ada", "Austin, USA", evDay(3, 18)),
	}
	events := detectGatherings(rows, map[int64]bool{})
	if len(events) != 0 {
		t.Fatalf("got %d gathering events, want 0 - one prolific author posting three times "+
			"alone is not a gathering", len(events))
	}
}

func TestDetectGatheringsNeverDateWindowMergesAcrossDays(t *testing.T) {
	// Ordinary hometown background posting: two people, one post each, every day for a
	// week. Never 3-in-a-day, so none of it should read as a gathering - this is exactly
	// the "constant background posting" false-positive the higher bar exists to avoid.
	var rows []eventPostRow
	for day := 0; day < 7; day++ {
		rows = append(rows,
			evRow(int64(day*2+1), 1, "Ada", "Austin, USA", evDay(day, 9)),
			evRow(int64(day*2+2), 2, "Bea", "Austin, USA", evDay(day, 20)))
	}
	events := detectGatherings(rows, map[int64]bool{})
	if len(events) != 0 {
		t.Fatalf("got %d gathering events, want 0 - a week of ordinary 2-a-day local "+
			"posting must never merge into a gathering the way a trip's days would",
			len(events))
	}
}

func TestDetectGatheringsSkipsPostsAlreadyConsumedByATrip(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(3, 8)),
		evRow(2, 2, "Bea", "Austin, USA", evDay(3, 9)),
		evRow(3, 3, "Cid", "Austin, USA", evDay(3, 10)),
	}
	consumed := map[int64]bool{1: true, 2: true, 3: true}
	events := detectGatherings(rows, consumed)
	if len(events) != 0 {
		t.Fatalf("got %d gathering events, want 0 - every post here was already claimed by "+
			"a trip and must not also become a gathering", len(events))
	}
}

// ---- buildEvent ----

func TestBuildEventCoverIsTheMostLikedPhoto(t *testing.T) {
	m1, m2, m3 := int64(101), int64(102), int64(103)
	run := []eventPostRow{
		{PostID: 1, AuthorID: 1, AuthorName: "Ada", Location: "Austin, USA",
			CreatedAt: evDay(3, 8), LikeCount: 2, PhotoCount: 1, CoverMediaID: &m1},
		{PostID: 2, AuthorID: 2, AuthorName: "Bea", Location: "Austin, USA",
			CreatedAt: evDay(3, 9), LikeCount: 9, PhotoCount: 1, CoverMediaID: &m2},
		{PostID: 3, AuthorID: 1, AuthorName: "Ada", Location: "Austin, USA",
			CreatedAt: evDay(3, 10), LikeCount: 4, PhotoCount: 1, CoverMediaID: &m3},
	}
	ev := buildEvent(EventKindGathering, run)
	if ev.CoverMediaID == nil || *ev.CoverMediaID != m2 {
		t.Errorf("cover = %v, want the most-liked post's photo (%d)", ev.CoverMediaID, m2)
	}
	if ev.PhotoCount != 3 {
		t.Errorf("photo count = %d, want 3 (summed across the run)", ev.PhotoCount)
	}
}

func TestBuildEventCoverIsNilWhenNothingHasAPhoto(t *testing.T) {
	run := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(3, 8)),
		evRow(2, 2, "Bea", "Austin, USA", evDay(3, 9)),
	}
	ev := buildEvent(EventKindGathering, run)
	if ev.CoverMediaID != nil {
		t.Errorf("cover = %v, want nil - nothing in the run has a photo", *ev.CoverMediaID)
	}
}

func TestBuildEventParticipantsOrderedByContributionThenID(t *testing.T) {
	run := []eventPostRow{
		evRow(1, 3, "Cid", "Austin, USA", evDay(3, 8)),
		evRow(2, 1, "Ada", "Austin, USA", evDay(3, 9)),
		evRow(3, 1, "Ada", "Austin, USA", evDay(3, 10)),
		evRow(4, 2, "Bea", "Austin, USA", evDay(3, 11)),
		evRow(5, 2, "Bea", "Austin, USA", evDay(3, 12)),
	}
	ev := buildEvent(EventKindGathering, run)
	if len(ev.Participants) != 3 {
		t.Fatalf("got %d participants, want 3", len(ev.Participants))
	}
	// Ada and Bea both posted twice (tie, broken by user id asc: Ada=1 before Bea=2); Cid
	// posted once and comes last.
	wantOrder := []int64{1, 2, 3}
	for i, id := range wantOrder {
		if ev.Participants[i].UserID != id {
			t.Errorf("participant[%d].UserID = %d, want %d (order: %v)",
				i, ev.Participants[i].UserID, id, ev.Participants)
		}
	}
}

// ---- ranking ----

func TestEventOutranksNewestEndDateFirst(t *testing.T) {
	older := Event{Kind: EventKindGathering, EndDate: evDay(10, 0), PostIDs: []int64{1}}
	newer := Event{Kind: EventKindGathering, EndDate: evDay(1, 0), PostIDs: []int64{2}}
	if !eventOutranks(newer, older) {
		t.Errorf("the newer event must outrank the older one")
	}
	if eventOutranks(older, newer) {
		t.Errorf("the older event must not outrank the newer one")
	}
}

func TestEventOutranksTripAboveGatheringOnTiedDate(t *testing.T) {
	trip := Event{Kind: EventKindTrip, EndDate: evDay(5, 0), StartDate: evDay(5, 0), PostIDs: []int64{1}}
	gathering := Event{Kind: EventKindGathering, EndDate: evDay(5, 0), StartDate: evDay(5, 0), PostIDs: []int64{2}}
	if !eventOutranks(trip, gathering) {
		t.Errorf("a trip must outrank a gathering when their end dates tie")
	}
}

func TestDetectEventsOverallOrdering(t *testing.T) {
	rows := []eventPostRow{
		// Ada and Bea's established home turf: Austin, on 3 distinct earlier days each -
		// enough to clear homeBaseMinDays, so the gathering below reads as home turf
		// rather than defaulting to "away" for lack of any history at all.
		evRow(10, 1, "Ada", "Austin, USA", evDay(50, 8)),
		evRow(11, 1, "Ada", "Austin, USA", evDay(40, 8)),
		evRow(12, 1, "Ada", "Austin, USA", evDay(30, 8)),
		evRow(13, 2, "Bea", "Austin, USA", evDay(50, 9)),
		evRow(14, 2, "Bea", "Austin, USA", evDay(40, 9)),
		evRow(15, 2, "Bea", "Austin, USA", evDay(30, 9)),
		// A gathering 3 days ago at that home turf.
		evRow(1, 1, "Ada", "Austin, USA", evDay(3, 8)),
		evRow(2, 2, "Bea", "Austin, USA", evDay(3, 9)),
		evRow(3, 3, "Cid", "Austin, USA", evDay(3, 10)),
		// A trip 1 day ago, both away.
		evRow(4, 1, "Ada", "Lisbon, Portugal", evDay(1, 8)),
		evRow(5, 2, "Bea", "Lisbon, Portugal", evDay(1, 9)),
	}
	events := detectEvents(rows, evNow)
	if len(events) != 2 {
		t.Fatalf("got %d events, want 2", len(events))
	}
	if events[0].Kind != EventKindTrip {
		t.Errorf("events[0].Kind = %q, want trip (it is the more recent of the two)", events[0].Kind)
	}
	if events[1].Kind != EventKindGathering {
		t.Errorf("events[1].Kind = %q, want gathering", events[1].Kind)
	}
}

func TestDetectEventsNoEventsForOrdinaryScatteredActivity(t *testing.T) {
	// Precision over recall: a handful of members posting from their own home turf on
	// their own, no shared same-day spikes, no shared away trips - nothing here should
	// ever be promoted into an event.
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(1, 8)),
		evRow(2, 2, "Bea", "Denver, USA", evDay(2, 8)),
		evRow(3, 3, "Cid", "Austin, USA", evDay(5, 8)),
		evRow(4, 1, "Ada", "Austin, USA", evDay(9, 8)),
	}
	events := detectEvents(rows, evNow)
	if len(events) != 0 {
		t.Fatalf("got %d events, want 0 for ordinary scattered solo activity", len(events))
	}
}

func TestDetectEventsEmptyInputProducesNoEvents(t *testing.T) {
	if events := detectEvents(nil, evNow); len(events) != 0 {
		t.Fatalf("got %d events from no rows at all, want 0", len(events))
	}
}

// TestDetectEventsFirstEverSharedTripHasNoOtherHistoryToCompareAgainst is a regression
// test for a real bug found integration-testing this feature: with no OTHER location
// history at all, two authors' first-ever cluster of posts together is trivially each of
// their own single (and therefore "modal") location too - so, without homeBaseMinDays'
// evidence floor, computeHomeBases would call the very trip being evaluated each
// participant's own home base, and the trip could never qualify (buildTripIfQualifies
// would see 0 away authors instead of 2). Exercised through detectEvents end to end - not
// detectTrips with a hand-fed home base map, which is exactly what let this slip past the
// other trip tests above despite them exercising the same qualification rule.
//
// Spans two days, not one: a second, later bug (see
// TestBuildTripIfQualifiesNoHistorySameDayClusterIsAGathering) found that an unqualified
// "unknown means away" rule wrongly promoted a same-day cluster with no history to a trip
// too - a local hangout among members who simply have not posted enough to have a home
// base yet, not a trip. The multi-day span here is what a first trip actually looks like
// and is the case this regression test exists to keep working.
func TestDetectEventsFirstEverSharedTripHasNoOtherHistoryToCompareAgainst(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(3, 8)),
		evRow(2, 2, "Bea", "Lisbon, Portugal", evDay(2, 14)),
	}
	events := detectEvents(rows, evNow)
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1 - two people with no other history posting together "+
			"for the first time, across more than one day, is exactly the ordinary case a "+
			"trip has to detect", len(events))
	}
	if events[0].Kind != EventKindTrip {
		t.Errorf("kind = %q, want trip", events[0].Kind)
	}
}

// ---- A1: the away rule's two branches (known-different vs unknown-and-multi-day) ----
//
// These all go through detectEvents end to end, deliberately not detectTrips/
// detectGatherings with a hand-fed home base map - that shortcut is exactly what let the
// original "unknown always counts as away" bug (reported against a live seed: four Austin
// locals with no prior history posting from one restaurant on one day came back as a
// "Trip") slip past every test above despite them exercising the same code path.

// TestDetectEventsNoHistorySameDayClusterIsAGathering pins the bug report directly: four
// members with NO prior location history anywhere, posting from the same place on the
// same day, must not read as a trip - nobody has been shown to be "away" from anywhere,
// and same-day is exactly the shape ordinary hometown activity takes.
func TestDetectEventsNoHistorySameDayClusterIsAGathering(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(1, 18)),
		evRow(2, 2, "Bea", "Austin, USA", evDay(1, 19)),
		evRow(3, 3, "Cid", "Austin, USA", evDay(1, 20)),
		evRow(4, 4, "Dee", "Austin, USA", evDay(1, 21)),
	}
	events := detectEvents(rows, evNow)
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1", len(events))
	}
	if events[0].Kind != EventKindGathering {
		t.Errorf("kind = %q, want gathering - no one here has established history anywhere, "+
			"so nobody can be confidently called away, and a same-day cluster on no evidence "+
			"must not default to a trip", events[0].Kind)
	}
}

// TestDetectEventsNoHistoryMultiDayClusterIsATrip is the other half of the same rule: the
// same four members with no history, but spread across more than one day, is trip-shaped
// on its own evidence even with nothing to compare it against.
func TestDetectEventsNoHistoryMultiDayClusterIsATrip(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Austin, USA", evDay(2, 18)),
		evRow(2, 2, "Bea", "Austin, USA", evDay(2, 19)),
		evRow(3, 3, "Cid", "Austin, USA", evDay(1, 20)),
		evRow(4, 4, "Dee", "Austin, USA", evDay(1, 21)),
	}
	events := detectEvents(rows, evNow)
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1", len(events))
	}
	if events[0].Kind != EventKindTrip {
		t.Errorf("kind = %q, want trip - spread across 2 days, this is trip-shaped even "+
			"with no home-base evidence to compare against", events[0].Kind)
	}
}

// TestDetectEventsKnownHomeSingleDayAwayClusterIsATrip: a day trip. Two members whose home
// base is firmly established elsewhere spend a single day somewhere that is neither of
// their home turf - a day trip to a city two hours away is still a trip, not a gathering,
// even though it is only one day.
func TestDetectEventsKnownHomeSingleDayAwayClusterIsATrip(t *testing.T) {
	var rows []eventPostRow
	// Establish Ada and Bea's home base as Denver: 3 distinct earlier days each.
	for i, day := range []int{50, 40, 30} {
		rows = append(rows,
			evRow(int64(100+i*2), 1, "Ada", "Denver, USA", evDay(day, 8)),
			evRow(int64(101+i*2), 2, "Bea", "Denver, USA", evDay(day, 9)))
	}
	// A single day trip to Boulder - neither of their home turf.
	rows = append(rows,
		evRow(1, 1, "Ada", "Boulder, USA", evDay(2, 10)),
		evRow(2, 2, "Bea", "Boulder, USA", evDay(2, 15)))

	events := detectEvents(rows, evNow)
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1 (just the Boulder day trip - the background history "+
			"must never itself cluster into an event): %+v", len(events), events)
	}
	if events[0].Place != "Boulder, USA" {
		t.Fatalf("place = %q, want Boulder, USA", events[0].Place)
	}
	if events[0].Kind != EventKindTrip {
		t.Errorf("kind = %q, want trip - both participants' home base is known (Denver) and "+
			"differs from Boulder, so a single day away is enough", events[0].Kind)
	}
}

// TestDetectEventsKnownHomeSameDayLocalClusterIsAGathering: the inverse of the day-trip
// case. Members whose home base IS this location, gathering here on one day, must read as
// a gathering, not a trip - known-and-matching is never away, regardless of how many days
// the cluster spans (here, one).
func TestDetectEventsKnownHomeSameDayLocalClusterIsAGathering(t *testing.T) {
	var rows []eventPostRow
	// Establish Ada, Bea and Cid's home base as Austin: 3 distinct earlier days each, on
	// separate days per author (never 2+ of them on the same establishing day) so none of
	// this background history can itself cluster into a second trip or gathering.
	for i, day := range []int{60, 50, 40} {
		rows = append(rows,
			evRow(int64(100+i*3), 1, "Ada", "Austin, USA", evDay(day, 8)),
			evRow(int64(101+i*3), 2, "Bea", "Austin, USA", evDay(day-1, 8)),
			evRow(int64(102+i*3), 3, "Cid", "Austin, USA", evDay(day-2, 8)))
	}
	// A dinner together at home turf.
	rows = append(rows,
		evRow(1, 1, "Ada", "Austin, USA", evDay(1, 18)),
		evRow(2, 2, "Bea", "Austin, USA", evDay(1, 19)),
		evRow(3, 3, "Cid", "Austin, USA", evDay(1, 20)))

	events := detectEvents(rows, evNow)
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1 (just the dinner - the staggered background history "+
			"must never itself cluster into an event): %+v", len(events), events)
	}
	if events[0].Kind != EventKindGathering {
		t.Errorf("kind = %q, want gathering - all three participants' home base is known "+
			"and matches Austin, so none of them is away", events[0].Kind)
	}
}

// ---- A2: location normalization ----

// TestDetectEventsNormalizesLocationCaseAndWhitespaceForClustering pins that geocoder
// output which differs only in case or internal whitespace still clusters as one place -
// on-device reverse geocoding legitimately varies by OS and locale for the same real
// place, and without folding these together a genuine shared trip could silently
// fragment below the two-author threshold and produce no event at all.
func TestDetectEventsNormalizesLocationCaseAndWhitespaceForClustering(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(3, 8)),
		evRow(2, 1, "Ada", "Lisbon, Portugal", evDay(2, 8)),
		evRow(3, 2, "Bea", "lisbon, portugal", evDay(2, 9)),
		evRow(4, 2, "Bea", "Lisbon,  Portugal", evDay(1, 9)), // double internal space
	}
	events := detectEvents(rows, evNow)
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1 - case/whitespace variants of the same place must "+
			"cluster together, not fragment into separate events", len(events))
	}
	if len(events[0].PostIDs) != 4 {
		t.Errorf("post ids = %v, want all 4 posts merged into the one event", events[0].PostIDs)
	}
	if events[0].Place != "Lisbon, Portugal" {
		t.Errorf("place = %q, want the most common original variant (Lisbon, Portugal, seen "+
			"twice)", events[0].Place)
	}
}

// ---- A3: trip span cap ----

// tripSpanHomeBase gives both tripSpanRows authors a home base far from where those rows
// post, so every sub-run - down to a single leftover day - independently qualifies as away
// regardless of the A1 unknown-history/multi-day nuance (see buildTripIfQualifies), which
// is not what these tests are about: they exist to pin tripMaxSpan in isolation.
var tripSpanHomeBase = map[int64]string{1: "denver, usa", 2: "denver, usa"}

// tripSpanRows builds a location's daily-posted run of length days - both authors post
// every day, each day only 1 day after the last (well within tripWindow), so only
// tripMaxSpan (not the day-to-day gap, and not the away rule - see tripSpanHomeBase) can
// be what splits it.
func tripSpanRows(days int) []eventPostRow {
	var rows []eventPostRow
	for d := 0; d < days; d++ {
		when := evDay(days-d, 8)
		rows = append(rows,
			evRow(int64(d*2+1), 1, "Ada", "Lisbon, Portugal", when),
			evRow(int64(d*2+2), 2, "Bea", "Lisbon, Portugal", when.Add(6*time.Hour)))
	}
	return rows
}

// TestDetectTripsSpanCappedAt30Days pins that a run long enough to clear tripWindow at
// every single step (each day only 1 day after the last) still splits once its total span
// passes tripMaxSpan - otherwise an extended, tightly-packed run could merge into one
// absurdly long "trip" no matter how many days it covers.
func TestDetectTripsSpanCappedAt30Days(t *testing.T) {
	rows := tripSpanRows(40)
	events, _ := detectTrips(rows, tripSpanHomeBase)
	if len(events) < 2 {
		t.Fatalf("got %d trip events for a 40-day run, want at least 2 - a run this long must "+
			"split rather than merge into one event", len(events))
	}
	for _, ev := range events {
		span := ev.EndDate.Sub(ev.StartDate)
		if span > tripMaxSpan {
			t.Errorf("event spans %v (start=%v end=%v), want at most tripMaxSpan (%v)",
				span, ev.StartDate, ev.EndDate, tripMaxSpan)
		}
	}
}

// TestDetectTripsExactlyThirtyDaySpanStillMerges is the boundary: a run whose first and
// last active day are exactly tripMaxSpan apart is still one event - the cap only splits
// a run that would exceed it, matching tripWindow's own "exactly N still merges" contract.
func TestDetectTripsExactlyThirtyDaySpanStillMerges(t *testing.T) {
	rows := tripSpanRows(31) // day 0 .. day 30 inclusive: a 30-day span, 31 distinct days
	events, _ := detectTrips(rows, tripSpanHomeBase)
	if len(events) != 1 {
		t.Fatalf("got %d trip events, want 1 - a span of exactly tripMaxSpan (30 days) must "+
			"still merge into one event", len(events))
	}
	if len(events[0].PostIDs) != 62 {
		t.Errorf("post ids = %v, want all 31 days' worth of posts (62, 2 authors/day) in the "+
			"one event", events[0].PostIDs)
	}
}

// TestDetectTripsThirtyOneDaySpanSplits: one day past the boundary, the run must split
// into the capped 30-day chunk and a single leftover day. Found by span length, not array
// index - ranking sorts newest-first (see eventOutranks), and the leftover day is the more
// recent of the two, so it is not safe to assume which index either chunk lands at.
func TestDetectTripsThirtyOneDaySpanSplits(t *testing.T) {
	rows := tripSpanRows(32) // day 0 .. day 31 inclusive: a 31-day span
	events, _ := detectTrips(rows, tripSpanHomeBase)
	if len(events) != 2 {
		t.Fatalf("got %d trip events, want 2 - a span of tripMaxSpan+1 day must split into "+
			"two runs rather than merging into one", len(events))
	}
	var capped, leftover *Event
	for i := range events {
		if events[i].EndDate.Sub(events[i].StartDate) == tripMaxSpan {
			capped = &events[i]
		} else if events[i].StartDate.Equal(events[i].EndDate) {
			leftover = &events[i]
		}
	}
	if capped == nil {
		t.Fatalf("no event spans exactly tripMaxSpan (30 days) among %+v", events)
	}
	if leftover == nil {
		t.Fatalf("no single-day leftover event among %+v", events)
	}
	if len(leftover.PostIDs) != 2 {
		t.Errorf("leftover post ids = %v, want the 2 posts (both authors) from the one "+
			"leftover day", leftover.PostIDs)
	}
}
