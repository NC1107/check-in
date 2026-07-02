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

func (s *Server) handleReportPost(w http.ResponseWriter, r *http.Request) {
	postID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	var req reportReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.Reason == "" {
		writeErr(w, http.StatusBadRequest, "reason required")
		return
	}
	if err := s.db.ReportPost(r.Context(), userFrom(r).ID, postID, req.Reason); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminListReports(w http.ResponseWriter, r *http.Request) {
	reports, err := s.db.ListReports(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
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
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	if err := s.db.DismissReport(r.Context(), id); errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "report not found")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- blocks ----

type blockReq struct {
	UserID int64 `json:"userId"`
}

func (s *Server) handleBlockUser(w http.ResponseWriter, r *http.Request) {
	targetID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	me := userFrom(r)
	if me.ID == targetID {
		writeErr(w, http.StatusBadRequest, "cannot block yourself")
		return
	}
	if err := s.db.BlockUser(r.Context(), me.ID, targetID); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleUnblockUser(w http.ResponseWriter, r *http.Request) {
	targetID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	if err := s.db.UnblockUser(r.Context(), userFrom(r).ID, targetID); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleListBlocks(w http.ResponseWriter, r *http.Request) {
	ids, err := s.db.ListBlockedIDs(r.Context(), userFrom(r).ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	if ids == nil {
		ids = []int64{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"blockedIds": ids})
}

func (s *Server) handleGetBlockStatus(w http.ResponseWriter, r *http.Request) {
	targetID, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	blocked, err := s.db.IsBlocked(r.Context(), userFrom(r).ID, targetID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blocked": blocked})
}

// ---- account deletion ----

func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request) {
	me := userFrom(r)
	paths, err := s.db.DeleteAccount(r.Context(), me.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	for _, p := range paths {
		_ = s.store.Delete(p)
	}
	w.WriteHeader(http.StatusNoContent)
}
