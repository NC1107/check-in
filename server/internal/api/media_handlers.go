package api

import (
	"errors"
	"io"
	"net/http"

	"github.com/nc1107/check-in/server/internal/db"
)

// handleUploadMedia accepts a multipart image upload, stores it safely, records it, and
// returns the media metadata (the client then references mediaId when creating a post
// or completing signup).
func (s *Server) handleUploadMedia(w http.ResponseWriter, r *http.Request) {
	// Cap the whole request so ParseMultipartForm can't spool a huge temp file to disk
	// before SaveImage gets a chance to reject it. Leave headroom for multipart framing.
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxUploadBytes+(1<<20))
	if err := r.ParseMultipartForm(s.cfg.MaxUploadBytes + 1024); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid upload")
		return
	}
	file, _, err := r.FormFile("file")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "missing 'file' field")
		return
	}
	defer file.Close()

	saved, err := s.store.SaveImage(file, s.cfg.MaxUploadBytes)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "could not process image: "+err.Error())
		return
	}

	owner := userFrom(r).ID
	media, err := s.db.CreateMedia(r.Context(), &owner, saved.RelPath, saved.Mime, saved.Width, saved.Height)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not save media")
		return
	}
	writeJSON(w, http.StatusCreated, media)
}

// handleServeMedia streams a stored image to authenticated clients.
func (s *Server) handleServeMedia(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	media, err := s.db.GetVisibleMedia(r.Context(), id, userFrom(r).ID)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "media not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	f, err := s.store.Open(media.Path)
	if err != nil {
		writeErr(w, http.StatusNotFound, "media file missing")
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", media.Mime)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	w.Header().Set("Content-Disposition", "attachment")
	_, _ = io.Copy(w, f)
}
