package storage

import (
	"bytes"
	"image"
	"image/color"
	"image/gif"
	"os"
	"path/filepath"
	"testing"
)

// gifStream hand-builds a GIF block stream: header, logical screen descriptor with no
// global color table, then whatever blocks the test needs, then the trailer. Only the
// block structure matters here - sanitizeGIF never touches pixel data.
func gifStream(blocks ...[]byte) []byte {
	var b bytes.Buffer
	b.WriteString("GIF89a")
	b.Write([]byte{1, 0, 1, 0, 0x00, 0, 0}) // 1x1, no global color table
	for _, blk := range blocks {
		b.Write(blk)
	}
	b.WriteByte(gifTrailer)
	return b.Bytes()
}

// gifFrame is an image descriptor with an empty (terminated) LZW sub-block chain.
func gifFrame() []byte {
	return []byte{
		gifImageDescriptor,
		0, 0, 0, 0, // position
		1, 0, 1, 0, // 1x1
		0x00, // packed: no local color table
		0x02, // LZW minimum code size
		0x00, // block terminator
	}
}

func gifExtension(label byte, subBlocks ...[]byte) []byte {
	out := []byte{gifExtensionIntroducer, label}
	for _, sb := range subBlocks {
		out = append(out, byte(len(sb)))
		out = append(out, sb...)
	}
	return append(out, 0x00)
}

func TestSanitizeGIFCountsFrames(t *testing.T) {
	frames, err := sanitizeGIF(gifStream(gifFrame(), gifFrame(), gifFrame()))
	if err != nil {
		t.Fatalf("sanitizeGIF: %v", err)
	}
	if frames != 3 {
		t.Errorf("frames = %d, want 3", frames)
	}
}

// The stdlib GIF decoder has no frame limit, so a tiny file can declare enough frames to
// exhaust memory on every client that renders it.
func TestSanitizeGIFRejectsFrameBomb(t *testing.T) {
	blocks := make([][]byte, maxGIFFrames+1)
	for i := range blocks {
		blocks[i] = gifFrame()
	}
	if _, err := sanitizeGIF(gifStream(blocks...)); err == nil {
		t.Fatal("expected rejection of a gif over the frame cap")
	}
	blocks = blocks[:maxGIFFrames]
	if _, err := sanitizeGIF(gifStream(blocks...)); err != nil {
		t.Fatalf("a gif exactly at the frame cap must be accepted: %v", err)
	}
}

func TestSanitizeGIFBlanksMetadataBlocks(t *testing.T) {
	secret := []byte("GPS 51.5074,-0.1278")
	xmp := []byte("XMP DataXMP")
	data := gifStream(
		gifExtension(gifCommentLabel, secret),
		gifExtension(gifApplicationLabel, xmp, secret),
		gifFrame(),
	)
	before := len(data)

	frames, err := sanitizeGIF(data)
	if err != nil {
		t.Fatalf("sanitizeGIF: %v", err)
	}
	if frames != 1 {
		t.Errorf("frames = %d, want 1", frames)
	}
	if len(data) != before {
		t.Errorf("length changed: %d -> %d, blanking must preserve the block structure", before, len(data))
	}
	if bytes.Contains(data, secret) {
		t.Error("comment/application payload survived sanitizing")
	}
}

// Blanking the loop-control extension would leave every stored animation playing exactly
// once, so it is preserved - but only in the exact shape that carries nothing else.
func TestSanitizeGIFKeepsLoopControl(t *testing.T) {
	loop := gifExtension(gifApplicationLabel, []byte("NETSCAPE2.0"), []byte{0x01, 0x00, 0x00})
	data := gifStream(loop, gifFrame())
	if _, err := sanitizeGIF(data); err != nil {
		t.Fatalf("sanitizeGIF: %v", err)
	}
	if !bytes.Contains(data, []byte("NETSCAPE2.0")) {
		t.Error("loop control extension was blanked; animations would stop looping")
	}

	// The same identifier wrapped around a real payload is not loop control.
	smuggled := gifExtension(gifApplicationLabel, []byte("NETSCAPE2.0"), []byte("GPS 51.5074,-0.1278"))
	data = gifStream(smuggled, gifFrame())
	if _, err := sanitizeGIF(data); err != nil {
		t.Fatalf("sanitizeGIF: %v", err)
	}
	if bytes.Contains(data, []byte("51.5074")) {
		t.Error("payload smuggled behind the loop-control identifier survived sanitizing")
	}
}

// A chain of many tiny sub-blocks under the loop-control identifier is the shape the
// original small-sub-blocks check waved through: each piece is within the 3-byte budget,
// but the chain as a whole carries an arbitrary payload. Only the exact one-sub-block
// loop-control form may survive blanking.
func TestSanitizeGIFBlanksChunkedSmuggleUnderLoopControlName(t *testing.T) {
	// Each smuggled token fits one 3-byte sub-block exactly, so it stays contiguous in
	// the stream: length bytes between chunks would break up anything longer, which is
	// what made an earlier version of this test pass no matter what the code did.
	data := gifStream(gifExtension(gifApplicationLabel,
		[]byte("NETSCAPE2.0"),
		[]byte("GPS"), []byte("LAT"), []byte("LON"), []byte("DEV"),
	), gifFrame())
	if _, err := sanitizeGIF(data); err != nil {
		t.Fatalf("sanitizeGIF: %v", err)
	}
	for _, token := range []string{"GPS", "LAT", "LON", "DEV"} {
		if bytes.Contains(data, []byte(token)) {
			t.Errorf("chunked %q under the loop-control identifier survived sanitizing", token)
		}
	}
}

func TestSanitizeGIFRejectsMalformedStream(t *testing.T) {
	cases := map[string][]byte{
		"empty":            nil,
		"header only":      []byte("GIF89a"),
		"no trailer":       gifStream()[:13],
		"unknown block":    append(gifStream()[:13], 0x99, 0x3B),
		"truncated frame":  append(gifStream()[:13], gifFrame()[:5]...),
		"unterminated ext": append(gifStream()[:13], gifExtensionIntroducer, gifCommentLabel, 0x04, 'a'),
	}
	for name, data := range cases {
		if _, err := sanitizeGIF(data); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

// The whole reason GIFs are stored as uploaded: a real animation has to come back out with
// every frame it went in with.
func TestSaveMediaPreservesGIFAnimation(t *testing.T) {
	dir := t.TempDir()
	store, err := New(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	var buf bytes.Buffer
	if err := gif.EncodeAll(&buf, animation(3)); err != nil {
		t.Fatalf("encode: %v", err)
	}
	saved, err := store.SaveMedia(&buf, 1<<20, 1<<20)
	if err != nil {
		t.Fatalf("SaveMedia: %v", err)
	}
	if saved.Mime != "image/gif" {
		t.Fatalf("mime = %q, want image/gif (re-encoding would flatten the animation)", saved.Mime)
	}
	if saved.Width != 4 || saved.Height != 4 {
		t.Errorf("dims = %dx%d, want 4x4", saved.Width, saved.Height)
	}
	if saved.DurationMs != 0 {
		t.Errorf("DurationMs = %d, want 0 for a still-image medium", saved.DurationMs)
	}

	stored, err := os.ReadFile(filepath.Join(dir, saved.RelPath))
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	out, err := gif.DecodeAll(bytes.NewReader(stored))
	if err != nil {
		t.Fatalf("decode stored gif: %v", err)
	}
	if len(out.Image) != 3 {
		t.Errorf("stored gif has %d frames, want the 3 that were uploaded", len(out.Image))
	}
}

func animation(frames int) *gif.GIF {
	out := &gif.GIF{}
	for i := 0; i < frames; i++ {
		img := image.NewPaletted(image.Rect(0, 0, 4, 4), color.Palette{color.Black, color.White})
		img.SetColorIndex(i%4, 0, 1)
		out.Image = append(out.Image, img)
		out.Delay = append(out.Delay, 10)
	}
	return out
}
