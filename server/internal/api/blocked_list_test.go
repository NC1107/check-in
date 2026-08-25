package api

// Blocking is the one moderation action a member takes entirely on their own, so being able
// to see and undo it matters as much as being able to do it. Until this route carried names
// there was no list to show: the app never called it, and undoing a block meant remembering
// the person's name well enough to search for them.

import (
	"fmt"
	"net/http"
	"testing"
)

type blockedList struct {
	BlockedIDs []int64 `json:"blockedIds"`
	Blocked    []struct {
		ID             int64  `json:"id"`
		Name           string `json:"name"`
		ProfileMediaID *int64 `json:"profileMediaId"`
	} `json:"blocked"`
}

func (h *harness) blocks(a actor) blockedList {
	h.t.Helper()
	var got blockedList
	h.get("/api/me/blocks", a.Token).expect(http.StatusOK).decode(&got)
	return got
}

func (h *harness) block(a actor, id int64) {
	h.t.Helper()
	h.post(fmt.Sprintf("/api/me/blocks/%d", id), a.Token, nil).expect(http.StatusNoContent)
}

func TestBlockListNamesWhoYouBlocked(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	sam := h.member(me, "Sam")
	ada := h.member(me, "Ada")

	if got := h.blocks(me); len(got.Blocked) != 0 || len(got.BlockedIDs) != 0 {
		t.Fatalf("a fresh account already had blocks: %+v", got)
	}

	h.block(me, sam.ID)
	h.block(me, ada.ID)

	got := h.blocks(me)
	if len(got.Blocked) != 2 {
		t.Fatalf("got %d blocked people, want 2: %+v", len(got.Blocked), got.Blocked)
	}
	// Most recently blocked first, so the one just blocked by mistake is at the top.
	if got.Blocked[0].ID != ada.ID || got.Blocked[1].ID != sam.ID {
		t.Errorf("order = %d, %d; want the most recent block first (%d then %d)",
			got.Blocked[0].ID, got.Blocked[1].ID, ada.ID, sam.ID)
	}
	if got.Blocked[0].Name != ada.Name {
		t.Errorf("name = %q, want %q - a list of ids is not something anyone can read",
			got.Blocked[0].Name, ada.Name)
	}
	// The id list stays alongside it for anything scripted against the API.
	if len(got.BlockedIDs) != 2 {
		t.Errorf("blockedIds = %v, want both ids still present", got.BlockedIDs)
	}
}

func TestBlockListDropsThemOnUnblock(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	sam := h.member(me, "Sam")

	h.block(me, sam.ID)
	if len(h.blocks(me).Blocked) != 1 {
		t.Fatal("the block did not show up in the list")
	}

	h.delete(fmt.Sprintf("/api/me/blocks/%d", sam.ID), me.Token).expect(http.StatusNoContent)

	if got := h.blocks(me); len(got.Blocked) != 0 {
		t.Errorf("still listed after unblocking: %+v", got.Blocked)
	}
}

// A member the host has since removed has no content left anywhere, so listing them offers
// nothing to act on and only makes the list longer.
func TestBlockListLeavesOutRevokedMembers(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	sam := h.member(me, "Sam")
	ada := h.member(me, "Ada")

	h.block(me, sam.ID)
	h.block(me, ada.ID)
	h.delete(fmt.Sprintf("/api/admin/users/%d", sam.ID), me.Token).expect(http.StatusNoContent)

	got := h.blocks(me)
	if len(got.Blocked) != 1 || got.Blocked[0].ID != ada.ID {
		t.Errorf("got %+v, want only the still-active member", got.Blocked)
	}
}

// One member's block list is their own. Seeing who else has blocked whom would turn a
// private safety action into something the group can read.
func TestBlockListIsPerMember(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	sam := h.member(me, "Sam")
	ada := h.member(me, "Ada")

	h.block(me, sam.ID)

	if got := h.blocks(ada); len(got.Blocked) != 0 {
		t.Errorf("another member saw %+v; a block list must be private to whoever made it",
			got.Blocked)
	}
}

// The invariant that keeps a block reversible. Blocking hides someone's check-ins and
// comments everywhere, so if it also hid them from people search there would be no route
// back to their profile and no way to undo it - the block list is the good path, and this is
// the one that has to keep working regardless.
func TestABlockedMemberStaysFindable(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	sam := h.member(me, "Sam")

	h.block(me, sam.ID)

	var found struct {
		Users []struct {
			ID   int64  `json:"id"`
			Name string `json:"name"`
		} `json:"users"`
	}
	h.get("/api/users?search=Sam", me.Token).expect(http.StatusOK).decode(&found)
	var seen bool
	for _, u := range found.Users {
		if u.ID == sam.ID {
			seen = true
		}
	}
	if !seen {
		t.Error("a blocked member vanished from people search; with their posts already " +
			"hidden there would be no way left to reach their profile and unblock them")
	}

	// And their profile still loads, which is where the Unblock button lives.
	h.get(fmt.Sprintf("/api/users/%d", sam.ID), me.Token).expect(http.StatusOK)
}
