package api

// Signup is the invite-only server's front door, and every rule it enforces lived inside a
// handler too large to test without a database - so none of them were. These are the rules
// on their own.

import (
	"strings"
	"testing"
	"time"
)

func i64p(v int64) *int64 { return &v }

// now is fixed so "a birthday in the future" means the same thing every run.
var signupNow = time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)

func validSignup() signupReq {
	return signupReq{
		Phone:     "+1 (555) 000-0001",
		FirstName: "Ada",
		LastName:  "Lovelace",
		Birthday:  "1990-04-01",
		Password:  "hunter22hunter",
	}
}

func TestValidateSignupAcceptsAGoodRequest(t *testing.T) {
	got, msg := validateSignup(validSignup(), "1", signupNow)
	if msg != "" {
		t.Fatalf("unexpected rejection: %s", msg)
	}
	if got.Phone != "15550000001" {
		t.Errorf("phone = %q, want it normalized to digits with the country code", got.Phone)
	}
	if got.FirstName != "Ada" || got.LastName != "Lovelace" {
		t.Errorf("names = %q / %q, want Ada / Lovelace", got.FirstName, got.LastName)
	}
	if got.Name != "Ada Lovelace" {
		t.Errorf("display name = %q, want it derived from the two", got.Name)
	}
	if !got.Birthday.Equal(time.Date(1990, 4, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("birthday = %v, want 1990-04-01", got.Birthday)
	}
}

// Surrounding whitespace on a name is a typing artefact, not part of someone's name.
func TestValidateSignupTrimsNames(t *testing.T) {
	req := validSignup()
	req.FirstName = "  Ada  "
	req.LastName = "  Lovelace  "
	got, msg := validateSignup(req, "1", signupNow)
	if msg != "" {
		t.Fatalf("unexpected rejection: %s", msg)
	}
	if got.FirstName != "Ada" || got.LastName != "Lovelace" {
		t.Errorf("names = %q / %q, want them trimmed", got.FirstName, got.LastName)
	}
}

func TestValidateSignupRequiresTheBasics(t *testing.T) {
	const want = "phone, name and an 8+ char password are required"
	for _, tc := range []struct {
		name   string
		mutate func(*signupReq)
	}{
		{"no phone", func(r *signupReq) { r.Phone = "" }},
		{"phone with no digits", func(r *signupReq) { r.Phone = "not a number" }},
		{"no name at all", func(r *signupReq) { r.FirstName, r.LastName, r.Name = "", "", "" }},
		{"whitespace name", func(r *signupReq) { r.FirstName, r.LastName = "   ", "   " }},
		{"no password", func(r *signupReq) { r.Password = "" }},
		{"seven-character password", func(r *signupReq) { r.Password = "1234567" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := validSignup()
			tc.mutate(&req)
			if _, msg := validateSignup(req, "1", signupNow); msg != want {
				t.Errorf("msg = %q, want %q", msg, want)
			}
		})
	}
}

// Eight is the boundary the message promises, so eight has to be accepted.
func TestValidateSignupPasswordBoundary(t *testing.T) {
	req := validSignup()
	req.Password = "12345678"
	if _, msg := validateSignup(req, "1", signupNow); msg != "" {
		t.Errorf("an 8-character password was rejected: %s", msg)
	}
}

func TestValidateSignupNameLengthCap(t *testing.T) {
	req := validSignup()
	req.DisplayName = strings.Repeat("a", 100)
	if _, msg := validateSignup(req, "1", signupNow); msg != "" {
		t.Errorf("a 100-character name was rejected: %s", msg)
	}
	req.DisplayName = strings.Repeat("a", 101)
	if _, msg := validateSignup(req, "1", signupNow); msg != "name too long (max 100 characters)" {
		t.Errorf("msg = %q, want the length cap", msg)
	}
}

func TestValidateSignupBirthday(t *testing.T) {
	for _, tc := range []struct {
		birthday string
		msg      string
	}{
		{"1990-04-01", ""},
		{"1900-01-01", ""},
		{"", "birthday must be YYYY-MM-DD"},
		{"01-04-1990", "birthday must be YYYY-MM-DD"},
		{"1990/04/01", "birthday must be YYYY-MM-DD"},
		{"1899-12-31", "birthday is not a valid date"},
		// Tomorrow: a date nobody has reached yet is data entry gone wrong, and the
		// birthday reminders would fire on it forever.
		{"2026-08-25", "birthday is not a valid date"},
	} {
		req := validSignup()
		req.Birthday = tc.birthday
		if _, msg := validateSignup(req, "1", signupNow); msg != tc.msg {
			t.Errorf("birthday %q: msg = %q, want %q", tc.birthday, msg, tc.msg)
		}
	}
}

// Today is a real birthday - somebody born this morning is a valid, if unusual, member -
// and rejecting it would be an off-by-one on the "not in the future" rule.
func TestValidateSignupAcceptsTodayAsABirthday(t *testing.T) {
	req := validSignup()
	req.Birthday = signupNow.Format("2006-01-02")
	if _, msg := validateSignup(req, "1", signupNow); msg != "" {
		t.Errorf("today was rejected as a birthday: %s", msg)
	}
}

// The media rule is the one with a security consequence: an id at signup is by definition
// somebody else's upload, since uploading needs a session this account does not have yet.
func TestValidateSignupRefusesAMediaID(t *testing.T) {
	req := validSignup()
	req.MediaID = i64p(7)
	if _, msg := validateSignup(req, "1", signupNow); msg != "attach the profile photo after signing up" {
		t.Errorf("msg = %q, want the media rejection - accepting it would let a new member "+
			"claim another member's file as their avatar", msg)
	}
}

// An explicit display name wins over the derived one, and a legacy single-field name still
// works for an app old enough to send only that.
func TestValidateSignupNameSources(t *testing.T) {
	req := validSignup()
	req.DisplayName = "Ada L."
	if got, _ := validateSignup(req, "1", signupNow); got.Name != "Ada L." {
		t.Errorf("name = %q, want the explicit display name to win", got.Name)
	}

	legacy := signupReq{Phone: "+15550000001", Name: "Ada Lovelace",
		Birthday: "1990-04-01", Password: "hunter22hunter"}
	got, msg := validateSignup(legacy, "1", signupNow)
	if msg != "" {
		t.Fatalf("a legacy single-name signup was rejected: %s", msg)
	}
	if got.Name != "Ada Lovelace" {
		t.Errorf("name = %q, want the legacy field", got.Name)
	}
}

// A number typed without its country code takes the server's default, which is what makes
// the invite list match what a member types.
func TestValidateSignupAppliesTheDefaultCountryCode(t *testing.T) {
	req := validSignup()
	req.Phone = "(555) 000-0001"
	if got, _ := validateSignup(req, "1", signupNow); got.Phone != "15550000001" {
		t.Errorf("phone = %q, want the default country code applied", got.Phone)
	}
}
