import 'package:flutter/material.dart' show Offset;
import 'package:flutter/services.dart' show ByteData;

/// The zigzag-varint delta-encoded ring format shared by world_outlines.dart (a single
/// flat list of rings) and region_outlines.dart (several ring GROUPS in one file) - see
/// assets/worldmap/SOURCE.md for the exact byte layout each one wraps this in, and
/// assets/worldmap/outline_codec.py for the matching Python-side encoder.
///
/// A stateful reader over one [ByteData], not a set of free functions taking an explicit
/// offset: every call site here already needs to read several rings/groups in sequence,
/// and threading an integer offset through each read (bumping it by however many bytes a
/// varint happened to take) is exactly the kind of easy-to-get-wrong bookkeeping a tiny
/// stateful cursor removes.
class OutlineReader {
  OutlineReader(this._data);

  final ByteData _data;
  int _offset = 0;

  int _readByte() => _data.getUint8(_offset++);

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _readByte();
      result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  int _readZigzag() {
    final v = readVarint();
    return (v & 1) == 0 ? (v >> 1) : -((v + 1) >> 1);
  }

  /// Reads one ring: a point count, then that many zigzag-delta-encoded (dx, dy) pairs -
  /// see the encoder's own doc comment for why the deltas are against the PREVIOUS point,
  /// first point's delta against (0, 0).
  List<Offset> readRing() {
    final pointCount = readVarint();
    final points = <Offset>[];
    var x = 0, y = 0;
    for (var p = 0; p < pointCount; p++) {
      x += _readZigzag();
      y += _readZigzag();
      points.add(Offset(x / 100.0, y / 100.0));
    }
    return points;
  }

  /// Reads a ring COUNT followed by that many rings - the shape both world_outlines.bin's
  /// single group and each of region_outlines.bin's two groups share.
  List<List<Offset>> readRingGroup() {
    final ringCount = readVarint();
    return [for (var r = 0; r < ringCount; r++) readRing()];
  }
}
