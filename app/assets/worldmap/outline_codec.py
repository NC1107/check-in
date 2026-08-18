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
