package config

import (
	"os"
	"testing"
)

// The relay is push's default: an unset CHECKIN_RELAY_URL must resolve to the maintainer
// relay so a self-hoster gets working push with no configuration.
func TestRelayURLDefaultsOnWhenUnset(t *testing.T) {
	os.Unsetenv("CHECKIN_RELAY_URL")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.RelayURL != DefaultRelayURL {
		t.Errorf("RelayURL = %q, want the default %q", cfg.RelayURL, DefaultRelayURL)
	}
}

// Setting the variable to an empty string is the documented way to opt out. The plain
// getenv helper would wrongly treat empty as "use the default", so this guards the
// LookupEnv-based handling that distinguishes present-empty from unset.
func TestRelayURLEmptyStringOptsOut(t *testing.T) {
	t.Setenv("CHECKIN_RELAY_URL", "")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.RelayURL != "" {
		t.Errorf("RelayURL = %q, want empty (push off), an explicit empty value must not fall back to the default", cfg.RelayURL)
	}
}

func TestRelayURLCustomValue(t *testing.T) {
	t.Setenv("CHECKIN_RELAY_URL", "https://relay.example.com")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.RelayURL != "https://relay.example.com" {
		t.Errorf("RelayURL = %q, want the configured value", cfg.RelayURL)
	}
}

// An unset key must default to off (empty), so a self-hoster who hasn't set up Klipy gets a
// clean "not configured" from the gif proxy rather than an accidental key leak from some
// other default.
func TestKlipyKeyDefaultsEmpty(t *testing.T) {
	os.Unsetenv("CHECKIN_KLIPY_KEY")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.KlipyKey != "" {
		t.Errorf("KlipyKey = %q, want empty when unset", cfg.KlipyKey)
	}
	if cfg.KlipyBaseURL != DefaultKlipyBaseURL {
		t.Errorf("KlipyBaseURL = %q, want the default %q", cfg.KlipyBaseURL, DefaultKlipyBaseURL)
	}
}

func TestKlipyKeyFromEnv(t *testing.T) {
	t.Setenv("CHECKIN_KLIPY_KEY", "test-key")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.KlipyKey != "test-key" {
		t.Errorf("KlipyKey = %q, want the configured value", cfg.KlipyKey)
	}
}

// The default must match the standard Compose deployment - exactly one hop (Caddy) - or
// the auth rate limiter's IP-from-X-Forwarded-For lookup reads the wrong position out of
// the box.
func TestTrustedProxyHopsDefaultsToOne(t *testing.T) {
	os.Unsetenv("CHECKIN_TRUSTED_PROXY_HOPS")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.TrustedProxyHops != 1 {
		t.Errorf("TrustedProxyHops = %d, want 1", cfg.TrustedProxyHops)
	}
}

func TestTrustedProxyHopsFromEnv(t *testing.T) {
	t.Setenv("CHECKIN_TRUSTED_PROXY_HOPS", "2")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.TrustedProxyHops != 2 {
		t.Errorf("TrustedProxyHops = %d, want the configured value 2", cfg.TrustedProxyHops)
	}
}

// middleware.ClientIPFromXFFTrustedProxies panics below 1, so a malformed value (zero,
// negative, or unparseable) must never reach it - it has to fall back to the safe default
// instead.
func TestTrustedProxyHopsRejectsInvalidValues(t *testing.T) {
	for _, v := range []string{"0", "-1", "not-a-number", ""} {
		t.Run(v, func(t *testing.T) {
			t.Setenv("CHECKIN_TRUSTED_PROXY_HOPS", v)
			cfg, err := Load()
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if cfg.TrustedProxyHops != 1 {
				t.Errorf("TrustedProxyHops = %d for input %q, want the default 1", cfg.TrustedProxyHops, v)
			}
		})
	}
}

// A missing database URL must fail loudly rather than fall back to a guess.
//
// It used to default to a localhost connection string with a password in it. That put a
// credential in source control - however placeholder it looks, secret scanners are right to
// flag it - and it made the required-check dead code, so a deployment that forgot the
// variable silently tried localhost instead of saying what was missing.
func TestDatabaseURLIsRequired(t *testing.T) {
	t.Setenv("CHECKIN_DATABASE_URL", "")
	if _, err := Load(); err == nil {
		t.Fatal("Load succeeded with no database URL - it must refuse rather than guess one")
	}
}

// And the binary must not carry a credential to fall back to.
func TestNoDatabaseCredentialIsBakedIn(t *testing.T) {
	t.Setenv("CHECKIN_DATABASE_URL", "postgres://real:secret@db:5432/checkin?sslmode=disable")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.DatabaseURL != "postgres://real:secret@db:5432/checkin?sslmode=disable" {
		t.Errorf("DatabaseURL = %q, want exactly what the environment supplied", cfg.DatabaseURL)
	}
}
