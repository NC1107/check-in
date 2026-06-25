// Command server runs the Check-In API server.
package main

import (
	"context"
	"errors"
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

	store, err := storage.New(cfg.MediaDir)
	if err != nil {
		log.Fatalf("storage: %v", err)
	}

	// Optional push notifications via FCM. Failure here only disables push; it never
	// stops the server from running.
	var pushSender *push.Sender
	if cfg.FCMCredentialsFile != "" {
		creds, rerr := os.ReadFile(cfg.FCMCredentialsFile)
		if rerr != nil {
			log.Printf("push: cannot read FCM credentials (%v); push disabled", rerr)
		} else if pushSender, err = push.New(ctx, creds); err != nil {
			log.Printf("push: init failed (%v); push disabled", err)
			pushSender = nil
		} else {
			log.Println("push: FCM enabled")
		}
	}

	srv := api.New(cfg, database, store, pushSender)
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
