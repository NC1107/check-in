package api

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// oldEnough clears memoryRecencyFloor (14 days) with a day to spare, so a test seeding a
// memory isn't sitting right on the boundary.
const oldEnough = 15 * 24 * time.Hour

// backdatePost rewrites a post's created_at directly. CreatePost always stamps now(), so
// this is the only way to seed something old enough to be a memory.
func backdatePost(t *testing.T, h *harness, postID int64, when time.Time) {
	t.Helper()
	if _, err := h.db.Pool.Exec(context.Background(),
		`UPDATE posts SET created_at = $2 WHERE id = $1`, postID, when); err != nil {
		t.Fatalf("backdate post %d: %v", postID, err)
	}
}

// seedRecapPost inserts a recap-kind post directly: CreatePost can only ever produce
// 'text'/'image'/'video' (see handleCreatePost), so a recap row has to be seeded straight
// into the table the way the real recap generator's INSERT does (see db/recap.go).
func seedRecapPost(t *testing.T, h *harness, authorID int64, when time.Time) int64 {
	t.Helper()
	var id int64
	if err := h.db.Pool.QueryRow(context.Background(),
		`INSERT INTO posts (author_id, kind, body, created_at) VALUES ($1, 'recap', 'Weekly recap', $2) RETURNING id`,
		authorID, when).Scan(&id); err != nil {
		t.Fatalf("seed recap post: %v", err)
	}
	return id
}

type randomMemoryResp struct {
	Post *db.Post `json:"post"`
}

func (h *harness) randomMemory(token string) randomMemoryResp {
	h.t.Helper()
	var got randomMemoryResp
	h.get("/api/memories/random", token).expect(http.StatusOK).decode(&got)
	return got
}

// TestRandomMemoryReturnsAPost pins the happy path: an old, eligible post comes back as the
// memory, with the fields a member would recognize their own check-in by.
func TestRandomMemoryReturnsAPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "old check-in"})
	backdatePost(t, h, post.ID, time.Now().Add(-oldEnough))

	got := h.randomMemory(admin.Token)
	if got.Post == nil {
		t.Fatal("post = nil, want the seeded memory")
	}
	if got.Post.ID != post.ID {
		t.Errorf("post id = %d, want %d", got.Post.ID, post.ID)
	}
	if got.Post.Body != "old check-in" {
		t.Errorf("post body = %q, want %q", got.Post.Body, "old check-in")
	}
	if got.Post.AuthorName != admin.Name {
		t.Errorf("author name = %q, want %q", got.Post.AuthorName, admin.Name)
	}
}

// TestRandomMemoryWireShapeMatchesFeedPost asserts the JSON keys the client's Post.fromJson
// actually reads are present, so a serializer that quietly diverged from the feed/getPost
// shape would fail here rather than only in the app at runtime.
func TestRandomMemoryWireShapeMatchesFeedPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "old check-in"})
	backdatePost(t, h, post.ID, time.Now().Add(-oldEnough))

	var env struct {
		Post map[string]any `json:"post"`
	}
	h.get("/api/memories/random", admin.Token).expect(http.StatusOK).decode(&env)
	if env.Post == nil {
		t.Fatal("post = nil, want the seeded memory")
	}
	for _, key := range []string{
		"id", "authorId", "authorName", "kind", "body", "createdAt",
		"likeCount", "commentCount", "likedByViewer",
	} {
		if _, ok := env.Post[key]; !ok {
			t.Errorf("post JSON missing key %q: %v", key, env.Post)
		}
	}
}

// TestRandomMemoryExcludesRecapPosts pins that a recap - a summary of a period, not a memory
// of a moment - never surfaces as one, even when it's the only post old enough to qualify.
func TestRandomMemoryExcludesRecapPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	seedRecapPost(t, h, admin.ID, time.Now().Add(-oldEnough))

	got := h.randomMemory(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v, want nil - the only eligible-by-age post is a recap", got.Post)
	}
}

// TestRandomMemoryExcludesBlockedAuthors pins that blocking a member removes their history
// from the memory pool, exactly as it already does from the feed.
func TestRandomMemoryExcludesBlockedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	post := h.createPost(member, map[string]any{"kind": "text", "body": "old check-in"})
	backdatePost(t, h, post.ID, time.Now().Add(-oldEnough))

	if got := h.randomMemory(admin.Token); got.Post == nil {
		t.Fatal("post = nil before blocking, want the seeded memory")
	}

	h.post("/api/me/blocks/"+itoa(member.ID), admin.Token, nil).expect(http.StatusNoContent)

	got := h.randomMemory(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v after blocking the only eligible author, want nil", got.Post)
	}
}

// TestRandomMemoryExcludesRevokedAuthors pins the other half of the author filter: the query
// screens on users.status, so a member an admin has since revoked takes their history out of
// the pool too. Blocking and revoking ride the same predicate but reach it by different
// routes, and only blocking was covered.
func TestRandomMemoryExcludesRevokedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	post := h.createPost(member, map[string]any{"kind": "text", "body": "old check-in"})
	backdatePost(t, h, post.ID, time.Now().Add(-oldEnough))

	if got := h.randomMemory(admin.Token); got.Post == nil {
		t.Fatal("post = nil before revoking, want the seeded memory")
	}

	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	got := h.randomMemory(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v after revoking the only eligible author, want nil", got.Post)
	}
}

// TestRandomMemoryExcludesRecentPosts pins the recency floor: a check-in from this week is
// not a memory yet, even when it's the only post in the group.
func TestRandomMemoryExcludesRecentPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.createPost(admin, map[string]any{"kind": "text", "body": "just now"})

	got := h.randomMemory(admin.Token)
	if got.Post != nil {
		t.Fatalf("post = %+v, want nil - the only post is younger than the recency floor", got.Post)
	}
}

// TestRandomMemoryEmptyResultForFreshGroup pins the clean-empty-result contract for a group
// with no history at all: 200 with post: null, never a 500 or an error envelope.
func TestRandomMemoryEmptyResultForFreshGroup(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	res := h.get("/api/memories/random", admin.Token)
	res.expect(http.StatusOK)
	var env struct {
		Post *db.Post `json:"post"`
	}
	res.decode(&env)
	if env.Post != nil {
		t.Fatalf("post = %+v, want nil for a brand-new group with no history", env.Post)
	}
}

// TestRandomMemoryAnyMemberMayCall pins that the endpoint is not admin-gated: it sits under
// the ordinary requireAuth group in Router(), not the requireAdmin subgroup.
func TestRandomMemoryAnyMemberMayCall(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "old check-in"})
	backdatePost(t, h, post.ID, time.Now().Add(-oldEnough))

	got := h.randomMemory(member.Token)
	if got.Post == nil {
		t.Fatal("post = nil for a non-admin member, want the seeded memory - the endpoint must not be admin-only")
	}
}

// TestRandomMemoryRouteIsRateLimited drives the real route through the real router, the same
// way TestGifSearchRouteIsRateLimited exercises the gif route - a member mashing "Another"
// must eventually get 429, not keep spending unbounded requests.
func TestRandomMemoryRouteIsRateLimited(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	burst := int(newContentLimits().memories.burst)
	for i := 0; i < burst; i++ {
		h.get("/api/memories/random", admin.Token).expect(http.StatusOK)
	}
	res := h.get("/api/memories/random", admin.Token)
	if res.Status != http.StatusTooManyRequests {
		t.Fatalf("status past the burst = %d, want 429; body: %s", res.Status, res.Body)
	}
}

// TestServerInfoAdvertisesMemories pins the capability flag a client gates the whole
// Memories entry point on - hidden entirely for a server old enough to 404 the route.
func TestServerInfoAdvertisesMemories(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	var info map[string]any
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
	if v, _ := info["memories"].(bool); !v {
		t.Errorf(`server-info["memories"] = %v, want true`, info["memories"])
	}
}
