package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// Config holds all runtime configuration, sourced from environment variables so the
// server stays a single self-contained binary that is easy to run under Docker.
type Config struct {
	// HTTPAddr is the address the API server listens on, e.g. ":8080".
	HTTPAddr string
	// DatabaseURL is the PostgreSQL connection string (pgx format).
	DatabaseURL string
	// MediaDir is the local filesystem path where uploaded media is stored.
	MediaDir string
	// ServerName is a human-friendly name surfaced to clients via /api/server-info.
	ServerName string
	// SessionTTL is how long a login session token stays valid.
	SessionTTL time.Duration
	// MaxUploadBytes caps the size of an uploaded image.
	MaxUploadBytes int64
	// DebugToken, when non-empty, enables the /debug web view (stats, phone numbers,
	// and a destructive DB reset) guarded by this token. Leave unset to disable entirely.
	DebugToken string
	// DefaultCountryCode is the calling code (e.g. "1" for US/Canada) applied to bare
	// national phone numbers so a contact saved as "+1 (415) 555-0148" matches a friend
	// who types "(415) 555-0148". Numbers entered with a leading '+' are taken as-is.
	DefaultCountryCode string
}

// Load reads configuration from the environment, applying sensible defaults so the
// server runs out of the box for local development.
func Load() (Config, error) {
	cfg := Config{
		HTTPAddr:           getenv("CHECKIN_HTTP_ADDR", ":8080"),
		DatabaseURL:        getenv("CHECKIN_DATABASE_URL", "postgres://checkin:checkin@localhost:5432/checkin?sslmode=disable"),
		MediaDir:           getenv("CHECKIN_MEDIA_DIR", "./data/media"),
		ServerName:         getenv("CHECKIN_SERVER_NAME", "Check-In"),
		SessionTTL:         getdur("CHECKIN_SESSION_TTL", 30*24*time.Hour),
		MaxUploadBytes:     getint64("CHECKIN_MAX_UPLOAD_BYTES", 10<<20), // 10 MiB
		DebugToken:         getenv("CHECKIN_DEBUG_TOKEN", ""),
		DefaultCountryCode: getenv("CHECKIN_DEFAULT_COUNTRY_CODE", "1"),
	}
	if cfg.DatabaseURL == "" {
		return cfg, fmt.Errorf("CHECKIN_DATABASE_URL is required")
	}
	return cfg, nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getint64(key string, def int64) int64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return def
}

func getdur(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
