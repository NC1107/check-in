import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/memories/map/detail_outlines.dart';
import 'package:checkin/features/memories/map/place_marker.dart';
import 'package:checkin/features/memories/map/region_outlines.dart';
import 'package:checkin/features/memories/map/world_outlines.dart';

/// Checks the REAL bundled outline assets, not an in-memory buffer like
/// world_outlines_test.dart/region_outlines_test.dart do.
///
/// Those two prove the parser reads back whatever the encoder wrote; this one proves the
/// bytes actually shipped were written by an encoder that agrees with it. The failure this
/// exists for is silent by construction: the quantization scale lives in two files, one
/// Python and one Dart (see outline_codec.dart's own kOutlineCoordinateScale), and if they
/// ever disagree nothing throws - every coastline in the world simply lands at the wrong
/// size, off the map or crushed into a corner. A coordinate-range check catches that on the
/// very first assertion instead of on a device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void expectSaneDegrees(List<List<Offset>> rings, String what) {
    expect(rings, isNotEmpty, reason: '$what parsed to no rings at all');
    var points = 0;
    for (final ring in rings) {
      for (final p in ring) {
        // dx is longitude, dy latitude - see outline_codec.dart. Longitude is allowed a
        // little past 180: Natural Earth carries a few rings that run over the antimeridian
        // rather than being split at it.
        expect(p.dx, inInclusiveRange(-200.0, 200.0),
            reason: '$what has a longitude outside any possible degree value - the encoder '
                "and decoder's quantization scales have probably drifted apart");
        expect(p.dy, inInclusiveRange(-90.0, 90.0),
            reason: '$what has a latitude outside any possible degree value - same cause');
        points++;
      }
    }
    expect(points, greaterThan(1000), reason: '$what is implausibly sparse for a real map');
  }

  testWidgets('the bundled world outline asset decodes to real degrees', (tester) async {
    final world = await WorldOutlines.load();
    expectSaneDegrees(world.rings, 'world_outlines.bin');
  });

  testWidgets('the bundled region outline asset decodes to real degrees', (tester) async {
    final region = await RegionOutlines.load();
    expectSaneDegrees(region.admin0Rings, "region_outlines.bin's admin-0 group");
    expectSaneDegrees(region.admin1Rings, "region_outlines.bin's admin-1 group");
  });

  testWidgets('the bundled detail asset decodes to real degrees', (tester) async {
    final detail = await DetailOutlines.load();
    expectSaneDegrees(detail.lakeRings, "detail_outlines.bin's lakes");
    expectSaneDegrees(detail.riverLines, "detail_outlines.bin's rivers");
    expectSaneDegrees(detail.urbanRings, "detail_outlines.bin's urban areas");
  });

  testWidgets('rivers are packed as open paths, not as rings', (tester) async {
    // The packer trims a repeated closing point from AREA rings only - doing it to a line
    // would open a genuinely closed one, and treating a line as a ring would draw a false
    // segment joining a river's mouth back to its source across whatever lies between.
    //
    // A handful of centerlines really do close on themselves (a loop around a delta
    // island), so this asserts the shape of the layer rather than demanding none exist: if
    // lines were ever run through the ring path, essentially all of them would come back
    // closed instead of a small minority.
    final detail = await DetailOutlines.load();
    final closed = detail.riverLines.where((r) => r.length > 2 && r.first == r.last).length;
    expect(closed / detail.riverLines.length, lessThan(0.1),
        reason: '$closed of ${detail.riverLines.length} river paths are closed - lines have '
            'probably been packed through the ring path');
  });

  testWidgets('the region asset actually covers the founder group\'s own corner of the map',
      (tester) async {
    // Somewhere inside the Maryland/Virginia/West Virginia area every real place in the
    // founder group sits in - if the asset ever gets repacked from a filtered or partial
    // source, "the map is empty exactly where our users are" is the failure to catch.
    final region = await RegionOutlines.load();
    final nearby = region.admin1Rings
        .expand((r) => r)
        .where((p) => p.dx > -80 && p.dx < -75 && p.dy > 37 && p.dy < 40);
    expect(nearby, isNotEmpty, reason: 'no admin-1 boundary points anywhere near the mid-Atlantic');
  });

  group('place node sizing', () {
    Place place(int postCount) => Place(
          location: 'Somewhere',
          postCount: postCount,
          photoCount: 0,
          posterCount: 1,
          firstSeen: DateTime.utc(2026),
          lastSeen: DateTime.utc(2026),
          homeArea: false,
        );

    test('a lone place gets the minimum size rather than the maximum', () {
      // A group with one place has nothing to be "busiest" against, so scaling it to the
      // ceiling would read as significance the data does not carry.
      expect(placeNodeDiameter(place(1).postCount, 1), kPlaceNodeMinDiameter);
    });

    test('the busiest place gets the maximum size', () {
      expect(placeNodeDiameter(40, 40), kPlaceNodeMaxDiameter);
    });

    test('sizes stay inside the declared bounds across a wide spread', () {
      for (final count in [1, 2, 5, 17, 99, 400]) {
        final d = placeNodeDiameter(count, 400);
        expect(d, inInclusiveRange(kPlaceNodeMinDiameter, kPlaceNodeMaxDiameter));
      }
    });

    test('area, not diameter, tracks the post count', () {
      // A place with a quarter the posts should be about half the diameter above the
      // floor - that is what makes the disc's AREA read as the ratio.
      final quarter = placeNodeDiameter(25, 100) - kPlaceNodeMinDiameter;
      final full = placeNodeDiameter(100, 100) - kPlaceNodeMinDiameter;
      expect(quarter / full, closeTo(0.5, 0.001));
    });

    test('a count above the group maximum is clamped rather than oversized', () {
      expect(placeNodeDiameter(500, 100), kPlaceNodeMaxDiameter);
    });
  });
}
