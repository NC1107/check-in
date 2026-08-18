import 'dart:math' as math;

import 'package:flutter/material.dart' show Offset;

/// A bare (latitude, longitude) pair in degrees - deliberately not [Place] itself, so every
/// pure function in this map feature (here and in map_projection.dart/map_tier.dart) can be
/// tested with plain coordinates, without constructing a full API model.
typedef LatLng = ({double lat, double lng});

/// Earth's mean radius in kilometres - the one constant [haversineKm] needs, kept here so
/// nothing else in this feature has to know or duplicate it.
const double _earthRadiusKm = 6371.0;

double _degToRad(double deg) => deg * math.pi / 180.0;

/// Great-circle distance between [a] and [b] in kilometres (the haversine formula). Pure
/// and side-effect free, so [maxPairwiseDistanceKm] (and so [decideMapTier] in
/// map_tier.dart) is directly unit-testable against known city-pair distances.
double haversineKm(LatLng a, LatLng b) {
  final dLat = _degToRad(b.lat - a.lat);
  final dLng = _degToRad(b.lng - a.lng);
  final lat1 = _degToRad(a.lat);
  final lat2 = _degToRad(b.lat);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * _earthRadiusKm * math.asin(math.min(1.0, math.sqrt(h)));
}

/// The largest distance between any two of [points], in kilometres - this set's own
/// "diameter", which [decideMapTier] uses to tell a tight cluster from a country-sized
/// spread from a continent-spanning one. O(n²), which is fine: a group's own distinct
/// places rarely runs past the low hundreds.
double maxPairwiseDistanceKm(List<LatLng> points) {
  if (points.length < 2) return 0;
  var maxKm = 0.0;
  for (var i = 0; i < points.length; i++) {
    for (var j = i + 1; j < points.length; j++) {
      final d = haversineKm(points[i], points[j]);
      if (d > maxKm) maxKm = d;
    }
  }
  return maxKm;
}

/// A marker's on-screen radius in logical pixels, sized so the place with the most
/// check-ins (`maxPostCount`) reads as visibly busier than one with only a couple - a
/// square-root scale (not linear) so a place with 10x the check-ins isn't drawn 10x the
/// radius (100x the area), which would swallow the rest of the map.
const double kMapMarkerMinRadius = 6.0;
const double kMapMarkerMaxRadius = 16.0;

double markerRadius(int postCount, int maxPostCount) {
  if (maxPostCount <= 1 || postCount <= 1) return kMapMarkerMinRadius;
  final t = math.sqrt(postCount / maxPostCount).clamp(0.0, 1.0);
  return kMapMarkerMinRadius + (kMapMarkerMaxRadius - kMapMarkerMinRadius) * t;
}

/// Pushes apart marker centers that would otherwise sit on top of each other closely enough
/// to turn into unreadable/untappable mush at world or region zoom (see the brief this map
/// implements: "overlapping markers ... handle it sensibly"). A few passes of simple
/// pairwise separation: any pair closer than 85% of their combined radii gets pushed apart
/// along the line between their centers by half the shortfall, repeated so a three-way
/// pile-up settles rather than just resolving its first pair and leaving the third
/// untouched.
///
/// Pure and deterministic (same input order and passes always produce the same output), so
/// it's directly testable without a CustomPainter or a widget tree - see map_projection or
/// the map widget test's own marker-layout group.
List<Offset> nudgeOverlappingMarkers(List<Offset> centers, List<double> radii, {int passes = 4}) {
  assert(centers.length == radii.length);
  final result = List<Offset>.of(centers);
  for (var pass = 0; pass < passes; pass++) {
    for (var i = 0; i < result.length; i++) {
      for (var j = i + 1; j < result.length; j++) {
        final delta = result[j] - result[i];
        final dist = delta.distance;
        final minDist = (radii[i] + radii[j]) * 0.85;
        if (dist >= minDist) continue;
        final overlap = minDist - dist;
        // Exactly coincident centers have no direction to separate along - pick a fixed
        // axis (rather than leaving them stacked forever) so even a duplicate coordinate
        // still settles into two distinct, tappable dots.
        final direction = dist < 0.001 ? const Offset(1, 0) : delta / dist;
        result[i] -= direction * (overlap / 2);
        result[j] += direction * (overlap / 2);
      }
    }
  }
  return result;
}
