package api

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// seedRecapActivity creates enough posts, from enough distinct authors, to clear the
// quality bar (>=3 posts, >=2 posters) inside [start, end).
func seedRecapActivity(h *harness, admin, member actor) {
	h.createPost(admin, map[string]any{"kind": "text", "body": "Monday check-in"})
	h.createPost(member, map[string]any{"kind": "text", "body": "Tuesday check-in"})
	h.createPost(member, map[string]any{"kind": "text", "body": "Wednesday check-in"})
}

// TestRecapSchedulerIdempotency invokes the scheduled-recap generator twice for the exact
// same period - as a restart mid-tick, or two ticks landing close together, would - and
// pins that only one post results. A bug here (e.g. dropping the advisory lock or the
// partial unique index) would double-post the group's recap every week.
func TestRecapSchedulerIdempotency(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapActivity(h, admin, member)

	start := time.Now().Add(-1 * time.Hour)
	end := time.Now().Add(1 * time.Hour)

	h.srv.generateScheduledRecap(context.Background(), "weekly", start, end)
	h.srv.generateScheduledRecap(context.Background(), "weekly", start, end)

	recaps := 0
	for _, p := range h.feed(admin) {
		if p.Kind == "recap" {
			recaps++
		}
	}
	if recaps != 1 {
		t.Errorf("recap posts in feed = %d, want exactly 1 after generating the same period twice", recaps)
	}
}

// TestRecapSchedulerBackfillGuard pins recap_since: a period starting before it must never
// be generated, even when the group-local hour/weekday say the moment has arrived - this is
// what stops turning the feature on for an existing group from producing a recap for
// history nobody asked for.
func TestRecapSchedulerBackfillGuard(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapActivity(h, admin, member)

	now := time.Now().UTC()
	h.patch("/api/admin/server", admin.Token, map[string]any{
		"recapCadence": "weekly",
		"recapWeekday": isoWeekday(now),
		"recapHour":    now.Hour(),
		"recapOffset":  0,
	}).expect(http.StatusOK)
	// Push the backfill guard to strictly after the period this tick would compute, so the
	// guard is the only thing standing between "due" and "generated".
	if _, err := h.db.Pool.Exec(context.Background(),
		`UPDATE server_config SET recap_since = now() + interval '1 day' WHERE id = 1`); err != nil {
		t.Fatalf("set recap_since: %v", err)
	}

	h.srv.runRecapTick(context.Background())

	for _, p := range h.feed(admin) {
		if p.Kind == "recap" {
			t.Fatal("a recap was generated for a period before recap_since - the backfill guard did not hold")
		}
	}
}

// TestRecapSchedulerOffCadenceDoesNothing pins that "off" never generates, even at exactly
// the configured hour/weekday.
func TestRecapSchedulerOffCadenceDoesNothing(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapActivity(h, admin, member)

	now := time.Now().UTC()
	h.patch("/api/admin/server", admin.Token, map[string]any{
		"recapCadence": "off",
		"recapWeekday": isoWeekday(now),
		"recapHour":    now.Hour(),
		"recapOffset":  0,
	}).expect(http.StatusOK)

	h.srv.runRecapTick(context.Background())

	for _, p := range h.feed(admin) {
		if p.Kind == "recap" {
			t.Fatal("a recap was generated while recapCadence is 'off'")
		}
	}
}

// TestGenerateRecapDuplicateThenReplace pins the on-demand endpoint's confirm-before-
// replace flow: the same (periodStart, periodEnd, panels) without replace=true is refused
// with 409 and the existing post id; with replace=true it deletes the old post and inserts
// the new one, and the old post id is genuinely gone afterward.
func TestGenerateRecapDuplicateThenReplace(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapActivity(h, admin, member)

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	body := map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}

	var first db.Post
	h.post("/api/admin/recaps", admin.Token, body).expect(http.StatusCreated).decode(&first)

	dup := h.post("/api/admin/recaps", admin.Token, body).expect(http.StatusConflict)
	var conflict struct {
		PostID int64 `json:"postId"`
	}
	dup.decode(&conflict)
	if conflict.PostID != first.ID {
		t.Errorf("409 postId = %d, want the existing recap's id %d", conflict.PostID, first.ID)
	}

	replaceBody := map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}, "replace": true}
	var second db.Post
	h.post("/api/admin/recaps", admin.Token, replaceBody).expect(http.StatusCreated).decode(&second)
	if second.ID == first.ID {
		t.Error("replace returned the same post id - it should delete and re-insert")
	}
	h.get("/api/posts/"+itoa(first.ID), admin.Token).expect(http.StatusNotFound)
}

// TestGenerateRecapRequiresAdmin pins that a non-admin member is refused (403), not merely
// unauthenticated - the on-demand endpoint sits under the same requireAdmin gate as the
// rest of PATCH /api/admin/server's neighbourhood.
func TestGenerateRecapRequiresAdmin(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	h.post("/api/admin/recaps", member.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusForbidden)
}

// TestGenerateRecapQualityBarSkip pins that a period with too little activity (fewer than
// 3 posts, or fewer than 2 distinct posters) is refused rather than posting an empty deck -
// mirroring runDigest's "say nothing" philosophy.
func TestGenerateRecapQualityBarSkip(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.createPost(admin, map[string]any{"kind": "text", "body": "just the one"})

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusUnprocessableEntity)
}

// TestRecapWireShape pins the back-compat contract in the actual bytes the server sends: a
// recap post reports kind == "recap", carries no media ids at all, and has a non-empty
// body. This is exactly what makes a v1.5.4 client (gates on kind == 'image') and a v1.9.x
// client (gates on media.isNotEmpty) degrade identically to a caption-only card instead of
// diverging - see 0018_recap.sql's doc comment. It also pins the author identity override:
// authorName is the group's name, not the admin's.
func TestRecapWireShape(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	h.patch("/api/admin/server", admin.Token, map[string]any{"name": "Ridgeway Family"}).expect(http.StatusOK)
	seedRecapActivity(h, admin, member)

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	res := h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage", "awards"}}).
		expect(http.StatusCreated)

	body := string(res.Body)
	if strings.Contains(body, `"mediaIds"`) || strings.Contains(body, `"media"`) {
		t.Errorf("recap post body carries a media field: %s", body)
	}

	var post db.Post
	res.decode(&post)
	if post.Kind != "recap" {
		t.Errorf("kind = %q, want %q", post.Kind, "recap")
	}
	if post.Body == "" {
		t.Error("body is empty - it's the entire value an old client ever sees")
	}
	if len(post.MediaIDs) != 0 || len(post.Media) != 0 || post.MediaID != nil {
		t.Errorf("recap post has media attached (MediaIDs=%v Media=%v MediaID=%v), want none",
			post.MediaIDs, post.Media, post.MediaID)
	}
	if post.AuthorName != "Ridgeway Family" {
		t.Errorf("authorName = %q, want the group name %q", post.AuthorName, "Ridgeway Family")
	}
	if post.AuthorPhotoID != nil {
		t.Errorf("authorPhotoId = %v, want nil for a recap post", *post.AuthorPhotoID)
	}
	if post.AuthorID != admin.ID {
		t.Errorf("authorId = %d, want the admin's real id %d (so admin delete-recap works)", post.AuthorID, admin.ID)
	}
	if post.Recap == nil {
		t.Fatal("recap payload is nil")
	}
	if len(post.Recap.Panels) == 0 {
		t.Error("recap payload has no panels")
	}
}

// TestRecapSurvivesBlockingTheAdmin pins the Feed blocked-author fix: a member who blocks
// the admin (the recap's author_id) must still see the group's recaps, even though every
// other post by that author is now hidden from them.
func TestRecapSurvivesBlockingTheAdmin(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	other := h.member(admin, "Alex")
	seedRecapActivity(h, admin, member)

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	var recap db.Post
	h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusCreated).decode(&recap)

	h.post("/api/me/blocks/"+itoa(admin.ID), member.Token, nil).expect(http.StatusNoContent)

	found := false
	for _, p := range h.feed(member) {
		if p.ID == recap.ID {
			found = true
		}
		if p.Kind != "recap" && p.AuthorID == admin.ID {
			t.Errorf("post %d by the blocked admin is still visible - block did not take effect", p.ID)
		}
	}
	if !found {
		t.Error("the recap disappeared from the feed of a member who blocked the admin")
	}

	// A bystander who never blocked anyone sees it too, same as any other post.
	byst := false
	for _, p := range h.feed(other) {
		if p.ID == recap.ID {
			byst = true
		}
	}
	if !byst {
		t.Error("the recap is missing from a bystander's feed")
	}
}
