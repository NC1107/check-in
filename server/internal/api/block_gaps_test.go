package api

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// ---- GAP 1: comments on a post hidden from the viewer must not be readable ----

// TestListCommentsRefusesBlockedAuthorsPost pins the fix: before it, handleListComments
// called db.ListComments with no check on the POST's own author at all, so a post whose
// author the viewer has blocked (already hidden from their feed and 404ing on
// GET /api/posts/{id}) still served its entire comment thread to anyone who knew or
// guessed the post id.
func TestListCommentsRefusesBlockedAuthorsPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")

	post := h.createPost(loud, map[string]any{"kind": "text", "body": "hot take"})
	h.post("/api/posts/"+itoa(post.ID)+"/comments", loud.Token, map[string]any{"body": "reply"}).
		expect(http.StatusCreated)

	// Sanity: the thread is readable before any block exists.
	h.get("/api/posts/"+itoa(post.ID)+"/comments", admin.Token).expect(http.StatusOK)

	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	res := h.get("/api/posts/"+itoa(post.ID)+"/comments", admin.Token)
	res.expect(http.StatusNotFound)

	// The post detail route already 404s for the same post; comments must now match it.
	h.get("/api/posts/"+itoa(post.ID), admin.Token).expect(http.StatusNotFound)
}

// TestListCommentsRefusesRevokedAuthorsPost is the same fix's other trigger: an author an
// admin has since revoked, not merely blocked by this particular viewer.
func TestListCommentsRefusesRevokedAuthorsPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	bystander := h.member(admin, "Alex")

	post := h.createPost(member, map[string]any{"kind": "text", "body": "will be revoked"})
	h.post("/api/posts/"+itoa(post.ID)+"/comments", member.Token, map[string]any{"body": "reply"}).
		expect(http.StatusCreated)

	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	h.get("/api/posts/"+itoa(post.ID)+"/comments", bystander.Token).expect(http.StatusNotFound)
}

// TestListCommentsOrdinaryCaseStillWorks confirms the new gate doesn't collateral-damage the
// common case: a normal member reading comments on a normal, unblocked post.
func TestListCommentsOrdinaryCaseStillWorks(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	post := h.createPost(member, map[string]any{"kind": "text", "body": "ordinary check-in"})
	h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{"body": "nice"}).
		expect(http.StatusCreated)

	var page struct {
		Comments []db.Comment `json:"comments"`
	}
	h.get("/api/posts/"+itoa(post.ID)+"/comments", member.Token).expect(http.StatusOK).decode(&page)
	if len(page.Comments) != 1 || page.Comments[0].Body != "nice" {
		t.Fatalf("comments = %+v, want the one ordinary comment", page.Comments)
	}
}

// ---- GAP 2: liking/commenting on a blocked author's post must be refused ----

// TestLikeRefusesBlockedAuthorsPost pins the fix: PostVisible used to check only that the
// author's account was active, so a member who blocked someone could still like their posts
// by id even though the feed had already hidden them.
func TestLikeRefusesBlockedAuthorsPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")

	post := h.createPost(loud, map[string]any{"kind": "text", "body": "like me"})
	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	h.post("/api/posts/"+itoa(post.ID)+"/like", admin.Token, nil).expect(http.StatusNotFound)
}

// TestAddCommentRefusesBlockedAuthorsPost is TestLikeRefusesBlockedAuthorsPost's twin for
// the comment-create route.
func TestAddCommentRefusesBlockedAuthorsPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")

	post := h.createPost(loud, map[string]any{"kind": "text", "body": "comment on me"})
	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{"body": "hi"}).
		expect(http.StatusNotFound)
}

// TestLikeAndCommentOrdinaryCaseStillWork confirms liking and commenting on a normal,
// unblocked post are unaffected by the fix.
func TestLikeAndCommentOrdinaryCaseStillWork(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	post := h.createPost(member, map[string]any{"kind": "text", "body": "ordinary"})
	h.post("/api/posts/"+itoa(post.ID)+"/like", admin.Token, nil).expect(http.StatusNoContent)
	h.post("/api/posts/"+itoa(post.ID)+"/comments", admin.Token, map[string]any{"body": "nice one"}).
		expect(http.StatusCreated)
}

// TestReportStillWorksOnBlockedAuthorsPost pins the deliberate carve-out: unlike liking and
// commenting, reporting a post must NOT start refusing once its author is blocked. Blocking
// and reporting are the expected pair of actions a member takes against abusive content, not
// a contradiction - refusing the report the moment someone protects themselves would make
// the safety feature actively worse at its job.
func TestReportStillWorksOnBlockedAuthorsPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")

	post := h.createPost(loud, map[string]any{"kind": "text", "body": "reported and blocked"})
	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	h.post("/api/posts/"+itoa(post.ID)+"/report", admin.Token, map[string]any{"reason": "harassment"}).
		expect(http.StatusNoContent)

	var page struct {
		Reports []db.ContentReport `json:"reports"`
	}
	h.get("/api/admin/reports", admin.Token).expect(http.StatusOK).decode(&page)
	if len(page.Reports) != 1 || page.Reports[0].PostID == nil || *page.Reports[0].PostID != post.ID {
		t.Fatalf("reports = %+v, want one report on post %d", page.Reports, post.ID)
	}
}

// TestReportStillWorksOrdinarily confirms reporting a normal post by a normal (non-blocked)
// author is unaffected.
func TestReportStillWorksOrdinarily(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	post := h.createPost(member, map[string]any{"kind": "text", "body": "ordinary"})
	h.post("/api/posts/"+itoa(post.ID)+"/report", admin.Token, map[string]any{"reason": "spam"}).
		expect(http.StatusNoContent)
}

// TestReportRefusesRevokedAuthorsPost pins ReportablePost's one remaining gate: a revoked
// author's post still 404s, matching PostVisible - there is no host left to act on a report
// about content whose author the host already removed.
func TestReportRefusesRevokedAuthorsPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	bystander := h.member(admin, "Alex")

	post := h.createPost(member, map[string]any{"kind": "text", "body": "will be revoked"})
	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	h.post("/api/posts/"+itoa(post.ID)+"/report", bystander.Token, map[string]any{"reason": "x"}).
		expect(http.StatusNotFound)
}

// ---- GAP 3: a recap surfacing a blocked member's card/roster entry ----

// TestRecapHidesBlockedAuthorsCardAndRosterEntry pins the chosen fix (filter the shared
// recap artifact per viewer at read time, see db.FilterRecapForViewer's doc comment): a
// member who blocks a fellow poster must not see that poster's collage card or cover
// roster entry, while a bystander who never blocked anyone still sees the full deck.
func TestRecapHidesBlockedAuthorsCardAndRosterEntry(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")
	bystander := h.member(admin, "Alex")

	h.createPost(admin, map[string]any{"kind": "text", "body": "one"})
	h.createPost(loud, map[string]any{"kind": "text", "body": "two"})
	h.createPost(loud, map[string]any{"kind": "text", "body": "three"})

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	var recap db.Post
	h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusCreated).decode(&recap)
	if recap.Recap == nil || len(recap.Recap.Panels) == 0 {
		t.Fatal("recap has no panels to begin with; can't test filtering")
	}
	wantPostersBefore := recap.Recap.Stats.Posters

	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	var seen db.Post
	found := false
	for _, p := range h.feed(admin) {
		if p.ID == recap.ID {
			seen = p
			found = true
		}
	}
	if !found {
		t.Fatal("the recap itself disappeared from the blocker's feed - it should stay, only its contents should filter")
	}
	if seen.Recap == nil {
		t.Fatal("filtered recap payload is nil")
	}
	for _, panel := range seen.Recap.Panels {
		for _, card := range panel.Cards {
			if card.AuthorID == loud.ID {
				t.Errorf("card by blocked author %d still present: %+v", loud.ID, card)
			}
		}
	}
	for _, person := range seen.Recap.People {
		if person.UserID == loud.ID {
			t.Errorf("roster entry for blocked author %d still present: %+v", loud.ID, person)
		}
	}
	// Stats must not contradict what's visible: posters/posts count only what survived.
	if seen.Recap.Stats.Posters != wantPostersBefore-1 {
		t.Errorf("stats.posters = %d, want %d (one fewer than before filtering)",
			seen.Recap.Stats.Posters, wantPostersBefore-1)
	}
	for _, person := range seen.Recap.People {
		if person.UserID == admin.ID && person.Posts != 1 {
			t.Errorf("admin's own roster entry changed: %+v", person)
		}
	}

	// A bystander who never blocked anyone still sees the whole thing, unfiltered.
	bystanderSeen := false
	for _, p := range h.feed(bystander) {
		if p.ID != recap.ID {
			continue
		}
		bystanderSeen = true
		foundCard := false
		for _, panel := range p.Recap.Panels {
			for _, card := range panel.Cards {
				if card.AuthorID == loud.ID {
					foundCard = true
				}
			}
		}
		if !foundCard {
			t.Error("bystander's recap is missing the loud member's card - filtering leaked across viewers")
		}
	}
	if !bystanderSeen {
		t.Error("recap missing from bystander's feed")
	}
}

// TestRecapPostDetailAlsoFiltersForBlockedAuthor confirms GET /api/posts/{id} (not just the
// feed) applies the same viewer-scoped recap filtering.
func TestRecapPostDetailAlsoFiltersForBlockedAuthor(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")

	h.createPost(admin, map[string]any{"kind": "text", "body": "one"})
	h.createPost(loud, map[string]any{"kind": "text", "body": "two"})
	h.createPost(loud, map[string]any{"kind": "text", "body": "three"})

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	var recap db.Post
	h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusCreated).decode(&recap)

	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	var got db.Post
	h.get("/api/posts/"+itoa(recap.ID), admin.Token).expect(http.StatusOK).decode(&got)
	for _, panel := range got.Recap.Panels {
		for _, card := range panel.Cards {
			if card.AuthorID == loud.ID {
				t.Errorf("GET /api/posts/{id} still carries a card from the blocked author: %+v", card)
			}
		}
	}
}

// ---- GAP 4: the digest count must exclude blocked/revoked authors and recap posts ----

// TestCountPostsSinceExcludesBlockedAuthor pins the digest fix: a member who has blocked the
// only other poster in the window must not be told "1 new check-in".
func TestCountPostsSinceExcludesBlockedAuthor(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")

	since := time.Now().Add(-1 * time.Hour)
	h.createPost(loud, map[string]any{"kind": "text", "body": "hello"})

	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	n, err := h.db.CountPostsSince(context.Background(), admin.ID, since)
	if err != nil {
		t.Fatalf("CountPostsSince: %v", err)
	}
	if n != 0 {
		t.Errorf("count = %d, want 0 - the only poster in the window is blocked", n)
	}
}

// TestCountPostsSinceExcludesRevokedAuthor pins the same fix for a revoked author.
func TestCountPostsSinceExcludesRevokedAuthor(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	viewer := h.member(admin, "Alex")

	since := time.Now().Add(-1 * time.Hour)
	h.createPost(member, map[string]any{"kind": "text", "body": "hello"})
	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	n, err := h.db.CountPostsSince(context.Background(), viewer.ID, since)
	if err != nil {
		t.Fatalf("CountPostsSince: %v", err)
	}
	if n != 0 {
		t.Errorf("count = %d, want 0 - the only poster in the window was revoked", n)
	}
}

// TestCountPostsSinceExcludesRecapPosts pins the decision that a recap post never counts as
// a "new check-in": it's the group's own periodic summary, not a fellow member's check-in,
// and counting it would double-count the activity it already tallies.
func TestCountPostsSinceExcludesRecapPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	h.createPost(admin, map[string]any{"kind": "text", "body": "one"})
	h.createPost(member, map[string]any{"kind": "text", "body": "two"})
	h.createPost(member, map[string]any{"kind": "text", "body": "three"})

	since := time.Now().Add(-1 * time.Hour)

	start := time.Now().Add(-2 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(2 * time.Hour).UTC().Format(time.RFC3339)
	h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusCreated)

	// A second, unrelated viewer with no blocks at all: the 3 ordinary posts count, the
	// recap post created on top of them must not add a 4th.
	viewer := h.member(admin, "Alex")
	n, err := h.db.CountPostsSince(context.Background(), viewer.ID, since)
	if err != nil {
		t.Fatalf("CountPostsSince: %v", err)
	}
	if n != 3 {
		t.Errorf("count = %d, want 3 (the recap post itself must not be counted)", n)
	}
}

// TestCountPostsSinceOrdinaryCaseStillWorks confirms the digest count still works normally:
// posts from active, unblocked authors are counted, and the viewer's own posts are not.
func TestCountPostsSinceOrdinaryCaseStillWorks(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	since := time.Now().Add(-1 * time.Hour)
	h.createPost(member, map[string]any{"kind": "text", "body": "one"})
	h.createPost(member, map[string]any{"kind": "text", "body": "two"})
	h.createPost(admin, map[string]any{"kind": "text", "body": "mine, shouldn't count for me"})

	n, err := h.db.CountPostsSince(context.Background(), admin.ID, since)
	if err != nil {
		t.Fatalf("CountPostsSince: %v", err)
	}
	if n != 2 {
		t.Errorf("count = %d, want 2 (member's two posts, not admin's own)", n)
	}
}
