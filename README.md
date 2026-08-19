<p align="center">
  <img src="docs/assets/banner.png" alt="Check-In" width="660">
</p>

<!-- social-badges:start -->
<p align="center">
  <a href="https://discord.gg/jUMuSxGf6q"><img src="https://img.shields.io/badge/Discord-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
  <a href="https://github.com/NC1107"><img src="https://img.shields.io/badge/GitHub-181717?logo=github&logoColor=white" alt="GitHub"></a>
  <a href="https://patreon.com/NPC1107"><img src="https://img.shields.io/badge/Patreon-F96854?logo=patreon&logoColor=white" alt="Patreon"></a>
</p>
<!-- social-badges:end -->

My solution for a way to check in with friends without selling my soul to monopolies
or getting stuck doomscrolling. As the admin you whitelist your people by giving the app access to selected contacts.
It stores their numbers on **your** server, and those people can sign up once you've
given them the server address. 

## How it works

- **One person self-hosts the server** (Docker). The **first user to sign up becomes the
  admin**.
- The admin's selected **contacts become the allowlist**. A friend installs the app,
  enters the server address, and signs up with a phone number that's on the list.
- Share a photo + caption or a quick text update, then close the app. Later, scroll the
  chronological feed or **filter to one person** to see a timeline of what they've been
  up to. Like and comment.
- **Birthday reminders** fire on-device — the app notes friends' birthdays and nudges you
  on the day so you can check in.

## Quick start (self-host the server)

```bash
cp .env.example .env          # set POSTGRES_PASSWORD and CHECKIN_DOMAIN
docker compose up -d --build
```

The first account created on a fresh server becomes the admin. For production
self-hosting (DNS, HTTPS, backups, upgrades) see the
**[self-hosting guide](docs/self-hosting/README.md)**.

One host can also run **several independent groups** (one container + database per
group, each on its own subdomain) — see
[multiple groups](docs/self-hosting/multiple-groups.md).

## Tech stack

| Concern       | Choice                                             |
|---------------|----------------------------------------------------|
| Backend       | Go 1.24, chi router, pgx, hand-written SQL         |
| Database      | PostgreSQL 16 (embedded migrations run at startup) |
| Media         | Local volume; images re-encoded (EXIF stripped)    |
| Auth          | Phone + password (argon2id), opaque session tokens |
| TLS           | Caddy reverse proxy, automatic Let's Encrypt       |
| App           | Flutter, Riverpod, dio                             |
| Notifications | On-device local notifications                      |

## Repository layout

```
server/   Go + PostgreSQL API (single static binary, Docker image)
app/      Flutter app (iOS + Android)
docs/     Self-hosting guide and setup notes
docker-compose.yml + Caddyfile   The self-hosted stack (Postgres + server + Caddy TLS)
```

## Develop

```bash
# Backend
cd server
scripts/test.sh        # the real suite: unit + DB-backed handler tests, with -race
CHECKIN_DATABASE_URL=postgres://checkin:checkin@localhost:5432/checkin?sslmode=disable \
  go run ./cmd/server

# App
cd app
flutter pub get
flutter run            # against a running server; enter its URL on first launch
```

Most of the Go suite drives the real HTTP handlers against a real PostgreSQL.
`scripts/test.sh` starts a throwaway database, runs everything with `-race`, and removes it again; it passes any arguments through to `go test`, so `scripts/test.sh ./internal/api/ -run TestFeed -v` works as expected.

A bare `go test ./...` **refuses to run** rather than silently skipping those tests.
They used to skip themselves when `TESTDB_URL` was unset, which meant a plain run printed a reassuring `ok` while the large majority of the suite never executed - that is how a real scan-order bug once survived a clean local run.
If you genuinely have no Docker, say so explicitly and accept the reduced coverage:

```bash
CHECKIN_SKIP_DB_TESTS=1 go test ./...
```

CI supplies its own database as a service container, so it always runs the full suite.

