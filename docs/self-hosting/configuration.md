# Configuration

All configuration is through environment variables, set in your `.env` file (which
`docker compose` reads automatically). Start from `.env.example`.

## Required

| Variable | Description |
|----------|-------------|
| `CHECKIN_DOMAIN` | The domain/subdomain pointed at this server (e.g. `check-in.example.com`). Caddy provisions a Let's Encrypt TLS certificate for it. |
| `POSTGRES_PASSWORD` | The PostgreSQL password. Use a long random string (e.g. `openssl rand -base64 32`). |

## Database

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | `checkin` | PostgreSQL username. |
| `POSTGRES_DB` | `checkin` | PostgreSQL database name. |

The server's `CHECKIN_DATABASE_URL` is assembled from these in `docker-compose.yml`, so
you normally don't set it directly when using Compose.

## Server

These are read by the Go server (defaults defined in `server/internal/config/config.go`).
Under Compose, sensible values are already wired up; override only if you need to.

| Variable | Default | Description |
|----------|---------|-------------|
| `CHECKIN_SERVER_NAME` | `Check-In` | Initial group name, seeded into the database on first boot. After that, an admin renames the group in-app (Settings → Group name) and that stored name is what clients see via `/api/server-info` and in push titles; changing this variable later has no effect once a name is set. |
| `CHECKIN_PUBLIC_URL` | *(empty)* | This server's public base URL (e.g. `https://alpha.check-in.example.com`). Surfaced via `/api/server-info` and stamped into push payloads so an app connected to several servers can attribute notifications. Set automatically by the multi-group generator; optional for single-group installs. |
| `CHECKIN_HTTP_ADDR` | `:8080` | Address the API listens on inside the container. |
| `CHECKIN_DATABASE_URL` | `postgres://checkin:checkin@localhost:5432/checkin?sslmode=disable` | Full PostgreSQL connection string. Set automatically by Compose; only override for a custom/external database. |
| `CHECKIN_MEDIA_DIR` | `./data/media` (`/data/media` in the image) | Where uploaded images are stored. Backed by the `media_data` volume in Compose. |
| `CHECKIN_SESSION_TTL` | `720h` (30 days) | How long a login session stays valid. Accepts Go durations (e.g. `168h`, `720h`). |
| `CHECKIN_MAX_UPLOAD_BYTES` | `10485760` (10 MiB) | Maximum accepted size for an uploaded image. |

## Push notifications

**Read this before setting up push.** Push is the one part of Check-In you cannot fully self-host today, and the reason is not obvious.

Push notifications go out through Firebase Cloud Messaging, which reaches Android directly and iOS through APNs.
FCM will only deliver to a device token that was minted against the *same* Firebase project the sending credentials belong to.
The Check-In apps published on the App Store and Google Play embed the maintainer's Firebase configuration, so every device running a published app mints its token against the maintainer's Firebase project.

The consequence: **if you point your server at your own Firebase service account, every send fails.**
FCM rejects each one with `SENDER_ID_MISMATCH`, your members get nothing, and your server otherwise looks perfectly healthy.
This is not a bug in your setup, and no amount of configuration fixes it.

There are three honest options.

### 1. Push off (the default)

Leave `CHECKIN_FCM_CREDENTIALS_FILE` unset.
Everything else in Check-In works; members simply see new check-ins when they open the app.
The server logs `push: disabled (no FCM credentials)` on every boot so this is never a mystery.

### 2. Relay through the maintainer (planned)

A small relay service, operated by the maintainer, that holds the Firebase credential and accepts sends from your server using a per-server key.
Your server keeps its data; the relay only ever sees a short title and body (never post content, photos, or comments) plus the device tokens to deliver to.

This does not exist yet.
If you want it, [open an issue](https://github.com/NC1107/check-in/issues) saying so and you will get a key when it ships.

The maintainer cannot simply email you the Firebase service-account JSON instead: that credential grants permission to send a notification to *any* Check-In device on *any* server, including other people's groups.
It is a master key, not a per-host one.
The relay exists precisely so hosts can be given something scoped and revocable.

In keeping with the project's approach, the relay will not paywall any feature and will be free to use for as long as it stays cheap to run.
FCM itself costs nothing at any volume; if the relay's hosting ever becomes a real recurring cost, that will be stated plainly rather than quietly turned into a subscription.

### 3. Bring your own Firebase (free, fully independent)

The only path that gives you working push with no dependency on the maintainer at all.
It requires **building and distributing the app yourself**, because the Firebase project is compiled into the app binary:

1. Create your own Firebase project and register an Android and/or iOS app in it.
2. Replace `app/android/app/google-services.json` and `app/ios/Runner/GoogleService-Info.plist` with yours.
3. For iOS, upload an APNs key to your Firebase project.
4. Build the app and distribute it to your members, sideloaded or through your own store listing.
   On iOS this means your own Apple Developer account and your own App Review submission.
5. Point the server at a service-account JSON from that same Firebase project:

| Variable | Default | Description |
|----------|---------|-------------|
| `CHECKIN_FCM_CREDENTIALS_HOST` | *(empty)* | Path on the host to your Firebase service-account JSON, mounted read-only into the container. |
| `CHECKIN_FCM_CREDENTIALS_FILE` | *(empty)* | Path the server reads it from *inside* the container, e.g. `/run/secrets/fcm-service-account.json`. Unset disables push. |

On boot the server prints which Firebase project it is sending through, so you can confirm it matches the one your app was built against.

Using these variables **with the published app** puts you in the broken state described above.

## Image version

| Variable | Default | Description |
|----------|---------|-------------|
| `CHECKIN_IMAGE` | `ghcr.io/nc1107/check-in:latest` | Which server image Compose runs. Pin to a release tag for reproducible upgrades, e.g. `ghcr.io/nc1107/check-in:v1.2.0`. See [operations.md](operations.md). |

## Storage volumes

`docker-compose.yml` defines four named Docker volumes. These hold all persistent state,
so back them up (see [operations.md](operations.md)):

| Volume | Holds |
|--------|-------|
| `db_data` | The PostgreSQL database (accounts, posts, comments, allowlist). |
| `media_data` | Uploaded images (posts + profile pictures). |
| `caddy_data` | TLS certificates and Caddy state. |
| `caddy_config` | Caddy's autosaved configuration. |

## Example `.env`

```ini
CHECKIN_DOMAIN=check-in.example.com
CHECKIN_SERVER_NAME=My Crew

POSTGRES_USER=checkin
POSTGRES_PASSWORD=Qb3...long-random...x9
POSTGRES_DB=checkin

# Optional: pin a specific released version instead of :latest
# CHECKIN_IMAGE=ghcr.io/nc1107/check-in:v1.2.0
```
