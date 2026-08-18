"""Rebuilds cities15000.tsv.gz from a raw GeoNames cities15000.txt export.

Not part of the Go build - a one-off transform to regenerate the embedded dataset when
GeoNames publishes an update. Run from this directory with cities15000.txt (from
https://download.geonames.org/export/dump/cities15000.zip) alongside it:

    python3 pack_cities.py
    gzip -9 -f cities_packed.tsv
    mv cities_packed.tsv.gz cities15000.tsv.gz

See SOURCE.md for what each output column is and why it's kept.
"""

import csv
import re
import sys

ASCII_ALIAS_RE = re.compile(r"^[A-Za-z0-9 .'\-]+$")

def usable_alias(name: str) -> bool:
    if not name or not name.isascii():
        return False
    if len(name) > 40:
        return False
    if not ASCII_ALIAS_RE.match(name):
        return False
    # GeoNames' alternatenames column is dominated by short all-caps airport/rail/postal
    # codes ("NY", "NYC", "LIS") - real, but not the shape a phone's on-device reverse
    # geocoder ever actually produces. Excluding them (rather than just deprioritizing)
    # keeps the length-based shortlist below from being crowded out by codes ahead of
    # genuine short exonyms like "New York".
    if name.isupper() and not name.islower():
        return False
    return True

MAX_EXTRA_ALIASES = 12

rows = []
with open("cities15000.txt", encoding="utf-8") as f:
    reader = csv.reader(f, delimiter="\t")
    for parts in reader:
        if len(parts) < 15:
            continue
        geonameid = parts[0]
        name = parts[1].strip()
        asciiname = parts[2].strip()
        alt = parts[3]
        lat = parts[4]
        lng = parts[5]
        country = parts[8].strip()
        try:
            population = int(parts[14]) if parts[14] else 0
        except ValueError:
            population = 0

        primary = asciiname if asciiname else name

        seen = {primary.lower()}
        extras = []
        if name and name.lower() not in seen:
            extras.append(name)
            seen.add(name.lower())
        for a in alt.split(","):
            a = a.strip()
            if not usable_alias(a):
                continue
            key = a.lower()
            if key in seen:
                continue
            seen.add(key)
            extras.append(a)

        # Shorter candidates are, empirically, far more likely to be the plain common
        # exonym a phone's on-device reverse geocoder would actually produce (e.g. "New
        # York" for "New York City") than the long tail of transliterations GeoNames'
        # alternatenames column also carries - so among the (often 50+) usable
        # candidates, keep the shortest MAX_EXTRA_ALIASES, tie-broken alphabetically for
        # determinism.
        extras.sort(key=lambda n: (len(n), n))
        extras = extras[:MAX_EXTRA_ALIASES]

        rows.append((geonameid, primary, extras, country, lat, lng, population))

print(f"total rows: {len(rows)}", file=sys.stderr)

with open("cities_packed.tsv", "w", encoding="utf-8", newline="") as out:
    w = csv.writer(out, delimiter="\t", lineterminator="\n")
    for geonameid, primary, extras, country, lat, lng, population in rows:
        w.writerow([primary, country, lat, lng, population, "|".join(extras)])
