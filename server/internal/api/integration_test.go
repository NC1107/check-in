package api

// End-to-end HTTP tests against a real Postgres. See harness_test.go for the setup and for
// why these skip without TESTDB_URL.
//
// The flows chosen here are the ones that have broken before or that would be expensive to
// get wrong: the signup gate, session auth, the media contract a published client reads
// (typed array plus the legacy id/cover fields), upload validation, orphaned-file cleanup,
// block filtering, and the public invite page.

import (
	"bytes"
	"net/http"
	"strings"
	"testing"

	"github.com/nc1107/check-in/server/internal/db"
)

func TestSignupBootstrapsTheFirstAdmin(t *testing.T) {
	h := newHarness(t)

	var before struct {
		Initialized bool `json:"initialized"`
	}
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&before)
	if before.Initialized {
		t.Fatal("a fresh server must report itself uninitialized")
	}

	admin := h.admin("Robin")

	var me struct {
		ID      int64 `json:"id"`
		IsAdmin bool  `json:"isAdmin"`
	}
	h.get("/api/me", admin.Token).expect(http.StatusOK).decode(&me)
	if me.ID != admin.ID || !me.IsAdmin {
		t.Errorf("/api/me = %+v, want the admin who just signed up (id %d)", me, admin.ID)
	}

	var after struct {
		Initialized bool `json:"initialized"`
	}
	h.get("/api/server-info", "").expect(http.StatusOK).decode(&after)
	if !after.Initialized {
		t.Error("the server must report itself initialized once an admin exists")
	}
}

// The allowlist is the whole access-control model: the phone number is the invite.
func TestSignupIsGatedOnTheInviteList(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	phone := h.nextPhone()

	res := h.signup(phone, "Uninvited").expect(http.StatusForbidden)
	if !strings.Contains(res.errorMessage(), "invite list") {
		t.Errorf("error = %q, want it to name the invite list", res.errorMessage())
	}

	h.invite(admin, phone)
	h.signup(phone, "Invited").expect(http.StatusOK)

	// The invite is spent: a second signup on the same number has to be told to log in.
	h.signup(phone, "Invited Again").expect(http.StatusConflict)
}

// A signup can never legitimately carry a media id - uploading needs a session and the
// account does not exist yet - so any id present belongs to somebody else.
func TestSignupRejectsAMediaID(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	victimMedia := h.uploadImage(admin.Token)

	phone := h.nextPhone()
	h.invite(admin, phone)
	res := h.post("/api/auth/signup", "", map[string]any{
		"phone":     phone,
		"firstName": "Mallory",
		"lastName":  "Tester",
		"birthday":  "1990-04-01",
		"password":  testPassword,
		"mediaId":   victimMedia.ID,
	}).expect(http.StatusBadRequest)
	if !strings.Contains(res.errorMessage(), "after signing up") {
		t.Errorf("error = %q, want it to point at attaching the photo after signup", res.errorMessage())
	}

	// The rejection must not have consumed the invite.
	h.signup(phone, "Mallory").expect(http.StatusOK)
}

func TestLoginIssuesAWorkingSessionToken(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	var login authResp
	h.post("/api/auth/login", "", map[string]any{
		"phone": admin.Phone, "password": testPassword,
	}).expect(http.StatusOK).decode(&login)
	if login.Token == "" || login.Token == admin.Token {
		t.Error("login must issue a fresh token")
	}
	h.get("/api/feed", login.Token).expect(http.StatusOK)

	h.post("/api/auth/login", "", map[string]any{
		"phone": admin.Phone, "password": "not-the-password",
	}).expect(http.StatusUnauthorized)

	h.get("/api/feed", "").expect(http.StatusUnauthorized)
	h.get("/api/feed", "a-token-nobody-issued").expect(http.StatusUnauthorized)

	// Logging out invalidates that device's token and nothing else.
	h.post("/api/auth/logout", login.Token, nil).expect(http.StatusNoContent)
	h.get("/api/feed", login.Token).expect(http.StatusUnauthorized)
	h.get("/api/feed", admin.Token).expect(http.StatusOK)
}

// The attachment contract a published client depends on: the typed array, the flat id list
// clients predating it read, and the cover id older clients render as the post's picture.
func TestPostWithAPhotoReachesTheFeedIntact(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	viewer := h.member(admin, "Sam")
	photo := h.uploadImage(admin.Token)

	created := h.createPost(admin, map[string]any{
		"kind":     "image",
		"body":     "morning swim",
		"mediaIds": []int64{photo.ID},
		"location": "Lisbon, Portugal",
	})

	for _, tc := range []struct {
		name string
		post db.Post
	}{
		{"as created", created},
		{"as the feed serves it", onlyPost(t, h.feed(viewer))},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := tc.post
			if p.Kind != "image" {
				t.Errorf("kind = %q, want image", p.Kind)
			}
			if p.MediaID == nil || *p.MediaID != photo.ID {
				t.Errorf("cover mediaId = %d, want %d", idOrZero(p.MediaID), photo.ID)
			}
			if len(p.MediaIDs) != 1 || p.MediaIDs[0] != photo.ID {
				t.Errorf("mediaIds = %v, want [%d]", p.MediaIDs, photo.ID)
			}
			if len(p.Media) != 1 {
				t.Fatalf("media = %+v, want one attachment", p.Media)
			}
			got := p.Media[0]
			want := db.PostMedia{ID: photo.ID, Mime: "image/png", Width: 640, Height: 480}
			if got != want {
				t.Errorf("media[0] = %+v, want %+v", got, want)
			}
		})
	}

	feed := h.feed(viewer)
	if len(feed) != 1 || feed[0].AuthorName != admin.Name || feed[0].Body != "morning swim" {
		t.Errorf("feed = %+v, want the one post authored by %q", feed, admin.Name)
	}
	if feed[0].Location == nil || *feed[0].Location != "Lisbon, Portugal" {
		t.Errorf("location = %q, want Lisbon, Portugal", strOrEmpty(feed[0].Location))
	}
}

// A post's kind is derived from what is attached, never from what the client claimed, and
// the legacy cover never points at a clip - an old client renders that id as a picture.
func TestCrossPostWithAClipDerivesKindAndCover(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	viewer := h.member(admin, "Sam")
	clip := h.uploadClip(admin.Token, 9000)
	photo := h.uploadImage(admin.Token)

	// The client claims "image"; the clip in the attachments makes it a video post.
	created := h.createPost(admin, map[string]any{
		"kind":        "image",
		"body":        "the whole weekend",
		"mediaIds":    []int64{clip.ID, photo.ID},
		"crossPostId": "shared-2f9c",
	})

	served := onlyPost(t, h.feed(viewer))
	for name, p := range map[string]db.Post{"as created": created, "as the feed serves it": served} {
		t.Run(name, func(t *testing.T) {
			if p.Kind != "video" {
				t.Errorf("kind = %q, want video - a clip is attached", p.Kind)
			}
			if p.MediaID == nil || *p.MediaID != photo.ID {
				t.Errorf("cover mediaId = %d, want the image (%d), never the clip (%d)",
					idOrZero(p.MediaID), photo.ID, clip.ID)
			}
			if p.CrossPostID == nil || *p.CrossPostID != "shared-2f9c" {
				t.Errorf("crossPostId = %q, want shared-2f9c", strOrEmpty(p.CrossPostID))
			}
			if len(p.MediaIDs) != 2 || p.MediaIDs[0] != clip.ID || p.MediaIDs[1] != photo.ID {
				t.Errorf("mediaIds = %v, want the attach order [%d %d]", p.MediaIDs, clip.ID, photo.ID)
			}
			if len(p.Media) != 2 {
				t.Fatalf("media = %+v, want two attachments", p.Media)
			}
			if p.Media[0].Mime != "video/mp4" || p.Media[0].DurationMs != 9000 {
				t.Errorf("media[0] = %+v, want the 9s mp4", p.Media[0])
			}
			if p.Media[1].Mime != "image/png" {
				t.Errorf("media[1] = %+v, want the photo", p.Media[1])
			}
		})
	}
}

func TestPostRejectsSomebodyElsesAttachment(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	other := h.member(admin, "Sam")
	theirs := h.uploadImage(other.Token)

	res := h.post("/api/posts", admin.Token, map[string]any{
		"kind": "image", "body": "not mine", "mediaIds": []int64{theirs.ID},
	}).expect(http.StatusBadRequest)
	if !strings.Contains(res.errorMessage(), "not yours") {
		t.Errorf("error = %q, want it to say the attachment is not the author's", res.errorMessage())
	}
}

func TestMediaUploadValidation(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")

	t.Run("a photo is stored and described", func(t *testing.T) {
		media := h.uploadImage(admin.Token)
		if media.Mime != "image/png" || media.Width != 640 || media.Height != 480 {
			t.Errorf("media = %+v, want a 640x480 image/png", media)
		}
		if media.DurationMs != 0 {
			t.Errorf("durationMs = %d, want 0 for a still", media.DurationMs)
		}
	})

	t.Run("a photo over the size limit is refused", func(t *testing.T) {
		oversize := bytes.Repeat([]byte{0x5A}, testMaxImageBytes+1024)
		h.uploadFile("/api/media", admin.Token, "huge.png", oversize).expect(http.StatusBadRequest)
	})

	t.Run("a clip within the duration cap is accepted", func(t *testing.T) {
		media := h.uploadClip(admin.Token, 11_500)
		if media.Mime != "video/mp4" || media.DurationMs != 11_500 {
			t.Errorf("media = %+v, want an 11.5s video/mp4", media)
		}
		if media.Width != 1920 || media.Height != 1080 {
			t.Errorf("dimensions = %dx%d, want 1920x1080", media.Width, media.Height)
		}
	})

	t.Run("a clip over the duration cap is refused", func(t *testing.T) {
		res := h.uploadFile("/api/media", admin.Token, "long.mp4", testClip(15_000)).
			expect(http.StatusBadRequest)
		if !strings.Contains(res.errorMessage(), "longer than 12 seconds") {
			t.Errorf("error = %q, want it to name the 12 second cap", res.errorMessage())
		}
	})

	t.Run("something that is not media at all is refused", func(t *testing.T) {
		h.uploadFile("/api/media", admin.Token, "notes.txt", []byte("just some text")).
			expect(http.StatusBadRequest)
	})
}

func TestServeMedia(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	stranger := h.member(admin, "Sam")
	clip := h.uploadClip(admin.Token, 8000)
	path := "/api/media/" + itoa(clip.ID)

	t.Run("the owner gets the clip", func(t *testing.T) {
		res := h.get(path, admin.Token).expect(http.StatusOK)
		if ct := res.Header.Get("Content-Type"); ct != "video/mp4" {
			t.Errorf("content-type = %q, want video/mp4", ct)
		}
	})

	// An upload that never became a post belongs to nobody else yet; serving it would let a
	// member enumerate other people's files.
	t.Run("a stranger cannot fetch an unposted upload", func(t *testing.T) {
		h.get(path, stranger.Token).expect(http.StatusNotFound)
	})

	// An iOS AVPlayer will not play a source that ignores Range.
	t.Run("a range request is answered with a partial body", func(t *testing.T) {
		res := h.get(path, admin.Token, func(r *http.Request) {
			r.Header.Set("Range", "bytes=0-9")
		}).expect(http.StatusPartialContent)
		if len(res.Body) != 10 {
			t.Errorf("body = %d bytes, want 10", len(res.Body))
		}
		if cr := res.Header.Get("Content-Range"); !strings.HasPrefix(cr, "bytes 0-9/") {
			t.Errorf("content-range = %q, want bytes 0-9/<size>", cr)
		}
	})

	t.Run("a poster that does not exist is a 404, not the clip", func(t *testing.T) {
		h.get(path+"?variant=poster", admin.Token).expect(http.StatusNotFound)
	})

	t.Run("a poster is served once attached", func(t *testing.T) {
		h.uploadFile(path+"/poster", admin.Token, "frame.png", pngBytes(t, 320, 180)).
			expect(http.StatusOK)
		res := h.get(path+"?variant=poster", admin.Token).expect(http.StatusOK)
		if ct := res.Header.Get("Content-Type"); ct != "image/png" {
			t.Errorf("content-type = %q, want image/png - a poster is a picture", ct)
		}
	})
}

// A video row owns two files. Returning only the clip on delete leaves a poster on disk that
// nothing references and nothing will ever look for again.
func TestDeletingAPostRemovesBothMediaFiles(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	clip := h.uploadClip(admin.Token, 6000)
	h.uploadFile("/api/media/"+itoa(clip.ID)+"/poster", admin.Token, "frame.png", pngBytes(t, 320, 180)).
		expect(http.StatusOK)

	clipPath, posterPath := h.mediaPaths(clip.ID)
	if clipPath == "" || posterPath == "" {
		t.Fatalf("stored paths = (%q, %q), want both set", clipPath, posterPath)
	}
	if !h.fileExists(clipPath) || !h.fileExists(posterPath) {
		t.Fatal("both files should be on disk before the delete")
	}

	post := h.createPost(admin, map[string]any{
		"kind": "video", "body": "gone in a moment", "mediaIds": []int64{clip.ID},
	})
	h.delete("/api/posts/"+itoa(post.ID), admin.Token).expect(http.StatusNoContent)

	h.get("/api/posts/"+itoa(post.ID), admin.Token).expect(http.StatusNotFound)
	if h.fileExists(clipPath) {
		t.Error("the clip is still on disk")
	}
	if h.fileExists(posterPath) {
		t.Error("the poster is still on disk - orphaned files fill the media volume silently")
	}
}

func TestBlockingHidesTheAuthorEverywhere(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	loud := h.member(admin, "Sam")
	bystander := h.member(admin, "Alex")

	post := h.createPost(loud, map[string]any{"kind": "text", "body": "look at me"})
	postPath := "/api/posts/" + itoa(post.ID)

	if len(h.feed(admin)) != 1 {
		t.Fatal("the post should be in the feed before the block")
	}

	h.post("/api/me/blocks/"+itoa(loud.ID), admin.Token, nil).expect(http.StatusNoContent)

	if got := h.feed(admin); len(got) != 0 {
		t.Errorf("blocker's feed = %+v, want the blocked author's post gone", got)
	}
	// Direct links have to close too, or the block only hides the post from the one screen
	// that lists it.
	h.get(postPath, admin.Token).expect(http.StatusNotFound)

	if got := h.feed(bystander); len(got) != 1 {
		t.Errorf("bystander's feed = %+v, want the post still there - a block is one-way", got)
	}

	h.delete("/api/me/blocks/"+itoa(loud.ID), admin.Token).expect(http.StatusNoContent)
	if got := h.feed(admin); len(got) != 1 {
		t.Errorf("feed after unblocking = %+v, want the post back", got)
	}
}

// The invite page is the link a host sends to someone who does not have the app: public by
// design, and the one page that renders HTML, so its own tighter CSP has to survive.
func TestJoinPageIsPublicAndLockedDown(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	h.patch("/api/admin/server", admin.Token,
		map[string]any{"name": "Weekend Crew", "color": "coral"}).expect(http.StatusOK)

	res := h.get("/join", "").expect(http.StatusOK)

	if got := res.Header.Get("Content-Security-Policy"); got != "default-src 'none'; style-src 'unsafe-inline'" {
		t.Errorf("CSP = %q, want the join page's own inline-style policy", got)
	}
	if got := res.Header.Get("Cache-Control"); got != "no-store" {
		t.Errorf("cache-control = %q, want no-store - the page names which server to trust", got)
	}
	if got := res.Header.Get("X-Content-Type-Options"); got != "nosniff" {
		t.Errorf("x-content-type-options = %q, want nosniff", got)
	}

	body := string(res.Body)
	for _, want := range []string{"Weekend Crew", groupColorHex["coral"], "checkin://join?server="} {
		if !strings.Contains(body, want) {
			t.Errorf("page does not mention %q", want)
		}
	}
}

// Content endpoints are throttled per member, so one member running a script cannot fill the
// group's feed, and cannot slow anybody else down while trying.
func TestPostingPastTheBurstIsThrottled(t *testing.T) {
	h := newHarness(t)
	admin := h.admin("Robin")
	other := h.member(admin, "Sam")

	burst := int(newContentLimits().posts.burst)
	for i := 0; i < burst; i++ {
		h.post("/api/posts", admin.Token,
			map[string]any{"kind": "text", "body": "flood"}).expect(http.StatusCreated)
	}

	res := h.post("/api/posts", admin.Token,
		map[string]any{"kind": "text", "body": "one too many"}).expect(http.StatusTooManyRequests)
	if !strings.Contains(res.errorMessage(), "slow down") {
		t.Errorf("error = %q, want it to tell the member to slow down", res.errorMessage())
	}

	// The throttle is that member's alone.
	h.post("/api/posts", other.Token,
		map[string]any{"kind": "text", "body": "unaffected"}).expect(http.StatusCreated)
}

// ---- helpers ----

// idOrZero and strOrEmpty keep failure messages readable: %v on a pointer prints an address,
// which tells the reader nothing about what went wrong.
func idOrZero(id *int64) int64 {
	if id == nil {
		return 0
	}
	return *id
}

func strOrEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func onlyPost(t *testing.T, posts []db.Post) db.Post {
	t.Helper()
	if len(posts) != 1 {
		t.Fatalf("feed has %d posts, want exactly 1", len(posts))
	}
	return posts[0]
}
