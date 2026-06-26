<p align="center">
  <img src="docs/assets/banner.png" alt="Check-In" width="660">
</p>

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
go test ./...
CHECKIN_DATABASE_URL=postgres://checkin:checkin@localhost:5432/checkin?sslmode=disable \
  go run ./cmd/server

# App
cd app
flutter pub get
flutter run            # against a running server; enter its URL on first launch
```

