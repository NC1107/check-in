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
