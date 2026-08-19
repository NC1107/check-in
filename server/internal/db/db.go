// Package db provides the PostgreSQL connection pool and a minimal embedded-migration
// runner. Queries are hand-written with pgx and fully parameterized.
package db

import (
	"context"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/nc1107/check-in/server/migrations"
)

// DB wraps the pgx connection pool.
type DB struct {
	Pool *pgxpool.Pool
}

// Connect opens a pooled connection to PostgreSQL and verifies it with a ping.
func Connect(ctx context.Context, url string) (*DB, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	return &DB{Pool: pool}, nil
}

// Close releases the connection pool.
func (d *DB) Close() { d.Pool.Close() }

// migrationLockKey is an arbitrary fixed key for the session-level advisory lock that
// serializes migration runs, so two server instances starting at once (e.g. during a
// rolling redeploy) can't race the same migration.
const migrationLockKey int64 = 4915012025

// Migrate applies any embedded migrations that have not yet been recorded in the
// schema_migrations table. Each migration runs in its own transaction. The whole run is
// guarded by a Postgres advisory lock so concurrent instances apply migrations serially.
func (d *DB) Migrate(ctx context.Context) error {
	conn, err := d.Pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire migration conn: %w", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrationLockKey); err != nil {
		return fmt.Errorf("advisory lock: %w", err)
	}
	defer func() {
		// Release on the same connection; use a fresh context so unlock still runs even if
		// ctx was cancelled.
		_, _ = conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, migrationLockKey)
	}()

	if _, err := d.Pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		name TEXT PRIMARY KEY,
		applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	names, err := migrationNames()
	if err != nil {
		return err
	}
	for _, name := range names {
		applied, err := d.migrationApplied(ctx, name)
		if err != nil {
			return err
		}
		if applied {
			continue
		}
		if err := d.applyMigration(ctx, name); err != nil {
			return err
		}
	}
	return nil
}

// migrationNames lists the embedded .sql migrations in the order they must run. Sorted by
// name, which is why they are numbered.
func migrationNames() ([]string, error) {
	entries, err := fs.ReadDir(migrations.Files, ".")
	if err != nil {
		return nil, fmt.Errorf("read migrations: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// migrationApplied reports whether this migration is already recorded.
func (d *DB) migrationApplied(ctx context.Context, name string) (bool, error) {
	var exists bool
	if err := d.Pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE name = $1)`, name,
	).Scan(&exists); err != nil {
		return false, fmt.Errorf("check migration %s: %w", name, err)
	}
	return exists, nil
}

// applyMigration runs one migration and records it in the same transaction, so a migration
// can never be recorded as applied unless its statements committed.
func (d *DB) applyMigration(ctx context.Context, name string) error {
	sqlBytes, err := migrations.Files.ReadFile(name)
	if err != nil {
		return fmt.Errorf("read migration %s: %w", name, err)
	}
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin %s: %w", name, err)
	}
	if _, err := tx.Exec(ctx, string(sqlBytes)); err != nil {
		_ = tx.Rollback(ctx)
		return fmt.Errorf("apply %s: %w", name, err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations (name) VALUES ($1)`, name); err != nil {
		_ = tx.Rollback(ctx)
		return fmt.Errorf("record %s: %w", name, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit %s: %w", name, err)
	}
	return nil
}
