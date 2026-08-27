#!/usr/bin/env python3
"""Rewrites check-in place labels that were stored in the poster's own language.

Why this exists
---------------
The app derives a check-in's "City, Country" label on the phone, by reverse-geocoding the
coordinates from the photo's EXIF (or the clip's MP4 atoms). Until the fix that ships
alongside this script, it did so without pinning a locale, and both platforms' geocoders
answer in the DEVICE's language. So the same coordinates became "Lisbon, Portugal" from one
member's phone and "Lissabon, Portugal" from another's, in whatever language each member
happens to run their phone in.

That is not only a cosmetic inconsistency. The label is also what the server's gazetteer
matches on when it places a check-in on the Places map, and the packed dataset only carries
a place's primary name plus its ASCII aliases (see pack_places.py's `usable_alias`, which
requires `name.isascii()`). A Cyrillic, CJK, Arabic or Greek label therefore matches
nothing at all, and that check-in silently vanishes from the map rather than merely reading
oddly.

Why it cannot use the gazetteer
-------------------------------
The obvious move - ask the gazetteer - does not work. places.bin is keyed by a hash of the
name and deliberately stores no name text at all, so `Candidate` has no name field: the
gazetteer can tell you that "Lissabon" matches a place at some coordinates, but never that
the canonical name is "Lisbon". Normalizing therefore has to go back to a source that can
still return a name, which is the raw GeoNames export.

Usage
-----
Fetch a populated-places export once (cities500 is ~10MB, against allCountries' ~420MB, and
is the right granularity for a city label):

    curl -fLO https://download.geonames.org/export/dump/cities500.zip
    unzip cities500.zip

Then, from the repo root, dry run first - it prints every change it would make and touches
nothing:

    python3 server/scripts/normalize_locations.py --database-url "$CHECKIN_DATABASE_URL"

and once the output looks right, apply it:

    python3 server/scripts/normalize_locations.py --database-url "$CHECKIN_DATABASE_URL" --apply

The export is looked for as cities500.txt in the working directory. Unzipped it somewhere
else? Pass --data-dir /path/to/that/directory. Names are resolved inside that directory
rather than taken as free paths.

Run it once per server: each group is its own database.

Only posts that still carry coordinates can be normalized. A check-in that predates
coordinate capture has nothing to re-derive its label FROM, so it is counted and skipped
rather than guessed at from the text - guessing is what would turn a merely mislabelled
check-in into a wrongly placed one.
"""

import argparse
import csv
import math
import os
import sys
from collections import defaultdict

# GeoNames' main export is tab-separated with no header. Only these columns are read.
COL_NAME = 1
COL_LAT = 4
COL_LNG = 5
COL_FCLASS = 6
COL_FCODE = 7
COL_COUNTRY = 8
COL_POPULATION = 14
EXPECTED_COLUMNS = 19

# Only real settlements. GeoNames' populated-place class also covers sections of a city
# (PPLX) and minor localities, so without this filter a coordinate inside San Francisco
# resolves to "Chinatown" or "Noe Valley" - the nearest centroid, but not the name anyone
# would write, and not what the phone geocoder that produced these labels returns.
PLACE_CLASS = "P"
SKIPPED_PLACE_CODES = frozenset({"PPLX", "PPLL", "PPLQ", "PPLW", "PPLH", "PPLCH", "PPLR"})

# Candidate cities are bucketed into whole-degree cells so a lookup compares against its own
# cell and the eight around it, rather than against every row in the file.
CELL = 1.0

COUNTRIES_TSV = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "internal", "gazetteer", "data", "countries.tsv",
)


def data_file(data_dir, name, what):
    """Resolves `name` inside `data_dir`, refusing anything that escapes it or is not a file.

    The data files are named relative to a directory rather than by free path so that a
    mistyped or surprising argument cannot wander off somewhere unrelated - it fails here,
    with the name it was given, instead of raising deeper in or reading the wrong file.
    Point --data-dir at wherever the export was unzipped; it defaults to the working
    directory, which is where the usage above puts it.
    """
    root = os.path.realpath(os.path.expanduser(data_dir))
    if not os.path.isdir(root):
        sys.exit(f"--data-dir: {data_dir!r} is not a directory")
    resolved = os.path.realpath(os.path.join(root, name))
    if os.path.commonpath([root, resolved]) != root:
        sys.exit(f"{what}: {name!r} resolves outside {data_dir!r}")
    if not os.path.isfile(resolved):
        sys.exit(f"{what}: {name!r} is not a readable file inside {data_dir!r}")
    return resolved


def load_countries(path):
    """ISO country code -> country name, from the same table the gazetteer is built with."""
    codes = {}
    with open(path, encoding="utf-8") as f:
        for row in csv.reader(f, delimiter="\t"):
            if len(row) >= 2 and row[0] and row[1]:
                codes[row[0]] = row[1]
    if not codes:
        sys.exit(f"no countries loaded from {path}")
    return codes


def load_cities(path):
    """Buckets every populated place by whole-degree cell, keyed for nearest-match lookup."""
    cells = defaultdict(list)
    count = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < EXPECTED_COLUMNS:
                continue
            try:
                lat = float(parts[COL_LAT])
                lng = float(parts[COL_LNG])
                population = int(parts[COL_POPULATION] or 0)
            except ValueError:
                continue
            name = parts[COL_NAME].strip()
            country = parts[COL_COUNTRY].strip()
            if not name or not country:
                continue
            if parts[COL_FCLASS].strip() != PLACE_CLASS:
                continue
            if parts[COL_FCODE].strip() in SKIPPED_PLACE_CODES:
                continue
            cells[(math.floor(lat / CELL), math.floor(lng / CELL))].append(
                (lat, lng, name, country, population))
            count += 1
    if not count:
        sys.exit(f"no places loaded from {path} - is it a GeoNames tab-separated export?")
    return cells, count


def haversine_km(lat1, lng1, lat2, lng2):
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def place_score(distance_km, population):
    """Lower is better: distance, discounted by how substantial the place is.

    Pure nearest-centroid is wrong for anywhere large. A point by the Golden Gate is closer
    to Sausalito's centre than to San Francisco's, so nearest alone renames half a trip to
    the town across the bay. Pure population is wrong the other way - it would rename a
    check-in in a small town to whichever city nearby happens to be bigger. Dividing by the
    population's order of magnitude keeps a place that is genuinely at hand while letting a
    real city outrank a village a similar distance off.
    """
    return distance_km / (1.0 + math.log10(max(population, 1)))


def nearest_city(cells, lat, lng, max_km):
    """The best-matching populated place, or None when nothing is within max_km."""
    ci, cj = math.floor(lat / CELL), math.floor(lng / CELL)
    best = None
    best_key = None
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            for city in cells.get((ci + di, cj + dj), ()):
                d = haversine_km(lat, lng, city[0], city[1])
                if d > max_km:
                    continue
                # Distance breaks a score tie, so two equally-weighted places still resolve
                # deterministically rather than by file order.
                key = (round(place_score(d, city[4]), 6), round(d, 3))
                if best_key is None or key < best_key:
                    best_key, best = key, city
    return best


def canonical_label(cells, countries, lat, lng, max_km):
    """The "City, Country" a coordinate should carry, or None when it cannot be derived."""
    if lat is None or lng is None:
        return None
    city = nearest_city(cells, float(lat), float(lng), max_km)
    if city is None:
        return None
    country = countries.get(city[3])
    return None if country is None else f"{city[2]}, {country}"


def plan_updates(cur, cells, countries, max_km):
    """Walks every located post and returns the rewrites to make, plus a tally of the rest.

    Split out of main so the reporting and the writing stay separately readable; this is
    also the whole of the dry run, which is why it prints as it goes rather than at the end.
    """
    updates = []
    tally = {"changed": 0, "unchanged": 0, "no_coords": 0, "unresolved": 0}
    cur.execute("""
        SELECT id, location, lat, lng FROM posts
        WHERE location IS NOT NULL AND location <> ''
        ORDER BY id
    """)
    for post_id, location, lat, lng in cur.fetchall():
        if lat is None or lng is None:
            tally["no_coords"] += 1
            continue
        canonical = canonical_label(cells, countries, lat, lng, max_km)
        if canonical is None:
            tally["unresolved"] += 1
        elif canonical == location:
            tally["unchanged"] += 1
        else:
            tally["changed"] += 1
            updates.append((canonical, post_id))
            print(f"post {post_id}: {location!r} -> {canonical!r}")
    return updates, tally


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--database-url", required=True,
                    help="postgres:// URL for the group's database")
    ap.add_argument("--data-dir", default=".",
                    help="directory holding the GeoNames export (default: working directory)")
    ap.add_argument("--cities", default="cities500.txt",
                    help="name of the export inside --data-dir")
    ap.add_argument("--countries", default=None,
                    help="ISO-to-country-name table inside --data-dir "
                         "(defaults to the gazetteer's own, shipped in this repo)")
    ap.add_argument("--max-km", type=float, default=40.0,
                    help="furthest a place may be from the coordinates and still name it")
    ap.add_argument("--apply", action="store_true",
                    help="write the changes; without it the run only reports them")
    return ap.parse_args()


def main():
    args = parse_args()
    try:
        import psycopg
    except ImportError:
        sys.exit("psycopg (v3) is required: pip install 'psycopg[binary]'")

    # The default countries table ships in this repo and is located from __file__, so only
    # an explicit override is resolved against --data-dir.
    countries_path = (COUNTRIES_TSV if args.countries is None
                      else data_file(args.data_dir, args.countries, "--countries"))
    countries = load_countries(countries_path)
    cells, city_count = load_cities(data_file(args.data_dir, args.cities, "--cities"))
    print(f"loaded {city_count} places and {len(countries)} countries", file=sys.stderr)

    with psycopg.connect(args.database_url) as conn:
        with conn.cursor() as cur:
            updates, tally = plan_updates(cur, cells, countries, args.max_km)
        if args.apply and updates:
            with conn.cursor() as cur:
                cur.executemany("UPDATE posts SET location = %s WHERE id = %s", updates)
            conn.commit()

    verb = "updated" if args.apply else "would update"
    print(f"\n{verb} {tally['changed']}; already canonical {tally['unchanged']}; "
          f"skipped {tally['no_coords']} without coordinates and {tally['unresolved']} "
          f"with no place within {args.max_km:g}km", file=sys.stderr)
    if not args.apply and tally["changed"]:
        print("dry run - nothing was written. Re-run with --apply to commit.", file=sys.stderr)


if __name__ == "__main__":
    main()
