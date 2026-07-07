package api

import "testing"

func TestValidServerName(t *testing.T) {
	cases := []struct {
		name   string
		raw    string
		want   string
		wantOK bool
	}{
		{"plain", "Book Club", "Book Club", true},
		{"trims whitespace", "  College crew  ", "College crew", true},
		{"empty", "", "", false},
		{"whitespace only", "   ", "", false},
		{"exactly 40", stringOf('a', 40), stringOf('a', 40), true},
		{"too long", stringOf('a', 41), "", false},
		{"multibyte counts by rune", stringOf('é', 40), stringOf('é', 40), true},
	}
	for _, c := range cases {
		got, ok := validServerName(c.raw)
		if ok != c.wantOK || (ok && got != c.want) {
			t.Errorf("%s: validServerName(%q) = (%q, %v), want (%q, %v)",
				c.name, c.raw, got, ok, c.want, c.wantOK)
		}
	}
}

func stringOf(r rune, n int) string {
	b := make([]rune, n)
	for i := range b {
		b[i] = r
	}
	return string(b)
}
