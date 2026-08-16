package push

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// fakeRelay records what the relay received and lets a test script the response.
type fakeRelay struct {
	sendCalls   atomic.Int32
	lastAuth    string
	lastReq     relaySendReq
	lastBody    string // raw JSON, so a test can tell an absent field from a zero one
	lastPublic  string
	registerKey string
	registerErr int // non-zero HTTP status to return from /v1/register
}

func (f *fakeRelay) server() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/send", func(w http.ResponseWriter, r *http.Request) {
		f.sendCalls.Add(1)
		f.lastAuth = r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		f.lastBody = string(raw)
		var req relaySendReq
		_ = json.Unmarshal(raw, &req)
		f.lastReq = req
		results := make([]relayResult, len(req.Messages))
		for i, m := range req.Messages {
			results[i] = relayResult{Token: m.Token, Status: "delivered"}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(relaySendResp{Results: results})
	})
	mux.HandleFunc("/v1/register", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			PublicURL string `json:"publicUrl"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.lastPublic = body.PublicURL
		if f.registerErr != 0 {
			w.WriteHeader(f.registerErr)
			_, _ = w.Write([]byte(`{"error":"nope"}`))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"key": f.registerKey})
	})
	return httptest.NewServer(mux)
}

func TestRelaySendForwardsBatch(t *testing.T) {
	f := &fakeRelay{}
	ts := f.server()
	defer ts.Close()

	rs := NewRelaySender(ts.URL, "ckr_secret")
	rs.Send(context.Background(), []string{"a", "b"}, "Alice checked in", "at the gym",
		map[string]string{"type": "post"}, "")

	if f.sendCalls.Load() != 1 {
		t.Fatalf("want 1 send call, got %d", f.sendCalls.Load())
	}
	if f.lastAuth != "Bearer ckr_secret" {
		t.Errorf("auth = %q, want Bearer ckr_secret", f.lastAuth)
	}
	if len(f.lastReq.Messages) != 2 {
		t.Fatalf("want 2 messages, got %d", len(f.lastReq.Messages))
	}
	m := f.lastReq.Messages[0]
	if m.Token != "a" || m.Title != "Alice checked in" || m.Body != "at the gym" || m.Data["type"] != "post" {
		t.Errorf("first message not forwarded intact: %+v", m)
	}
}

// A self-hoster in relay mode gets the same dedup as a direct-FCM one, so the cross-post id
// has to survive the extra hop.
func TestRelaySendForwardsCollapseID(t *testing.T) {
	f := &fakeRelay{}
	ts := f.server()
	defer ts.Close()

	NewRelaySender(ts.URL, "k").Send(context.Background(), []string{"a"}, "t", "b", nil, "xpost-42")

	if len(f.lastReq.Messages) != 1 {
		t.Fatalf("want 1 message, got %d", len(f.lastReq.Messages))
	}
	if got := f.lastReq.Messages[0].CollapseID; got != "xpost-42" {
		t.Errorf("collapse id = %q, want xpost-42", got)
	}
}

// With nothing to collapse the field is left out entirely, keeping the request identical to
// what relays accepted before collapsing existed - they reject unknown fields, so the
// wire shape is worth pinning.
func TestRelaySendOmitsAnEmptyCollapseID(t *testing.T) {
	f := &fakeRelay{}
	ts := f.server()
	defer ts.Close()

	NewRelaySender(ts.URL, "k").Send(context.Background(), []string{"a"}, "t", "b", nil, "")

	if strings.Contains(f.lastBody, "collapseId") {
		t.Errorf("request carries collapseId with nothing to collapse: %s", f.lastBody)
	}
}

func TestRelaySendChunks(t *testing.T) {
	f := &fakeRelay{}
	ts := f.server()
	defer ts.Close()

	tokens := make([]string, 250) // 100 + 100 + 50 across three requests
	for i := range tokens {
		tokens[i] = "t"
	}
	NewRelaySender(ts.URL, "k").Send(context.Background(), tokens, "t", "b", nil, "")

	if f.sendCalls.Load() != 3 {
		t.Errorf("250 tokens at batch 100 should be 3 requests, got %d", f.sendCalls.Load())
	}
}

func TestRelaySendNilAndEmptyAreNoOps(t *testing.T) {
	var rs *RelaySender
	rs.Send(context.Background(), []string{"a"}, "t", "b", nil, "") // nil receiver

	f := &fakeRelay{}
	ts := f.server()
	defer ts.Close()
	NewRelaySender(ts.URL, "k").Send(context.Background(), nil, "t", "b", nil, "") // no tokens
	if f.sendCalls.Load() != 0 {
		t.Errorf("a send with no tokens should not hit the relay, got %d calls", f.sendCalls.Load())
	}
}

// The relay client must never log the notification's title, body, or a device token.
func TestRelaySendNeverLogsContent(t *testing.T) {
	f := &fakeRelay{}
	ts := f.server()
	defer ts.Close()

	var buf bytes.Buffer
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	NewRelaySender(ts.URL, "k").Send(context.Background(),
		[]string{"secret-token"}, "Alice checked in", "at the climbing gym", nil, "")

	for _, secret := range []string{"secret-token", "Alice", "climbing gym"} {
		if strings.Contains(buf.String(), secret) {
			t.Errorf("log leaked %q:\n%s", secret, buf.String())
		}
	}
}

func TestRegisterWithRelaySuccess(t *testing.T) {
	f := &fakeRelay{registerKey: "ckr_issued"}
	ts := f.server()
	defer ts.Close()

	key, err := RegisterWithRelay(context.Background(), ts.URL, "https://alpha.example.com")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if key != "ckr_issued" {
		t.Errorf("key = %q, want ckr_issued", key)
	}
	if f.lastPublic != "https://alpha.example.com" {
		t.Errorf("relay saw publicUrl %q, want the server's own URL", f.lastPublic)
	}
}

func TestRegisterWithRelayErrorStatus(t *testing.T) {
	f := &fakeRelay{registerErr: http.StatusTooManyRequests}
	ts := f.server()
	defer ts.Close()

	if _, err := RegisterWithRelay(context.Background(), ts.URL, ""); err == nil {
		t.Fatal("want an error on a 429 from the relay, got nil")
	}
}

func TestRegisterWithRelayEmptyKey(t *testing.T) {
	f := &fakeRelay{registerKey: ""} // 200 but no key
	ts := f.server()
	defer ts.Close()

	if _, err := RegisterWithRelay(context.Background(), ts.URL, ""); err == nil {
		t.Fatal("want an error when the relay returns an empty key, got nil")
	}
}

// Guard against a regression where relaySendResp stops decoding the relay's results.
func TestRelayResultDecoding(t *testing.T) {
	var out relaySendResp
	if err := json.NewDecoder(io.NopCloser(bytes.NewReader(
		[]byte(`{"results":[{"token":"a","status":"unregistered"}]}`)))).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if len(out.Results) != 1 || out.Results[0].Status != "unregistered" {
		t.Errorf("decoded results wrong: %+v", out.Results)
	}
}
