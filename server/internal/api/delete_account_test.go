package api

import (
	"fmt"
	"net/http"
	"testing"
)

// Account deletion is the path App Review checks under Guideline 5.1.1(v), and almost none
// of what it removes was verified. Dropping sessions from the delete list, dropping
// user_blocks, and deleting the user row before the allowlist entry all left the whole
// suite green. Each of those is a real consequence:
//
//   - a surviving session means a deleted account's token still works
//   - a surviving allowlist row means the phone can sign up again with no fresh invite,
//     which is the one thing an invite-only server must not allow
//
// The allowlist case is order-dependent rather than presence-dependent: the statement finds
// the phone through a subquery on the users row, so deleting the user first silently makes
// it a no-op. That is exactly the kind of bug a list of statements invites, and exactly why
// accountDeletions documents its order.

func TestDeleteAccountRevokesTheSession(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Admin")
	gone := h.member(admin, "Departing")

	h.get("/api/me", gone.Token).expect(http.StatusOK)
	h.delete("/api/me", gone.Token).expect(http.StatusNoContent)

	// The token must stop working immediately, not merely stop being useful.
	if res := h.get("/api/me", gone.Token); res.Status != http.StatusUnauthorized {
		t.Errorf("GET /api/me after deletion = %d, want 401; body: %s", res.Status, res.Body)
	}
}

// The phone must fall off the allowlist, so re-joining needs a fresh invite from the admin.
func TestDeleteAccountRemovesThePhoneFromTheAllowlist(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Admin")
	gone := h.member(admin, "Departing")

	h.delete("/api/me", gone.Token).expect(http.StatusNoContent)

	// Signing up on the same number again must be refused until re-invited.
	res := h.signup(gone.Phone, "Sneaking Back")
	if res.Status == http.StatusOK {
		t.Fatalf("the deleted phone signed up again with no fresh invite; body: %s", res.Body)
	}

	// And it works again once the admin genuinely re-invites them.
	h.invite(admin, gone.Phone)
	h.signup(gone.Phone, "Invited Back").expect(http.StatusOK)
}

// Blocks are mutual state: leaving rows behind would keep filtering content for a member
// who is no longer there, and keep the departed account's id referenced.
func TestDeleteAccountRemovesBlocksBothWays(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Admin")
	blocker := h.member(admin, "Blocker")
	gone := h.member(admin, "Departing")

	h.post(fmt.Sprintf("/api/me/blocks/%d", gone.ID), blocker.Token, nil).
		expect(http.StatusNoContent)
	h.post(fmt.Sprintf("/api/me/blocks/%d", blocker.ID), gone.Token, nil).
		expect(http.StatusNoContent)

	h.delete("/api/me", gone.Token).expect(http.StatusNoContent)

	// The surviving member's block list must no longer mention the departed account.
	var blocks struct {
		BlockedIDs []int64 `json:"blockedIds"`
	}
	h.get("/api/me/blocks", blocker.Token).expect(http.StatusOK).decode(&blocks)
	for _, id := range blocks.BlockedIDs {
		if id == gone.ID {
			t.Errorf("block on the deleted account survived: %v", blocks.BlockedIDs)
		}
	}
}

// The last admin cannot delete themselves, or the group is left with nobody able to invite
// members, review reports or remove content.
func TestDeleteAccountRefusesTheOnlyAdmin(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Admin")
	h.member(admin, "Ordinary")

	h.delete("/api/me", admin.Token).expect(http.StatusConflict)
	// Still able to act afterwards.
	h.get("/api/me", admin.Token).expect(http.StatusOK)
}
