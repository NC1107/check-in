package api

// What a notification's data payload says is what decides where a tap lands. Nothing tested
// it: every push test on this branch checked the collapse id, and the app's own routing had
// no coverage at all, which is how "tapping a reply doesn't take me to the reply" survived.
//
// The payload's job is to name three things - which server, which post, and (for a comment
// or a reply) which comment - precisely enough that the app can open exactly that thing.

import (
	"net/http"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/config"
)

// deeplinkHarness builds a server that advertises a public URL and has the recipient's
// device registered, which is the shape every routing question below is asked in.
func deeplinkHarness(t *testing.T) (*harness, *recordingNotifier, actor) {
	t.Helper()
	notifier := &recordingNotifier{}
	h := newHarnessOn(t, openTestDB(t), func(c *config.Config) {
		c.PublicURL = "https://checkin.example.com"
	}, notifier)
	recipient := h.admin("Robin")
	h.post("/api/me/devices", recipient.Token,
		map[string]any{"token": "robin-device", "platform": "ios"}).expect(http.StatusNoContent)
	return h, notifier, recipient
}

// onlyPush waits for exactly one notification and returns it, so a test that means "this
// action notifies once" fails loudly rather than silently reading the wrong entry.
func onlyPush(t *testing.T, n *recordingNotifier) sentPush {
	t.Helper()
	sent := n.await(t, 1)
	if len(sent) != 1 {
		t.Fatalf("got %d notifications, want exactly 1: %+v", len(sent), sent)
	}
	return sent[0]
}

// pushOfType returns the single notification of the given type, for a test whose setup also
// produces unrelated ones - a member posting a check-in notifies the group before the
// comment under test ever happens, and indexing into the list would silently read that.
func pushOfType(t *testing.T, n *recordingNotifier, kind string) sentPush {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		var found []sentPush
		for _, s := range n.await(t, 0) {
			if s.Data["type"] == kind {
				found = append(found, s)
			}
		}
		if len(found) == 1 {
			return found[0]
		}
		if len(found) > 1 {
			t.Fatalf("got %d %q notifications, want exactly 1: %+v", len(found), kind, found)
		}
		if time.Now().After(deadline) {
			t.Fatalf("no %q notification was sent", kind)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// A comment on my check-in must name the comment, or the app can only scroll the thread
// into view - which on a thread long enough to scroll is what "it didn't take me to the
// comment" actually looks like.
func TestCommentPushNamesTheComment(t *testing.T) {
	h, notifier, recipient := deeplinkHarness(t)
	commenter := h.member(recipient, "Sam")
	post := h.createPost(recipient, map[string]any{"kind": "text", "body": "trip"})

	comment := h.comment(commenter, post.ID, "looks great")

	got := onlyPush(t, notifier).Data
	if got["type"] != "comment" {
		t.Errorf("type = %q, want comment", got["type"])
	}
	if got["postId"] != itoa(post.ID) {
		t.Errorf("postId = %q, want %d", got["postId"], post.ID)
	}
	if got["commentId"] != itoa(comment.ID) {
		t.Errorf("commentId = %q, want %d - without it the tap lands on the top of the "+
			"thread instead of the comment", got["commentId"], comment.ID)
	}
	if got["server"] != "https://checkin.example.com" {
		t.Errorf("server = %q, want the public URL - a multi-group app needs it to pick "+
			"the right group, since post ids collide across servers", got["server"])
	}
}

// A reply must name the REPLY, not the parent it answers. Naming the parent would scroll to
// the comment the member already wrote and knows about, rather than the new thing they are
// being told about - a bug that looks like working code from the outside.
func TestReplyPushNamesTheReplyNotTheParent(t *testing.T) {
	h, notifier, recipient := deeplinkHarness(t)
	author := h.member(recipient, "Ada")
	replier := h.member(recipient, "Sam")

	// The post belongs to a third member, so the recipient is notified as the parent
	// comment's author only - the same p.author_id <> recipient split the server makes.
	post := h.createPost(author, map[string]any{"kind": "text", "body": "trip"})
	parent := h.comment(recipient, post.ID, "where was this?")
	reply := h.reply(replier, post.ID, parent.ID, "Lisbon")

	got := pushOfType(t, notifier, "reply").Data
	if got["commentId"] == itoa(parent.ID) {
		t.Fatal("the push named the parent comment; a tap would scroll to the member's own " +
			"comment rather than the reply they were notified about")
	}
	if got["commentId"] != itoa(reply.ID) {
		t.Errorf("commentId = %q, want the reply %d", got["commentId"], reply.ID)
	}
}

// A like and a new check-in are about the post itself, so they carry no comment id. An id
// here would send the tap to some unrelated comment.
func TestPostAndLikePushesCarryNoCommentID(t *testing.T) {
	h, notifier, recipient := deeplinkHarness(t)
	other := h.member(recipient, "Sam")
	post := h.createPost(recipient, map[string]any{"kind": "text", "body": "trip"})

	h.like(other, post.ID)
	like := onlyPush(t, notifier).Data
	if like["type"] != "like" {
		t.Errorf("type = %q, want like", like["type"])
	}
	if _, ok := like["commentId"]; ok {
		t.Errorf("a like carried commentId = %q; a like is about the post", like["commentId"])
	}
	if like["postId"] != itoa(post.ID) {
		t.Errorf("postId = %q, want %d", like["postId"], post.ID)
	}

	// And a new check-in from someone else, which reaches the recipient as "shared a
	// check-in" rather than as anything comment-shaped.
	theirs := h.createPost(other, map[string]any{"kind": "text", "body": "mine"})
	sent := notifier.await(t, 2)
	newPost := sent[len(sent)-1].Data
	if newPost["type"] != "post" {
		t.Fatalf("type = %q, want post", newPost["type"])
	}
	if _, ok := newPost["commentId"]; ok {
		t.Errorf("a new check-in carried commentId = %q", newPost["commentId"])
	}
	if newPost["postId"] != itoa(theirs.ID) {
		t.Errorf("postId = %q, want %d", newPost["postId"], theirs.ID)
	}
}

// A comment that is also a reply fires two notifications, and each must point at the same
// new comment under its own type - the pair the app tells apart to word the row and to pick
// where in the thread to land.
func TestCommentThatIsAlsoAReplyNamesOneCommentTwice(t *testing.T) {
	h, notifier, recipient := deeplinkHarness(t)
	other := h.member(recipient, "Sam")

	// The recipient owns the post AND the parent comment, so both notifications are theirs.
	// Only one device is registered, so two pushes means two entries here.
	post := h.createPost(recipient, map[string]any{"kind": "text", "body": "trip"})
	parent := h.comment(recipient, post.ID, "day one")
	reply := h.reply(other, post.ID, parent.ID, "nice")

	// notifyCommentReply deliberately skips the post's author (see TokensForCommentReply),
	// so owning both means exactly one push, as "commented on your check-in".
	got := onlyPush(t, notifier).Data
	if got["type"] != "comment" {
		t.Errorf("type = %q, want comment - a reply on your own post is not double-buzzed",
			got["type"])
	}
	if got["commentId"] != itoa(reply.ID) {
		t.Errorf("commentId = %q, want the new comment %d", got["commentId"], reply.ID)
	}
}

// A server with no public URL configured cannot say which group it is. The payload must
// simply omit the key rather than inventing one, because the app treats an unmatched server
// as "do not guess" - see the routing helper on the client.
func TestPushOmitsServerWhenNoPublicURL(t *testing.T) {
	notifier := &recordingNotifier{}
	h := newHarnessWithNotifier(t, notifier)
	recipient := h.admin("Robin")
	h.post("/api/me/devices", recipient.Token,
		map[string]any{"token": "robin-device", "platform": "ios"}).expect(http.StatusNoContent)
	other := h.member(recipient, "Sam")
	post := h.createPost(recipient, map[string]any{"kind": "text", "body": "trip"})

	h.comment(other, post.ID, "hi")

	if v, ok := onlyPush(t, notifier).Data["server"]; ok {
		t.Errorf("server = %q, want the key absent when no public URL is configured", v)
	}
}
