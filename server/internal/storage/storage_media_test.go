package storage

import (
	"bytes"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func TestSaveMediaStoresVideoWithDurationAndStrippedLocation(t *testing.T) {
	dir := t.TempDir()
	store, err := New(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	upload := clip(mvhdV0(9000),
		append(videoTrack(), box("udta", box("\xa9xyz", []byte(gpsPayload))))...)

	saved, err := store.SaveMedia(bytes.NewReader(upload), 1<<20, 1<<20)
	if err != nil {
		t.Fatalf("SaveMedia: %v", err)
	}
	if saved.Mime != "video/mp4" {
		t.Errorf("mime = %q, want video/mp4", saved.Mime)
	}
	if saved.DurationMs != 9000 {
		t.Errorf("DurationMs = %d, want 9000", saved.DurationMs)
	}
	if saved.Width != 1920 || saved.Height != 1080 {
		t.Errorf("dims = %dx%d, want 1920x1080", saved.Width, saved.Height)
	}

	stored, err := os.ReadFile(filepath.Join(dir, saved.RelPath))
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if len(stored) != len(upload) {
		t.Errorf("stored %d bytes, uploaded %d - the file must be stored at its original length", len(stored), len(upload))
	}
	if bytes.Contains(stored, []byte("51.5074")) {
		t.Error("coordinates reached disk")
	}
}

// The two limits are separate for a reason, and the check has to happen after the type is
// known: a clip that is over the image limit but under the video limit is fine.
func TestSaveMediaAppliesThePerTypeSizeLimit(t *testing.T) {
	store, _ := New(t.TempDir())
	upload := clip(mvhdV0(3000), videoTrack()...)

	if _, err := store.SaveMedia(bytes.NewReader(upload), int64(len(upload)-1), int64(len(upload))); err != nil {
		t.Errorf("a video under the video limit must be accepted: %v", err)
	}
	if _, err := store.SaveMedia(bytes.NewReader(upload), int64(len(upload)), int64(len(upload)-1)); err == nil {
		t.Error("expected rejection of a video over the video limit")
	}
}

func TestSaveMediaRejectsUnsupportedTypes(t *testing.T) {
	store, _ := New(t.TempDir())
	if _, err := store.SaveMedia(bytes.NewReader([]byte("not media at all")), 1<<20, 1<<20); err == nil {
		t.Error("expected rejection of a non-media upload")
	}
}

// Photos keep the pipeline they have always had: decoded and re-encoded, which is what
// strips their EXIF.
func TestSaveMediaReencodesStillImages(t *testing.T) {
	store, _ := New(t.TempDir())
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 8, 8))); err != nil {
		t.Fatalf("encode: %v", err)
	}
	saved, err := store.SaveMedia(&buf, 1<<20, 1<<20)
	if err != nil {
		t.Fatalf("SaveMedia: %v", err)
	}
	if saved.Mime != "image/png" {
		t.Errorf("mime = %q, want image/png", saved.Mime)
	}
	if saved.DurationMs != 0 {
		t.Errorf("DurationMs = %d, want 0", saved.DurationMs)
	}
}
