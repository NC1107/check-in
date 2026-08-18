"""Rebuilds world_outlines.bin from a raw Natural Earth 1:110m admin-0-countries export.

Not part of the Flutter build - a one-off transform to regenerate the embedded map asset,
the same pattern server/internal/gazetteer/data/pack_cities.py uses for the city gazetteer.
Requires shapely (`pip install shapely`). Run from this directory with
ne_110m_admin_0_countries.geojson (downloaded from
https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson,
Natural Earth's own public-domain 1:110m countries layer) alongside it:

    python3 pack_world.py

writes world_outlines.bin next to this script. See SOURCE.md for the binary format, the
simplification tolerance, and why holes don't need special-casing here.
"""

import json
import sys

from shapely.geometry import shape

# Degrees of Douglas-Peucker simplification tolerance (preserve_topology=True, so no ring
# collapses to nothing). Chosen empirically: it roughly halves the raw point count while the
# quantization below (0.01 degree) is already the real precision floor, so most of what
# simplify() removes at this tolerance is redundant near-collinear detail invisible at the
# small size this ever renders at - see SOURCE.md for the point/byte counts at nearby
# tolerances this was chosen against.
SIMPLIFY_TOLERANCE_DEG = 0.1

# Quantization: coordinates are stored as integers of this many units per degree. 100 units/
# degree (~1.1km of latitude) is far finer than this asset is ever rendered at, and keeps
# every coordinate a small varint.
SCALE = 100


def usable_ring(points):
    return len(points) >= 3


def rings_of(geom):
    """Yields every linear ring (exterior and interior alike) of a Polygon/MultiPolygon as a
    plain list of (lng, lat) tuples with the redundant closing point dropped - a hole is
    just another closed ring here, not tagged as such: painting every ring from every
    country into one Path with an even-odd fill rule reproduces holes for free without this
    format needing to know which rings are holes (see world_outlines.dart)."""
    if geom.geom_type == "Polygon":
        yield list(geom.exterior.coords)
        for interior in geom.interiors:
            yield list(interior.coords)
    elif geom.geom_type == "MultiPolygon":
        for part in geom.geoms:
            yield from rings_of(part)


def zigzag_encode(n: int) -> int:
    return (n << 1) if n >= 0 else (((-n) << 1) - 1)


def write_varint(buf: bytearray, value: int) -> None:
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            buf.append(b | 0x80)
        else:
            buf.append(b)
            return


def pack(features, tolerance_deg: float) -> bytes:
    all_rings = []
    for feature in features:
        geom = shape(feature["geometry"]).simplify(tolerance_deg, preserve_topology=True)
        for ring in rings_of(geom):
            # Every raw ring is closed (first point == last); drop the duplicate before
            # storing since world_outlines.dart's parser always treats a ring as closed.
            points = ring[:-1] if ring and ring[0] == ring[-1] else ring
            if usable_ring(points):
                all_rings.append(points)

    buf = bytearray()
    write_varint(buf, len(all_rings))
    for points in all_rings:
        write_varint(buf, len(points))
        prev_x, prev_y = 0, 0
        for lng, lat in points:
            x = round(lng * SCALE)
            y = round(lat * SCALE)
            write_varint(buf, zigzag_encode(x - prev_x))
            write_varint(buf, zigzag_encode(y - prev_y))
            prev_x, prev_y = x, y
    return bytes(buf)


def main() -> None:
    with open("ne_110m_admin_0_countries.geojson", encoding="utf-8") as f:
        data = json.load(f)
    features = data["features"]
    print(f"countries: {len(features)}", file=sys.stderr)

    packed = pack(features, SIMPLIFY_TOLERANCE_DEG)
    with open("world_outlines.bin", "wb") as out:
        out.write(packed)
    print(f"world_outlines.bin: {len(packed)} bytes", file=sys.stderr)


if __name__ == "__main__":
    main()
