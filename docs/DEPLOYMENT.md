# Release & app-store deployment

This page covers the **CI/CD release pipeline** and shipping the mobile apps to the
Google Play Store and Apple App Store.

> Running the **server** on your own machine is a separate topic — see the
> [self-hosting guide](self-hosting/README.md).

## How releases work

Every push to `main` runs `.github/workflows/release.yml`, which:

- bumps the version from conventional commit messages and tags it,
- builds and publishes the server Docker image to `ghcr.io/nc1107/check-in`,
- builds the Flutter apps, and
- creates a GitHub Release with the Android APK attached.

All of the above works out of the box using the built-in `GITHUB_TOKEN` — **no setup
needed**. The store-deploy jobs below stay dormant until you add the corresponding
secrets.

## App store release pipeline

The release workflow deploys to the stores only when the relevant secrets exist. Add them
under **GitHub → repo Settings → Secrets and variables → Actions**.

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

The iOS job imports the certificate/profile into a temporary keychain and uploads with
`altool` (no fastlane `match`). The presence of `IOS_CERTIFICATE_BASE64` is what enables
the App Store job.

| Secret | What it is | Where to get it |
|--------|------------|-----------------|
| `IOS_CERTIFICATE_BASE64` | Apple **Distribution** certificate + private key as a base64 `.p12` | Export your "Apple Distribution" identity from Keychain Access as a `.p12`, then `base64 -w0 cert.p12` |
| `IOS_CERTIFICATE_PASSWORD` | Password you set when exporting the `.p12` | Chosen at export time |
| `IOS_PROVISIONING_PROFILE_BASE64` | App Store provisioning profile (`.mobileprovision`), base64-encoded | Apple Developer portal → Profiles → create an App Store profile for the bundle id, download it, then `base64 -w0 profile.mobileprovision` |
| `ASC_API_KEY_BASE64` | Contents of the `.p8` App Store Connect API key, base64-encoded | App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key (App Manager role), download the `.p8`, then `base64 -w0 AuthKey_*.p8` |
| `ASC_KEY_ID` | The key's ID | Shown next to the key in App Store Connect |
| `ASC_ISSUER_ID` | The issuer ID | Top of the API keys page |

One-time: register the app's **Bundle ID** in the Apple Developer portal and create the
app record in App Store Connect, then generate the distribution certificate + App Store
provisioning profile above.

### What you need to give me to finish wiring it up

To fill in the platform-specific identifiers in the project (not secrets — these are safe
to commit), tell me:

- **Android application ID** you want (e.g. `top.npcserver.checkin`).
- **iOS bundle identifier** (often the same reverse-domain id).
- **Apple Team ID** (10-char, from the Apple Developer membership page).
- **App display name** (defaults to "Check-In").

Then add the secrets above. Everything else (signing wiring, lanes, version bumping) is
already in place.
