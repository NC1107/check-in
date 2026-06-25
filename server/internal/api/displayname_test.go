package api

import "testing"

func TestSignupDisplayName(t *testing.T) {
	cases := []struct {
		name string
		req  signupReq
		want string
	}{
		{"explicit display name wins", signupReq{DisplayName: "Nick", FirstName: "Nicholas", LastName: "Conn"}, "Nick"},
		{"falls back to full name", signupReq{FirstName: "Nicholas", LastName: "Conn"}, "Nicholas Conn"},
		{"first name only", signupReq{FirstName: "Nicholas"}, "Nicholas"},
		{"legacy single name", signupReq{Name: "Legacy User"}, "Legacy User"},
		{"trims whitespace", signupReq{DisplayName: "  Spaced  "}, "Spaced"},
		{"empty", signupReq{}, ""},
	}
	for _, c := range cases {
		if got := c.req.displayName(); got != c.want {
			t.Errorf("%s: displayName() = %q, want %q", c.name, got, c.want)
		}
	}
}
