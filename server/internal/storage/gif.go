package storage

import (
	"errors"
	"fmt"
)

// maxGIFFrames bounds a stored animation. The stdlib GIF decoder still has no frame limit
// (golang/go#22199), so a few hundred KB of input can declare tens of thousands of frames
// and turn every client that renders it into a memory bomb. Real reaction GIFs are well
// under this.
const maxGIFFrames = 256

// GIF block identifiers, from the GIF89a spec.
const (
	gifExtensionIntroducer = 0x21
	gifImageDescriptor     = 0x2C
	gifTrailer             = 0x3B

	gifCommentLabel     = 0xFE
	gifApplicationLabel = 0xFF
)

var errBadGIF = errors.New("malformed gif")

// sanitizeGIF walks a GIF's block stream in place: it counts frames (rejecting an animation
// beyond maxGIFFrames) and blanks the extension blocks that can carry metadata, without ever
// decoding pixel data. It is O(file) in I/O and O(1) in memory - no LZW decode happens, so
// none of the decompression-bomb behaviour the stdlib decoder has is reachable from here.
//
// This is the whole privacy boundary for GIFs, because unlike JPEG they are stored as
// uploaded. That is safe for the same reason the block model is simple: GIF has no EXIF and
// no place to put it. The only metadata channels are comment blocks and non-animation
// application extensions (XMP being the one that actually ships GPS), and both are zeroed
// here.
//
// The animation-control application extension (NETSCAPE2.0 / ANIMEXTS1.0) is deliberately
// preserved: it carries the loop count and nothing else, and blanking it makes every stored
// GIF play exactly once.
func sanitizeGIF(data []byte) (frames int, err error) {
	// Header: "GIF87a"/"GIF89a" + 7-byte logical screen descriptor.
	if len(data) < 13 || string(data[0:3]) != "GIF" {
		return 0, errBadGIF
	}
	p := 13
	if data[10]&0x80 != 0 { // global color table present
		p += colorTableSize(data[10])
	}

	for {
		if p >= len(data) {
			return 0, errBadGIF // ran off the end without a trailer
		}
		switch data[p] {
		case gifTrailer:
			return frames, nil
		case gifImageDescriptor:
			frames++
			if frames > maxGIFFrames {
				return 0, fmt.Errorf("gif has too many frames (max %d)", maxGIFFrames)
			}
			// Image descriptor: 1 introducer + 8 position/size + 1 packed field.
			if p+10 > len(data) {
				return 0, errBadGIF
			}
			packed := data[p+9]
			p += 10
			if packed&0x80 != 0 { // local color table present
				p += colorTableSize(packed)
			}
			p++ // LZW minimum code size
			if p, err = skipSubBlocks(data, p, false); err != nil {
				return 0, err
			}
		case gifExtensionIntroducer:
			if p+2 > len(data) {
				return 0, errBadGIF
			}
			label := data[p+1]
			p += 2
			blank := label == gifCommentLabel
			if label == gifApplicationLabel && !isAnimationExtension(data, p) {
				blank = true
			}
			if p, err = skipSubBlocks(data, p, blank); err != nil {
				return 0, err
			}
		default:
			return 0, errBadGIF
		}
	}
}

// colorTableSize returns the byte length of the color table described by a packed field.
func colorTableSize(packed byte) int {
	return 3 * (1 << ((packed & 0x07) + 1))
}

// skipSubBlocks advances past a chain of length-prefixed sub-blocks, optionally zeroing
// their payloads. Zeroing preserves every length byte, so the block stream keeps its exact
// shape and byte count and only the content disappears.
func skipSubBlocks(data []byte, p int, blank bool) (int, error) {
	for {
		if p >= len(data) {
			return 0, errBadGIF
		}
		n := int(data[p])
		p++
		if n == 0 { // block terminator
			return p, nil
		}
		if p+n > len(data) {
			return 0, errBadGIF
		}
		if blank {
			clear(data[p : p+n])
		}
		p += n
	}
}

// isAnimationExtension reports whether the application extension whose sub-block chain
// starts at p is the loop-control one every animated GIF carries. The legitimate form is
// rigid - the fixed 11-byte identifier, exactly ONE 3-byte sub-block, then the chain
// terminator - and exactly that shape is demanded, not just "every sub-block is small":
// a chain of many tiny sub-blocks under the well-known name would otherwise smuggle a
// payload of arbitrary total length past the blanking pass.
func isAnimationExtension(data []byte, p int) bool {
	if p >= len(data) || data[p] != 11 || p+12 > len(data) {
		return false
	}
	if id := string(data[p+1 : p+12]); id != "NETSCAPE2.0" && id != "ANIMEXTS1.0" {
		return false
	}
	p += 12
	// One sub-block of exactly 3 bytes (buffer sub-block id + 16-bit loop count) ...
	if p+4 > len(data) || data[p] != 3 {
		return false
	}
	p += 4
	// ... followed immediately by the terminator.
	return p < len(data) && data[p] == 0
}
