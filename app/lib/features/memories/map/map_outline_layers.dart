import 'package:flutter/material.dart' show Color, Offset;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Turns the packed outline rings (see outline_codec.dart, which carries each point as an
/// [Offset] whose `dx` is longitude and `dy` is latitude) into the geometry flutter_map
/// draws.
///
/// This is the whole of what used to be a hand-written projection, transform and painter:
/// flutter_map owns the projection (Web Mercator), the camera, culling and the gestures, so
/// the only thing left for this feature to do is hand it points in degrees.
///
/// Memoized on each ring list's own identity rather than rebuilt per frame. Both outline
/// assets parse once and are cached for the app's lifetime (see WorldOutlines and
/// RegionOutlines), so the same list object comes back on every rebuild, and rebuilding
/// tens of thousands of [LatLng]s during a pan would be pure waste. An [Expando] rather
/// than a plain map so the derived geometry is collected if the asset ever is.
final Expando<List<Polygon>> _landCache = Expando<List<Polygon>>('landPolygons');
final Expando<List<Polyline>> _borderCache = Expando<List<Polyline>>('borderPolylines');

/// Country/coastline rings, filled and stroked.
///
/// Rings of fewer than three points are dropped: they cannot enclose an area, and at the
/// coarser simplification tolerances a handful of tiny islands degenerate to exactly that.
List<Polygon> landPolygons(
  List<List<Offset>> rings, {
  required Color fill,
  required Color border,
  required double strokeWidth,
}) {
  final cached = _landCache[rings];
  if (cached != null) return cached;
  final built = <Polygon>[
    for (final ring in rings)
      if (ring.length >= 3)
        Polygon(
          points: <LatLng>[for (final p in ring) LatLng(p.dy, p.dx)],
          color: fill,
          borderColor: border,
          borderStrokeWidth: strokeWidth,
        ),
  ];
  _landCache[rings] = built;
  return built;
}

/// Admin-1 (state/province) boundaries, stroked only.
///
/// Never filled - see RegionOutlines' own doc comment for why: filling them would paint a
/// second colour over every country interior these happen to tile, and any precision
/// mismatch between the two layers would show as seams.
List<Polyline> borderPolylines(
  List<List<Offset>> rings, {
  required Color color,
  required double strokeWidth,
}) {
  final cached = _borderCache[rings];
  if (cached != null) return cached;
  final built = <Polyline>[
    for (final ring in rings)
      if (ring.length >= 2)
        Polyline(
          points: <LatLng>[for (final p in ring) LatLng(p.dy, p.dx)],
          color: color,
          strokeWidth: strokeWidth,
        ),
  ];
  _borderCache[rings] = built;
  return built;
}
