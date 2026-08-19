package api

import (
	"errors"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/nc1107/check-in/server/internal/db"
)

// handleUploadMedia accepts a multipart upload, stores it safely, records it, and returns
// the media metadata (the client then references mediaId when creating a post or completing
// signup).
func (s *Server) handleUploadMedia(w http.ResponseWriter, r *http.Request) {
	// Cap the whole request so ParseMultipartForm can't spool a huge temp file to disk
	// before the store gets a chance to reject it. Leave headroom for multipart framing.
	// The type is not known until the file is sniffed, so the request-level cap is the
	// larger of the two limits and the per-type one is enforced inside SaveMedia.
	maxBytes := max(s.cfg.MaxUploadBytes, s.cfg.MaxVideoBytes)
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes+(1<<20))
	if err := r.ParseMultipartForm(maxBytes + 1024); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid upload")
		return
	}
	file, _, err := r.FormFile("file")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "missing 'file' field")
		return
	}
	defer file.Close()

	saved, err := s.store.SaveMedia(file, s.cfg.MaxUploadBytes, s.cfg.MaxVideoBytes)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "could not process upload: "+err.Error())
		return
	}

	owner := userFrom(r).ID
	media, err := s.db.CreateMedia(r.Context(), &owner, saved.RelPath, saved.Mime, saved.Width, saved.Height, saved.DurationMs)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not save media")
		return
	}
	writeJSON(w, http.StatusCreated, media)
}

// handleSetMediaPoster attaches a still frame to a clip the caller uploaded. The frame goes
// through the image pipeline, so a poster is always a plain re-encoded image no matter what
// was sent.
func (s *Server) handleSetMediaPoster(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
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
	previous, err := s.db.SetMediaPoster(r.Context(), id, userFrom(r).ID, saved.RelPath)
	if errors.Is(err, db.ErrNotFound) {
		// The just-stored file has nothing pointing at it now, so take it back out.
		_ = s.store.Delete(saved.RelPath)
		writeErr(w, http.StatusNotFound, "media not found or not yours")
		return
	}
	if err != nil {
		_ = s.store.Delete(saved.RelPath)
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if previous != "" {
		_ = s.store.Delete(previous)
	}
	media, err := s.db.GetMedia(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, media)
}

// handleServeMedia streams a stored file to authenticated clients.
func (s *Server) handleServeMedia(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	media, err := s.db.GetVisibleMedia(r.Context(), id, userFrom(r).ID)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "media not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	relPath, mime, ok := variantFile(media, r.URL.Query().Get("variant"))
	if !ok {
		writeErr(w, http.StatusNotFound, "poster not found")
		return
	}
	f, err := s.store.Open(relPath)
	if err != nil {
		writeErr(w, http.StatusNotFound, "media file missing")
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}

	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	// Inline rather than attachment: this is content the app displays, not a download. It
	// is safe to inline because nothing reaches disk without being re-encoded or validated,
	// and every response carries X-Content-Type-Options: nosniff.
	w.Header().Set("Content-Disposition", "inline")
	// ServeContent rather than io.Copy for the Range handling: an iOS AVPlayer will not
	// play a source that ignores Range, and conditional requests come free for images too.
	// The name is empty and the type pre-set so it never re-sniffs and contradicts us.
	http.ServeContent(w, r, "", info.ModTime(), f)
}

// variantFile picks which stored file answers a request, and what to call it.
//
// A poster request for a clip that has none is refused rather than answered with the
// clip: the caller asked for something image-shaped, and handing back an mp4 fails later
// and further away, as an undecodable image. Unknown variant NAMES still fall back to the
// main file, so a future client asking for a variant this server predates degrades to
// today's behaviour instead of breaking.
func variantFile(media db.Media, variant string) (relPath, mime string, ok bool) {
	if variant == "poster" {
		if media.PosterPath == "" {
			return "", "", false
		}
		return media.PosterPath, posterMime(media.PosterPath), true
	}
	return media.Path, media.Mime, true
}

// isImage reports whether a stored item can be rendered anywhere an image is expected.
// Ownership is not enough on its own: it is what stops a member pointing an avatar, or
// anything else that must be a picture, at a video clip.
func isImage(mime string) bool {
	return strings.HasPrefix(mime, "image/")
}

// posterMime names a poster from its stored extension. Posters come out of the image
// pipeline, so there are only ever two.
func posterMime(relPath string) string {
	if strings.EqualFold(filepath.Ext(relPath), ".png") {
		return "image/png"
	}
	return "image/jpeg"
}
