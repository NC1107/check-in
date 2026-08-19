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
	// GazetteerPath is the local filesystem path to the places gazetteer's plain,
	// directly-seekable dataset (internal/gazetteer/data/places.bin, decompressed from its
	// checked-in .gz sibling at Docker build time - see the Dockerfile and
	// internal/gazetteer's own doc comment for why it's read off disk rather than embedded
	// in the binary). The default matches where the Dockerfile bakes it into the image; a
	// host running the binary directly (not via the published image) would need to point
	// this at wherever they placed a decompressed copy of that same file.
	GazetteerPath string
	// ServerName is a human-friendly name surfaced to clients via /api/server-info.
	ServerName string
	// PublicURL is this server's public base URL (e.g. "https://alpha.check-in.example.com").
	// Surfaced via /api/server-info and stamped into push payloads so a client connected to
	// several servers can attribute a notification to the right one. Optional; empty means
	// the client falls back to matching on nothing (single-server installs don't need it).
	PublicURL string
	// SessionTTL is how long a login session token stays valid.
	SessionTTL time.Duration
	// MaxUploadBytes caps the size of an uploaded image.
	MaxUploadBytes int64
	// MaxVideoBytes caps the size of an uploaded video clip. Separate from MaxUploadBytes
	// because a 10s H.264 clip is a few times heavier than a photo, and raising the photo
	// limit to match would also raise what a photo upload can spend.
	MaxVideoBytes int64
	// DebugToken, when non-empty, enables the /debug web view (stats, phone numbers,
	// and a destructive DB reset) guarded by this token. Leave unset to disable entirely.
	DebugToken string
	// DefaultCountryCode is the calling code (e.g. "1" for US/Canada) applied to bare
	// national phone numbers so a contact saved as "+1 (415) 555-0148" matches a friend
	// who types "(415) 555-0148". Numbers entered with a leading '+' are taken as-is.
	DefaultCountryCode string
	// FCMCredentialsFile points to a Firebase service-account JSON used to send push
	// notifications via FCM directly (reaches Android directly, iOS through APNs). Set only
	// by a host that built and ships its own app; the maintainer's own server uses it too.
	FCMCredentialsFile string
	// RelayURL is the base URL of the push relay this server forwards notifications through
	// when it has no FCM credentials of its own. Defaults to the maintainer's relay so a
	// self-hoster running the published apps gets working push with no setup. Clear it to
	// turn push off (short of bringing your own Firebase). Ignored when FCMCredentialsFile
	// is set, since that means the server can reach FCM directly.
	RelayURL string
	// KlipyKey is the API key for the Klipy GIF-search proxy (GET /api/gifs/search). Empty
	// disables gif search entirely: the proxy answers a clean error and /api/server-info
	// leaves gifSearch out of what it tells the app this server can do.
	KlipyKey string
	// KlipyBaseURL is the upstream Klipy API's base URL. Overridable so tests can point the
	// proxy at an httptest fake instead of the real service.
	KlipyBaseURL string
	// TrustedProxyHops is how many reverse proxies sit directly in front of this server -
	// the ones the auth rate limiter (rateLimitAuth) is allowed to trust for the caller's
	// real IP, read from the X-Forwarded-For chain at that exact position (see
	// middleware.ClientIPFromXFFTrustedProxies). The standard Compose deployment is exactly
	// one (Caddy; see docker-compose.yml and "only expose 80/443" in
	// docs/self-hosting/security.md) and that's the default. A host fronting Caddy with
	// another proxy of their own (a corporate load balancer, say) adds one for each such
	// hop - putting Cloudflare in front of Caddy does NOT count, since Caddy is still the
	// only hop that talks to this process directly. Getting this wrong in either direction
	// either lets a caller spoof their way past the limiter again or throttles everyone
	// under one shared bucket, so it's a knob to change deliberately, not to guess at.
	TrustedProxyHops int
}

// DefaultRelayURL is the maintainer-run relay the published apps' Firebase project is
// wired to. Baked in as the default so push works out of the box for self-hosters; a host
// opts out by setting CHECKIN_RELAY_URL empty.
const DefaultRelayURL = "https://checkin-relay.npc-server.top"

// DefaultKlipyBaseURL is Klipy's real API host, used unless a test overrides it.
const DefaultKlipyBaseURL = "https://api.klipy.com"

// Load reads configuration from the environment, applying sensible defaults so the
// server runs out of the box for local development.
func Load() (Config, error) {
	cfg := Config{
		HTTPAddr: getenv("CHECKIN_HTTP_ADDR", ":8080"),
		// No default. A connection string with a password baked into the binary is a
		// credential in source control however placeholder it looks, and it also made the
		// required-check below dead code - an unset variable silently became "try localhost
		// with a guessed password" rather than an error naming what is missing. Compose sets
		// this from POSTGRES_PASSWORD, and the README passes it explicitly.
		DatabaseURL:        os.Getenv("CHECKIN_DATABASE_URL"),
		MediaDir:           getenv("CHECKIN_MEDIA_DIR", "./data/media"),
		GazetteerPath:      getenv("CHECKIN_GAZETTEER_PATH", "/app/data/places.bin"),
		ServerName:         getenv("CHECKIN_SERVER_NAME", "Check-In"),
		PublicURL:          getenv("CHECKIN_PUBLIC_URL", ""),
		SessionTTL:         getdur("CHECKIN_SESSION_TTL", 30*24*time.Hour),
		MaxUploadBytes:     getint64("CHECKIN_MAX_UPLOAD_BYTES", 10<<20), // 10 MiB
		MaxVideoBytes:      getint64("CHECKIN_MAX_VIDEO_BYTES", 25<<20),  // 25 MiB
		DebugToken:         getenv("CHECKIN_DEBUG_TOKEN", ""),
		DefaultCountryCode: getenv("CHECKIN_DEFAULT_COUNTRY_CODE", "1"),
		FCMCredentialsFile: getenv("CHECKIN_FCM_CREDENTIALS_FILE", ""),
		RelayURL:           relayURLFromEnv(),
		KlipyKey:           getenv("CHECKIN_KLIPY_KEY", ""),
		KlipyBaseURL:       getenv("CHECKIN_KLIPY_BASE_URL", DefaultKlipyBaseURL),
		TrustedProxyHops:   getPositiveInt("CHECKIN_TRUSTED_PROXY_HOPS", 1),
	}
	if cfg.DatabaseURL == "" {
		return cfg, fmt.Errorf(
			"CHECKIN_DATABASE_URL is required, e.g. postgres://user:password@host:5432/checkin?sslmode=disable")
	}
	return cfg, nil
}

// relayURLFromEnv resolves the relay URL with "present but empty means off" semantics: an
// unset CHECKIN_RELAY_URL falls back to the maintainer relay (push on by default), while
// setting it to an empty string is how a host opts out. The plain getenv helper can't
// express this because it treats empty and unset the same.
func relayURLFromEnv() string {
	if v, ok := os.LookupEnv("CHECKIN_RELAY_URL"); ok {
		return v
	}
	return DefaultRelayURL
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

// getPositiveInt reads a positive integer env var, falling back to def when it's unset,
// unparseable, or not positive - middleware.ClientIPFromXFFTrustedProxies panics on
// anything less than 1, so a malformed value here must never reach it.
func getPositiveInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 {
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
