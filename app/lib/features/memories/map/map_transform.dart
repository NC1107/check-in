import 'dart:math' as math;

import 'package:flutter/material.dart' show Offset, Size;

import 'map_projection.dart';

/// How far a user has panned/zoomed the map view away from its own fitted (tier-computed)
/// base window - see [applyMapTransform] for how this combines with that base window to
/// produce the actual window projected/painted against, and PlacesMapView's own gesture
/// handling for how live touch input turns into a new [MapTransform] each frame.
///
/// scale=1 with [focalLng]/[focalLat] at the base window's own center is the IDENTITY
/// transform - exactly the fitted view [computeLngWindow]/[computeLatWindow] already
/// compute, completely unchanged - see [MapTransform.identity].
class MapTransform {
  const MapTransform({required this.scale, required this.focalLng, required this.focalLat});

  /// Always >= [scaleBounds]' own `min` and <= its `max` - see [clampMapTransform], the
  /// only place a transform not already known to be in range should ever pass through.
  /// The base window's own span is divided by this to get the effective window's span, so
  /// 1 is "exactly the fitted view", greater than 1 zooms in, less than 1 zooms out
  /// (bounded at the whole world - see [scaleBounds]).
  final double scale;

  /// The geographic point the effective window is centered on - the base window's own
  /// center at scale 1, wherever the user has since panned to otherwise.
  final double focalLng;
  final double focalLat;

  /// The un-panned, un-zoomed transform for a given fitted base window - what a reset
  /// affordance (double-tap, the recenter button) returns to.
  factory MapTransform.identity({required LngWindow baseLng, required LatWindow baseLat}) =>
      MapTransform(
        scale: 1.0,
        focalLng: normalizeLngDegrees(baseLng.west + baseLng.spanDegrees / 2),
        focalLat: (baseLat.south + baseLat.north) / 2,
      );
}

/// The effective window [applyMapTransform] would compute at [transform]'s own maximum
/// zoom-in - roughly "as tight as this data is worth showing": the group's own place data
/// is never more precise than city-level (see map_projection.dart's own doc comment), so
/// zooming in past a couple dozen kilometres of visible span reveals no more real detail,
/// just larger empty space between an unchanged set of dots.
const double kMapMaxZoomSpanDegrees = 0.5;

/// The latitude span the WORLD tier itself already uses (see PlacesMapView) - reused here
/// as the pole-ward bound panning/zooming out must never cross, so the region/local
/// transform's own "zoomed all the way out" state lines up with the world tier's own fixed
/// window instead of drifting past it toward the actual poles.
const double kMapWorldLatSpanDegrees = 170.0;

/// The [MapTransform.scale] range [clampMapTransform] enforces for a given fitted base
/// window: never so small that the effective window would exceed the whole world (lng) or
/// [kMapWorldLatSpanDegrees] (lat) - "do not let someone zoom out past the whole world" -
/// and never so large that the effective window would shrink past [kMapMaxZoomSpanDegrees].
/// `min` is always <= 1 <= `max`, so the fitted (identity) view is always reachable.
({double min, double max}) scaleBounds({required LngWindow baseLng, required LatWindow baseLat}) {
  final minForLng = baseLng.spanDegrees > 0 ? baseLng.spanDegrees / 360.0 : 0.0;
  final minForLat = baseLat.spanDegrees > 0 ? baseLat.spanDegrees / kMapWorldLatSpanDegrees : 0.0;
  final min = math.max(minForLng, minForLat).clamp(0.0001, 1.0);

  final baseMaxSpan = math.max(baseLng.spanDegrees, baseLat.spanDegrees);
  final max = baseMaxSpan > 0 ? math.max(baseMaxSpan / kMapMaxZoomSpanDegrees, 1.0) : 1.0;

  return (min: min, max: max);
}

/// Clamps [raw] to a fitted base window: scale into [scaleBounds]' own range, then the
/// focal point so the resulting effective window never crosses the poles (longitude needs
/// no clamping at all - it wraps, via [normalizeLngDegrees], the same way an ordinary
/// world map pans seamlessly around the antimeridian rather than hitting an edge).
MapTransform clampMapTransform(
  MapTransform raw, {
  required LngWindow baseLng,
  required LatWindow baseLat,
}) {
  final bounds = scaleBounds(baseLng: baseLng, baseLat: baseLat);
  final scale = raw.scale.clamp(bounds.min, bounds.max);

  final effectiveLatSpan = (baseLat.spanDegrees / scale).clamp(0.0, kMapWorldLatSpanDegrees);
  final halfLat = effectiveLatSpan / 2;
  final maxNorth = kMapWorldLatSpanDegrees / 2 - halfLat;
  final focalLat = maxNorth >= 0 ? raw.focalLat.clamp(-maxNorth, maxNorth) : 0.0;

  return MapTransform(
    scale: scale,
    focalLng: normalizeLngDegrees(raw.focalLng),
    focalLat: focalLat,
  );
}

/// The effective (lng, lat) window [transform] projects the map's own outlines and markers
/// against, derived from the fitted [baseLng]/[baseLat] window every tier's own fit-to-
/// points math already computes - see map_projection.dart's [projectLatLng], which is what
/// every caller of this actually paints through.
({LngWindow lng, LatWindow lat}) applyMapTransform({
  required LngWindow baseLng,
  required LatWindow baseLat,
  required MapTransform transform,
}) {
  final lngSpan = (baseLng.spanDegrees / transform.scale).clamp(0.0, 360.0);
  final lngWindow = LngWindow(
    west: normalizeLngDegrees(transform.focalLng - lngSpan / 2),
    spanDegrees: lngSpan,
  );

  final latSpan = (baseLat.spanDegrees / transform.scale).clamp(0.0, kMapWorldLatSpanDegrees);
  final latWindow = LatWindow(
    south: transform.focalLat - latSpan / 2,
    north: transform.focalLat + latSpan / 2,
  );

  return (lng: lngWindow, lat: latWindow);
}

/// Computes the next [MapTransform] from one live gesture update: [start] is the
/// transform in effect when the gesture began (not the previous frame's - see
/// PlacesMapView's own onScaleStart, which snapshots this once per gesture so small
/// per-frame errors never accumulate), [startFocalPoint] is where that gesture began in
/// screen space, [currentFocalPoint] and [gestureScale] are the live values Flutter's own
/// `ScaleGestureRecognizer` reports on each update (a one-finger drag reports
/// `gestureScale == 1`; a two-finger pinch reports both a moving focal point AND a scale
/// factor, so this one function drives both pan and zoom together, same as the recognizer
/// itself does). Pure - every input a real gesture callback would read off its own
/// `ScaleUpdateDetails` is passed in explicitly - so this is directly testable with
/// synthetic gesture data instead of pumping a real `GestureDetector`.
MapTransform updateMapTransformForScaleGesture({
  required MapTransform start,
  required Offset startFocalPoint,
  required Offset currentFocalPoint,
  required double gestureScale,
  required LngWindow baseLng,
  required LatWindow baseLat,
  required Size canvasSize,
}) {
  if (canvasSize.width <= 0 || canvasSize.height <= 0 || start.scale <= 0) return start;

  final degPerPxLng = (baseLng.spanDegrees / start.scale) / canvasSize.width;
  final degPerPxLat = (baseLat.spanDegrees / start.scale) / canvasSize.height;

  final dx = currentFocalPoint.dx - startFocalPoint.dx;
  final dy = currentFocalPoint.dy - startFocalPoint.dy;

  // Dragging right (dx > 0) reveals content to the west - the visible window's own center
  // slides west (lng decreases). Dragging down (dy > 0) reveals content to the south -
  // the center slides south (lat decreases), matching projectLatLng's own north-is-up
  // convention.
  final focalLng = start.focalLng - dx * degPerPxLng;
  final focalLat = start.focalLat - dy * degPerPxLat;
  final scale = start.scale * gestureScale;

  return clampMapTransform(
    MapTransform(scale: scale, focalLng: focalLng, focalLat: focalLat),
    baseLng: baseLng,
    baseLat: baseLat,
  );
}
