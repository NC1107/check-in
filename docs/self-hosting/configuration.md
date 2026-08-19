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
| `CHECKIN_DATABASE_URL` | _(required)_ | Full PostgreSQL connection string. Set automatically by Compose from `POSTGRES_PASSWORD`; only set it yourself for a custom or external database. The server refuses to start without it rather than guessing a local one. |
| `CHECKIN_MEDIA_DIR` | `./data/media` (`/data/media` in the image) | Where uploaded images are stored. Backed by the `media_data` volume in Compose. |
| `CHECKIN_SESSION_TTL` | `720h` (30 days) | How long a login session stays valid. Accepts Go durations (e.g. `168h`, `720h`). |
| `CHECKIN_MAX_UPLOAD_BYTES` | `10485760` (10 MiB) | Maximum accepted size for an uploaded image. |
| `CHECKIN_MAX_VIDEO_BYTES` | `26214400` (25 MiB) | Maximum accepted size for an uploaded video clip. Clips are capped at 12 seconds server-side, so this mostly bounds how generous a bitrate the app may send. If you raise it, raise the reverse proxy's request body limit to match (`request_body max_size` in the `Caddyfile`), or uploads fail at the proxy before reaching the server. |
| `CHECKIN_TRUSTED_PROXY_HOPS` | `1` | How many reverse proxies sit directly in front of this server. Used to find the caller's real IP in the `X-Forwarded-For` chain for the login/signup rate limiter, at the position only that many trusted hops could have written - never a position a caller could forge by setting the header themselves. The standard Compose deployment is exactly one (Caddy; nothing else is exposed - see [security.md](security.md)) and that's the default. Only raise this if you put another reverse proxy of your own in front of Caddy (e.g. a corporate load balancer); fronting Caddy with Cloudflare or similar does **not** count, since Caddy is still the only hop that talks to this process directly. Getting it wrong in either direction either lets a caller spoof past the limiter again or throttles every member under one shared bucket. |

## Push notifications

Push works out of the box now, so most self-hosters don't need to configure anything here. This section explains how, and how to change it.

Push notifications go out through Firebase Cloud Messaging, which reaches Android directly and iOS through APNs.
FCM will only deliver to a device token that was minted against the *same* Firebase project the sending credentials belong to.
The Check-In apps published on the App Store and Google Play embed the maintainer's Firebase configuration, so every device running a published app mints its token against the maintainer's Firebase project.

That one fact decides how push works for you:

- **If your members use the published apps** (the normal case), only the maintainer's Firebase project can deliver to them, and your server cannot reach that project directly. So your server forwards notifications through a relay the maintainer runs. This is automatic and is the default.
- **If you build and ship your own app** with your own Firebase project compiled in, your server sends to FCM directly with your own credentials.

There are three options.

### 1. Relay through the maintainer (the default)

Out of the box your server forwards push through a small relay the maintainer runs at a fixed URL.
On its first boot the server registers itself with the relay, gets a scoped, revocable key, stores it, and reuses it on every boot after.
There is nothing to set up: a freshly started server whose members use the published apps just delivers notifications.

The relay holds the one Firebase credential the published apps were built against and forwards on your behalf.
It only ever sees a short notification title and body (for example "Alice shared a check-in") plus the device tokens to deliver to.
It never sees post content, photos, comments, phone numbers, or who is in your group, and it does not log the title, body, or tokens.

The tradeoff is that you are trusting the maintainer's relay with that short title and body in transit.
If that is not acceptable, use option 3 for full independence, or turn push off with option 2.

The maintainer cannot simply hand you the Firebase service-account JSON instead: that credential can send a notification to *any* Check-In device on *any* server, including other people's groups.
It is a master key, not a per-host one, which is exactly why the relay exists - so each host gets something scoped and revocable.

The relay will not paywall any feature and is free to use for as long as it stays cheap to run.
FCM itself costs nothing at any volume; if the relay's hosting ever becomes a real recurring cost, that will be stated plainly rather than quietly turned into a subscription.

On boot the server logs `push: relay via <url>`, so which mode you're in is never a mystery.

| Variable | Default | Description |
|----------|---------|-------------|
| `CHECKIN_RELAY_URL` | the maintainer's relay | Base URL of the relay to forward push through. Set it to an empty string to turn the relay off (option 2). Ignored when `CHECKIN_FCM_CREDENTIALS_FILE` is set, since that means the server sends directly. |

### 2. Push off

Set `CHECKIN_RELAY_URL` to an empty string, and leave `CHECKIN_FCM_CREDENTIALS_FILE` unset.
Everything else in Check-In works; members simply see new check-ins when they open the app.
The server logs `push: disabled (no FCM credentials and no relay URL)` on every boot.

Leaving the variable *unset* does not turn push off - unset means "use the default relay". You have to set it to an explicit empty value to opt out.

### 3. Bring your own Firebase (free, fully independent)

The only path with no dependency on the maintainer at all.
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
| `CHECKIN_FCM_CREDENTIALS_FILE` | *(empty)* | Path the server reads it from *inside* the container, e.g. `/run/secrets/fcm-service-account.json`. When set, the server sends directly through FCM and ignores the relay. |

On boot the server prints which Firebase project it is sending through, so you can confirm it matches the one your app was built against.
Using these variables **with the published app** puts you in the `SENDER_ID_MISMATCH` state: the published app's tokens belong to the maintainer's project, not yours, and every send fails while the server looks healthy.

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
