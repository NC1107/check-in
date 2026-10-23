package api

import (
	"context"
	"net/http"
	"testing"

	"github.com/nc1107/check-in/server/internal/db"
)

func TestCreatePostTagsPeople(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	zed := h.member(admin, "Zed")
	amy := h.member(admin, "Amy")
	gone := h.member(admin, "Gone")
	if err := h.db.SetUserStatus(context.Background(), gone.ID, "revoked"); err != nil {
		t.Fatal(err)
	}

	tag := func(ids ...int64) []db.TaggedPerson {
		var post db.Post
		h.post("/api/posts", admin.Token, map[string]any{
			"kind": "text", "body": "out and about", "peopleIds": ids,
		}).expect(http.StatusCreated).decode(&post)
		return post.People
	}

	got := tag(zed.ID, amy.ID, zed.ID, admin.ID, gone.ID, 999999)
	if len(got) != 2 || got[0].ID != amy.ID || got[1].ID != zed.ID {
		t.Errorf("people = %+v, want Amy then Zed only", got)
	}
	if got := tag(); len(got) != 0 {
		t.Errorf("no tags gave %+v", got)
	}
}
