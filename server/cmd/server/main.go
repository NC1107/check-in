// Command server runs the Check-In API server.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nc1107/check-in/server/internal/api"
	"github.com/nc1107/check-in/server/internal/config"
	"github.com/nc1107/check-in/server/internal/db"
	"github.com/nc1107/check-in/server/internal/gazetteer"
	"github.com/nc1107/check-in/server/internal/push"
	"github.com/nc1107/check-in/server/internal/storage"
)

// Where a self-hoster goes to understand any of the push start-up messages below. One
// constant so a moved anchor is fixed in a single place rather than in whichever copies
// somebody remembers to grep for.
const pushDocsRef = "docs/self-hosting/configuration.md#push-notifications"

func main() {
	// `server -healthcheck` hits the local health endpoint and exits 0/1. Used as the
	// container healthcheck since the distroless image has no shell or curl.
	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		os.Exit(healthcheck())
	}

	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	// Must happen before anything could possibly trigger a places lookup (the gazetteer
	// package's own lazy sync.Once init means a later call would silently do nothing) -
	// see gazetteer.SetDataPath's own doc comment.
	gazetteer.SetDataPath(cfg.GazetteerPath)

	ctx := context.Background()
	database, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer database.Close()

	if err := database.Migrate(ctx); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	// One-time migration of the env-configured name into the DB, so it's editable by
	// admins from the app afterward. No-op once a name has been set.
	if err := database.SeedServerName(ctx, cfg.ServerName); err != nil {
		log.Printf("seed server name: %v", err)
	}

	store, err := storage.New(cfg.MediaDir)
	if err != nil {
		log.Fatalf("storage: %v", err)
	}

	// Push notifications. A server with its own FCM credentials sends directly; otherwise it
	// forwards through the relay (the default), registering once on first boot; with neither
	// configured, push is off. setupPush states the chosen mode on every boot - "no
	// notifications" is otherwise indistinguishable from a healthy server and is the hardest
	// thing for a self-hoster to diagnose. A push failure only disables push, never stops
	// the server.
	srv := api.New(cfg, database, store, setupPush(ctx, cfg, database))
	// Daily summaries for members who chose a digest over a ping per check-in. No-op when
	// push isn't configured.
	srv.StartDigestScheduler(ctx)
	// Weekly/monthly recap posts. Unlike the digest scheduler this runs regardless of
	// whether push is configured - a recap is a feed post, not a push-only feature.
	srv.StartRecapScheduler(ctx)
	httpServer := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           srv.Router(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		log.Printf("check-in server listening on %s", cfg.HTTPAddr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	// Purge expired sessions hourly to keep the sessions table from growing forever.
	go func() {
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for range ticker.C {
			if _, err := database.Pool.Exec(ctx, `DELETE FROM sessions WHERE expires_at < now()`); err != nil {
				log.Printf("session cleanup: %v", err)
			}
		}
	}()

	// Graceful shutdown on SIGINT/SIGTERM.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	log.Println("shutting down...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(shutdownCtx)
}

// publishedFirebaseProject is the project the App Store and Play Store builds are configured
// with (app/android/app/google-services.json, app/ios/Runner/GoogleService-Info.plist). Those
// devices mint their FCM tokens against it, so credentials for this project reach them and
// credentials for any other project do not.
const publishedFirebaseProject = "check-in-48fdc"

// directPushLog is the boot line for direct-FCM mode. Which app a member installed decides
// whether direct delivery reaches them at all, so the line has to say which case the host is
// actually in: stating the warning unconditionally sends someone whose push works perfectly
// off hunting for a fault that isn't there.
func directPushLog(projectID string) string {
	if projectID == publishedFirebaseProject {
		return fmt.Sprintf("push: direct FCM through Firebase project %q, the one the published "+
			"apps were built against, so members running those receive notifications. "+
			"See "+pushDocsRef, projectID)
	}
	return fmt.Sprintf("push: direct FCM through Firebase project %q. This only reaches an app "+
		"built against that project; the published apps were not, so members running those get "+
		"nothing. Clear CHECKIN_FCM_CREDENTIALS_FILE to deliver through the relay instead. "+
		"See "+pushDocsRef, projectID)
}

// setupPush selects and builds the push Notifier from config, logging the chosen mode. It
// returns nil (push off) rather than erroring, so a push misconfiguration never stops the
// server. Precedence: direct FCM when credentials are present (a host shipping its own app,
// and the maintainer's own server), else the relay when a URL is set (the default), else off.
func setupPush(ctx context.Context, cfg config.Config, database *db.DB) push.Notifier {
	if cfg.FCMCredentialsFile != "" {
		creds, err := os.ReadFile(cfg.FCMCredentialsFile)
		if err != nil {
			log.Printf("push: cannot read FCM credentials (%v); push disabled", err)
			return nil
		}
		sender, err := push.New(ctx, creds)
		if err != nil {
			log.Printf("push: init failed (%v); push disabled", err)
			return nil
		}
		if sender == nil {
			log.Println("push: disabled (empty FCM credentials file)")
			return nil
		}
		log.Print(directPushLog(sender.ProjectID()))
		return sender
	}

	if cfg.RelayURL != "" {
		key, err := ensureRelayKey(ctx, cfg, database)
		if err != nil {
			log.Printf("push: relay registration with %s failed (%v); push disabled. Members will "+
				"not receive notifications. See "+pushDocsRef,
				cfg.RelayURL, err)
			return nil
		}
		log.Printf("push: relay via %s. Members running the published apps receive notifications "+
			"through the maintainer's relay, which sees only a short title/body plus the device "+
			"tokens - never post content. Clear CHECKIN_RELAY_URL to turn this off. "+
			"See "+pushDocsRef, cfg.RelayURL)
		return push.NewRelaySender(cfg.RelayURL, key)
	}

	log.Println("push: disabled (no FCM credentials and no relay URL). Members will not receive " +
		"notifications. See " + pushDocsRef)
	return nil
}

// ensureRelayKey returns this server's relay key, registering with the relay on first use
// and persisting the issued key so registration happens exactly once across restarts.
func ensureRelayKey(ctx context.Context, cfg config.Config, database *db.DB) (string, error) {
	key, err := database.GetRelayKey(ctx)
	if err != nil {
		return "", fmt.Errorf("read stored relay key: %w", err)
	}
	if key != "" {
		return key, nil
	}
	regCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	key, err = push.RegisterWithRelay(regCtx, cfg.RelayURL, cfg.PublicURL)
	if err != nil {
		return "", err
	}
	if err := database.SetRelayKey(ctx, key); err != nil {
		return "", fmt.Errorf("persist relay key: %w", err)
	}
	log.Println("push: registered with the relay and stored a key for future boots")
	return key, nil
}

// healthcheck performs a single GET against the local health endpoint, returning 0 when
// it responds 200 and 1 otherwise. Run via `server -healthcheck` as the container probe.
func healthcheck() int {
	addr := os.Getenv("CHECKIN_HTTP_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1" + addr + "/api/health")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
