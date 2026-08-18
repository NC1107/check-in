import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/memories/map/places_map_painter.dart';
import 'package:checkin/features/memories/memories_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The explicit gesture-conflict rule between the Places map's own pan/zoom and the
/// Memories surface's horizontal-drag-to-close (see MemoriesHubController.mapViewActive's
/// own doc comment): while the map view is showing, a horizontal drag pans the map and
/// does NOT close the surface; the header's close (X) button and Android back both still
/// close it regardless.
class _FakePlacesApi extends ApiClient {
  _FakePlacesApi(this._places) : super(baseUrl: 'https://x.invalid');

  final List<Place> _places;

  @override
  Future<List<Place>> places() async => _places;

  @override
  Future<({List<Post> posts, bool hasMore})> placePosts(String location) async =>
      (posts: const <Post>[], hasMore: false);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ServerAccount account() => const ServerAccount(
        id: 'a.invalid',
        baseUrl: 'https://a.invalid',
        serverName: 'Alpha',
        token: 't',
        placesCapable: true,
        memoriesCapable: true,
      );

  // London/Manchester: ~262km apart - inside kMapSinglePlaceRadiusKm..kMapWorldSpanKm, so
  // this lands in the region tier (a real, interactive map, not the no-map singlePlace
  // state) - see map_tier_test.dart's own equivalent fixture.
  List<Place> regionPlaces() => [
        Place(
          location: 'London, United Kingdom',
          lat: 51.5074,
          lng: -0.1278,
          postCount: 8,
          photoCount: 0,
          posterCount: 2,
          firstSeen: DateTime(2026, 1, 1),
          lastSeen: DateTime(2026, 6, 1),
          homeArea: true,
        ),
        Place(
          location: 'Manchester, United Kingdom',
          lat: 53.4808,
          lng: -2.2426,
          postCount: 3,
          photoCount: 0,
          posterCount: 1,
          firstSeen: DateTime(2026, 2, 1),
          lastSeen: DateTime(2026, 3, 1),
          homeArea: false,
        ),
      ];

  Future<AnimationController> pumpOpenSurfaceInMapMode(
    WidgetTester tester, {
    required VoidCallback onClose,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    final controller = AnimationController(
        vsync: const TestVSync(), value: 1, duration: const Duration(milliseconds: 220));
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(
            () => MultiSessionController.seeded(MultiSession(groups: [account()], restored: true))),
        apiForGroupProvider.overrideWith((ref, id) => _FakePlacesApi(regionPlaces())),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: MemoriesSurface(controller: controller, onClose: onClose),
        ),
      ),
    ));
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.tap(find.text('Places'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Map view'));
    await settle(tester);
    return controller;
  }

  Finder mapPainterFinder() =>
      find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PlacesMapPainter,
          description: 'the Places map CustomPaint');

  PlacesMapPainter currentPainter(WidgetTester tester) =>
      (tester.widget(mapPainterFinder()) as CustomPaint).painter as PlacesMapPainter;

  group('map view gesture suppression', () {
    testWidgets('a horizontal drag on the map pans it and does not move the surface toward closed',
        (tester) async {
      var closeCalls = 0;
      final controller = await pumpOpenSurfaceInMapMode(tester, onClose: () => closeCalls++);

      final beforeWindow = currentPainter(tester).lngWindow;

      final gesture = await tester.startGesture(tester.getCenter(mapPainterFinder()));
      for (var i = 1; i <= 6; i++) {
        await gesture.moveBy(const Offset(20, 0), timeStamp: Duration(milliseconds: i * 16));
        await tester.pump();
      }
      await gesture.up();
      // Flushes the map's own onDoubleTap recognizer, which starts an internal timer on
      // every pointer-down to wait out kDoubleTapTimeout before ruling out a second tap -
      // otherwise that timer is still pending when this test tears down.
      await tester.pump(const Duration(milliseconds: 350));

      expect(controller.value, 1.0,
          reason: 'the surface must not budge toward closed while the map is being panned');
      expect(closeCalls, 0);

      final afterWindow = currentPainter(tester).lngWindow;
      expect(afterWindow.west, isNot(beforeWindow.west),
          reason: 'the drag must actually pan the map - the projected window should have moved');
    });

    testWidgets('the header close (X) button still closes the surface while the map is showing',
        (tester) async {
      var closeCalls = 0;
      late AnimationController controller;
      controller = await pumpOpenSurfaceInMapMode(tester, onClose: () {
        closeCalls++;
        controller.value = 0;
      });

      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pump();

      expect(closeCalls, 1);
    });

    testWidgets('Android back still closes the surface while the map is showing', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      var closeCalls = 0;
      late AnimationController controller;
      controller = await pumpOpenSurfaceInMapMode(
        tester,
        navigatorKey: nav,
        onClose: () {
          closeCalls++;
          controller.value = 0;
        },
      );

      // The Places screen itself is one level below the hub root, exactly like any other
      // hub entry - back steps up to the hub first, same as it would from the list view,
      // completely unaffected by the map's own gesture suppression (PopScope is a
      // separate mechanism from the horizontal-drag GestureDetector this feature guards).
      await nav.currentState!.maybePop();
      await tester.pump();
      expect(closeCalls, 0, reason: 'the first back step returns to the hub root, not closes yet');

      await nav.currentState!.maybePop();
      await tester.pump();
      expect(closeCalls, 1,
          reason: 'the second back step, now at the hub root, closes the surface');
    });
  });
}
