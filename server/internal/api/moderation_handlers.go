package api

import (
	"errors"
	"net/http"

	"github.com/nc1107/check-in/server/internal/db"
)

// ---- reports ----

type reportReq struct {
	Reason string `json:"reason"`
}

// maxReportReason caps a report's free-text reason. Without it the reason is bounded only by
// the 1 MiB body limit, so a member could store megabytes of text per report.
const maxReportReason = 1000

func (s *Server) handleReportPost(w http.ResponseWriter, r *http.Request) {
	postID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	var req reportReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	if req.Reason == "" || len(req.Reason) > maxReportReason {
		writeErr(w, http.StatusBadRequest, "reason must be 1-1000 characters")
		return
	}
	me := userFrom(r)
	// Verify the post exists and its author is still active before inserting, so a
	// deleted/bad id is a clean 404 rather than a foreign-key violation surfacing as a
	// generic 500. Deliberately uses ReportablePost, NOT PostVisible: reporting must not get
	// harder (or start 404ing) the moment a member protects themselves by blocking a post's
	// author - "I blocked them AND reported this" is the expected pair of actions a safety
	// feature should support, not a contradiction, and a member who blocked someone
	// specifically because of a post is exactly who most needs to still be able to flag it
	// for the host to see. See PostVisible's own doc comment for the like/comment side of
	// this same distinction.
	if visible, err := s.db.ReportablePost(r.Context(), postID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	} else if !visible {
		writeErr(w, http.StatusNotFound, msgPostNotFound)
		return
	}
	if err := s.db.ReportPost(r.Context(), me.ID, postID, req.Reason); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleReportComment(w http.ResponseWriter, r *http.Request) {
	commentID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	var req reportReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	if req.Reason == "" || len(req.Reason) > maxReportReason {
		writeErr(w, http.StatusBadRequest, "reason must be 1-1000 characters")
		return
	}
	if exists, err := s.db.CommentExists(r.Context(), commentID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	} else if !exists {
		writeErr(w, http.StatusNotFound, "comment not found")
		return
	}
	if err := s.db.ReportComment(r.Context(), userFrom(r).ID, commentID, req.Reason); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminListReports(w http.ResponseWriter, r *http.Request) {
	reports, err := s.db.ListReports(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if reports == nil {
		reports = []db.ContentReport{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"reports": reports})
}

func (s *Server) handleAdminDismissReport(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	if err := s.db.DismissReport(r.Context(), id); errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "report not found")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- blocks ----

func (s *Server) handleBlockUser(w http.ResponseWriter, r *http.Request) {
	targetID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	me := userFrom(r)
	if me.ID == targetID {
		writeErr(w, http.StatusBadRequest, "cannot block yourself")
		return
	}
	if _, err := s.db.GetUser(r.Context(), targetID); errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "user not found")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if err := s.db.BlockUser(r.Context(), me.ID, targetID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleUnblockUser(w http.ResponseWriter, r *http.Request) {
	targetID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	if err := s.db.UnblockUser(r.Context(), userFrom(r).ID, targetID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleListBlocks returns who the caller has blocked.
//
// "blocked" carries names and photos, which is what makes a block list something a member
// can read and undo. Ids alone cannot be shown to anyone, and resolving them one at a time
// is a request per row - which is why, until this, the app never called this route and a
// member had no way to see who they had blocked.
//
// "blockedIds" stays for anything scripted against the API. Nothing in the app reads it;
// the feed filters blocked authors in SQL rather than from a list the client holds.
func (s *Server) handleListBlocks(w http.ResponseWriter, r *http.Request) {
	blocked, err := s.db.BlockedUsers(r.Context(), userFrom(r).ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	ids := make([]int64, 0, len(blocked))
	people := make([]peerUser, 0, len(blocked))
	for _, u := range blocked {
		ids = append(ids, u.ID)
		people = append(people, newPeerUser(u))
	}
	writeJSON(w, http.StatusOK, map[string]any{"blockedIds": ids, "blocked": people})
}

func (s *Server) handleGetBlockStatus(w http.ResponseWriter, r *http.Request) {
	targetID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	blocked, err := s.db.IsBlocked(r.Context(), userFrom(r).ID, targetID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blocked": blocked})
}

// ---- account deletion ----

func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request) {
	me := userFrom(r)
	// Refuse to delete the only admin: doing so would leave the server with no one able to
	// invite members, review reports, or remove content (server_config stays initialized, so
	// no new first-admin is ever created). The admin must promote another member first.
	if me.IsAdmin {
		other, err := s.db.OtherAdminExists(r.Context(), me.ID)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, msgServerError)
			return
		}
		if !other {
			writeErr(w, http.StatusConflict,
				"you are the only admin - promote another member to admin before deleting your account")
			return
		}
	}
	paths, err := s.db.DeleteAccount(r.Context(), me.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	for _, p := range paths {
		_ = s.store.Delete(p)
	}
	w.WriteHeader(http.StatusNoContent)
}
