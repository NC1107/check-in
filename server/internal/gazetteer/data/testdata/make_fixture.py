"""Builds fixture.bin: a small, hand-curated places.bin in the exact same on-disk format
(see ../SOURCE.md's "Format" section and ../pack_places.py) covering exactly the real-world
cases this package's own resolution logic tests need - proximity disambiguation, anchors,
population dominance, alias tiering, and the merge-when-all-primary-is-zero-population
rule. It exists because the real, full dataset is never committed to this repo (fetched and
packed at Docker build time - see ../SOURCE.md) and CI checks out a clean tree with no
network access to build one: without a fixture, every test asserting a real coordinate
would either fail outright or - worse - silently skip and stop exercising the very logic
that has had the real bugs in this feature (see gazetteertest's own doc comment for how
tests point themselves at this file instead of the real one).

Run from this directory to regenerate:

    python3 make_fixture.py

Every coordinate and population below is a REAL value from the real GeoNames dataset (the
same one ../pack_places.py packs in full) - nothing here is invented. What's curated is
which real rows are INCLUDED: exactly the ones a specific test needs, trimmed of
population-0 "noise" rivals that don't change any test's outcome (a name's ambiguity or
its anchor-dominance ratio only depends on which candidates are present and their
populations, never on how many additional zero-population rivals also exist - see each
place's own comment below for what it's proving).
"""

import sys

sys.path.insert(0, "..")
from pack_places import (  # noqa: E402 - see the sys.path.insert above
    COORD_SCALE,
    key_rows_for,
    serialize,
)

# Each entry is (name, iso, lat, lng, population, extra_alias_names) - "name" becomes a
# PRIMARY key row; each of extra_alias_names becomes its own ALIAS key row, both pointing
# at the same entry (see ../SOURCE.md's "Format" section for why an alias never duplicates
# the coordinates). "name" itself is never stored past hashing (see pack_places.py's own
# doc comment) - it's here purely so this file stays readable as source.
ENTRIES = [
    # --- Lisbon: the plain single-candidate, case/whitespace-fold happy path. ---
    ("Lisbon", "PT", 38.72509, -9.1498, 517802, []),
    # --- Denver: another plain single-candidate place, used across several places_test.go
    # aggregation tests (cover picks, ordering, tie-breaks) that don't care about
    # ambiguity at all. ---
    ("Denver", "US", 39.73915, -104.9847, 715522, []),
    # --- Austin / Zurich: single-candidate places used only as aggregation-test filler
    # (home-area logic, tie-break-by-location). ---
    ("Austin", "US", 30.26715, -97.74306, 961855, []),
    ("Zurich", "CH", 47.36667, 8.55, 402762, []),
    # --- Arlington: the ORIGINAL bug's own regression case. Three real US Arlingtons -
    # Virginia (what a DC-anchored group means), Texas (the single most populous, what a
    # population-only tiebreak wrongly picks), and a third real Arlington inside Baltimore
    # City itself (what a Baltimore-ONLY-anchored group's own proximity resolves to,
    # nearer to Baltimore than VA's is) - see places_test.go's own arlingtonVA/arlingtonTX/
    # arlingtonMD tests for all three directions this is disambiguated in.
    ("Arlington", "US", 38.88101, -77.10428, 208437, []),  # VA
    ("Arlington", "US", 32.73569, -97.10807, 388125, []),  # TX - most populous
    ("Arlington", "US", 39.34857, -76.68324, 3065, []),  # MD - inside Baltimore City
    # --- Great Falls: MT (most populous, the old population-only bug's wrong answer), VA
    # and MD (both real, both near a DC-anchored group - MD is the one that actually wins
    # proximity there), plus Paterson, NJ's OWN entry, referenced ONLY by its "Great Falls"
    # ALIAS (never a primary row for "Paterson" - nothing queries that) - the alternate-
    # name-tiering regression case: Paterson's much larger population must never let its
    # merely-historical alias outrank a real town PRIMARILY named Great Falls.
    ("Great Falls", "US", 47.50024, -111.30081, 59638, []),  # MT
    ("Great Falls", "US", 38.99817, -77.28832, 15427, []),  # VA
    ("Great Falls", "US", 39.00233, -77.24609, 0, []),  # MD
    ("Paterson", "US", 40.91677, -74.17181, 147754, ["Great Falls"]),
    # --- New York: the alias-merge regression case. Every one of these PRIMARY "New York"
    # rows is a real, unrelated, population-0 rural crossroads (see gazetteer.go's own
    # Candidates doc comment) - New York City itself is reachable only through its own
    # "New York" ALIAS (its real primary name is "New York City", not included here since
    # nothing queries it directly). Without the merge-when-all-primary-population-is-zero
    # rule, these obscure primaries would silently block NYC's alias from ever being
    # offered as a candidate at all.
    ("New York", "US", 39.68529, -93.92688, 0, []),  # MO
    ("New York", "US", 30.83852, -87.2008, 0, []),  # FL
    ("New York", "US", 36.98894, -88.95256, 0, []),  # KY
    ("New York City", "US", 40.71427, -74.00597, 8804190, ["New York"]),
    # --- Ocean City: the small-town-coverage regression case (this exact name is what
    # cities15000 dropped entirely). MD is what a Baltimore-anchored group means; NJ is the
    # more populous wrong answer a population-only tiebreak picks; FL/WA round out the real
    # candidate set. ---
    ("Ocean City", "US", 38.3365, -75.08491, 7055, []),  # MD
    ("Ocean City", "US", 39.27762, -74.5746, 11355, []),  # NJ - most populous
    ("Ocean City", "US", 30.44103, -86.61356, 5550, []),  # FL
    ("Ocean City", "US", 47.07092, -124.16601, 200, []),  # WA
    # --- Mathias, WV: population 0, the single-candidate small-town case cities15000 (and
    # even cities500) dropped outright - this app's own founding evidence for why no
    # population floor works at all. ---
    ("Mathias", "US", 38.87789, -78.86614, 0, []),
    # --- Gaithersburg: single-candidate, one of the founder group's own real anchors. ---
    ("Gaithersburg", "US", 39.14344, -77.20137, 67456, []),
    # --- Washington: the anchor-DOMINANCE regression case. DC's real population (689,545)
    # outnumbers the next real US "Washington" (Utah, 24,299) by ~28x - comfortably past
    # kAnchorDominanceRatio (10x, see places.go) - which is what lets DC anchor a group's
    # OTHER ambiguous places even though "Washington, United States" is no longer the
    # single-candidate match it was under the old population-floored dataset.
    ("Washington", "US", 38.89511, -77.03637, 689545, []),  # DC
    ("Washington", "US", 37.13054, -113.50829, 24299, []),  # UT
    # --- Columbia: MD is what a DC-area group means; SC is the more populous wrong answer
    # a population-only tiebreak picks (not dominant enough to auto-anchor - see
    # kAnchorDominanceRatio - so this stays a genuine proximity-disambiguation case). ---
    ("Columbia", "US", 39.24038, -76.83942, 99615, []),  # MD
    ("Columbia", "US", 34.00071, -81.03481, 142416, []),  # SC - more populous
    # --- Poolesville: MD is real (population 5,201, still below cities15000's bar); VA is
    # a real, unrelated, population-0 rival. ---
    ("Poolesville", "US", 39.14594, -77.41693, 5201, []),  # MD
    ("Poolesville", "US", 37.09265, -76.72412, 0, []),  # VA
    # --- Boyds: every real candidate is population-0 except a barely-populated Washington
    # State one (34) - the "a lone tiny nonzero population is not meaningfully different
    # from its zero-population rivals" case (kAnchorDominanceMinPopulation), proving MD
    # still wins by proximity rather than WA winning by technically-nonzero population.
    ("Boyds", "US", 32.81735, -85.40467, 0, []),  # AL
    ("Boyds", "US", 39.18372, -77.31276, 0, []),  # MD
    ("Boyds", "US", 39.49506, -83.38325, 0, []),  # OH
    ("Boyds", "US", 48.724, -118.132, 34, []),  # WA
    # --- Dickerson: every real candidate is population-0; MD wins purely by proximity. ---
    ("Dickerson", "US", 39.2201, -77.42415, 0, []),  # MD
    ("Dickerson", "US", 34.32122, -90.63649, 0, []),  # MS
    ("Dickerson", "US", 35.13738, -77.01272, 0, []),  # NC
    ("Dickerson", "US", 36.26487, -78.55167, 0, []),  # NC
    ("Dickerson", "US", 40.31837, -88.42228, 0, []),  # IL
    # --- Moorefield: WV is real (population 2,482); several rivals carry small nonzero
    # populations (AR 137, NE 30) that must not outrank WV on population alone - proximity
    # to the founder group's other anchors is what has to win here. ---
    ("Moorefield", "US", 32.82513, -85.44412, 0, []),  # AL
    ("Moorefield", "US", 35.76841, -91.57041, 137, []),  # AR
    ("Moorefield", "US", 38.80562, -85.17023, 0, []),  # KY
    ("Moorefield", "US", 38.27313, -83.93104, 0, []),  # KY
    ("Moorefield", "US", 33.28878, -80.1687, 0, []),  # SC
    ("Moorefield", "US", 39.06233, -78.96947, 2482, []),  # WV
    ("Moorefield", "US", 40.19979, -81.17094, 0, []),  # OH
    ("Moorefield", "US", 40.69001, -100.39931, 30, []),  # NE
    # --- Rockville: MD (66,980) against its real most-populous rival, CT (7,474) - a
    # ~8.96x ratio, deliberately just BELOW kAnchorDominanceRatio (10x), so this stays a
    # genuine proximity case rather than auto-anchoring on dominance alone. ---
    ("Rockville", "US", 39.084, -77.15276, 66980, []),  # MD
    ("Rockville", "US", 41.86676, -72.44953, 7474, []),  # CT
    # --- White Plains: the second half of the founder's own real evidence - the wrong dot
    # (White Plains, NY, real population 58,459) versus the right one (White Plains,
    # Charles County, MD, population 0, twenty minutes from the rest of the founder's own
    # group) - the exact case that used to resolve to New York because Maryland's own row
    # had no population floor clearing any of cities500/1000/5000/15000's bars at all.
    ("White Plains", "US", 38.5904, -76.94025, 0, []),  # MD - Charles County
    ("White Plains", "US", 38.37178, -75.54576, 0, []),  # MD - Somerset County
    ("White Plains", "US", 41.03399, -73.76291, 58459, []),  # NY - more populous, wrong
    ("White Plains", "US", 33.74732, -85.68913, 811, []),  # AL
    ("White Plains", "US", 37.18366, -87.38361, 872, []),  # KY
    # --- Baltimore: dominance via a wide RATIO (585,708 / 2,970 ≈ 197x) - the anchor for
    # the Baltimore-only Arlington test above, and one leg of the DC-group test below. ---
    ("Baltimore", "US", 39.29038, -76.61219, 585708, []),  # MD
    ("Baltimore", "US", 39.84534, -82.60072, 2970, []),  # OH
    # --- Silver Spring: unambiguous on its own (a single real candidate) - anchors
    # directly, no dominance math needed at all; the DC-group test's second leg. ---
    ("Silver Spring", "US", 38.99067, -77.02609, 71452, []),
    # --- Bethesda: dominance via ratio again (60,858 / 1,245 ≈ 48.9x) - the DC-group
    # test's third leg. ---
    ("Bethesda", "US", 38.98067, -77.10026, 60858, []),  # MD
    ("Bethesda", "US", 40.01618, -81.0726, 1245, []),  # OH
]


def build() -> bytes:
    entries = []
    key_rows = []
    for name, iso, lat, lng, population, aliases in ENTRIES:
        idx = len(entries)
        entries.append((round(lat * COORD_SCALE), round(lng * COORD_SCALE), population))
        key_rows.extend(key_rows_for(iso, name, aliases, idx))
    return serialize(entries, key_rows)


def main() -> None:
    data = build()
    with open("fixture.bin", "wb") as f:
        f.write(data)
    print(f"wrote fixture.bin: {len(data)} bytes, {len(ENTRIES)} entries", file=sys.stderr)


if __name__ == "__main__":
    main()
