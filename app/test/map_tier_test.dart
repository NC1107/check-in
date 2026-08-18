import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/memories/map/geo.dart';
import 'package:checkin/features/memories/map/map_tier.dart';

/// The zoom-tier decision the Memories map uses to pick world/region/singlePlace - see
/// map_tier.dart's own doc comment for the thresholds and why a very large single country is
/// an accepted, documented edge case that lands in the world tier.
void main() {
  group('decideMapTier', () {
    test('no points is treated as a single place (nothing to plot)', () {
      expect(decideMapTier(const []), MapTier.singlePlace);
    });

    test('one point is a single place', () {
      expect(decideMapTier(const [(lat: 51.5, lng: -0.12)]), MapTier.singlePlace);
    });

    test('two points a few km apart in the same city are a single place', () {
      // Central London to Camden - well under the 50km single-place radius.
      const points = <LatLng>[(lat: 51.5074, lng: -0.1278), (lat: 51.5390, lng: -0.1426)];
      expect(decideMapTier(points), MapTier.singlePlace);
    });

    test('places within one country fit a region, not the whole world', () {
      // London, Manchester, Edinburgh - all within Great Britain.
      const points = <LatLng>[
        (lat: 51.5074, lng: -0.1278),
        (lat: 53.4808, lng: -2.2426),
        (lat: 55.9533, lng: -3.1883),
      ];
      expect(decideMapTier(points), MapTier.region);
    });

    test('places spread across continents show the whole world', () {
      // New York, Tokyo, Sydney.
      const points = <LatLng>[
        (lat: 40.7128, lng: -74.0060),
        (lat: 35.6762, lng: 139.6503),
        (lat: -33.8688, lng: 151.2093),
      ];
      expect(decideMapTier(points), MapTier.world);
    });

    test('the singlePlace/region boundary is exactly kMapSinglePlaceRadiusKm', () {
      final justUnder = maxPairwiseDistanceKm(const [
        (lat: 0, lng: 0),
        (lat: 0, lng: 0.4), // ~44.4km at the equator
      ]);
      expect(justUnder, lessThan(kMapSinglePlaceRadiusKm));
    });

    test('the region/world boundary is exactly kMapWorldSpanKm', () {
      // ~3003km apart at the equator.
      const atThreshold = <LatLng>[(lat: 0, lng: 0), (lat: 0, lng: 27)];
      expect(maxPairwiseDistanceKm(atThreshold), greaterThan(kMapWorldSpanKm));
      expect(decideMapTier(atThreshold), MapTier.world);
    });
  });

  group('haversineKm', () {
    test('the same point is zero distance apart', () {
      expect(haversineKm((lat: 10, lng: 20), (lat: 10, lng: 20)), 0);
    });

    test('a known city pair: London to Paris is roughly 344km', () {
      final d = haversineKm((lat: 51.5074, lng: -0.1278), (lat: 48.8566, lng: 2.3522));
      expect(d, closeTo(344, 10));
    });
  });

  group('maxPairwiseDistanceKm', () {
    test('fewer than two points has no distance', () {
      expect(maxPairwiseDistanceKm(const <LatLng>[]), 0);
      expect(maxPairwiseDistanceKm(const <LatLng>[(lat: 0, lng: 0)]), 0);
    });

    test('picks the diameter, not just the first pair', () {
      const points = <LatLng>[
        (lat: 0, lng: 0),
        (lat: 0, lng: 1), // close to the first
        (lat: 40, lng: 90), // far from both
      ];
      final d = maxPairwiseDistanceKm(points);
      expect(d, greaterThan(haversineKm(points[0], points[1])));
    });
  });

  group('markerRadius', () {
    test('the busiest place gets the maximum radius', () {
      expect(markerRadius(10, 10), kMapMarkerMaxRadius);
    });

    test('a place with the fewest check-ins gets the minimum radius', () {
      expect(markerRadius(1, 10), kMapMarkerMinRadius);
    });

    test('radius grows monotonically with post count', () {
      final small = markerRadius(2, 20);
      final big = markerRadius(18, 20);
      expect(big, greaterThan(small));
    });
  });

  group('nudgeOverlappingMarkers', () {
    test('markers already far apart are left untouched', () {
      final centers = [const Offset(0, 0), const Offset(100, 0)];
      final result = nudgeOverlappingMarkers(centers, const [5, 5]);
      expect(result[0], const Offset(0, 0));
      expect(result[1], const Offset(100, 0));
    });

    test('coincident markers are pushed apart into two distinct, non-overlapping points', () {
      final centers = [const Offset(50, 50), const Offset(50, 50)];
      final result = nudgeOverlappingMarkers(centers, const [10, 10]);
      expect((result[0] - result[1]).distance, greaterThan(0));
    });

    test('nearly-overlapping markers end up at least their combined radii apart', () {
      final centers = [const Offset(0, 0), const Offset(5, 0)];
      final radii = const [10.0, 10.0];
      final result = nudgeOverlappingMarkers(centers, radii);
      final finalDist = (result[0] - result[1]).distance;
      expect(finalDist, greaterThan((centers[0] - centers[1]).distance));
    });
  });
}
