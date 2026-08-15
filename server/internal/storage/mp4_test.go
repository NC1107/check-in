package storage

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
)

// The MP4 helpers below hand-build box structures the same way pngHeader hand-builds a PNG
// header: real files are megabytes of sample data wrapped around a few hundred bytes of
// structure, and only the structure is under test.

func box(typ string, payload ...[]byte) []byte {
	body := bytes.Join(payload, nil)
	out := make([]byte, 0, 8+len(body))
	out = binary.BigEndian.AppendUint32(out, uint32(8+len(body)))
	out = append(out, typ...)
	return append(out, body...)
}

func be32(v uint32) []byte { return binary.BigEndian.AppendUint32(nil, v) }
func be64(v uint64) []byte { return binary.BigEndian.AppendUint64(nil, v) }

func ftyp(brand string) []byte {
	return box("ftyp", []byte(brand), be32(512), []byte(brand))
}

// mvhdV0 builds a version-0 movie header declaring a duration in milliseconds.
func mvhdV0(durationMs uint32) []byte {
	return box("mvhd",
		be32(0),          // version 0 + flags
		be32(0), be32(0), // creation, modification
		be32(1000),        // timescale: 1 unit == 1ms
		be32(durationMs),  // duration
		be32(0x00010000),  // rate
		[]byte{1, 0},      // volume
		make([]byte, 2+8), // reserved
		identityMatrix(),
		make([]byte, 24), // pre_defined
		be32(2),          // next track id
	)
}

// mvhdV1 is the 64-bit variant, which files longer than a few hours and some encoders use
// unconditionally.
func mvhdV1(durationMs uint64) []byte {
	return box("mvhd",
		[]byte{1, 0, 0, 0}, // version 1 + flags
		be64(0), be64(0),   // creation, modification
		be32(1000),        // timescale
		be64(durationMs),  // duration
		be32(0x00010000),  // rate
		[]byte{1, 0},      // volume
		make([]byte, 2+8), // reserved
		identityMatrix(),
		make([]byte, 24),
		be32(2),
	)
}

func identityMatrix() []byte {
	return matrix(0x00010000, 0, 0, 0, 0x00010000, 0)
}

// quarterTurnMatrix is what a phone writes when it was held upright: the stored frame is
// landscape and the display matrix turns it.
func quarterTurnMatrix() []byte {
	return matrix(0, 0x00010000, 0, -0x00010000, 0, 0)
}

func matrix(a, b, u, c, d, v int32) []byte {
	out := make([]byte, 0, 36)
	for _, n := range []int32{a, b, u, c, d, v, 0, 0} {
		out = binary.BigEndian.AppendUint32(out, uint32(n))
	}
	return binary.BigEndian.AppendUint32(out, 0x40000000)
}

func tkhd(width, height uint32, m []byte) []byte {
	return box("tkhd",
		be32(0),          // version 0 + flags
		be32(0), be32(0), // creation, modification
		be32(1),         // track id
		be32(0),         // reserved
		be32(0),         // duration
		make([]byte, 8), // reserved
		make([]byte, 8), // layer, alternate group, volume, reserved
		m,
		be32(width<<16), be32(height<<16), // 16.16 fixed point
	)
}

func mdhd(timescale, duration uint32) []byte {
	return box("mdhd",
		be32(0),          // version 0 + flags
		be32(0), be32(0), // creation, modification
		be32(timescale),
		be32(duration),
		be32(0), // language + pre_defined
	)
}

func stts(count, delta uint32) []byte {
	return box("stts", be32(0), be32(1), be32(count), be32(delta))
}

// clip assembles a playable-looking file: ftyp, a movie header, one video track, and a
// (empty) mdat so the layout matches a real one.
func clip(mvhd []byte, trakChildren ...[]byte) []byte {
	return bytes.Join([][]byte{
		ftyp("isom"),
		box("moov", mvhd, box("trak", trakChildren...)),
		box("mdat", make([]byte, 64)),
	}, nil)
}

func videoTrack() [][]byte {
	return [][]byte{
		tkhd(1920, 1080, identityMatrix()),
		box("mdia", mdhd(1000, 0), box("minf", box("stbl", stts(0, 0)))),
	}
}

func TestProbeMP4ReadsDurationAndDimensions(t *testing.T) {
	info, err := probeMP4(clip(mvhdV0(5000), videoTrack()...))
	if err != nil {
		t.Fatalf("probeMP4: %v", err)
	}
	if info.DurationMs != 5000 {
		t.Errorf("DurationMs = %d, want 5000", info.DurationMs)
	}
	if info.Width != 1920 || info.Height != 1080 {
		t.Errorf("dims = %dx%d, want 1920x1080", info.Width, info.Height)
	}
}

func TestProbeMP4ReadsVersion1MovieHeader(t *testing.T) {
	info, err := probeMP4(clip(mvhdV1(7500), videoTrack()...))
	if err != nil {
		t.Fatalf("probeMP4: %v", err)
	}
	if info.DurationMs != 7500 {
		t.Errorf("DurationMs = %d, want 7500", info.DurationMs)
	}
}

// The 12s cap is the server's half of the 10s capture UI: a trim tool that lands a little
// over its nominal target still gets through, anything that is not a short clip does not.
func TestProbeMP4RejectsClipOverTheCap(t *testing.T) {
	if _, err := probeMP4(clip(mvhdV0(maxVideoDurationMs), videoTrack()...)); err != nil {
		t.Fatalf("a clip exactly at the cap must be accepted: %v", err)
	}
	_, err := probeMP4(clip(mvhdV0(maxVideoDurationMs+1), videoTrack()...))
	if err == nil {
		t.Fatal("expected rejection of a clip over the duration cap")
	}
	if !strings.Contains(err.Error(), "longer than") {
		t.Errorf("error = %v, want it to name the duration cap", err)
	}
}

func TestProbeMP4RejectsNonMP4(t *testing.T) {
	cases := map[string][]byte{
		"empty":     nil,
		"no ftyp":   box("moov", mvhdV0(1000)),
		"no moov":   ftyp("isom"),
		"not video": bytes.Join([][]byte{ftyp("heic"), box("moov", mvhdV0(1000))}, nil),
		"truncated": clip(mvhdV0(1000), videoTrack()...)[:20],
	}
	for name, data := range cases {
		if _, err := probeMP4(data); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

// A portrait phone clip stores landscape dimensions plus a quarter turn in the display
// matrix. Reporting the stored numbers would give every client the wrong aspect ratio.
func TestProbeMP4AppliesDisplayRotation(t *testing.T) {
	info, err := probeMP4(clip(mvhdV0(3000),
		tkhd(1920, 1080, quarterTurnMatrix()),
		box("mdia", mdhd(1000, 0), box("minf", box("stbl", stts(0, 0))))))
	if err != nil {
		t.Fatalf("probeMP4: %v", err)
	}
	if info.Width != 1080 || info.Height != 1920 {
		t.Errorf("dims = %dx%d, want 1080x1920 (rotated)", info.Width, info.Height)
	}
}

// A fragmented file legitimately reports mvhd.duration == 0, so the track headers and then
// the sample table have to be able to answer instead.
func TestProbeMP4FallsBackToTrackDuration(t *testing.T) {
	info, err := probeMP4(clip(mvhdV0(0),
		tkhd(640, 480, identityMatrix()),
		box("mdia", mdhd(600, 1800), box("minf", box("stbl", stts(0, 0))))))
	if err != nil {
		t.Fatalf("probeMP4: %v", err)
	}
	if info.DurationMs != 3000 {
		t.Errorf("DurationMs = %d, want 3000 (1800 units at timescale 600)", info.DurationMs)
	}
}

func TestProbeMP4FallsBackToSampleTable(t *testing.T) {
	info, err := probeMP4(clip(mvhdV0(0),
		tkhd(640, 480, identityMatrix()),
		box("mdia", mdhd(30000, 0), box("minf", box("stbl", stts(60, 1000))))))
	if err != nil {
		t.Fatalf("probeMP4: %v", err)
	}
	if info.DurationMs != 2000 {
		t.Errorf("DurationMs = %d, want 2000 (60 samples of 1000 at timescale 30000)", info.DurationMs)
	}
}

const gpsPayload = "\x00\x15\x15\xc7+51.5074-0.1278+015.000/"

// The length assertion is the point of this test, not a detail of it: stco/co64 hold
// absolute offsets into mdat, so a strip that removed the box instead of blanking it would
// shift every sample offset and produce a file that no longer plays. Length-preserving is
// the invariant, and it has to fail loudly if anyone "tidies" the strip into a rewrite.
func TestStripLocationMetadataZeroesCoordinatesInPlace(t *testing.T) {
	original := clip(mvhdV0(3000),
		append(videoTrack(), box("udta", box("\xa9xyz", []byte(gpsPayload))))...)

	stripped := stripLocationMetadata(append([]byte(nil), original...))

	if len(stripped) != len(original) {
		t.Fatalf("length changed: %d -> %d, the strip must zero bytes, never remove them",
			len(original), len(stripped))
	}
	if bytes.Contains(stripped, []byte("51.5074")) {
		t.Error("coordinates survived the strip")
	}
	if i := bytes.Index(original, []byte(gpsPayload)); !isZero(stripped[i : i+len(gpsPayload)]) {
		t.Errorf("payload at %d = %q, want all zero bytes", i, stripped[i:i+len(gpsPayload)])
	}
	// Everything that is not metadata has to come through untouched.
	if !bytes.Equal(stripped[:len(ftyp("isom"))], original[:len(ftyp("isom"))]) {
		t.Error("ftyp was modified")
	}
}

func TestStripLocationMetadataZeroesDeviceAtoms(t *testing.T) {
	original := clip(mvhdV0(3000), append(videoTrack(), box("udta",
		box("\xa9mak", []byte("Apple")),
		box("\xa9mod", []byte("iPhone 15 Pro")),
		box("\xa9swr", []byte("18.0")),
		box("\xa9day", []byte("2026-08-15T10:00:00+0100")),
		box("loci", []byte("\x00\x00\x00\x00home\x00\x00")),
	))...)

	stripped := stripLocationMetadata(append([]byte(nil), original...))

	if len(stripped) != len(original) {
		t.Fatalf("length changed: %d -> %d", len(original), len(stripped))
	}
	for _, leak := range []string{"Apple", "iPhone 15 Pro", "18.0", "2026-08-15", "home"} {
		if bytes.Contains(stripped, []byte(leak)) {
			t.Errorf("%q survived the strip", leak)
		}
	}
}

// iOS does not use ©xyz: it writes a keys table of metadata names and a parallel ilst of
// values addressed by index.
func TestStripLocationMetadataZeroesIOSKeysAndIlst(t *testing.T) {
	keys := box("keys", be32(0), be32(2),
		keyEntry("com.apple.quicktime.location.ISO6709"),
		keyEntry("com.apple.quicktime.make"))
	ilst := box("ilst",
		box(string(be32(1)), box("data", be32(1), be32(0), []byte(gpsPayload))),
		box(string(be32(2)), box("data", be32(1), be32(0), []byte("Apple"))))
	original := bytes.Join([][]byte{
		ftyp("isom"),
		box("moov", mvhdV0(3000), box("trak", videoTrack()...), box("meta", be32(0), keys, ilst)),
		box("mdat", make([]byte, 64)),
	}, nil)

	stripped := stripLocationMetadata(append([]byte(nil), original...))

	if len(stripped) != len(original) {
		t.Fatalf("length changed: %d -> %d", len(original), len(stripped))
	}
	if bytes.Contains(stripped, []byte("51.5074")) || bytes.Contains(stripped, []byte("Apple")) {
		t.Error("ilst values survived the strip")
	}
	// The key names themselves are constants, not member data, and the entry they address
	// has to keep its shape - so the table is deliberately left alone.
	if !bytes.Contains(stripped, []byte("com.apple.quicktime.location.ISO6709")) {
		t.Error("keys table was blanked; only the values should be")
	}
}

func keyEntry(name string) []byte {
	out := binary.BigEndian.AppendUint32(nil, uint32(8+len(name)))
	out = append(out, "mdta"...)
	return append(out, name...)
}

func isZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}

// A 64-bit largesize chosen so that offset+size wraps past 2^64 lands back inside the
// buffer and used to pass the naive bounds check, then panic at the slice. The walk must
// refuse it. Reproduces the reviewed PoC: a second box at a nonzero offset carrying a
// largesize that wraps the naive offset+size bound.
func TestParseBoxesRefusesWraparoundLargesize(t *testing.T) {
	first := box("free")
	// Hand-build the malicious sibling: size=1 selects the 64-bit form, then a largesize
	// that wraps p+size to a small value.
	evil := make([]byte, 16)
	binary.BigEndian.PutUint32(evil[0:4], 1)
	copy(evil[4:8], "moov")
	// 2^64-4: p+size wraps to p-4, inside the buffer and BELOW p+header, so the naive
	// p+size bound passes and the slice low > high panics. (An earlier value here summed
	// to exactly 2^64, which reads back as size 0 and never reached the vulnerable path.)
	binary.BigEndian.PutUint64(evil[8:16], ^uint64(3))
	data := append(first, evil...)

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("parseBoxes panicked on a wraparound largesize: %v", r)
		}
	}()
	if _, ok := parseBoxes(data); ok {
		t.Error("a wraparound largesize was accepted as a valid box list")
	}
}

// mvhd is self-reported and a crafted file can understate it while its sample tables
// describe minutes of playable video. The cap must bind against the longest duration any
// source reports, so lying in the movie header buys nothing.
func TestProbeMP4RejectsUnderstatedMvhdDuration(t *testing.T) {
	// mvhd claims 5s; the track's sample table sums to 60s (1800 samples at 1/30s).
	data := clip(mvhdV0(5000),
		tkhd(720, 1280, identityMatrix()),
		box("mdia", mdhd(30000, 0), box("minf", box("stbl", stts(1800, 1000)))))
	if _, err := probeMP4(data); err == nil {
		t.Error("a clip whose sample table runs 60s was accepted on a 5s mvhd claim")
	}
}
