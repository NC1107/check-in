# Technical Debt & Audit Findings

Last updated: 2026-08-15 (stabilization pass; resolved + remaining items below)

Overall the codebase is in good shape: argon2id password hashing with constant-time
verify, opaque SHA-256-hashed session tokens with server-side expiry + status checks,
fully parameterized SQL (no injection), 1 MiB JSON body caps with `DisallowUnknownFields`,
per-IP auth rate limiting with idle eviction, server-side image re-encode that strips
EXIF/GPS, and a sensible secure-headers/CSP baseline. The items below are the gaps found.

## Summary
**Fixed in 2026-06-25 pass: 6 · Resolved since: 5 · Remaining (documented): 4** - Critical: 0 · High: 0 · Medium: 1 · Low: 3

---

## Fixed 2026-08-15 (stabilization pass)

- **[testing/medium] No DB-backed handler/integration tests - done** - every `internal/api` test
  was a pure helper test, so the HTTP handlers had no end-to-end coverage at all.
  `server/internal/api/harness_test.go` now stands up the production router (`api.New(...).Router()`)
  in front of a real `db.DB`, applies the embedded migrations, and hands tests helpers for
  members, JSON calls, multipart uploads and stored-file assertions.
  Isolation is a catalog-driven `TRUNCATE ... RESTART IDENTITY CASCADE` between tests rather
  than a rolled-back transaction, because the handlers open their own transactions through the
  shared pool and there is no outer transaction to wrap them in.
  The suite skips itself unless `TESTDB_URL` is set, so a local `go test ./...` needs no
  database; CI supplies a `postgres:16` service container in both `ci.yml` and `release.yml`.
  First wave in `server/internal/api/integration_test.go`: the signup allowlist gate and
  first-admin bootstrap, the signup `mediaId` rejection, login/logout and 401 handling, the
  post-with-media contract end to end (typed array plus the legacy `mediaIds`/`kind`/cover a
  published client reads), cross-post id and video kind derivation, upload validation
  (oversize, over-length clip, non-media), media serving (Range 206, `?variant=poster` 404
  when absent, IDOR on an unposted upload), orphaned clip *and poster* removal on delete,
  block filtering across feed and direct link, and the public `/join` page's headers.
- **[security/low] Content endpoints unthrottled - done** - only the auth endpoints had a
  limiter, so `POST /api/posts`, `/comments`, `/like` and `/media` were bounded by nothing but
  the body-size cap. `contentLimits` (`server/internal/api/ratelimit.go`) adds a bucket per
  action, keyed per USER rather than per IP: these routes are authenticated, and a household
  behind one address must not share a posting budget. 30 posts/min (burst 10), 60 comments/min
  (burst 20), 60 likes/min (burst 30), 30 uploads/min (burst 20 - a ten-clip check-in is twenty
  requests, each clip plus its poster, so a smaller burst would reject a post the app let the
  member build). The limits stop automation rather than pacing anyone, and a drained bucket
  refills continuously, so the app recovers on its own.

---

## Fixed 2026-07-07 (pre-Apple-review copy + consistency audit)

Inline multi-domain review (Apple readiness, Go backend, Flutter correctness, copy/UX)
ahead of a fresh App Review submission. Backend + client state logic verified clean:
routes gated correctly (`handleUpdateServer` under `requireAdmin`), account deletion is
transactional and complete with every `REFERENCES users(id)` set `ON DELETE CASCADE` (no
FK-violation risk on the Apple-critical 5.1.1(v) path), block filtering threaded through
feed/search/comments/detail, phone-merge (`PersonDirectory`) and feed merge race-safe.
Terms screen scrolls (Guideline 4), report/block/delete all reachable. Fixes applied:

- **[copy] Em-dashes in user-facing strings** - 12 user-visible strings used "—" against the
  house style ("-"): `feed_screen.dart`, `home_shell.dart`, `profile_screen.dart`,
  `contacts_picker_screen.dart`, `auth_screen.dart`, `admin_screen.dart`,
  `notification_settings_screen.dart`, `birthday_notifier.dart`. Plus two server validation
  errors surfaced in-app used en-dashes (`"1–40"/"1–100"`, `auth_handlers.go`). All normalized;
  55 comment em/en-dashes across 19 Dart files also normalized to keep the rule blanket.
- **[copy/consistency] Role term "admin" vs "host"** - the app uses "host" everywhere (badge,
  reset-password, onboarding) but moderation + terms copy said "the admin"/"the server admin".
  Repointed to "the host" in `post_card.dart` (report sheet + snackbar) and `terms_screen.dart`
  (3 sections), so the person a user is told will act on reports matches the role they've seen.
- **[copy/consistency] "server" leaking into social copy** - `NSContactsUsageDescription` said
  "invite to your server" → "your group"; terms said "the server admin" (above).
- **[apple] Misleading permission string** - `NSUserNotificationUsageDescription` promised
  "notifications for new messages" though the app has no messaging → "new check-ins and activity"
  (a reviewer reads this; it must match shipped features).
- **[copy] Smart quotes** - 3 strings used curly `'`/`'` while the rest use straight `'`
  (`admin_screen.dart`, `terms_screen.dart`, `auth_screen.dart`); normalized.

`flutter analyze` clean, `flutter test` green (74). Client changes ship via the release build;
the two Go string edits deploy via CI + watchtower. Open product-voice calls (onboarding
"server"-noun in the connect/setup flow; "post" vs "check-in" in moderation UI) tracked below.

---

## Fixed 2026-07-06 (safety-hardening audit of the App Store block/report/delete features)

- **[security/safety/medium] Blocking only filtered the feed** - the blocked-author exclusion
  lived only in `Feed`. `ListComments`, the inline comment-preview expr, `SearchPosts`, and
  `GetPost` (`server/internal/db/queries.go`) ignored blocks, so a blocked abuser's comments
  still showed everywhere and their posts stayed reachable via search + direct link. Threaded
  the block exclusion (and viewer id) through all of them; `handleListComments` now passes the
  viewer.
- **[correctness/moderation/medium] Sole admin could delete themselves and brick moderation**
  - `handleDeleteAccount` had no last-admin guard, so the only admin deleting their account
  left a server no one could administer (`server_config.initialized` stays true, so no new
  first-admin is created). Added `OtherAdminExists` + a `409` guard requiring the admin to
  promote someone first.
- **[robustness/low] Report/block on a missing target 500'd; report had no length cap or dedup**
  - `handleReportPost`/`handleBlockUser` now verify the target exists (`404` instead of an FK
  `500`), cap the reason at 1000 chars, and dedupe via `ON CONFLICT DO NOTHING` backed by new
  unique partial indexes (migration `0010_report_dedup.sql`).
- **[hygiene/low] Dead `ReportComment` query wired up** - added `POST /api/comments/{id}/report`
  (`handleReportComment`) with the same validation, so comment reporting is reachable (the
  admin report list + DB already supported it). Comments are the main harassment channel.

All server-side; deploys via CI + watchtower with no App Review impact. `go build`/`vet`/`test`
green; `gofmt` clean.

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

## Resolved since the audit (2026-06-26)

- **[maintenance] Expired-session cleanup — done** — `cmd/server/main.go:83` runs an hourly
  `DELETE FROM sessions WHERE expires_at < now()` goroutine. (Previously listed as Remaining.)
- **[bug/perf] Photo-upload OOM crash — fixed** — the upload handler rotated the
  full-resolution image for EXIF orientation *before* downscaling, allocating ~190 MB RGBA
  buffers that OOM-killed the 256 MB container mid-request (clients saw the generic "check
  your connection"). Now downscales first (`server/internal/storage/storage.go`); container
  memory limit raised 256 M → 512 M (`docker-compose.yml` + prod).
- **[bug] iPhone HEIC uploads — fixed** — the server only decodes JPEG/PNG/GIF, so HEIC
  photos failed outright. The app now downscales + transcodes to JPEG client-side before
  upload (`flutter_image_compress`), which also keeps the server off the full-res decode path.

---

## Remaining (documented)

### Medium
- **[performance] Feed correlated subqueries** — `server/internal/db/queries.go` `Feed`
  runs 4 per-row subqueries (like count, comment count, liked-exists, comment preview).
  Fine at current scale; revisit with JOINs/aggregates if the feed grows. Effort: medium.

### Low
- **[maintenance] Orphan media** — an upload followed by a failed `createPost` leaves an
  unreferenced media row + file (cleanup only runs via `DeletePost`; nothing reclaims an
  upload that never became a post). Add a periodic sweep or make upload+post transactional.
  Effort: small.
- **[feature] Global search not paginated** — `app/lib/features/feed/global_search_delegate.dart:47`
  calls `_api.search(query)` once with no cursor, while the server `Feed` query already
  supports `before`/`beforeID`. Add a `ScrollController` + load-more mirroring
  `feed_screen.dart:172`. Effort: medium.
- **[a11y] Tap targets lack Semantics** — bare `GestureDetector` wrappers without `Semantics`
  labels at `feed_screen.dart:428,483,490` and `post_card.dart:370`; screen readers can't
  announce them as buttons. Wrap in `Semantics(button: true, label: …)`. Effort: small.
- **[hardening] Rate-limit IP trust** — `rateLimitAuth` trusts `X-Real-IP`; correct behind
  the Caddy/Traefik proxy, but ensure the server is never exposed directly. Effort: n/a (ops).

## Progress tracking
- [x] Image pixel-bomb DoS
- [x] Upload disk-exhaustion DoS
- [x] Formatting + CI gates
- [x] Stray-file cleanup
- [x] Media IDOR (per-resource authz)
- [x] Unit + widget test coverage (pure-logic + widgets)
- [x] Expired-session cleanup (hourly goroutine, main.go:83)
- [x] Photo-upload OOM crash fix (downscale-before-orient + 512M)
- [x] iPhone HEIC upload fix (client-side transcode)
- [x] DB-backed handler/integration tests
- [ ] Feed query optimization
- [x] Content-endpoint throttling
- [ ] Orphan-media cleanup
- [ ] Global search pagination
- [ ] Tap-target Semantics (a11y)
