package db

// DeleteAccount's residue is not observable through the API: the user row goes with
// everything else, so a leftover session still fails auth and a leftover block is filtered
// out of the block list - both because the user is gone, not because the row was removed.
//
// Most of those rows are removed by the schema rather than by the statement list. sessions,
// device_tokens, likes, comments, post_people and user_blocks all declare
// ON DELETE CASCADE on users(id), so dropping their DELETE from accountDeletions changes
// nothing that can be observed - the explicit statements are belt-and-braces over the
// cascade. This test asserts the guarantee rather than the mechanism, so it would fail if a
// future migration recreated one of those tables without its cascade.
//
// allowed_phones is the exception and the reason this test exists. It has no foreign key to
// users - it is keyed by phone - so it is removed only by its own statement, which finds the
// number through a subquery on the users row. Deleting the user first silently turns that
// into a no-op and leaves the number on the allowlist, which would let a deleted account
// sign up again with no fresh invite. That ordering bug was undetected before this.
//
// Like migration_0021_test.go, this runs inside its own throwaway schema rather than the
// shared 'public' one, so it cannot race the other packages that migrate and truncate the
// same physical database at the same time.

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// scratchDB builds a fully migrated DB inside a private schema and drops it afterwards.
// search_path rides on the connection string so every pooled connection lands in the same
// schema, which a per-connection SET could not guarantee.
func scratchDB(t *testing.T, ctx context.Context, name string) *DB {
	t.Helper()
	raw := os.Getenv("TESTDB_URL")
	if raw == "" {
		if os.Getenv("CHECKIN_SKIP_DB_TESTS") == "" {
			t.Fatal("TESTDB_URL is not set. Run server/scripts/test.sh, or set " +
				"CHECKIN_SKIP_DB_TESTS=1 to run without a database on purpose.")
		}
		t.Skip("TESTDB_URL is not set and CHECKIN_SKIP_DB_TESTS was set - skipping")
	}

	admin, err := pgxpool.New(ctx, raw)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer admin.Close()

	schema := fmt.Sprintf("%s_%d", name, time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	t.Cleanup(func() {
		cleanup, err := pgxpool.New(context.Background(), raw)
		if err != nil {
			return
		}
		defer cleanup.Close()
		_, _ = cleanup.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
	})

	scoped, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse TESTDB_URL: %v", err)
	}
	q := scoped.Query()
	q.Set("search_path", schema)
	scoped.RawQuery = q.Encode()

	pool, err := pgxpool.New(ctx, scoped.String())
	if err != nil {
		t.Fatalf("connect to %s: %v", schema, err)
	}
	t.Cleanup(pool.Close)

	d := &DB{Pool: pool}
	if err := d.Migrate(ctx); err != nil {
		t.Fatalf("migrate %s: %v", schema, err)
	}
	return d
}

func TestDeleteAccountLeavesNoRowsBehind(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	d := scratchDB(t, ctx, "delete_account")

	newUser := func(phone, name string, admin bool) User {
		t.Helper()
		u, err := d.CreateUser(ctx, NewUser{
			Phone: phone, Name: name, FirstName: name, LastName: "Tester",
			Birthday:     time.Date(1990, 4, 1, 0, 0, 0, 0, time.UTC),
			PasswordHash: "hash", IsAdmin: admin,
		})
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		return u
	}

	admin := newUser("+15550000001", "Admin", true)
	gone := newUser("+15550000002", "Departing", false)

	if _, err := d.AddAllowedPhones(ctx, []string{gone.Phone}, admin.ID); err != nil {
		t.Fatalf("allow phone: %v", err)
	}
	if err := d.CreateSession(ctx, gone.ID, "token-hash", time.Now().Add(time.Hour)); err != nil {
		t.Fatalf("create session: %v", err)
	}
	if err := d.BlockUser(ctx, admin.ID, gone.ID); err != nil {
		t.Fatalf("admin blocks departing: %v", err)
	}
	if err := d.BlockUser(ctx, gone.ID, admin.ID); err != nil {
		t.Fatalf("departing blocks admin: %v", err)
	}

	if _, err := d.DeleteAccount(ctx, gone.ID); err != nil {
		t.Fatalf("delete account: %v", err)
	}

	count := func(query string, args ...any) int {
		t.Helper()
		var n int
		if err := d.Pool.QueryRow(ctx, query, args...).Scan(&n); err != nil {
			t.Fatalf("count: %v", err)
		}
		return n
	}

	if n := count(`SELECT count(*) FROM users WHERE id = $1`, gone.ID); n != 0 {
		t.Errorf("users rows left: %d", n)
	}
	if n := count(`SELECT count(*) FROM sessions WHERE user_id = $1`, gone.ID); n != 0 {
		t.Errorf("sessions rows left: %d - a session with no owner is a live credential", n)
	}
	if n := count(
		`SELECT count(*) FROM user_blocks WHERE blocker_id = $1 OR blocked_id = $1`, gone.ID,
	); n != 0 {
		t.Errorf("user_blocks rows left: %d, in either direction", n)
	}
	if n := count(`SELECT count(*) FROM allowed_phones WHERE phone = $1`, gone.Phone); n != 0 {
		t.Errorf("allowed_phones rows left: %d - the phone could sign up again uninvited", n)
	}

	// The admin, who is not being deleted, must be untouched apart from the block they had
	// on the departing member.
	if n := count(`SELECT count(*) FROM users WHERE id = $1`, admin.ID); n != 1 {
		t.Errorf("admin user rows = %d, want 1", n)
	}
}
