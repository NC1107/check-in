package api

import (
	"strings"
	"testing"
)

// None of these bounds had coverage: widening the attachment cap, the body cap, the tagged-
// people cap, the location cap and the cross-post id cap all at once left the whole api
// suite green. Extracting validateCreatePost out of handleCreatePost makes them reachable
// without a request or a database.

func f64p(v float64) *float64 { return &v }

func ids(n int) []int64 {
	out := make([]int64, n)
	for i := range out {
		out[i] = int64(i + 1)
	}
	return out
}

func TestValidateCreatePostKind(t *testing.T) {
	for _, tc := range []struct {
		name string
		req  createPostReq
		msg  string
	}{
		{"text with body", createPostReq{Kind: "text", Body: "hello"}, ""},
		{"text with only whitespace", createPostReq{Kind: "text", Body: "   "}, "text posts need a body"},
		{"text with no body", createPostReq{Kind: "text"}, "text posts need a body"},
		{"image with media", createPostReq{Kind: "image", MediaIDs: ids(1)}, ""},
		{"image with none", createPostReq{Kind: "image"}, "media posts need at least one attachment"},
		{"video with media", createPostReq{Kind: "video", MediaIDs: ids(1)}, ""},
		{"video with none", createPostReq{Kind: "video"}, "media posts need at least one attachment"},
		{"unknown kind", createPostReq{Kind: "audio", Body: "x"}, "kind must be 'text', 'image' or 'video'"},
		{"empty kind", createPostReq{Body: "x"}, "kind must be 'text', 'image' or 'video'"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, msg := validateCreatePost(tc.req); msg != tc.msg {
				t.Errorf("msg = %q, want %q", msg, tc.msg)
			}
		})
	}
}

func TestValidateCreatePostAttachmentCap(t *testing.T) {
	for _, tc := range []struct {
		count int
		ok    bool
	}{{1, true}, {10, true}, {11, false}, {50, false}} {
		_, msg := validateCreatePost(createPostReq{Kind: "image", MediaIDs: ids(tc.count)})
		if tc.ok && msg != "" {
			t.Errorf("%d attachments rejected: %s", tc.count, msg)
		}
		if !tc.ok && msg != "too many attachments (max 10)" {
			t.Errorf("%d attachments: msg = %q, want the cap message", tc.count, msg)
		}
	}
}

func TestValidateCreatePostBodyCap(t *testing.T) {
	for _, tc := range []struct {
		n  int
		ok bool
	}{{5000, true}, {5001, false}} {
		_, msg := validateCreatePost(createPostReq{Kind: "text", Body: strings.Repeat("a", tc.n)})
		if tc.ok && msg != "" {
			t.Errorf("body of %d rejected: %s", tc.n, msg)
		}
		if !tc.ok && msg != "body too long" {
			t.Errorf("body of %d: msg = %q, want \"body too long\"", tc.n, msg)
		}
	}
}

func TestValidateCreatePostTaggedPeopleCap(t *testing.T) {
	for _, tc := range []struct {
		n  int
		ok bool
	}{{30, true}, {31, false}} {
		_, msg := validateCreatePost(createPostReq{Kind: "text", Body: "x", PeopleIDs: ids(tc.n)})
		if tc.ok && msg != "" {
			t.Errorf("%d tagged rejected: %s", tc.n, msg)
		}
		if !tc.ok && msg != "too many tagged people (max 30)" {
			t.Errorf("%d tagged: msg = %q, want the cap message", tc.n, msg)
		}
	}
}

// The legacy single mediaId still works, and the ordered list wins when both are sent.
func TestValidateCreatePostNormalizesMediaIDs(t *testing.T) {
	legacy := int64(7)
	got, msg := validateCreatePost(createPostReq{Kind: "image", MediaID: &legacy})
	if msg != "" {
		t.Fatalf("unexpected rejection: %s", msg)
	}
	if len(got.mediaIDs) != 1 || got.mediaIDs[0] != 7 {
		t.Errorf("mediaIDs = %v, want [7]", got.mediaIDs)
	}

	got, _ = validateCreatePost(createPostReq{Kind: "image", MediaIDs: []int64{1, 2}, MediaID: &legacy})
	if len(got.mediaIDs) != 2 {
		t.Errorf("mediaIDs = %v, want the ordered list to win", got.mediaIDs)
	}
}

// A text post must not carry attachments through, whatever the client sent.
func TestValidateCreatePostTextDropsMedia(t *testing.T) {
	got, msg := validateCreatePost(createPostReq{Kind: "text", Body: "hi", MediaIDs: ids(3)})
	if msg != "" {
		t.Fatalf("unexpected rejection: %s", msg)
	}
	if got.mediaIDs != nil {
		t.Errorf("mediaIDs = %v, want nil on a text post", got.mediaIDs)
	}
}

func TestBoundedCrossPostID(t *testing.T) {
	if boundedCrossPostID(nil) != nil {
		t.Error("nil should stay nil")
	}
	for _, blank := range []string{"", "   "} {
		if got := boundedCrossPostID(&blank); got != nil {
			t.Errorf("blank %q should drop, got %q", blank, *got)
		}
	}
	ok := strings.Repeat("a", 64)
	if got := boundedCrossPostID(&ok); got == nil || *got != ok {
		t.Error("64 chars should be kept")
	}
	tooLong := strings.Repeat("a", 65)
	if got := boundedCrossPostID(&tooLong); got != nil {
		t.Error("65 chars should drop")
	}
	padded := "  abc  "
	if got := boundedCrossPostID(&padded); got == nil || *got != "abc" {
		t.Error("should be trimmed")
	}
}

func TestBoundedLocation(t *testing.T) {
	if boundedLocation(nil) != nil {
		t.Error("nil should stay nil")
	}
	blank := "   "
	if boundedLocation(&blank) != nil {
		t.Error("blank should drop")
	}
	padded := "  Denver, United States  "
	if got := boundedLocation(&padded); got == nil || *got != "Denver, United States" {
		t.Error("should be trimmed")
	}
	// Over the cap it is truncated rather than rejected, so a long place name still posts.
	long := strings.Repeat("x", 200)
	got := boundedLocation(&long)
	if got == nil || len(*got) != 120 {
		t.Errorf("long location should truncate to 120, got %v", got)
	}
}

// Location and coordinates only ride along with an attachment - a text post cannot carry
// GPS, since there was no file to have held it.
func TestValidateCreatePostDropsPlaceWithoutMedia(t *testing.T) {
	loc := "Denver, United States"
	got, msg := validateCreatePost(createPostReq{
		Kind: "text", Body: "hi", Location: &loc, Lat: f64p(39.74), Lng: f64p(-104.98),
	})
	if msg != "" {
		t.Fatalf("unexpected rejection: %s", msg)
	}
	if got.location != nil || got.lat != nil || got.lng != nil {
		t.Errorf("text post kept place data: loc=%v lat=%v lng=%v", got.location, got.lat, got.lng)
	}
}

func TestValidateCreatePostKeepsPlaceWithMedia(t *testing.T) {
	loc := "Denver, United States"
	got, msg := validateCreatePost(createPostReq{
		Kind: "image", MediaIDs: ids(1), Location: &loc, Lat: f64p(39.74), Lng: f64p(-104.98),
	})
	if msg != "" {
		t.Fatalf("unexpected rejection: %s", msg)
	}
	if got.location == nil || *got.location != loc {
		t.Errorf("location = %v, want %q", got.location, loc)
	}
	if got.lat == nil || got.lng == nil {
		t.Error("coordinates should ride along with an attachment")
	}
}
