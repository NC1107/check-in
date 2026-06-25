package storage

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func TestSaveImageHappyPath(t *testing.T) {
	dir := t.TempDir()
	s, err := New(dir)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 4, 4))); err != nil {
		t.Fatalf("encode: %v", err)
	}
	saved, err := s.SaveImage(&buf, 1<<20)
	if err != nil {
		t.Fatalf("SaveImage: %v", err)
	}
	if saved.Width != 4 || saved.Height != 4 {
		t.Errorf("dims = %dx%d, want 4x4", saved.Width, saved.Height)
	}
	if _, err := os.Stat(filepath.Join(dir, saved.RelPath)); err != nil {
		t.Errorf("written file missing: %v", err)
	}
}

func TestSaveImageRejectsOversizedBytes(t *testing.T) {
	s, _ := New(t.TempDir())
	if _, err := s.SaveImage(bytes.NewReader(bytes.Repeat([]byte{0}, 100)), 10); err == nil {
		t.Fatal("expected rejection when input exceeds maxBytes")
	}
}

func TestSaveImageRejectsHugeDimensions(t *testing.T) {
	s, _ := New(t.TempDir())
	// A valid PNG header declaring 70000×70000 (~4.9 GP) — a classic "pixel bomb".
	// DecodeConfig reads only the header, so SaveImage must reject before decoding.
	if _, err := s.SaveImage(bytes.NewReader(pngHeader(70000, 70000)), 1<<20); err == nil {
		t.Fatal("expected rejection of oversized image dimensions")
	}
}

// pngHeader builds a minimal PNG (signature + valid IHDR chunk) declaring the given
// dimensions. Enough for image.DecodeConfig to report width/height.
func pngHeader(w, h uint32) []byte {
	var b bytes.Buffer
	b.Write([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a})
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], w)
	binary.BigEndian.PutUint32(ihdr[4:], h)
	ihdr[8] = 8 // bit depth
	ihdr[9] = 6 // color type: RGBA
	typeAndData := append([]byte("IHDR"), ihdr...)
	_ = binary.Write(&b, binary.BigEndian, uint32(13))
	b.Write(typeAndData)
	_ = binary.Write(&b, binary.BigEndian, crc32.ChecksumIEEE(typeAndData))
	return b.Bytes()
}
