import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/memories/map/map_labels.dart';

/// The Memories map's label placement/collision algorithm - see map_labels.dart's own doc
/// comment for the priority and drop rules this pins. [measure] throughout is a fixed,
/// fake text-size function (never a real TextPainter) so this stays a fast, deterministic
/// pure-function test.
void main() {
  Size fixedSize(String text) => const Size(40, 12);

  LabelSubject subject(double cx, double cy, double radius, [String text = 'Place']) =>
      (text: text, center: Offset(cx, cy), radius: radius);

  group('layoutMarkerLabels', () {
    test('a single marker gets a label placed to the right, vertically centered', () {
      final placements = layoutMarkerLabels(
        [subject(50, 50, 6)],
        fixedSize,
        canvasSize: const Size(400, 400),
      );
      expect(placements, hasLength(1));
      final p = placements.single;
      expect(p.markerIndex, 0);
      expect(p.textOrigin.dx, 50 + 6 + kMapLabelGap);
      expect(p.textOrigin.dy, 50 - 12 / 2);
    });

    test('non-overlapping markers both keep their labels', () {
      final placements = layoutMarkerLabels(
        [subject(50, 50, 6), subject(300, 300, 6)],
        fixedSize,
        canvasSize: const Size(400, 400),
      );
      expect(placements.map((p) => p.markerIndex).toSet(), {0, 1});
    });

    test('a larger (busier) marker keeps its label over a smaller one that would overlap it', () {
      // Both labels would land in the same ~40x12 patch immediately to the right of
      // (50, 50) - only the busier (larger-radius) marker's label should survive.
      final placements = layoutMarkerLabels(
        [subject(50, 50, 4, 'Small'), subject(48, 51, 10, 'Busy')],
        fixedSize,
        canvasSize: const Size(400, 400),
      );
      expect(placements, hasLength(1));
      expect(placements.single.markerIndex, 1, reason: 'the busier marker (index 1) must win');
    });

    test('equal-radius markers break the tie toward the earlier one in input order', () {
      final placements = layoutMarkerLabels(
        [subject(50, 50, 6, 'First'), subject(50, 51, 6, 'Second')],
        fixedSize,
        canvasSize: const Size(400, 400),
      );
      expect(placements, hasLength(1));
      expect(placements.single.markerIndex, 0);
    });

    test(
        'a label that would spill past the right edge of the canvas is dropped, not clipped '
        'or repositioned', () {
      final placements = layoutMarkerLabels(
        [subject(390, 50, 6)], // label would start at x=396+gap, width 40 -> off-canvas
        fixedSize,
        canvasSize: const Size(400, 400),
      );
      expect(placements, isEmpty);
    });

    test('a label that would spill past the top edge is dropped', () {
      Size tallSize(String text) => const Size(40, 200);
      final placements = layoutMarkerLabels(
        [subject(50, 10, 6)], // vertically centered => top goes well negative
        tallSize,
        canvasSize: const Size(400, 400),
      );
      expect(placements, isEmpty);
    });

    test('a label that would spill past the bottom edge is dropped', () {
      final placements = layoutMarkerLabels(
        [subject(50, 397, 6)],
        fixedSize,
        canvasSize: const Size(400, 400),
      );
      expect(placements, isEmpty);
    });

    test('three markers piled on top of each other: only the busiest keeps its label', () {
      final placements = layoutMarkerLabels(
        [subject(50, 50, 4), subject(51, 50, 6), subject(49, 51, 8)],
        fixedSize,
        canvasSize: const Size(400, 400),
      );
      expect(placements, hasLength(1));
      expect(placements.single.markerIndex, 2, reason: 'radius 8 is the busiest of the three');
    });

    test('no markers produces no placements', () {
      expect(layoutMarkerLabels(const [], fixedSize, canvasSize: const Size(400, 400)), isEmpty);
    });
  });
}
