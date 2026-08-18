import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/memories/map/map_projection.dart';

/// The Memories map's equirectangular projection - the one file everything else (the
/// painter, the marker layout, the tier-fitted view) trusts to place a lat/lng at the right
/// fraction of the canvas. See map_projection.dart's own doc comment for why equirectangular
/// was chosen and why the antimeridian needs no special-casing once [computeLngWindow] finds
/// the right window.
void main() {
  group('normalizeLngDegrees', () {
    test('leaves an ordinary value untouched', () {
      expect(normalizeLngDegrees(45), 45);
      expect(normalizeLngDegrees(-120), -120);
    });

    test('wraps a value past +180 back into range', () {
      expect(normalizeLngDegrees(190), closeTo(-170, 1e-9));
    });

    test('wraps a value past -180 back into range', () {
      expect(normalizeLngDegrees(-190), closeTo(170, 1e-9));
    });

    test('the antimeridian itself canonicalizes to +180', () {
      expect(normalizeLngDegrees(-180), 180);
      expect(normalizeLngDegrees(180), 180);
    });
  });

  group('computeLngWindow', () {
    test('a simple non-wrapping cluster', () {
      final w = computeLngWindow([10, 20, 30]);
      expect(w.west, closeTo(10, 1e-9));
      expect(w.spanDegrees, closeTo(20, 1e-9));
    });

    test(
        'a cluster split across the antimeridian picks the short true arc, not the long way '
        'around through the prime meridian', () {
      final w = computeLngWindow([179, -179]);
      expect(w.west, closeTo(179, 1e-9));
      expect(w.spanDegrees, closeTo(2, 1e-9));
      expect(w.east, closeTo(-179, 1e-9));
    });

    test('a single distinct longitude has zero span', () {
      final w = computeLngWindow([42, 42, 42]);
      expect(w.west, closeTo(42, 1e-9));
      expect(w.spanDegrees, 0);
    });

    test('empty input spans the whole globe', () {
      final w = computeLngWindow(const []);
      expect(w.spanDegrees, 360);
    });
  });

  group('computeLatWindow', () {
    test('a simple range', () {
      final w = computeLatWindow([10, -5, 30]);
      expect(w.south, -5);
      expect(w.north, 30);
    });

    test('empty input spans the whole globe', () {
      final w = computeLatWindow(const []);
      expect(w.south, -90);
      expect(w.north, 90);
    });
  });

  group('LngWindow.padded / LatWindow.padded', () {
    test('widens a window symmetrically', () {
      const w = LngWindow(west: 10, spanDegrees: 20);
      final padded = w.padded(5);
      expect(padded.west, closeTo(5, 1e-9));
      expect(padded.spanDegrees, closeTo(30, 1e-9));
    });

    test('clamps latitude padding at the poles', () {
      const w = LatWindow(south: -88, north: 85);
      final padded = w.padded(10);
      expect(padded.south, -90);
      expect(padded.north, 90);
    });
  });

  group('projectLatLng', () {
    const size = Size(200, 100);
    const lngWindow = LngWindow(west: -20, spanDegrees: 40); // -20..20
    const latWindow = LatWindow(south: -10, north: 10); // -10..10

    test('the window center lands on the canvas center', () {
      final p =
          projectLatLng(lat: 0, lng: 0, lngWindow: lngWindow, latWindow: latWindow, size: size);
      expect(p.dx, closeTo(100, 1e-9));
      expect(p.dy, closeTo(50, 1e-9));
    });

    test('the window west edge lands on the canvas left edge', () {
      final p =
          projectLatLng(lat: 0, lng: -20, lngWindow: lngWindow, latWindow: latWindow, size: size);
      expect(p.dx, closeTo(0, 1e-9));
    });

    test('the window east edge lands on the canvas right edge', () {
      final p =
          projectLatLng(lat: 0, lng: 20, lngWindow: lngWindow, latWindow: latWindow, size: size);
      expect(p.dx, closeTo(200, 1e-9));
    });

    test('north is up: the window north edge lands on y=0', () {
      final p =
          projectLatLng(lat: 10, lng: 0, lngWindow: lngWindow, latWindow: latWindow, size: size);
      expect(p.dy, closeTo(0, 1e-9));
    });

    test('south is down: the window south edge lands on y=size.height', () {
      final p =
          projectLatLng(lat: -10, lng: 0, lngWindow: lngWindow, latWindow: latWindow, size: size);
      expect(p.dy, closeTo(100, 1e-9));
    });

    test('the north pole always lands at y=0 regardless of window', () {
      const world = LatWindow(south: -90, north: 90);
      final p = projectLatLng(
          lat: 90,
          lng: 0,
          lngWindow: const LngWindow(west: -180, spanDegrees: 360),
          latWindow: world,
          size: size);
      expect(p.dy, closeTo(0, 1e-9));
    });

    test('the south pole always lands at y=size.height regardless of window', () {
      const world = LatWindow(south: -90, north: 90);
      final p = projectLatLng(
          lat: -90,
          lng: 0,
          lngWindow: const LngWindow(west: -180, spanDegrees: 360),
          latWindow: world,
          size: size);
      expect(p.dy, closeTo(100, 1e-9));
    });

    test(
        '+180 and -180 (the same antimeridian point) land at the same fraction of a window '
        'that straddles it', () {
      final window = computeLngWindow([170, -170]); // straddles the antimeridian
      final positive =
          projectLatLng(lat: 0, lng: 180, lngWindow: window, latWindow: latWindow, size: size);
      final negative =
          projectLatLng(lat: 0, lng: -180, lngWindow: window, latWindow: latWindow, size: size);
      expect(positive.dx, closeTo(negative.dx, 1e-6));
    });

    test(
        'a point inside an antimeridian-straddling window lands within the canvas bounds, '
        'not off in a wraparound direction', () {
      final window = computeLngWindow([179, -179]);
      final p = projectLatLng(
          lat: 0, lng: 180, lngWindow: window, latWindow: latWindow, size: const Size(100, 50));
      expect(p.dx, inInclusiveRange(0, 100));
    });

    test('a degenerate (zero-span) window centers every point', () {
      const zero = LngWindow(west: 42, spanDegrees: 0);
      final p = projectLatLng(lat: 0, lng: 999, lngWindow: zero, latWindow: latWindow, size: size);
      expect(p.dx, closeTo(100, 1e-9));
    });
  });
}
