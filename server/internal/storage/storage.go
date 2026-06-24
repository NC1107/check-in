// Package storage handles safe media uploads to the local filesystem. Images are
// re-encoded (which strips EXIF/GPS metadata), given random filenames, and validated
// for type and size.
package storage

import (
	"bytes"
	"crypto/rand"
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
