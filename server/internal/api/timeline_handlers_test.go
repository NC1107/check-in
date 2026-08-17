package api

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// timelinePost creates a check-in backdated to when, optionally carrying a photo and a
// location - the building block every timeline test uses.
func (h *harness) timelinePost(a actor, when time.Time, opts ...func(map[string]any)) db.Post {
	h.t.Helper()
	body := map[string]any{"kind": "text", "body": "check-in"}
	for _, opt := range opts {
		opt(body)
	}
	post := h.createPost(a, body)
	backdatePost(h.t, h, post.ID, when)
	return post
}

// withPhoto attaches a fresh uploaded photo to a timelinePost body.
func (h *harness) withPhoto(token string) func(map[string]any) {
	return func(body map[string]any) {
		media := h.uploadImage(token)
		body["kind"] = "image"
		body["mediaIds"] = []int64{media.ID}
	}
}

// withLocation sets a timelinePost body's location.
func withLocation(loc string) func(map[string]any) {
	return func(body map[string]any) { body["location"] = loc }
}

// seedTimelinePosts inserts n plain text check-ins directly into the database, each dated
// an hour apart starting at start - bypassing both handleCreatePost's per-member rate
// limiter (burst 10, refill 30/min: a loop of real HTTP creates would hit it long before
// reaching the hundreds needed to exercise the timeline month cap) and the image-upload
// cost a photo-bearing fixture would otherwise add for a test that only cares about count.
func seedTimelinePosts(t *testing.T, h *harness, authorID int64, start time.Time, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		if _, err := h.db.Pool.Exec(context.Background(),
			`INSERT INTO posts (author_id, kind, body, created_at) VALUES ($1, 'text', 'check-in', $2)`,
			authorID, start.Add(time.Duration(i)*time.Hour)); err != nil {
			t.Fatalf("seed timeline post %d: %v", i, err)
		}
	}
}

type timelineResp struct {
	Months []db.TimelineMonth `json:"months"`
}

func (h *harness) timeline(token string) timelineResp {
	h.t.Helper()
	var got timelineResp
	h.get("/api/memories/timeline", token).expect(http.StatusOK).decode(&got)
	return got
}

type timelineMonthResp struct {
	Posts   []db.Post `json:"posts"`
	HasMore bool      `json:"hasMore"`
}

func (h *harness) timelineMonth(token string, year, month int) *response {
	h.t.Helper()
	return h.get(fmt.Sprintf("/api/memories/timeline/%d/%d", year, month), token)
}

// TestTimelineGroupsByMonth pins the happy path: posts in two different months come back as
// two month entries, newest first, with the right counts.
func TestTimelineGroupsByMonth(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	h.timelinePost(admin, time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC),
		h.withPhoto(admin.Token), withLocation("Lisbon, Portugal"))
	h.timelinePost(member, time.Date(2026, 6, 20, 12, 0, 0, 0, time.UTC),
		withLocation("Lisbon, Portugal"))
	h.timelinePost(admin, time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC),
		h.withPhoto(admin.Token), withLocation("Porto, Portugal"))

	got := h.timeline(admin.Token)
	if len(got.Months) != 2 {
		t.Fatalf("got %d months, want 2; %+v", len(got.Months), got.Months)
	}
	if got.Months[0].Year != 2026 || got.Months[0].Month != 8 {
		t.Errorf("months[0] = %d-%02d, want 2026-08 (newest first)",
			got.Months[0].Year, got.Months[0].Month)
	}
	if got.Months[0].PostCount != 1 {
		t.Errorf("months[0].postCount = %d, want 1", got.Months[0].PostCount)
	}
	if got.Months[1].Year != 2026 || got.Months[1].Month != 6 {
		t.Errorf("months[1] = %d-%02d, want 2026-06", got.Months[1].Year, got.Months[1].Month)
	}
	if got.Months[1].PostCount != 2 {
		t.Errorf("months[1].postCount = %d, want 2", got.Months[1].PostCount)
	}
	if got.Months[1].PosterCount != 2 {
		t.Errorf("months[1].posterCount = %d, want 2 distinct authors", got.Months[1].PosterCount)
	}
	if got.Months[1].PlaceCount != 1 {
		t.Errorf("months[1].placeCount = %d, want 1 (both June posts share Lisbon)",
			got.Months[1].PlaceCount)
	}
}

// TestTimelineIncludesTheCurrentMonth pins that, unlike RandomMemory, there is no recency
// floor: a check-in from moments ago still shows up on the timeline.
func TestTimelineIncludesTheCurrentMonth(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.createPost(admin, map[string]any{"kind": "text", "body": "just now"})

	got := h.timeline(admin.Token)
	if len(got.Months) != 1 {
		t.Fatalf("got %d months, want 1 for a single just-posted check-in", len(got.Months))
	}
	now := time.Now()
	if got.Months[0].Year != now.Year() || got.Months[0].Month != int(now.Month()) {
		t.Errorf("month = %d-%02d, want the current month %d-%02d",
			got.Months[0].Year, got.Months[0].Month, now.Year(), int(now.Month()))
	}
}

// TestTimelineExcludesRecapPosts mirrors TestEventsExcludesRecapPosts: a recap row must
// never contribute to a month's stats.
func TestTimelineExcludesRecapPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	seedRecapPost(t, h, admin.ID, time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC))

	got := h.timeline(admin.Token)
	if len(got.Months) != 0 {
		t.Fatalf("months = %+v, want none - the only post is a recap", got.Months)
	}
}

// TestTimelineExcludesBlockedAuthors mirrors the same predicate test on events/memories.
func TestTimelineExcludesBlockedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	h.timelinePost(member, time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC))

	if got := h.timeline(admin.Token); len(got.Months) != 1 {
		t.Fatalf("got %d months before blocking, want 1", len(got.Months))
	}

	h.post("/api/me/blocks/"+itoa(member.ID), admin.Token, nil).expect(http.StatusNoContent)

	got := h.timeline(admin.Token)
	if len(got.Months) != 0 {
		t.Fatalf("months = %+v after blocking the only poster, want none", got.Months)
	}
}

// TestTimelineExcludesRevokedAuthors mirrors TestEventsExcludesRevokedAuthors.
func TestTimelineExcludesRevokedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	h.timelinePost(member, time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC))

	if got := h.timeline(admin.Token); len(got.Months) != 1 {
		t.Fatalf("got %d months before revoking, want 1", len(got.Months))
	}

	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	got := h.timeline(admin.Token)
	if len(got.Months) != 0 {
		t.Fatalf("months = %+v after revoking the only poster, want none", got.Months)
	}
}

// TestTimelineEmptyResultForFreshGroup pins the clean-empty-result contract.
func TestTimelineEmptyResultForFreshGroup(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	got := h.timeline(admin.Token)
	if got.Months == nil {
		t.Fatal("months = nil, want an empty array (JSON []), not null")
	}
	if len(got.Months) != 0 {
		t.Fatalf("months = %+v, want none for a brand-new group", got.Months)
	}
}

// TestTimelineWireShapeHasTheKeysTheClientReads pins the month-list JSON shape.
func TestTimelineWireShapeHasTheKeysTheClientReads(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.timelinePost(admin, time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC),
		h.withPhoto(admin.Token), withLocation("Lisbon, Portugal"))

	var env struct {
		Months []map[string]any `json:"months"`
	}
	h.get("/api/memories/timeline", admin.Token).expect(http.StatusOK).decode(&env)
	if len(env.Months) != 1 {
		t.Fatalf("got %d months, want 1", len(env.Months))
	}
	m := env.Months[0]
	for _, key := range []string{
		"year", "month", "postCount", "photoCount", "clipCount",
		"placeCount", "posterCount", "coverMediaIds",
	} {
		if _, ok := m[key]; !ok {
			t.Errorf("month JSON missing key %q: %v", key, m)
		}
	}
}

// TestTimelineMonthReturnsFeedShapedPosts pins that the month-detail route reuses the exact
// feed post serializer.
func TestTimelineMonthReturnsFeedShapedPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	post := h.timelinePost(admin, time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC),
		h.withPhoto(admin.Token), withLocation("Lisbon, Portugal"))

	var env timelineMonthResp
	h.timelineMonth(admin.Token, 2026, 8).expect(http.StatusOK).decode(&env)
	if len(env.Posts) != 1 {
		t.Fatalf("got %d posts, want 1", len(env.Posts))
	}
	if env.Posts[0].ID != post.ID {
		t.Errorf("post id = %d, want %d", env.Posts[0].ID, post.ID)
	}
	if len(env.Posts[0].Media) != 1 {
		t.Errorf("media = %+v, want the one attached photo - the feed's own postMediaExpr shape",
			env.Posts[0].Media)
	}
	if env.Posts[0].AuthorName != admin.Name {
		t.Errorf("authorName = %q, want %q", env.Posts[0].AuthorName, admin.Name)
	}
}

// TestTimelineMonthHasMoreAtTheCap pins the fix for the silent-truncation bug: a month
// exactly at maxTimelineMonthPosts reports hasMore: false (nothing was actually cut), while
// one post over the cap reports hasMore: true and still returns only the capped page - the
// client's own header must key off this (and off len(posts)), never off the unbounded
// TimelineMonth.PostCount from the list route, which can legitimately exceed the cap.
func TestTimelineMonthHasMoreAtTheCap(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	const cap = 200 // mirrors db.maxTimelineMonthPosts; not exported, so pinned literally here
	monthStart := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	seedTimelinePosts(t, h, admin.ID, monthStart, cap)

	var atCap timelineMonthResp
	h.timelineMonth(admin.Token, 2026, 8).expect(http.StatusOK).decode(&atCap)
	if len(atCap.Posts) != cap {
		t.Fatalf("posts = %d, want exactly %d", len(atCap.Posts), cap)
	}
	if atCap.HasMore {
		t.Errorf("hasMore = true at exactly %d posts, want false - nothing was truncated", cap)
	}

	// One more post, still comfortably inside August (the 200 above already span more than
	// 8 days from midnight Aug 1), tips it over the cap.
	seedTimelinePosts(t, h, admin.ID, monthStart.Add(cap*time.Hour), 1)

	var overCap timelineMonthResp
	h.timelineMonth(admin.Token, 2026, 8).expect(http.StatusOK).decode(&overCap)
	if len(overCap.Posts) != cap {
		t.Fatalf("posts = %d, want the page still capped at %d even though %d exist",
			len(overCap.Posts), cap, cap+1)
	}
	if !overCap.HasMore {
		t.Errorf("hasMore = false at %d posts (one over the cap), want true", cap+1)
	}
}

// TestTimelineMonthExcludesOtherMonths pins that a post outside the requested month never
// leaks into it. The fixture times sit mid-month (the 15th, noon UTC) rather than right on
// a month boundary deliberately: the exact-boundary behavior (a post near local midnight on
// the last/first day of a month) is already pinned precisely, under a controlled time zone,
// by the db package's own TestBucketTimelineLocalMidnightBoundary - this integration test
// only needs to prove the route filters by month at all, without also depending on
// whichever real time zone happens to run the test suite.
func TestTimelineMonthExcludesOtherMonths(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.timelinePost(admin, time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC))
	aug := h.timelinePost(admin, time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC))

	var env timelineMonthResp
	h.timelineMonth(admin.Token, 2026, 8).expect(http.StatusOK).decode(&env)
	if len(env.Posts) != 1 || env.Posts[0].ID != aug.ID {
		t.Fatalf("posts = %+v, want exactly the August post %d", env.Posts, aug.ID)
	}
}

// TestTimelineMonthExcludesBlockedAndRecap pins eligibility on the month-detail route too.
func TestTimelineMonthExcludesBlockedAndRecap(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapPost(t, h, admin.ID, time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC))
	blocked := h.timelinePost(member, time.Date(2026, 8, 6, 12, 0, 0, 0, time.UTC))

	h.post("/api/me/blocks/"+itoa(member.ID), admin.Token, nil).expect(http.StatusNoContent)

	var env timelineMonthResp
	h.timelineMonth(admin.Token, 2026, 8).expect(http.StatusOK).decode(&env)
	for _, p := range env.Posts {
		if p.ID == blocked.ID {
			t.Errorf("posts = %+v, must not include the blocked member's post", env.Posts)
		}
		if p.Kind == "recap" {
			t.Errorf("posts = %+v, must not include the recap row", env.Posts)
		}
	}
}

// TestTimelineMonthEmptyForFreshGroup pins the clean-empty-result contract for the
// month-detail route too.
func TestTimelineMonthEmptyForFreshGroup(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	var env timelineMonthResp
	h.timelineMonth(admin.Token, 2026, 8).expect(http.StatusOK).decode(&env)
	if len(env.Posts) != 0 {
		t.Fatalf("posts = %+v, want none for a month with nothing in it", env.Posts)
	}
}

// TestTimelineMonthGuardsBadInputs pins that a malformed or out-of-range {year}/{month}
// 400s cleanly - never a 500, never an unbounded scan.
func TestTimelineMonthGuardsBadInputs(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	cases := []struct {
		name string
		path string
	}{
		{"non-numeric month", "/api/memories/timeline/2026/august"},
		{"non-numeric year", "/api/memories/timeline/twentytwentysix/8"},
		{"month zero", "/api/memories/timeline/2026/0"},
		{"month 13", "/api/memories/timeline/2026/13"},
		{"negative month", "/api/memories/timeline/2026/-1"},
		{"absurd year", "/api/memories/timeline/999999999999/8"},
		{"year before the app existed", "/api/memories/timeline/1900/1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := h.get(tc.path, admin.Token)
			if res.Status != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400; body: %s", res.Status, res.Body)
			}
		})
	}
}

// TestTimelineMonthAcceptsTheCurrentMonth pins that "this year plus a little" is actually
// accepted, not just rejected - the upper-bound guard must not be so tight it locks out a
// real, current request.
func TestTimelineMonthAcceptsTheCurrentMonth(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	now := time.Now()

	res := h.timelineMonth(admin.Token, now.Year(), int(now.Month()))
	res.expect(http.StatusOK)
}

// TestTimelineAnyMemberMayCall pins that neither route is admin-gated.
func TestTimelineAnyMemberMayCall(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	h.timelinePost(member, time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC))

	got := h.timeline(member.Token)
	if len(got.Months) != 1 {
		t.Fatalf("got %d months for a non-admin member, want 1 - the endpoint must not be admin-only",
			len(got.Months))
	}

	res := h.timelineMonth(member.Token, 2026, 8)
	res.expect(http.StatusOK)
}

// TestTimelineRequiresAuth pins that both routes sit under requireAuth.
func TestTimelineRequiresAuth(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	if res := h.get("/api/memories/timeline", ""); res.Status != http.StatusUnauthorized {
		t.Fatalf("timeline status = %d, want 401 without a bearer token", res.Status)
	}
	if res := h.get("/api/memories/timeline/2026/8", ""); res.Status != http.StatusUnauthorized {
		t.Fatalf("timeline month status = %d, want 401 without a bearer token", res.Status)
	}
}

// TestTimelineRouteIsRateLimited drives the real route through the real router, the same
// way TestEventsRouteIsRateLimited exercises the sibling events route.
func TestTimelineRouteIsRateLimited(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	burst := int(newContentLimits().timeline.burst)
	for i := 0; i < burst; i++ {
		h.get("/api/memories/timeline", admin.Token).expect(http.StatusOK)
	}
	res := h.get("/api/memories/timeline", admin.Token)
	if res.Status != http.StatusTooManyRequests {
		t.Fatalf("status past the burst = %d, want 429; body: %s", res.Status, res.Body)
	}
}

// TestServerInfoAdvertisesTimeline pins the capability flag a client gates the "Your
// months" hub entry on - hidden entirely for a server old enough to 404 the routes.
func TestServerInfoAdvertisesTimeline(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	var info map[string]any
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
	if v, _ := info["timeline"].(bool); !v {
		t.Errorf(`server-info["timeline"] = %v, want true`, info["timeline"])
	}
}
