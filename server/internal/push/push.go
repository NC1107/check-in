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
	"strings"
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

	// collapseIDMax is APNs' hard limit on the apns-collapse-id header. A longer value
	// makes APNs reject the notification outright, so an over-long id is trimmed rather
	// than sent. Cross-post ids are UUIDs and fit; this only guards a future caller.
	collapseIDMax = 64
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
	//
	// collapseID names the event the notification is about, when several notifications can
	// describe the same one: a device shows a single entry per id instead of one per
	// notification. Empty means no collapsing, which is right for anything already unique
	// per member.
	Send(ctx context.Context, tokens []string, title, body string, data map[string]string, collapseID string)
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
	// JWTConfigFromJSON, not CredentialsFromJSON: that one is deprecated precisely because it
	// accepts any credential configuration without validating it, including the
	// externally-sourced kinds whose token URL is named inside the file itself. This server
	// only ever wants a Firebase service-account key, and asking for exactly that makes
	// anything else fail to load rather than merely go unused - it rejects a file whose
	// "type" is not service_account before any of it is trusted.
	cfg, err := google.JWTConfigFromJSON(credentialsJSON, fcmScope)
	if err != nil {
		return nil, fmt.Errorf("parse FCM credentials: %w", err)
	}
	// The project id is not part of a JWT config, and FCM's endpoint is per project, so it
	// is read from the same file directly.
	var key struct {
		ProjectID string `json:"project_id"`
	}
	if err := json.Unmarshal(credentialsJSON, &key); err != nil {
		return nil, fmt.Errorf("parse FCM credentials: %w", err)
	}
	if key.ProjectID == "" {
		return nil, fmt.Errorf("FCM credentials missing project_id")
	}
	return &Sender{
		tokens:    cfg.TokenSource(ctx),
		projectID: key.ProjectID,
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

// applyCollapse threads a collapse id onto an FCM v1 message so both platforms fold repeat
// deliveries of one event into a single entry: APNs replaces a pending notification carrying
// the same apns-collapse-id, Android replaces one posted under the same tag. An empty id
// leaves the message exactly as it was before collapsing existed.
func applyCollapse(message map[string]any, collapseID string) {
	if collapseID == "" {
		return
	}
	if len(collapseID) > collapseIDMax {
		// Dropping a rune the cut split keeps the header valid UTF-8. Every copy of one
		// event trims identically, so a trimmed id still collapses them together.
		collapseID = strings.ToValidUTF8(collapseID[:collapseIDMax], "")
	}
	message["apns"] = map[string]any{"headers": map[string]string{"apns-collapse-id": collapseID}}
	message["android"] = map[string]any{"notification": map[string]string{"tag": collapseID}}
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
func (s *Sender) Send(ctx context.Context, tokens []string, title, body string, data map[string]string, collapseID string) {
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
		message := map[string]any{
			"token":        t,
			"notification": map[string]string{"title": title, "body": body},
			"data":         data,
		}
		applyCollapse(message, collapseID)
		payload, _ := json.Marshal(map[string]any{"message": message})
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
