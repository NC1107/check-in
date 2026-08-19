package api

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"
)

// recordingNotifier captures what the handlers actually hand the push layer.
//
// The pure collapseFor tests prove the id is BUILT correctly; nothing proved it was ever
// passed. A handler that dropped it - or read the wrong field, or forgot the prefix - would
// have satisfied every other test on this branch while every notification arrived
// uncollapsed, which is precisely the bug the shared id exists to prevent.
type recordingNotifier struct {
	mu   sync.Mutex
	sent []struct {
		Title      string
		CollapseID string
	}
}

func (r *recordingNotifier) Send(_ context.Context, tokens []string, title, body string,
	_ map[string]string, collapseID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sent = append(r.sent, struct {
		Title      string
		CollapseID string
	}{Title: title, CollapseID: collapseID})
}

// collapseIDs waits briefly for the handlers' notify goroutines, then returns what was sent.
// The notify* helpers deliberately run off the request path, so a response arriving does not
// mean the push has been handed over yet.
func (r *recordingNotifier) collapseIDs(t *testing.T, want int) []string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		r.mu.Lock()
		n := len(r.sent)
		r.mu.Unlock()
		if n >= want || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.sent))
	for _, s := range r.sent {
		out = append(out, s.CollapseID)
	}
	return out
}

// A comment sent to several groups must reach the push layer carrying its shared id, or the
// copies never collapse and a member of three groups is told three times about one sentence.
func TestSharedCommentIDReachesThePushLayer(t *testing.T) {
	notifier := &recordingNotifier{}
	h := newHarnessWithNotifier(t, notifier)
	admin := h.admin("Robin")
	commenter := h.member(admin, "Sam")
	h.post("/api/me/devices", admin.Token,
		map[string]any{"token": "robin-device", "platform": "ios"}).expect(http.StatusNoContent)

	post := h.createPost(admin, map[string]any{"kind": "text", "body": "trip"})
	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), commenter.Token,
		map[string]any{"body": "everywhere", "crossCommentId": "shared-2f9c"}).
		expect(http.StatusCreated)

	ids := notifier.collapseIDs(t, 1)
	if len(ids) == 0 {
		t.Fatal("no push was sent for a comment on someone else's post")
	}
	if ids[0] != "comment:shared-2f9c" {
		t.Errorf("collapse id = %q, want comment:shared-2f9c - the handler must pass the "+
			"stored shared id through, not drop it", ids[0])
	}
}

// An ordinary single-group comment must NOT collapse. Sending a constant id here would fold
// every unrelated comment notification into one and silently destroy them.
func TestOrdinaryCommentSendsNoCollapseID(t *testing.T) {
	notifier := &recordingNotifier{}
	h := newHarnessWithNotifier(t, notifier)
	admin := h.admin("Robin")
	commenter := h.member(admin, "Sam")
	h.post("/api/me/devices", admin.Token,
		map[string]any{"token": "robin-device", "platform": "ios"}).expect(http.StatusNoContent)

	post := h.createPost(admin, map[string]any{"kind": "text", "body": "trip"})
	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), commenter.Token,
		map[string]any{"body": "just here"}).expect(http.StatusCreated)

	ids := notifier.collapseIDs(t, 1)
	if len(ids) == 0 {
		t.Fatal("no push was sent")
	}
	if ids[0] != "" {
		t.Errorf("collapse id = %q, want empty - nothing about this comment is shared", ids[0])
	}
}

// A cross-posted check-in's own notification must carry a prefixed id too. Unprefixed, a
// post's raw shared id and a comment's could be the same string, and one would replace the
// other on the device.
func TestCrossPostNotificationCarriesAPrefixedCollapseID(t *testing.T) {
	notifier := &recordingNotifier{}
	h := newHarnessWithNotifier(t, notifier)
	admin := h.admin("Robin")
	viewer := h.member(admin, "Sam")
	h.post("/api/me/devices", viewer.Token,
		map[string]any{"token": "sam-device", "platform": "ios"}).expect(http.StatusNoContent)

	h.createPost(admin, map[string]any{
		"kind": "text", "body": "shared everywhere", "crossPostId": "shared-2f9c",
	})

	ids := notifier.collapseIDs(t, 1)
	if len(ids) == 0 {
		t.Fatal("no push was sent for a new check-in")
	}
	if ids[0] != "post:shared-2f9c" {
		t.Errorf("collapse id = %q, want post:shared-2f9c", ids[0])
	}
}
