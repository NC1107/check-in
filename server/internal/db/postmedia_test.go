package db

import (
	"encoding/json"
	"strings"
	"testing"
)

// The post payload's media array, pinned from this end. Its twin lands with the client
// pass (app/test, feeding this same literal to the Dart parser), so a shape change on one
// side fails the pair rather than shipping a feed the app renders as broken images.
func TestPostMediaWireFormat(t *testing.T) {
	const want = `[{"id":7,"mime":"image/jpeg","width":1600,"height":1200,"durationMs":0,"hasPoster":false},` +
		`{"id":8,"mime":"video/mp4","width":1080,"height":1920,"durationMs":9500,"hasPoster":true}]`

	got, err := json.Marshal([]PostMedia{
		{ID: 7, Mime: "image/jpeg", Width: 1600, Height: 1200},
		{ID: 8, Mime: "video/mp4", Width: 1080, Height: 1920, DurationMs: 9500, HasPoster: true},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(got) != want {
		t.Errorf("media json =\n%s\nwant\n%s", got, want)
	}
}

// mediaIds is what every published client reads, and it has to keep coming out of the same
// query as the typed array or a client on one and a client on the other see different posts.
func TestApplyMediaDerivesTheLegacyIDList(t *testing.T) {
	var p Post
	p.applyMedia([]byte(`[{"id":3,"mime":"video/mp4"},{"id":1,"mime":"image/jpeg"}]`))

	if len(p.Media) != 2 {
		t.Fatalf("Media has %d entries, want 2", len(p.Media))
	}
	if len(p.MediaIDs) != 2 || p.MediaIDs[0] != 3 || p.MediaIDs[1] != 1 {
		t.Errorf("MediaIDs = %v, want [3 1] in the array's order", p.MediaIDs)
	}
}

// A text post must not grow an empty array in its payload: omitempty only drops a nil one,
// and older clients treat a present-but-empty list as "this post has media".
func TestApplyMediaLeavesTextPostsBare(t *testing.T) {
	var p Post
	p.applyMedia([]byte(`[]`))

	if p.MediaIDs != nil || p.Media != nil {
		t.Fatalf("MediaIDs = %v, Media = %v, want both nil", p.MediaIDs, p.Media)
	}
	out, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(out), "media") {
		t.Errorf("text post payload mentions media: %s", out)
	}
}

// The stored kind describes what is attached, whatever the client called the post.
func TestKindFor(t *testing.T) {
	image := PostMedia{ID: 1, Mime: "image/jpeg"}
	gif := PostMedia{ID: 2, Mime: "image/gif"}
	video := PostMedia{ID: 3, Mime: "video/mp4"}

	tests := []struct {
		name  string
		media []PostMedia
		want  string
	}{
		{"nothing attached is a text post", nil, "text"},
		{"a photo is an image post", []PostMedia{image}, "image"},
		{"a gif is still an image post", []PostMedia{gif}, "image"},
		{"a clip is a video post", []PostMedia{video}, "video"},
		{"one clip among photos makes it a video post", []PostMedia{image, video, gif}, "video"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := kindFor(tt.media); got != tt.want {
				t.Errorf("kindFor() = %q, want %q", got, tt.want)
			}
		})
	}
}

// The legacy cover must never point at a clip: published clients render posts.media_id
// as a picture, so a video there paints a broken-image icon where caption-only is the
// intended degradation.
func TestCoverForSkipsClips(t *testing.T) {
	clipFirst := []PostMedia{
		{ID: 8, Mime: "video/mp4"},
		{ID: 7, Mime: "image/jpeg"},
	}
	if got := coverFor(clipFirst); got == nil || *got != 7 {
		t.Errorf("coverFor(clip first) = %v, want the first image id 7", got)
	}
	clipOnly := []PostMedia{{ID: 8, Mime: "video/mp4"}}
	if got := coverFor(clipOnly); got != nil {
		t.Errorf("coverFor(clip only) = %v, want nil", got)
	}
	if got := coverFor(nil); got != nil {
		t.Errorf("coverFor(nil) = %v, want nil", got)
	}
}
