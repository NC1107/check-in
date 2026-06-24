# Security

Check-In is built for a **small group of people who trust each other**. This page
explains the trust model so you can decide if it fits your group, and lists the steps to
keep your server safe.

## The access model: phone number = invite code

There is no SMS one-time-password step. Instead:

1. As admin, you upload your phone contacts. Their phone numbers become the **allowlist**.
2. A person can create exactly one account by entering a phone number that's on the
   allowlist. Once used, that number can't be used to register again.
3. The first account ever created on a fresh server becomes the admin (you).

In other words, **knowing an invited phone number is what grants access.** This is simple
and friction-free, which is the point — but be aware of the trade-off:

- Phone numbers aren't secret the way passwords are. Someone who knows an invited
  person's number *could* register as them before they do. For a private group of
  friends this is an acceptable risk; for anything larger or higher-stakes it isn't the
  right model.

### Built-in protections

- **One account per number** — a number can only be registered once.
- **Rate limiting** — signup and login attempts are throttled per client IP.
- **Admin revoke** — you can disable any member from the Admin tab; they can no longer
  log in.
- **Strong password required** — each account sets a password (argon2id-hashed) used for
  returning logins, independent of the phone number.

### A note on number matching

Phone numbers are normalized before matching: spaces, dashes, and parentheses are
stripped, and a single leading `+` is kept. That means `(555) 123-4567` and
`555-123-4567` match, but `+1 555 123 4567` (with country code) and `555 123 4567`
(without) are treated as **different** numbers. When inviting people, make sure the
number you have in your contacts matches the format they'll type — ideally store full
international numbers (`+1…`) for everyone and have them sign up the same way.

## Hardening the server

- **Use a strong `POSTGRES_PASSWORD`.** Generate it (`openssl rand -base64 32`); never
  reuse a password. See [configuration.md](configuration.md).
- **Only expose ports 80 and 443.** PostgreSQL (5432) and the API (8080) stay on the
  internal Docker network and should never be published to the internet. Run a firewall
  (`ufw allow 80,443/tcp` and deny the rest).
- **TLS is automatic.** Caddy provisions and renews a Let's Encrypt certificate for your
  domain. Because it's trusted, the app needs no certificate pinning. Don't disable it
  or serve over plain HTTP.
- **Keep images patched.** Update regularly (`docker compose pull && up -d`, see
  [operations.md](operations.md)) so you pick up base-image and dependency fixes.
- **Back up your data** and store backups off-server — see
  [operations.md](operations.md).
- **Protect `.env`.** It contains your database password. It's already git-ignored; keep
  its file permissions tight (`chmod 600 .env`).

## What the server does with media

Uploaded images are decoded and **re-encoded** server-side, which strips EXIF/GPS
metadata, and they're downscaled and given random filenames. Images are served only to
authenticated users through the API — there's no public, directly-browsable media URL.

## What's intentionally not here

No ads, no third-party trackers, no external analytics, no cloud push services. Birthday
reminders are scheduled **on each user's device**, so birthday data never leaves your
server for a push provider.
