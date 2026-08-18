import 'package:flutter/material.dart' show Offset, Size;

/// All the Memories map's projection math lives in this one file, deliberately: every other
/// part of the feature (the painter, the marker layout, the tests) treats it as a black box,
/// so "is the math right" only ever has to be checked in one place.
///
/// Projection: **equirectangular** (Plate Carrée) - longitude maps linearly to x, latitude
/// maps linearly to y. This is the simplest projection that's still correct, and it's the
/// right choice here: the group's own place data is city-level (see Place.lat/lng's own doc
/// comment), never more precise than that, so Web Mercator's extra complexity (and its
/// distortion blowing up near the poles) buys nothing a straight linear map doesn't already
/// give a stylised, non-navigational outline view.

/// A window of longitude to fit into a canvas's full width, expressed as [west] (the
/// window's left edge, standard -180..180 degrees) plus [spanDegrees] (its angular width,
/// always non-negative and at most 360) - not as (west, east), because a window that
/// crosses the antimeridian has an east edge numerically smaller than its west edge, and
/// carrying span alongside west means every consumer ([lngFraction], [padded]) can treat
/// the wrap as ordinary arithmetic instead of a special case.
class LngWindow {
  const LngWindow({required this.west, required this.spanDegrees});

  final double west;
  final double spanDegrees;

  /// The window's right edge, normalized back to -180..180 - purely a convenience for
  /// debugging/logging; [lngFraction] never uses it, only [west] and [spanDegrees].
  double get east => normalizeLngDegrees(west + spanDegrees);

  /// The same window widened by [paddingDegrees] on each side - how the map view turns a
  /// tight bounding window around the group's own places into one with a little breathing
  /// room before markers touch the canvas edge. Clamped at 360° total: padding a
  /// near-global window further would otherwise overshoot into double-covering the globe.
  LngWindow padded(double paddingDegrees) => LngWindow(
        west: normalizeLngDegrees(west - paddingDegrees),
        spanDegrees: (spanDegrees + 2 * paddingDegrees).clamp(0.0, 360.0),
      );

  @override
  bool operator ==(Object other) =>
      other is LngWindow && other.west == west && other.spanDegrees == spanDegrees;

  @override
  int get hashCode => Object.hash(west, spanDegrees);
}

/// A window of latitude to fit into a canvas's full height. Never wraps (the poles bound
/// it), so unlike [LngWindow] this is plain (south, north).
class LatWindow {
  const LatWindow({required this.south, required this.north});

  final double south;
  final double north;

  double get spanDegrees => north - south;

  /// The same window widened by [paddingDegrees] on each side, clamped to the poles - a
  /// group whose places already reach a pole can't be padded past it.
  LatWindow padded(double paddingDegrees) => LatWindow(
        south: (south - paddingDegrees).clamp(-90.0, 90.0),
        north: (north + paddingDegrees).clamp(-90.0, 90.0),
      );

  @override
  bool operator ==(Object other) =>
      other is LatWindow && other.south == south && other.north == north;

  @override
  int get hashCode => Object.hash(south, north);
}

/// Normalizes any longitude (including values outside -180..180, which [LngWindow.padded]
/// and antimeridian arithmetic both produce) to the standard -180..180 range, with +180
/// picked as the canonical form of the antimeridian itself (matching [computeLngWindow]'s
/// own convention below).
double normalizeLngDegrees(double lng) {
  final wrapped = ((lng + 180) % 360 + 360) % 360 - 180;
  // The modulo above lands exactly -180 back at -180, not +180; both name the same
  // meridian, but +180 is this file's chosen canonical form (see computeLngWindow).
  return wrapped == -180 ? 180 : wrapped;
}

/// Finds the tightest arc of longitude that encloses every value in [lngs], by finding the
/// circle's single largest empty gap and returning its complement - the general "smallest
/// enclosing arc on a circle" construction. This is what makes the antimeridian a non-issue
/// rather than a special case: a cluster split across +179°/-179° has its largest gap on
/// the OTHER side of the circle (through 0°), so the window this returns is the true ~2°
/// arc the points actually span, not the ~358° one a naive min(lngs)..max(lngs) would
/// report.
///
/// Empty input returns the whole globe. A single distinct longitude returns a zero-width
/// window at that value (padding, done by the caller, is what gives it visible width).
LngWindow computeLngWindow(List<double> lngs) {
  if (lngs.isEmpty) return const LngWindow(west: -180, spanDegrees: 360);
  final normalized = lngs.map((l) => ((l % 360) + 360) % 360).toList()..sort();
  if (normalized.length == 1 || normalized.last - normalized.first == 0) {
    return LngWindow(west: normalizeLngDegrees(normalized.first), spanDegrees: 0);
  }
  var largestGap = -1.0;
  var gapEndIndex = 0; // the index of the point right after the largest gap
  for (var i = 0; i < normalized.length; i++) {
    final cur = normalized[i];
    final isLast = i == normalized.length - 1;
    final next = isLast ? normalized.first + 360 : normalized[i + 1];
    final gap = next - cur;
    if (gap > largestGap) {
      largestGap = gap;
      gapEndIndex = isLast ? 0 : i + 1;
    }
  }
  final west = normalizeLngDegrees(normalized[gapEndIndex]);
  final span = (360 - largestGap).clamp(0.0, 360.0);
  return LngWindow(west: west, spanDegrees: span);
}

/// The tightest window of latitude enclosing every value in [lats]. No antimeridian-style
/// wraparound is possible for latitude (the poles bound it), so this is a plain min/max.
LatWindow computeLatWindow(List<double> lats) {
  if (lats.isEmpty) return const LatWindow(south: -90, north: 90);
  var south = lats.first, north = lats.first;
  for (final lat in lats) {
    if (lat < south) south = lat;
    if (lat > north) north = lat;
  }
  return LatWindow(south: south, north: north);
}

/// Where [lng] falls within [window], as a 0..1 fraction of the window's own span - the
/// core of the antimeridian handling: wrapping `lng - window.west` into 0..360 before
/// dividing by the span means a window that crosses the antimeridian needs no branch here
/// at all, the same arithmetic that handles an ordinary non-wrapping window also handles
/// the wrapping one.
double lngFraction(double lng, LngWindow window) {
  if (window.spanDegrees <= 0) return 0.5;
  final delta = ((lng - window.west) % 360 + 360) % 360;
  return (delta / window.spanDegrees).clamp(0.0, 1.0);
}

/// Projects a single (lat, lng) point into an [Offset] within a canvas of [size], via the
/// equirectangular mapping this file's own doc comment describes: x from [lngFraction]
/// against [lngWindow], y linearly from [lat] against [latWindow] with north at the top (a
/// higher latitude produces a smaller y). Pure - no state, no BuildContext - so every place
/// marker and every point of the world outline can funnel through this one function and it
/// alone has to be proven correct (see map_projection_test.dart's antimeridian/pole cases).
Offset projectLatLng({
  required double lat,
  required double lng,
  required LngWindow lngWindow,
  required LatWindow latWindow,
  required Size size,
}) {
  final x = lngFraction(lng, lngWindow) * size.width;
  final latSpan = latWindow.spanDegrees;
  final yFraction = latSpan <= 0 ? 0.5 : ((latWindow.north - lat) / latSpan).clamp(0.0, 1.0);
  return Offset(x, yFraction * size.height);
}
