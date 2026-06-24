package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

func (s *Server) handleFeed(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	limit := parseLimit(r, 30, 100)

	var authorID *int64
	if a := r.URL.Query().Get("author"); a != "" {
		if id, err := strconv.ParseInt(a, 10, 64); err == nil {
			authorID = &id
		}
	}
	var before *time.Time
	if b := r.URL.Query().Get("before"); b != "" {
		if t, err := time.Parse(time.RFC3339, b); err == nil {
			before = &t
		}
	}

	posts, err := s.db.Feed(r.Context(), viewer.ID, authorID, before, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": posts})
}

func (s *Server) handleSearchUsers(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("search"))
	users, err := s.db.SearchUsers(r.Context(), q, parseLimit(r, 50, 200))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

func (s *Server) handleGetUser(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	user, err := s.db.GetUser(r.Context(), id)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "user not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, user)
}

// handleUserPosts returns one person's timeline (git-history style): their posts in
// reverse-chronological order with cursor pagination.
func (s *Server) handleUserPosts(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	var before *time.Time
	if b := r.URL.Query().Get("before"); b != "" {
		if t, err := time.Parse(time.RFC3339, b); err == nil {
			before = &t
		}
	}
	posts, err := s.db.Feed(r.Context(), userFrom(r).ID, &id, before, parseLimit(r, 30, 100))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": posts})
}

type createPostReq struct {
	Kind    string `json:"kind"`    // "text" or "image"
	Body    string `json:"body"`    // text body or image caption
	MediaID *int64 `json:"mediaId"` // required when kind == "image"
}

func (s *Server) handleCreatePost(w http.ResponseWriter, r *http.Request) {
	var req createPostReq
	if err := decodeJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	req.Body = strings.TrimSpace(req.Body)
	switch req.Kind {
	case "text":
		if req.Body == "" {
			writeErr(w, http.StatusBadRequest, "text posts need a body")
			return
		}
		req.MediaID = nil
	case "image":
		if req.MediaID == nil {
			writeErr(w, http.StatusBadRequest, "image posts need a mediaId")
			return
		}
	default:
		writeErr(w, http.StatusBadRequest, "kind must be 'text' or 'image'")
		return
	}
	if len(req.Body) > 5000 {
		writeErr(w, http.StatusBadRequest, "body too long")
		return
	}

	post, err := s.db.CreatePost(r.Context(), userFrom(r).ID, req.Kind, req.Body, req.MediaID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not create post")
		return
	}
	writeJSON(w, http.StatusCreated, post)
}

func (s *Server) handleGetPost(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	post, err := s.db.GetPost(r.Context(), userFrom(r).ID, id)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "post not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, post)
}

func (s *Server) handleDeletePost(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	err = s.db.DeletePost(r.Context(), id, userFrom(r).ID)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "post not found or not yours")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleLike(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	if err := s.db.LikePost(r.Context(), id, userFrom(r).ID); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleUnlike(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	if err := s.db.UnlikePost(r.Context(), id, userFrom(r).ID); err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleListComments(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	comments, err := s.db.ListComments(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"comments": comments})
}

type addCommentReq struct {
	Body string `json:"body"`
}

func (s *Server) handleAddComment(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	var req addCommentReq
	if err := decodeJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	req.Body = strings.TrimSpace(req.Body)
	if req.Body == "" || len(req.Body) > 2000 {
		writeErr(w, http.StatusBadRequest, "comment must be 1-2000 characters")
		return
	}
	comment, err := s.db.AddComment(r.Context(), id, userFrom(r).ID, req.Body)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not add comment")
		return
	}
	writeJSON(w, http.StatusCreated, comment)
}

func (s *Server) handleUpcomingBirthdays(w http.ResponseWriter, r *http.Request) {
	birthdays, err := s.db.UpcomingBirthdays(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"birthdays": birthdays})
}

func parseLimit(r *http.Request, def, max int) int {
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 {
			if n > max {
				return max
			}
			return n
		}
	}
	return def
}
