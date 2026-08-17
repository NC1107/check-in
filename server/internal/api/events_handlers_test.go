package api

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// eventPost creates a check-in carrying a photo and a location, backdated to when - the
// building block every events test uses. handleCreatePost only ever stores a location
// alongside an attachment (see content_handlers.go), so a location-bearing post always
// needs a photo too, exactly like a real check-in with GPS would.
func (h *harness) eventPost(a actor, location string, when time.Time) db.Post {
	h.t.Helper()
	media := h.uploadImage(a.Token)
	post := h.createPost(a, map[string]any{
		"kind":     "image",
		"mediaIds": []int64{media.ID},
		"location": location,
	})
	backdatePost(h.t, h, post.ID, when)
	return post
}

// seedEventRecapPost inserts a recap-kind row carrying a location directly - a real recap
// never has one (see recap.go), but this is what proves the events query's own
// kind <> 'recap' predicate rather than relying on that coincidence.
func seedEventRecapPost(t *testing.T, h *harness, authorID int64, location string, when time.Time) int64 {
	t.Helper()
	var id int64
	if err := h.db.Pool.QueryRow(context.Background(),
		`INSERT INTO posts (author_id, kind, body, location, created_at)
		 VALUES ($1, 'recap', 'Weekly recap', $2, $3) RETURNING id`,
		authorID, location, when).Scan(&id); err != nil {
		t.Fatalf("seed recap post: %v", err)
	}
	return id
}

type eventsResp struct {
	Events []db.Event `json:"events"`
}

func (h *harness) events(token string, limit int) eventsResp {
	h.t.Helper()
	path := "/api/memories/events"
	if limit > 0 {
		path += fmt.Sprintf("?limit=%d", limit)
	}
	var got eventsResp
	h.get(path, token).expect(http.StatusOK).decode(&got)
	return got
}

// TestEventsDetectsATrip pins the happy path: two members with no prior history (so
// neither has a home base anywhere, and both count as "away") checking in together from
// the same place a couple of days apart forms one trip.
func TestEventsDetectsATrip(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-2*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-2*24*time.Hour+time.Hour))

	got := h.events(admin.Token, 0)
	if len(got.Events) != 1 {
		t.Fatalf("got %d events, want 1", len(got.Events))
	}
	ev := got.Events[0]
	if ev.Kind != db.EventKindTrip {
		t.Errorf("kind = %q, want trip", ev.Kind)
	}
	if ev.Place != "Lisbon, Portugal" {
		t.Errorf("place = %q, want Lisbon, Portugal", ev.Place)
	}
	if len(ev.Participants) != 2 {
		t.Errorf("participants = %d, want 2", len(ev.Participants))
	}
	if len(ev.PostIDs) != 2 {
		t.Errorf("post ids = %v, want 2", ev.PostIDs)
	}
	if ev.PhotoCount != 2 {
		t.Errorf("photo count = %d, want 2 (both posts carried one photo each)", ev.PhotoCount)
	}
	if ev.CoverMediaID == nil {
		t.Errorf("cover media id = nil, want a cover - both posts carried a photo")
	}
}

// TestEventsWireShapeHasTheKeysTheClientReads asserts the JSON keys the client's event
// hub actually reads are present, the same way TestRandomMemoryWireShapeMatchesFeedPost
// pins the random-memory shape.
func TestEventsWireShapeHasTheKeysTheClientReads(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-2*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-2*24*time.Hour+time.Hour))

	var env struct {
		Events []map[string]any `json:"events"`
	}
	h.get("/api/memories/events", admin.Token).expect(http.StatusOK).decode(&env)
	if len(env.Events) != 1 {
		t.Fatalf("got %d events, want 1", len(env.Events))
	}
	ev := env.Events[0]
	for _, key := range []string{
		"kind", "place", "startDate", "endDate", "participants", "postIds", "photoCount",
	} {
		if _, ok := ev[key]; !ok {
			t.Errorf("event JSON missing key %q: %v", key, ev)
		}
	}
	if ev["kind"] != "trip" {
		t.Errorf(`kind = %v, want "trip"`, ev["kind"])
	}
	if _, ok := ev["coverMediaId"]; !ok {
		t.Errorf("coverMediaId missing - both posts carried a photo, so this must be present")
	}
	participants, _ := ev["participants"].([]any)
	if len(participants) != 2 {
		t.Fatalf("participants = %v, want 2 entries", ev["participants"])
	}
	first, _ := participants[0].(map[string]any)
	for _, key := range []string{"id", "name"} {
		if _, ok := first[key]; !ok {
			t.Errorf("participant JSON missing key %q: %v", key, first)
		}
	}
}

// TestEventsExcludesRecapPosts pins the kind <> 'recap' predicate directly - a recap
// row seeded into the same cluster's window must never contribute to the event.
func TestEventsExcludesRecapPosts(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-2*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-2*24*time.Hour+time.Hour))
	recapID := seedEventRecapPost(t, h, admin.ID, "Lisbon, Portugal", now.Add(-2*24*time.Hour+2*time.Hour))

	got := h.events(admin.Token, 0)
	if len(got.Events) != 1 {
		t.Fatalf("got %d events, want 1", len(got.Events))
	}
	if len(got.Events[0].PostIDs) != 2 {
		t.Errorf("post ids = %v, want exactly the 2 real check-ins, not the recap",
			got.Events[0].PostIDs)
	}
	for _, id := range got.Events[0].PostIDs {
		if id == recapID {
			t.Errorf("post ids = %v, must not include the recap post %d",
				got.Events[0].PostIDs, recapID)
		}
	}
}

// TestEventsExcludesBlockedAuthors pins that blocking a member removes their history from
// the events pool too, exactly as it already does for the feed and RandomMemory.
func TestEventsExcludesBlockedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-2*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-2*24*time.Hour+time.Hour))

	if got := h.events(admin.Token, 0); len(got.Events) != 1 {
		t.Fatalf("got %d events before blocking, want 1", len(got.Events))
	}

	h.post("/api/me/blocks/"+itoa(member.ID), admin.Token, nil).expect(http.StatusNoContent)

	got := h.events(admin.Token, 0)
	if len(got.Events) != 0 {
		t.Fatalf("got %d events after blocking the only other participant, want 0 - a trip "+
			"needs 2 distinct away authors and only 1 remains eligible", len(got.Events))
	}
}

// TestEventsExcludesRevokedAuthors pins the other half of the author filter: a member an
// admin has since revoked takes their history out of the pool too.
func TestEventsExcludesRevokedAuthors(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Lisbon, Portugal", now.Add(-2*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-2*24*time.Hour+time.Hour))

	if got := h.events(admin.Token, 0); len(got.Events) != 1 {
		t.Fatalf("got %d events before revoking, want 1", len(got.Events))
	}

	h.delete("/api/admin/users/"+itoa(member.ID), admin.Token).expect(http.StatusNoContent)

	got := h.events(admin.Token, 0)
	if len(got.Events) != 0 {
		t.Fatalf("got %d events after revoking the only other participant, want 0", len(got.Events))
	}
}

// TestEventsEmptyResultForFreshGroup pins the clean-empty-result contract: 200 with
// events: [], never a 500 or an error envelope, for a group with no history at all.
func TestEventsEmptyResultForFreshGroup(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	res := h.get("/api/memories/events", admin.Token)
	res.expect(http.StatusOK)
	var env struct {
		Events []db.Event `json:"events"`
	}
	res.decode(&env)
	if env.Events == nil {
		t.Fatal("events = nil, want an empty array (JSON []), not null")
	}
	if len(env.Events) != 0 {
		t.Fatalf("events = %+v, want none for a brand-new group with no history", env.Events)
	}
}

// TestEventsAnyMemberMayCall pins that the endpoint is not admin-gated, the same as
// RandomMemory.
func TestEventsAnyMemberMayCall(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	other := h.member(admin, "Alex")
	now := time.Now()

	h.eventPost(member, "Lisbon, Portugal", now.Add(-2*24*time.Hour))
	h.eventPost(other, "Lisbon, Portugal", now.Add(-2*24*time.Hour+time.Hour))

	got := h.events(member.Token, 0)
	if len(got.Events) != 1 {
		t.Fatalf("got %d events for a non-admin member, want 1 - the endpoint must not be "+
			"admin-only", len(got.Events))
	}
	_ = admin
}

// TestEventsRequiresAuth pins that the route sits under requireAuth: no token, no answer.
func TestEventsRequiresAuth(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	res := h.get("/api/memories/events", "")
	if res.Status != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 without a bearer token", res.Status)
	}
}

// TestEventsRespectsLimit pins that ?limit= actually bounds the result, keeping the
// newest-ranked events.
func TestEventsRespectsLimit(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	now := time.Now()

	h.eventPost(admin, "Porto, Portugal", now.Add(-40*24*time.Hour))
	h.eventPost(member, "Porto, Portugal", now.Add(-40*24*time.Hour+time.Hour))
	h.eventPost(admin, "Lisbon, Portugal", now.Add(-2*24*time.Hour))
	h.eventPost(member, "Lisbon, Portugal", now.Add(-2*24*time.Hour+time.Hour))

	all := h.events(admin.Token, 0)
	if len(all.Events) != 2 {
		t.Fatalf("got %d events with no limit, want 2", len(all.Events))
	}

	limited := h.events(admin.Token, 1)
	if len(limited.Events) != 1 {
		t.Fatalf("got %d events with limit=1, want 1", len(limited.Events))
	}
	if limited.Events[0].Place != "Lisbon, Portugal" {
		t.Errorf("place = %q, want the newer Lisbon trip ranked first", limited.Events[0].Place)
	}
}

// TestEventsRouteIsRateLimited drives the real route through the real router, the same
// way TestRandomMemoryRouteIsRateLimited exercises the sibling memories route.
func TestEventsRouteIsRateLimited(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	burst := int(newContentLimits().events.burst)
	for i := 0; i < burst; i++ {
		h.get("/api/memories/events", admin.Token).expect(http.StatusOK)
	}
	res := h.get("/api/memories/events", admin.Token)
	if res.Status != http.StatusTooManyRequests {
		t.Fatalf("status past the burst = %d, want 429; body: %s", res.Status, res.Body)
	}
}

// TestServerInfoAdvertisesEvents pins the capability flag a client gates the "You were
// there" hub entry on - hidden entirely for a server old enough to 404 the route.
func TestServerInfoAdvertisesEvents(t *testing.T) {
	h := newHarness(t)
	h.admin("Robin")

	var info map[string]any
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&info)
	if v, _ := info["events"].(bool); !v {
		t.Errorf(`server-info["events"] = %v, want true`, info["events"])
	}
}
