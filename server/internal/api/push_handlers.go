package api

import (
	"context"
	"net/http"
	"strconv"
	"strings"
)

type deviceReq struct {
	Token    string `json:"token"`
	Platform string `json:"platform"` // "ios" | "android"
}

// handleRegisterDevice stores (or refreshes) the caller's FCM token so the server can
// push to this device.
func (s *Server) handleRegisterDevice(w http.ResponseWriter, r *http.Request) {
	var req deviceReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	if strings.TrimSpace(req.Token) == "" {
		writeErr(w, http.StatusBadRequest, "token required")
		return
	}
	if err := s.db.UpsertDeviceToken(r.Context(), userFrom(r).ID, req.Token, req.Platform); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleUnregisterDevice drops a token (e.g. on logout).
func (s *Server) handleUnregisterDevice(w http.ResponseWriter, r *http.Request) {
	var req deviceReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.db.DeleteDeviceToken(r.Context(), req.Token); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	posts, replies, err := s.db.NotificationPrefs(r.Context(), userFrom(r).ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"posts": posts, "replies": replies})
}

type notifyPrefsReq struct {
	Posts   *bool `json:"posts"`
	Replies *bool `json:"replies"`
}

// handleUpdateNotificationPrefs sets the caller's opt-out toggles. Omitted fields keep
// their current value.
func (s *Server) handleUpdateNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	var req notifyPrefsReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	posts, replies, err := s.db.NotificationPrefs(r.Context(), userFrom(r).ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	if req.Posts != nil {
		posts = *req.Posts
	}
	if req.Replies != nil {
		replies = *req.Replies
	}
	if err := s.db.SetNotificationPrefs(r.Context(), userFrom(r).ID, posts, replies); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"posts": posts, "replies": replies})
}

// notifyPost pushes a new-post notification to everyone opted in except the author. It
// runs in its own goroutine off the request path, so it uses a background context.
func (s *Server) notifyPost(authorID int64, authorName string, postID int64) {
	if s.push == nil {
		return
	}
	ctx := context.Background()
	tokens, err := s.db.TokensForNewPost(ctx, authorID)
	if err != nil || len(tokens) == 0 {
		return
	}
	s.push.Send(ctx, tokens, "Check-In", authorName+" shared a check-in",
		map[string]string{"type": "post", "postId": strconv.FormatInt(postID, 10)})
}

// notifyReply pushes a reply notification to the post's author.
func (s *Server) notifyReply(commenterName string, postID, commenterID int64) {
	if s.push == nil {
		return
	}
	ctx := context.Background()
	tokens, err := s.db.TokensForReply(ctx, postID, commenterID)
	if err != nil || len(tokens) == 0 {
		return
	}
	s.push.Send(ctx, tokens, "Check-In", commenterName+" commented on your check-in",
		map[string]string{"type": "comment", "postId": strconv.FormatInt(postID, 10)})
}
