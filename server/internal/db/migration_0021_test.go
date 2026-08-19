package db

// TestMigration0021ChangesDefaultOnlyLeavesExistingRowsAlone exercises
// 0021_recap_monthly_default.sql end to end, against a real Postgres. Unlike the
// internal/api harness's shared TESTDB_URL database, this runs inside its own throwaway
// schema (CREATE SCHEMA / DROP SCHEMA CASCADE) so it can apply migrations one at a time
// without racing every other package's tests that also migrate and truncate the same
// physical database.

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/nc1107/check-in/server/migrations"
)

func TestMigration0021ChangesDefaultOnlyLeavesExistingRowsAlone(t *testing.T) {
	url := os.Getenv("TESTDB_URL")
	if url == "" {
		// Same rule as internal/api's own guard: a skip that only ever shows under -v, in a
		// package whose "ok" is otherwise indistinguishable from a real pass, is how a whole
		// suite quietly stops running. Skipping has to be chosen.
		if os.Getenv("CHECKIN_SKIP_DB_TESTS") == "" {
			t.Fatal("TESTDB_URL is not set. Run server/scripts/test.sh, or set " +
				"CHECKIN_SKIP_DB_TESTS=1 to run without a database on purpose.")
		}
		t.Skip("TESTDB_URL is not set and CHECKIN_SKIP_DB_TESTS was set - skipping")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	defer conn.Release()

	// An isolated schema, not 'public': every migration file is schema-unqualified, so
	// pointing this connection's search_path at a scratch schema is enough to build a
	// private copy of the whole schema history without touching what any other package's
	// TESTDB_URL-backed suite is doing against 'public' at the same time.
	schema := fmt.Sprintf("recap_cadence_migration_%d", time.Now().UnixNano())
	if _, err := conn.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
	})
	if _, err := conn.Exec(ctx, "SET search_path TO "+schema); err != nil {
		t.Fatalf("set search_path: %v", err)
	}

	pre0021, migration0021 := splitAt0021(t)

	for _, name := range pre0021 {
		applyMigrationFile(t, ctx, conn, name)
	}

	// Baseline: before 0021 runs, the singleton row still carries 0018's untouched schema
	// default. This is deliberately indistinguishable, from the schema alone, from a host
	// who explicitly chose weekly - which is exactly why 0021 must never rewrite it.
	cadence := func() string {
		t.Helper()
		var c string
		if err := conn.QueryRow(ctx, "SELECT recap_cadence FROM server_config WHERE id = 1").
			Scan(&c); err != nil {
			t.Fatalf("read recap_cadence: %v", err)
		}
		return c
	}
	columnDefault := func() string {
		t.Helper()
		var d string
		if err := conn.QueryRow(ctx, `
			SELECT column_default FROM information_schema.columns
			WHERE table_schema = $1 AND table_name = 'server_config' AND column_name = 'recap_cadence'`,
			schema).Scan(&d); err != nil {
			t.Fatalf("read column default: %v", err)
		}
		return d
	}

	if got := cadence(); got != "weekly" {
		t.Fatalf("recap_cadence before 0021 = %q, want the untouched 0018 default %q", got, "weekly")
	}
	if got := columnDefault(); !strings.Contains(got, "weekly") {
		t.Fatalf("column default before 0021 = %q, want it to still contain %q", got, "weekly")
	}

	applyMigrationFile(t, ctx, conn, migration0021)

	// The column default is what changes: a brand new server_config row (a fresh install)
	// now lands on 'monthly'.
	if got := columnDefault(); !strings.Contains(got, "monthly") {
		t.Errorf("column default after 0021 = %q, want it to contain %q", got, "monthly")
	}

	// The load-bearing safety property: an existing row must be left exactly as it was.
	// There is no way to tell a host who deliberately chose weekly from one who simply never
	// visited recap settings - recap_since is stamped once and never rewritten on a settings
	// change, and a genuinely-weekly group that keeps missing the quality bar can go months
	// without ever writing a recaps row - so 0021 must never touch an existing row's value.
	// Reintroducing an UPDATE (even a guarded one) would flip this row to 'monthly' and fail
	// this assertion.
	if got := cadence(); got != "weekly" {
		t.Errorf("recap_cadence after 0021 = %q, want it left untouched at %q", got, "weekly")
	}

	// Idempotency: a migration runner may apply 0021 more than once (a restart mid-run, a
	// re-run against a schema that already recorded it in some other bookkeeping scheme).
	// Running it again must be a no-op, not a second attempt to rewrite the row.
	applyMigrationFile(t, ctx, conn, migration0021)
	if got := cadence(); got != "weekly" {
		t.Errorf("recap_cadence after applying 0021 twice = %q, want it still untouched at %q",
			got, "weekly")
	}
	if got := columnDefault(); !strings.Contains(got, "monthly") {
		t.Errorf("column default after applying 0021 twice = %q, want it to still contain %q",
			got, "monthly")
	}
}

// splitAt0021 returns every embedded migration filename strictly before 0021, and 0021's own
// filename, in the same lexical order Migrate applies them in.
func splitAt0021(t *testing.T) (pre []string, migration0021 string) {
	t.Helper()
	entries, err := fs.ReadDir(migrations.Files, ".")
	if err != nil {
		t.Fatalf("read migrations dir: %v", err)
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		if strings.HasPrefix(name, "0021_") {
			migration0021 = name
			break
		}
		pre = append(pre, name)
	}
	if migration0021 == "" {
		t.Fatal("0021 migration file not found - was it renamed?")
	}
	return pre, migration0021
}

// applyMigrationFile reads and runs one embedded migration file verbatim - no transaction, no
// schema_migrations bookkeeping, since this test drives the migration sequence itself rather
// than going through DB.Migrate.
func applyMigrationFile(t *testing.T, ctx context.Context, conn *pgxpool.Conn, name string) {
	t.Helper()
	sqlBytes, err := migrations.Files.ReadFile(name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	if _, err := conn.Exec(ctx, string(sqlBytes)); err != nil {
		t.Fatalf("apply %s: %v", name, err)
	}
}
