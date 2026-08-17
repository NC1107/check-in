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
	if got[1] != "Austin, USA" {
		t.Errorf("home base = %q, want Austin, USA (3 distinct days there vs 2 in Denver)", got[1])
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
	if got[1] != "Austin, USA" {
		t.Errorf("home base = %q, want Austin, USA - the Denver posts are outside the "+
			"trailing 6 months and must not count", got[1])
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
	if got[1] != "Austin, USA" {
		t.Errorf("home base = %q, want the lexically smaller of the tied locations "+
			"(Austin, USA)", got[1])
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
	homeBase := map[int64]string{1: "Austin, USA", 2: "Denver, USA"}
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
	homeBase := map[int64]string{1: "Lisbon, Portugal", 2: "Denver, USA"}
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
	homeBase := map[int64]string{1: "Lisbon, Portugal", 2: "Denver, USA", 3: "Austin, USA"}
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
	homeBase := map[int64]string{1: "Austin, USA", 2: "Denver, USA"}
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
	homeBase := map[int64]string{1: "Austin, USA", 2: "Denver, USA"}
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
	homeBase := map[int64]string{1: "Austin, USA", 2: "Denver, USA"}
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
	homeBase := map[int64]string{1: "Austin, USA", 2: "Denver, USA"}
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
	ev := buildEvent(EventKindGathering, "Austin, USA", run)
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
	ev := buildEvent(EventKindGathering, "Austin, USA", run)
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
	ev := buildEvent(EventKindGathering, "Austin, USA", run)
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
func TestDetectEventsFirstEverSharedTripHasNoOtherHistoryToCompareAgainst(t *testing.T) {
	rows := []eventPostRow{
		evRow(1, 1, "Ada", "Lisbon, Portugal", evDay(2, 8)),
		evRow(2, 2, "Bea", "Lisbon, Portugal", evDay(2, 14)),
	}
	events := detectEvents(rows, evNow)
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1 - two people with no other history posting together "+
			"for the first time is exactly the ordinary case a trip has to detect", len(events))
	}
	if events[0].Kind != EventKindTrip {
		t.Errorf("kind = %q, want trip", events[0].Kind)
	}
}
