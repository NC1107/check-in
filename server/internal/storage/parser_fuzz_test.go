package storage

// These parsers are the only code in the server that reads a byte for byte of a file a
// member uploaded, before anything has decided the file is what it claims to be. A panic
// here is not a cosmetic failure: it happens on the upload path, where the handler's
// recovery is the only thing between one malformed file and the process, and where an
// attacker picks the bytes.
//
// Table tests can only cover the shapes someone thought of. Fuzzing covers the ones nobody
// did, which is the entire category these functions exist to survive.
//
// Run a longer campaign with:
//
//	go test ./internal/storage/ -run xxx -fuzz FuzzSanitizeGIF -fuzztime 2m

import (
	"testing"
	"time"
)

// FuzzSanitizeGIF asserts only that the parser returns rather than panics, loops forever, or
// reports frames for input it also rejected. What a malformed gif *means* is the table
// tests' business; this is about it not taking the process with it.
func FuzzSanitizeGIF(f *testing.F) {
	f.Add(gifStream(gifFrame()))
	f.Add([]byte("GIF89a"))
	f.Add([]byte("GIF89a\x01\x00\x01\x00\x80\x00\x00"))
	// A global colour table header claiming a table that is not there: the shape that walks
	// a cursor past the end if the bounds check is wrong.
	f.Add([]byte("GIF89a\x01\x00\x01\x00\xf7\x00\x00"))
	f.Add([]byte{})

	f.Fuzz(func(t *testing.T, data []byte) {
		done := make(chan struct{})
		var frames int
		var err error
		go func() {
			defer close(done)
			frames, err = sanitizeGIF(data)
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatalf("sanitizeGIF did not return within 5s on %d bytes - a cursor that "+
				"stops advancing hangs the upload handler, not just this test", len(data))
		}
		if err != nil && frames != 0 {
			t.Errorf("rejected the file but still reported %d frames; a caller that checks "+
				"the count before the error would let it through", frames)
		}
		if err == nil && frames < 1 {
			t.Errorf("accepted the file but reported %d frames", frames)
		}
	})
}

// FuzzProbeMP4 covers the box walker, which is the part that follows attacker-chosen
// lengths. A box claiming a size larger than the file, or a size of zero, is the classic way
// to make a walker read out of bounds or never advance.
func FuzzProbeMP4(f *testing.F) {
	f.Add(clip(mvhdV0(5000), videoTrack()...))
	f.Add([]byte("\x00\x00\x00\x08ftypmp42"))
	// A box whose declared size covers the whole file, and one that declares zero.
	f.Add([]byte("\xff\xff\xff\xffftypmp42"))
	f.Add([]byte("\x00\x00\x00\x00ftypmp42"))
	f.Add([]byte{})

	f.Fuzz(func(t *testing.T, data []byte) {
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, _ = probeMP4(data)
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatalf("probeMP4 did not return within 5s on %d bytes", len(data))
		}
	})
}

// FuzzStripLocationMetadata is the same walker used for writing rather than reading: it
// blanks GPS in place, so a bounds mistake corrupts the member's file instead of only
// failing to parse it. It must also never change the file's length.
func FuzzStripLocationMetadata(f *testing.F) {
	f.Add(clip(mvhdV0(5000), videoTrack()...))
	f.Add([]byte("\x00\x00\x00\x08ftypmp42"))
	f.Add([]byte("\xff\xff\xff\xffmeta\x00\x00\x00\x00"))
	f.Add([]byte{})

	f.Fuzz(func(t *testing.T, data []byte) {
		before := len(data)
		done := make(chan struct{})
		var out []byte
		go func() {
			defer close(done)
			out = stripLocationMetadata(data)
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatalf("stripLocationMetadata did not return within 5s on %d bytes", before)
		}
		if len(out) != before {
			t.Errorf("length changed from %d to %d; this blanks bytes in place and must "+
				"never resize the member's file", before, len(out))
		}
	})
}
