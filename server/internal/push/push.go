// Package push sends notifications to members' devices via Firebase Cloud Messaging
// (FCM HTTP v1). FCM delivers to Android directly and to iOS through APNs (using the
// APNs key uploaded to the Firebase project), so a single channel covers both platforms.
//
// It talks to the FCM REST API directly with an OAuth2 token minted from the service
// account, avoiding the heavyweight Firebase Admin SDK.
package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

const (
	fcmScope    = "https://www.googleapis.com/auth/firebase.messaging"
	fcmEndpoint = "https://fcm.googleapis.com"

	// senderIDMismatch is FCM's verdict when a token was minted against a different
	// Firebase project than the one the credentials belong to.
	senderIDMismatch = "SENDER_ID_MISMATCH"
)

// mismatchAdvice names the one push failure a self-hoster cannot diagnose from the
// symptom. The published Check-In apps embed the maintainer's Firebase config, so devices
// mint their tokens against that project; a host's own service account can never deliver
// to them, and every send fails while the server looks correctly configured.
const mismatchAdvice = "push: FCM rejected a device token as belonging to a different Firebase " +
	"project (SENDER_ID_MISMATCH). The published Check-In apps mint device tokens against the " +
	"maintainer's Firebase project, so your own service account cannot deliver to them and no " +
	"notification will ever arrive. See docs/self-hosting/configuration.md#push-notifications " +
	"for the supported ways to get push working."

// Notifier delivers a notification to a set of device tokens. Two implementations exist:
// *Sender talks to FCM directly (a host with its own Firebase credentials), and
// *RelaySender forwards to the maintainer's relay (the default for self-hosters running the
// published apps). The server holds one as an interface so the notify* handlers and the
// digest scheduler don't care which is in use; a nil Notifier means push is off.
type Notifier interface {
	// Send delivers title/body/data to every token, best-effort. It must never block the
	// caller for long or panic, and must not log the notification content.
	Send(ctx context.Context, tokens []string, title, body string, data map[string]string)
}

// Sender posts notifications to FCM. A nil *Sender is a no-op, so the server runs fine
// when push isn't configured.
type Sender struct {
	tokens    oauth2.TokenSource
	projectID string
	http      *http.Client
	endpoint  string

	// adviseOnce keeps the mismatch explanation to a single line per process; the
	// condition repeats on every token of every send.
	adviseOnce sync.Once
}

// New builds a Sender from a Firebase service-account JSON. Returns (nil, nil) when the
// credentials are empty so callers can treat "push disabled" as a non-error.
func New(ctx context.Context, credentialsJSON []byte) (*Sender, error) {
	if len(credentialsJSON) == 0 {
		return nil, nil
	}
	creds, err := google.CredentialsFromJSON(ctx, credentialsJSON, fcmScope)
	if err != nil {
		return nil, fmt.Errorf("parse FCM credentials: %w", err)
	}
	if creds.ProjectID == "" {
		return nil, fmt.Errorf("FCM credentials missing project_id")
	}
	return &Sender{
		tokens:    creds.TokenSource,
		projectID: creds.ProjectID,
		http:      &http.Client{Timeout: 15 * time.Second},
		endpoint:  fcmEndpoint,
	}, nil
}

// ProjectID is the Firebase project these notifications are sent through. Empty when push
// is disabled, so it is safe to call on a nil Sender.
func (s *Sender) ProjectID() string {
	if s == nil {
		return ""
	}
	return s.projectID
}

// fcmErrorCode pulls FCM v1's machine-readable code out of an error response, preferring
// the specific code in details (e.g. SENDER_ID_MISMATCH, UNREGISTERED) over the generic
// status. Returns "" when the body isn't the shape we expect.
func fcmErrorCode(body []byte) string {
	var resp struct {
		Error struct {
			Status  string `json:"status"`
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return ""
	}
	for _, d := range resp.Error.Details {
		if d.ErrorCode != "" {
			return d.ErrorCode
		}
	}
	return resp.Error.Status
}

// Send delivers a notification to every token, best-effort and one request per token
// (FCM v1 has no multicast). Payloads are kept minimal so the providers only ever see a
// short title/body, never post content. Failures are logged, never fatal.
func (s *Sender) Send(ctx context.Context, tokens []string, title, body string, data map[string]string) {
	if s == nil || len(tokens) == 0 {
		return
	}
	tok, err := s.tokens.Token()
	if err != nil {
		log.Printf("push: oauth token: %v", err)
		return
	}
	url := fmt.Sprintf("%s/v1/projects/%s/messages:send", s.endpoint, s.projectID)
	for _, t := range tokens {
		payload, _ := json.Marshal(map[string]any{
			"message": map[string]any{
				"token":        t,
				"notification": map[string]string{"title": title, "body": body},
				"data":         data,
			},
		})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
		if err != nil {
			continue
		}
		req.Header.Set("Authorization", "Bearer "+tok.AccessToken)
		req.Header.Set("Content-Type", "application/json")
		resp, err := s.http.Do(req)
		if err != nil {
			log.Printf("push: send: %v", err)
			continue
		}
		if resp.StatusCode >= 300 {
			raw, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
			if code := fcmErrorCode(raw); code != "" {
				log.Printf("push: FCM %d (%s)", resp.StatusCode, code)
				if code == senderIDMismatch {
					s.adviseOnce.Do(func() { log.Print(mismatchAdvice) })
				}
			} else {
				log.Printf("push: FCM %d: %s", resp.StatusCode, raw)
			}
		}
		resp.Body.Close()
	}
}
