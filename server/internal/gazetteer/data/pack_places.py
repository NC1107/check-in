"""Rebuilds places.bin from a raw, feature-class-filtered GeoNames allCountries export.

Not part of the Go build, and not run against a dataset checked into this repo either -
see SOURCE.md for why: the raw GeoNames dump is fetched and packed at Docker BUILD time
(see ../../../Dockerfile), the same "fetch it fresh, never commit the raw or packed data"
posture assets/worldmap/pack_world.py already uses for Natural Earth. To reproduce
places.bin locally:

    curl -fL -o allCountries.zip https://download.geonames.org/export/dump/allCountries.zip
    unzip -q allCountries.zip
    awk -F'\t' '$7=="P" && $8!="PPLX" && $8!="PPLQ" && $8!="PPLW" && $8!="PPLH" && $8!="PPLCH"' \
        allCountries.txt > allCountriesP_filtered.txt
    python3 pack_places.py allCountriesP_filtered.txt places.bin

See SOURCE.md for the feature-code filter's reasoning and this format's own layout: a
single flat table keyed by a 64-bit hash of the normalized "ISO\\x00name" string rather
than the string itself (see `fnv1a64` below) - nothing ever needs the gazetteer's own name
back (a post's location string is what a client already sent and what the UI already
shows; the gazetteer only ever MATCHES against a name, never returns one - see
gazetteer.go's own `Candidate`, which has no name field at all), so storing the text at
all past match time was pure overhead. A primary name and every one of its alternate names
each become their own row in that same hash-keyed table, tagged PRIMARY or ALIAS and
pointing at a shared, deduplicated entries table (lat/lng/population) - see gazetteer.go's
own doc comment for exactly why that tag still has to survive even though the name text
doesn't (the Great Falls, MT / Paterson, NJ "Great Falls" alias case).
"""

import csv
import re
import struct
import sys
import time

ASCII_ALIAS_RE = re.compile(r"^[A-Za-z0-9 .'\-]+$")

# Coordinates are stored as fixed-point int32, scaled by this many units per degree -
# exactly matching GeoNames' own 5-decimal-place precision (e.g. 38.72509 -> 3872509), so
# the round trip back to float64 in Go reproduces bit-for-bit the same value
# strconv.ParseFloat would give the original decimal string (verified directly: every
# pinned coordinate in gazetteer_test.go round-trips exactly at this scale). This halves
# each entry's coordinate storage against float64 (8 bytes) at zero precision cost.
COORD_SCALE = 100_000

# FNV-1a, 64-bit - the exact algorithm Go's own hash/fnv.New64a() implements (verified
# directly: this Python implementation and Go's stdlib one were compared byte-for-byte
# against the same test strings before this format shipped). Not cryptographic, and
# doesn't need to be: this only has to distribute several million short strings evenly
# enough for a sorted binary search, not resist a deliberate attacker.
#
# On collisions: this format stores no name text at all past pack time (see this module's
# own doc comment), so two DIFFERENT normalized "ISO\x00name" strings that happened to hash
# to the same 64-bit value would be indistinguishable at query time - their rows would
# simply merge into one lookup result. This was considered and accepted deliberately: at
# 64 bits of hash space against this dataset's own row count (order 10 million, primary
# rows plus every alternate-name row combined - see main()'s own final count), the
# birthday-bound probability of even one such collision anywhere in the whole table is
# on the order of 1 in 300,000 - and even if one did occur, the practical effect is two
# real, unrelated places occasionally sharing a match, not a systemic failure of any kind.
FNV64_OFFSET_BASIS = 0xCBF29CE484222325
FNV64_PRIME = 0x100000001B3
FNV64_MASK = (1 << 64) - 1


def fnv1a64(s: str) -> int:
    h = FNV64_OFFSET_BASIS
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * FNV64_PRIME) & FNV64_MASK
    return h


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


def normalize_key(s: str) -> str:
    # Mirrors gazetteer.go's normalizeKey exactly (case-insensitive, internal whitespace
    # runs collapsed to one space) - this packer folds and hashes a key once, offline,
    # rather than at every server startup; the two fold rules have to agree byte-for-byte,
    # or a query hash built in Go would never match the row the packer meant it to.
    return " ".join(s.split()).lower()


MAX_EXTRA_ALIASES = 12

FLAG_PRIMARY = 1
FLAG_ALIAS = 0

# Header layout - see SOURCE.md's "Format" section for the full field-by-field
# description. Fixed size and fixed field order: gazetteer.go reads it with one ReadAt at
# file offset 0, so every other section's offset is known before any of their actual bytes
# are read.
HEADER_FORMAT = "<4sI QQQ IQQQ"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
MAGIC = b"PLC3"


def main() -> None:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <input allCountriesP_filtered.txt> <output places.bin>",
              file=sys.stderr)
        sys.exit(2)
    input_path, output_path = sys.argv[1], sys.argv[2]

    t0 = time.time()
    entries: list = []  # (lat_fixed, lng_fixed, population) - one per real GeoNames row
    key_rows: list = []  # (hash, entry_idx, flag) - one per (row, name-or-alias) pair

    with open(input_path, encoding="utf-8") as f:
        reader = csv.reader(f, delimiter="\t")
        for i, parts in enumerate(reader):
            if len(parts) < 15:
                continue
            name = parts[1].strip()
            asciiname = parts[2].strip()
            alt = parts[3]
            try:
                lat = round(float(parts[4]) * COORD_SCALE)
                lng = round(float(parts[5]) * COORD_SCALE)
            except ValueError:
                continue
            iso = parts[8].strip()
            try:
                population = int(parts[14]) if parts[14] else 0
            except ValueError:
                population = 0

            primary = asciiname if asciiname else name
            if not primary or not iso:
                continue

            idx = len(entries)
            entries.append((lat, lng, population))

            primary_key = iso + "\x00" + normalize_key(primary)
            key_rows.append((fnv1a64(primary_key), idx, FLAG_PRIMARY))

            seen = {primary.lower()}
            extras = []
            if name and name.lower() not in seen:
                extras.append(name)
                seen.add(name.lower())
            if alt:
                for a in alt.split(","):
                    a = a.strip()
                    if not usable_alias(a):
                        continue
                    key = a.lower()
                    if key in seen:
                        continue
                    seen.add(key)
                    extras.append(a)
            extras.sort(key=lambda n: (len(n), n))
            for a in extras[:MAX_EXTRA_ALIASES]:
                akey = iso + "\x00" + normalize_key(a)
                if akey == primary_key:
                    continue
                key_rows.append((fnv1a64(akey), idx, FLAG_ALIAS))

            if i % 1_000_000 == 0:
                print(f"{i} rows, {time.time() - t0:.1f}s", file=sys.stderr)

    print(f"entries: {len(entries)}, key rows: {len(key_rows)}, {time.time() - t0:.1f}s",
          file=sys.stderr)

    key_rows.sort(key=lambda r: r[0])
    print(f"sorted, {time.time() - t0:.1f}s", file=sys.stderr)

    key_count = len(key_rows)
    hashes = struct.pack(f"<{key_count}Q", *(r[0] for r in key_rows))
    entry_indices = struct.pack(f"<{key_count}I", *(r[1] for r in key_rows))
    flags = struct.pack(f"<{key_count}B", *(r[2] for r in key_rows))

    entry_count = len(entries)
    lat_bytes = struct.pack(f"<{entry_count}i", *(e[0] for e in entries))
    lng_bytes = struct.pack(f"<{entry_count}i", *(e[1] for e in entries))
    pop_bytes = struct.pack(f"<{entry_count}i", *(e[2] for e in entries))

    hashes_offset = HEADER_SIZE
    entry_indices_offset = hashes_offset + len(hashes)
    flags_offset = entry_indices_offset + len(entry_indices)
    lat_offset = flags_offset + len(flags)
    lng_offset = lat_offset + len(lat_bytes)
    pop_offset = lng_offset + len(lng_bytes)

    header = struct.pack(
        HEADER_FORMAT,
        MAGIC,
        key_count,
        hashes_offset,
        entry_indices_offset,
        flags_offset,
        entry_count,
        lat_offset,
        lng_offset,
        pop_offset,
    )
    assert len(header) == HEADER_SIZE

    with open(output_path, "wb") as f:
        f.write(header)
        f.write(hashes)
        f.write(entry_indices)
        f.write(flags)
        f.write(lat_bytes)
        f.write(lng_bytes)
        f.write(pop_bytes)

    total = pop_offset + len(pop_bytes)
    print(f"wrote {output_path}: {total} bytes, {time.time() - t0:.1f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
