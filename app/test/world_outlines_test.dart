import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/memories/map/world_outlines.dart';

/// The packed world-outline asset's binary parser (see assets/worldmap/SOURCE.md for the
/// format pack_world.py writes and this reads back) - built and checked entirely in memory
/// here, without touching the real ~23KB asset, so a corrupt/truncated real file would show
/// up as a parser bug being caught by these tests rather than a silent asset problem.
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

  /// Builds a buffer in exactly the format pack_world.py writes: a ring count, then each
  /// ring's point count followed by zigzag-varint (dx, dy) deltas from the previous point
  /// (the first point's delta is from the origin) - see this function's callers for the
  /// [rings] each test exercises, where each ring is a list of (lng, lat) *100 integer
  /// pairs (matching pack_world.py's own SCALE).
  ByteData buildBuffer(List<List<(int, int)>> rings) {
    final buf = BytesBuilder();
    writeVarint(buf, rings.length);
    for (final ring in rings) {
      writeVarint(buf, ring.length);
      var prevX = 0, prevY = 0;
      for (final (x, y) in ring) {
        writeVarint(buf, zigzagEncode(x - prevX));
        writeVarint(buf, zigzagEncode(y - prevY));
        prevX = x;
        prevY = y;
      }
    }
    final bytes = buf.toBytes();
    return ByteData.sublistView(bytes);
  }

  test('an empty buffer (zero rings) parses to an empty list', () {
    final rings = parseWorldOutlines(buildBuffer(const []));
    expect(rings, isEmpty);
  });

  test('a single triangle ring round-trips exactly, scaled back down by 100', () {
    final data = buildBuffer([
      [(0, 0), (1000, 0), (500, 1000)], // a 10°x10° right triangle
    ]);
    final rings = parseWorldOutlines(data);

    expect(rings, hasLength(1));
    expect(rings.single, [const Offset(0, 0), const Offset(10, 0), const Offset(5, 10)]);
  });

  test('multiple rings are each parsed independently, in order', () {
    final data = buildBuffer([
      [(0, 0), (100, 0), (0, 100)],
      [(-1000, -2000), (-500, -2000), (-500, -1500)],
    ]);
    final rings = parseWorldOutlines(data);

    expect(rings, hasLength(2));
    expect(rings[0], hasLength(3));
    expect(rings[1].first, const Offset(-10, -20));
  });

  test('negative deltas (a ring that moves west/south) decode correctly via zigzag', () {
    final data = buildBuffer([
      [(500, 500), (400, 400), (300, 300)], // strictly decreasing x and y
    ]);
    final rings = parseWorldOutlines(data);

    expect(rings.single, [const Offset(5, 5), const Offset(4, 4), const Offset(3, 3)]);
  });

  test('a ring crossing the antimeridian carries large deltas without overflowing', () {
    // 179°E to 179°W: an 800-unit (8°) eastward jump across the dateline in raw longitude
    // terms, well within a varint's range.
    final data = buildBuffer([
      [(17900, 0), (18700, 0), (18000, 500)],
    ]);
    final rings = parseWorldOutlines(data);

    expect(rings.single[1], const Offset(187, 0));
  });
}
