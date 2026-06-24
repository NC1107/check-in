# Operations (Day 2)

Running your server over time: upgrades, logs, backups, and restores. All commands run
from the directory containing `docker-compose.yml`.

## Checking status

```bash
docker compose ps                 # container status
curl https://YOUR_DOMAIN/api/health   # {"status":"ok"}
```

## Viewing logs

```bash
docker compose logs -f server     # the API server
docker compose logs -f caddy      # TLS / reverse proxy (cert issues show here)
docker compose logs -f db         # PostgreSQL
```

## Upgrading

Releases are published automatically to the GitHub Container Registry.

**Track the latest** (simplest):

```bash
git pull                          # get any compose/Caddyfile changes
docker compose pull               # fetch the newest server image
docker compose up -d              # recreate changed containers
```

Database migrations run automatically on server startup, so there's no separate migrate
step.

**Pin a specific version** (recommended for predictability): set `CHECKIN_IMAGE` in
`.env` to a release tag, then re-up:

```ini
CHECKIN_IMAGE=ghcr.io/nc1107/check-in:v1.2.0
```
```bash
docker compose up -d
```

Browse available tags on the repository's Releases / Packages page.

## Backups

Your important state is in two volumes: **`db_data`** (the database) and
**`media_data`** (uploaded images). Back up both.

### Database

```bash
# Dump to a file (run from the compose directory)
docker compose exec -T db pg_dump -U checkin checkin > checkin-db-$(date +%F).sql
```

For a compressed custom-format dump (smaller, restorable with `pg_restore`):

```bash
docker compose exec -T db pg_dump -U checkin -Fc checkin > checkin-db-$(date +%F).dump
```

### Media

Copy the contents of the media volume:

```bash
docker run --rm \
  -v check-in_media_data:/media \
  -v "$PWD":/backup \
  alpine tar czf /backup/checkin-media-$(date +%F).tar.gz -C /media .
```

> The volume name is prefixed with the Compose project (the folder name), usually
> `check-in_media_data`. Confirm with `docker volume ls`.

Automate by putting these in a nightly `cron` job and copying the output off-server.

## Restoring

### Database

From a plain SQL dump:

```bash
docker compose exec -T db psql -U checkin -d checkin < checkin-db-2025-01-01.sql
```

From a custom-format dump:

```bash
cat checkin-db-2025-01-01.dump | docker compose exec -T db pg_restore -U checkin -d checkin --clean --if-exists
```

### Media

```bash
docker run --rm \
  -v check-in_media_data:/media \
  -v "$PWD":/backup \
  alpine sh -c "cd /media && tar xzf /backup/checkin-media-2025-01-01.tar.gz"
```

## Restarting / stopping

```bash
docker compose restart server     # restart just the API
docker compose down               # stop everything (volumes are preserved)
docker compose up -d              # start again
```

`docker compose down` does **not** delete named volumes, so your data is safe. Avoid
`docker compose down -v`, which **would** delete the volumes and all data.

---

See also [troubleshooting.md](troubleshooting.md) and [security.md](security.md).
