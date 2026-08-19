package api

import (
	"context"
	"fmt"
	"net/http"
	"testing"

	"github.com/nc1107/check-in/server/internal/db"
)

// Blocking must silence the blocked person's notifications, not just hide their posts.
//
// Blocking here is asymmetric on purpose - PostVisible filters against the VIEWER's own
// block list, so a blocked member can still post and comment perfectly well. What must not
// happen is their name arriving on the blocker's lock screen: every feed and content query
// already excludes them, so the push would advertise something the recipient's own app then
// refuses to show. That is worse than a missing notification, because it cannot be acted on.
//
// These go through the real handlers and a real database, and assert on the token lists the
// push layer is actually handed - the closest thing to observing the notification itself
// without a live FCM.
func TestBlockingSilencesPushes(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	blocked := h.member(admin, "Bob")

	// Robin blocks Bob, and has a device that would otherwise be notified.
	h.post(fmt.Sprintf("/api/me/blocks/%d", blocked.ID), admin.Token, nil).
		expect(http.StatusNoContent)
	h.post("/api/me/devices", admin.Token,
		map[string]any{"token": "robin-device", "platform": "ios"}).
		expect(http.StatusNoContent)

	post := h.createPost(admin, map[string]any{"kind": "text", "body": "Robin's check-in"})
	ctx := context.Background()

	t.Run("a new check-in by the blocked member", func(t *testing.T) {
		tokens, err := h.db.TokensForNewPost(ctx, blocked.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(tokens) != 0 {
			t.Errorf("got %d tokens, want none - Robin blocked Bob, so Bob sharing a "+
				"check-in must not reach Robin's device", len(tokens))
		}
	})

	t.Run("a comment by the blocked member on the blocker's post", func(t *testing.T) {
		tokens, err := h.db.TokensForReply(ctx, post.ID, blocked.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(tokens) != 0 {
			t.Errorf("got %d tokens, want none - the push would name someone Robin blocked, "+
				"about a comment Robin's own feed hides", len(tokens))
		}
	})

	t.Run("a reply by the blocked member to the blocker's own comment", func(t *testing.T) {
		// The fourth token query, and the one that was fixed without a test. It resolves the
		// recipient through the PARENT COMMENT's author rather than the post's, so it needs
		// its own block check - and getting that correlation wrong is invisible on a read.
		//
		// The parent must be on somebody ELSE's post: the query deliberately skips a parent
		// author who also wrote the post, since notifyReply already covers them and they
		// would otherwise be told twice about one reply.
		other := h.member(admin, "Sam")
		theirPost := h.createPost(other, map[string]any{"kind": "text", "body": "Sam's"})
		var parent db.Comment
		h.post(fmt.Sprintf("/api/posts/%d/comments", theirPost.ID), admin.Token,
			map[string]any{"body": "Robin's comment on Sam's post"}).
			expect(http.StatusCreated).decode(&parent)

		tokens, err := h.db.TokensForCommentReply(ctx, parent.ID, blocked.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(tokens) != 0 {
			t.Errorf("got %d tokens, want none - a reply from someone Robin blocked must "+
				"not reach Robin either", len(tokens))
		}
	})

	t.Run("a like by the blocked member", func(t *testing.T) {
		tokens, err := h.db.TokensForLike(ctx, post.ID, blocked.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(tokens) != 0 {
			t.Errorf("got %d tokens, want none", len(tokens))
		}
	})
}

// The block filter must not silence everyone else. A filter that over-matched would be just
// as broken and far harder to notice, since nothing would ever look wrong on screen.
func TestBlockingLeavesEveryoneElseNotified(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	blocked := h.member(admin, "Bob")
	friend := h.member(admin, "Sam")

	h.post(fmt.Sprintf("/api/me/blocks/%d", blocked.ID), admin.Token, nil).
		expect(http.StatusNoContent)
	h.post("/api/me/devices", admin.Token,
		map[string]any{"token": "robin-device", "platform": "ios"}).
		expect(http.StatusNoContent)

	post := h.createPost(admin, map[string]any{"kind": "text", "body": "Robin's check-in"})
	ctx := context.Background()

	tokens, err := h.db.TokensForNewPost(ctx, friend.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens) != 1 {
		t.Errorf("got %d tokens, want 1 - Sam is not blocked and must still reach Robin",
			len(tokens))
	}

	tokens, err = h.db.TokensForReply(ctx, post.ID, friend.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens) != 1 {
		t.Errorf("got %d tokens for Sam's comment, want 1", len(tokens))
	}

	// Again on someone else's post, for the reason the sibling test documents.
	ada := h.member(admin, "Ada")
	adaPost := h.createPost(ada, map[string]any{"kind": "text", "body": "Ada's"})
	var parent db.Comment
	h.post(fmt.Sprintf("/api/posts/%d/comments", adaPost.ID), admin.Token,
		map[string]any{"body": "Robin's comment on Ada's post"}).
		expect(http.StatusCreated).decode(&parent)
	tokens, err = h.db.TokensForCommentReply(ctx, parent.ID, friend.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens) != 1 {
		t.Errorf("got %d tokens for Sam's reply, want 1 - the block filter must not silence "+
			"everyone", len(tokens))
	}
}
