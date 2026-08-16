package db

// TestMigration0021DefaultsAndBackfillsMonthlyCadence exercises 0021_recap_monthly_default.sql
// end to end, against a real Postgres. Unlike the internal/api harness's shared TESTDB_URL
// database, this runs inside its own throwaway schema (CREATE SCHEMA / DROP SCHEMA CASCADE)
// so it can apply migrations one at a time without racing every other package's tests that
// also migrate and truncate the same physical database.

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

func TestMigration0021DefaultsAndBackfillsMonthlyCadence(t *testing.T) {
	url := os.Getenv("TESTDB_URL")
	if url == "" {
		t.Skip("TESTDB_URL is not set - skipping the DB-backed migration test")
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
	// default - the exact starting state 0021's in-place UPDATE is meant to move off of.
	var cadence string
	if err := conn.QueryRow(ctx, "SELECT recap_cadence FROM server_config WHERE id = 1").
		Scan(&cadence); err != nil {
		t.Fatalf("read pre-0021 recap_cadence: %v", err)
	}
	if cadence != "weekly" {
		t.Fatalf("recap_cadence before 0021 = %q, want the untouched 0018 default %q", cadence, "weekly")
	}

	applyMigrationFile(t, ctx, conn, migration0021)

	// The load-bearing assertion: an existing row that had never been touched off the
	// untouched 'weekly' default must be moved to 'monthly' in place, by 0021 itself - not
	// merely apply to rows created after it. Dropping 0021's UPDATE (keeping only the
	// ALTER COLUMN ... SET DEFAULT) would leave this on 'weekly' forever, since nothing else
	// ever revisits an existing row - this is exactly what this assertion catches.
	if err := conn.QueryRow(ctx, "SELECT recap_cadence FROM server_config WHERE id = 1").
		Scan(&cadence); err != nil {
		t.Fatalf("read post-0021 recap_cadence: %v", err)
	}
	if cadence != "monthly" {
		t.Errorf("recap_cadence after 0021 = %q, want the backfilled %q", cadence, "monthly")
	}

	// The other half of 0021: new rows (a server that has never had a server_config row at
	// all - not this app's real shape, since 0001_init.sql seeds the singleton, but the
	// column's own DEFAULT clause is what a bare INSERT (id) would fall through to) must
	// also land on 'monthly', not just this backfilled row.
	var columnDefault string
	if err := conn.QueryRow(ctx, `
		SELECT column_default FROM information_schema.columns
		WHERE table_schema = $1 AND table_name = 'server_config' AND column_name = 'recap_cadence'`,
		schema).Scan(&columnDefault); err != nil {
		t.Fatalf("read column default: %v", err)
	}
	if !strings.Contains(columnDefault, "monthly") {
		t.Errorf("server_config.recap_cadence column default = %q, want it to contain %q",
			columnDefault, "monthly")
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
