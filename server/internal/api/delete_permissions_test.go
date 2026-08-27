package api

import (
	"net/http"
	"testing"
)

// commentsOf reads the thread back, so a deletion is judged by what the next reader would
// actually see rather than by the delete call's own status code.
func commentsOf(t *testing.T, h *harness, postID int64, token string) []commentResp {
	t.Helper()
	var page struct {
		Comments []commentResp `json:"comments"`
	}
	h.get("/api/posts/"+itoa(postID)+"/comments", token).expect(http.StatusOK).decode(&page)
	return page.Comments
}

func addComment(t *testing.T, h *harness, postID int64, token, body string) commentResp {
	t.Helper()
	var c commentResp
	h.post("/api/posts/"+itoa(postID)+"/comments", token, map[string]any{"body": body}).
		expect(http.StatusCreated).decode(&c)
	return c
}

// Before this existed a member could write a comment and then had no way to take it back:
// AdminDeleteComment was wired only to the operator dashboard, and there was no
// DELETE /api/comments/{id} at all.
func TestDeleteOwnComment(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "movie night"})
	c := addComment(t, h, post.ID, member.Token, "wrong thread, sorry")

	h.delete("/api/comments/"+itoa(c.ID), member.Token).expect(http.StatusNoContent)

	for _, got := range commentsOf(t, h, post.ID, admin.Token) {
		if got.ID == c.ID {
			t.Fatalf("comment %d still in the thread after its author deleted it", c.ID)
		}
	}
}

// A plain member deleting someone else's comment must fail, and must fail as 404 rather
// than 403: a distinguishable "forbidden" would let anyone map which comment ids exist.
func TestDeleteOthersCommentIsRefused(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	author := h.member(admin, "Sam")
	other := h.member(admin, "Alex")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "movie night"})
	c := addComment(t, h, post.ID, author.Token, "mine to delete")

	h.delete("/api/comments/"+itoa(c.ID), other.Token).expect(http.StatusNotFound)

	found := false
	for _, got := range commentsOf(t, h, post.ID, admin.Token) {
		if got.ID == c.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("comment %d disappeared after a refused delete", c.ID)
	}
}

// The admin is the one who acts on reports for the group, so moderation has to be possible
// from inside the app rather than only from the operator dashboard.
func TestAdminDeletesAnyComment(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	post := h.createPost(admin, map[string]any{"kind": "text", "body": "movie night"})
	c := addComment(t, h, post.ID, member.Token, "something to moderate")

	h.delete("/api/comments/"+itoa(c.ID), admin.Token).expect(http.StatusNoContent)

	for _, got := range commentsOf(t, h, post.ID, admin.Token) {
		if got.ID == c.ID {
			t.Fatalf("comment %d survived an admin delete", c.ID)
		}
	}
}

// handleDeletePost used to scope every delete to the caller's own id, so an admin asking to
// remove a reported check-in got "post not found or not yours" - the one person expected to
// moderate the group was the one person who could not.
func TestAdminDeletesAnyPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	member := h.member(admin, "Sam")
	post := h.createPost(member, map[string]any{"kind": "text", "body": "reported check-in"})

	h.delete("/api/posts/"+itoa(post.ID), admin.Token).expect(http.StatusNoContent)
	h.get("/api/posts/"+itoa(post.ID), admin.Token).expect(http.StatusNotFound)
}

// The admin bypass must not become a general one: a plain member still cannot delete
// anyone else's check-in.
func TestMemberCannotDeleteOthersPost(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	author := h.member(admin, "Sam")
	other := h.member(admin, "Alex")
	post := h.createPost(author, map[string]any{"kind": "text", "body": "mine"})

	h.delete("/api/posts/"+itoa(post.ID), other.Token).expect(http.StatusNotFound)
	h.get("/api/posts/"+itoa(post.ID), author.Token).expect(http.StatusOK)
}
