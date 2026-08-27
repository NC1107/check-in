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

    python3 server/scripts/normalize_locations.py \\
      --database-url "$CHECKIN_DATABASE_URL" --cities cities500.txt

and once the output looks right, apply it:

    python3 server/scripts/normalize_locations.py \\
      --database-url "$CHECKIN_DATABASE_URL" --cities cities500.txt --apply

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
COL_COUNTRY = 8
COL_POPULATION = 14
EXPECTED_COLUMNS = 19

# Candidate cities are bucketed into whole-degree cells so a lookup compares against its own
# cell and the eight around it, rather than against every row in the file.
CELL = 1.0

COUNTRIES_TSV = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "internal", "gazetteer", "data", "countries.tsv",
)


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


def nearest_city(cells, lat, lng, max_km):
    """The closest populated place, or None when nothing is within max_km.

    Ties on distance are broken by population, so a coordinate sitting between a city and a
    hamlet of the same distance gets the name a person would actually have written.
    """
    ci, cj = math.floor(lat / CELL), math.floor(lng / CELL)
    best = None
    best_key = None
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            for city in cells.get((ci + di, cj + dj), ()):
                d = haversine_km(lat, lng, city[0], city[1])
                if d > max_km:
                    continue
                key = (round(d, 3), -city[4])
                if best_key is None or key < best_key:
                    best_key, best = key, city
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--database-url", required=True,
                    help="postgres:// URL for the group's database")
    ap.add_argument("--cities", required=True,
                    help="GeoNames export, e.g. the cities500.txt from cities500.zip")
    ap.add_argument("--countries", default=COUNTRIES_TSV,
                    help="ISO-to-country-name table (defaults to the gazetteer's own)")
    ap.add_argument("--max-km", type=float, default=40.0,
                    help="furthest a place may be from the coordinates and still name it")
    ap.add_argument("--apply", action="store_true",
                    help="write the changes; without it the run only reports them")
    args = ap.parse_args()

    try:
        import psycopg
    except ImportError:
        sys.exit("psycopg (v3) is required: pip install 'psycopg[binary]'")

    countries = load_countries(args.countries)
    cells, city_count = load_cities(args.cities)
    print(f"loaded {city_count} places and {len(countries)} countries", file=sys.stderr)

    changed = unchanged = no_coords = unresolved = 0
    updates = []
    with psycopg.connect(args.database_url) as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id, location, lat, lng FROM posts
                WHERE location IS NOT NULL AND location <> ''
                ORDER BY id
            """)
            for post_id, location, lat, lng in cur.fetchall():
                if lat is None or lng is None:
                    no_coords += 1
                    continue
                city = nearest_city(cells, float(lat), float(lng), args.max_km)
                if city is None:
                    unresolved += 1
                    continue
                country = countries.get(city[3])
                if country is None:
                    unresolved += 1
                    continue
                canonical = f"{city[2]}, {country}"
                if canonical == location:
                    unchanged += 1
                    continue
                changed += 1
                updates.append((canonical, post_id))
                print(f"post {post_id}: {location!r} -> {canonical!r}")

        if args.apply and updates:
            with conn.cursor() as cur:
                cur.executemany("UPDATE posts SET location = %s WHERE id = %s", updates)
            conn.commit()

    verb = "updated" if args.apply else "would update"
    print(f"\n{verb} {changed}; already canonical {unchanged}; "
          f"skipped {no_coords} without coordinates and {unresolved} with no place "
          f"within {args.max_km:g}km", file=sys.stderr)
    if not args.apply and changed:
        print("dry run - nothing was written. Re-run with --apply to commit.", file=sys.stderr)


if __name__ == "__main__":
    main()
