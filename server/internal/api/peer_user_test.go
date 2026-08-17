package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// asMap decodes a response body into a generic map, so a test can assert on which top-level
// keys are (or aren't) present - not just what a typed struct happens to declare.
func (r *response) asMap(t *testing.T) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(r.Body, &m); err != nil {
		t.Fatalf("decode into map: %v; body: %s", err, r.Body)
	}
	return m
}

// CRITICAL 2 of the pre-submission audit: GET /api/users returned every member's phone
// number unconditionally, and an empty search matches everyone - so one request from any
// ordinary member dumped the whole roster's numbers, which in this invite-only app double
// as the invite credential (docs/self-hosting/security.md).
func TestSearchUsersHidesPhoneFromPeers(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.member(admin, "Sam")

	var page struct {
		Users []map[string]any `json:"users"`
	}
	h.get("/api/users?search=", admin.Token).expect(http.StatusOK).decode(&page)
	if len(page.Users) != 2 {
		t.Fatalf("users = %+v, want both members", page.Users)
	}
	for _, u := range page.Users {
		if _, has := u["phone"]; has {
			t.Errorf("user %v carries a raw phone number, want it stripped for a peer view", u["id"])
		}
		key, _ := u["phoneKey"].(string)
		if key == "" {
			t.Errorf("user %v has no phoneKey - the multi-group join needs something to compare", u["id"])
		}
	}
}

// GET /api/users/{id} is the other route the audit named directly: any authenticated member
// could look up any other member by id and get their phone back.
func TestGetUserHidesPhoneFromPeers(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	m := h.get("/api/users/"+itoa(member.ID), admin.Token).expect(http.StatusOK).asMap(t)
	if _, has := m["phone"]; has {
		t.Error("GET /api/users/{id} carries a raw phone number, want it stripped")
	}
	if key, _ := m["phoneKey"].(string); key == "" {
		t.Error("GET /api/users/{id} has no phoneKey")
	}
}

// The "people" half of full-content search reuses SearchUsers under the hood - same fix,
// same reason.
func TestSearchPeopleResultsHidePhone(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.member(admin, "Sam")

	var page struct {
		People []map[string]any `json:"people"`
	}
	h.get("/api/search?q=Sam", admin.Token).expect(http.StatusOK).decode(&page)
	if len(page.People) != 1 {
		t.Fatalf("people = %+v, want the one matching member", page.People)
	}
	if _, has := page.People[0]["phone"]; has {
		t.Error("search's people results carry a raw phone number, want it stripped")
	}
}

// The caller's own record is the one peer-view exception: GET /api/me still needs the real
// phone (it's how the app shows a member their own number, e.g. before a reset).
func TestMeStillReturnsOwnPhone(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	m := h.get("/api/me", admin.Token).expect(http.StatusOK).asMap(t)
	want := strings.TrimPrefix(admin.Phone, "+") // the server stores/returns the normalized form
	if got, _ := m["phone"].(string); got != want {
		t.Errorf("GET /api/me phone = %q, want %q - the caller's own record must keep it", got, want)
	}
}

// The admin-only roster is the other legitimate exception: admins manage invites and need
// the real numbers.
func TestAdminListUsersStillReturnsPhone(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	var page struct {
		Users []map[string]any `json:"users"`
	}
	h.get("/api/admin/users", admin.Token).expect(http.StatusOK).decode(&page)
	want := strings.TrimPrefix(member.Phone, "+")
	found := false
	for _, u := range page.Users {
		if int64(u["id"].(float64)) == member.ID {
			found = true
			if got, _ := u["phone"].(string); got != want {
				t.Errorf("admin listing phone = %q, want %q", got, want)
			}
		}
	}
	if !found {
		t.Fatalf("admin listing = %+v, missing member %d", page.Users, member.ID)
	}
}

// The multi-group client-side join (person_directory.dart) only works if the same phone
// keys the same way everywhere a peer view is returned, and two different phones must never
// collide.
func TestPhoneKeyIsStableAndDistinguishesMembers(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")

	fromList := h.get("/api/users?search=", admin.Token).expect(http.StatusOK).asMap(t)
	users := fromList["users"].([]any)
	var listKey string
	for _, raw := range users {
		u := raw.(map[string]any)
		if int64(u["id"].(float64)) == member.ID {
			listKey, _ = u["phoneKey"].(string)
		}
	}
	fromGet := h.get("/api/users/"+itoa(member.ID), admin.Token).expect(http.StatusOK).asMap(t)
	getKey, _ := fromGet["phoneKey"].(string)

	if listKey == "" || getKey == "" {
		t.Fatalf("phoneKey missing: list=%q get=%q", listKey, getKey)
	}
	if listKey != getKey {
		t.Errorf("phoneKey for the same member differs by route: list=%q get=%q", listKey, getKey)
	}

	adminView := h.get("/api/users/"+itoa(admin.ID), member.Token).expect(http.StatusOK).asMap(t)
	adminKey, _ := adminView["phoneKey"].(string)
	if adminKey == listKey {
		t.Error("two different members must not share a phoneKey")
	}
}
