package api

import "net/http"

// handleRandomMemory answers the hidden Memories surface's one action: a uniformly-random
// post from the group's history the caller is allowed to see (see db.RandomMemory for the
// eligibility rules). Serialized exactly like a feed post - post is the same key the client
// already reads everywhere else it decodes a Post - so the client's model needs no special
// case for where the post came from.
//
// An empty group (or one where nothing is old enough yet) is not an error: post comes back
// null and the client renders that as its own empty state, the same way an author with no
// posts renders an empty profile rather than a failure.
func (s *Server) handleRandomMemory(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	post, ok, err := s.db.RandomMemory(r.Context(), viewer.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"post": nil})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"post": post})
}
