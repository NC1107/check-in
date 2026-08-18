"""The zigzag-varint delta encoding shared by pack_world.py and pack_region.py - not part
of the Flutter build, imported by the two pack scripts only. See either script's own doc
comment for the binary layout each builds around this, and region_outlines.dart/
world_outlines.dart for the matching Dart-side decoder.
"""

# Fixed-point units per degree that every coordinate in both assets is quantized to.
#
# Defined here once because it is a property of the ENCODING, not of either script: the
# Dart decoder divides by exactly this (see outline_codec.dart's own
# kOutlineCoordinateScale), so a packer using a different value would not fail loudly - it
# would silently draw every coastline in the world at the wrong size.
#
# 1000 (0.001 degrees, ~110m) rather than the 100 this originally shipped with. Both layers
# are simplified at a FINER tolerance than 0.01 degrees, so the coarser grid was throwing
# away detail that had already been paid for and snapping every coastline onto a ~1.1km
# lattice - visible as angular, wrong-looking geometry as soon as the map could be zoomed.
SCALE = 1000


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


def rings_of(geom):
    """Every linear ring (exterior and interior alike) of a Polygon/MultiPolygon, as a plain
    list of (lng, lat) tuples.

    A hole is just another closed ring here, not tagged as such: painting every ring with an
    even-odd fill reproduces holes for free without this format needing to know which rings
    are holes (see world_outlines.dart).

    Duck-typed rather than importing shapely, so this module stays a pure encoder with no
    dependencies of its own - the pack scripts are what need shapely.
    """
    if geom.geom_type == "Polygon":
        yield list(geom.exterior.coords)
        for interior in geom.interiors:
            yield list(interior.coords)
    elif geom.geom_type == "MultiPolygon":
        for part in geom.geoms:
            yield from rings_of(part)


def lines_of(geom):
    """Every path of a LineString/MultiLineString - what the river layer is made of."""
    if geom.geom_type == "LineString":
        yield list(geom.coords)
    elif geom.geom_type == "MultiLineString":
        for part in geom.geoms:
            yield from lines_of(part)


def pack_group(buf: bytearray, rings) -> None:
    """Writes one ring group: a ring count, then each ring's point count followed by its
    zigzag-varint (dx, dy) deltas.

    Defined once here rather than in each pack script because it IS the format - all three
    assets are read back by the same OutlineReader, so a copy of this that drifted would
    produce a file the decoder still parses and silently draws wrong.
    """
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
