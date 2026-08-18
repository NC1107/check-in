package api

import "net/http"

// handlePlaces answers the Memories hub's "Places" entry: GET /api/memories/places, every
// distinct location across the group's eligible check-ins, most check-ins first (see
// db.PlacesForViewer for the full aggregation, ranking, and gazetteer-resolution
// pipeline).
//
// An empty group (or one with no located posts yet) is not an error: places comes back an
// empty array, the same honest-empty-state contract RandomMemory, EventsForViewer and
// Timeline already use.
func (s *Server) handlePlaces(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	places, err := s.db.PlacesForViewer(r.Context(), viewer.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"places": places})
}

// handlePlacePosts answers a place card's tap-through: GET
// /api/memories/places/photos?location=..., that place's own eligible check-ins
// serialized exactly like the feed (see db.PostsForPlace). location is the exact display
// string GET /api/memories/places returned for the place being opened - the client never
// constructs one itself.
//
// hasMore reports whether the place actually had more eligible posts than
// db.PostsForPlace returns - the client must use it (and posts' own length) rather than
// trusting the places LIST endpoint's own postCount for this place, which is an unbounded
// aggregate that can legitimately exceed the capped page returned here (see
// db.PostsForPlace's own doc comment - the same contract handleTimelineMonth already
// gives its own callers for a month's hasMore).
//
// An absent or empty location 400s outright: there is no place to look up.
func (s *Server) handlePlacePosts(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	location := r.URL.Query().Get("location")
	if location == "" {
		writeErr(w, http.StatusBadRequest, "location is required")
		return
	}
	posts, hasMore, err := s.db.PostsForPlace(r.Context(), viewer.ID, location)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": posts, "hasMore": hasMore})
}
