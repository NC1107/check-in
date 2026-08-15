package api

import (
	"html/template"
	"net/http"
	"net/url"
	"strings"
)

// The invite landing page a host sends to someone who isn't in the app yet. Public and
// unauthenticated: it reveals only the group's display name, color and address, and
// membership is still decided by the phone allowlist.
//
// The page never navigates on its own - no script, no meta refresh. Following a checkin://
// URL automatically when the app isn't installed shows the visitor a browser error they can
// do nothing about, so the deep link is an explicit tap target with the store links beside
// it.

const (
	joinAppStoreURL  = "https://apps.apple.com/app/id6783974361"
	joinPlayStoreURL = "https://play.google.com/store/apps/details?id=top.npcserver.checkin"

	// Accent for a group whose admin hasn't picked a color, matching the app's own default
	// (kAccent in app/lib/theme/tokens.dart).
	joinDefaultAccent = "#37E07E"

	// The group name shown when the server somehow has none, matching the fallback the app
	// uses for an unnamed group.
	joinFallbackName = "Check-In"
)

// joinView is everything the invite page renders.
type joinView struct {
	GroupName string
	// Accent is a CSS color literal, so it lands in the stylesheet's value context.
	Accent string
	// Host is the bare address a visitor can type into the app by hand.
	Host string
	// PageURL is this page's own address, for the link preview cards that messaging apps
	// build from the og: tags.
	PageURL string

	// DeepLink is typed template.URL because html/template's contextual autoescaper trusts
	// only http, https and mailto in an href and rewrites everything else to the literal
	// "#ZgotmplZ" - which would leave the page's only working button dead. Safe by
	// construction: deepLinkFor builds the whole value, escaping the server address.
	DeepLink template.URL

	AppStoreURL  string
	PlayStoreURL string
}

func (s *Server) handleJoinPage(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	renderJoinPage(w, buildJoinView(
		s.serverName(ctx),
		s.serverColor(ctx),
		joinBaseURL(s.cfg.PublicURL, r),
	))
}

func renderJoinPage(w http.ResponseWriter, view joinView) {
	// Narrower than the global policy allows for: the page has no script, no images and no
	// fonts, so inline styles are the only thing it needs beyond 'none'.
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// When no CHECKIN_PUBLIC_URL is set the address on this page comes from the request's
	// own Host, so a cache in front that keyed on path alone could serve one visitor a link
	// pointing at somebody else's server - and this page's whole job is to be trusted about
	// which server to talk to.
	w.Header().Set("Cache-Control", "no-store")
	if err := joinTmpl.Execute(w, view); err != nil {
		// Response already partially written; nothing useful to do but let the recoverer log.
		return
	}
}

// joinBaseURL is the group's public base URL: the configured CHECKIN_PUBLIC_URL when the
// host set one, otherwise the address this request arrived on. TLS terminates at the
// reverse proxy, so the connection itself looks plaintext and the forwarded scheme is the
// only signal that the group is served over https.
func joinBaseURL(publicURL string, r *http.Request) string {
	if u := strings.TrimRight(strings.TrimSpace(publicURL), "/"); u != "" {
		return u
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	// Only the two schemes we can serve, so a forged header can't put anything else in
	// front of the address the page shows.
	if proto, _, _ := strings.Cut(r.Header.Get("X-Forwarded-Proto"), ","); strings.TrimSpace(proto) == "https" {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

// deepLinkFor builds the custom-scheme invite the app parses. The wire format is pinned
// from both sides: TestDeepLinkForWireFormat here and its twin in
// app/test/invite_links_test.dart, against inviteServerFromUri in
// app/lib/features/onboarding/invite_links.dart.
func deepLinkFor(baseURL string) string {
	return "checkin://join?server=" + url.QueryEscape(baseURL)
}

func buildJoinView(groupName, colorID, baseURL string) joinView {
	name := strings.TrimSpace(groupName)
	if name == "" {
		name = joinFallbackName
	}
	host := baseURL
	if u, err := url.Parse(baseURL); err == nil && u.Host != "" {
		host = u.Host
	}
	accent := joinDefaultAccent
	if hex, ok := groupColorHex[colorID]; ok {
		accent = hex
	}
	return joinView{
		GroupName:    name,
		Accent:       accent,
		Host:         host,
		PageURL:      baseURL + "/join",
		DeepLink:     template.URL(deepLinkFor(baseURL)),
		AppStoreURL:  joinAppStoreURL,
		PlayStoreURL: joinPlayStoreURL,
	}
}

var joinTmpl = template.Must(template.New("join").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Join {{.GroupName}} on Check-In</title>
<meta name="description" content="{{.GroupName}} shares private check-ins on its own Check-In server.">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Check-In">
<meta property="og:title" content="Join {{.GroupName}} on Check-In">
<meta property="og:description" content="{{.GroupName}} shares private check-ins on its own Check-In server. Open this invite in the app to join.">
<meta property="og:url" content="{{.PageURL}}">
<meta name="twitter:card" content="summary">
<style>
  :root{--accent:{{.Accent}};}
  *{box-sizing:border-box;}
  body{margin:0;padding:32px 20px;background:#0A0A0A;color:#F4F4F5;
       font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       display:flex;min-height:100vh;align-items:center;justify-content:center;}
  main{width:100%;max-width:400px;text-align:center;}
  .mark{display:block;width:58px;height:58px;margin:0 auto 20px;}
  .mark circle,.mark path{fill:none;stroke:var(--accent);}
  .mark .r1{opacity:.3;stroke-width:3;}
  .mark .r2{opacity:.62;stroke-width:3.5;}
  .mark .core{fill:var(--accent);}
  .mark .tick{stroke:#0A0A0A;stroke-width:3.6;stroke-linecap:round;stroke-linejoin:round;}
  h1{margin:0 0 10px;font-size:23px;line-height:1.3;font-weight:700;}
  h1 span{color:var(--accent);}
  .lede{margin:0 0 22px;color:#A1A1AA;font-size:15px;}
  .btn{display:block;padding:15px 22px;border-radius:14px;background:var(--accent);
       color:#07140C;font-size:16px;font-weight:700;text-decoration:none;}
  .stores{display:flex;gap:10px;margin-top:10px;}
  .stores a{flex:1;padding:13px 8px;border:1px solid #2A2A2A;border-radius:14px;
            background:#161616;color:#F4F4F5;font-size:14px;font-weight:600;text-decoration:none;}
  .card{margin-top:22px;padding:16px;border:1px solid #2A2A2A;border-radius:14px;
        background:#161616;text-align:left;}
  .card h2{margin:0 0 8px;color:#8B8B93;font-size:11px;font-weight:600;letter-spacing:.6px;
           text-transform:uppercase;}
  .card p{margin:0;color:#A1A1AA;font-size:14px;}
  code{display:block;margin-top:10px;padding:13px 14px;border:1px solid var(--accent);border-radius:10px;
       background:#0A0A0A;color:#F4F4F5;font-size:15px;font-weight:600;word-break:break-all;
       user-select:all;-webkit-user-select:all;}
  .foot{margin:20px 0 0;color:#8B8B93;font-size:13px;}
</style></head>
<body><main>
  <svg class="mark" viewBox="0 0 64 64" aria-hidden="true">
    <circle class="r1" cx="32" cy="32" r="29"/>
    <circle class="r2" cx="32" cy="32" r="21"/>
    <circle class="core" cx="32" cy="32" r="13"/>
    <path class="tick" d="M26 32.5l4.6 4.6L38.6 28"/>
  </svg>
  <h1>You're invited to <span>{{.GroupName}}</span></h1>
  <p class="lede">{{.GroupName}} shares private check-ins on its own Check-In server. Open this
     invite in the app to join.</p>
  <!-- The checkin:// button is best-effort: whether a browser follows a custom-scheme link
       varies (mobile Firefox, for one, ignores it entirely), and with no script here there
       is no way to detect or work around that. The server address block below is the
       guaranteed path into the app and is spelled out for exactly that case. -->
  <a class="btn" href="{{.DeepLink}}">Open in Check-In</a>
  <div class="stores">
    <a href="{{.AppStoreURL}}">App Store</a>
    <a href="{{.PlayStoreURL}}">Google Play</a>
  </div>
  <div class="card">
    <h2>Button did nothing?</h2>
    <p>Some browsers ignore the button above. Open Check-In yourself, tap Add group, and enter
       this address:</p>
    <code>{{.Host}}</code>
  </div>
  <p class="foot">Your number has to be on this group's invite list - ask whoever sent you this
     link to add it. Check-In is a phone app, so on a computer this page is just the address
     above.</p>
</main></body></html>`))
