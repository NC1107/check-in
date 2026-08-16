package api

import (
	"context"
	"math"
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

// setUserTitle stamps a member's title directly (bypassing BestowTitles), so a test can pin
// down a "before" state - an existing title from a prior bestowal - to check it survives
// (or doesn't) a subsequent one.
func setUserTitle(t *testing.T, h *harness, userID int64, title string, setAt time.Time) {
	t.Helper()
	if _, err := h.db.Pool.Exec(context.Background(),
		`UPDATE users SET title = $2, title_set_at = $3 WHERE id = $1`, userID, title, setAt); err != nil {
		t.Fatalf("seed title: %v", err)
	}
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

// TestGenerateRecapRejectsOverlongCustomPeriod pins the 366-day cap on an on-demand
// recap's custom period: without it, a client bug (or a hostile request) could ask for a
// query spanning the whole table.
func TestGenerateRecapRejectsOverlongCustomPeriod(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	start := time.Now().Add(-400 * 24 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().UTC().Format(time.RFC3339)
	res := h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusBadRequest)
	if !strings.Contains(res.errorMessage(), "366") {
		t.Errorf("error = %q, want it to mention the 366-day limit", res.errorMessage())
	}
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
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
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

// floatOrNaN renders a coordinate pointer for a test failure message without a nil-pointer
// panic; NaN prints clearly as "not set" without being confused for a real value.
func floatOrNaN(v *float64) float64 {
	if v == nil {
		return math.NaN()
	}
	return *v
}

// TestCreatePostNormalizesCoordinates pins that lat/lng are clamped and rounded to 2
// decimal places server-side, regardless of what the client sends - the client already
// rounds before sending (home_shell.dart's _roundCoord), but that is advisory only. This
// data accumulates permanently once a post exists, so the server, not the client, is the
// actual guarantee.
func TestCreatePostNormalizesCoordinates(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	t.Run("full precision is rounded to 2 decimal places", func(t *testing.T) {
		photo := h.uploadImage(admin.Token)
		created := h.createPost(admin, map[string]any{
			"kind":     "image",
			"body":     "high precision GPS",
			"mediaIds": []int64{photo.ID},
			"lat":      38.123456789,
			"lng":      -9.987654321,
		})
		if created.Lat == nil || *created.Lat != 38.12 {
			t.Errorf("lat = %v, want 38.12", floatOrNaN(created.Lat))
		}
		if created.Lng == nil || *created.Lng != -9.99 {
			t.Errorf("lng = %v, want -9.99", floatOrNaN(created.Lng))
		}

		// Round-trips through the feed exactly as created - not just accepted once and
		// then dropped or recomputed differently on read.
		feed := onlyPost(t, h.feed(admin))
		if feed.Lat == nil || *feed.Lat != 38.12 {
			t.Errorf("feed lat = %v, want 38.12", floatOrNaN(feed.Lat))
		}
		if feed.Lng == nil || *feed.Lng != -9.99 {
			t.Errorf("feed lng = %v, want -9.99", floatOrNaN(feed.Lng))
		}
	})

	t.Run("out-of-range coordinates are clamped, not rejected", func(t *testing.T) {
		photo := h.uploadImage(admin.Token)
		created := h.createPost(admin, map[string]any{
			"kind":     "image",
			"body":     "garbage coordinates",
			"mediaIds": []int64{photo.ID},
			"lat":      999.0,
			"lng":      -999.0,
		})
		if created.Lat == nil || *created.Lat != 90 {
			t.Errorf("lat = %v, want 90 (clamped to the valid range)", floatOrNaN(created.Lat))
		}
		if created.Lng == nil || *created.Lng != -180 {
			t.Errorf("lng = %v, want -180 (clamped to the valid range)", floatOrNaN(created.Lng))
		}
	})
}

// TestServerInfoAdvertisesRecapCapability pins the capability signal a client gates
// lat/lng (and the recap settings PATCH fields) on: without it, a new client sending those
// fields to an old server would 400 every post (DisallowUnknownFields).
func TestServerInfoAdvertisesRecapCapability(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	var info struct {
		Recap        bool   `json:"recap"`
		RecapCadence string `json:"recapCadence"`
		RecapWeekday int    `json:"recapWeekday"`
		RecapHour    int    `json:"recapHour"`
		RecapOffset  int    `json:"recapOffset"`
	}
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)

	if !info.Recap {
		t.Error(`server-info "recap" = false, want true`)
	}
	if info.RecapCadence != "weekly" {
		t.Errorf("recapCadence = %q, want the schema default %q", info.RecapCadence, "weekly")
	}
	if info.RecapWeekday != 1 {
		t.Errorf("recapWeekday = %d, want the schema default 1 (Monday)", info.RecapWeekday)
	}
	if info.RecapHour != 19 {
		t.Errorf("recapHour = %d, want the schema default 19", info.RecapHour)
	}
	if info.RecapOffset != 0 {
		t.Errorf("recapOffset = %d, want the schema default 0", info.RecapOffset)
	}
}

// TestUserPostsExcludesRecaps pins the product decision that a recap - a group artifact -
// never appears on the authoring admin's own profile timeline, even though author_id is
// genuinely theirs (so the admin's delete-recap-via-DELETE-/posts still works). It stays
// everywhere else: the main feed, GetPost, search.
func TestUserPostsExcludesRecaps(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapActivity(h, admin, member)

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	var recap db.Post
	h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusCreated).decode(&recap)

	var page struct {
		Posts []db.Post `json:"posts"`
	}
	h.get("/api/users/"+itoa(admin.ID)+"/posts", admin.Token).expect(http.StatusOK).decode(&page)

	for _, p := range page.Posts {
		if p.ID == recap.ID {
			t.Fatal("the recap post appears on the admin's own profile timeline - it is a group artifact, not a personal post")
		}
		if p.Kind == "recap" {
			t.Errorf("post %d on the profile timeline has kind 'recap', want none at all", p.ID)
		}
	}

	// It is still very much present in the main feed and directly by id.
	foundInFeed := false
	for _, p := range h.feed(admin) {
		if p.ID == recap.ID {
			foundInFeed = true
		}
	}
	if !foundInFeed {
		t.Error("the recap is missing from the main feed - it should only be excluded from the profile timeline")
	}
	h.get("/api/posts/"+itoa(recap.ID), admin.Token).expect(http.StatusOK)
}

// TestCreateRecapPostManualOriginDeduplicatesUnderLock calls db.CreateRecapPost directly
// twice with the exact same manual spec and no replace - what two concurrent identical
// on-demand requests would each attempt after both saw "nothing exists yet" from the
// handler's cheap pre-check (FindManualRecap). Before this fix, CreateRecapPost's advisory
// lock and existence re-check only ran for origin == "scheduled", so both calls would
// insert; this pins that the manual path is now covered by the same guarantee.
func TestCreateRecapPostManualOriginDeduplicatesUnderLock(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapActivity(h, admin, member)

	spec := db.RecapSpec{
		PeriodStart: time.Now().Add(-1 * time.Hour),
		PeriodEnd:   time.Now().Add(1 * time.Hour),
		Panels:      []string{"collage"},
		Cadence:     "custom",
		Origin:      "manual",
	}
	payload, err := h.db.BuildRecap(context.Background(), spec)
	if err != nil {
		t.Fatalf("BuildRecap: %v", err)
	}

	firstID, inserted, _, err := h.db.CreateRecapPost(context.Background(), admin.ID, spec, payload, nil)
	if err != nil {
		t.Fatalf("first CreateRecapPost: %v", err)
	}
	if !inserted || firstID == 0 {
		t.Fatalf("first CreateRecapPost: inserted=%v id=%d, want a fresh insert", inserted, firstID)
	}

	secondID, inserted2, conflictID, err := h.db.CreateRecapPost(context.Background(), admin.ID, spec, payload, nil)
	if err != nil {
		t.Fatalf("second CreateRecapPost: %v", err)
	}
	if inserted2 {
		t.Fatalf("second CreateRecapPost inserted a duplicate (id=%d) instead of detecting the first (id=%d)",
			secondID, firstID)
	}
	if conflictID != firstID {
		t.Errorf("conflictID = %d, want the first post's id %d", conflictID, firstID)
	}

	recaps := 0
	for _, p := range h.feed(admin) {
		if p.Kind == "recap" {
			recaps++
		}
	}
	if recaps != 1 {
		t.Errorf("recap posts in feed = %d, want exactly 1", recaps)
	}
}

// TestGenerateRecapRejectsAwardsPanel pins that Awards Night is fully retired from
// generation, not merely hidden client-side: the on-demand endpoint 400s a request for it
// rather than silently accepting and dropping it.
func TestGenerateRecapRejectsAwardsPanel(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	res := h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"awards"}}).
		expect(http.StatusBadRequest)
	if !strings.Contains(res.errorMessage(), "awards") {
		t.Errorf("error = %q, want it to mention the rejected panel type", res.errorMessage())
	}
}

// TestGeneratedRecapNeverCarriesAwardsPanel pins that neither generation path - scheduled
// or manual - can produce an awards panel any more, even though the wire format
// (RecapPanel.Awards, "awards" as a payload panel type) still exists so an
// already-published recap from before this version keeps rendering.
func TestGeneratedRecapNeverCarriesAwardsPanel(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapActivity(h, admin, member)

	start := time.Now().Add(-1 * time.Hour)
	end := time.Now().Add(1 * time.Hour)

	h.srv.generateScheduledRecap(context.Background(), "weekly", start, end)
	feed := h.feed(admin)
	var scheduled *db.Post
	for i := range feed {
		if feed[i].Kind == "recap" {
			scheduled = &feed[i]
			break
		}
	}
	if scheduled == nil {
		t.Fatal("no scheduled recap in feed")
	}
	for _, p := range scheduled.Recap.Panels {
		if p.Type == "awards" {
			t.Error("scheduled recap carries an awards panel - it was supposed to be retired")
		}
	}

	var manual db.Post
	h.post("/api/admin/recaps", admin.Token, map[string]any{
		"periodStart": start.UTC().Format(time.RFC3339),
		"periodEnd":   end.UTC().Format(time.RFC3339),
		"panels":      []string{"collage"},
	}).expect(http.StatusCreated).decode(&manual)
	for _, p := range manual.Recap.Panels {
		if p.Type == "awards" {
			t.Error("manual recap carries an awards panel - it was supposed to be retired")
		}
	}
}

// TestScheduledRecapBestowsTitlesAndPreservesNonQualifying pins the scheduler's automatic
// bestowal: a member who qualifies for an award this period gets it as their title, and a
// member who qualifies for nothing keeps whatever title they already had - title persists
// until replaced, it is never cleared by a quiet period.
func TestScheduledRecapBestowsTitlesAndPreservesNonQualifying(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	sam := h.member(admin, "Sam")
	alex := h.member(admin, "Alex")

	staleSetAt := time.Now().Add(-30 * 24 * time.Hour).UTC().Truncate(time.Second)
	setUserTitle(t, h, alex.ID, "biggest_fan", staleSetAt)

	h.createPost(admin, map[string]any{"kind": "text", "body": "Monday check-in"})
	samPost := h.createPost(sam, map[string]any{"kind": "text", "body": "Tuesday check-in"})
	h.createPost(sam, map[string]any{"kind": "text", "body": "Wednesday check-in"})
	h.like(admin, samPost.ID) // the only like anyone gets this period - makes Sam the sole most_liked qualifier

	start := time.Now().Add(-1 * time.Hour)
	end := time.Now().Add(1 * time.Hour)
	h.srv.generateScheduledRecap(context.Background(), "weekly", start, end)

	samUser, err := h.db.GetUser(context.Background(), sam.ID)
	if err != nil {
		t.Fatalf("get sam: %v", err)
	}
	if samUser.Title == nil || *samUser.Title != "most_liked" {
		t.Errorf("sam's title = %v, want most_liked (the only member with any likes this period)", samUser.Title)
	}
	if samUser.TitleSetAt == nil {
		t.Error("sam's titleSetAt is nil after being bestowed a title")
	}

	alexUser, err := h.db.GetUser(context.Background(), alex.ID)
	if err != nil {
		t.Fatalf("get alex: %v", err)
	}
	if alexUser.Title == nil || *alexUser.Title != "biggest_fan" {
		t.Errorf("alex's title = %v, want it untouched at biggest_fan - alex qualified for no award this period", alexUser.Title)
	}
	if alexUser.TitleSetAt == nil || !alexUser.TitleSetAt.Equal(staleSetAt) {
		t.Errorf("alex's titleSetAt changed to %v, want it left at %v", alexUser.TitleSetAt, staleSetAt)
	}
}

// TestGenerateRecapBestowTitlesFlag pins the on-demand endpoint's opt-in: a manual recap
// with no bestowTitles flag never touches titles, and one with bestowTitles: true does.
func TestGenerateRecapBestowTitlesFlag(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	seedRecapActivity(h, admin, member)

	start := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	end := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)

	h.post("/api/admin/recaps", admin.Token,
		map[string]any{"periodStart": start, "periodEnd": end, "panels": []string{"collage"}}).
		expect(http.StatusCreated)

	adminUser, err := h.db.GetUser(context.Background(), admin.ID)
	if err != nil {
		t.Fatalf("get admin: %v", err)
	}
	if adminUser.Title != nil {
		t.Errorf("admin's title = %q after a manual recap with no bestowTitles flag, want nil", *adminUser.Title)
	}

	h.post("/api/admin/recaps", admin.Token, map[string]any{
		"periodStart":  start,
		"periodEnd":    end,
		"panels":       []string{"collage"},
		"replace":      true,
		"bestowTitles": true,
	}).expect(http.StatusCreated)

	adminUser, err = h.db.GetUser(context.Background(), admin.ID)
	if err != nil {
		t.Fatalf("get admin again: %v", err)
	}
	if adminUser.Title == nil {
		t.Error("admin has no title after a manual recap with bestowTitles: true")
	}
}

// TestServerInfoAdvertisesTitlesCapability pins the capability signal a client gates the
// on-demand generate sheet's "bestow titles" toggle on.
func TestServerInfoAdvertisesTitlesCapability(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	var info struct {
		Titles bool `json:"titles"`
	}
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
	if !info.Titles {
		t.Error(`server-info "titles" = false, want true`)
	}
}

// TestGetUserSerializesTitle pins that both GET /api/users/{id} and GET /api/me include
// title and titleSetAt once a title has been bestowed, and that the key is absent
// (omitempty), not present-but-null, before that.
func TestGetUserSerializesTitle(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	res := h.get("/api/users/"+itoa(member.ID), admin.Token).expect(http.StatusOK)
	if strings.Contains(string(res.Body), `"title"`) {
		t.Errorf("a member with no title yet serializes a title key at all: %s", res.Body)
	}

	setAt := time.Now().UTC().Truncate(time.Second)
	setUserTitle(t, h, member.ID, "night_owl", setAt)

	var user struct {
		Title      *string    `json:"title"`
		TitleSetAt *time.Time `json:"titleSetAt"`
	}
	h.get("/api/users/"+itoa(member.ID), admin.Token).expect(http.StatusOK).decode(&user)
	if user.Title == nil || *user.Title != "night_owl" {
		t.Errorf("title = %v, want night_owl", user.Title)
	}
	if user.TitleSetAt == nil || !user.TitleSetAt.Equal(setAt) {
		t.Errorf("titleSetAt = %v, want %v", user.TitleSetAt, setAt)
	}

	// /api/me comes off userFrom (UserForToken), a separate query from GetUser - pin it
	// carries the same fields rather than assuming the two queries stay in sync.
	var me struct {
		Title *string `json:"title"`
	}
	h.get("/api/me", member.Token).expect(http.StatusOK).decode(&me)
	if me.Title == nil || *me.Title != "night_owl" {
		t.Errorf("/api/me title = %v, want night_owl", me.Title)
	}
}

// TestOrderedUniquePanelsPreservesRequestOrder pins the fix for the panel-order bug: unlike
// sortedUniquePanels (the alphabetical form used only as FindManualRecap's lookup key),
// orderedUniquePanels - the one that becomes RecapSpec.Panels - must preserve the order
// panels were requested in, deduping without reordering.
func TestOrderedUniquePanelsPreservesRequestOrder(t *testing.T) {
	tests := []struct {
		name  string
		input []string
		want  []string
	}{
		{"already in request order", []string{"collage", "z-future-panel"}, []string{"collage", "z-future-panel"}},
		{"reversed order is preserved, not alphabetized", []string{"z-future-panel", "collage"}, []string{"z-future-panel", "collage"}},
		{"duplicates dropped, first occurrence's position kept", []string{"b", "a", "b"}, []string{"b", "a"}},
		{"blank entries trimmed away", []string{" b ", "", "a"}, []string{"b", "a"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := orderedUniquePanels(tt.input)
			if len(got) != len(tt.want) {
				t.Fatalf("orderedUniquePanels(%v) = %v, want %v", tt.input, got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("orderedUniquePanels(%v)[%d] = %q, want %q", tt.input, i, got[i], tt.want[i])
				}
			}
		})
	}
}

// TestSortedUniquePanelsStillSorts pins that the separate, alphabetical helper used for the
// duplicate-recap lookup key is unaffected by the orderedUniquePanels fix above - it must
// keep normalising to a canonical order regardless of request order.
func TestSortedUniquePanelsStillSorts(t *testing.T) {
	got := sortedUniquePanels([]string{"z-future-panel", "collage"})
	want := []string{"collage", "z-future-panel"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("sortedUniquePanels = %v, want %v (alphabetical)", got, want)
	}
}
