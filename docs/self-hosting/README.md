# Self-Hosting Check-In

Everything you need to run your own Check-In server. Check-In is designed to be hosted by
**one person** (you, the admin) for a small circle of friends. You run a server, your
friends point the app at it, and only people you invite can join.

If you just want to get going, follow the **Quick start** below. The other pages go
deeper on each topic.

## Documentation

| Page | What it covers |
|------|----------------|
| [prerequisites.md](prerequisites.md) | What you need before you begin (server, domain, DNS, ports) |
| [installation.md](installation.md) | Step-by-step first install and first-admin setup |
| [configuration.md](configuration.md) | Every environment variable, explained |
| [operations.md](operations.md) | Upgrades, logs, backups & restore, health checks |
| [security.md](security.md) | The trust model and how to keep your server safe |
| [troubleshooting.md](troubleshooting.md) | Fixes for the most common problems |

For building and shipping the mobile apps to the App Store / Play Store, see
[../DEPLOYMENT.md](../DEPLOYMENT.md) instead — that's a separate concern from running the
server.

---

## Quick start (~10 minutes)

You need a Linux server with Docker, a domain/subdomain pointed at it, and ports 80 and
443 open. See [prerequisites.md](prerequisites.md) for details.

1. **Point DNS at your server.** Create an `A` record, e.g.
   `check-in.example.com → <your server's public IP>`.

2. **Get the code and configure it:**
   ```bash
   git clone https://github.com/nc1107/check-in.git
   cd check-in
   cp .env.example .env
   ```
   Edit `.env` and set at least:
   - `CHECKIN_DOMAIN` — your subdomain (e.g. `check-in.example.com`)
   - `POSTGRES_PASSWORD` — a long random string

3. **Start the stack:**
   ```bash
   docker compose up -d
   ```
   Caddy automatically obtains a free, trusted HTTPS certificate for your domain from
   Let's Encrypt. Give it a minute on first boot.

4. **Become the admin.** Open the app, enter your server URL
   (`https://check-in.example.com`), and sign up. **The first account created on a fresh
   server is the admin.**

5. **Invite your friends.** As admin, upload your phone contacts in the app. Each
   contact's phone number becomes their invite — that's the whole access-control model.
   See [security.md](security.md) for how this works and its caveats.

6. **Share your server URL** with friends. They install the app, enter the URL, and sign
   up by entering a phone number you invited.

That's it. To upgrade later: `docker compose pull && docker compose up -d`
(see [operations.md](operations.md)).
