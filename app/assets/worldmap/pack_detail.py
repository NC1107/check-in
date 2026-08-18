"""Rebuilds detail_outlines.bin from raw Natural Earth 1:50m lakes, rivers and urban-area
exports.

Not part of the Flutter build - a one-off transform to regenerate the embedded asset, the
same pattern pack_world.py and pack_region.py use for the other two map layers. Requires
shapely (`pip install shapely`). Run from this directory with ne_50m_lakes.geojson,
ne_50m_rivers_lake_centerlines.geojson and ne_50m_urban_areas.geojson alongside it (all
from https://github.com/nvkelso/natural-earth-vector/tree/master/geojson, Natural Earth's
own public-domain 1:50m layers):

    python3 pack_detail.py

writes detail_outlines.bin next to this script.

Why these three layers and not a terrain raster: a bundled shaded-relief image is a fixed
resolution, so it looks its best zoomed out and goes soft exactly at the few-degree span a
real group's own places actually fit into - to stay sharp there a world raster would need
to be on the order of 100,000 pixels wide. Vector features have no such limit, and lakes,
rivers and towns are what a region is actually RECOGNISED by: the map reads as a real place
because the Potomac is on it, not because the hills are shaded.

Three ring GROUPS in the order the map paints them (see detail_outlines.dart): lakes
(filled like ocean), rivers (stroked), urban areas (filled as a faint tint). Same varint
container as pack_region.py's own two-group file - see SOURCE.md for the byte layout.
"""

import json
import sys

from shapely.geometry import shape

from outline_codec import lines_of, pack_group, rings_of, write_varint

# Matches pack_region.py's own tolerance: this asset is drawn at the same region/local zoom
# its admin-0/admin-1 layers are, so a coarser one here would read as obviously blockier
# water sitting on top of a finer coastline.
SIMPLIFY_TOLERANCE_DEG = 0.005

# Rivers are stored as centerlines rather than as banks, so a 2-point line is a legitimate
# feature, unlike an area ring which needs 3 to enclose anything.
MIN_AREA_POINTS = 3
MIN_LINE_POINTS = 2


def simplified(features, tolerance_deg, *, areas: bool):
    out = []
    minimum = MIN_AREA_POINTS if areas else MIN_LINE_POINTS
    for feature in features:
        geometry = feature.get("geometry")
        if not geometry:
            continue
        geom = shape(geometry).simplify(tolerance_deg, preserve_topology=True)
        parts = rings_of(geom) if areas else lines_of(geom)
        for part in parts:
            # An area ring repeats its first point at the end; a line does not, and
            # trimming one that merely happens to be closed would silently open it.
            points = part[:-1] if areas and part and part[0] == part[-1] else part
            if len(points) >= minimum:
                out.append(points)
    return out


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)["features"]


def main() -> None:
    lakes = simplified(load("ne_50m_lakes.geojson"), SIMPLIFY_TOLERANCE_DEG, areas=True)
    rivers = simplified(
        load("ne_50m_rivers_lake_centerlines.geojson"), SIMPLIFY_TOLERANCE_DEG, areas=False)
    urban = simplified(load("ne_50m_urban_areas.geojson"), SIMPLIFY_TOLERANCE_DEG, areas=True)

    buf = bytearray()
    write_varint(buf, 3)  # lakes (filled), rivers (stroked), urban areas (tinted)
    pack_group(buf, lakes)
    pack_group(buf, rivers)
    pack_group(buf, urban)

    with open("detail_outlines.bin", "wb") as out:
        out.write(bytes(buf))
    print(f"detail_outlines.bin: {len(buf)} bytes "
          f"(lakes: {len(lakes)} rings/{sum(len(r) for r in lakes)} pts, "
          f"rivers: {len(rivers)} lines/{sum(len(r) for r in rivers)} pts, "
          f"urban: {len(urban)} rings/{sum(len(r) for r in urban)} pts)", file=sys.stderr)


if __name__ == "__main__":
    main()
