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
		"15551234567":        "15551234567", // already has the country code
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
