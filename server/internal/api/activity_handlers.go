package api

import (
	"net/http"

	"github.com/nc1107/check-in/server/internal/db"
)

// The activity list is the record of what happened about a member - comments on their
// check-ins, replies to their comments, likes on their check-ins - so a notification they
// missed, or swiped away, is still reachable. See db/activity.go for why it is derived from
// existing rows rather than logged at notify time.
//
// The route is /api/me/activity rather than /api/me/notifications because that path already
// belongs to notification *preferences*.

// handleActivity returns one page of the caller's activity, newest first, along with how
// many items are newer than their seen marker so the app can badge the bell without a second
// request, and the cursor to continue from when there is more.
func (s *Server) handleActivity(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)

	// The cursor is opaque: it comes straight back from a previous page's nextCursor, and
	// an unreadable one starts from the newest activity rather than failing the request.
	items, next, err := s.db.Activity(r.Context(), db.ActivityQuery{
		ViewerID: viewer.ID,
		Cursor:   r.URL.Query().Get("cursor"),
		Limit:    parseLimit(r, 30, 100),
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	unread, err := s.db.UnreadActivity(r.Context(), viewer.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	// Never null: an app that has no activity yet should render an empty list, not fail to
	// decode one.
	if items == nil {
		items = []db.ActivityItem{}
	}
	body := map[string]any{"items": items, "unreadCount": unread}
	if next != "" {
		body["nextCursor"] = next
	}
	writeJSON(w, http.StatusOK, body)
}

// handleMarkActivitySeen clears the caller's unread count. Server-side rather than
// per-device so reading the list on a phone also clears the badge on a tablet.
func (s *Server) handleMarkActivitySeen(w http.ResponseWriter, r *http.Request) {
	if err := s.db.MarkActivitySeen(r.Context(), userFrom(r).ID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
