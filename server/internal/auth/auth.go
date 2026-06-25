// Package auth provides password hashing (argon2id), opaque session-token generation,
// and phone-number normalization.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// argon2id parameters — tuned for an interactive login on a small self-hosted server.
const (
	argonTime    = 1
	argonMemory  = 64 * 1024 // 64 MiB
	argonThreads = 4
	argonKeyLen  = 32
	argonSaltLen = 16
)

// HashPassword returns an encoded argon2id hash (PHC-like string) for a password.
func HashPassword(password string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key),
	), nil
}

// VerifyPassword checks a password against an encoded argon2id hash in constant time.
func VerifyPassword(password, encoded string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false
	}
	var version, mem, time, threads int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil {
		return false
	}
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &mem, &time, &threads); err != nil {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, uint32(time), uint32(mem), uint8(threads), uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// NewToken returns a fresh random session token (the plaintext shown to the client)
// and its SHA-256 hash (what is stored server-side).
func NewToken() (token, hash string, err error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", "", err
	}
	token = base64.RawURLEncoding.EncodeToString(raw)
	return token, HashToken(token), nil
}

// HashToken returns the hex SHA-256 of a token, used to look up sessions without
// storing the plaintext token.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// NormalizePhone reduces a phone number to a canonical, digits-only comparable form for
// allowlist matching. All formatting (spaces, dashes, parentheses, '+') is stripped, and
// a default country code is applied to bare national numbers so the same person matches
// no matter how the number was written:
//
//	"+1 (415) 555-0148"  → "14155550148"
//	"(415) 555-0148"     → "14155550148"   (defaultCC "1" prepended)
//	"415-555-0148"       → "14155550148"
//	"+44 20 7946 0958"   → "442079460958"  (explicit '+' kept as-is)
//
// defaultCC is the calling code (e.g. "1"); pass "" to disable defaulting. A number
// written with a leading '+' is treated as already international and never altered.
func NormalizePhone(phone, defaultCC string) string {
	phone = strings.TrimSpace(phone)
	hadPlus := strings.HasPrefix(phone, "+")

	var b strings.Builder
	for _, r := range phone {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	digits := b.String()
	if digits == "" {
		return ""
	}
	if hadPlus || defaultCC == "" {
		return digits
	}
	// Bare 10-digit national number (US/Canada style) → prepend the default code.
	if len(digits) == 10 {
		return defaultCC + digits
	}
	// Otherwise assume the country code is already present (e.g. "14155550148").
	return digits
}
