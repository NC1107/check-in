package api

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/nc1107/check-in/server/internal/config"
	"github.com/nc1107/check-in/server/internal/db"
)

// serverInfoResp is the subset of GET /api/server-info this file asserts on.
type serverInfoResp struct {
	GifSearch    *bool `json:"gifSearch"`
	CommentMedia *bool `json:"commentMedia"`
}

func TestServerInfoGifSearchFollowsConfig(t *testing.T) {
	t.Run("no key configured", func(t *testing.T) {
		h := newHarness(t)
		var info serverInfoResp
		h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
		if info.GifSearch == nil || *info.GifSearch {
			t.Errorf("gifSearch = %v, want false (or the key absent) with no key configured", info.GifSearch)
		}
	})

	t.Run("key configured", func(t *testing.T) {
		h := newHarnessWithKlipyKey(t, "test-key")
		var info serverInfoResp
		h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
		if info.GifSearch == nil || !*info.GifSearch {
			t.Error("gifSearch = false, want true once a key is configured")
		}
	})
}

// commentMedia is intrinsic to this server version - it must always be true, never absent -
// so the client's compatibility gate (present vs. absent) actually protects an old server
// rather than a server that could theoretically say "false".
func TestServerInfoCommentMediaAlwaysTrue(t *testing.T) {
	h := newHarness(t)
	var info serverInfoResp
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
	if info.CommentMedia == nil || !*info.CommentMedia {
		t.Errorf("commentMedia = %v, want true", info.CommentMedia)
	}
}

// commentResp mirrors what /api/posts/{id}/comments returns, including the mediaId this
// feature adds.
type commentResp struct {
	ID      int64  `json:"id"`
	Body    string `json:"body"`
	MediaID *int64 `json:"mediaId"`
}

func TestCommentWithGifAttachment(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "movie night"})
	gifMedia := h.uploadGif(admin.Token)

	t.Run("create with mediaId and an empty body", func(t *testing.T) {
		var c commentResp
		h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{
			"mediaId": gifMedia.ID,
		}).expect(http.StatusCreated).decode(&c)
		if c.MediaID == nil || *c.MediaID != gifMedia.ID {
			t.Errorf("mediaId = %v, want %d", c.MediaID, gifMedia.ID)
		}
		if c.Body != "" {
			t.Errorf("body = %q, want empty for a gif-only comment", c.Body)
		}
	})

	t.Run("neither body nor mediaId is rejected", func(t *testing.T) {
		res := h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{}).
			expect(http.StatusBadRequest)
		if !strings.Contains(res.errorMessage(), "body or a gif") {
			t.Errorf("error = %q, want it to explain a comment needs a body or a gif", res.errorMessage())
		}
	})

	t.Run("serialized in the comment list", func(t *testing.T) {
		var page struct {
			Comments []commentResp `json:"comments"`
		}
		h.get("/api/posts/"+itoa(post.ID)+"/comments", admin.Token).expect(http.StatusOK).decode(&page)
		found := false
		for _, c := range page.Comments {
			if c.MediaID != nil && *c.MediaID == gifMedia.ID {
				found = true
			}
		}
		if !found {
			t.Errorf("comments = %+v, want one carrying mediaId %d", page.Comments, gifMedia.ID)
		}
	})

	t.Run("serialized in the feed's comment preview", func(t *testing.T) {
		posts := h.feed(admin)
		p := onlyPost(t, posts)
		found := false
		for _, cp := range p.CommentsPreview {
			if cp.MediaID != nil && *cp.MediaID == gifMedia.ID {
				found = true
			}
		}
		if !found {
			t.Errorf("commentsPreview = %+v, want the gif comment's mediaId", p.CommentsPreview)
		}
	})
}

func TestCommentRejectsSomebodyElsesAttachment(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	other := h.member(admin, "Sam")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "movie night"})
	theirs := h.uploadGif(other.Token)

	res := h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{
		"mediaId": theirs.ID,
	}).expect(http.StatusBadRequest)
	if !strings.Contains(res.errorMessage(), "not yours") {
		t.Errorf("error = %q, want it to say the attachment is not the author's", res.errorMessage())
	}
}

func TestCommentEmptyBodyWithoutMediaStillRejected(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "movie night"})
	res := h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{"body": "   "}).
		expect(http.StatusBadRequest)
	if !strings.Contains(res.errorMessage(), "body or a gif") {
		t.Errorf("error = %q, want the body-or-gif message for a blank, mediaId-less comment", res.errorMessage())
	}
}

// Deleting a comment must garbage-collect its media once nothing else points at it, but
// never touch media another comment (or a post) still uses.
func TestCommentDeleteCleansUpOrphanedMedia(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "movie night"})
	gifMedia := h.uploadGif(admin.Token)

	var first, second db.Comment
	h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{"mediaId": gifMedia.ID}).
		expect(http.StatusCreated).decode(&first)
	h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{"mediaId": gifMedia.ID}).
		expect(http.StatusCreated).decode(&second)

	ctx := context.Background()

	t.Run("still referenced by the other comment: media survives", func(t *testing.T) {
		paths, err := h.db.AdminDeleteComment(ctx, first.ID)
		if err != nil {
			t.Fatalf("AdminDeleteComment: %v", err)
		}
		if len(paths) != 0 {
			t.Errorf("orphan paths = %v, want none - the second comment still references the media", paths)
		}
		if _, err := h.db.GetMedia(ctx, gifMedia.ID); err != nil {
			t.Errorf("media %d should still exist: %v", gifMedia.ID, err)
		}
	})

	t.Run("last reference gone: media is cleaned up", func(t *testing.T) {
		paths, err := h.db.AdminDeleteComment(ctx, second.ID)
		if err != nil {
			t.Fatalf("AdminDeleteComment: %v", err)
		}
		if len(paths) != 1 {
			t.Fatalf("orphan paths = %v, want the one file the gif was stored under", paths)
		}
		if _, err := h.db.GetMedia(ctx, gifMedia.ID); err == nil {
			t.Errorf("media %d should have been deleted once nothing referenced it", gifMedia.ID)
		}
	})
}

// A comment's media must not be swept up while a post still points at the same media id -
// deleteOrphanMedia's comment check must be additive to, not a replacement for, the
// pre-existing post checks.
func TestCommentDeleteKeepsMediaStillUsedByAPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	gifMedia := h.uploadGif(admin.Token)
	post := h.createPost(admin, map[string]any{"kind": "image", "body": "", "mediaIds": []int64{gifMedia.ID}})

	// Re-upload isn't needed: the same owner may attach one media id to more than one place
	// (see ownedMedia/commentMediaOwned - ownership, not exclusivity, is what's checked).
	var comment db.Comment
	h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{"mediaId": gifMedia.ID}).
		expect(http.StatusCreated).decode(&comment)

	paths, err := h.db.AdminDeleteComment(context.Background(), comment.ID)
	if err != nil {
		t.Fatalf("AdminDeleteComment: %v", err)
	}
	if len(paths) != 0 {
		t.Errorf("orphan paths = %v, want none - the post still references this media", paths)
	}
	if _, err := h.db.GetMedia(context.Background(), gifMedia.ID); err != nil {
		t.Errorf("media %d should still exist (still the post's attachment): %v", gifMedia.ID, err)
	}
}

// newHarnessWithKlipyKey is newHarness plus a configured Klipy key, for the one test that
// needs server-info to report gifSearch: true.
func newHarnessWithKlipyKey(t *testing.T, key string) *harness {
	t.Helper()
	return newHarnessWithConfig(t, func(cfg *config.Config) { cfg.KlipyKey = key })
}
