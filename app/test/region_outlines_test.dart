import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/memories/map/region_outlines.dart';

/// The packed region-outline asset's binary parser (see assets/worldmap/SOURCE.md for the
/// format pack_region.py writes and this reads back) - built and checked entirely in
/// memory here, without touching the real ~300KB asset, so a corrupt/truncated real file
/// would show up as a parser bug being caught by these tests rather than a silent asset
/// problem. See world_outlines_test.dart for the single-group version of this same
/// per-ring encoding this format wraps in two groups.
void main() {
  int zigzagEncode(int n) => n >= 0 ? (n << 1) : (((-n) << 1) - 1);

  void writeVarint(BytesBuilder buf, int value) {
    while (true) {
      final b = value & 0x7F;
      value >>= 7;
      if (value != 0) {
        buf.addByte(b | 0x80);
      } else {
        buf.addByte(b);
        return;
      }
    }
  }

  void writeRing(BytesBuilder buf, List<(int, int)> ring) {
    writeVarint(buf, ring.length);
    var prevX = 0, prevY = 0;
    for (final (x, y) in ring) {
      writeVarint(buf, zigzagEncode(x - prevX));
      writeVarint(buf, zigzagEncode(y - prevY));
      prevX = x;
      prevY = y;
    }
  }

  /// Builds a buffer in exactly the format pack_region.py writes: a group count, then
  /// each group's own ring count and rings (same per-ring shape as
  /// world_outlines_test.dart's own buildBuffer) - [groups] is admin-0's rings first,
  /// admin-1's second, matching the real asset's own group order.
  ByteData buildBuffer(List<List<List<(int, int)>>> groups) {
    final buf = BytesBuilder();
    writeVarint(buf, groups.length);
    for (final rings in groups) {
      writeVarint(buf, rings.length);
      for (final ring in rings) {
        writeRing(buf, ring);
      }
    }
    final bytes = buf.toBytes();
    return ByteData.sublistView(bytes);
  }

  test('an empty buffer (zero groups) parses to two empty ring lists', () {
    final outlines = parseRegionOutlines(buildBuffer(const []));
    expect(outlines.admin0Rings, isEmpty);
    expect(outlines.admin1Rings, isEmpty);
  });

  test('a group with zero rings still parses cleanly', () {
    final outlines = parseRegionOutlines(buildBuffer(const [[], []]));
    expect(outlines.admin0Rings, isEmpty);
    expect(outlines.admin1Rings, isEmpty);
  });

  test('admin-0 and admin-1 rings are kept as two separate lists, in the right order', () {
    final outlines = parseRegionOutlines(buildBuffer([
      [
        [(0, 0), (1000, 0), (500, 1000)], // a country outline
      ],
      [
        [(0, 0), (500, 0), (250, 500)], // a state boundary
        [(-1000, -1000), (-500, -1000), (-500, -500)], // a second state boundary
      ],
    ]));

    expect(outlines.admin0Rings, hasLength(1));
    expect(outlines.admin0Rings.single,
        [const Offset(0, 0), const Offset(10, 0), const Offset(5, 10)]);

    expect(outlines.admin1Rings, hasLength(2));
    expect(outlines.admin1Rings[0], hasLength(3));
    expect(outlines.admin1Rings[1].first, const Offset(-10, -10));
  });

  test('negative deltas decode correctly via zigzag, in either group', () {
    final outlines = parseRegionOutlines(buildBuffer([
      [
        [(500, 500), (400, 400), (300, 300)],
      ],
      [
        [(200, 200), (100, 100)],
      ],
    ]));

    expect(
        outlines.admin0Rings.single, [const Offset(5, 5), const Offset(4, 4), const Offset(3, 3)]);
    expect(outlines.admin1Rings.single, [const Offset(2, 2), const Offset(1, 1)]);
  });
}
