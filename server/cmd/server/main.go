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
	"github.com/nc1107/check-in/server/internal/push"
	"github.com/nc1107/check-in/server/internal/storage"
)

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
		log.Printf("push: direct FCM, sending through Firebase project %q. Delivery only works if "+
			"the app your members installed was built against this project; the published apps "+
			"were not. See docs/self-hosting/configuration.md#push-notifications",
			sender.ProjectID())
		return sender
	}

	if cfg.RelayURL != "" {
		key, err := ensureRelayKey(ctx, cfg, database)
		if err != nil {
			log.Printf("push: relay registration with %s failed (%v); push disabled. Members will "+
				"not receive notifications. See docs/self-hosting/configuration.md#push-notifications",
				cfg.RelayURL, err)
			return nil
		}
		log.Printf("push: relay via %s. Members running the published apps receive notifications "+
			"through the maintainer's relay, which sees only a short title/body plus the device "+
			"tokens - never post content. Clear CHECKIN_RELAY_URL to turn this off. "+
			"See docs/self-hosting/configuration.md#push-notifications", cfg.RelayURL)
		return push.NewRelaySender(cfg.RelayURL, key)
	}

	log.Println("push: disabled (no FCM credentials and no relay URL). Members will not receive " +
		"notifications. See docs/self-hosting/configuration.md#push-notifications")
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
