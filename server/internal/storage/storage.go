// Package storage handles safe media uploads to the local filesystem. Everything stored
// gets a random filename, a size limit, and a validated type - but "stripped of metadata by
// re-encoding" is no longer the whole privacy contract, because not every medium survives a
// re-encode. Each type has its own boundary:
//
//   - JPEG, PNG and WebP are decoded and re-encoded. The output shares no bytes with the
//     input, so EXIF (and the GPS in it) cannot survive.
//   - GIF is stored as uploaded, because re-encoding it destroys the animation that is the
//     whole point of accepting it. It has no EXIF to strip; its metadata channels are
//     comment and application extension blocks, which sanitizeGIF blanks.
//   - MP4 is stored as uploaded, because re-encoding video needs a transcoder this server
//     deliberately does not have. Its location and device atoms are blanked in place by
//     stripLocationMetadata.
//
// A future reader tempted to "fix" the passthrough paths by routing them back through the
// image encoder should know that both were passthrough on purpose, and that the sanitizers
// are what replaces the re-encode.
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
	_ "golang.org/x/image/webp" // the app already uploads webp; without this it is rejected
)

// maxDimension is the largest width/height kept; larger images are scaled down.
const maxDimension = 1600

// maxPixels guards against decompression/"pixel bomb" attacks: a few KB of input can
// declare enormous dimensions, and a decoder allocates a buffer proportional to W*H. 50 MP
// covers high-end phone cameras with margin.
const maxPixels = 50_000_000

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

// SavedMedia describes a stored file.
type SavedMedia struct {
	// RelPath is the path relative to the base dir (stored in the DB).
	RelPath string
	Mime    string
	Width   int
	Height  int
	// DurationMs is how long a timed medium runs; 0 for stills.
	DurationMs int
}

// SaveMedia stores an uploaded file of any supported type, picking the pipeline that fits
// it. Images and videos have separate size limits, so the caller passes both and the
// per-type check happens here, once the type is actually known.
func (s *Store) SaveMedia(r io.Reader, maxImageBytes, maxVideoBytes int64) (SavedMedia, error) {
	data, err := readCapped(r, max(maxImageBytes, maxVideoBytes))
	if err != nil {
		return SavedMedia{}, err
	}
	switch {
	case isMP4(data):
		if int64(len(data)) > maxVideoBytes {
			return SavedMedia{}, fmt.Errorf("video exceeds %d bytes", maxVideoBytes)
		}
		return s.saveVideo(data)
	case isGIF(data):
		if int64(len(data)) > maxImageBytes {
			return SavedMedia{}, fmt.Errorf("image exceeds %d bytes", maxImageBytes)
		}
		return s.saveGIF(data)
	default:
		if int64(len(data)) > maxImageBytes {
			return SavedMedia{}, fmt.Errorf("image exceeds %d bytes", maxImageBytes)
		}
		return s.saveImage(data)
	}
}

// SaveImage decodes, downscales if needed, re-encodes (stripping metadata), and writes
// an image. Decoding untrusted input through the standard library and re-encoding is the
// safety boundary: we never persist the raw uploaded bytes. An animated GIF loses its
// animation here, which is why SaveMedia routes GIF uploads elsewhere; this path is for
// callers that specifically want a still image, such as a video's poster frame.
func (s *Store) SaveImage(r io.Reader, maxBytes int64) (SavedMedia, error) {
	data, err := readCapped(r, maxBytes)
	if err != nil {
		return SavedMedia{}, err
	}
	if int64(len(data)) > maxBytes {
		return SavedMedia{}, fmt.Errorf("image exceeds %d bytes", maxBytes)
	}
	return s.saveImage(data)
}

// readCapped reads at most maxBytes+1 bytes, so the caller can tell "at the limit" from
// "over it" without buffering an unbounded upload.
func readCapped(r io.Reader, maxBytes int64) ([]byte, error) {
	return io.ReadAll(io.LimitReader(r, maxBytes+1))
}

func (s *Store) saveImage(data []byte) (SavedMedia, error) {
	// Check the header before decoding, so a pixel bomb is rejected without ever
	// allocating the buffer it asks for.
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(data)); err != nil {
		return SavedMedia{}, fmt.Errorf("decode image: %w", err)
	} else if int64(cfg.Width)*int64(cfg.Height) > maxPixels {
		return SavedMedia{}, fmt.Errorf("image dimensions too large")
	}

	img, format, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return SavedMedia{}, fmt.Errorf("decode image: %w", err)
	}
	// Downscale before applying orientation. Both steps allocate a fresh buffer, but the
	// rotate/flip is the expensive one — done on the full-resolution image, a portrait
	// 48MP photo allocates a ~190MB RGBA copy just to turn it upright, which OOM-kills a
	// memory-capped container. Rotating the already-shrunk image keeps the peak bounded to
	// ~maxDimension². Orientation commutes with a uniform downscale, so the result matches.
	img = downscale(img)
	// Phone cameras record orientation in EXIF rather than rotating pixels; the stdlib
	// decoder ignores it, so apply it here or portrait photos come out sideways/upside down.
	if format == "jpeg" {
		if o := exifOrientation(data); o > 1 {
			img = applyOrientation(img, o)
		}
	}

	var buf bytes.Buffer
	var mime, ext string
	switch format {
	case "png":
		if err := png.Encode(&buf, img); err != nil {
			return SavedMedia{}, err
		}
		mime, ext = "image/png", ".png"
	default: // jpeg, webp, gif and anything else are normalized to jpeg
		if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85}); err != nil {
			return SavedMedia{}, err
		}
		mime, ext = "image/jpeg", ".jpg"
	}

	rel, err := s.write(buf.Bytes(), ext)
	if err != nil {
		return SavedMedia{}, err
	}

	b := img.Bounds()
	return SavedMedia{RelPath: rel, Mime: mime, Width: b.Dx(), Height: b.Dy()}, nil
}

// saveGIF stores an animated GIF as uploaded, after checking its dimensions, counting its
// frames and blanking its metadata blocks. Nothing is re-encoded: gif.EncodeAll would
// re-quantize every frame, and a round trip through it is both slow and visibly lossy.
func (s *Store) saveGIF(data []byte) (SavedMedia, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return SavedMedia{}, fmt.Errorf("decode image: %w", err)
	}
	if int64(cfg.Width)*int64(cfg.Height) > maxPixels {
		return SavedMedia{}, fmt.Errorf("image dimensions too large")
	}
	if _, err := sanitizeGIF(data); err != nil {
		return SavedMedia{}, err
	}
	rel, err := s.write(data, ".gif")
	if err != nil {
		return SavedMedia{}, err
	}
	return SavedMedia{RelPath: rel, Mime: "image/gif", Width: cfg.Width, Height: cfg.Height}, nil
}

// saveVideo validates a clip's container, reads its duration and display size, and stores
// it with its location and device metadata blanked.
func (s *Store) saveVideo(data []byte) (SavedMedia, error) {
	info, err := probeMP4(data)
	if err != nil {
		return SavedMedia{}, err
	}
	rel, err := s.write(stripLocationMetadata(data), ".mp4")
	if err != nil {
		return SavedMedia{}, err
	}
	return SavedMedia{
		RelPath:    rel,
		Mime:       "video/mp4",
		Width:      info.Width,
		Height:     info.Height,
		DurationMs: info.DurationMs,
	}, nil
}

// write stores bytes under a random name and returns the path relative to the base dir.
func (s *Store) write(data []byte, ext string) (string, error) {
	name, err := randomName()
	if err != nil {
		return "", err
	}
	// Shard by first two chars to avoid huge flat directories.
	rel := filepath.Join(name[:2], name+ext)
	abs := filepath.Join(s.baseDir, rel)
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(abs, data, 0o644); err != nil {
		return "", err
	}
	return rel, nil
}

// isGIF and isMP4 identify the two passthrough types from their magic bytes, before any
// decoder sees the file. Everything else falls through to the image pipeline, which
// rejects what it cannot decode.
func isGIF(data []byte) bool {
	return len(data) > 3 && string(data[0:3]) == "GIF"
}

func isMP4(data []byte) bool {
	return len(data) > 8 && string(data[4:8]) == "ftyp"
}

// Open returns a reader for a stored file given its relative path. The path is cleaned
// and confined to the base directory to prevent traversal.
func (s *Store) Open(relPath string) (*os.File, error) {
	clean := filepath.Clean("/" + relPath) // force absolute, removes ../
	abs := filepath.Join(s.baseDir, clean)
	return os.Open(abs)
}

// Delete removes a stored file given its relative path, confined to the base directory.
// A missing file is treated as success, since the row may already be gone.
func (s *Store) Delete(relPath string) error {
	clean := filepath.Clean("/" + relPath) // force absolute, removes ../
	abs := filepath.Join(s.baseDir, clean)
	if err := os.Remove(abs); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
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
