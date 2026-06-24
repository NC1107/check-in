# Check-In

A simple, private, self-hosted way to keep up with friends. Think a stripped-down
Instagram + Twitter: share a photo with a caption or a quick text update, then close the
app. Later, scroll the chronological feed or filter to one person to see a
git-history-style timeline of what they've been up to. Like and comment. No reels, no
ads, no algorithm.

## How it works

- **One person self-hosts the server** (Docker). The **first user to sign up becomes the
  admin** and is prompted to share their phone contacts.
- Those contact phone numbers become the **allowlist**. A friend installs the app, enters
  the server address the admin gave them, and signs up just by entering a phone number
  that's on the list — **the phone number is the invite/access code** (no SMS codes).
- Signup collects name, birthday, password, and an optional profile picture.
- **Birthday reminders** are scheduled on-device (no cloud push needed): the app syncs
  friends' birthdays when opened and notifies you on the day so you can check in.

## Repository layout

```
server/   Go + PostgreSQL API (single static binary, Docker image)
app/       Flutter app (iOS + Android)
.github/   CI (PRs) and Release (on push to main) pipelines
docs/      Self-hosting guide (docs/self-hosting/) + release/CI setup
docker-compose.yml + Caddyfile   The self-hosted stack (Postgres + server + Caddy TLS)
```

## Tech stack

| Concern        | Choice                                             |
|----------------|----------------------------------------------------|
| Backend        | Go 1.24, chi router, pgx, hand-written SQL         |
| Database       | PostgreSQL 16 (embedded migrations run at startup) |
| Media          | Local volume; images re-encoded (EXIF stripped)    |
| Auth           | Phone + password (argon2id), opaque session tokens |
| TLS            | Caddy reverse proxy, automatic Let's Encrypt       |
| App            | Flutter, Riverpod, dio                              |
| Notifications  | On-device local notifications                       |

## Run the server locally

```bash
cp .env.example .env          # set POSTGRES_PASSWORD and CHECKIN_DOMAIN
docker compose up -d --build
```

The first account created on a fresh server becomes the admin. For production
self-hosting (DNS, HTTPS, backups, upgrades) see the
**[self-hosting guide](docs/self-hosting/README.md)**. For the CI/CD and app-store
release setup see [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Develop the backend

```bash
cd server
go test ./...
CHECKIN_DATABASE_URL=postgres://checkin:checkin@localhost:5432/checkin?sslmode=disable \
  go run ./cmd/server
```

## Develop the app

```bash
cd app
flutter pub get
flutter run            # against a running server; enter its URL on first launch
```

## Releases

Every commit to `main` triggers `.github/workflows/release.yml`, which bumps the version
from [conventional commits](https://www.conventionalcommits.org/), publishes the server
image to `ghcr.io/nc1107/check-in`, builds the apps, creates a GitHub Release with the
Android APK, and (once store secrets are configured) ships to Google Play and TestFlight.
