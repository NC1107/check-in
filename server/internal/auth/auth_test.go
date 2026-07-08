package auth

import "testing"

func TestHashAndVerifyPassword(t *testing.T) {
	hash, err := HashPassword("correct horse battery")
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if !VerifyPassword("correct horse battery", hash) {
		t.Error("expected correct password to verify")
	}
	if VerifyPassword("wrong password", hash) {
		t.Error("expected wrong password to fail")
	}
	if VerifyPassword("anything", "not-a-valid-hash") {
		t.Error("expected malformed hash to fail safely")
	}
}

func TestTokenRoundTrip(t *testing.T) {
	token, hash, err := NewToken()
	if err != nil {
		t.Fatalf("new token: %v", err)
	}
	if token == "" || hash == "" {
		t.Fatal("empty token or hash")
	}
	if HashToken(token) != hash {
		t.Error("HashToken should match the hash returned by NewToken")
	}
	if HashToken("different") == hash {
		t.Error("different token should hash differently")
	}
}

func TestNormalizePhone(t *testing.T) {
	// With a US default country code, the same number matches no matter how it's written.
	cases := map[string]string{
		"+1 (555) 123-4567":  "15551234567",
		"555-123-4567":       "15551234567", // 10-digit national → default code prepended
		"(555) 123-4567":     "15551234567",
		"15551234567":        "15551234567",  // already has the country code
		"  +44 20 7946 0958": "442079460958", // explicit + kept as international
		"":                   "",
		"abc":                "",
	}
	for in, want := range cases {
		if got := NormalizePhone(in, "1"); got != want {
			t.Errorf("NormalizePhone(%q, \"1\") = %q, want %q", in, got, want)
		}
	}

	// A contact saved with +1 must match a friend who types the bare national number.
	if NormalizePhone("+1 (555) 123-4567", "1") != NormalizePhone("555-123-4567", "1") {
		t.Error("contact (+1) and typed (no +1) forms should normalize equal")
	}

	// With defaulting disabled, formatting is still stripped but no code is added.
	if got := NormalizePhone("555-123-4567", ""); got != "5551234567" {
		t.Errorf("NormalizePhone with empty defaultCC = %q, want %q", got, "5551234567")
	}
}

func TestNormalizePassword(t *testing.T) {
	// Surrounding whitespace and newlines (common copy-paste artifacts) are trimmed,
	// but interior characters, case, and internal spaces are preserved exactly.
	cases := map[string]string{
		"checkinreview":     "checkinreview",
		" checkinreview":    "checkinreview",
		"checkinreview ":    "checkinreview",
		"  checkinreview  ": "checkinreview",
		"checkinreview\n":   "checkinreview",
		"\tcheckinreview\t": "checkinreview",
		"Checkinreview":     "Checkinreview", // case is preserved
		"pass word":         "pass word",     // interior space preserved
		"   ":               "",              // whitespace-only collapses to empty
	}
	for in, want := range cases {
		if got := NormalizePassword(in); got != want {
			t.Errorf("NormalizePassword(%q) = %q, want %q", in, got, want)
		}
	}

	// End to end: a hash of the clean password verifies whatever surrounding whitespace
	// a reviewer pastes, because both sides normalize the same way.
	hash, err := HashPassword(NormalizePassword("checkinreview"))
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	for _, typed := range []string{"checkinreview", " checkinreview ", "checkinreview\n"} {
		if !VerifyPassword(NormalizePassword(typed), hash) {
			t.Errorf("normalized %q should verify against the clean hash", typed)
		}
	}
	// A genuinely different password (case change) must still fail.
	if VerifyPassword(NormalizePassword("Checkinreview"), hash) {
		t.Error("a case-changed password must not verify (trimming is not case-folding)")
	}
}
