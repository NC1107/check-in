# Installation

This walks through a first install from scratch. It assumes you've completed
[prerequisites.md](prerequisites.md) — a server with Docker, a subdomain with an A record
pointed at it, and ports 80/443 open.

## 1. Get the code

```bash
git clone https://github.com/nc1107/check-in.git
cd check-in
```

## 2. Configure your environment

Copy the example file and edit it:

```bash
cp .env.example .env
```

At minimum, set these two values in `.env`:

```ini
# The subdomain you pointed at this server. Caddy gets a Let's Encrypt cert for it.
CHECKIN_DOMAIN=check-in.example.com

# A long random database password. Generate one, e.g.:  openssl rand -base64 32
POSTGRES_PASSWORD=your-long-random-password
```

See [configuration.md](configuration.md) for every available setting.

## 3. Start the stack

```bash
docker compose up -d
```

This launches three containers:

- **db** — PostgreSQL (data lives in the `db_data` volume)
- **server** — the Check-In API (media lives in the `media_data` volume; database
  migrations run automatically on startup)
- **caddy** — reverse proxy that terminates HTTPS and forwards to the server

On first boot, Caddy contacts Let's Encrypt and provisions a certificate for your domain.
This takes up to a minute. Watch it happen:

```bash
docker compose logs -f caddy
```

When you see it serving your domain over HTTPS, you're ready.

## 4. Verify it's up

From anywhere:

```bash
curl https://check-in.example.com/api/health
# {"status":"ok"}
```

## 5. Become the admin

Open the Check-In app on your phone. On the first screen, enter your server URL:

```
https://check-in.example.com
```

Then sign up. **The very first account created on a fresh server automatically becomes
the admin** — the app shows a short notice telling you so. You'll provide your name,
birthday, a password, and (optionally) a profile photo.

## 6. Build your invite list

As the admin, open the **Admin** tab and tap **Upload my contacts**. The app reads your
phone's contacts and sends the phone numbers to your server. Each number becomes an
invite — anyone whose number is on the list can sign up, once.

> The phone number itself is the access code. There's no SMS step. See
> [security.md](security.md) for the reasoning and the caveats.

You can re-upload contacts any time to add new people, and remove members from the
**Admin** tab.

## 7. Share with friends

Tell your friends two things:

1. The server URL: `https://check-in.example.com`
2. To sign up with the phone number you have for them.

They install the app, enter the URL, enter their number, and complete signup.

---

Next: [operations.md](operations.md) for upgrades and backups.
