package db

import (
	"sort"
	"strings"
	"time"
)

// EventKind names one of the two shapes "You Were There" detects.
type EventKind string

const (
	EventKindTrip      EventKind = "trip"
	EventKindGathering EventKind = "gathering"
)

// Event is one detected cluster of check-ins: a trip (posts somewhere at least two
// participants can be confidently called away from) or a gathering (a concentrated
// same-day spike at a place that reads as home turf, or that nobody has enough history to
// call otherwise). See buildTripIfQualifies for exactly what "confidently away" requires.
type Event struct {
	Kind         EventKind          `json:"kind"`
	Place        string             `json:"place"`
	StartDate    time.Time          `json:"startDate"`
	EndDate      time.Time          `json:"endDate"`
	Participants []EventParticipant `json:"participants"`
	PostIDs      []int64            `json:"postIds"`
	PhotoCount   int                `json:"photoCount"`

	// CoverMediaID is the most-liked photo in the cluster (the post with the highest like
	// count among posts that carry at least one image), or nil when nothing in the cluster
	// has a photo at all (an all-text or all-clip event, which the client renders with a
	// placeholder rather than a cover).
	CoverMediaID *int64 `json:"coverMediaId,omitempty"`
}

// EventParticipant is one member who shows up in an Event, ordered in the roster by how
// much of the cluster is theirs (see buildEvent) - the same "who showed up" lens
// recapPeople uses for the recap cover's own roster.
type EventParticipant struct {
	UserID  int64  `json:"id"`
	Name    string `json:"name"`
	PhotoID *int64 `json:"photoId,omitempty"`

	// Posts is this participant's post count within the event - the ranking weight above,
	// never itself serialized.
	Posts int `json:"-"`
}

// eventPostRow is one eligible, location-bearing post considered for event detection -
// already filtered to the same eligibility the feed and RandomMemory use (active author,
// not blocked by the viewer, kind <> 'recap') by EventsForViewer's query; see this
// package's queries.go and memories.go for that precedent. A plain Go struct, not a query
// result, precisely so detectEvents and everything it calls can be exercised as a pure
// function over hand-built rows with no database in the loop.
type eventPostRow struct {
	PostID        int64
	AuthorID      int64
	AuthorName    string
	AuthorPhotoID *int64
	Location      string
	CreatedAt     time.Time
	LikeCount     int
	PhotoCount    int    // image attachments on this post
	CoverMediaID  *int64 // this post's own first image attachment, if any
}

// homeBaseLookback is how far back a member's posting history counts toward their home
// base - a moving window, not their whole lifetime, so someone who relocated reads as
// home in their new city within a couple of months rather than being permanently
// classified as "away" from where they actually live now.
const homeBaseLookback6Months = -6 // months, passed to time.AddDate

// tripWindow is how large a gap between a location's consecutive active days a trip run
// tolerates before splitting into a separate event - large enough that a week in one city
// merges into one event (each day only 24h from the last), small enough that two
// unrelated visits to the same place months apart stay two events, not one.
const tripWindow = 3 * 24 * time.Hour

// tripMaxSpan caps how long a single trip run is allowed to run on for, measured from its
// first active day, regardless of how tightly packed the days in between are (a run can
// clear tripWindow at every step and still, added up, cover half a year). 30 days is
// generous for a real trip - long enough for an extended stay, short enough that nothing
// resembling "moved somewhere for a season" gets presented as one continuous vacation. A
// run that would otherwise keep merging past this splits at the boundary: the days beyond
// it start a fresh candidate run of their own (which is separately judged - it may or may
// not qualify as its own trip), rather than the whole thing being silently truncated or
// discarded.
const tripMaxSpan = 30 * 24 * time.Hour

// gatheringMinPosts and gatheringMinAuthors are the (higher-than-a-trip's) bar a single
// day at a home-turf place has to clear to read as a real get-together rather than a
// hometown's ordinary background posting - see detectGatherings' own doc comment for why
// this needs to be stricter than a trip's bar at all.
const (
	gatheringMinPosts   = 3
	gatheringMinAuthors = 2
)

// tripMinAwayAuthors is how many participants have to be somewhere that ISN'T their own
// home base for a cluster to read as a trip - see buildTripIfQualifies's own doc comment
// for why this is checked against the AWAY subset specifically, not the cluster's full
// author count.
const tripMinAwayAuthors = 2

// dayOf floors t to its UTC calendar date (midnight) - the unit every window/bucket
// calculation in this file groups and compares by. UTC, not the group's or a viewer's
// local time zone: check-ins in one group come from members who may be in different time
// zones, and there is no single "local day" that would be correct for all of them: UTC is
// at least the same answer for everyone, which is what "same day" needs to mean for a
// shared event.
func dayOf(t time.Time) time.Time {
	u := t.UTC()
	return time.Date(u.Year(), u.Month(), u.Day(), 0, 0, 0, 0, time.UTC)
}

// normalizeLocation returns a comparison key for "is this the same place", not something
// ever shown to a member: case-folded, with runs of internal whitespace collapsed to a
// single space. Location is client-supplied from on-device reverse geocoding
// (content_handlers.go trims it but never otherwise touches it), and the same real place
// legitimately comes back differently shaped depending on the poster's OS and locale -
// "Lisbon, Portugal" from one phone, "lisbon, portugal" from another, an extra space from
// a third. Without folding those together here, a genuine shared trip can silently
// fragment across posts into clusters too small to ever clear tripMinAwayAuthors or
// gatheringMinAuthors, and produce no event at all. Every place this file groups or
// compares locations (computeHomeBases, detectTrips, detectGatherings) has to use this key
// consistently, or a member's own home-base evidence could fragment the exact same way.
//
// What a member actually SEES stays the original, unfolded string - see displayLocation.
func normalizeLocation(loc string) string {
	return strings.ToLower(strings.Join(strings.Fields(loc), " "))
}

// displayLocation picks the most common ORIGINAL location string among run's posts - what
// an event actually shows, even though its rows were grouped by normalizeLocation's
// case-folded key. Ties break toward the lexicographically smallest string, the same
// deterministic-tiebreak convention this file uses everywhere else.
func displayLocation(run []eventPostRow) string {
	counts := make(map[string]int, len(run))
	for _, r := range run {
		counts[r.Location]++
	}
	var best string
	var bestCount int
	for loc, n := range counts {
		if n > bestCount || (n == bestCount && loc < best) {
			best, bestCount = loc, n
		}
	}
	return best
}

// homeBaseMinDays is the fewest DISTINCT calendar days an author has to have posted from
// one place within the trailing window before that place counts as evidence of home turf
// at all - not just the most-visited place among however little history exists. Without a
// floor like this, detectEvents is circular for anyone with no OTHER location history: the
// very cluster of posts being evaluated for tripMinAwayAuthors is also, trivially, that
// author's only (and therefore "modal") location, so it would silently count as their own
// home base and the cluster could never qualify as a trip - which is exactly backwards for
// someone's first-ever trip together, the single most common case this feature exists for.
// Three days is enough to separate "somewhere I show up repeatedly" from "the two or three
// check-ins I just posted from the place I'm evaluating."
const homeBaseMinDays = 3

// homeAreaMinMembers and homeAreaMinDaysPerMember are the bar a normalized location has to
// clear to count as part of the GROUP's home area, not just one member's own modal
// location: at least this many DISTINCT members must have each posted from that place on
// at least this many DISTINCT days within the trailing homeBaseLookback6Months window. A
// real hometown metro spans several nearby location strings - a member's own city, the next
// suburb over, downtown - not one, and a per-member modal location alone treats every
// string but a member's single most-visited one as equally foreign: that is how a
// ten-minute trip to the next suburb reads as a "trip" while the actual home city can too,
// whenever enough members' individual modal locations happen to be scattered across
// slightly different strings in the same metro. Requiring evidence from at least two
// DIFFERENT members (three-plus days apiece, not just one member's repeat visits) is what
// keeps a real one-off group trip from ever qualifying as home area: no faraway vacation
// destination the group is actually away from has two-plus members separately
// accumulating 3+ days there over six months the way ordinary hometown life naturally
// does. These numbers reuse homeBaseMinDays' own per-member day threshold and its
// six-month window - the same evidence bar computeHomeBases already applies to an
// individual, just requiring it from more than one person before it describes the group
// rather than that one person alone.
const (
	homeAreaMinMembers       = 2
	homeAreaMinDaysPerMember = homeBaseMinDays
)

// computeHomeArea returns the set of normalized locations (see normalizeLocation) that
// read as the group's own collective home turf, as opposed to any single member's modal
// location (see computeHomeBases): anywhere at least homeAreaMinMembers different members
// each separately show homeAreaMinDaysPerMember or more days of routine posting history.
// detectTrips never lets a run at one of these locations become a trip, regardless of what
// any individual participant's own home base happens to be - see its own doc comment for
// why the per-member "away from MY city" signal alone is not enough to rule out home turf.
func computeHomeArea(rows []eventPostRow, now time.Time) map[string]bool {
	cutoff := now.AddDate(0, homeBaseLookback6Months, 0)
	// normalized location -> author id -> distinct days posted there.
	days := make(map[string]map[int64]map[time.Time]bool)
	for _, r := range rows {
		if r.CreatedAt.Before(cutoff) {
			continue
		}
		loc := normalizeLocation(r.Location)
		byAuthor := days[loc]
		if byAuthor == nil {
			byAuthor = make(map[int64]map[time.Time]bool)
			days[loc] = byAuthor
		}
		daySet := byAuthor[r.AuthorID]
		if daySet == nil {
			daySet = make(map[time.Time]bool)
			byAuthor[r.AuthorID] = daySet
		}
		daySet[dayOf(r.CreatedAt)] = true
	}
	homeArea := make(map[string]bool, len(days))
	for loc, byAuthor := range days {
		qualifying := 0
		for _, daySet := range byAuthor {
			if len(daySet) >= homeAreaMinDaysPerMember {
				qualifying++
			}
		}
		if qualifying >= homeAreaMinMembers {
			homeArea[loc] = true
		}
	}
	return homeArea
}

// computeHomeBases returns each author's modal (most DISTINCT DAYS posted from) location
// among their own rows from the trailing homeBaseLookback6Months, keyed by author id -
// but only once a location clears homeBaseMinDays; see its own doc comment for why. An
// author with no location clearing that bar (including one with no rows in the window at
// all) has no entry - buildTripIfQualifies treats a missing home base as a weaker signal
// of "away" than a known, different one; see its own doc comment for the full rule.
//
// The map is keyed by normalizeLocation's folded form, not the original string, and so is
// every lookup against it (see buildTripIfQualifies) - a member's own home-base evidence
// has to fold the same case/whitespace variants together that clustering does, or it would
// fragment exactly the way raw location grouping would (see normalizeLocation's own doc
// comment).
//
// Ties (two-plus places with the same distinct-day count) break toward the
// lexicographically smallest normalized key - simple, deterministic, and independent of
// Go's unspecified map iteration order, which is what actually matters here: any
// consistent tiebreak is defensible, but the result has to be the same every time this
// runs over the same rows.
func computeHomeBases(rows []eventPostRow, now time.Time) map[int64]string {
	cutoff := now.AddDate(0, homeBaseLookback6Months, 0)
	// authorID -> normalized location -> the set of distinct days posted there.
	days := make(map[int64]map[string]map[time.Time]bool)
	for _, r := range rows {
		if r.CreatedAt.Before(cutoff) {
			continue
		}
		byLoc := days[r.AuthorID]
		if byLoc == nil {
			byLoc = make(map[string]map[time.Time]bool)
			days[r.AuthorID] = byLoc
		}
		loc := normalizeLocation(r.Location)
		daySet := byLoc[loc]
		if daySet == nil {
			daySet = make(map[time.Time]bool)
			byLoc[loc] = daySet
		}
		daySet[dayOf(r.CreatedAt)] = true
	}
	homeBase := make(map[int64]string, len(days))
	for author, byLoc := range days {
		var best string
		var bestCount int
		for loc, daySet := range byLoc {
			n := len(daySet)
			if n < homeBaseMinDays {
				continue
			}
			if n > bestCount || (n == bestCount && loc < best) {
				best, bestCount = loc, n
			}
		}
		if bestCount > 0 {
			homeBase[author] = best
		}
	}
	return homeBase
}

// detectEvents is the whole "You Were There" detection pipeline over a group's eligible,
// location-bearing posts: compute home bases, cluster trips (consuming the posts they
// claim), cluster gatherings from whatever is left, then rank everything newest-first with
// trips ahead of gatherings on a tied date. A pure function of rows and the current time -
// no database, no HTTP - so every rule above is directly unit-testable; EventsForViewer is
// the thin DB-fetching wrapper that calls this.
func detectEvents(rows []eventPostRow, now time.Time) []Event {
	homeBase := computeHomeBases(rows, now)
	homeArea := computeHomeArea(rows, now)
	trips, consumed := detectTrips(rows, homeBase, homeArea)
	gatherings := detectGatherings(rows, consumed)

	events := make([]Event, 0, len(trips)+len(gatherings))
	events = append(events, trips...)
	events = append(events, gatherings...)
	sort.Slice(events, func(i, j int) bool { return eventOutranks(events[i], events[j]) })
	return events
}

// detectTrips clusters rows by normalized location, merges each location's consecutive
// active days into runs (splitting wherever the gap between one active day and the next
// exceeds tripWindow, or the run's total span from its first active day would exceed
// tripMaxSpan), and keeps a run only when it qualifies as a trip (see
// buildTripIfQualifies). A location the group already reads as home area (see
// computeHomeArea) is skipped entirely before any run is even built there - it is left
// wholly unconsumed, not partially claimed and partially left over, so detectGatherings
// sees every one of its posts and can still find a real get-together within it. Returns
// the qualifying events and the set of post ids they claim, so detectGatherings never
// reconsiders the same posts as a second, different kind of event.
func detectTrips(
	rows []eventPostRow, homeBase map[int64]string, homeArea map[string]bool,
) (events []Event, consumed map[int64]bool) {
	consumed = make(map[int64]bool)

	byLocation := make(map[string][]eventPostRow)
	for _, r := range rows {
		loc := normalizeLocation(r.Location)
		byLocation[loc] = append(byLocation[loc], r)
	}
	locations := make([]string, 0, len(byLocation))
	for loc := range byLocation {
		locations = append(locations, loc)
	}
	sort.Strings(locations) // deterministic iteration; map order is not

	for _, loc := range locations {
		if homeArea[loc] {
			continue
		}
		locRows := byLocation[loc]
		sort.Slice(locRows, func(i, j int) bool { return locRows[i].CreatedAt.Before(locRows[j].CreatedAt) })

		var run []eventPostRow
		var firstDay, lastDay time.Time
		flush := func() {
			if len(run) == 0 {
				return
			}
			if ev, ok := buildTripIfQualifies(loc, run, homeBase); ok {
				events = append(events, ev)
				for _, r := range run {
					consumed[r.PostID] = true
				}
			}
			run = nil
		}
		for _, r := range locRows {
			day := dayOf(r.CreatedAt)
			if len(run) > 0 && (day.Sub(lastDay) > tripWindow || day.Sub(firstDay) > tripMaxSpan) {
				flush()
			}
			if len(run) == 0 {
				firstDay = day
			}
			run = append(run, r)
			lastDay = day
		}
		flush()
	}
	return events, consumed
}

// buildTripIfQualifies decides whether one normalized location's date-merged run of posts
// is a trip: at least tripMinAwayAuthors distinct participants who can be confidently
// called away from this location. Only ever reached for a location detectTrips has already
// confirmed is NOT the group's own home area (see computeHomeArea) - this function has no
// group-wide notion of "home," only each individual participant's own home base, which is
// deliberately a weaker signal (see below) and not enough on its own to rule out a
// location the group merely happens to spread its home-turf posting across several nearby
// strings for. What counts as away depends on what is actually known about each
// participant, and the two cases are deliberately not treated the same:
//
//   - Home base KNOWN (see computeHomeBases) and different from this location: away,
//     regardless of how long the run is. A single day is enough - a day trip to a city
//     two hours away is still a trip.
//   - Home base UNKNOWN (no location anywhere clears homeBaseMinDays for that person):
//     away only when the run spans MORE THAN ONE DAY. A same-day cluster with no
//     home-base evidence either way is far more likely an ordinary local hangout that
//     just hasn't accumulated enough history yet than a genuine trip - four members with
//     no posting history at all, out to dinner once, must not read as a trip - so it is
//     left for detectGatherings to judge on its own, stricter bar instead. A run spanning
//     multiple days is trip-shaped on its own evidence even with nothing to compare it
//     against, which is what keeps a group's first-ever trip together detectable (before
//     anyone has 3+ days of history anywhere to prove they were "away" from).
//
// Checking the away subset specifically, rather than the run's full author count, is also
// what lets a trip still qualify when a local host who lives right there shows up in a few
// of the photos: the group traveled even if not every single person in the photos did.
func buildTripIfQualifies(loc string, run []eventPostRow, homeBase map[int64]string) (Event, bool) {
	multiDay := dayOf(run[0].CreatedAt).Before(dayOf(run[len(run)-1].CreatedAt))

	away := make(map[int64]bool)
	for _, r := range run {
		hb, known := homeBase[r.AuthorID]
		switch {
		case known && hb != loc:
			away[r.AuthorID] = true
		case !known && multiDay:
			away[r.AuthorID] = true
		}
	}
	if len(away) < tripMinAwayAuthors {
		return Event{}, false
	}
	return buildEvent(EventKindTrip, run), true
}

// detectGatherings buckets whatever posts a trip run didn't already claim by (location,
// calendar day) and keeps a bucket only when it clears gatheringMinPosts/
// gatheringMinAuthors. This bar is deliberately higher than a trip's (which only needs 2
// away authors, no minimum post count beyond that): a group's hometown accumulates
// constant background posting from members just living their lives there, and without a
// stronger signal than "two people happened to post from the same city on the same day"
// nearly every day would falsely read as a gathering. Requiring three-plus posts on the
// SAME day, not date-window-merged the way a trip is, is what keeps this reading as "an
// actual get-together happened" rather than "a week of routine local check-ins."
func detectGatherings(rows []eventPostRow, consumed map[int64]bool) []Event {
	type bucketKey struct {
		loc string // normalizeLocation's folded form - see detectTrips' identical reasoning
		day time.Time
	}
	buckets := make(map[bucketKey][]eventPostRow)
	for _, r := range rows {
		if consumed[r.PostID] {
			continue
		}
		k := bucketKey{loc: normalizeLocation(r.Location), day: dayOf(r.CreatedAt)}
		buckets[k] = append(buckets[k], r)
	}

	keys := make([]bucketKey, 0, len(buckets))
	for k := range buckets {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if !keys[i].day.Equal(keys[j].day) {
			return keys[i].day.Before(keys[j].day)
		}
		return keys[i].loc < keys[j].loc
	})

	var events []Event
	for _, k := range keys {
		run := buckets[k]
		authors := make(map[int64]bool, len(run))
		for _, r := range run {
			authors[r.AuthorID] = true
		}
		if len(run) >= gatheringMinPosts && len(authors) >= gatheringMinAuthors {
			events = append(events, buildEvent(EventKindGathering, run))
		}
	}
	return events
}

// buildEvent turns a qualifying run of posts at one place into the Event the client
// renders: post ids and date range in chronological order, every distinct author rolled
// up into a roster ordered by contribution (the same post-count-desc, user-id-asc
// convention recapPeople uses for the recap cover's own roster - see its doc comment for
// why post count, not likes, is the right lens for "who showed up"), and a cover picked as
// the most-liked photo in the run (ties broken toward the earlier post id, for a
// deterministic pick when two posts tie on likes). Place is computed from run itself (see
// displayLocation) rather than passed in, since the caller only ever has the normalized
// grouping key at hand - what a member sees always comes from the original strings.
func buildEvent(kind EventKind, run []eventPostRow) Event {
	sorted := make([]eventPostRow, len(run))
	copy(sorted, run)
	sort.Slice(sorted, func(i, j int) bool {
		if !sorted[i].CreatedAt.Equal(sorted[j].CreatedAt) {
			return sorted[i].CreatedAt.Before(sorted[j].CreatedAt)
		}
		return sorted[i].PostID < sorted[j].PostID
	})

	postIDs := make([]int64, len(sorted))
	photoCount := 0
	var coverMediaID *int64
	var coverPost eventPostRow
	haveCover := false

	participants := make(map[int64]*EventParticipant, len(sorted))
	var order []int64

	for i, r := range sorted {
		postIDs[i] = r.PostID
		photoCount += r.PhotoCount
		if r.CoverMediaID != nil {
			if !haveCover || r.LikeCount > coverPost.LikeCount ||
				(r.LikeCount == coverPost.LikeCount && r.PostID < coverPost.PostID) {
				coverMediaID = r.CoverMediaID
				coverPost = r
				haveCover = true
			}
		}
		p, ok := participants[r.AuthorID]
		if !ok {
			p = &EventParticipant{UserID: r.AuthorID, Name: r.AuthorName, PhotoID: r.AuthorPhotoID}
			participants[r.AuthorID] = p
			order = append(order, r.AuthorID)
		}
		p.Posts++
	}

	people := make([]EventParticipant, len(order))
	for i, id := range order {
		people[i] = *participants[id]
	}
	sort.Slice(people, func(i, j int) bool {
		if people[i].Posts != people[j].Posts {
			return people[i].Posts > people[j].Posts
		}
		return people[i].UserID < people[j].UserID
	})

	return Event{
		Kind:         kind,
		Place:        displayLocation(sorted),
		StartDate:    dayOf(sorted[0].CreatedAt),
		EndDate:      dayOf(sorted[len(sorted)-1].CreatedAt),
		Participants: people,
		PostIDs:      postIDs,
		PhotoCount:   photoCount,
		CoverMediaID: coverMediaID,
	}
}

// eventOutranks reports whether a ranks strictly ahead of b in the events list: newest
// end date first (per the endpoint's contract), trips ahead of gatherings when the end
// date ties, then start date, place, and finally the run's earliest post id - full
// determinism, so the order never depends on map/slice iteration order upstream.
func eventOutranks(a, b Event) bool {
	if !a.EndDate.Equal(b.EndDate) {
		return a.EndDate.After(b.EndDate)
	}
	if a.Kind != b.Kind {
		return a.Kind == EventKindTrip
	}
	if !a.StartDate.Equal(b.StartDate) {
		return a.StartDate.After(b.StartDate)
	}
	if a.Place != b.Place {
		return a.Place < b.Place
	}
	return a.PostIDs[0] < b.PostIDs[0]
}
