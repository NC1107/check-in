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
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

const fcmScope = "https://www.googleapis.com/auth/firebase.messaging"

// Sender posts notifications to FCM. A nil *Sender is a no-op, so the server runs fine
// when push isn't configured.
type Sender struct {
	tokens    oauth2.TokenSource
	projectID string
	http      *http.Client
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
	}, nil
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
	url := fmt.Sprintf("https://fcm.googleapis.com/v1/projects/%s/messages:send", s.projectID)
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
			msg, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
			log.Printf("push: FCM %d: %s", resp.StatusCode, msg)
		}
		resp.Body.Close()
	}
}
