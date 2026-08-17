package api

import (
	"net/http"
	"testing"
)

// TestServeMediaHiddenFromBlockedAuthorButNotBystanders is the CRITICAL fix: GetVisibleMedia
// used to have no idea what a block or a revoke was, so /api/media/{id} kept answering for
// content the feed itself had already hidden. It covers both the post's cover image (the
// posts.media_id branch) and a second, non-cover attachment (the post_media branch) -
// CreatePost always inserts a post_media row for every attachment, but only the first image
// becomes the cover, so a two-image post is the only way to exercise the post_media EXISTS
// clause on its own.
func TestServeMediaHiddenFromBlockedAuthorButNotBystanders(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")
	bystander := h.member(admin, "Alex")

	cover := h.uploadImage(loud.Token)
	second := h.uploadImage(loud.Token)
	post := h.createPost(loud, map[string]any{
		"kind": "image", "body": "gallery", "mediaIds": []int64{cover.ID, second.ID},
	})
	if len(post.MediaIDs) != 2 {
		t.Fatalf("post.MediaIDs = %v, want both attachments", post.MediaIDs)
	}

	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	t.Run("cover image 404s for the blocker", func(t *testing.T) {
		h.get("/api/media/"+itoa(cover.ID), admin.Token).expect(http.StatusNotFound)
	})
	t.Run("second (non-cover) attachment also 404s for the blocker", func(t *testing.T) {
		h.get("/api/media/"+itoa(second.ID), admin.Token).expect(http.StatusNotFound)
	})
	t.Run("bystander who hasn't blocked still sees both", func(t *testing.T) {
		h.get("/api/media/"+itoa(cover.ID), bystander.Token).expect(http.StatusOK)
		h.get("/api/media/"+itoa(second.ID), bystander.Token).expect(http.StatusOK)
	})
	t.Run("the author can always see their own upload", func(t *testing.T) {
		h.get("/api/media/"+itoa(cover.ID), loud.Token).expect(http.StatusOK)
	})
}

// A revoked author's media must 404 for everyone, not just for whoever happened to block
// them - status = 'active' is the same gate every other content query already applies.
func TestServeMediaHiddenAfterAuthorRevoked(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	bystander := h.member(admin, "Alex")

	img := h.uploadImage(member.Token)
	h.createPost(member, map[string]any{"kind": "image", "body": "", "mediaIds": []int64{img.ID}})

	h.get("/api/media/"+itoa(img.ID), admin.Token).expect(http.StatusOK)

	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	h.get("/api/media/"+itoa(img.ID), admin.Token).expect(http.StatusNotFound)
	h.get("/api/media/"+itoa(img.ID), bystander.Token).expect(http.StatusNotFound)
}

// The uploader can always fetch their own file, whether or not it has ever been attached
// anywhere - GetVisibleMedia's owner_id branch is untouched by this fix and has to stay that
// way (e.g. a photo mid-compose, before the post that will use it exists yet).
func TestServeMediaOwnUnattachedUploadAlwaysResolves(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	img := h.uploadImage(admin.Token)
	h.get("/api/media/"+itoa(img.ID), admin.Token).expect(http.StatusOK)
}

// A profile photo is how a member appears throughout the app - comments, likers, tagged
// people - so it has to stay visible to every active member regardless of this fix, which
// only tightens the post/post_media/comment branches.
func TestServeMediaActiveMemberProfilePhotoResolves(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	viewer := h.member(admin, "Alex")

	photo := h.uploadImage(member.Token)
	h.send(http.MethodPut, "/api/me/photo", member.Token, map[string]any{"mediaId": photo.ID}).
		expect(http.StatusOK)

	h.get("/api/media/"+itoa(photo.ID), viewer.Token).expect(http.StatusOK)
}

// Comment media (a gif reply) previously matched none of GetVisibleMedia's branches at all -
// every member but the uploader got a 404 on a gif comment's own image. This is the other
// half of the fix: a comment gif must resolve for anyone who can see the thread, gated by
// the comment author's active/not-blocked status the same way post media is.
func TestServeMediaCommentGifVisibility(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	commenter := h.member(admin, "Sam")
	viewer := h.member(admin, "Alex")

	post := h.createPost(admin, map[string]any{"kind": "text", "body": "movie night"})
	gif := h.uploadGif(commenter.Token)
	h.post("/api/posts/"+itoa(post.ID)+"/comments", commenter.Token,
		map[string]any{"mediaId": gif.ID}).expect(http.StatusCreated)

	t.Run("resolves for the commenter", func(t *testing.T) {
		h.get("/api/media/"+itoa(gif.ID), commenter.Token).expect(http.StatusOK)
	})
	t.Run("resolves for another member who can see the thread", func(t *testing.T) {
		h.get("/api/media/"+itoa(gif.ID), viewer.Token).expect(http.StatusOK)
	})
	t.Run("404s once the viewer blocks the commenter", func(t *testing.T) {
		h.post("/api/me/blocks/"+itoa(commenter.ID), viewer.Token, nil).expect(http.StatusNoContent)
		h.get("/api/media/"+itoa(gif.ID), viewer.Token).expect(http.StatusNotFound)
	})
}
