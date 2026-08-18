"""Rebuilds region_outlines.bin from raw Natural Earth 1:50m admin-0-countries and
admin-1-states-provinces exports.

Not part of the Flutter build - a one-off transform to regenerate the embedded map asset,
the same pattern pack_world.py (this directory) uses for the coarser world-tier asset.
Requires shapely (`pip install shapely`). Run from this directory with
ne_50m_admin_0_countries.geojson and ne_50m_admin_1_states_provinces.geojson (both from
https://github.com/nvkelso/natural-earth-vector/tree/master/geojson, Natural Earth's own
public-domain 1:50m layers) alongside it:

    python3 pack_region.py

writes region_outlines.bin next to this script. See SOURCE.md for the binary format
(two ring GROUPS rather than world_outlines.bin's single flat list - see
region_outlines.dart), the simplification tolerance, and why admin-1 boundaries are kept
as plain rings too rather than tagged with which country/state they belong to.
"""

import json
import sys

from shapely.geometry import shape

from outline_codec import write_varint, zigzag_encode

# Degrees of Douglas-Peucker simplification tolerance (preserve_topology=True). Far finer
# than pack_world.py's 0.1 - this asset is what the map actually renders at region/local
# zoom (see places_map_view.dart), where 0.1 degrees (~11km between vertices) reads as an
# angular blob. 0.005 degrees (~550m) is close to where simplify() stops removing anything
# beyond what's already redundant at 1:50m source resolution - see SOURCE.md for the
# byte counts at nearby tolerances this was chosen against.
SIMPLIFY_TOLERANCE_DEG = 0.005

SCALE = 100  # same quantization as pack_world.py - see its own doc comment.


def usable_ring(points):
    return len(points) >= 3


def rings_of(geom):
    """Yields every linear ring of a Polygon/MultiPolygon, exterior and interior (hole)
    alike, as a plain list of (lng, lat) tuples with the redundant closing point dropped -
    same convention as pack_world.py's own rings_of, and for the same reason: neither
    layer this writes needs to know which of its own rings are holes at render time (see
    region_outlines.dart)."""
    if geom.geom_type == "Polygon":
        yield list(geom.exterior.coords)
        for interior in geom.interiors:
            yield list(interior.coords)
    elif geom.geom_type == "MultiPolygon":
        for part in geom.geoms:
            yield from rings_of(part)


def simplified_rings(features, tolerance_deg):
    out = []
    for feature in features:
        geom = shape(feature["geometry"]).simplify(tolerance_deg, preserve_topology=True)
        for ring in rings_of(geom):
            points = ring[:-1] if ring and ring[0] == ring[-1] else ring
            if usable_ring(points):
                out.append(points)
    return out


def pack_group(buf: bytearray, rings) -> None:
    write_varint(buf, len(rings))
    for points in rings:
        write_varint(buf, len(points))
        prev_x, prev_y = 0, 0
        for lng, lat in points:
            x = round(lng * SCALE)
            y = round(lat * SCALE)
            write_varint(buf, zigzag_encode(x - prev_x))
            write_varint(buf, zigzag_encode(y - prev_y))
            prev_x, prev_y = x, y


def main() -> None:
    with open("ne_50m_admin_0_countries.geojson", encoding="utf-8") as f:
        admin0_features = json.load(f)["features"]
    with open("ne_50m_admin_1_states_provinces.geojson", encoding="utf-8") as f:
        admin1_features = json.load(f)["features"]
    print(f"admin-0 countries: {len(admin0_features)}", file=sys.stderr)
    print(f"admin-1 states/provinces: {len(admin1_features)}", file=sys.stderr)

    admin0_rings = simplified_rings(admin0_features, SIMPLIFY_TOLERANCE_DEG)
    admin1_rings = simplified_rings(admin1_features, SIMPLIFY_TOLERANCE_DEG)

    buf = bytearray()
    write_varint(buf, 2)  # group count: admin-0 (filled), then admin-1 (stroked only)
    pack_group(buf, admin0_rings)
    pack_group(buf, admin1_rings)

    with open("region_outlines.bin", "wb") as out:
        out.write(bytes(buf))
    print(f"region_outlines.bin: {len(buf)} bytes "
          f"(admin-0: {sum(len(r) for r in admin0_rings)} pts, "
          f"admin-1: {sum(len(r) for r in admin1_rings)} pts)", file=sys.stderr)


if __name__ == "__main__":
    main()
