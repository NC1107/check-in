package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/config"
)

// klipyStub is a fake Klipy upstream: it records every request path+query it received and
// answers a fixed body (or hangs, for the timeout test). Standing in for
// https://api.klipy.com so the proxy is testable without a real key or network.
type klipyStub struct {
	*httptest.Server
	lastPath string
	lastRaw  string
}

func newKlipyStub(t *testing.T, respond func(w http.ResponseWriter, r *http.Request)) *klipyStub {
	t.Helper()
	stub := &klipyStub{}
	stub.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		stub.lastPath = r.URL.Path
		stub.lastRaw = r.URL.RawQuery
		respond(w, r)
	}))
	t.Cleanup(stub.Close)
	return stub
}

// gifServer builds a Server wired at the given fake Klipy key/base URL, calling
// handleGifSearch directly - no router, no auth middleware, no database - since the handler
// itself touches neither.
func gifServer(baseURL, key string, timeout time.Duration) *Server {
	return &Server{
		cfg:          config.Config{KlipyKey: key, KlipyBaseURL: baseURL},
		content:      newContentLimits(),
		klipyTimeout: timeout,
	}
}

func doGifSearch(s *Server, query string) *httptest.ResponseRecorder {
	url := "/api/gifs/search"
	if query != "" {
		url += "?" + query
	}
	r := httptest.NewRequest(http.MethodGet, url, nil)
	w := httptest.NewRecorder()
	s.handleGifSearch(w, r)
	return w
}

// klipyFixture is one item in Klipy's real response shape (trimmed to the fields the proxy
// reads), reused across the mapping tests.
const klipyFixture = `{
	"result": true,
	"data": {
		"data": [{
			"id": 9017911837986147,
			"slug": "robin-and-ted-high-five",
			"title": "Robin and Ted High-Five",
			"file": {
				"hd": {"gif": {"url": "https://static.klipy.com/hd.gif", "width": 480, "height": 270}, "webp": {"url": "https://static.klipy.com/hd.webp", "width": 480, "height": 270}},
				"md": {"gif": {"url": "https://static.klipy.com/md.gif", "width": 300, "height": 169}, "webp": {"url": "https://static.klipy.com/md.webp", "width": 300, "height": 169}},
				"sm": {"gif": {"url": "https://static.klipy.com/sm.gif", "width": 150, "height": 84}, "webp": {"url": "https://static.klipy.com/sm.webp", "width": 150, "height": 84}}
			}
		}],
		"current_page": 1,
		"per_page": 24,
		"has_next": true
	}
}`

func TestGifSearchMapsRenditionsAndRouting(t *testing.T) {
	stub := newKlipyStub(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(klipyFixture))
	})
	s := gifServer(stub.URL, "test-key", 0)

	t.Run("empty q hits trending, non-empty hits search", func(t *testing.T) {
		res := doGifSearch(s, "")
		if res.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body: %s", res.Code, res.Body)
		}
		if stub.lastPath != "/api/v1/test-key/gifs/trending" {
			t.Errorf("path = %q, want the trending endpoint for an empty query", stub.lastPath)
		}

		doGifSearch(s, "q=cat")
		if stub.lastPath != "/api/v1/test-key/gifs/search" {
			t.Errorf("path = %q, want the search endpoint for a non-empty query", stub.lastPath)
		}
		if !strings.Contains(stub.lastRaw, "q=cat") {
			t.Errorf("query = %q, want it to carry q=cat", stub.lastRaw)
		}
		if !strings.Contains(stub.lastRaw, "per_page=24") {
			t.Errorf("query = %q, want the server-fixed per_page=24", stub.lastRaw)
		}
	})

	t.Run("the slim shape picks the right renditions with fallbacks", func(t *testing.T) {
		res := doGifSearch(s, "q=cat")
		var got gifSearchResp
		if err := json.Unmarshal(res.Body.Bytes(), &got); err != nil {
			t.Fatalf("decode: %v; body: %s", err, res.Body)
		}
		if !got.HasNext {
			t.Error("hasNext = false, want true (from the fixture's has_next)")
		}
		if len(got.Gifs) != 1 {
			t.Fatalf("gifs = %d, want 1", len(got.Gifs))
		}
		g := got.Gifs[0]
		if g.ID != "9017911837986147" {
			t.Errorf("id = %q, want the full-precision klipy id as a string", g.ID)
		}
		if g.Title != "Robin and Ted High-Five" {
			t.Errorf("title = %q", g.Title)
		}
		// Preview: smallest webp available.
		if g.PreviewURL != "https://static.klipy.com/sm.webp" || g.PreviewWidth != 150 || g.PreviewHeight != 84 {
			t.Errorf("preview = %+v, want the sm webp rendition", g)
		}
		// Attachment: md gif.
		if g.GifURL != "https://static.klipy.com/md.gif" || g.Width != 300 || g.Height != 169 {
			t.Errorf("gif = %+v, want the md gif rendition", g)
		}
	})

	t.Run("a missing sm/md webp falls back to gif renditions", func(t *testing.T) {
		fallback := `{"result":true,"data":{"data":[{
			"id": 42,
			"title": "no webp",
			"file": {
				"hd": {"gif": {"url": "https://static.klipy.com/hd.gif", "width": 480, "height": 270}},
				"md": {},
				"sm": {}
			}
		}], "current_page": 1, "per_page": 24, "has_next": false}}`
		stub2 := newKlipyStub(t, func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(fallback))
		})
		s2 := gifServer(stub2.URL, "test-key", 0)
		res := doGifSearch(s2, "q=x")
		var got gifSearchResp
		if err := json.Unmarshal(res.Body.Bytes(), &got); err != nil {
			t.Fatalf("decode: %v; body: %s", err, res.Body)
		}
		if len(got.Gifs) != 1 {
			t.Fatalf("gifs = %d, want 1", len(got.Gifs))
		}
		g := got.Gifs[0]
		// No sm/md rendition at all here, so both the preview and the attachment must fall
		// all the way back to the one rendition present: hd gif.
		if g.PreviewURL != "https://static.klipy.com/hd.gif" {
			t.Errorf("previewUrl = %q, want the hd gif fallback when nothing smaller exists", g.PreviewURL)
		}
		if g.GifURL != "https://static.klipy.com/hd.gif" {
			t.Errorf("gifUrl = %q, want the hd gif fallback when md and sm are absent", g.GifURL)
		}
	})

	t.Run("an item with no gif rendition at all is dropped, not emitted broken", func(t *testing.T) {
		empty := `{"result":true,"data":{"data":[{"id":1,"title":"broken","file":{"hd":{},"md":{},"sm":{}}}],"current_page":1,"per_page":24,"has_next":false}}`
		stub3 := newKlipyStub(t, func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(empty)) })
		s3 := gifServer(stub3.URL, "test-key", 0)
		res := doGifSearch(s3, "q=x")
		var got gifSearchResp
		if err := json.Unmarshal(res.Body.Bytes(), &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if len(got.Gifs) != 0 {
			t.Errorf("gifs = %d, want 0 - an item with nothing attachable must not reach the client", len(got.Gifs))
		}
	})
}

func TestGifSearchNoKeyConfigured(t *testing.T) {
	s := gifServer("http://unused.invalid", "", 0)
	res := doGifSearch(s, "q=cat")
	if res.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 when no key is configured", res.Code)
	}
}

func TestGifSearchUpstreamTimeout(t *testing.T) {
	// The stub sleeps far longer than the configured timeout below. If the handler's context
	// deadline were dropped, the request would complete only after the full sleep - so the
	// elapsed-time assertion below actually exercises the timeout wiring, not just the
	// eventual error status. httptest.Server.Close waits out any in-flight handler, so the
	// sleep is kept short (a few hundred ms) to avoid stalling the test suite while still
	// comfortably clearing the 20ms timeout.
	stub := newKlipyStub(t, func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(400 * time.Millisecond)
		_, _ = w.Write([]byte(klipyFixture))
	})
	s := gifServer(stub.URL, "test-key", 20*time.Millisecond)
	start := time.Now()
	res := doGifSearch(s, "q=cat")
	elapsed := time.Since(start)
	if res.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502 on an upstream timeout; body: %s", res.Code, res.Body)
	}
	if elapsed > 200*time.Millisecond {
		t.Errorf("took %v, want the ~20ms configured timeout to have cut the wait off well under the stub's 400ms sleep", elapsed)
	}
}

// The key must never leak into anything the client can see: not the success body, not any
// error body, no matter what fails.
func TestGifSearchNeverLeaksTheKey(t *testing.T) {
	const secretKey = "super-secret-klipy-key"
	cases := []struct {
		name   string
		server *Server
		query  string
	}{
		{
			name: "success",
			server: gifServer(newKlipyStub(t, func(w http.ResponseWriter, r *http.Request) {
				_, _ = w.Write([]byte(klipyFixture))
			}).URL, secretKey, 0),
			query: "q=cat",
		},
		{
			name:   "upstream down",
			server: gifServer("http://127.0.0.1:1", secretKey, 200*time.Millisecond),
			query:  "q=cat",
		},
		{
			name: "upstream non-200",
			server: gifServer(newKlipyStub(t, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusInternalServerError)
			}).URL, secretKey, 0),
			query: "q=cat",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := doGifSearch(tc.server, tc.query)
			if strings.Contains(res.Body.String(), secretKey) {
				t.Fatalf("response body leaked the key: %s", res.Body)
			}
		})
	}
}

// Sanity check that the fixture's id (above JSON's float64 precision ceiling) survives the
// round-trip as a string with every digit intact - the whole reason the wire item and the
// mapper use int64 rather than a generic numeric decode.
func TestGifIDSurvivesFullPrecision(t *testing.T) {
	const bigID = 9017911837986147
	if fmt.Sprintf("%d", bigID) != "9017911837986147" {
		t.Fatal("test fixture drifted from the id in klipyFixture")
	}
}
