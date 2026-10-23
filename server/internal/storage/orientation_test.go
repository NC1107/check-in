package storage

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"testing"
)

// marked is a 3 wide by 2 tall image whose every pixel is distinct, so any rotation or flip
// that lands a pixel in the wrong place shows up as a specific coordinate.
func marked() *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, 3, 2))
	for y := 0; y < 2; y++ {
		for x := 0; x < 3; x++ {
			img.Set(x, y, color.RGBA{R: uint8(10 + x*40), G: uint8(10 + y*100), B: 200, A: 255})
		}
	}
	return img
}

func samePixel(a, b color.Color) bool {
	ar, ag, ab, aa := a.RGBA()
	br, bg, bb, ba := b.RGBA()
	return ar == br && ag == bg && ab == bb && aa == ba
}

func TestRotateMovesPixelsClockwise(t *testing.T) {
	src := marked()
	tests := []struct {
		deg    int
		w, h   int
		sx, sy int
		dx, dy int
	}{
		{90, 2, 3, 0, 0, 1, 0},
		{90, 2, 3, 2, 1, 0, 2},
		{180, 3, 2, 0, 0, 2, 1},
		{180, 3, 2, 2, 0, 0, 1},
		{270, 2, 3, 0, 0, 0, 2},
		{270, 2, 3, 2, 1, 1, 0},
	}
	for _, tc := range tests {
		got := rotate(src, tc.deg)
		b := got.Bounds()
		if b.Dx() != tc.w || b.Dy() != tc.h {
			t.Fatalf("rotate %d: size %dx%d, want %dx%d", tc.deg, b.Dx(), b.Dy(), tc.w, tc.h)
		}
		if !samePixel(got.At(tc.dx, tc.dy), src.At(tc.sx, tc.sy)) {
			t.Errorf("rotate %d: pixel (%d,%d) did not land at (%d,%d)", tc.deg, tc.sx, tc.sy, tc.dx, tc.dy)
		}
	}
}

func TestApplyOrientationDimensions(t *testing.T) {
	for o := 1; o <= 8; o++ {
		b := applyOrientation(marked(), o).Bounds()
		wantW, wantH := 3, 2
		if o >= 5 {
			wantW, wantH = 2, 3
		}
		if b.Dx() != wantW || b.Dy() != wantH {
			t.Errorf("orientation %d: %dx%d, want %dx%d", o, b.Dx(), b.Dy(), wantW, wantH)
		}
	}
}

// jpegWithOrientation encodes a w by h JPEG and splices an APP1 Exif segment holding the
// orientation tag straight after the SOI marker.
func jpegWithOrientation(t *testing.T, w, h, orientation int, order binary.ByteOrder) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewRGBA(image.Rect(0, 0, w, h)), nil); err != nil {
		t.Fatal(err)
	}
	enc := buf.Bytes()

	tiff := make([]byte, 8+2+12+4)
	if order == binary.LittleEndian {
		copy(tiff, "II")
	} else {
		copy(tiff, "MM")
	}
	order.PutUint16(tiff[2:], 42)
	order.PutUint32(tiff[4:], 8)
	order.PutUint16(tiff[8:], 1)
	order.PutUint16(tiff[10:], 0x0112)
	order.PutUint16(tiff[12:], 3)
	order.PutUint32(tiff[14:], 1)
	order.PutUint16(tiff[18:], uint16(orientation))

	payload := append([]byte("Exif\x00\x00"), tiff...)
	seg := []byte{0xFF, 0xE1, byte((len(payload) + 2) >> 8), byte(len(payload) + 2)}
	seg = append(seg, payload...)

	out := append([]byte{}, enc[:2]...)
	out = append(out, seg...)
	return append(out, enc[2:]...)
}

func TestExifOrientationRead(t *testing.T) {
	for _, order := range []binary.ByteOrder{binary.LittleEndian, binary.BigEndian} {
		for o := 1; o <= 8; o++ {
			if got := exifOrientation(jpegWithOrientation(t, 8, 8, o, order)); got != o {
				t.Errorf("%v orientation %d read as %d", order, o, got)
			}
		}
	}
}

func TestSaveMediaAppliesExifOrientation(t *testing.T) {
	store, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for o := 1; o <= 8; o++ {
		data := jpegWithOrientation(t, 24, 8, o, binary.BigEndian)
		saved, err := store.SaveMedia(bytes.NewReader(data), 1<<20, 1<<20)
		if err != nil {
			t.Fatalf("orientation %d: %v", o, err)
		}
		wantW, wantH := 24, 8
		if o >= 5 {
			wantW, wantH = 8, 24
		}
		if saved.Width != wantW || saved.Height != wantH {
			t.Errorf("orientation %d stored as %dx%d, want %dx%d", o, saved.Width, saved.Height, wantW, wantH)
		}
	}
}

func TestJpegSegmentRejectsBadInput(t *testing.T) {
	tests := []struct {
		name string
		data []byte
	}{
		{"not a marker", []byte{0x00, 0xE1, 0x00, 0x10, 0, 0, 0, 0}},
		{"start of scan", []byte{0xFF, 0xDA, 0x00, 0x08, 0, 0, 0, 0}},
		{"end of image", []byte{0xFF, 0xD9, 0x00, 0x08, 0, 0, 0, 0}},
		{"size under 2", []byte{0xFF, 0xE1, 0x00, 0x01, 0, 0, 0, 0}},
		{"size past data", []byte{0xFF, 0xE1, 0x01, 0x00, 0, 0, 0, 0}},
	}
	for _, tc := range tests {
		if _, _, ok := jpegSegment(tc.data, 0); ok {
			t.Errorf("%s: accepted", tc.name)
		}
		full := append([]byte{0xFF, 0xD8}, tc.data...)
		if got := exifOrientation(full); got != 1 {
			t.Errorf("%s: orientation %d, want 1", tc.name, got)
		}
	}
	if got := exifOrientation([]byte{0xFF, 0xD8, 0xFF, 0xE1, 0x00}); got != 1 {
		t.Errorf("truncated header: orientation %d, want 1", got)
	}
}

func FuzzExifOrientation(f *testing.F) {
	f.Add([]byte{0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x04, 0, 0})
	f.Add([]byte{})
	f.Fuzz(func(t *testing.T, data []byte) {
		if o := exifOrientation(data); o < 1 || o > 8 {
			t.Fatalf("orientation %d out of range", o)
		}
	})
}
