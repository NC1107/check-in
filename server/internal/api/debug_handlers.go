package api

import (
	"crypto/subtle"
	"fmt"
	"html/template"
	"net/http"
	"strconv"
	"strings"

	"github.com/nc1107/check-in/server/internal/auth"
	"github.com/nc1107/check-in/server/internal/db"
)

// The debug web view is a self-hosted maintenance console. It is only mounted when
// CHECKIN_DEBUG_TOKEN is set, and every request must carry that token. It exposes
// operational stats, the raw phone numbers (members + allowlist), and a destructive
// "reset to first-login" action that wipes the database.

// requireDebugToken gates the /debug routes on a constant-time token comparison. The
// token may be supplied as ?token= or an X-Debug-Token header. A bad token returns 404
// so the endpoint's existence isn't advertised.
func (s *Server) requireDebugToken(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := r.URL.Query().Get("token")
		if got == "" {
			got = r.Header.Get("X-Debug-Token")
		}
		want := s.cfg.DebugToken
		if want == "" || subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
			http.NotFound(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type debugView struct {
	ServerName     string
	Token          string
	Stats          db.Stats
	Users          []db.User
	Allowed        []db.AllowedPhone
	RecentPosts    []db.Post
	RecentComments []db.Comment
	Notice         string
}

func (s *Server) handleDebugDashboard(w http.ResponseWriter, r *http.Request) {
	s.renderDebug(w, r, "")
}

// handleDebugReset wipes the database after an explicit typed confirmation, returning the
// server to first-login state.
func (s *Server) handleDebugReset(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid form")
		return
	}
	if r.PostFormValue("confirm") != "RESET" {
		s.renderDebug(w, r, "Reset cancelled — type RESET to confirm.")
		return
	}
	if err := s.db.ResetDatabase(r.Context()); err != nil {
		s.renderDebug(w, r, "Reset failed: "+err.Error())
		return
	}
	s.renderDebug(w, r, "Database wiped. The next signup will become the first admin.")
}

// --- invite list management ---

// handleDebugInviteAdd adds typed numbers (comma/newline separated) to the allowlist.
func (s *Server) handleDebugInviteAdd(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid form")
		return
	}
	seen := map[string]struct{}{}
	var phones []string
	for _, p := range strings.FieldsFunc(r.PostFormValue("phones"),
		func(c rune) bool { return c == ',' || c == ';' || c == '\n' || c == '\r' }) {
		n := auth.NormalizePhone(p, s.cfg.DefaultCountryCode)
		if n == "" {
			continue
		}
		if _, ok := seen[n]; ok {
			continue
		}
		seen[n] = struct{}{}
		phones = append(phones, n)
	}
	if len(phones) == 0 {
		s.renderDebug(w, r, "No valid numbers to add.")
		return
	}
	added, err := s.db.AddAllowedPhonesNoUser(r.Context(), phones)
	if err != nil {
		s.renderDebug(w, r, "Could not add numbers: "+err.Error())
		return
	}
	s.renderDebug(w, r, fmt.Sprintf("Added %d new number(s); %d were already invited.", added, len(phones)-added))
}

// handleDebugInviteRemove removes a number from the allowlist.
func (s *Server) handleDebugInviteRemove(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid form")
		return
	}
	phone := r.PostFormValue("phone")
	if err := s.db.RemoveAllowedPhone(r.Context(), phone); err != nil {
		s.renderDebug(w, r, "Could not remove "+phone+".")
		return
	}
	s.renderDebug(w, r, "Removed "+phone+" from the invite list.")
}

// --- member management ---

// handleDebugMemberRevoke disables a member and ends their sessions.
func (s *Server) handleDebugMemberRevoke(w http.ResponseWriter, r *http.Request) {
	id, ok := s.debugFormID(w, r)
	if !ok {
		return
	}
	if err := s.db.SetUserStatus(r.Context(), id, "revoked"); err != nil {
		s.renderDebug(w, r, "Could not revoke that member.")
		return
	}
	_ = s.db.DeleteUserSessions(r.Context(), id)
	s.renderDebug(w, r, "Member revoked and signed out.")
}

// handleDebugMemberPromote grants a member admin rights.
func (s *Server) handleDebugMemberPromote(w http.ResponseWriter, r *http.Request) {
	id, ok := s.debugFormID(w, r)
	if !ok {
		return
	}
	if err := s.db.SetUserAdmin(r.Context(), id, true); err != nil {
		s.renderDebug(w, r, "Could not promote that member.")
		return
	}
	s.renderDebug(w, r, "Member promoted to admin.")
}

// --- content moderation ---

func (s *Server) handleDebugPostDelete(w http.ResponseWriter, r *http.Request) {
	id, ok := s.debugFormID(w, r)
	if !ok {
		return
	}
	if err := s.db.AdminDeletePost(r.Context(), id); err != nil {
		s.renderDebug(w, r, "Could not delete that post.")
		return
	}
	s.renderDebug(w, r, "Post deleted.")
}

func (s *Server) handleDebugCommentDelete(w http.ResponseWriter, r *http.Request) {
	id, ok := s.debugFormID(w, r)
	if !ok {
		return
	}
	if err := s.db.AdminDeleteComment(r.Context(), id); err != nil {
		s.renderDebug(w, r, "Could not delete that comment.")
		return
	}
	s.renderDebug(w, r, "Comment deleted.")
}

// debugFormID parses the "id" form field shared by the per-row action forms.
func (s *Server) debugFormID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	if err := r.ParseForm(); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid form")
		return 0, false
	}
	id, err := strconv.ParseInt(r.PostFormValue("id"), 10, 64)
	if err != nil {
		s.renderDebug(w, r, "Invalid id.")
		return 0, false
	}
	return id, true
}

func (s *Server) renderDebug(w http.ResponseWriter, r *http.Request, notice string) {
	ctx := r.Context()
	stats, err := s.db.Stats(ctx)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "stats error")
		return
	}
	users, _ := s.db.ListAllUsers(ctx)
	allowed, _ := s.db.ListAllowedPhones(ctx)
	recentPosts, _ := s.db.Feed(ctx, 0, nil, nil, 12)
	recentComments, _ := s.db.RecentComments(ctx, 12)

	token := r.URL.Query().Get("token")
	if token == "" {
		token = r.Header.Get("X-Debug-Token")
	}

	// Operator-only page: relax the global CSP to allow inline styles and the small
	// confirm() guards on destructive buttons. All dynamic data is auto-escaped by
	// html/template, so there's no injection surface despite 'unsafe-inline'.
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := debugTmpl.Execute(w, debugView{
		ServerName:     s.cfg.ServerName,
		Token:          token,
		Stats:          stats,
		Users:          users,
		Allowed:        allowed,
		RecentPosts:    recentPosts,
		RecentComments: recentComments,
		Notice:         notice,
	}); err != nil {
		// Response already partially written; nothing useful to do but log via recoverer.
		return
	}
}

var debugTmpl = template.Must(template.New("debug").Funcs(template.FuncMap{
	"fmtTime": func(t interface{ Format(string) string }) string { return t.Format("2006-01-02 15:04") },
	"trunc": func(s string, n int) string {
		s = strings.TrimSpace(s)
		r := []rune(s)
		if len(r) <= n {
			return s
		}
		return string(r[:n]) + "…"
	},
}).Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.ServerName}} · Admin</title>
<style>
  body{margin:0;background:#0a0a0b;color:#ededef;font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;}
  .wrap{max-width:1000px;margin:0 auto;padding:28px 20px 80px;}
  h1{font-size:20px;margin:0 0 4px;} h2{font-size:14px;text-transform:uppercase;letter-spacing:.6px;color:#848490;margin:34px 0 12px;}
  .sub{color:#848490;margin:0 0 8px;}
  .notice{background:#1c1c1e;border:1px solid #5557e0;border-radius:10px;padding:12px 14px;margin:16px 0;}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;}
  .stat{background:#1c1c1e;border:1px solid #27272a;border-radius:12px;padding:14px;}
  .stat .n{font-size:24px;font-weight:700;} .stat .l{color:#848490;font-size:12px;}
  .pill{display:inline-block;padding:2px 9px;border-radius:9999px;font-size:12px;font-weight:600;}
  .ok{background:rgba(34,197,94,.16);color:#22c55e;} .no{background:rgba(239,68,68,.16);color:#ef4444;}
  table{width:100%;border-collapse:collapse;background:#1c1c1e;border:1px solid #27272a;border-radius:12px;overflow:hidden;}
  th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #27272a;font-size:13px;vertical-align:middle;}
  th{color:#848490;font-weight:600;text-transform:uppercase;font-size:11px;letter-spacing:.4px;}
  tr:last-child td{border-bottom:none;}
  code{background:#232326;padding:1px 6px;border-radius:6px;}
  .muted{color:#848490;}
  .btn{background:#27272a;color:#ededef;border:1px solid #3a3a3f;border-radius:8px;padding:9px 14px;font-weight:600;cursor:pointer;font-size:13px;}
  .btn:hover{background:#323237;}
  .btn-sm{padding:5px 10px;font-size:12px;}
  .btn-warn{background:rgba(233,150,10,.14);border-color:#e9960a;color:#e9960a;}
  .btn-danger{background:rgba(239,68,68,.14);border-color:#ef4444;color:#ef4444;}
  .btn-danger:hover{background:rgba(239,68,68,.24);}
  form.inline{display:inline;margin:0;}
  td.actions{white-space:nowrap;} td.actions form{margin-right:6px;}
  .add-form{display:flex;gap:8px;margin-bottom:12px;align-items:flex-start;}
  .add-form textarea{flex:1;background:#0a0a0b;border:1px solid #27272a;border-radius:8px;color:#ededef;padding:9px 11px;font:13px sans-serif;resize:vertical;}
  .danger{margin-top:40px;border:1px solid #ef4444;border-radius:12px;padding:18px;background:rgba(239,68,68,.06);}
  .danger h2{color:#ef4444;margin-top:0;}
  .danger input[type=text]{background:#0a0a0b;border:1px solid #27272a;border-radius:8px;color:#ededef;padding:9px 11px;font:14px sans-serif;}
  .danger button{background:#ef4444;color:#fff;border:none;border-radius:8px;padding:10px 16px;font-weight:700;cursor:pointer;}
  .empty{color:#848490;padding:12px;}
</style></head>
<body><div class="wrap">
  <h1>{{.ServerName}} · Admin</h1>
  <p class="sub">Server state {{if .Stats.Initialized}}<span class="pill ok">initialized</span>{{else}}<span class="pill no">not initialized (next signup = admin)</span>{{end}}</p>
  {{if .Notice}}<div class="notice">{{.Notice}}</div>{{end}}

  <h2>Stats</h2>
  <div class="grid">
    <div class="stat"><div class="n">{{.Stats.Users}}</div><div class="l">Users ({{.Stats.Admins}} admin)</div></div>
    <div class="stat"><div class="n">{{.Stats.AllowedPhones}}</div><div class="l">Invited ({{.Stats.UsedPhones}} used)</div></div>
    <div class="stat"><div class="n">{{.Stats.Posts}}</div><div class="l">Posts</div></div>
    <div class="stat"><div class="n">{{.Stats.Comments}}</div><div class="l">Comments</div></div>
    <div class="stat"><div class="n">{{.Stats.Likes}}</div><div class="l">Likes</div></div>
    <div class="stat"><div class="n">{{.Stats.Sessions}}</div><div class="l">Sessions</div></div>
    <div class="stat"><div class="n">{{.Stats.Media}}</div><div class="l">Media</div></div>
  </div>

  <h2>Members ({{len .Users}})</h2>
  {{if .Users}}<table><tr><th>ID</th><th>Display</th><th>Phone</th><th>Role</th><th>Status</th><th>Joined</th><th>Actions</th></tr>
  {{range .Users}}<tr><td>{{.ID}}</td><td>{{.Name}}</td><td><code>{{.Phone}}</code></td>
    <td>{{if .IsAdmin}}<span class="pill ok">admin</span>{{else}}member{{end}}</td>
    <td>{{.Status}}</td><td>{{fmtTime .CreatedAt}}</td>
    <td class="actions">{{if and (not .IsAdmin) (eq .Status "active")}}
      <form class="inline" method="post" action="/debug/member/promote?token={{$.Token}}"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button class="btn btn-sm">Make admin</button></form>
      <form class="inline" method="post" action="/debug/member/revoke?token={{$.Token}}" onsubmit="return confirm('Revoke {{.Name}}? They will be signed out.')"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button class="btn btn-warn btn-sm">Revoke</button></form>
    {{else if eq .Status "revoked"}}<span class="muted">revoked</span>{{else}}<span class="muted">—</span>{{end}}</td></tr>{{end}}</table>
  {{else}}<div class="empty">No members yet.</div>{{end}}

  <h2>Invite list ({{len .Allowed}})</h2>
  <form class="add-form" method="post" action="/debug/invite/add?token={{.Token}}">
    <input type="hidden" name="token" value="{{.Token}}">
    <textarea name="phones" rows="2" placeholder="Add numbers — comma or newline separated, e.g. +1 (415) 555-0148"></textarea>
    <button class="btn">Add</button>
  </form>
  {{if .Allowed}}<table><tr><th>Phone</th><th>Status</th><th>Added</th><th>Actions</th></tr>
  {{range .Allowed}}<tr><td><code>{{.Phone}}</code></td>
    <td>{{if .Used}}<span class="pill ok">joined</span>{{else}}<span class="pill no">pending</span>{{end}}</td>
    <td>{{fmtTime .CreatedAt}}</td>
    <td class="actions">{{if not .Used}}<form class="inline" method="post" action="/debug/invite/remove?token={{$.Token}}" onsubmit="return confirm('Remove {{.Phone}} from the invite list?')"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="phone" value="{{.Phone}}"><button class="btn btn-warn btn-sm">Remove</button></form>{{else}}<span class="muted">—</span>{{end}}</td></tr>{{end}}</table>
  {{else}}<div class="empty">No invited numbers.</div>{{end}}

  <h2>Recent posts</h2>
  {{if .RecentPosts}}<table><tr><th>ID</th><th>Author</th><th>When</th><th>Location</th><th>Content</th><th>♥</th><th>💬</th><th></th></tr>
  {{range .RecentPosts}}<tr><td>{{.ID}}</td><td>{{.AuthorName}}</td><td>{{fmtTime .CreatedAt}}</td>
    <td>{{if .Location}}{{.Location}}{{else}}<span class="muted">—</span>{{end}}</td>
    <td>{{if eq .Kind "image"}}<span class="muted">[photo]</span> {{end}}{{trunc .Body 60}}</td>
    <td>{{.LikeCount}}</td><td>{{.CommentCount}}</td>
    <td class="actions"><form class="inline" method="post" action="/debug/post/delete?token={{$.Token}}" onsubmit="return confirm('Delete post #{{.ID}}?')"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button class="btn btn-danger btn-sm">Delete</button></form></td></tr>{{end}}</table>
  {{else}}<div class="empty">No posts yet.</div>{{end}}

  <h2>Recent comments</h2>
  {{if .RecentComments}}<table><tr><th>ID</th><th>Author</th><th>When</th><th>On post</th><th>Comment</th><th></th></tr>
  {{range .RecentComments}}<tr><td>{{.ID}}</td><td>{{.AuthorName}}</td><td>{{fmtTime .CreatedAt}}</td><td>#{{.PostID}}</td>
    <td>{{trunc .Body 70}}</td>
    <td class="actions"><form class="inline" method="post" action="/debug/comment/delete?token={{$.Token}}" onsubmit="return confirm('Delete this comment?')"><input type="hidden" name="token" value="{{$.Token}}"><input type="hidden" name="id" value="{{.ID}}"><button class="btn btn-danger btn-sm">Delete</button></form></td></tr>{{end}}</table>
  {{else}}<div class="empty">No comments yet.</div>{{end}}

  <div class="danger">
    <h2>Danger zone</h2>
    <p class="sub">Wipe the entire database (users, posts, invites, media records, sessions) and return the server to first-login state. The next person to sign up becomes the admin. This cannot be undone.</p>
    <form method="post" action="/debug/reset?token={{.Token}}">
      <input type="hidden" name="token" value="{{.Token}}">
      <label>Type <code>RESET</code> to confirm: <input type="text" name="confirm" autocomplete="off" placeholder="RESET"></label>
      <button type="submit">Wipe database</button>
    </form>
  </div>
</div></body></html>`))
