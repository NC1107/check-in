package api

import (
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/nc1107/check-in/server/internal/db"
)

// The push collapse id is what stops one comment, sent to three groups, arriving as three
// notifications on a device that belongs to all three. Each group is its own server and they
// cannot coordinate, so the only thing tying the copies together is the id the client
// generated - see applyCollapse for how it reaches APNs and Android.
func TestCollapseForSharedComment(t *testing.T) {
	if got := collapseFor("comment", ""); got != noCollapse {
		t.Errorf("a comment sent to one group must not collapse; got %q", got)
	}
	if got := collapseFor("comment", "shared-2f9c"); got != "comment:shared-2f9c" {
		t.Errorf("collapseFor = %q, want comment:shared-2f9c", got)
	}
}

// A comment that is also a reply fires BOTH notifyReply and notifyCommentReply. If they
// shared a collapse id, the second would replace the first on the device and the post's
// author would silently never learn about it.
func TestCollapseKindsStayDistinct(t *testing.T) {
	comment := collapseFor("comment", "shared-2f9c")
	reply := collapseFor("reply", "shared-2f9c")
	if comment == reply {
		t.Fatalf("both notifications for one comment collapsed onto %q - one would be lost", comment)
	}
}

// The id's exact shape is a contract between servers that never talk to each other: every
// copy has to derive a byte-identical string from the same shared id, or the copies simply
// do not collapse and the mechanism is a silent no-op. Pinning the literal is what catches a
// change to the format - comparing the function against itself would only ever be a
// tautology.
func TestCollapseIdFormatIsPinned(t *testing.T) {
	if got := collapseFor("comment", "abc"); got != "comment:abc" {
		t.Errorf("collapse id = %q, want comment:abc - a different shape on one server means "+
			"its copies never collapse against another's", got)
	}
	if got := collapseFor("reply", "abc"); got != "reply:abc" {
		t.Errorf("collapse id = %q, want reply:abc", got)
	}
}

// The comment counts a post reports, against a real database.
//
// This exists because nothing else asserted them. Every other reference to commentCount in
// this package's tests only checks that the JSON key is PRESENT, never what it holds - so
// the two count columns could be scanned in the wrong order and every test would still pass
// while the feed showed the wrong numbers. Both columns are plain integers, which is exactly
// the kind of mismatch a compiler cannot catch either.
//
// sharedCommentCount is what lets the multi-group client total comments across copies
// without counting a shared one once per group; if it silently tracked the wrong column, the
// correction would quietly make the count worse rather than better.
func TestPostReportsTotalAndSharedCommentCounts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	viewer := h.member(admin, "Sam")

	post := h.createPost(admin, map[string]any{"kind": "text", "body": "trip photos"})

	// Two ordinary comments and one written once and sent to every group.
	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), admin.Token,
		map[string]any{"body": "first"})
	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), viewer.Token,
		map[string]any{"body": "second"})
	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), admin.Token,
		map[string]any{"body": "said everywhere", "crossCommentId": "shared-2f9c"})

	// Every endpoint that serves a Post scans the same column list through scanPost, and a
	// column swap between two integers is invisible to the compiler - so each one is checked
	// rather than trusting that they share code today and always will.
	for _, tc := range []struct {
		name string
		post db.Post
	}{
		{"as the feed serves it", onlyPost(t, h.feed(viewer))},
		{"as the single-post endpoint serves it", h.postByID(viewer, post.ID)},
		{"as a member's own posts serve it", onlyPost(t, h.userPosts(viewer, admin.ID))},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.post.CommentCount != 3 {
				t.Errorf("commentCount = %d, want 3", tc.post.CommentCount)
			}
			if tc.post.SharedCommentCount != 1 {
				t.Errorf("sharedCommentCount = %d, want 1 - only one carried a shared id",
					tc.post.SharedCommentCount)
			}
		})
	}
}

// A comment with no shared id must not be counted as one, or the client would subtract an
// overlap that does not exist and under-report the thread.
func TestOrdinaryCommentsAreNeverCountedAsShared(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "hello"})

	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), admin.Token,
		map[string]any{"body": "just here"})
	// An explicitly blank id is dropped rather than stored - otherwise every comment carrying
	// one would collapse into a single entry on the client.
	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), admin.Token,
		map[string]any{"body": "blank id", "crossCommentId": "  "})

	got := h.postByID(admin, post.ID)
	if got.CommentCount != 2 {
		t.Errorf("commentCount = %d, want 2", got.CommentCount)
	}
	if got.SharedCommentCount != 0 {
		t.Errorf("sharedCommentCount = %d, want 0", got.SharedCommentCount)
	}
}

// postByID reads one post through the public endpoint, as a client would.
func (h *harness) postByID(a actor, id int64) db.Post {
	h.t.Helper()
	var p db.Post
	h.get(fmt.Sprintf("/api/posts/%d", id), a.Token).expect(http.StatusOK).decode(&p)
	return p
}

// The client only sends crossCommentId to a server that advertises this. If the flag ever
// stopped being published, every client would treat every group as incapable and quietly
// stop collapsing anything - comments and notifications would silently start arriving once
// per group again, with nothing failing to explain why.
func TestServerInfoAdvertisesCrossComments(t *testing.T) {
	h := newHarness(t)
	var info map[string]any
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)

	if got, ok := info["crossComments"].(bool); !ok || !got {
		t.Errorf("crossComments = %v, want true - a client gates the whole feature on it",
			info["crossComments"])
	}
}

// The shared id is opaque and client-supplied, so its bounds are the server's business.
func TestCrossCommentIDIsBounded(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "trip"})

	for _, tc := range []struct {
		name string
		id   any
		want bool // whether the comment should end up carrying an id
	}{
		{"an ordinary id is kept", "shared-2f9c", true},
		{"blank is dropped", "", false},
		{"whitespace only is dropped", "   ", false},
		{"over 64 characters is dropped", strings.Repeat("x", 65), false},
		{"exactly 64 characters is kept", strings.Repeat("x", 64), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var c db.Comment
			h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), admin.Token,
				map[string]any{"body": "hi", "crossCommentId": tc.id}).
				expect(http.StatusCreated).decode(&c)

			got := c.CrossCommentID != nil
			if got != tc.want {
				t.Errorf("stored an id = %v, want %v", got, tc.want)
			}
		})
	}
}

// userPosts reads one member's posts through the public endpoint.
func (h *harness) userPosts(a actor, userID int64) []db.Post {
	h.t.Helper()
	var page struct {
		Posts []db.Post `json:"posts"`
	}
	h.get(fmt.Sprintf("/api/users/%d/posts", userID), a.Token).
		expect(http.StatusOK).decode(&page)
	return page.Posts
}
