# App Store screenshots

Four screenshots at 1290x2796 (Apple's 6.9" size), uploadable to App Store Connect as-is:

| File | Shows |
|---|---|
| `1-group-trips.png` | Memories → Group trips: the trips and nights out the group posted from |
| `2-places-map.png` | Places, on the map, with each place drawn from its own photos |
| `3-month-by-month.png` | Memories → Month by month |
| `4-profile.png` | Your profile: host badge, a recap title, a check-in with tagged people |

Captured against `checkin-test.npc-server.top` signed in as Sam Rivers, which is the
seeded demo instance rather than anyone's real group. All four come from the same
instance on purpose: mixing sources gives one screenshot a different cast of people
than the next, which reads as incoherently as mixing themes would.

These are Flutter web renders at exact iPhone dimensions, not iOS device captures.
Flutter draws its own widgets, so the UI is identical; the only difference is that
there is no iOS status bar.

## What is live, and what these replace

The five screenshots on the store (`01_feed`, `05_invite`, `02_profile`, `03_filter`,
`04_compose`) all date from the old purple theme. They should be replaced together, not
one at a time - a green screenshot beside a purple one looks broken.

App Store Connect only allows screenshot edits on a version in "Prepare for Submission".
A version that is "Ready for Distribution" has its whole listing locked: the Media Manager
list renders `disabled`, with no upload or delete controls.

## Capturing more

1. `flutter build web --release` from `app/`.
2. A same-origin Python proxy serving `app/build/web` and forwarding `/api/*` to the
   server. Same-origin is required because the API sends no CORS headers, which is correct
   for an API whose only real client is a native app. The proxy must forward the browser's
   User-Agent or Cloudflare answers "error code: 1010", and it must inject a bearer token
   for `/api/media/*`, since an `<img>` cannot carry an Authorization header.
3. Headless Chrome with `--enable-unsafe-swiftshader` and `--remote-allow-origins='*'`.
4. `Emulation.setDeviceMetricsOverride` (430x932 @ DPR 3), **then reload** - Flutter reads
   the window size at boot and will not relayout for a late override.

### Three things that cost time, so they are written down

**The metrics override dies with the CDP session that set it.** Splitting the work across
two scripts silently produces 430x932 desktop captures instead of 1290x2796, and nothing
warns you - the screenshot just comes out wrong. Do the override, the navigation and the
capture in one connection.

**The demo instance's feed is all recaps at the top.** Recaps were generated recently
while the check-ins are backdated across a year, so the newest thing in the feed is a wall
of recap cards and scrolling past them is slow and unreliable. Filtering the feed to one
person drops them, because a recap is authored by the group rather than by a member.

**A slow avatar reads as a black circle, not as loading.** `AuthImage`'s placeholder is
`ColoredBox(Color(0x11000000))` with a spinner; on the app's near-black background that
colour is invisible and at avatar size the spinner is too small to see. Under headless
CanvasKit a screenful of avatars competes and the losers sit in that placeholder
indefinitely, so a capture can look like several members have no photo. Give the page a
long settle - 30 seconds or more - before the shot, and check the avatars before
accepting it.
