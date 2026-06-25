# Technical Debt & Audit Findings

Last updated: 2026-06-25 (full backend + Flutter audit)

Overall the codebase is in good shape: argon2id password hashing with constant-time
verify, opaque SHA-256-hashed session tokens with server-side expiry + status checks,
fully parameterized SQL (no injection), 1 MiB JSON body caps with `DisallowUnknownFields`,
per-IP auth rate limiting with idle eviction, server-side image re-encode that strips
EXIF/GPS, and a sensible secure-headers/CSP baseline. The items below are the gaps found.

## Summary
**Fixed in this pass: 6 · Remaining (documented): 5** — Critical: 0 · High: 0 · Medium: 1 · Low: 4

---

## Fixed in this audit

- **[security/medium] Image "pixel bomb" DoS** — `server/internal/storage/storage.go`
  `image.Decode` allocated a buffer proportional to declared W×H, so a few KB of input
  could request gigabytes of memory. Now rejects via `image.DecodeConfig` + a 50 MP cap
  before decoding.
- **[security/medium] Upload disk-exhaustion DoS** — `server/internal/api/media_handlers.go:15`
  `ParseMultipartForm` spooled the whole request to a temp file before the size check.
  Now wrapped in `http.MaxBytesReader` so oversized uploads are rejected early.
- **[standards] Formatting not enforced** — 2 Go files + 15 Dart files were not
  formatter-clean. Ran `gofmt`/`dart format` (100-col, set in `analysis_options.yaml`) and
  added CI gates (`gofmt -l`, `dart format --set-exit-if-changed`) so it can't drift again.
- **[hygiene] Stray files committed** — removed `play-review.md` / `tf-testers.md`
  (leftover Playwright snapshots) and gitignored `.playwright-mcp/`.
- **[security] Media IDOR — fixed** — `handleServeMedia` now uses `GetVisibleMedia`, which
  only serves media the requester owns, that's attached to a post, or that's a profile
  photo (404 otherwise). Closes enumeration of others' unposted uploads / deleted-post media.
- **[testing] Coverage raised** — added pure unit tests (no DB needed, so they run in CI):
  rate limiter, signup display-name derivation, image DoS guards (Go); plus Flutter model
  tests (post location, invite) and widget tests (UserAvatar, AppTextField, PrimaryButton).
  DB-backed HTTP handler/integration tests are still a gap (see below).

---

## Remaining (documented)

### Medium
- **[testing] No DB-backed handler/integration tests** — the new tests cover pure logic and
  widgets, but the HTTP handlers (signup/login/feed/post flows) aren't exercised end-to-end.
  *Fix:* stand up a throwaway Postgres in CI (service container) and add httptest-based
  handler tests. Effort: large.
- **[performance] Feed correlated subqueries** — `server/internal/db/queries.go` `Feed`
  runs 4 per-row subqueries (like count, comment count, liked-exists, comment preview).
  Fine at current scale; revisit with JOINs/aggregates if the feed grows. Effort: medium.

### Low
- **[security] Content endpoints unthrottled** — only auth endpoints are rate-limited;
  `POST /api/posts`, `/comments`, `/like`, `/media` are not. Trusted group → low risk; add
  a per-user limiter if the tester pool widens. Effort: small.
- **[maintenance] Expired sessions never purged** — expiry is enforced on read (no security
  impact), but `sessions` rows accumulate. Add a periodic cleanup or prune on login.
  Effort: small.
- **[maintenance] Orphan media** — an upload followed by a failed `createPost` leaves an
  unreferenced media row + file. Add a sweep or make upload+post transactional. Effort: small.
- **[hardening] Rate-limit IP trust** — `rateLimitAuth` trusts `X-Real-IP`; correct behind
  the Caddy/Traefik proxy, but ensure the server is never exposed directly. Effort: n/a (ops).

## Progress tracking
- [x] Image pixel-bomb DoS
- [x] Upload disk-exhaustion DoS
- [x] Formatting + CI gates
- [x] Stray-file cleanup
- [x] Media IDOR (per-resource authz)
- [x] Unit + widget test coverage (pure-logic + widgets)
- [ ] DB-backed handler/integration tests
- [ ] Feed query optimization
- [ ] Content-endpoint throttling
- [ ] Expired-session cleanup
- [ ] Orphan-media cleanup
