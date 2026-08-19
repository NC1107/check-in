package api

import "net/http"

// handleForgottenPhoto answers the Memories hub's "Forgotten photos" entry: one old,
// lightly-engaged photo from the group's history the caller is allowed to see (see
// db.ForgottenPhoto for what "forgotten" means and how one is picked). Serialized exactly
// like a feed post under the same "post" key RandomMemory already uses, so the client's
// existing Post model and _MemoryCard widget need no special case for where it came from -
// createdAt alone is enough for the client to render "how long ago", the same way it already
// does for a random memory.
//
// An empty group (or one with nothing old and quiet enough yet) is not an error: post comes
// back null and the client renders that as its own honest empty state - every group hits this
// for its first few months, since forgottenAgeFloor alone rules out anything younger.
func (s *Server) handleForgottenPhoto(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	post, ok, err := s.db.ForgottenPhoto(r.Context(), viewer.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"post": nil})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"post": post})
}
