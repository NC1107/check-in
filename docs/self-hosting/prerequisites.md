# Prerequisites

Before you install Check-In, get these in place.

## A Linux server

Any machine that can run Docker 24/7 and is reachable from the internet: a small cloud
VPS (DigitalOcean, Hetzner, Linode, etc.), a home server, or a Raspberry Pi.

Check-In is lightweight — it's a single Go binary plus PostgreSQL and Caddy.

| Friend-group size | Suggested specs |
|-------------------|-----------------|
| Up to ~50 people  | 1 vCPU, 1 GB RAM, 10 GB disk |
| ~50–500 people    | 2 vCPU, 2 GB RAM, 25 GB+ disk |

Disk grows mainly with uploaded photos. Images are downscaled (max 1600px) and
re-encoded on upload, so they stay modest, but budget for them over time.

## Docker + Docker Compose

Install Docker Engine and the Compose plugin:

```bash
curl -fsSL https://get.docker.com | sh
docker compose version   # confirm the Compose plugin is available
```

## A domain or subdomain

You need a hostname pointed at your server so Caddy can issue a trusted HTTPS
certificate. A subdomain is perfect, e.g. `check-in.example.com`.

Using a real domain (rather than a bare IP address) matters: it lets the server get a
**trusted** Let's Encrypt certificate, so the mobile app connects with no certificate
warnings or special configuration.

## DNS

Create an **A record** pointing your hostname at the server's **public IP**:

```
check-in.example.com.   A   203.0.113.45
```

If your server is behind a home router, also forward ports 80 and 443 to it, and use
your public IP. DNS changes can take a few minutes to propagate.

## Open ports

The server needs these inbound ports reachable from the internet:

| Port | Purpose |
|------|---------|
| 80   | HTTP — used by Let's Encrypt for the certificate challenge, redirects to HTTPS |
| 443  | HTTPS — all app traffic |

If you run a firewall (e.g. `ufw`):

```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

You do **not** need to expose PostgreSQL (5432) or the server's internal port (8080) —
those stay inside the Docker network. See [security.md](security.md).

---

Next: [installation.md](installation.md)
