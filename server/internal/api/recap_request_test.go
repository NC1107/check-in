package api

import "testing"

func TestValidateRecapRequest(t *testing.T) {
	ok := generateRecapReq{PeriodStart: "2026-01-01T00:00:00Z", PeriodEnd: "2026-02-01T00:00:00Z", Panels: []string{"collage"}}
	with := func(edit func(*generateRecapReq)) generateRecapReq {
		r := ok
		edit(&r)
		return r
	}
	tests := []struct {
		name string
		req  generateRecapReq
		want string
	}{
		{"valid", ok, ""},
		{"bad start", with(func(r *generateRecapReq) { r.PeriodStart = "yesterday" }), "periodStart must be RFC3339"},
		{"bad end", with(func(r *generateRecapReq) { r.PeriodEnd = "" }), "periodEnd must be RFC3339"},
		{"end equals start", with(func(r *generateRecapReq) { r.PeriodEnd = r.PeriodStart }), "periodEnd must be after periodStart"},
		{"end before start", with(func(r *generateRecapReq) { r.PeriodEnd = "2025-01-01T00:00:00Z" }), "periodEnd must be after periodStart"},
		{"too long", with(func(r *generateRecapReq) { r.PeriodEnd = "2028-01-01T00:00:00Z" }), "the period can't be longer than 366 days"},
		{"no panels", with(func(r *generateRecapReq) { r.Panels = []string{" ", ""} }), "panels must include at least one of: collage"},
		{"unknown panel", with(func(r *generateRecapReq) { r.Panels = []string{"collage", "bogus"} }), "unknown panel type: bogus"},
	}
	for _, tc := range tests {
		_, _, _, _, msg := validateRecapRequest(tc.req)
		if msg != tc.want {
			t.Errorf("%s: msg %q, want %q", tc.name, msg, tc.want)
		}
	}
}

func TestValidateRecapRequestDedupesPanels(t *testing.T) {
	req := generateRecapReq{PeriodStart: "2026-01-01T00:00:00Z", PeriodEnd: "2026-02-01T00:00:00Z", Panels: []string{"collage", "collage"}}
	_, _, requested, sorted, msg := validateRecapRequest(req)
	if msg != "" || len(requested) != 1 || len(sorted) != 1 {
		t.Fatalf("got %v %v %q", requested, sorted, msg)
	}
}
