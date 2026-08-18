import 'package:flutter/material.dart' show Offset;
import 'package:flutter/services.dart' show ByteData, rootBundle;

/// The bundled world map outline asset: every ring (country boundary or hole alike) of
/// Natural Earth's 1:110m admin-0-countries layer, packed by
/// assets/worldmap/pack_world.py into a compact varint binary - see
/// assets/worldmap/SOURCE.md for the exact format, license, and why holes need no special
/// handling here.
class WorldOutlines {
  const WorldOutlines._(this.rings);

  /// Every ring as a closed loop of (lng, lat) degree pairs, stored as [Offset]s with
  /// `dx` = longitude and `dy` = latitude (NOT screen pixels - callers project each point
  /// through map_projection.dart's [projectLatLng] before painting).
  final List<List<Offset>> rings;

  /// Caches the fully-parsed result, not the in-flight [Future] itself - every call gets
  /// its own fresh Future (cheap once [_value] is set, since then it resolves on the very
  /// next microtask with no I/O), rather than every caller sharing one Future instance
  /// across the app's whole lifetime. That distinction matters in widget tests: a shared
  /// Future object created and completed inside one `testWidgets` body, then reused by a
  /// `FutureBuilder` built inside a LATER, separate `testWidgets` body, does not reliably
  /// deliver its already-known value to that later listener under
  /// TestWidgetsFlutterBinding's per-test reset - each test's [FutureBuilder] needs its own
  /// freshly-created Future to subscribe to, even when the underlying data was already
  /// loaded by an earlier test.
  static WorldOutlines? _value;

  static Future<WorldOutlines> load() async {
    final cached = _value;
    if (cached != null) return cached;
    final data = await rootBundle.load('assets/worldmap/world_outlines.bin');
    final parsed = WorldOutlines._(parseWorldOutlines(data));
    _value = parsed;
    return parsed;
  }
}

/// Parses the packed binary format documented in assets/worldmap/SOURCE.md into a flat list
/// of rings. Pure (no asset I/O) so it's directly testable against an in-memory buffer built
/// the same way pack_world.py builds the real file, without needing Flutter's asset bundle
/// machinery in a plain unit test.
List<List<Offset>> parseWorldOutlines(ByteData data) {
  var offset = 0;

  int readByte() => data.getUint8(offset++);

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = readByte();
      result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  int readZigzag() {
    final v = readVarint();
    return (v & 1) == 0 ? (v >> 1) : -((v + 1) >> 1);
  }

  final ringCount = readVarint();
  final rings = <List<Offset>>[];
  for (var r = 0; r < ringCount; r++) {
    final pointCount = readVarint();
    final points = <Offset>[];
    var x = 0, y = 0;
    for (var p = 0; p < pointCount; p++) {
      x += readZigzag();
      y += readZigzag();
      points.add(Offset(x / 100.0, y / 100.0));
    }
    rings.add(points);
  }
  return rings;
}
