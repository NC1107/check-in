package push

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/oauth2"
)

func TestFCMErrorCode(t *testing.T) {
	tests := []struct {
		name string
		body string
		want string
	}{
		{
			name: "sender id mismatch",
			body: `{"error":{"code":403,"status":"PERMISSION_DENIED","details":[
				{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"SENDER_ID_MISMATCH"}]}}`,
			want: "SENDER_ID_MISMATCH",
		},
		{
			name: "unregistered token",
			body: `{"error":{"code":404,"status":"NOT_FOUND","details":[
				{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"UNREGISTERED"}]}}`,
			want: "UNREGISTERED",
		},
		{
			name: "falls back to the generic status when there is no detail code",
			body: `{"error":{"code":401,"status":"UNAUTHENTICATED"}}`,
			want: "UNAUTHENTICATED",
		},
		{"not json", `<html>502 Bad Gateway</html>`, ""},
		{"empty", ``, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := fcmErrorCode([]byte(tt.body)); got != tt.want {
				t.Errorf("fcmErrorCode() = %q, want %q", got, tt.want)
			}
		})
	}
}

// testSender points a Sender at a fake FCM so Send can be exercised without credentials.
func testSender(endpoint string) *Sender {
	return &Sender{
		tokens:    oauth2.StaticTokenSource(&oauth2.Token{AccessToken: "test"}),
		projectID: "someone-elses-project",
		http:      &http.Client{Timeout: 5 * time.Second},
		endpoint:  endpoint,
	}
}

// captureLog redirects the standard logger for the duration of a test.
func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	flags := log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(os.Stderr) // restore the real writer; nil would panic any later log call
		log.SetFlags(flags)
	})
	return &buf
}

// The failure a third-party host actually hits: their own service account cannot deliver to
// tokens the published app minted against the maintainer's Firebase project. The symptom is
// otherwise invisible, so Send must say so in plain language rather than dumping a status.
func TestSendExplainsSenderIDMismatch(t *testing.T) {
	fcm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":403,"status":"PERMISSION_DENIED","details":[
			{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"SENDER_ID_MISMATCH"}]}}`))
	}))
	defer fcm.Close()

	logs := captureLog(t)
	s := testSender(fcm.URL)
	s.Send(context.Background(), []string{"tok-a", "tok-b", "tok-c"}, "Alice checked in", "", nil, "")

	out := logs.String()
	if !strings.Contains(out, "SENDER_ID_MISMATCH") {
		t.Errorf("expected the FCM error code in the log, got:\n%s", out)
	}
	if n := strings.Count(out, "maintainer's Firebase project"); n != 1 {
		t.Errorf("expected the explanation exactly once across 3 rejected tokens, got %d:\n%s", n, out)
	}
}

// A notification's title and body must never reach the logs, whatever FCM answers.
func TestSendNeverLogsMessageContent(t *testing.T) {
	fcm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"code":500,"status":"INTERNAL"}}`))
	}))
	defer fcm.Close()

	logs := captureLog(t)
	s := testSender(fcm.URL)
	s.Send(context.Background(), []string{"tok"}, "Alice checked in", "at the climbing gym", nil, "")

	for _, secret := range []string{"Alice", "climbing gym"} {
		if strings.Contains(logs.String(), secret) {
			t.Errorf("log leaked message content %q:\n%s", secret, logs.String())
		}
	}
}

// captureMessage runs one Send against a fake FCM and returns the message object it posted.
func captureMessage(t *testing.T, collapseID string) map[string]any {
	t.Helper()
	var payload map[string]any
	fcm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Errorf("decode request: %v", err)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer fcm.Close()

	testSender(fcm.URL).Send(context.Background(), []string{"tok"}, "Alice checked in",
		"at the gym", map[string]string{"type": "post"}, collapseID)
	message, ok := payload["message"].(map[string]any)
	if !ok {
		t.Fatalf("no message object in payload: %v", payload)
	}
	return message
}

// One check-in cross-posted to three shared groups sends three notifications. Both platforms
// need the shared id for the device to show one entry instead of three.
func TestSendCollapsesACrossPostOnBothPlatforms(t *testing.T) {
	const crossPostID = "b3f1c0de-1234-4567-89ab-cdef01234567"
	message := captureMessage(t, crossPostID)

	apns, _ := message["apns"].(map[string]any)
	headers, _ := apns["headers"].(map[string]any)
	if got := headers["apns-collapse-id"]; got != crossPostID {
		t.Errorf("apns-collapse-id = %v, want the cross-post id (message %v)", got, message)
	}
	android, _ := message["android"].(map[string]any)
	notification, _ := android["notification"].(map[string]any)
	if got := notification["tag"]; got != crossPostID {
		t.Errorf("android tag = %v, want the cross-post id (message %v)", got, message)
	}
}

// Back-compat pin: an ordinary post has nothing to collapse against, and its payload must
// stay the one FCM has always received - no platform blocks that could change delivery.
func TestSendWithoutACollapseIDKeepsThePayloadUnchanged(t *testing.T) {
	message := captureMessage(t, "")

	want := map[string]any{
		"token":        "tok",
		"notification": map[string]any{"title": "Alice checked in", "body": "at the gym"},
		"data":         map[string]any{"type": "post"},
	}
	if !reflect.DeepEqual(message, want) {
		t.Errorf("payload changed:\n got %v\nwant %v", message, want)
	}
}

// APNs rejects a collapse id over 64 bytes and drops the notification with it, so an
// over-long id is trimmed rather than allowed to cost someone their push.
func TestSendTrimsAnOverlongCollapseID(t *testing.T) {
	message := captureMessage(t, strings.Repeat("x", 100))

	apns, _ := message["apns"].(map[string]any)
	headers, _ := apns["headers"].(map[string]any)
	got, _ := headers["apns-collapse-id"].(string)
	if len(got) != collapseIDMax {
		t.Errorf("collapse id is %d bytes, want it trimmed to %d", len(got), collapseIDMax)
	}
}

func TestSendIsANoOpWhenDisabled(t *testing.T) {
	var s *Sender
	s.Send(context.Background(), []string{"tok"}, "title", "body", nil, "")
	if s.ProjectID() != "" {
		t.Error("a nil Sender should report no project")
	}
}
