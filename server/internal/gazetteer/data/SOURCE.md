# Data source

`places.bin` is derived from GeoNames' full `allCountries.zip` export (every place
GeoNames tracks worldwide, of every kind - not just populated places), pinned at
`https://download.geonames.org/export/dump/allCountries.zip`, filtered down to feature
class `P` ("city, village, ..." - a populated place) with the historical/non-standalone
feature codes below excluded:

  - `PPLQ` (abandoned populated place), `PPLW` (destroyed populated place), `PPLH`
    (historical populated place - a former name), `PPLCH` (historical capital) - these
    describe places that no longer exist, or no longer exist under that name. A check-in
    can't happen somewhere that isn't there anymore.
  - `PPLX` (section of a populated place - a neighborhood or district within an
    already-separately-listed city, e.g. a borough) - excluded because it isn't a
    standalone place in the sense this dataset otherwise means one; the parent city is
    already its own row.

That leaves 4,994,873 real places - see "Why no population floor" below for why this is so
much larger than a typical GeoNames "cities" export, and "Memory" for what that actually
costs at runtime.

**Neither the raw GeoNames export nor the packed `places.bin` is committed to this repo.**
`internal/gazetteer/data/fetch_and_pack.sh` downloads the pinned URL above, filters it, and
packs it, run once at Docker BUILD time (see `../../../Dockerfile`) - the same posture
`assets/worldmap/pack_world.py` already uses for Natural Earth in the Flutter app: a script
and a pinned source URL live in the repo, the multi-hundred-MB data itself never does. This
is a build-time download, not a runtime external call, so it doesn't touch this app's own
no-phoning-home posture (see `gazetteer.go`'s own doc comment) - only whoever builds the
image needs the network; everyone who pulls the finished image doesn't. `fetch_and_pack.sh`
fails the build outright (rather than silently shipping a partial gazetteer) if the
download comes back short or the packed output is implausibly small - see its own comments
for the exact thresholds.

### Building it locally

For local development, or to poke at the real dataset directly (`go test ./...` itself does
NOT need this - see "Testing" below):

```
cd internal/gazetteer/data
sh fetch_and_pack.sh
```

This is the exact same script and pinned URL the Docker build itself runs; it takes a few
minutes (a ~420MB download, then packing ~5 million rows), writes `places.bin` next to
this file (gitignored, never committed), and only needs to be run once per checkout.

`countries.tsv` is derived from GeoNames' `countryInfo.txt` - trimmed to just the ISO
alpha-2 code and the full English country name (252 rows), which is what turns a post's
"City, Country" string into a country to search within. Small enough (3.5KB) that it stays
`go:embed`'d, unlike `places.bin` - see `gazetteer.go`'s own doc comment.

## Testing

`go test ./...` never needs the real dataset - not in local dev, not in CI, which checks
out a clean tree with no network access at all. `internal/gazetteer/gazetteertest` points
every test in `internal/gazetteer`, `internal/db`, and `internal/api` (every package whose
tests exercise gazetteer resolution, directly or through `db.PlacesForViewer`) at
`testdata/fixture.bin` instead - a small, hand-curated dataset in this exact same on-disk
format, committed to the repo (1,486 bytes, 56 real GeoNames rows), covering exactly the
cases this package's own resolution RULES need to keep being exercised regardless of
whether anyone has run `fetch_and_pack.sh` locally: proximity disambiguation (Arlington,
Great Falls), population dominance both by ratio and by absolute floor (Washington,
Baltimore, Bethesda, Silver Spring), primary/alias tiering (the Great Falls/Paterson
case), the merge-when-every-primary-candidate-is-zero-population rule (New York), and all
ten of one real self-hosted group's own historical location strings this whole dataset
rework was built to fix (Mathias, Poolesville, Boyds, Dickerson, Moorefield, and White
Plains resolving to Maryland rather than New York, among them) - see
`testdata/make_fixture.py`'s own doc comment for the full list and exactly why each row is
there. Every coordinate and population in it is a real value from the real dataset;
what's curated is which real rows are included.

This was a real bug fixed alongside this fixture's own introduction: before it, these
tests only passed on a machine that happened to have a full `places.bin` sitting around
locally (gitignored, so invisible to `git status`) - a clean CI checkout has no such file,
the loader correctly degrades to "no match" (see `gazetteer.go`'s own `load`), and every
test asserting a real coordinate failed. Verified directly, not just reasoned about: move
`internal/gazetteer/data/places.bin` out of the way and `go test ./...` (with or without
`TESTDB_URL`) still passes, using only the fixture.

A test that genuinely needs the FULL, several-million-row dataset - a coverage claim, a
size or performance assertion against the real production artifact - would skip cleanly
when it's absent, the same idiom `internal/api`'s own `TESTDB_URL`-gated integration tests
already use for "no database here" (see `harness_test.go`). There is no such test today:
`fetch_and_pack.sh` itself already fails the build loudly on an implausibly small packed
output (see "Data source" above), and the real pipeline has been verified end to end via a
real `docker build`, not merely assumed to work.

## Why no population floor

Every GeoNames "cities" export (`cities500`, `cities1000`, `cities5000`, `cities15000`,
...) is built from the same rule: keep a populated place only if its recorded population
clears the export's own threshold, OR it's a first-order administrative seat. This
package's first version used `cities15000` (population > 15,000, ~34,100 rows worldwide)
and it was the wrong choice for what this app actually is: a self-hosted group's
check-ins overwhelmingly come from wherever they actually live, which is usually a small
town, not a place with 15,000+ people.

The obvious fix looks like "use a lower-threshold export instead" - `cities1000` or
`cities500`. It doesn't work. GeoNames' own `population` field is 0 (unset, not "zero
people") for the large majority of real, currently-inhabited small settlements it
otherwise lists - Mathias, WV; Boyds, MD; Dickerson, MD; the Maryland White Plains twenty
minutes from the rest of one real self-hosted group's own check-ins, all real, all
present in GeoNames, all recorded at population 0 - and NO population floor, however low,
keeps a population-0 row. Nor is this a US-specific data-quality quirk: measured directly
against the full `allCountries` export, China is 99.6% population-0 among its own listed
populated places, India 98.7%, Indonesia 99.8%, Russia 96.7%, the US 81.7% - this is how
GeoNames' population field behaves worldwide, not an artifact of one country's import.
The only dataset shape that actually stops silently dropping real small towns is
"every populated place regardless of recorded population" - which is what this file is.

## Memory

Loading 4,994,873 places the straightforward way - parse each row, build
`map[string][]entry` for the primary and alias name indexes exactly like the old
`cities15000`-era code did - was measured (a standalone throwaway harness, not part of
this repo) at **~800 MB of live heap, ~1.6 GB of memory the Go runtime had touched by the
time loading finished**. Go's own per-entry map bucket overhead, multiplied across several
million distinct keys, dominates that number - not the data itself.

A second version fixed that by parsing the whole dataset into flat, unboxed arrays instead
of a map (still fully memory-resident) - a real improvement (~271 MB of live heap, no
per-key hash overhead), but still hundreds of MB per server process, which is the wrong
budget entirely for what this package actually is: a **backfill**, not a hot path. Every
check-in has captured its own device coordinates since coordinate capture shipped
alongside this feature, and never touches the gazetteer at all - this package only ever
resolves the historical location strings that predate that, and a real self-hosted group
has on the order of ten to fifty of those, ever (see `internal/db/places.go`'s own
`gazetteer_cache` table, which makes sure each one is read off disk at most once, ever,
regardless of how many times any viewer opens Places afterward). A self-hosted deployment
routinely runs several instances of this app on one modest box - hundreds of MB of
permanent heap per instance, purely to resolve place names nobody is actively querying
almost all of the time, is not a defensible cost there.

So `places.bin` is **not loaded into memory at all**. It's a fixed-offset binary file (see
"Format" below) `gazetteer.go` opens once with `os.Open` and reads via `os.File.ReadAt` -
binary search happens directly against the file, each comparison step reading only the
exact byte range it needs. Measured against the real dataset and the real lookup code
(`internal/gazetteer`'s own package, not a throwaway reimplementation): resolving all ten
of one real group's own historical location strings (see the table-driven tests in
`gazetteer_test.go` and `internal/db/places_test.go`) took **354µs total** and grew Go's
own heap by **7 KB**. A synthetic stress run - 1,000 lookups across 20 distinct locations,
far more churn than any real group's history would ever produce - left steady-state
process RSS at **4.6 MB**, up from a ~2.7 MB baseline before the gazetteer was touched at
all. A real containerized build of this server, boot to serving, sits at **~71 MB RSS
before a single gazetteer lookup has happened** (ordinary Go/HTTP/DB-pool overhead,
unrelated to this package) - confirming nothing is parsed or decompressed at boot either;
`places.bin` is already sitting on disk, fully built, before the container's own
entrypoint ever runs (see "Data source" above). This is what "steady-state RSS is noise,
not a number worth discussing" looks like in practice.

`CHECKIN_GAZETTEER_PATH` overrides where the plain file lives, for a host running the
binary directly rather than the published image (see `internal/config`).

## License

GeoNames' data is licensed under the [Creative Commons Attribution 4.0
License](https://creativecommons.org/licenses/by/4.0/), which requires attribution.
Attribution: place data (c) GeoNames.org contributors, CC BY 4.0.

## What was kept, and why

The raw, filtered export this is built from is ~640 MB and carries columns this feature
has no use for (feature codes beyond the class/code filter already applied, elevation, a
modification date, ...) plus an `alternatenames` column that alone runs to a large share
of that. None of that belongs in a Docker image for a self-hosted group chat app, so
`pack_places.py` (run by `fetch_and_pack.sh`, not part of the Go build) trims each row to
exactly what `Candidates`/`Resolve` need:

  - lat/lng and population per entry, deduplicated one row per real GeoNames place (not
    per name - see "Format" below for why a place with several alternate names doesn't
    carry several copies of its own coordinates). lat/lng are fixed-point int32s, not
    float64s: scaled by 100,000 (`COORD_SCALE` in `pack_places.py`), the same
    5-decimal-place precision GeoNames itself reports coordinates at, so the round trip
    back to float64 in Go reproduces the exact same value `strconv.ParseFloat` would give
    the original decimal string - verified directly against every pinned coordinate in
    `gazetteer_test.go`, not just argued from theory. Halves each entry's coordinate
    storage against float64 at zero precision cost.
  - a 64-bit hash (see "Format" below for why a hash, not the name text itself) of every
    entry's own ASCII name (or original-script name, when GeoNames records no ASCII form),
    normalized and paired with its ISO alpha-2 country, tagged PRIMARY
  - the same hash shape for up to 12 additional short, ASCII, non-abbreviation alternate
    names per entry, tagged ALIAS, so a common English exonym GeoNames files under
    `alternatenames` rather than under `name` (e.g. "New York" for the row GeoNames calls
    "New York City") still resolves. All-caps entries (airport/rail/postal codes like
    "NYC", "LIS") are dropped outright rather than merely deprioritized - real GeoNames
    data, but not a shape a phone's on-device reverse geocoder ever actually produces, and
    keeping them crowded out genuine short exonyms in the length-sorted shortlist.

Every coordinate in this file is GeoNames' own reported value for that place - nothing
here was hand-typed, approximated, or guessed. A place this dataset has no row for at all
(a name with no real match anywhere in the filtered feature-class-P export) simply has no
resolution; see gazetteer.go's `Resolve` for how that comes back (ok=false, not a guess).

## Format

An uncompressed, little-endian binary with a fixed-size, fixed-offset header - what lets
`gazetteer.go` seek straight to any section without reading anything before it:

```
header (60 bytes, all fixed-width, at file offset 0):
  magic:              4 bytes ("PLC3")
  keyCount:           uint32
  hashesOffset:       uint64  (file offset of the keyCount x uint64 hash array)
  entryIndicesOffset: uint64  (file offset of the keyCount x uint32 entry-index array)
  flagsOffset:        uint64  (file offset of the keyCount x uint8 PRIMARY/ALIAS array)
  entryCount:         uint32  (parsed but never read back out - see gazetteer.go's header
                                struct doc comment)
  latOffset:          uint64  (file offset of the entryCount x int32 lat array)
  lngOffset:          uint64  (file offset of the entryCount x int32 lng array)
  populationOffset:   uint64  (file offset of the entryCount x int32 population array)

key table, at its own header-given offsets, sorted ascending by hash:
  hashes:        keyCount x uint64  (FNV-1a 64 of "ISO\x00normalized name" - see below)
  entryIndices:  keyCount x uint32  (which entries-table row this key's coordinates live at)
  flags:         keyCount x uint8   (1 = PRIMARY, 0 = ALIAS - see Candidates' own doc
                                      comment for why this still matters with no name text)

entries table, at its own header-given offsets, one row per real GeoNames place:
  lat, lng, population: entryCount x int32 each
```

**No name text is stored anywhere in this file.** The previous version of this format
stored every key as literal UTF-8 bytes ("ISO\x00normalized name") in a separate blob,
binary-searched by comparing that text directly - genuinely simple, but the text itself
was pure overhead: nothing downstream ever reads a place's name back out of the gazetteer
at all. A post's location string is whatever the client already sent and the UI already
shows (see `Candidate`'s own doc comment); this package only ever MATCHES a name against a
key, never returns one. So a key is now just its 64-bit `fnv1a64` hash (see
`pack_places.py`/`gazetteer.go`, both implementing the exact same FNV-1a algorithm,
verified directly against each other) - `gazetteer.go` hashes the query the same way and
binary-searches the sorted hash column directly, reading only the handful of 8-byte
ranges an O(log n) search actually needs to compare, then (only for actual matches) the
small contiguous run of same-hash rows and their entry indices.

Dropping the name text also means a genuine hash collision - two different normalized
"ISO\x00name" keys landing on the same 64-bit value - would be undetectable at query time;
this was considered and accepted deliberately (see `pack_places.py`'s own doc comment for
the numbers: at 64 bits of hash space against this dataset's own row count, order 10
million, the birthday-bound probability of even one collision anywhere in the whole table
is on the order of 1 in 300,000, and the practical effect of one occurring would be two
real, unrelated places occasionally sharing a match - not a systemic failure).

An alternate name is its own row in the SAME key table, pointing (via `entryIndices`) at
the SAME entries-table row its primary name does, tagged ALIAS instead of PRIMARY -
"pointing at", not carrying its own copy of the coordinates, is what keeps the entries
table deduplicated at one row per real place regardless of how many alternate names it
has, rather than growing with the total row count the way the coordinate data would if
every alias duplicated it.

## Size

`places.bin` (never committed - see "Data source" above) is 181,868,227 bytes (~173.4 MB) -
down from an earlier, still disk-backed but text-keyed version of this same format at
~220.2 MB (a ~21% cut from dropping name text entirely, on top of the ~15% the fixed-point
coordinate encoding already bought over a float64 version at ~258 MB). That's still a
large jump from the old `cities15000.tsv.gz`'s ~1.3 MB, and larger than "a few
megabytes" - genuinely worth naming plainly rather than rounding away: it's the honest
cost of population-agnostic worldwide coverage (see "Why no population floor" above), the
only shape of dataset that actually resolves the small real towns this app's own
check-ins come from. Unlike the size of this file, though, the RAM and startup-time cost
of shipping it is not a real cost at all any more - see "Memory" above - and since the
file is never committed at all (see "Data source" above), neither is the git-history cost
a self-hosted host's own clone has to pay.
