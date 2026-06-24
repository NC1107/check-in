# Troubleshooting

Fixes for the most common problems. Start by checking logs:

```bash
docker compose ps
docker compose logs -f caddy    # TLS / proxy
docker compose logs -f server   # API
docker compose logs -f db       # database
```

## HTTPS certificate won't issue

Symptoms: the app/browser shows a TLS error, or `caddy` logs show ACME/Let's Encrypt
failures.

- **DNS not pointed correctly.** Confirm your domain resolves to the server's public IP:
  `dig +short check-in.example.com`. It must return your server's IP.
- **Ports 80/443 not reachable.** Let's Encrypt validates over port 80. Make sure both
  are open in your firewall and (for home setups) forwarded to the server. Test from
  outside: `curl -I http://check-in.example.com`.
- **`CHECKIN_DOMAIN` wrong or unset.** It must exactly match the hostname in DNS. Check
  `.env`, then `docker compose up -d` to apply.
- **Rate limited.** If you restarted many times, Let's Encrypt may briefly rate-limit.
  Wait, or use their staging environment while testing.

## The app says it can't reach the server

- Test the API directly: `curl https://check-in.example.com/api/health` should return
  `{"status":"ok"}`.
- Make sure you typed the full URL including `https://` in the app's connect screen.
- If `/api/health` works from a browser but not the app, check that you're not on a
  network that blocks the domain, and that the certificate is valid (no TLS warning in a
  browser).

## `server` container keeps restarting

Usually it can't reach the database. Check `docker compose logs server`.

- Wait a moment on first boot — the server waits for PostgreSQL to become healthy.
- Confirm `POSTGRES_PASSWORD` is set in `.env` (the DB container refuses to start without
  it) and that you didn't change it after the volume was first created. If you changed
  the password after first run, the existing `db_data` volume still has the old one —
  either set it back, or reset the database (destroys data): `docker compose down` then
  remove the volume.

## `db` is unhealthy / "connection refused"

- `docker compose logs db` will show the cause. A common one is a previously
  initialized volume with a different password (see above).
- Ensure nothing else on the host is using the same internal resources; the DB is not
  meant to be published to the host — don't add a `ports:` mapping for it.

## Contacts upload added 0 numbers

- Grant the app **Contacts** permission when prompted (re-enable in your phone's app
  settings if you denied it).
- Contacts without any phone number are skipped. The upload response reports
  `received`, `valid`, and `added` counts.
- Numbers already on the list aren't re-added, so a second upload may legitimately add 0.

## A friend can't sign up ("not on the invite list")

- The number they're entering must match an uploaded contact after normalization (see
  the matching note in [security.md](security.md)). Watch for a missing/extra country
  code (`+1`).
- If they already registered once, the number is marked used — they should **log in**
  instead. If they need a fresh start, remove them from the Admin tab and re-upload.

## 502 Bad Gateway

Caddy is up but can't reach the server container.

- `docker compose ps` — is `server` running and healthy?
- `docker compose logs server` for a startup error (often a DB connection problem).
- `docker compose restart server`.

## Still stuck?

Collect `docker compose logs` output and open an issue on the repository with your
symptoms, what you've tried, and the relevant log lines (redact secrets).
