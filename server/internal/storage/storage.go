// Package storage handles safe media uploads to the local filesystem. Images are
// re-encoded (which strips EXIF/GPS metadata), given random filenames, and validated
// for type and size.
package storage

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"os"
	"path/filepath"

	_ "image/gif" // register decoders

	"golang.org/x/image/draw"
)

// maxDimension is the largest width/height kept; larger images are scaled down.
const maxDimension = 1600

// Store writes media files under a base directory.
type Store struct {
	baseDir string
}

// New creates a Store, ensuring the base directory exists.
func New(baseDir string) (*Store, error) {
	if err := os.MkdirAll(baseDir, 0o755); err != nil {
		return nil, err
	}
	return &Store{baseDir: baseDir}, nil
}

// SavedImage describes a stored image.
type SavedImage struct {
	// RelPath is the path relative to the base dir (stored in the DB).
	RelPath string
	Mime    string
	Width   int
	Height  int
}

// SaveImage decodes, downscales if needed, re-encodes (stripping metadata), and writes
// an image. Decoding untrusted input through the standard library and re-encoding is the
// safety boundary: we never persist the raw uploaded bytes.
func (s *Store) SaveImage(r io.Reader, maxBytes int64) (SavedImage, error) {
	limited := io.LimitReader(r, maxBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return SavedImage{}, err
	}
	if int64(len(data)) > maxBytes {
		return SavedImage{}, fmt.Errorf("image exceeds %d bytes", maxBytes)
	}

	img, format, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return SavedImage{}, fmt.Errorf("decode image: %w", err)
	}
	// Phone cameras record orientation in EXIF rather than rotating pixels; the stdlib
	// decoder ignores it, so apply it here or portrait photos come out sideways/upside down.
	if format == "jpeg" {
		if o := exifOrientation(data); o > 1 {
			img = applyOrientation(img, o)
		}
	}
	img = downscale(img)

	var buf bytes.Buffer
	var mime, ext string
	switch format {
	case "png":
		if err := png.Encode(&buf, img); err != nil {
			return SavedImage{}, err
		}
		mime, ext = "image/png", ".png"
	default: // jpeg, gif and anything else are normalized to jpeg
		if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85}); err != nil {
			return SavedImage{}, err
		}
		mime, ext = "image/jpeg", ".jpg"
	}

	name, err := randomName()
	if err != nil {
		return SavedImage{}, err
	}
	// Shard by first two chars to avoid huge flat directories.
	rel := filepath.Join(name[:2], name+ext)
	abs := filepath.Join(s.baseDir, rel)
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return SavedImage{}, err
	}
	if err := os.WriteFile(abs, buf.Bytes(), 0o644); err != nil {
		return SavedImage{}, err
	}

	b := img.Bounds()
	return SavedImage{RelPath: rel, Mime: mime, Width: b.Dx(), Height: b.Dy()}, nil
}

// Open returns a reader for a stored file given its relative path. The path is cleaned
// and confined to the base directory to prevent traversal.
func (s *Store) Open(relPath string) (*os.File, error) {
	clean := filepath.Clean("/" + relPath) // force absolute, removes ../
	abs := filepath.Join(s.baseDir, clean)
	return os.Open(abs)
}

func downscale(img image.Image) image.Image {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= maxDimension && h <= maxDimension {
		return img
	}
	var nw, nh int
	if w >= h {
		nw = maxDimension
		nh = h * maxDimension / w
	} else {
		nh = maxDimension
		nw = w * maxDimension / h
	}
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, b, draw.Over, nil)
	return dst
}

func randomName() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// exifOrientation extracts the EXIF orientation tag (1–8) from JPEG bytes, returning 1
// (normal) when absent or unparseable. It walks JPEG markers to the APP1/Exif segment and
// reads tag 0x0112 from IFD0. Bounds are checked throughout so malformed input is safe.
func exifOrientation(data []byte) int {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return 1
	}
	i := 2
	for i+4 <= len(data) {
		if data[i] != 0xFF {
			return 1
		}
		marker := data[i+1]
		if marker == 0xDA || marker == 0xD9 { // start-of-scan / end — no metadata past here
			return 1
		}
		size := int(data[i+2])<<8 | int(data[i+3])
		if size < 2 || i+2+size > len(data) {
			return 1
		}
		if marker == 0xE1 { // APP1
			if o := parseExifOrientation(data[i+4 : i+2+size]); o != 0 {
				return o
			}
		}
		i += 2 + size
	}
	return 1
}

func parseExifOrientation(seg []byte) int {
	if len(seg) < 14 || string(seg[0:6]) != "Exif\x00\x00" {
		return 0
	}
	tiff := seg[6:]
	var bo binary.ByteOrder
	switch string(tiff[0:2]) {
	case "II":
		bo = binary.LittleEndian
	case "MM":
		bo = binary.BigEndian
	default:
		return 0
	}
	ifd := int(bo.Uint32(tiff[4:8]))
	if ifd+2 > len(tiff) || ifd < 0 {
		return 0
	}
	count := int(bo.Uint16(tiff[ifd : ifd+2]))
	for j := 0; j < count; j++ {
		e := ifd + 2 + j*12
		if e+12 > len(tiff) {
			return 0
		}
		if bo.Uint16(tiff[e:e+2]) == 0x0112 { // Orientation
			v := int(bo.Uint16(tiff[e+8 : e+10]))
			if v >= 1 && v <= 8 {
				return v
			}
			return 0
		}
	}
	return 0
}

// applyOrientation returns img transformed so it displays upright for the given EXIF
// orientation value (1–8).
func applyOrientation(img image.Image, o int) image.Image {
	switch o {
	case 2:
		return flip(img, true)
	case 3:
		return rotate(img, 180)
	case 4:
		return flip(img, false)
	case 5:
		return rotate(flip(img, true), 270)
	case 6:
		return rotate(img, 90)
	case 7:
		return rotate(flip(img, true), 90)
	case 8:
		return rotate(img, 270)
	default:
		return img
	}
}

// rotate turns img clockwise by 90, 180, or 270 degrees.
func rotate(src image.Image, deg int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	var dst *image.RGBA
	switch deg {
	case 90:
		dst = image.NewRGBA(image.Rect(0, 0, h, w))
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				dst.Set(h-1-y, x, src.At(b.Min.X+x, b.Min.Y+y))
			}
		}
	case 270:
		dst = image.NewRGBA(image.Rect(0, 0, h, w))
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				dst.Set(y, w-1-x, src.At(b.Min.X+x, b.Min.Y+y))
			}
		}
	default: // 180
		dst = image.NewRGBA(image.Rect(0, 0, w, h))
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				dst.Set(w-1-x, h-1-y, src.At(b.Min.X+x, b.Min.Y+y))
			}
		}
	}
	return dst
}

// flip mirrors img horizontally (horizontal=true) or vertically.
func flip(src image.Image, horizontal bool) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if horizontal {
				dst.Set(w-1-x, y, src.At(b.Min.X+x, b.Min.Y+y))
			} else {
				dst.Set(x, h-1-y, src.At(b.Min.X+x, b.Min.Y+y))
			}
		}
	}
	return dst
}
