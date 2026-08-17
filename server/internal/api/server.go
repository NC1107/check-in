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
	push    push.Notifier // nil when push isn't configured (direct FCM or relay)
	authLim *rateLimiter  // limits signup/login attempts, per IP
	content contentLimits // limits what a member can create, per user

	// klipyTimeout bounds how long the gif-search proxy waits on Klipy. Zero (the value New
	// leaves every other Server field at in tests that build one by hand) means "use the
	// default" - see klipyTimeoutOrDefault - so a test only has to set this when it wants a
	// short timeout to exercise the upstream-unreachable path quickly.
	klipyTimeout time.Duration
}

// New constructs a Server. A nil notifier disables push; pass a genuinely nil interface
// (not a typed-nil *push.Sender) so the notify* handlers' nil checks fire.
func New(cfg config.Config, database *db.DB, store *storage.Store, notifier push.Notifier) *Server {
	return &Server{
		cfg:     cfg,
		db:      database,
		store:   store,
		push:    notifier,
		authLim: newRateLimiter(20, 10), // 20/min, burst 10, per IP
		content: newContentLimits(),
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

	// The group's invite landing page. Public by design: it is the link a host sends to
	// someone who doesn't have the app yet.
	r.Get("/join", s.handleJoinPage)

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
		r.With(s.rateLimitUser(s.content.memories)).Get("/api/memories/random", s.handleRandomMemory)
		r.With(s.rateLimitUser(s.content.events)).Get("/api/memories/events", s.handleEvents)
		r.Get("/api/locations", s.handleLocations)
		r.Get("/api/search", s.handleSearch)
		r.Get("/api/users", s.handleSearchUsers)
		r.Get("/api/users/{id}", s.handleGetUser)
		r.Get("/api/users/{id}/posts", s.handleUserPosts)

		// The routes that create something are throttled per member (see contentLimits);
		// reading is not.
		r.With(s.rateLimitUser(s.content.posts)).Post("/api/posts", s.handleCreatePost)
		r.Get("/api/posts/{id}", s.handleGetPost)
		r.Delete("/api/posts/{id}", s.handleDeletePost)
		r.With(s.rateLimitUser(s.content.likes)).Post("/api/posts/{id}/like", s.handleLike)
		r.With(s.rateLimitUser(s.content.likes)).Delete("/api/posts/{id}/like", s.handleUnlike)
		r.Get("/api/posts/{id}/likes", s.handleListLikers)
		r.Get("/api/posts/{id}/comments", s.handleListComments)
		r.With(s.rateLimitUser(s.content.comments)).Post("/api/posts/{id}/comments", s.handleAddComment)

		r.Post("/api/posts/{id}/report", s.handleReportPost)
		r.Post("/api/comments/{id}/report", s.handleReportComment)

		r.Get("/api/me/blocks", s.handleListBlocks)
		r.Get("/api/me/blocks/{id}", s.handleGetBlockStatus)
		r.Post("/api/me/blocks/{id}", s.handleBlockUser)
		r.Delete("/api/me/blocks/{id}", s.handleUnblockUser)

		r.Get("/api/birthdays/upcoming", s.handleUpcomingBirthdays)

		r.With(s.rateLimitUser(s.content.media)).Post("/api/media", s.handleUploadMedia)
		r.Get("/api/media/{id}", s.handleServeMedia)
		r.With(s.rateLimitUser(s.content.media)).Post("/api/media/{id}/poster", s.handleSetMediaPoster)

		r.With(s.rateLimitUser(s.content.gifs)).Get("/api/gifs/search", s.handleGifSearch)

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
			r.Patch("/api/admin/server", s.handleUpdateServer)
			r.With(s.rateLimitUser(s.content.posts)).Post("/api/admin/recaps", s.handleGenerateRecap)
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
