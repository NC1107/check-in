import 'package:flutter/material.dart' show Offset;
import 'package:flutter/services.dart' show ByteData, rootBundle;

import 'outline_codec.dart';

/// The bundled DETAIL map layer: Natural Earth's 1:50m lakes, river centerlines and urban
/// areas, packed by assets/worldmap/pack_detail.py - see SOURCE.md for the byte layout and
/// that script's own doc comment for why this is vector rather than a terrain raster.
///
/// Drawn only at region/local zoom, on top of the country fill and under the place nodes.
/// At world zoom it would be illegible noise and is skipped entirely, which also means a
/// group whose places never leave the world tier never pays this asset's parse cost.
class DetailOutlines {
  const DetailOutlines._(this.lakeRings, this.riverLines, this.urbanRings);

  /// Lakes, filled in the ocean colour - same (lng, lat)-as-Offset convention as the other
  /// two assets.
  final List<List<Offset>> lakeRings;

  /// River centerlines. Paths, not closed rings: a river has two ends, and treating one as
  /// a ring would draw a false segment joining its mouth back to its source.
  final List<List<Offset>> riverLines;

  /// Built-up areas, filled as a faint tint. What makes "there is a city here" legible
  /// without needing a label to say so.
  final List<List<Offset>> urbanRings;

  /// See WorldOutlines._value's own doc comment for why this caches the parsed value
  /// rather than the Future - the same reasoning applies here verbatim.
  static DetailOutlines? _value;

  static Future<DetailOutlines> load() async {
    final cached = _value;
    if (cached != null) return cached;
    final data = await rootBundle.load('assets/worldmap/detail_outlines.bin');
    final parsed = parseDetailOutlines(data);
    _value = parsed;
    return parsed;
  }
}

/// Parses the packed format documented in assets/worldmap/SOURCE.md: a group count
/// (3 in the real asset, but this reads whatever is there rather than hardcoding it)
/// followed by that many ring groups - lakes, rivers, urban areas, in paint order. Pure
/// (no asset I/O) so it is directly testable against an in-memory buffer.
DetailOutlines parseDetailOutlines(ByteData data) {
  final reader = OutlineReader(data);
  final groupCount = reader.readVarint();
  final groups = [for (var g = 0; g < groupCount; g++) reader.readRingGroup()];
  List<List<Offset>> group(int i) => groups.length > i ? groups[i] : const <List<Offset>>[];
  return DetailOutlines._(group(0), group(1), group(2));
}
