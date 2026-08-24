package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// forgottenOldEnough clears forgottenAgeFloor (90 days) with a day to spare, so a test seeding
// a forgotten photo isn't sitting right on the boundary.
const forgottenOldEnough = 91 * 24 * time.Hour

// forgottenTooRecent is old enough to already clear RandomMemory's own 14-day floor - proving
// a test post excluded here is excluded specifically by the forgotten-photo age floor, not by
// some other recency check - but still well short of forgottenAgeFloor.
const forgottenTooRecent = 30 * 24 * time.Hour

// forgottenCandidatePost creates a photo-bearing check-in backdated to when - the base
// fixture every "would otherwise qualify" test in this file builds on.
func (h *harness) forgottenCandidatePost(a actor, when time.Time) db.Post {
	h.t.Helper()
	media := h.uploadImage(a.Token)
	post := h.createPost(a, map[string]any{
		"kind": "image", "body": "an old photo", "mediaIds": []int64{media.ID},
	})
	backdatePost(h.t, h, post.ID, when)
	return post
}

// comment posts a plain-text comment as [a], failing the test unless the server accepts it,
// and returns what the server created. Most callers only care that it worked; the ones
// asking where a notification about it would land need its id.
func (h *harness) comment(a actor, postID int64, body string) db.Comment {
	h.t.Helper()
	var c db.Comment
	h.post("/api/posts/"+itoa(postID)+"/comments", a.Token, map[string]any{"body": body}).
		expect(http.StatusCreated).decode(&c)
	return c
}

// reply is comment, threaded under an existing comment on the same post.
func (h *harness) reply(a actor, postID, parentID int64, body string) db.Comment {
	h.t.Helper()
	var c db.Comment
	h.post("/api/posts/"+itoa(postID)+"/comments", a.Token,
		map[string]any{"body": body, "parentCommentId": parentID}).
		expect(http.StatusCreated).decode(&c)
	return c
}

type forgottenPhotoResp struct {
	Post *db.Post `json:"post"`
}

func (h *harness) forgottenPhoto(token string) forgottenPhotoResp {
	h.t.Helper()
	var got forgottenPhotoResp
	h.get("/api/memories/forgotten", token).expect(http.StatusOK).decode(&got)
	return got
}

// TestForgottenPhotoReturnsAPost pins the happy path: an old, quiet, photo-bearing post comes
// back as the forgotten photo, with the fields a member would recognize their own check-in by.
func TestForgottenPhotoReturnsAPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.forgottenCandidatePost(admin, time.Now().Add(-forgottenOldEnough))

	got := h.forgottenPhoto(admin.Token)
	if got.Post == nil {
		t.Fatal("post = nil, want the seeded forgotten photo")
	}
	if got.Post.ID != post.ID {
		t.Errorf("post id = %d, want %d", got.Post.ID, post.ID)
	}
	if got.Post.AuthorName != admin.Name {
		t.Errorf("author name = %q, want %q", got.Post.AuthorName, admin.Name)
	}
}

// TestForgottenPhotoWireShapeMatchesFeedPost asserts the JSON keys the client's Post.fromJson
// actually reads are present - including "media", which is what tells the client this is a
// photo it can render - so a serializer that quietly diverged from the feed/getPost shape
// would fail here rather than only in the app at runtime.
func TestForgottenPhotoWireShapeMatchesFeedPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.forgottenCandidatePost(admin, time.Now().Add(-forgottenOldEnough))

	var env struct {
		Post map[string]any `json:"post"`
	}
	h.get("/api/memories/forgotten", admin.Token).expect(http.StatusOK).decode(&env)
	if env.Post == nil {
		t.Fatal("post = nil, want the seeded forgotten photo")
	}
	for _, key := range []string{
		"id", "authorId", "authorName", "kind", "body", "createdAt",
		"likeCount", "commentCount", "likedByViewer", "media",
	} {
		if _, ok := env.Post[key]; !ok {
			t.Errorf("post JSON missing key %q: %v", key, env.Post)
		}
	}
}

// TestForgottenPhotoExcludesRecentPosts pins the age floor: a photo from a month ago is
// already old enough to be a RandomMemory (14 days), but nowhere near old enough to be
// "forgotten" (90 days) - it is not yet the kind of neglect the feature means to surface.
func TestForgottenPhotoExcludesRecentPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.forgottenCandidatePost(admin, time.Now().Add(-forgottenTooRecent))

	got := h.forgottenPhoto(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v, want nil - the only post is younger than forgottenAgeFloor", got.Post)
	}
}

// TestForgottenPhotoExcludesHeavilyEngagedPosts pins the engagement ceiling: an old photo
// three different members have liked is not neglected - it got noticed - so it must not
// surface even though nothing else about it disqualifies it.
func TestForgottenPhotoExcludesHeavilyEngagedPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	m1 := h.member(admin, "Sam")
	m2 := h.member(admin, "Lee")
	post := h.forgottenCandidatePost(admin, time.Now().Add(-forgottenOldEnough))

	h.like(admin, post.ID)
	h.like(m1, post.ID)
	h.like(m2, post.ID)

	got := h.forgottenPhoto(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v, want nil - 3 likes is past forgottenEngagementCeiling", got.Post)
	}
}

// TestForgottenPhotoAllowsALightlyEngagedPost pins the other half of the engagement rule: a
// single stray like must not disqualify an otherwise-forgotten photo (see
// forgottenEngagementCeiling's own doc comment for why zero-only would be too strict for a
// small group).
func TestForgottenPhotoAllowsALightlyEngagedPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	post := h.forgottenCandidatePost(admin, time.Now().Add(-forgottenOldEnough))
	h.like(member, post.ID)

	got := h.forgottenPhoto(admin.Token)
	if got.Post == nil {
		t.Fatal("post = nil, want the seeded photo - a single like must still count as forgotten")
	}
	if got.Post.ID != post.ID {
		t.Errorf("post id = %d, want %d", got.Post.ID, post.ID)
	}
}

// TestForgottenPhotoExcludesTextOnlyPosts pins that this is "forgotten PHOTOS": an old, quiet,
// text-only check-in never qualifies, no matter how neglected it is.
func TestForgottenPhotoExcludesTextOnlyPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "old, quiet, no photo"})
	backdatePost(t, h, post.ID, time.Now().Add(-forgottenOldEnough))

	got := h.forgottenPhoto(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v, want nil - the only eligible-by-age-and-engagement post has no media", got.Post)
	}
}

// TestForgottenPhotoExcludesRecapPosts pins that a recap - a summary of a period, not a
// forgotten moment - never surfaces as one, even when it's the only post old enough to
// qualify.
func TestForgottenPhotoExcludesRecapPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	seedRecapPost(t, h, admin.ID, time.Now().Add(-forgottenOldEnough))

	got := h.forgottenPhoto(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v, want nil - the only eligible-by-age post is a recap", got.Post)
	}
}

// TestForgottenPhotoExcludesBlockedAuthors pins that blocking a member removes their history
// from the forgotten-photo pool, exactly as it already does from the feed and from
// RandomMemory.
func TestForgottenPhotoExcludesBlockedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	h.forgottenCandidatePost(member, time.Now().Add(-forgottenOldEnough))

	if got := h.forgottenPhoto(admin.Token); got.Post == nil {
		t.Fatal("post = nil before blocking, want the seeded photo")
	}

	h.post("/api/me/blocks/"+itoa(member.ID), admin.Token, nil).expect(http.StatusNoContent)

	got := h.forgottenPhoto(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v after blocking the only eligible author, want nil", got.Post)
	}
}

// TestForgottenPhotoExcludesRevokedAuthors pins the other half of the author filter: a member
// an admin has since revoked takes their history out of the pool too.
func TestForgottenPhotoExcludesRevokedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	h.forgottenCandidatePost(member, time.Now().Add(-forgottenOldEnough))

	if got := h.forgottenPhoto(admin.Token); got.Post == nil {
		t.Fatal("post = nil before revoking, want the seeded photo")
	}

	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	got := h.forgottenPhoto(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v after revoking the only eligible author, want nil", got.Post)
	}
}

// TestForgottenPhotoEmptyResultForYoungGroup pins the clean-empty-result contract for a group
// with no history old enough yet: 200 with post: null, never a 500 or an error envelope - the
// state every group's first few months actually look like.
func TestForgottenPhotoEmptyResultForYoungGroup(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	// A photo posted just now: real content, just nowhere near old enough.
	h.forgottenCandidatePost(admin, time.Now())

	res := h.get("/api/memories/forgotten", admin.Token)
	res.expect(http.StatusOK)
	var env struct {
		Post *db.Post `json:"post"`
	}
	res.decode(&env)
	if env.Post != nil {
		t.Fatalf("post = %+v, want nil for a young group with nothing old enough yet", env.Post)
	}
}

// TestForgottenPhotoAnyMemberMayCall pins that the endpoint is not admin-gated: it sits under
// the ordinary requireAuth group in Router(), not the requireAdmin subgroup.
func TestForgottenPhotoAnyMemberMayCall(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	h.forgottenCandidatePost(admin, time.Now().Add(-forgottenOldEnough))

	got := h.forgottenPhoto(member.Token)
	if got.Post == nil {
		t.Fatal("post = nil for a non-admin member, want the seeded photo - the endpoint must not be admin-only")
	}
}

// TestForgottenPhotoRequiresAuth pins that an unauthenticated caller is rejected, the same
// contract every other authenticated content route gives.
func TestForgottenPhotoRequiresAuth(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	res := h.get("/api/memories/forgotten", "")
	if res.Status != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 for a missing token", res.Status)
	}
}

// TestForgottenPhotoRouteIsRateLimited drives the real route through the real router, the same
// way TestRandomMemoryRouteIsRateLimited does - a member mashing "Another" must eventually get
// 429, not keep spending unbounded requests.
func TestForgottenPhotoRouteIsRateLimited(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	burst := int(newContentLimits().forgotten.burst)
	for i := 0; i < burst; i++ {
		h.get("/api/memories/forgotten", admin.Token).expect(http.StatusOK)
	}
	res := h.get("/api/memories/forgotten", admin.Token)
	if res.Status != http.StatusTooManyRequests {
		t.Fatalf("status past the burst = %d, want 429; body: %s", res.Status, res.Body)
	}
}

// TestServerInfoAdvertisesForgotten pins the capability flag a client gates the "Forgotten
// photos" hub entry on - hidden entirely for a server old enough to 404 the route.
func TestServerInfoAdvertisesForgotten(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	var info map[string]any
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
	if v, _ := info["forgotten"].(bool); !v {
		t.Errorf(`server-info["forgotten"] = %v, want true`, info["forgotten"])
	}
}
