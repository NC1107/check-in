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
	cases := map[string]string{
		"+1 (555) 123-4567": "+15551234567",
		"555-123-4567":      "5551234567",
		"  +44 20 7946 0958": "+442079460958",
		"":                  "",
		"abc":               "",
		"+1+2+3":            "+123", // only a leading + is kept
	}
	for in, want := range cases {
		if got := NormalizePhone(in); got != want {
			t.Errorf("NormalizePhone(%q) = %q, want %q", in, got, want)
		}
	}
}
