import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/memories/map/map_projection.dart';
import 'package:checkin/features/memories/map/map_transform.dart';

/// The Memories map's pan/zoom transform maths - pure functions, so every case here is a
/// plain input/output check with no widget tree, gesture recognizer, or CustomPainter
/// involved. See PlacesMapView for how a live ScaleGestureRecognizer feeds
/// updateMapTransformForScaleGesture, and map_transform.dart's own doc comments for the
/// reasoning behind each bound.
void main() {
  const baseLng = LngWindow(west: -80, spanDegrees: 10); // -80..-70
  const baseLat = LatWindow(south: 35, north: 45); // 10 degrees

  group('MapTransform.identity', () {
    test('scale is 1 and the focal point is the base window\'s own center', () {
      final t = MapTransform.identity(baseLng: baseLng, baseLat: baseLat);
      expect(t.scale, 1.0);
      expect(t.focalLng, -75.0);
      expect(t.focalLat, 40.0);
    });
  });

  group('applyMapTransform', () {
    test('at the identity transform, returns exactly the base window', () {
      final identity = MapTransform.identity(baseLng: baseLng, baseLat: baseLat);
      final result = applyMapTransform(baseLng: baseLng, baseLat: baseLat, transform: identity);
      expect(result.lng.west, baseLng.west);
      expect(result.lng.spanDegrees, baseLng.spanDegrees);
      expect(result.lat.south, baseLat.south);
      expect(result.lat.north, baseLat.north);
    });

    test('scale 2 halves both spans, centered on the focal point', () {
      const t = MapTransform(scale: 2.0, focalLng: -75.0, focalLat: 40.0);
      final result = applyMapTransform(baseLng: baseLng, baseLat: baseLat, transform: t);
      expect(result.lng.spanDegrees, closeTo(5.0, 1e-9));
      expect(result.lng.west, closeTo(-77.5, 1e-9));
      expect(result.lat.spanDegrees, closeTo(5.0, 1e-9));
      expect(result.lat.south, closeTo(37.5, 1e-9));
      expect(result.lat.north, closeTo(42.5, 1e-9));
    });

    test('scale 0.5 doubles both spans (zoomed out from the fitted view)', () {
      const t = MapTransform(scale: 0.5, focalLng: -75.0, focalLat: 40.0);
      final result = applyMapTransform(baseLng: baseLng, baseLat: baseLat, transform: t);
      expect(result.lng.spanDegrees, closeTo(20.0, 1e-9));
      expect(result.lat.spanDegrees, closeTo(20.0, 1e-9));
    });

    test('panning moves the window without changing its span', () {
      const t = MapTransform(scale: 1.0, focalLng: -60.0, focalLat: 20.0);
      final result = applyMapTransform(baseLng: baseLng, baseLat: baseLat, transform: t);
      expect(result.lng.spanDegrees, baseLng.spanDegrees);
      expect(result.lng.west, closeTo(-65.0, 1e-9));
      expect(result.lat.south, closeTo(15.0, 1e-9));
      expect(result.lat.north, closeTo(25.0, 1e-9));
    });
  });

  group('scaleBounds', () {
    test('min is always <= 1 and max is always >= 1 - the fitted view is always reachable', () {
      for (final span in [0.001, 1.0, 10.0, 100.0, 350.0]) {
        final bounds = scaleBounds(
          baseLng: LngWindow(west: -10, spanDegrees: span),
          baseLat: LatWindow(south: -span / 2, north: span / 2),
        );
        expect(bounds.min, lessThanOrEqualTo(1.0), reason: 'span=$span');
        expect(bounds.max, greaterThanOrEqualTo(1.0), reason: 'span=$span');
      }
    });

    test(
        'min scale caps the zoomed-out effective span at the whole world on whichever '
        'axis binds first, and never overshoots it on the other', () {
      final bounds = scaleBounds(baseLng: baseLng, baseLat: baseLat);
      final effectiveLngSpanAtMin = baseLng.spanDegrees / bounds.min;
      final effectiveLatSpanAtMin = baseLat.spanDegrees / bounds.min;
      // This base window's lat span (10 degrees against a 170-degree world cap) binds
      // before its lng span (10 degrees against a 360-degree world cap) does.
      expect(effectiveLatSpanAtMin, closeTo(kMapWorldLatSpanDegrees, 1e-6));
      expect(effectiveLngSpanAtMin, lessThanOrEqualTo(360.0));
    });

    test('max scale caps the zoomed-in effective span at kMapMaxZoomSpanDegrees', () {
      final bounds = scaleBounds(baseLng: baseLng, baseLat: baseLat);
      final maxBaseSpan =
          baseLng.spanDegrees > baseLat.spanDegrees ? baseLng.spanDegrees : baseLat.spanDegrees;
      final effectiveSpanAtMax = maxBaseSpan / bounds.max;
      expect(effectiveSpanAtMax, closeTo(kMapMaxZoomSpanDegrees, 1e-6));
    });

    test('a near-point base window never produces an unusable (zero or negative) range', () {
      final bounds = scaleBounds(
        baseLng: const LngWindow(west: 0, spanDegrees: 0),
        baseLat: const LatWindow(south: 0, north: 0),
      );
      expect(bounds.min, greaterThan(0));
      expect(bounds.max, greaterThanOrEqualTo(bounds.min));
    });
  });

  group('clampMapTransform', () {
    test('a scale below the minimum is clamped up to it', () {
      final bounds = scaleBounds(baseLng: baseLng, baseLat: baseLat);
      final t = clampMapTransform(
        MapTransform(scale: bounds.min / 2, focalLng: -75, focalLat: 40),
        baseLng: baseLng,
        baseLat: baseLat,
      );
      expect(t.scale, bounds.min);
    });

    test('a scale above the maximum is clamped down to it', () {
      final bounds = scaleBounds(baseLng: baseLng, baseLat: baseLat);
      final t = clampMapTransform(
        MapTransform(scale: bounds.max * 2, focalLng: -75, focalLat: 40),
        baseLng: baseLng,
        baseLat: baseLat,
      );
      expect(t.scale, bounds.max);
    });

    test('panning toward the pole is clamped so the effective window never crosses it', () {
      final t = clampMapTransform(
        const MapTransform(scale: 1.0, focalLng: -75, focalLat: 89),
        baseLng: baseLng,
        baseLat: baseLat,
      );
      final window = applyMapTransform(baseLng: baseLng, baseLat: baseLat, transform: t);
      expect(window.lat.north, lessThanOrEqualTo(kMapWorldLatSpanDegrees / 2));
    });

    test('panning past the south pole is clamped symmetrically', () {
      final t = clampMapTransform(
        const MapTransform(scale: 1.0, focalLng: -75, focalLat: -89),
        baseLng: baseLng,
        baseLat: baseLat,
      );
      final window = applyMapTransform(baseLng: baseLng, baseLat: baseLat, transform: t);
      expect(window.lat.south, greaterThanOrEqualTo(-kMapWorldLatSpanDegrees / 2));
    });

    test('longitude is normalized, not clamped - panning wraps around the antimeridian', () {
      final t = clampMapTransform(
        const MapTransform(scale: 1.0, focalLng: 190, focalLat: 40),
        baseLng: baseLng,
        baseLat: baseLat,
      );
      expect(t.focalLng, closeTo(-170, 1e-9));
    });
  });

  group('updateMapTransformForScaleGesture', () {
    const start = MapTransform(scale: 1.0, focalLng: -75.0, focalLat: 40.0);
    const canvasSize = Size(200, 200);

    test('a pure one-finger drag right pans the focal point west (gestureScale stays 1)', () {
      final t = updateMapTransformForScaleGesture(
        start: start,
        startFocalPoint: const Offset(100, 100),
        currentFocalPoint: const Offset(150, 100), // dragged 50px right
        gestureScale: 1.0,
        baseLng: baseLng,
        baseLat: baseLat,
        canvasSize: canvasSize,
      );
      expect(t.scale, 1.0);
      expect(t.focalLng, lessThan(start.focalLng),
          reason: 'dragging right reveals land to the west');
      expect(t.focalLat, start.focalLat);
    });

    test('a pure one-finger drag down pans the focal point south', () {
      final t = updateMapTransformForScaleGesture(
        start: start,
        startFocalPoint: const Offset(100, 100),
        currentFocalPoint: const Offset(100, 150),
        gestureScale: 1.0,
        baseLng: baseLng,
        baseLat: baseLat,
        canvasSize: canvasSize,
      );
      expect(t.focalLat, lessThan(start.focalLat),
          reason: 'dragging down reveals land to the south');
      expect(t.focalLng, start.focalLng);
    });

    test('a pinch with no focal-point movement only changes scale', () {
      final t = updateMapTransformForScaleGesture(
        start: start,
        startFocalPoint: const Offset(100, 100),
        currentFocalPoint: const Offset(100, 100),
        gestureScale: 2.0,
        baseLng: baseLng,
        baseLat: baseLat,
        canvasSize: canvasSize,
      );
      expect(t.scale, closeTo(2.0, 1e-9));
      expect(t.focalLng, start.focalLng);
      expect(t.focalLat, start.focalLat);
    });

    test('the resulting transform is always clamped into range', () {
      final t = updateMapTransformForScaleGesture(
        start: start,
        startFocalPoint: const Offset(100, 100),
        currentFocalPoint: const Offset(100, 100),
        gestureScale: 1000.0, // an absurd pinch factor
        baseLng: baseLng,
        baseLat: baseLat,
        canvasSize: canvasSize,
      );
      final bounds = scaleBounds(baseLng: baseLng, baseLat: baseLat);
      expect(t.scale, bounds.max);
    });

    test('a degenerate zero-size canvas is a no-op rather than dividing by zero', () {
      final t = updateMapTransformForScaleGesture(
        start: start,
        startFocalPoint: const Offset(100, 100),
        currentFocalPoint: const Offset(150, 100),
        gestureScale: 1.0,
        baseLng: baseLng,
        baseLat: baseLat,
        canvasSize: Size.zero,
      );
      expect(t.scale, start.scale);
      expect(t.focalLng, start.focalLng);
      expect(t.focalLat, start.focalLat);
    });
  });
}
