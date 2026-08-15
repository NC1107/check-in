package storage

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"

	mp4 "github.com/abema/go-mp4"
)

// maxVideoDurationMs is the hard cap on a stored clip. The capture UI aims at 10s; trim
// tools routinely land a few hundred milliseconds over their nominal target, so a cap set
// exactly at the UI's number would reject clips the user was told were fine.
const maxVideoDurationMs = 12_000

// Bounds on the box walk. An MP4 is a tree of length-prefixed boxes, and a hostile file can
// declare a deep or wide one purely in headers; neither limit is anywhere near what a real
// clip needs.
const (
	maxBoxDepth    = 8
	maxBoxSiblings = 4096
)

// videoBrands are the ftyp brands we accept. This is a sanity gate rather than a security
// boundary (the box walk below is what actually validates the file), but it rejects the
// common confusions - audio-only M4A, images in a HEIF container - before any of them can
// be stored as a video.
var videoBrands = map[string]bool{
	"isom": true, "iso2": true, "iso4": true, "iso5": true, "iso6": true,
	"mp41": true, "mp42": true, "avc1": true, "M4V ": true,
	"3gp4": true, "3gp5": true, "3gp6": true, "qt  ": true,
}

// mp4Containers are the boxes whose payload is a list of child boxes. Anything not listed
// here is treated as a leaf, which is what keeps the walk off mdat: the sample data is
// never parsed, only skipped.
var mp4Containers = map[string]bool{
	"moov": true, "trak": true, "mdia": true, "minf": true, "stbl": true,
	"udta": true, "edts": true, "moof": true, "traf": true,
}

// privacyBoxes are the metadata atoms blanked on the way in. The names use the raw 0xA9
// marker byte, not the UTF-8 copyright sign: "\xa9xyz" is the four-byte box type usually
// written ©xyz.
//
// ©xyz (Apple) and loci (3GPP) are the two places a phone writes the coordinates the clip
// was recorded at. The rest are device fingerprints - make, model, encoding software, and
// the capture timestamp - which identify the member's phone as reliably as EXIF does on a
// photo.
var privacyBoxes = map[string]bool{
	"\xa9xyz": true, // ISO 6709 coordinates
	"loci":    true, // 3GPP location, name + coordinates
	"gps ":    true,
	"\xa9mak": true, // manufacturer
	"\xa9mod": true, // model
	"\xa9swr": true, // encoding software
	"\xa9too": true, // encoding tool, which is the one most muxers actually write
	"\xa9day": true, // capture date
}

// privacyKeyTokens match the metadata key names iOS writes into moov/meta/keys, e.g.
// "com.apple.quicktime.location.ISO6709" or "com.apple.quicktime.model". Matching on a
// token rather than the full name errs toward blanking one field too many, which is the
// right direction to be wrong in.
var privacyKeyTokens = []string{"location", "make", "model", "software", "creationdate"}

// videoInfo is what a validated clip tells us about itself.
type videoInfo struct {
	DurationMs int
	Width      int
	Height     int
}

// mp4Box is one box in the tree. Payload aliases the caller's buffer, so blanking a
// payload edits the file in place.
type mp4Box struct {
	typ     string
	payload []byte
}

// probeMP4 validates an MP4/QuickTime file from its box structure alone and returns the
// duration and display dimensions. It never decodes a frame: everything here reads headers
// and the handful of small metadata boxes that describe the timeline.
func probeMP4(data []byte) (videoInfo, error) {
	root, ok := parseBoxes(data)
	if !ok || len(root) == 0 {
		return videoInfo{}, errors.New("not a valid mp4 file")
	}
	if root[0].typ != "ftyp" || len(root[0].payload) < 4 {
		return videoInfo{}, errors.New("not a valid mp4 file (no ftyp)")
	}
	if !hasVideoBrand(root[0].payload) {
		return videoInfo{}, errors.New("unsupported video format")
	}
	moov, found := findBox(root, "moov")
	if !found {
		return videoInfo{}, errors.New("not a valid mp4 file (no moov)")
	}
	moovKids, _ := parseBoxes(moov.payload)

	info := videoInfo{}
	if mvhd, found := findBox(moovKids, "mvhd"); found {
		var b mp4.Mvhd
		if err := unmarshalBox(mvhd.payload, &b); err == nil {
			info.DurationMs = int(scaleToMs(b.GetDuration(), uint64(b.Timescale)))
		}
	}

	// mvhd carries the PRESENTED duration - the movie timeline after edit lists are applied -
	// and that is the authoritative length. A track's raw sample table (stts) sums the coded
	// samples, which routinely runs LONGER than the presentation whenever an edit list trims
	// the head or tail; phone recorders and re-encoders emit such edit lists as a matter of
	// course. Taking the max of mvhd and the stts sum therefore over-counts and falsely
	// rejects legitimate clips (a real 9s clip whose stts sums to 12s). So mvhd wins whenever
	// it is present, and the track/stts duration is used ONLY when mvhd is 0 (fragmented files
	// and the encoders that leave the movie header blank). The "spoofed short mvhd hiding a
	// long file" case is low severity: the 25MB size cap is the real resource control here.
	for _, trak := range findBoxes(moovKids, "trak") {
		trakKids, _ := parseBoxes(trak.payload)
		if tkhd, found := findBox(trakKids, "tkhd"); found {
			w, h := trackDimensions(tkhd.payload)
			if w*h > info.Width*info.Height {
				info.Width, info.Height = w, h
			}
		}
		if info.DurationMs <= 0 {
			if ms := trackDurationMs(trakKids); ms > info.DurationMs {
				info.DurationMs = ms
			}
		}
	}

	if info.DurationMs <= 0 {
		return videoInfo{}, errors.New("could not determine video duration")
	}
	if info.DurationMs > maxVideoDurationMs {
		return videoInfo{}, fmt.Errorf("video is longer than %d seconds", maxVideoDurationMs/1000)
	}
	if info.Width <= 0 || info.Height <= 0 {
		return videoInfo{}, errors.New("video has no displayable track")
	}
	return info, nil
}

// stripLocationMetadata blanks every metadata box that can carry the member's location or
// identify their device, and returns the sanitized file.
//
// It works by zeroing payloads in place, never by removing boxes, and that is load-bearing
// rather than a shortcut: stco/co64 hold absolute file offsets into mdat, so deleting bytes
// from a faststart moov silently shifts every sample offset and the file stops playing.
// Removal done properly means rewriting those tables, which is a different feature; zeroing
// achieves the same privacy result with the file layout provably untouched.
func stripLocationMetadata(data []byte) []byte {
	boxes, _ := parseBoxes(data)
	stripBoxes(boxes, 0)
	return data
}

func stripBoxes(boxes []mp4Box, depth int) {
	if depth >= maxBoxDepth {
		return
	}
	for _, b := range boxes {
		switch {
		case privacyBoxes[b.typ]:
			clear(b.payload)
		case b.typ == "meta":
			stripMetaBox(b.payload)
		case mp4Containers[b.typ]:
			kids, _ := parseBoxes(b.payload)
			stripBoxes(kids, depth+1)
		}
	}
}

// stripMetaBox blanks the location and device entries of an iOS-style metadata box, whose
// values live in an ilst keyed by position into a parallel keys box.
func stripMetaBox(payload []byte) {
	kids, _ := parseBoxes(metaChildren(payload))
	keys := metadataKeys(kids)
	ilst, found := findBox(kids, "ilst")
	if !found {
		return
	}
	for _, e := range parseIndexedBoxes(ilst.payload) {
		// An entry is named either by its 1-based index into the keys box (iOS) or directly
		// by a four-character code (iTunes-style).
		key := ""
		if index := int(binary.BigEndian.Uint32([]byte(e.typ))); index >= 1 && index <= len(keys) {
			key = keys[index-1]
		}
		if privacyKey(key) || privacyBoxes[e.typ] {
			blankIlstValue(e)
		}
	}
}

// blankIlstValue zeroes the value bytes of a metadata entry, leaving the enclosing data
// box's header, version, flags and locale intact. Blanking the whole entry instead would
// zero the inner box's size field, and a zero size means "extends to end of file" - a
// well-formed way to corrupt the file.
func blankIlstValue(entry mp4Box) {
	kids, _ := parseBoxes(entry.payload)
	for _, k := range kids {
		if k.typ == "data" && len(k.payload) > 8 {
			clear(k.payload[8:]) // 4 bytes type indicator + 4 bytes locale
		}
	}
}

// metadataKeys returns the key names of a meta box's keys entry table, in index order.
func metadataKeys(metaKids []mp4Box) []string {
	keys, found := findBox(metaKids, "keys")
	if !found || len(keys.payload) < 8 {
		return nil
	}
	count := int(binary.BigEndian.Uint32(keys.payload[4:8]))
	if count < 0 || count > maxBoxSiblings {
		return nil
	}
	out := make([]string, 0, count)
	p := 8
	for i := 0; i < count; i++ {
		if p+8 > len(keys.payload) {
			break
		}
		size := int(binary.BigEndian.Uint32(keys.payload[p : p+4]))
		if size < 8 || p+size > len(keys.payload) {
			break
		}
		out = append(out, string(keys.payload[p+8:p+size]))
		p += size
	}
	return out
}

func privacyKey(key string) bool {
	if key == "" {
		return false
	}
	lower := strings.ToLower(key)
	for _, token := range privacyKeyTokens {
		if strings.Contains(lower, token) {
			return true
		}
	}
	return false
}

// metaChildren returns the child-box region of a meta box. ISO-BMFF declares meta as a
// full box (4 bytes of version and flags before the children) while QuickTime declares it
// as a plain container, and files of both shapes reach this server - so the layout is
// detected rather than assumed.
func metaChildren(payload []byte) []byte {
	if looksLikeBoxHeader(payload) {
		return payload
	}
	if len(payload) >= 4 && looksLikeBoxHeader(payload[4:]) {
		return payload[4:]
	}
	return nil
}

func looksLikeBoxHeader(data []byte) bool {
	if len(data) < 8 {
		return false
	}
	size := int(binary.BigEndian.Uint32(data[0:4]))
	if size < 8 || size > len(data) {
		return false
	}
	return validBoxType(data[4:8])
}

// parseBoxes splits a box payload into its direct children. ok reports whether the whole
// region parsed cleanly; when it is false the boxes read before the malformed point are
// still returned, so a sanitizing pass can do its work on the part of the file that makes
// sense while a validating pass rejects the file outright.
func parseBoxes(data []byte) (boxes []mp4Box, ok bool) {
	return parseBoxList(data, true)
}

// parseIndexedBoxes parses the children of an ilst box, whose type field holds a big-endian
// index into the keys table rather than four printable characters.
func parseIndexedBoxes(data []byte) []mp4Box {
	boxes, _ := parseBoxList(data, false)
	return boxes
}

func parseBoxList(data []byte, printableTypes bool) (boxes []mp4Box, ok bool) {
	for p := 0; p < len(data); {
		if len(boxes) >= maxBoxSiblings {
			return boxes, false
		}
		if p+8 > len(data) {
			return boxes, false
		}
		size := uint64(binary.BigEndian.Uint32(data[p : p+4]))
		typ := data[p+4 : p+8]
		if printableTypes && !validBoxType(typ) {
			return boxes, false
		}
		header := 8
		switch size {
		case 0: // extends to the end of the file
			size = uint64(len(data) - p)
		case 1: // 64-bit size follows the type
			if p+16 > len(data) {
				return boxes, false
			}
			size = binary.BigEndian.Uint64(data[p+8 : p+16])
			header = 16
		}
		// Bound against len(data)-p rather than p+size: size comes straight off attacker
		// bytes, and a value near 2^64 makes p+size wrap to something small that passes
		// the naive check, then panics when sliced. len(data)-p cannot wrap - the loop
		// guarantees p < len(data).
		if size < uint64(header) || size > uint64(len(data)-p) {
			return boxes, false
		}
		boxes = append(boxes, mp4Box{
			typ:     string(typ),
			payload: data[p+header : p+int(size)],
		})
		p += int(size)
	}
	return boxes, true
}

// validBoxType rejects headers whose type is not four printable characters, which is what
// stops a walk from wandering into sample data on a truncated or hostile file. 0xA9 is
// allowed because Apple's metadata atoms start with it.
func validBoxType(typ []byte) bool {
	for _, c := range typ {
		if c == 0xA9 {
			continue
		}
		if c < 0x20 || c > 0x7E {
			return false
		}
	}
	return true
}

func findBox(boxes []mp4Box, typ string) (mp4Box, bool) {
	for _, b := range boxes {
		if b.typ == typ {
			return b, true
		}
	}
	return mp4Box{}, false
}

func findBoxes(boxes []mp4Box, typ string) []mp4Box {
	var out []mp4Box
	for _, b := range boxes {
		if b.typ == typ {
			out = append(out, b)
		}
	}
	return out
}

func hasVideoBrand(ftypPayload []byte) bool {
	// Major brand first, then the compatible-brands list that follows the 4-byte version.
	for p := 0; p+4 <= len(ftypPayload); p += 4 {
		if p == 4 {
			continue // minor version, not a brand
		}
		if videoBrands[string(ftypPayload[p:p+4])] {
			return true
		}
	}
	return false
}

// trackDimensions returns a track's display size from its tkhd, in pixels. The stored width
// and height are pre-rotation, so a portrait phone clip reports landscape numbers with a
// quarter-turn in the display matrix; applying the matrix here is what makes the client's
// aspect ratio match what the viewer actually sees.
func trackDimensions(tkhdPayload []byte) (width, height int) {
	var b mp4.Tkhd
	if err := unmarshalBox(tkhdPayload, &b); err != nil {
		return 0, 0
	}
	width, height = int(b.Width>>16), int(b.Height>>16)
	if b.Matrix[0] == 0 && b.Matrix[4] == 0 && (b.Matrix[1] != 0 || b.Matrix[3] != 0) {
		width, height = height, width
	}
	return width, height
}

// trackDurationMs derives one track's duration from its media header, falling back to
// summing the sample table when the header says zero.
func trackDurationMs(trakKids []mp4Box) int {
	mdia, found := findBox(trakKids, "mdia")
	if !found {
		return 0
	}
	mdiaKids, _ := parseBoxes(mdia.payload)
	mdhd, found := findBox(mdiaKids, "mdhd")
	if !found {
		return 0
	}
	var header mp4.Mdhd
	if err := unmarshalBox(mdhd.payload, &header); err != nil {
		return 0
	}
	timescale := uint64(header.Timescale)
	if ms := scaleToMs(header.GetDuration(), timescale); ms > 0 {
		return int(ms)
	}
	return int(scaleToMs(sampleTableDuration(mdiaKids), timescale))
}

// sampleTableDuration sums a track's per-sample deltas, in the track's own timescale.
func sampleTableDuration(mdiaKids []mp4Box) uint64 {
	minf, found := findBox(mdiaKids, "minf")
	if !found {
		return 0
	}
	minfKids, _ := parseBoxes(minf.payload)
	stbl, found := findBox(minfKids, "stbl")
	if !found {
		return 0
	}
	stblKids, _ := parseBoxes(stbl.payload)
	stts, found := findBox(stblKids, "stts")
	if !found {
		return 0
	}
	var b mp4.Stts
	if err := unmarshalBox(stts.payload, &b); err != nil {
		return 0
	}
	var total uint64
	for _, e := range b.Entries {
		total += uint64(e.SampleCount) * uint64(e.SampleDelta)
	}
	return total
}

// scaleToMs converts a duration expressed in timescale units to milliseconds. The division
// is done before the multiplication so a long duration in a fine timescale cannot overflow.
func scaleToMs(duration, timescale uint64) uint64 {
	if timescale == 0 {
		return 0
	}
	return (duration/timescale)*1000 + (duration%timescale)*1000/timescale
}

func unmarshalBox(payload []byte, dst mp4.IBox) error {
	_, err := mp4.Unmarshal(bytes.NewReader(payload), uint64(len(payload)), dst, mp4.Context{})
	return err
}
