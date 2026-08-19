package api

// DB-backed integration harness: a real chi router, real handlers, real queries against a
// real Postgres. Everything above this line in the stack is the same code production runs;
// only the database and the media directory are throwaway.
//
// The suite skips itself unless TESTDB_URL points at a Postgres the tests may destroy, so
// `go test ./...` on a laptop with no database stays green. CI supplies one as a service
// container (.github/workflows/ci.yml).
//
// Isolation is a TRUNCATE of every table between tests rather than a transaction rolled
// back at the end: handlers reach the database through the shared pgx pool and open their
// own transactions (CreatePost, deletePost), so there is no single transaction a test could
// wrap them in. That makes the tests order-independent but NOT safe to run in parallel with
// each other - none of them call t.Parallel.

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/config"
	"github.com/nc1107/check-in/server/internal/db"
	"github.com/nc1107/check-in/server/internal/push"
	"github.com/nc1107/check-in/server/internal/storage"
)

// testDBEnv names the environment variable holding the connection string of a Postgres the
// tests may wipe. Unset means "no database here", not "failure".
const testDBEnv = "TESTDB_URL"

// Upload limits for the harness. Deliberately far below production's 10 MiB / 25 MiB so an
// over-limit upload can be tested with a payload small enough to build in memory.
const (
	testMaxImageBytes = 256 << 10
	testMaxVideoBytes = 512 << 10
)

var (
	testDBOnce sync.Once
	testDB     *db.DB
	testDBErr  error
)

// openTestDB connects once per test binary and applies the embedded migrations, exactly as
// cmd/server does on boot, so the schema under test is the one that ships.
//
// The pool is never closed. Closing it at the end of a test would race the goroutines the
// handlers fan work out to (notifyPost and friends), which outlive the request that started
// them; letting the process exit take the pool with it costs nothing and removes the race.
func openTestDB(t *testing.T) *db.DB {
	t.Helper()
	url := os.Getenv(testDBEnv)
	if url == "" {
		t.Skipf("%s is not set - skipping the DB-backed integration tests", testDBEnv)
	}
	testDBOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if testDB, testDBErr = db.Connect(ctx, url); testDBErr != nil {
			return
		}
		testDBErr = testDB.Migrate(ctx)
	})
	if testDBErr != nil {
		t.Fatalf("test database: %v", testDBErr)
	}
	return testDB
}

// resetDB returns the database to the state a freshly migrated server starts from: no rows
// anywhere, identity sequences back at 1, and a server_config nobody has signed up to yet.
//
// The table list comes from the catalog rather than a literal in this file. A migration that
// adds a table would otherwise leave its rows behind for whichever test ran next, and that
// failure surfaces nowhere near its cause.
func resetDB(t *testing.T, database *db.DB) {
	t.Helper()
	ctx := context.Background()
	rows, err := database.Pool.Query(ctx, `
		SELECT quote_ident(tablename) FROM pg_tables
		WHERE schemaname = 'public' AND tablename <> 'schema_migrations'`)
	if err != nil {
		t.Fatalf("list tables: %v", err)
	}
	var tables []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			rows.Close()
			t.Fatalf("scan table name: %v", err)
		}
		tables = append(tables, name)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatalf("list tables: %v", err)
	}
	if len(tables) == 0 {
		t.Fatal("no tables found - did the migrations run?")
	}
	// One statement with CASCADE: users and media reference each other, so no ordering of
	// separate truncates would work.
	if _, err := database.Pool.Exec(ctx,
		"TRUNCATE "+strings.Join(tables, ", ")+" RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	// server_config is a singleton row the schema seeds, and truncating it took the row with
	// it. Re-inserting by id alone restores every column to its schema default, including any
	// column a later migration adds.
	if _, err := database.Pool.Exec(ctx, `INSERT INTO server_config (id) VALUES (1)`); err != nil {
		t.Fatalf("reseed server_config: %v", err)
	}
}

// harness is one isolated server under test: an empty database, an empty media directory,
// and a real HTTP server in front of the production router.
type harness struct {
	t        *testing.T
	db       *db.DB
	store    *storage.Store
	mediaDir string
	http     *httptest.Server
	// srv is the same *Server instance the httptest server routes to, exposed so
	// package-internal tests can call unexported methods directly (e.g. the recap
	// scheduler's tick) rather than waiting on a real ticker.
	srv *Server

	// phoneSeq hands out distinct phone numbers so tests never collide on the unique index.
	phoneSeq int
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	return newHarnessWithConfig(t, nil)
}

// newHarnessWithConfig is newHarness with a chance to tweak the config before the server is
// built - for the handful of tests that need something newHarness's fixed cfg doesn't set
// (e.g. a Klipy key), without disturbing every other test's baseline config.
// newHarnessWithNotifier is newHarness with a push Notifier attached, for the tests that
// need to observe what the handlers actually hand the push layer.
func newHarnessWithNotifier(t *testing.T, n push.Notifier) *harness {
	t.Helper()
	return newHarnessWith(t, nil, n)
}

func newHarnessWithConfig(t *testing.T, mutate func(*config.Config)) *harness {
	t.Helper()
	return newHarnessWith(t, mutate, nil)
}

func newHarnessWith(t *testing.T, mutate func(*config.Config), notifier push.Notifier) *harness {
	t.Helper()
	database := openTestDB(t)
	resetDB(t, database)

	dir := t.TempDir()
	store, err := storage.New(dir)
	if err != nil {
		t.Fatalf("storage: %v", err)
	}
	cfg := config.Config{
		ServerName:         "Check-In",
		SessionTTL:         time.Hour,
		MaxUploadBytes:     testMaxImageBytes,
		MaxVideoBytes:      testMaxVideoBytes,
		DefaultCountryCode: "1",
	}
	if mutate != nil {
		mutate(&cfg)
	}
	// Usually a genuinely nil Notifier, so every notify* helper returns before touching the
	// database - most tests care about the response, and push would only add goroutines
	// racing the test's end. The tests that DO care pass one in (see newHarnessWithNotifier).
	srv := New(cfg, database, store, notifier)
	ts := httptest.NewServer(srv.Router())
	t.Cleanup(ts.Close)

	return &harness{t: t, db: database, store: store, mediaDir: dir, http: ts, srv: srv}
}

// itoa renders an id for a URL path.
func itoa(id int64) string { return strconv.FormatInt(id, 10) }

// ---- requests ----

// response is a completed call: status, headers and body, already read and closed.
type response struct {
	t      *testing.T
	Status int
	Header http.Header
	Body   []byte
}

// expect fails the test unless the status matches, quoting the body - an unexplained
// "want 201, got 400" is the slowest kind of test failure to diagnose.
func (r *response) expect(status int) *response {
	r.t.Helper()
	if r.Status != status {
		r.t.Fatalf("status = %d, want %d; body: %s", r.Status, status, r.Body)
	}
	return r
}

func (r *response) decode(v any) *response {
	r.t.Helper()
	if err := json.Unmarshal(r.Body, v); err != nil {
		r.t.Fatalf("decode %T: %v; body: %s", v, err, r.Body)
	}
	return r
}

// errorMessage is the "error" field of the API's error envelope.
func (r *response) errorMessage() string {
	var env struct {
		Error string `json:"error"`
	}
	_ = json.Unmarshal(r.Body, &env)
	return env.Error
}

// do issues one request. token, when non-empty, is sent as a bearer token; each edit runs
// against the built request, which is how a test adds a Range or Content-Type header.
func (h *harness) do(method, path, token string, body io.Reader, edits ...func(*http.Request)) *response {
	h.t.Helper()
	req, err := http.NewRequest(method, h.http.URL+path, body)
	if err != nil {
		h.t.Fatalf("build request: %v", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for _, edit := range edits {
		edit(req)
	}
	resp, err := h.http.Client().Do(req)
	if err != nil {
		h.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		h.t.Fatalf("read %s %s: %v", method, path, err)
	}
	return &response{t: h.t, Status: resp.StatusCode, Header: resp.Header, Body: raw}
}

func (h *harness) get(path, token string, edits ...func(*http.Request)) *response {
	h.t.Helper()
	return h.do(http.MethodGet, path, token, nil, edits...)
}

func (h *harness) delete(path, token string) *response {
	h.t.Helper()
	return h.do(http.MethodDelete, path, token, nil)
}

func (h *harness) post(path, token string, body any) *response {
	h.t.Helper()
	return h.send(http.MethodPost, path, token, body)
}

func (h *harness) patch(path, token string, body any) *response {
	h.t.Helper()
	return h.send(http.MethodPatch, path, token, body)
}

func (h *harness) send(method, path, token string, body any) *response {
	h.t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		h.t.Fatalf("encode body: %v", err)
	}
	return h.do(method, path, token, bytes.NewReader(raw), func(r *http.Request) {
		r.Header.Set("Content-Type", "application/json")
	})
}

// uploadFile posts a multipart body with the single "file" part every upload endpoint reads.
func (h *harness) uploadFile(path, token, filename string, data []byte) *response {
	h.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, err := mw.CreateFormFile("file", filename)
	if err != nil {
		h.t.Fatalf("multipart: %v", err)
	}
	if _, err := part.Write(data); err != nil {
		h.t.Fatalf("multipart write: %v", err)
	}
	if err := mw.Close(); err != nil {
		h.t.Fatalf("multipart close: %v", err)
	}
	return h.do(http.MethodPost, path, token, &buf, func(r *http.Request) {
		r.Header.Set("Content-Type", mw.FormDataContentType())
	})
}

// ---- actors ----

// actor is a signed-up member and the session token their device holds.
type actor struct {
	ID    int64
	Name  string
	Phone string
	Token string
}

const testPassword = "correct-horse-battery"

// nextPhone hands out a fresh number in the reserved 555-01xx range.
func (h *harness) nextPhone() string {
	h.phoneSeq++
	return fmt.Sprintf("+1555010%04d", h.phoneSeq)
}

type authResp struct {
	Token string `json:"token"`
	User  struct {
		ID      int64  `json:"id"`
		Name    string `json:"name"`
		IsAdmin bool   `json:"isAdmin"`
	} `json:"user"`
}

// signup posts a well-formed signup for a phone and returns the raw response, so a test can
// assert on the rejection paths as well as the happy one.
func (h *harness) signup(phone, name string) *response {
	h.t.Helper()
	return h.post("/api/auth/signup", "", map[string]any{
		"phone":     phone,
		"firstName": name,
		"lastName":  "Tester",
		"birthday":  "1990-04-01",
		"password":  testPassword,
	})
}

// admin signs up the very first member, who becomes the group's admin by bootstrap.
func (h *harness) admin(name string) actor {
	h.t.Helper()
	phone := h.nextPhone()
	var got authResp
	h.signup(phone, name).expect(http.StatusOK).decode(&got)
	if !got.User.IsAdmin {
		h.t.Fatal("the first member to sign up must become the admin")
	}
	return actor{ID: got.User.ID, Name: got.User.Name, Phone: phone, Token: got.Token}
}

// member invites a new phone the way a host does - through the admin's contact upload - and
// signs it up.
func (h *harness) member(admin actor, name string) actor {
	h.t.Helper()
	phone := h.nextPhone()
	h.invite(admin, phone)
	var got authResp
	h.signup(phone, name).expect(http.StatusOK).decode(&got)
	return actor{ID: got.User.ID, Name: got.User.Name, Phone: phone, Token: got.Token}
}

func (h *harness) invite(admin actor, phones ...string) {
	h.t.Helper()
	h.post("/api/admin/contacts", admin.Token,
		map[string]any{"phones": phones}).expect(http.StatusOK)
}

// ---- fixtures ----

// pngBytes encodes a solid-colour PNG of the given size. Solid rather than noise so the
// encoded file stays small enough to sit well under the harness's upload limit.
func pngBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: 0x2E, G: 0xC4, B: 0x7A, A: 0xFF})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

// uploadImage stores a photo and returns the media the server recorded for it.
func (h *harness) uploadImage(token string) db.Media {
	h.t.Helper()
	var media db.Media
	h.uploadFile("/api/media", token, "photo.png", pngBytes(h.t, 640, 480)).
		expect(http.StatusCreated).decode(&media)
	return media
}

// gifBytes encodes a tiny single-frame animated GIF, small and simple enough to sit well
// under the harness's upload limit while still round-tripping through the server's gif
// pipeline (which stores animations as-is rather than re-encoding them).
func gifBytes(t *testing.T) []byte {
	t.Helper()
	img := image.NewPaletted(image.Rect(0, 0, 4, 4), color.Palette{color.Black, color.White})
	var buf bytes.Buffer
	if err := gif.EncodeAll(&buf, &gif.GIF{Image: []*image.Paletted{img}, Delay: []int{0}}); err != nil {
		t.Fatalf("encode gif: %v", err)
	}
	return buf.Bytes()
}

// uploadGif stores a small animated gif and returns the media the server recorded for it -
// what a re-hosted Klipy pick looks like once the client has downloaded and uploaded it.
func (h *harness) uploadGif(token string) db.Media {
	h.t.Helper()
	var media db.Media
	h.uploadFile("/api/media", token, "pick.gif", gifBytes(h.t)).
		expect(http.StatusCreated).decode(&media)
	return media
}

// uploadClip stores a video of the given length and returns the media the server recorded.
func (h *harness) uploadClip(token string, durationMs int) db.Media {
	h.t.Helper()
	var media db.Media
	h.uploadFile("/api/media", token, "clip.mp4", testClip(durationMs)).
		expect(http.StatusCreated).decode(&media)
	return media
}

// createPost posts a check-in and returns what the server said it created.
func (h *harness) createPost(a actor, body map[string]any) db.Post {
	h.t.Helper()
	var post db.Post
	h.post("/api/posts", a.Token, body).expect(http.StatusCreated).decode(&post)
	return post
}

// feed reads a member's timeline.
func (h *harness) feed(a actor) []db.Post {
	h.t.Helper()
	var page struct {
		Posts []db.Post `json:"posts"`
	}
	h.get("/api/feed", a.Token).expect(http.StatusOK).decode(&page)
	return page.Posts
}

// like has [actor] like a post, failing the test unless the server accepts it.
func (h *harness) like(a actor, postID int64) {
	h.t.Helper()
	h.post("/api/posts/"+itoa(postID)+"/like", a.Token, nil).expect(http.StatusNoContent)
}

// mediaPaths reads the stored file paths of a media row straight from the database, so a
// test can check what the delete path actually left on disk.
func (h *harness) mediaPaths(id int64) (path, poster string) {
	h.t.Helper()
	err := h.db.Pool.QueryRow(context.Background(),
		`SELECT path, poster_path FROM media WHERE id = $1`, id).Scan(&path, &poster)
	if err != nil {
		h.t.Fatalf("read media %d: %v", id, err)
	}
	return path, poster
}

// fileExists reports whether a stored media file is still on disk.
func (h *harness) fileExists(relPath string) bool {
	h.t.Helper()
	f, err := h.store.Open(relPath)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

// ---- MP4 fixture ----
//
// A minimal but structurally valid clip: the server's probe reads box headers only and never
// decodes a frame, so a handful of correctly sized boxes is a complete video as far as the
// upload path is concerned. The same shape is built in the storage package's own tests; it
// is repeated here because those builders are test-only and unexported.

func testClip(durationMs int) []byte {
	return bytes.Join([][]byte{
		mp4Box("ftyp", []byte("isom"), be32(512), []byte("isom")),
		mp4Box("moov",
			mvhd(uint32(durationMs)),
			mp4Box("trak",
				tkhd(1920, 1080),
				mp4Box("mdia",
					mdhd(1000, 0),
					mp4Box("minf", mp4Box("stbl", mp4Box("stts", be32(0), be32(1), be32(0), be32(0)))),
				),
			),
		),
		mp4Box("mdat", make([]byte, 64)),
	}, nil)
}

func mp4Box(typ string, payload ...[]byte) []byte {
	body := bytes.Join(payload, nil)
	out := binary.BigEndian.AppendUint32(nil, uint32(8+len(body)))
	out = append(out, typ...)
	return append(out, body...)
}

func be32(v uint32) []byte { return binary.BigEndian.AppendUint32(nil, v) }

// mvhd is a version-0 movie header on a 1-unit-per-millisecond timescale, so its duration
// field reads directly in milliseconds.
func mvhd(durationMs uint32) []byte {
	return mp4Box("mvhd",
		be32(0),          // version 0 + flags
		be32(0), be32(0), // creation, modification
		be32(1000),        // timescale: 1 unit == 1ms
		be32(durationMs),  // duration
		be32(0x00010000),  // rate
		[]byte{1, 0},      // volume
		make([]byte, 2+8), // reserved
		identityMatrix(),
		make([]byte, 24), // pre_defined
		be32(2),          // next track id
	)
}

func tkhd(width, height uint32) []byte {
	return mp4Box("tkhd",
		be32(0),          // version 0 + flags
		be32(0), be32(0), // creation, modification
		be32(1),         // track id
		be32(0),         // reserved
		be32(0),         // duration
		make([]byte, 8), // reserved
		make([]byte, 8), // layer, alternate group, volume, reserved
		identityMatrix(),
		be32(width<<16), be32(height<<16), // 16.16 fixed point
	)
}

func mdhd(timescale, duration uint32) []byte {
	return mp4Box("mdhd",
		be32(0),          // version 0 + flags
		be32(0), be32(0), // creation, modification
		be32(timescale),
		be32(duration),
		be32(0), // language + pre_defined
	)
}

func identityMatrix() []byte {
	return bytes.Join([][]byte{
		be32(0x00010000), be32(0), be32(0),
		be32(0), be32(0x00010000), be32(0),
		be32(0), be32(0), be32(0x40000000),
	}, nil)
}
