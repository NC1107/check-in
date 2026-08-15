package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The invite link's wire format, pinned from both ends. Its twin lives in
// app/test/invite_links_test.dart ("parses the exact link the server's /join page emits"),
// which feeds this same literal to the Dart parser. Change the shape on one side and the
// pair fails rather than shipping a link the app silently ignores.
func TestDeepLinkForWireFormat(t *testing.T) {
	const want = "checkin://join?server=https%3A%2F%2Falpha.check-in.example.com"
	if got := deepLinkFor("https://alpha.check-in.example.com"); got != want {
		t.Errorf("deepLinkFor() = %q, want %q", got, want)
	}
}

func TestJoinBaseURL(t *testing.T) {
	req := func(host string, headers map[string]string) *http.Request {
		r := httptest.NewRequest(http.MethodGet, "http://"+host+"/join", nil)
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		return r
	}
	cases := []struct {
		name      string
		publicURL string
		req       *http.Request
		want      string
	}{
		{"configured public url wins", "https://alpha.example.com", req("internal:8080", nil),
			"https://alpha.example.com"},
		{"configured url loses its trailing slash", "https://alpha.example.com/", req("internal:8080", nil),
			"https://alpha.example.com"},
		{"falls back to the request host", "", req("alpha.example.com", nil),
			"http://alpha.example.com"},
		{"behind a proxy that terminated TLS", "",
			req("alpha.example.com", map[string]string{"X-Forwarded-Proto": "https"}),
			"https://alpha.example.com"},
		{"first hop of a forwarded chain decides", "",
			req("alpha.example.com", map[string]string{"X-Forwarded-Proto": "https, http"}),
			"https://alpha.example.com"},
		{"an unknown forwarded scheme is ignored", "",
			req("alpha.example.com", map[string]string{"X-Forwarded-Proto": "javascript"}),
			"http://alpha.example.com"},
		{"a local port survives", "", req("localhost:8080", nil), "http://localhost:8080"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := joinBaseURL(c.publicURL, c.req); got != c.want {
				t.Errorf("joinBaseURL(%q) = %q, want %q", c.publicURL, got, c.want)
			}
		})
	}
}

func TestBuildJoinView(t *testing.T) {
	view := buildJoinView("Book Club", "indigo", "https://alpha.example.com")
	if view.GroupName != "Book Club" {
		t.Errorf("GroupName = %q, want %q", view.GroupName, "Book Club")
	}
	if view.Accent != "#7C83FF" {
		t.Errorf("Accent = %q, want the indigo palette hex", view.Accent)
	}
	if view.Host != "alpha.example.com" {
		t.Errorf("Host = %q, want the bare host to type into the app", view.Host)
	}
	if view.PageURL != "https://alpha.example.com/join" {
		t.Errorf("PageURL = %q, want this page's own address", view.PageURL)
	}

	// A group whose admin never picked a color still gets the app's own default, so the
	// page is never unstyled.
	if got := buildJoinView("Book Club", "", "https://alpha.example.com").Accent; got != joinDefaultAccent {
		t.Errorf("Accent with no group color = %q, want %q", got, joinDefaultAccent)
	}
	if got := buildJoinView("Book Club", "chartreuse", "https://alpha.example.com").Accent; got != joinDefaultAccent {
		t.Errorf("Accent for an unknown color id = %q, want %q", got, joinDefaultAccent)
	}
	if got := buildJoinView("   ", "", "https://alpha.example.com").GroupName; got != joinFallbackName {
		t.Errorf("GroupName for a blank name = %q, want %q", got, joinFallbackName)
	}
}

// Every group color the API accepts must render, or an admin could pick a color that
// leaves the invite page with the wrong accent.
func TestGroupColorHexCoversTheWholePalette(t *testing.T) {
	for _, id := range []string{"coral", "gold", "lime", "cyan", "indigo", "magenta", "orange", "steel"} {
		if _, ok := validGroupColor(id); !ok {
			t.Fatalf("validGroupColor(%q) rejected a palette id", id)
		}
		hex, ok := groupColorHex[id]
		if !ok || !strings.HasPrefix(hex, "#") || len(hex) != 7 {
			t.Errorf("groupColorHex[%q] = %q, want a #RRGGBB literal", id, hex)
		}
	}
}

func renderTestJoinPage(t *testing.T) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	renderJoinPage(rec, buildJoinView("Book Club", "indigo", "https://alpha.example.com"))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	return rec
}

// The regression that would kill the feature silently: html/template rewrites an href it
// doesn't trust to "#ZgotmplZ", and checkin:// is not a scheme it trusts. Typing DeepLink
// as anything but template.URL leaves the page's only working button dead.
func TestJoinPageKeepsTheDeepLinkHref(t *testing.T) {
	body := renderTestJoinPage(t).Body.String()
	if strings.Contains(body, "ZgotmplZ") {
		t.Fatal("the deep link was escaped away by html/template; DeepLink must be a template.URL")
	}
	want := `href="checkin://join?server=https%3A%2F%2Falpha.example.com"`
	if !strings.Contains(body, want) {
		t.Errorf("rendered page is missing %s", want)
	}
}

// The page is shown to people who may not have the app. An automatic checkin:// navigation
// would hand them a browser error they can do nothing about, so the deep link stays an
// explicit tap target and the stores are always one tap away beside it.
func TestJoinPageNeverRedirectsOnItsOwn(t *testing.T) {
	body := strings.ToLower(renderTestJoinPage(t).Body.String())
	for _, banned := range []string{"<script", "http-equiv", "location.href", "location.replace", "onload="} {
		if strings.Contains(body, banned) {
			t.Errorf("the invite page must not navigate on its own, found %q", banned)
		}
	}
}

// Mobile Firefox (and other browsers) ignore the custom-scheme button, so the manual
// address fallback is the guaranteed path in. It must always be spelled out, clearly tied
// to the "button did nothing" case, with the bare host shown for the visitor to enter.
func TestJoinPageSpellsOutTheManualAddressFallback(t *testing.T) {
	body := renderTestJoinPage(t).Body.String()
	for _, want := range []string{
		"Button did nothing?",
		"Open Check-In yourself, tap Add group",
		"<code>alpha.example.com</code>",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("invite page is missing the manual fallback text %q", want)
		}
	}
}

func TestJoinPageAlwaysShowsBothStores(t *testing.T) {
	body := renderTestJoinPage(t).Body.String()
	for _, link := range []string{joinAppStoreURL, joinPlayStoreURL} {
		if !strings.Contains(body, link) {
			t.Errorf("rendered page is missing the store link %s", link)
		}
	}
}

func TestJoinPageHeaders(t *testing.T) {
	rec := renderTestJoinPage(t)
	if got := rec.Header().Get("Content-Type"); got != "text/html; charset=utf-8" {
		t.Errorf("Content-Type = %q", got)
	}
	// The page has no script of its own, so unlike /debug its policy must not allow one.
	csp := rec.Header().Get("Content-Security-Policy")
	if csp != "default-src 'none'; style-src 'unsafe-inline'" {
		t.Errorf("Content-Security-Policy = %q", csp)
	}
	// Without CHECKIN_PUBLIC_URL the address on the page is derived from the request Host,
	// so it must never be cached and handed to a visitor it was not built for.
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}
}

// The group name and address are attacker-influencable only by the group's own admin, but
// the page is public, so the usual escaping still has to hold.
func TestJoinPageEscapesTheGroupName(t *testing.T) {
	rec := httptest.NewRecorder()
	renderJoinPage(rec, buildJoinView(`Book "Club" <script>`, "", "https://alpha.example.com"))
	body := rec.Body.String()
	if strings.Contains(body, "<script>") {
		t.Error("the group name was rendered unescaped")
	}
	if !strings.Contains(body, "&lt;script&gt;") {
		t.Error("expected the group name to survive as escaped text")
	}
}
