package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
)

// minTimelineYear is comfortably before this app could have any real history in it - a
// floor on GET /api/memories/timeline/{year}/{month}'s {year} so an absurd value (0,
// negative, or a typo'd extra digit) 400s outright rather than reaching the database.
const minTimelineYear = 2000

// validTimelineMonth reports whether year/month name a real, in-range calendar month this
// endpoint will accept - month strictly 1-12 (never normalized by wrapping the way
// time.Date silently rolls a month of 13 into next January), and year within
// [minTimelineYear, thisYear+1] (the +1 tolerates a client whose clock is a little ahead).
// A pure function of the parsed ints plus "now" (for the upper bound), so the guard itself
// is directly unit-testable.
func validTimelineMonth(year, month int, now time.Time) bool {
	if month < 1 || month > 12 {
		return false
	}
	return year >= minTimelineYear && year <= now.Year()+1
}

// handleTimeline answers the Memories hub's "Your months" entry: GET
// /api/memories/timeline, the group's history bucketed into calendar months, newest
// first - see db.Timeline for the whole aggregation and its month-bucketing convention.
//
// An empty group (or one where nothing is eligible yet) is not an error: months comes back
// an empty array, the same honest-empty-state contract RandomMemory and EventsForViewer
// already use.
func (s *Server) handleTimeline(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	months, err := s.db.Timeline(r.Context(), viewer.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"months": months})
}

// handleTimelineMonth answers one month's tap-through: GET
// /api/memories/timeline/{year}/{month}, that month's posts serialized exactly like the
// feed (see db.TimelineMonthPosts). {year}/{month} are validated before ever reaching the
// database (see validTimelineMonth) - a non-numeric, zero, negative, or wildly out-of-range
// value 400s cleanly rather than triggering a nonsensical or unbounded scan.
//
// hasMore reports whether the month actually had more eligible posts than
// db.TimelineMonthPosts returns - the client must use it (and posts' own length) rather
// than trusting GET /api/memories/timeline's own PostCount for this month, which is an
// unbounded aggregate that can legitimately exceed the capped page returned here.
func (s *Server) handleTimelineMonth(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	year, err := strconv.Atoi(chi.URLParam(r, "year"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid year")
		return
	}
	month, err := strconv.Atoi(chi.URLParam(r, "month"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid month")
		return
	}
	if !validTimelineMonth(year, month, time.Now()) {
		writeErr(w, http.StatusBadRequest, "year/month out of range")
		return
	}
	posts, hasMore, err := s.db.TimelineMonthPosts(r.Context(), viewer.ID, year, month)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": posts, "hasMore": hasMore})
}
