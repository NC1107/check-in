package api

import (
	"testing"

	"github.com/nc1107/check-in/server/internal/db"
)

func TestVariantFile(t *testing.T) {
	clip := db.Media{Path: "ab/abcd.mp4", Mime: "video/mp4", PosterPath: "cd/cdef.jpg"}
	unposted := db.Media{Path: "ab/abcd.mp4", Mime: "video/mp4"}
	photo := db.Media{Path: "ef/efgh.png", Mime: "image/png"}

	tests := []struct {
		name     string
		media    db.Media
		variant  string
		wantPath string
		wantMime string
	}{
		{"no variant serves the file itself", clip, "", "ab/abcd.mp4", "video/mp4"},
		{"poster serves the still frame", clip, "poster", "cd/cdef.jpg", "image/jpeg"},
		{"a clip with no poster falls back to the clip", unposted, "poster", "ab/abcd.mp4", "video/mp4"},
		{"an image has no poster to serve", photo, "poster", "ef/efgh.png", "image/png"},
		{"an unknown variant falls back", clip, "thumbnail", "ab/abcd.mp4", "video/mp4"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path, mime := variantFile(tt.media, tt.variant)
			if path != tt.wantPath || mime != tt.wantMime {
				t.Errorf("variantFile() = (%q, %q), want (%q, %q)", path, mime, tt.wantPath, tt.wantMime)
			}
		})
	}
}

// A poster is served with the type it was stored as, never the clip's - an <img> pointed at
// something labelled video/mp4 renders as a broken image.
func TestPosterMime(t *testing.T) {
	if got := posterMime("ab/abcd.png"); got != "image/png" {
		t.Errorf("posterMime(.png) = %q, want image/png", got)
	}
	if got := posterMime("ab/abcd.jpg"); got != "image/jpeg" {
		t.Errorf("posterMime(.jpg) = %q, want image/jpeg", got)
	}
}

// Ownership is checked elsewhere; this is the guard that keeps a clip out of the places
// that can only render a picture.
func TestIsImage(t *testing.T) {
	for mime, want := range map[string]bool{
		"image/jpeg": true,
		"image/png":  true,
		"image/gif":  true,
		"video/mp4":  false,
		"":           false,
		"imagevideo": false,
	} {
		if got := isImage(mime); got != want {
			t.Errorf("isImage(%q) = %v, want %v", mime, got, want)
		}
	}
}
