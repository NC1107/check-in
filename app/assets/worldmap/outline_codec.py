"""The zigzag-varint delta encoding shared by pack_world.py and pack_region.py - not part
of the Flutter build, imported by the two pack scripts only. See either script's own doc
comment for the binary layout each builds around this, and region_outlines.dart/
world_outlines.dart for the matching Dart-side decoder.
"""


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
