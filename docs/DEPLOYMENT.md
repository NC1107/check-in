# Deployment & CI/CD setup

This covers (1) self-hosting the server and (2) configuring the automated store
releases. The release pipeline already builds the Docker image and a GitHub Release with
the Android APK using only the built-in `GITHUB_TOKEN` — no setup needed for that part.
The store-deploy jobs stay dormant until you add the secrets below.

## 1. Self-hosting the server

1. Point a subdomain's DNS **A record** at your server's public IP, e.g.
   `check-in.npc-server.top → <your IP>`. Open ports **80** and **443**.
2. On the server:
   ```bash
   git clone https://github.com/nc1107/check-in.git && cd check-in
   cp .env.example .env
   # edit .env: set CHECKIN_DOMAIN=check-in.npc-server.top and a strong POSTGRES_PASSWORD
   docker compose up -d
   ```
3. Caddy automatically obtains a Let's Encrypt certificate for your domain. Because it's
   a real, trusted cert, the mobile app needs no special configuration — users just enter
   `https://check-in.npc-server.top`.
4. Open the app, sign up — **the first account becomes the admin** — then upload your
   contacts to build the invite list.

To upgrade, pull the new image and restart: `docker compose pull && docker compose up -d`.
Pin a specific version by setting `CHECKIN_IMAGE=ghcr.io/nc1107/check-in:vX.Y.Z` in `.env`.

## 2. App store release pipeline

The release workflow (`.github/workflows/release.yml`) deploys to the stores only when
the relevant secrets exist. Add them under **GitHub → repo Settings → Secrets and
variables → Actions**.

### Android / Google Play

| Secret | What it is | Where to get it |
|--------|------------|-----------------|
| `ANDROID_KEYSTORE_BASE64` | Your upload keystore (`.jks`), base64-encoded | Create once with `keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`, then `base64 -w0 upload-keystore.jks` |
| `ANDROID_KEY_PROPERTIES` | The `key.properties` contents | `storePassword=…`<br>`keyPassword=…`<br>`keyAlias=upload`<br>`storeFile=upload-keystore.jks` |
| `PLAY_SERVICE_ACCOUNT_JSON` | Service-account JSON with Play Console access | Google Play Console → Setup → API access → create a service account in Google Cloud, grant it "Release to testing tracks", download the JSON key |

One-time in Play Console: create the app, set package name (e.g. `top.npcserver.checkin`),
and upload one build manually so the internal track exists. After that, CI pushes to the
**internal** track automatically.

### iOS / App Store (TestFlight)

| Secret | What it is | Where to get it |
|--------|------------|-----------------|
| `APP_STORE_CONNECT_API_KEY` | Contents of the `.p8` App Store Connect API key | App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key (App Manager role), download the `.p8` |
| `APP_STORE_CONNECT_KEY_ID` | The key's ID | Shown next to the key in App Store Connect |
| `APP_STORE_CONNECT_ISSUER_ID` | The issuer ID | Top of the API keys page |
| `MATCH_GIT_URL` | URL of a **private** git repo for fastlane `match` to store signing certs/profiles | Create an empty private repo, e.g. `github.com/nc1107/check-in-certs` |
| `MATCH_PASSWORD` | Passphrase that encrypts the match repo | Any strong secret you choose; run `fastlane match appstore` once locally to initialize the repo |

One-time: register the app's **Bundle ID** in the Apple Developer portal and create the
app record in App Store Connect, then run `fastlane match appstore` locally once to seed
the certs repo.

### What you need to give me to finish wiring it up

To fill in the platform-specific identifiers in the project (not secrets — these are safe
to commit), tell me:

- **Android application ID** you want (e.g. `top.npcserver.checkin`).
- **iOS bundle identifier** (often the same reverse-domain id).
- **Apple Team ID** (10-char, from the Apple Developer membership page).
- **App display name** (defaults to "Check-In").

Then add the secrets above. Everything else (signing wiring, lanes, version bumping) is
already in place.
