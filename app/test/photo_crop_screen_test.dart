import 'package:checkin/features/profile/photo_crop_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The cropper frames the picked photo by covering a square viewport and centring the
// overflow. That framing math is the only custom logic - the pan/zoom (InteractiveViewer)
// and the capture (RepaintBoundary.toImage) are stdlib. These verify the geometry directly;
// a full widget test can't run here because decodeImageFromList/toImage need a rasterizer
// this headless test host doesn't provide.
void main() {
  group('coverSize', () {
    test('portrait image pins width to the square and overflows in height', () {
      final c = coverSize(400, 600, 300);
      expect(c.width, 300);
      expect(c.height, 450);
    });

    test('landscape image pins height to the square and overflows in width', () {
      final c = coverSize(600, 400, 300);
      expect(c.width, 450);
      expect(c.height, 300);
    });

    test('square image exactly fills the viewport', () {
      final c = coverSize(500, 500, 300);
      expect(c.width, 300);
      expect(c.height, 300);
    });

    test('cover always fully spans the viewport on both axes', () {
      for (final (w, h) in [(400.0, 600.0), (600.0, 400.0), (1000.0, 200.0), (321.0, 987.0)]) {
        final c = coverSize(w, h, 300);
        expect(c.width, greaterThanOrEqualTo(300 - 0.001));
        expect(c.height, greaterThanOrEqualTo(300 - 0.001));
      }
    });
  });

  group('centerTranslate', () {
    test('splits the overflow evenly as a negative offset', () {
      expect(centerTranslate(const Size(300, 450), 300), const Offset(0, -75));
      expect(centerTranslate(const Size(450, 300), 300), const Offset(-75, 0));
    });

    test('no translation when the image already fills the square', () {
      expect(centerTranslate(const Size(300, 300), 300), Offset.zero);
    });

    test('centred cover leaves no gap: translate + cover spans past the far edge', () {
      const side = 300.0;
      final cover = coverSize(400, 600, side);
      final t = centerTranslate(cover, side);
      // Top-left of the image sits at t (<= 0); bottom-right must reach past the viewport.
      expect(t.dx, lessThanOrEqualTo(0));
      expect(t.dy, lessThanOrEqualTo(0));
      expect(t.dx + cover.width, greaterThanOrEqualTo(side - 0.001));
      expect(t.dy + cover.height, greaterThanOrEqualTo(side - 0.001));
    });
  });
}
