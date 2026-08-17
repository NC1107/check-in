package api

import (
	"net/http"
	"strconv"
)

// handleEvents answers the Memories hub's "You were there" entry: GET
// /api/memories/events?limit=N, newest events first (trips ranked above gatherings when
// dates tie) - see db.EventsForViewer for the whole detection algorithm. An absent,
// unparseable, or non-positive limit falls back to db.EventsForViewer's own default;
// anything above its maximum is clamped down to it - never rejected outright. This is a
// read, not a write, and a client sending a slightly wrong limit should still get a usable
// answer rather than an error.
//
// An empty group (or one with no detected events yet) is not an error: events comes back
// an empty array and the client renders that as its own honest empty state, the same way
// RandomMemory's empty result does for the "Give me a memory" action.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	limit := 0
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			limit = n
		}
	}
	events, err := s.db.EventsForViewer(r.Context(), viewer.ID, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": events})
}
