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

// phoneMatchKeyPrefix namespaces PhoneMatchKey's hash so it doesn't collide with a generic
// sha256(phone) computed for some unrelated purpose. It is not a secret - the source is
// public - so it raises no real barrier on its own; see PhoneMatchKey's doc comment.
const phoneMatchKeyPrefix = "checkin-phone-match:"

// PhoneMatchKey derives a stable, non-secret identity key for an already-normalized phone
// number: the hex SHA-256 of it. It exists for the one legitimate reason a peer's phone
// number reaches the wire at all - the app's multi-group client-side join, which merges the
// same human's accounts across the several groups a device is signed into by comparing
// whether two accounts share a number (app/lib/state/person_directory.dart). Two peer views
// agreeing on PhoneKey still means "same phone", so that join keeps working, without handing
// back the number itself - which in this invite-only app doubles as the invite credential
// (see docs/self-hosting/security.md) and must not be bulk-readable by an ordinary member.
//
// This is the same tradeoff phone-number contact discovery makes elsewhere (Signal,
// WhatsApp): it stops a trivial bulk read, but a phone number is a small enough keyspace
// that a determined attacker who knows the algorithm - it's open source - could still brute
// force one back out of its hash offline. It raises the bar; it is not a strong guarantee,
// and callers must not treat a PhoneKey as safe to hand to just anyone regardless.
func PhoneMatchKey(phone string) string {
	sum := sha256.Sum256([]byte(phoneMatchKeyPrefix + phone))
	return hex.EncodeToString(sum[:])
}

// resetCodeAlphabet has 32 unambiguous characters (no 0/O, 1/I/L) so a recovery code is
// easy to read aloud and type. 32 divides 256 evenly, so the byte→char map is unbiased.
const resetCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// NewResetCode returns a short, human-relayable recovery code (uppercase). Hash it with
// HashPassword before storing.
func NewResetCode() (string, error) {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	out := make([]byte, len(buf))
	for i, b := range buf {
		out[i] = resetCodeAlphabet[int(b)%len(resetCodeAlphabet)]
	}
	return string(out), nil
}

// NormalizeResetCode upper-cases and strips spaces/dashes so the code matches however the
// user typed it.
func NormalizeResetCode(code string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(code) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// NormalizePassword trims surrounding whitespace from a password. Leading or trailing
// spaces and newlines are never intentional and are a common copy-paste artifact (a
// credential copied with a trailing space or newline). Applying this symmetrically at
// signup, login, and reset means a stray whitespace character can't cause a spurious
// authentication failure, mirroring how NormalizePhone canonicalizes the phone.
func NormalizePassword(password string) string {
	return strings.TrimSpace(password)
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
