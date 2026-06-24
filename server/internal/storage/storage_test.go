package storage

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"testing"
)

func TestSaveImageReencodesAndStores(t *testing.T) {
	dir := t.TempDir()
	store, err := New(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	// Build a small in-memory PNG.
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode: %v", err)
	}

	saved, err := store.SaveImage(&buf, 1<<20)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if saved.Mime != "image/png" {
		t.Errorf("mime = %q, want image/png", saved.Mime)
	}
	if saved.Width != 4 || saved.Height != 4 {
		t.Errorf("dimensions = %dx%d, want 4x4", saved.Width, saved.Height)
	}

	f, err := store.Open(saved.RelPath)
	if err != nil {
		t.Fatalf("open saved: %v", err)
	}
	f.Close()
}

func TestSaveImageRejectsNonImage(t *testing.T) {
	store, _ := New(t.TempDir())
	_, err := store.SaveImage(bytes.NewReader([]byte("not an image")), 1<<20)
	if err == nil {
		t.Error("expected error decoding non-image data")
	}
}

func TestSaveImageEnforcesSizeLimit(t *testing.T) {
	store, _ := New(t.TempDir())
	big := bytes.Repeat([]byte{0xFF}, 100)
	_, err := store.SaveImage(bytes.NewReader(big), 10)
	if err == nil {
		t.Error("expected size-limit error")
	}
}

func TestOpenRejectsTraversal(t *testing.T) {
	store, _ := New(t.TempDir())
	// Traversal attempts are cleaned and confined to the base dir, so this resolves
	// inside the base directory and simply fails to find the file (no escape).
	if _, err := store.Open("../../etc/passwd"); err == nil {
		t.Error("expected traversal path to not open a file outside base dir")
	}
}
