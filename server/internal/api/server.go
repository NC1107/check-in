// Package api wires together the HTTP router, middleware, and handlers.
package api

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/nc1107/check-in/server/internal/config"
	"github.com/nc1107/check-in/server/internal/db"
	"github.com/nc1107/check-in/server/internal/push"
	"github.com/nc1107/check-in/server/internal/storage"
)

// Server holds dependencies shared by all handlers.
type Server struct {
	cfg     config.Config
	db      *db.DB
	store   *storage.Store
	push    *push.Sender // nil when push isn't configured
	authLim *rateLimiter // limits signup/login attempts
}

// New constructs a Server.
func New(cfg config.Config, database *db.DB, store *storage.Store, pushSender *push.Sender) *Server {
	return &Server{
		cfg:     cfg,
		db:      database,
		store:   store,
		push:    pushSender,
		authLim: newRateLimiter(20, 10), // 20/min, burst 10, per IP
	}
}

// Router builds the chi router with all routes and middleware.
func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(30 * time.Second))
	r.Use(secureHeaders)

	r.Get("/api/health", s.handleHealth)
	r.Get("/api/server-info", s.handleServerInfo)

	// Debug/maintenance web view — only mounted when a debug token is configured,
	// and every request must carry it. Disabled by default in production.
	if s.cfg.DebugToken != "" {
		r.Group(func(r chi.Router) {
			r.Use(s.requireDebugToken)
			r.Get("/debug", s.handleDebugDashboard)
			r.Post("/debug/reset", s.handleDebugReset)
			r.Post("/debug/invite/add", s.handleDebugInviteAdd)
			r.Post("/debug/invite/remove", s.handleDebugInviteRemove)
			r.Post("/debug/member/revoke", s.handleDebugMemberRevoke)
			r.Post("/debug/member/promote", s.handleDebugMemberPromote)
			r.Post("/debug/post/delete", s.handleDebugPostDelete)
			r.Post("/debug/comment/delete", s.handleDebugCommentDelete)
		})
	}

	// Auth / onboarding (rate-limited).
	r.Group(func(r chi.Router) {
		r.Use(s.rateLimitAuth)
		r.Post("/api/auth/check-phone", s.handleCheckPhone)
		r.Post("/api/auth/signup", s.handleSignup)
		r.Post("/api/auth/login", s.handleLogin)
		r.Post("/api/auth/reset-password", s.handleResetPassword)
	})

	// Authenticated routes.
	r.Group(func(r chi.Router) {
		r.Use(s.requireAuth)

		r.Post("/api/auth/logout", s.handleLogout)
		r.Get("/api/me", s.handleMe)
		r.Patch("/api/me", s.handleUpdateMe)
		r.Put("/api/me/photo", s.handleSetProfilePhoto)
		r.Delete("/api/me", s.handleDeleteAccount)

		r.Post("/api/me/devices", s.handleRegisterDevice)
		r.Delete("/api/me/devices", s.handleUnregisterDevice)
		r.Get("/api/me/notifications", s.handleGetNotificationPrefs)
		r.Patch("/api/me/notifications", s.handleUpdateNotificationPrefs)

		r.Get("/api/feed", s.handleFeed)
		r.Get("/api/locations", s.handleLocations)
		r.Get("/api/search", s.handleSearch)
		r.Get("/api/users", s.handleSearchUsers)
		r.Get("/api/users/{id}", s.handleGetUser)
		r.Get("/api/users/{id}/posts", s.handleUserPosts)

		r.Post("/api/posts", s.handleCreatePost)
		r.Get("/api/posts/{id}", s.handleGetPost)
		r.Delete("/api/posts/{id}", s.handleDeletePost)
		r.Post("/api/posts/{id}/like", s.handleLike)
		r.Delete("/api/posts/{id}/like", s.handleUnlike)
		r.Get("/api/posts/{id}/comments", s.handleListComments)
		r.Post("/api/posts/{id}/comments", s.handleAddComment)

		r.Post("/api/posts/{id}/report", s.handleReportPost)

		r.Get("/api/me/blocks", s.handleListBlocks)
		r.Get("/api/me/blocks/{id}", s.handleGetBlockStatus)
		r.Post("/api/me/blocks/{id}", s.handleBlockUser)
		r.Delete("/api/me/blocks/{id}", s.handleUnblockUser)

		r.Get("/api/birthdays/upcoming", s.handleUpcomingBirthdays)

		r.Post("/api/media", s.handleUploadMedia)
		r.Get("/api/media/{id}", s.handleServeMedia)

		// Admin-only.
		r.Group(func(r chi.Router) {
			r.Use(s.requireAdmin)
			r.Post("/api/admin/contacts", s.handleUploadContacts)
			r.Get("/api/admin/allowed", s.handleAdminListAllowed)
			r.Delete("/api/admin/allowed", s.handleAdminRemoveAllowed)
			r.Get("/api/admin/users", s.handleAdminListUsers)
			r.Delete("/api/admin/users/{id}", s.handleAdminRevokeUser)
			r.Post("/api/admin/users/{id}/reset-code", s.handleAdminIssueResetCode)
			r.Get("/api/admin/reports", s.handleAdminListReports)
			r.Delete("/api/admin/reports/{id}", s.handleAdminDismissReport)
		})
	})

	return r
}

func secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'none'")
		next.ServeHTTP(w, r)
	})
}
