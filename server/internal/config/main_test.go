package config

import (
	"os"
	"testing"
)

// Every test here calls Load(), which now requires a database URL - there is deliberately no
// default, since a connection string with a password in it does not belong in the binary
// (see Load). These tests are about the OTHER settings, so one is supplied for the whole
// package rather than repeated in each.
func TestMain(m *testing.M) {
	if os.Getenv("CHECKIN_DATABASE_URL") == "" {
		_ = os.Setenv("CHECKIN_DATABASE_URL", "postgres://u:p@localhost:5432/db?sslmode=disable")
	}
	os.Exit(m.Run())
}
