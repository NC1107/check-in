package api

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// A group in Check-In is a whole separate server, and every cross-group feature is the
// CLIENT talking to several of them with a shared, client-generated id. Until now that seam
// was only ever exercised against fakes: the app tests stub each group's ApiClient, and the
// server tests stand up exactly one server. Nothing checked that two independent servers,
// which cannot see each other, actually agree about a shared id or keep their own ids to
// themselves.
//
// This harness runs two of them - two databases, two media directories, two HTTP servers -
// so a test can drive the real fan-out across both.

// secondDBSuffix names the second database, derived from the first so both live on whatever
// Postgres TESTDB_URL points at.
const secondDBSuffix = "_second"

var (
	secondDBOnce sync.Once
	secondDB     *db.DB
	secondDBName string
	secondDBErr  error
)

// openSecondTestDB creates, migrates and returns a database independent of the first.
//
// A separate DATABASE rather than a schema: the migrations and every query assume they own
// the public schema, and a second server sharing tables with the first would be exactly the
// coupling these tests exist to prove does not happen.
func openSecondTestDB(t *testing.T) *db.DB {
	t.Helper()
	primary := requireTestDBURL(t)

	secondDBOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()

		parsed, err := url.Parse(primary)
		if err != nil {
			secondDBErr = fmt.Errorf("parse %s: %w", testDBEnv, err)
			return
		}
		secondDBName = strings.TrimPrefix(parsed.Path, "/") + secondDBSuffix

		// Created from a connection to the FIRST database: a database cannot be created
		// (or later dropped) from a connection to itself.
		admin, err := db.Connect(ctx, primary)
		if err != nil {
			secondDBErr = fmt.Errorf("connect to create %s: %w", secondDBName, err)
			return
		}
		defer admin.Pool.Close()
		// Dropped first so a crashed previous run cannot leave rows behind that would make
		// this run's results depend on it.
		if _, err := admin.Pool.Exec(ctx,
			fmt.Sprintf("DROP DATABASE IF EXISTS %s WITH (FORCE)", quoteIdent(secondDBName))); err != nil {
			secondDBErr = fmt.Errorf("drop stale %s: %w", secondDBName, err)
			return
		}
		if _, err := admin.Pool.Exec(ctx,
			fmt.Sprintf("CREATE DATABASE %s", quoteIdent(secondDBName))); err != nil {
			secondDBErr = fmt.Errorf("create %s: %w", secondDBName, err)
			return
		}

		second := *parsed
		second.Path = "/" + secondDBName
		if secondDB, secondDBErr = db.Connect(ctx, second.String()); secondDBErr != nil {
			return
		}
		secondDBErr = secondDB.Migrate(ctx)
	})
	if secondDBErr != nil {
		t.Fatalf("second test database: %v", secondDBErr)
	}
	return secondDB
}

// dropSecondTestDB tears the second database down at the end of the test binary.
//
// Called from TestMain rather than a per-test cleanup because the pool is shared across
// every test that asked for it. WITH (FORCE) because the handlers' notify goroutines outlive
// the requests that start them, so a connection can still be open when this runs - the
// alternative is an occasional "database is being accessed by other users" failure that has
// nothing to do with what was being tested.
func dropSecondTestDB() {
	if secondDB == nil || secondDBName == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	secondDB.Pool.Close()
	admin, err := db.Connect(ctx, primaryTestDBURL())
	if err != nil {
		return
	}
	defer admin.Pool.Close()
	_, _ = admin.Pool.Exec(ctx,
		fmt.Sprintf("DROP DATABASE IF EXISTS %s WITH (FORCE)", quoteIdent(secondDBName)))
}

// quoteIdent wraps a generated identifier for use in DDL, which cannot take parameters.
func quoteIdent(name string) string {
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}

// group is one server standing in for one Check-In group: its own database, media directory
// and HTTP server, sharing nothing with any other.
type group struct {
	*harness
	Name  string
	Admin actor
}

// comments reads a post's thread through the public endpoint.
func (g *group) comments(postID int64) []db.Comment {
	g.t.Helper()
	var page struct {
		Comments []db.Comment `json:"comments"`
	}
	g.get(fmt.Sprintf("/api/posts/%d/comments", postID), g.Admin.Token).
		expect(http.StatusOK).decode(&page)
	return page.Comments
}

// postCarrying finds this server's own copy of a cross-posted check-in.
func (g *group) postCarrying(t *testing.T, crossPostID string) db.Post {
	t.Helper()
	for _, p := range g.feed(g.Admin) {
		if p.CrossPostID != nil && *p.CrossPostID == crossPostID {
			return p
		}
	}
	t.Fatalf("%s has no post carrying crossPostId %q", g.Name, crossPostID)
	return db.Post{}
}

// addComment posts a comment carrying a shared id, failing the test unless it is accepted.
func (g *group) addComment(postID int64, body, crossCommentID string) db.Comment {
	g.t.Helper()
	var c db.Comment
	g.post(fmt.Sprintf("/api/posts/%d/comments", postID), g.Admin.Token,
		map[string]any{"body": body, "crossCommentId": crossCommentID}).
		expect(http.StatusCreated).decode(&c)
	return c
}

// twoGroups stands up two independent servers.
//
// Each gets its own harness, so every existing helper (signup, createPost, feed) works
// against either. Both are reset before use and torn down by their own t.Cleanup.
func twoGroups(t *testing.T) (a, b *group) {
	t.Helper()
	alpha := &group{harness: newHarness(t), Name: "Alpha"}
	alpha.Admin = alpha.admin("Robin")

	beta := &group{harness: newHarnessOnSecondDB(t), Name: "Beta"}
	beta.Admin = beta.admin("Robin")
	// Beta's identity sequences are pushed along so its post and comment ids CANNOT
	// coincide with Alpha's. Two fresh servers otherwise both start at 1, and a test that
	// sends one server's id to the other would pass by luck rather than by correctness.
	// Done deterministically rather than hoped for: an earlier version skipped itself when
	// the ids happened to match, which is the same silently-not-running problem this suite
	// exists to avoid.
	filler := beta.member(beta.Admin, "Filler")
	for i := 0; i < 3; i++ {
		p := beta.createPost(filler, map[string]any{"kind": "text", "body": "filler"})
		beta.post(fmt.Sprintf("/api/posts/%d/comments", p.ID), filler.Token,
			map[string]any{"body": "filler"}).expect(http.StatusCreated)
	}
	return alpha, beta
}

// The seam itself: one check-in and one comment written to two independent servers, the way
// the client actually does it.
//
// Neither server can see the other, so everything that makes the copies "the same thing" is
// carried by the client-generated id. What must hold is that each server stores that id
// byte-for-byte, and that the per-server ids it hands back are its own - the client relies
// on both to collapse the copies for display and for notifications.
func TestOneCommentAcrossTwoIndependentServers(t *testing.T) {
	// The same human, signed up separately on each server, holding a DIFFERENT user id on
	// each - which is exactly why nothing here can be keyed on a user id.
	alpha, beta := twoGroups(t)

	const sharedPost = "shared-post-2f9c"
	const sharedComment = "shared-comment-8b1d"

	aPost := alpha.createPost(alpha.Admin, map[string]any{
		"kind": "text", "body": "the trip", "crossPostId": sharedPost,
	})
	bPost := beta.createPost(beta.Admin, map[string]any{
		"kind": "text", "body": "the trip", "crossPostId": sharedPost,
	})

	alpha.addComment(aPost.ID, "said everywhere", sharedComment)
	beta.addComment(bPost.ID, "said everywhere", sharedComment)

	t.Run("both servers store the shared ids verbatim", func(t *testing.T) {
		// If either normalised, trimmed or regenerated the id, the copies would never
		// collapse and the client would show one sentence twice with nothing to explain it.
		for _, g := range []*group{alpha, beta} {
			p := g.postCarrying(t, sharedPost)
			if p.CrossPostID == nil || *p.CrossPostID != sharedPost {
				t.Errorf("%s: crossPostId = %q, want %q", g.Name, strOrEmpty(p.CrossPostID), sharedPost)
			}
			cs := g.comments(p.ID)
			if len(cs) != 1 {
				t.Fatalf("%s: %d comments, want 1", g.Name, len(cs))
			}
			if cs[0].CrossCommentID == nil || *cs[0].CrossCommentID != sharedComment {
				t.Errorf("%s: crossCommentId = %q, want %q", g.Name,
					strOrEmpty(cs[0].CrossCommentID), sharedComment)
			}
		}
	})

	t.Run("each server keeps its own ids", func(t *testing.T) {
		// The client sends each server ITS OWN post id and parent comment id. This is the
		// property that makes that necessary: the two servers genuinely disagree about what
		// number names this conversation.
		aComments := alpha.comments(aPost.ID)
		bComments := beta.comments(bPost.ID)
		if aPost.ID == bPost.ID {
			t.Errorf("both servers named this check-in %d - twoGroups is supposed to push "+
				"Beta's sequences along so a wrong-server id cannot pass by coincidence",
				aPost.ID)
		}
		if aComments[0].ID == bComments[0].ID {
			t.Errorf("both servers named this comment %d - same problem", aComments[0].ID)
		}
		if aComments[0].PostID != aPost.ID {
			t.Errorf("Alpha's comment points at post %d, want %d", aComments[0].PostID, aPost.ID)
		}
		if bComments[0].PostID != bPost.ID {
			t.Errorf("Beta's comment points at post %d, want %d", bComments[0].PostID, bPost.ID)
		}
	})

	t.Run("neither server knows anything about the other", func(t *testing.T) {
		// The isolation the whole model rests on. Alpha must not have learned Beta's post
		// exists just because they share an id.
		// Exactly one copy each. Two would mean a server had somehow taken on the other's,
		// which is the failure this whole separation is meant to make impossible.
		for _, g := range []*group{alpha, beta} {
			n := 0
			for _, p := range g.feed(g.Admin) {
				if p.CrossPostID != nil && *p.CrossPostID == sharedPost {
					n++
				}
			}
			if n != 1 {
				t.Errorf("%s holds %d copies of the shared check-in, want 1", g.Name, n)
			}
		}
		// And Beta's own unrelated posts stay Beta's.
		for _, p := range alpha.feed(alpha.Admin) {
			if p.Body == "filler" {
				t.Error("Alpha's feed contains a post that only exists on Beta")
			}
		}
	})

	t.Run("both derive the same collapse id, which is what folds the notifications", func(t *testing.T) {
		// Two servers, no coordination, must produce a byte-identical collapse key or the
		// device shows one notification per group for one sentence.
		if collapseFor("comment", sharedComment) != collapseFor("comment", sharedComment) {
			t.Fatal("unreachable")
		}
		want := "comment:" + sharedComment
		if got := collapseFor("comment", sharedComment); got != want {
			t.Errorf("collapse id = %q, want %q", got, want)
		}
	})
}
