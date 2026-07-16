package push

import (
	"bytes"
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
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
	s.Send(context.Background(), []string{"tok-a", "tok-b", "tok-c"}, "Alice checked in", "", nil)

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
	s.Send(context.Background(), []string{"tok"}, "Alice checked in", "at the climbing gym", nil)

	for _, secret := range []string{"Alice", "climbing gym"} {
		if strings.Contains(logs.String(), secret) {
			t.Errorf("log leaked message content %q:\n%s", secret, logs.String())
		}
	}
}

func TestSendIsANoOpWhenDisabled(t *testing.T) {
	var s *Sender
	s.Send(context.Background(), []string{"tok"}, "title", "body", nil)
	if s.ProjectID() != "" {
		t.Error("a nil Sender should report no project")
	}
}
