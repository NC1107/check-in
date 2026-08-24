package api

// The activity list is what makes a missed notification recoverable, so what it does and
// does not contain is the whole feature. It is derived from likes and comments at read time
// (see db/activity.go), which means these tests are also what pins the derivation to the
// push queries it is supposed to mirror.

import (
	"context"
	"net/http"
	"net/url"
	"testing"
	"time"
)

type activityItem struct {
	Kind      string `json:"kind"`
	PostID    int64  `json:"postId"`
	CommentID *int64 `json:"commentId"`
	ActorID   int64  `json:"actorId"`
	ActorName string `json:"actorName"`
	Preview   string `json:"preview"`
	CreatedAt string `json:"createdAt"`
}

type activityPage struct {
	Items       []activityItem `json:"items"`
	UnreadCount int            `json:"unreadCount"`
	NextCursor  string         `json:"nextCursor"`
}

func (h *harness) activity(a actor) activityPage {
	h.t.Helper()
	var page activityPage
	h.get("/api/me/activity", a.Token).expect(http.StatusOK).decode(&page)
	return page
}

// kinds is the activity list flattened to its kinds, newest first - enough to say what a
// member is being shown without restating every field.
func (p activityPage) kinds() []string {
	out := make([]string, 0, len(p.Items))
	for _, it := range p.Items {
		out = append(out, it.Kind)
	}
	return out
}

func TestActivityListsCommentsRepliesAndLikesAboutMe(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")

	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})
	comment := h.comment(other, mine.ID, "looks great")
	h.like(other, mine.ID)

	// A reply to my comment on SOMEONE ELSE'S post is the third source.
	theirs := h.createPost(other, map[string]any{"kind": "text", "body": "their trip"})
	myComment := h.comment(me, theirs.ID, "where was this?")
	reply := h.reply(other, theirs.ID, myComment.ID, "Lisbon")

	page := h.activity(me)
	if got := len(page.Items); got != 3 {
		t.Fatalf("got %d items, want 3 (a comment, a like and a reply): %+v", got, page.Items)
	}
	// The list fits in one page, so there is nothing to continue from. Handing back a cursor
	// here would have the app fetch a page that can only ever be empty.
	if page.NextCursor != "" {
		t.Errorf("nextCursor = %q at the end of the list, want it absent", page.NextCursor)
	}
	// Newest first: the reply happened last.
	if page.Items[0].Kind != "reply" || page.Items[0].CommentID == nil ||
		*page.Items[0].CommentID != reply.ID {
		t.Errorf("newest item = %+v, want the reply %d", page.Items[0], reply.ID)
	}

	byKind := map[string]activityItem{}
	for _, it := range page.Items {
		byKind[it.Kind] = it
	}
	if c := byKind["comment"]; c.CommentID == nil || *c.CommentID != comment.ID {
		t.Errorf("comment item = %+v, want commentId %d", c, comment.ID)
	}
	if c := byKind["comment"]; c.Preview != "looks great" {
		t.Errorf("comment preview = %q, want the comment's text", c.Preview)
	}
	if l := byKind["like"]; l.CommentID != nil {
		t.Errorf("like carried commentId %d; a like is about the post", *l.CommentID)
	}
	if l := byKind["like"]; l.PostID != mine.ID || l.ActorID != other.ID {
		t.Errorf("like item = %+v, want post %d by %d", l, mine.ID, other.ID)
	}
	if r := byKind["reply"]; r.ActorName != other.Name {
		t.Errorf("reply actorName = %q, want %q", r.ActorName, other.Name)
	}
}

// The list is about ME. Someone else's check-in being commented on, and my own actions on
// my own posts, are both noise here - the first belongs to them, the second I already know.
func TestActivityExcludesOtherPeoplesActivityAndMyOwn(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")
	third := h.member(me, "Ada")

	// Someone else's post, commented and liked by a third member: nothing to do with me.
	theirs := h.createPost(other, map[string]any{"kind": "text", "body": "their trip"})
	h.comment(third, theirs.ID, "nice")
	h.like(third, theirs.ID)

	// And my own comment and like on my own check-in.
	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})
	h.comment(me, mine.ID, "note to self")
	h.like(me, mine.ID)

	if page := h.activity(me); len(page.Items) != 0 {
		t.Errorf("got %+v, want an empty list", page.Items)
	}
}

// Replying to my comment on my OWN check-in must appear once, not twice. The server
// deliberately does not double-buzz for this (TokensForCommentReply skips the post author),
// and the list mirrors the notifications, so a duplicate here would be the list disagreeing
// with what was actually sent.
func TestActivityDoesNotDoubleCountAReplyOnMyOwnPost(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")

	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})
	myComment := h.comment(me, mine.ID, "day one")
	h.reply(other, mine.ID, myComment.ID, "nice")

	page := h.activity(me)
	if got := page.kinds(); len(got) != 1 || got[0] != "comment" {
		t.Errorf("kinds = %v, want exactly one comment - a reply on my own post is already "+
			"covered as a comment on it", got)
	}
}

// Blocking someone is supposed to remove them from what you see. An activity list that kept
// showing their likes and comments would hand back exactly what the block was for.
func TestActivityHidesABlockedMember(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	nuisance := h.member(me, "Sam")

	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})
	h.comment(nuisance, mine.ID, "unpleasant")
	h.like(nuisance, mine.ID)

	if page := h.activity(me); len(page.Items) != 2 {
		t.Fatalf("expected the comment and like before blocking, got %+v", page.Items)
	}
	h.post("/api/me/blocks/"+itoa(nuisance.ID), me.Token, nil).expect(http.StatusNoContent)

	if page := h.activity(me); len(page.Items) != 0 {
		t.Errorf("got %+v, want nothing from a blocked member", page.Items)
	}
}

// Muting a notification should stop the buzzing, not erase history. Someone who turned off
// like notifications still wants to see who liked their check-in - that is the whole point
// of having somewhere to look.
func TestActivityIgnoresNotificationPreferences(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")
	h.patch("/api/me/notifications", me.Token,
		map[string]any{"likes": false, "replies": false}).expect(http.StatusOK)

	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})
	h.comment(other, mine.ID, "looks great")
	h.like(other, mine.ID)

	if got := len(h.activity(me).Items); got != 2 {
		t.Errorf("got %d items, want 2 - muting the push must not remove the history", got)
	}
}

// A gif-only comment has no text, so the row falls back to naming the attachment rather than
// rendering as a blank line.
func TestActivityPreviewsAGifOnlyComment(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")
	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})

	media := h.uploadGif(other.Token)
	h.post("/api/posts/"+itoa(mine.ID)+"/comments", other.Token,
		map[string]any{"mediaId": media.ID}).expect(http.StatusCreated)

	page := h.activity(me)
	if len(page.Items) != 1 || page.Items[0].Preview != "GIF" {
		t.Errorf("got %+v, want a single item previewing as GIF", page.Items)
	}
}

// Deleting a post takes its activity with it, because the rows the list is derived from are
// gone. This is the property that made deriving worth choosing over a log table, which would
// have kept describing something no longer there.
func TestActivityDropsWithTheDeletedPost(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")

	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})
	h.comment(other, mine.ID, "looks great")
	h.like(other, mine.ID)
	if got := len(h.activity(me).Items); got != 2 {
		t.Fatalf("got %d items before the delete, want 2", got)
	}

	h.delete("/api/posts/"+itoa(mine.ID), me.Token).expect(http.StatusNoContent)

	if page := h.activity(me); len(page.Items) != 0 {
		t.Errorf("got %+v, want nothing left once the post is gone", page.Items)
	}
}

// The unread count is what lights the bell, and the seen marker is what puts it out.
func TestActivityUnreadCountAndSeenMarker(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")
	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})

	// A member who has just signed up starts caught up rather than being handed a badge for
	// history they were present for.
	if n := h.activity(me).UnreadCount; n != 0 {
		t.Errorf("unreadCount = %d on a fresh account, want 0", n)
	}

	h.comment(other, mine.ID, "looks great")
	h.like(other, mine.ID)
	if n := h.activity(me).UnreadCount; n != 2 {
		t.Errorf("unreadCount = %d, want 2", n)
	}

	h.post("/api/me/activity/seen", me.Token, nil).expect(http.StatusNoContent)
	page := h.activity(me)
	if page.UnreadCount != 0 {
		t.Errorf("unreadCount = %d after marking seen, want 0", page.UnreadCount)
	}
	// Seen clears the badge; it does not clear the list.
	if len(page.Items) != 2 {
		t.Errorf("got %d items after marking seen, want the history to remain", len(page.Items))
	}

	// And something new after the marker counts again.
	h.comment(other, mine.ID, "and another")
	if n := h.activity(me).UnreadCount; n != 1 {
		t.Errorf("unreadCount = %d for one new comment, want 1", n)
	}
}

// stampActivity forces a comment or like to an exact timestamp, so a test can build the tie
// the cursor's tiebreak exists for. Two rows landing in the same instant is rare enough that
// it will not happen by writing quickly, and consequential enough that it has to be pinned.
func stampActivity(t *testing.T, h *harness, table string, id int64, when time.Time) {
	t.Helper()
	if _, err := h.db.Pool.Exec(context.Background(),
		"UPDATE "+table+" SET created_at = $2 WHERE id = $1", id, when); err != nil {
		t.Fatalf("stamp %s %d: %v", table, id, err)
	}
}

// Two items sharing a created_at must still page cleanly. Ordering by time alone leaves
// Postgres free to put them either way round on the two sides of a page boundary, which
// drops one item and repeats the other - the same class of bug the feed's composite cursor
// already guards against.
func TestActivityPagesAcrossATimestampTie(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")
	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})

	comment := h.comment(other, mine.ID, "looks great")
	h.like(other, mine.ID)
	var likeID int64
	if err := h.db.Pool.QueryRow(context.Background(),
		`SELECT id FROM likes WHERE post_id = $1`, mine.ID).Scan(&likeID); err != nil {
		t.Fatalf("read like id: %v", err)
	}
	tie := time.Now().UTC().Truncate(time.Second)
	stampActivity(t, h, "comments", comment.ID, tie)
	stampActivity(t, h, "likes", likeID, tie)

	// One at a time, so the boundary falls exactly between the tied rows. Both rows are
	// also id 1 in their own table, which is the case that broke the first cursor design.
	seen := map[string]int{}
	cursor := ""
	for pages := 0; pages < 4; pages++ {
		var page activityPage
		h.get("/api/me/activity?limit=1"+cursor, me.Token).expect(http.StatusOK).decode(&page)
		if len(page.Items) == 0 {
			break
		}
		seen[page.Items[0].Kind]++
		if page.NextCursor == "" {
			break
		}
		cursor = "&cursor=" + url.QueryEscape(page.NextCursor)
	}
	if seen["comment"] != 1 || seen["like"] != 1 {
		t.Errorf("saw %v paging one-at-a-time across a timestamp tie, want one of each", seen)
	}
}

// Paging must not skip or repeat. The cursor is (createdAt, sourceId) precisely because a
// like and a comment can share a timestamp, and ordering by time alone would leave Postgres
// free to put them either way round on either side of the boundary.
func TestActivityPagesWithoutSkippingOrRepeating(t *testing.T) {
	h := newHarness(t)
	me := h.admin("Robin")
	other := h.member(me, "Sam")
	mine := h.createPost(me, map[string]any{"kind": "text", "body": "my trip"})

	const total = 7
	for i := 0; i < total; i++ {
		h.comment(other, mine.ID, "comment")
	}

	seen := map[int64]bool{}
	cursor := ""
	for pages := 0; pages < total; pages++ {
		var page activityPage
		h.get("/api/me/activity?limit=3"+cursor, me.Token).expect(http.StatusOK).decode(&page)
		if len(page.Items) == 0 {
			break
		}
		for _, it := range page.Items {
			if it.CommentID == nil {
				t.Fatalf("comment item with no id: %+v", it)
			}
			if seen[*it.CommentID] {
				t.Fatalf("comment %d came back on a second page", *it.CommentID)
			}
			seen[*it.CommentID] = true
		}
		if page.NextCursor == "" {
			break
		}
		cursor = "&cursor=" + url.QueryEscape(page.NextCursor)
	}
	if len(seen) != total {
		t.Errorf("paged over %d comments, want all %d", len(seen), total)
	}
}
