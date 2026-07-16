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
	"time"
)

// relaySendBatch caps how many tokens go in one request to the relay. It stays well under
// the relay's own per-request limit and keeps a single round-trip short enough to finish
// inside the caller's context timeout even when FCM is slow.
const relaySendBatch = 100

// RelaySender forwards notifications to the maintainer's push relay instead of talking to
// FCM directly. A self-hosted server uses this when it has no Firebase credentials of its
// own: the relay holds the one credential the published apps were built against, so this is
// the only way those apps receive push. It satisfies Notifier.
type RelaySender struct {
	url  string // relay base URL, no trailing slash
	key  string // this server's registration key
	http *http.Client
}

// NewRelaySender builds a RelaySender for a relay base URL and the key this server was
// issued at registration.
func NewRelaySender(relayURL, key string) *RelaySender {
	return &RelaySender{
		url:  strings.TrimRight(relayURL, "/"),
		key:  key,
		http: &http.Client{Timeout: 60 * time.Second},
	}
}

type relayMessage struct {
	Token string            `json:"token"`
	Title string            `json:"title"`
	Body  string            `json:"body"`
	Data  map[string]string `json:"data,omitempty"`
}

type relaySendReq struct {
	Messages []relayMessage `json:"messages"`
}

type relayResult struct {
	Token  string `json:"token"`
	Status string `json:"status"`
}

type relaySendResp struct {
	Results []relayResult `json:"results"`
}

// Send forwards a notification for every token to the relay in batches. It is best-effort:
// failures are logged, never fatal, and never include the token or the message content.
func (r *RelaySender) Send(ctx context.Context, tokens []string, title, body string, data map[string]string) {
	if r == nil || len(tokens) == 0 {
		return
	}
	for start := 0; start < len(tokens); start += relaySendBatch {
		end := start + relaySendBatch
		if end > len(tokens) {
			end = len(tokens)
		}
		r.sendBatch(ctx, tokens[start:end], title, body, data)
	}
}

func (r *RelaySender) sendBatch(ctx context.Context, tokens []string, title, body string, data map[string]string) {
	msgs := make([]relayMessage, len(tokens))
	for i, t := range tokens {
		msgs[i] = relayMessage{Token: t, Title: title, Body: body, Data: data}
	}
	payload, err := json.Marshal(relaySendReq{Messages: msgs})
	if err != nil {
		return
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.url+"/v1/send", bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "Bearer "+r.key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := r.http.Do(req)
	if err != nil {
		log.Printf("push: relay send: %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		log.Printf("push: relay send: HTTP %d", resp.StatusCode)
		return
	}
	// Read the per-token results only to log a delivery tally; the counts are useful and
	// carry no message content. Token pruning off these results is a future refinement.
	var out relaySendResp
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return
	}
	var delivered, unregistered, failed int
	for _, res := range out.Results {
		switch res.Status {
		case "delivered":
			delivered++
		case "unregistered":
			unregistered++
		default:
			failed++
		}
	}
	log.Printf("push: relay sent n=%d delivered=%d unregistered=%d error=%d",
		len(msgs), delivered, unregistered, failed)
}

// RegisterWithRelay claims a scoped send key from the relay. A server calls this once, on
// its first boot in relay mode, then stores and reuses the returned key. publicURL is this
// server's own base URL, which the relay uses to verify it is a real Check-In server; it may
// be empty, in which case the relay issues a lower-tier key.
func RegisterWithRelay(ctx context.Context, relayURL, publicURL string) (string, error) {
	payload, err := json.Marshal(map[string]string{"publicUrl": publicURL})
	if err != nil {
		return "", err
	}
	url := strings.TrimRight(relayURL, "/") + "/v1/register"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("relay register: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var out struct {
		Key string `json:"key"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<10)).Decode(&out); err != nil {
		return "", fmt.Errorf("relay register: decode response: %w", err)
	}
	if out.Key == "" {
		return "", fmt.Errorf("relay register: empty key in response")
	}
	return out.Key, nil
}
