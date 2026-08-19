package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/push"
)

// The whole push chain, from a real comment to the bytes that leave this server.
//
// Two halves of this were already covered and the join between them was not: push_wiring_test
// checks what the handlers hand a Notifier, and internal/push's own tests check what a
// RelaySender puts on the wire - but nothing ran a real request through a real RelaySender
// and looked at the resulting HTTP body. A shared id that survives the handler and is then
// dropped, renamed or mis-nested on its way out would satisfy both halves and still leave
// every member notified once per group.
//
// The relay here is a local stand-in, not the maintainer's. That keeps the test hermetic and
// keeps CI from sending real notifications to real phones; what it verifies is OUR side of
// the contract - the URL, the auth header, and the exact JSON.
type fakeRelay struct {
	*httptest.Server
	mu       sync.Mutex
	requests []struct {
		Path string
		Auth string
		Body map[string]any
	}
}

func newFakeRelay(t *testing.T) *fakeRelay {
	t.Helper()
	f := &fakeRelay{}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.requests = append(f.requests, struct {
			Path string
			Auth string
			Body map[string]any
		}{Path: r.URL.Path, Auth: r.Header.Get("Authorization"), Body: body})
		f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"results":[{"token":"t","status":"delivered"}]}`))
	}))
	t.Cleanup(f.Server.Close)
	return f
}

// waitForMessages waits for the handlers' notify goroutines, which run off the request path.
func (f *fakeRelay) waitForMessages(t *testing.T, want int) []map[string]any {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		f.mu.Lock()
		n := len(f.requests)
		f.mu.Unlock()
		if n >= want || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	var msgs []map[string]any
	for _, req := range f.requests {
		if req.Path != "/v1/send" {
			t.Errorf("relay path = %q, want /v1/send", req.Path)
		}
		if req.Auth != "Bearer test-relay-key" {
			t.Errorf("auth header = %q, want the server's registration key", req.Auth)
		}
		for _, m := range req.Body["messages"].([]any) {
			msgs = append(msgs, m.(map[string]any))
		}
	}
	return msgs
}

func TestCommentReachesTheRelayWithItsCollapseID(t *testing.T) {
	relay := newFakeRelay(t)
	h := newHarnessWithNotifier(t, push.NewRelaySender(relay.URL, "test-relay-key"))
	admin := h.admin("Robin")
	commenter := h.member(admin, "Sam")
	h.post("/api/me/devices", admin.Token,
		map[string]any{"token": "robin-device", "platform": "ios"}).expect(http.StatusNoContent)

	post := h.createPost(admin, map[string]any{"kind": "text", "body": "trip"})
	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), commenter.Token,
		map[string]any{"body": "said everywhere", "crossCommentId": "shared-2f9c"}).
		expect(http.StatusCreated)

	msgs := relay.waitForMessages(t, 1)
	if len(msgs) != 1 {
		t.Fatalf("relay received %d messages, want 1", len(msgs))
	}
	if got := msgs[0]["collapseId"]; got != "comment:shared-2f9c" {
		t.Errorf("collapseId on the wire = %v, want comment:shared-2f9c", got)
	}
	// The privacy claim the boot log makes, checked against the actual bytes rather than
	// against the code that builds them.
	if got := msgs[0]["title"]; got != "Check-In" {
		t.Errorf("title = %v, want the server name", got)
	}
	if body, _ := msgs[0]["body"].(string); !strings.HasSuffix(body, " commented on your check-in") {
		t.Errorf("body = %q, want the fixed 'X commented on your check-in' template", body)
	}
	for _, field := range msgs[0] {
		if s, ok := field.(string); ok && s == "said everywhere" {
			t.Error("the comment's own text reached the relay - it must never leave this server")
		}
	}
}

func TestOrdinaryCommentReachesTheRelayWithNoCollapseID(t *testing.T) {
	relay := newFakeRelay(t)
	h := newHarnessWithNotifier(t, push.NewRelaySender(relay.URL, "test-relay-key"))
	admin := h.admin("Robin")
	commenter := h.member(admin, "Sam")
	h.post("/api/me/devices", admin.Token,
		map[string]any{"token": "robin-device", "platform": "ios"}).expect(http.StatusNoContent)

	post := h.createPost(admin, map[string]any{"kind": "text", "body": "trip"})
	h.post(fmt.Sprintf("/api/posts/%d/comments", post.ID), commenter.Token,
		map[string]any{"body": "just here"}).expect(http.StatusCreated)

	msgs := relay.waitForMessages(t, 1)
	if len(msgs) != 1 {
		t.Fatalf("relay received %d messages, want 1", len(msgs))
	}
	// Omitted entirely rather than sent empty: the relay rejects unknown fields, and an
	// empty one would also collapse every unrelated notification together.
	if _, present := msgs[0]["collapseId"]; present {
		t.Errorf("collapseId was sent for a comment that is not shared: %v", msgs[0]["collapseId"])
	}
}
