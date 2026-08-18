import 'package:flutter/material.dart' show Offset;
import 'package:flutter/services.dart' show ByteData, rootBundle;

import 'outline_codec.dart';

/// The bundled REGION/LOCAL-tier map outline asset: Natural Earth's 1:50m admin-0-countries
/// AND admin-1-states-provinces layers, packed by assets/worldmap/pack_region.py into a
/// compact varint binary - see assets/worldmap/SOURCE.md for the exact format, license,
/// and simplification tolerance.
///
/// Two separate ring GROUPS, not one flat list like world_outlines.dart's own asset,
/// because the two layers paint differently: [admin0Rings] (country outlines) are filled
/// AND stroked, the same as the world tier; [admin1Rings] (state/province boundaries) are
/// stroked only - painting them filled would double-color every country's own interior
/// with however many admin-1 polygons happen to tile it, and paint order/precision
/// mismatches between the two layers could produce visible seams. A plain outline (no
/// fill) has neither problem: it reads as "here's where the state line is" regardless of
/// how it sits relative to the country fill beneath it.
///
/// Loaded only when the map view actually needs it (region or local zoom - see
/// places_map_view.dart) - a group whose places never leave the world tier never pays for
/// this asset's parse cost at all.
class RegionOutlines {
  const RegionOutlines._(this.admin0Rings, this.admin1Rings);

  /// Country outlines - same (lng, lat)-as-Offset convention as [WorldOutlines.rings].
  final List<List<Offset>> admin0Rings;

  /// State/province boundaries - same convention, but see this class's own doc comment
  /// for why callers must paint these stroke-only, never filled.
  final List<List<Offset>> admin1Rings;

  /// See [WorldOutlines._value]'s own doc comment for exactly why this caches the parsed
  /// value rather than the Future itself - the same reasoning applies here verbatim.
  static RegionOutlines? _value;

  static Future<RegionOutlines> load() async {
    final cached = _value;
    if (cached != null) return cached;
    final data = await rootBundle.load('assets/worldmap/region_outlines.bin');
    final parsed = parseRegionOutlines(data);
    _value = parsed;
    return parsed;
  }
}

/// Parses the packed binary format documented in assets/worldmap/SOURCE.md: a group count
/// (always 2 in the real asset, but this reads whatever is actually there rather than
/// hardcoding it) followed by that many ring groups - admin-0 then admin-1. Pure (no asset
/// I/O), directly testable against an in-memory buffer built the same way
/// pack_region.py builds the real file.
RegionOutlines parseRegionOutlines(ByteData data) {
  final reader = OutlineReader(data);
  final groupCount = reader.readVarint();
  final groups = [for (var g = 0; g < groupCount; g++) reader.readRingGroup()];
  final admin0 = groups.isNotEmpty ? groups[0] : const <List<Offset>>[];
  final admin1 = groups.length > 1 ? groups[1] : const <List<Offset>>[];
  return RegionOutlines._(admin0, admin1);
}
