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
| `CHECKIN_SERVER_NAME` | `Check-In` | Friendly name shown to clients via `/api/server-info`. |
| `CHECKIN_HTTP_ADDR` | `:8080` | Address the API listens on inside the container. |
| `CHECKIN_DATABASE_URL` | `postgres://checkin:checkin@localhost:5432/checkin?sslmode=disable` | Full PostgreSQL connection string. Set automatically by Compose; only override for a custom/external database. |
| `CHECKIN_MEDIA_DIR` | `./data/media` (`/data/media` in the image) | Where uploaded images are stored. Backed by the `media_data` volume in Compose. |
| `CHECKIN_SESSION_TTL` | `720h` (30 days) | How long a login session stays valid. Accepts Go durations (e.g. `168h`, `720h`). |
| `CHECKIN_MAX_UPLOAD_BYTES` | `10485760` (10 MiB) | Maximum accepted size for an uploaded image. |

## Image version

| Variable | Default | Description |
|----------|---------|-------------|
| `CHECKIN_IMAGE` | `ghcr.io/nc1107/check-in:latest` | Which server image Compose runs. Pin to a release tag for reproducible upgrades, e.g. `ghcr.io/nc1107/check-in:v1.2.0`. See [operations.md](operations.md). |

## Storage volumes

`docker-compose.yml` defines four named Docker volumes. These hold all persistent state —
back them up (see [operations.md](operations.md)):

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
