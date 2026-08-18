import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/memories/memories_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The Memories "Places" screen's map view (phase 2 of the Places feature - the list view's
/// own tests live in memories_places_test.dart): the list/map toggle, the tiered map itself
/// rendering for a real payload, the tasteful no-map state for a group that's all in one
/// place, a place with unresolved coordinates surfaced rather than silently dropped, tapping
/// a marker reaching the same place detail the list view's own card opens, and the map
/// staying well-behaved across the existing unsupported/empty/error states and a group
/// switch.
class _FakePlacesApi extends ApiClient {
  _FakePlacesApi({List<Place>? places, this.failPlaces = false})
      : _places = places ?? const [],
        super(baseUrl: 'https://x.invalid');

  final List<Place> _places;
  final bool failPlaces;

  @override
  Future<List<Place>> places() async {
    if (failPlaces) throw Exception('boom');
    return _places;
  }

  @override
  Future<({List<Post> posts, bool hasMore})> placePosts(String location) async =>
      (posts: const <Post>[], hasMore: false);

  @override
  Future<Post?> randomMemory() async => null;

  @override
  Future<List<Event>> events({int? limit}) async => const [];
}

/// A bounded stand-in for pumpAndSettle() - see memories_places_test.dart's identical
/// helper for why: a real AuthImage's network fetch never resolves in a widget test, and
/// the map's own asset load is a genuine Future too.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ServerAccount account(String id, {bool placesCapable = true}) => ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't',
        placesCapable: placesCapable,
        memoriesCapable: true,
      );

  Place place({
    required String location,
    double? lat,
    double? lng,
    int postCount = 5,
    int posterCount = 2,
    bool homeArea = false,
  }) =>
      Place(
        location: location,
        lat: lat,
        lng: lng,
        postCount: postCount,
        photoCount: 0,
        posterCount: posterCount,
        firstSeen: DateTime(2026, 1, 1),
        lastSeen: DateTime(2026, 6, 1),
        homeArea: homeArea,
      );

  Future<void> pumpOpenSurface(WidgetTester tester,
      {required ServerAccount serverAccount, required ApiClient api}) async {
    final controller = AnimationController(
        vsync: const TestVSync(), value: 1, duration: const Duration(milliseconds: 220));
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() =>
            MultiSessionController.seeded(MultiSession(groups: [serverAccount], restored: true))),
        apiForGroupProvider.overrideWith((ref, id) => api),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MemoriesSurface(controller: controller, onClose: () => controller.value = 0),
        ),
      ),
    ));
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  Future<void> pumpOpenSurfaceMulti(WidgetTester tester,
      {required List<ServerAccount> groups,
      required ApiClient Function(String groupId) apiFor}) async {
    final controller = AnimationController(
        vsync: const TestVSync(), value: 1, duration: const Duration(milliseconds: 220));
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(
            () => MultiSessionController.seeded(MultiSession(groups: groups, restored: true))),
        apiForGroupProvider.overrideWith((ref, id) => apiFor(id)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MemoriesSurface(controller: controller, onClose: () => controller.value = 0),
        ),
      ),
    ));
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  Future<void> openPlacesInMapMode(WidgetTester tester) async {
    await tester.tap(find.text('Places'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Map view'));
    await settle(tester);
  }

  group('list/map toggle', () {
    testWidgets('is offered once places have loaded, and opens on the map', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'),
          api: _FakePlacesApi(places: [place(location: 'Lisbon, Portugal', lat: 38.7, lng: -9.1)]));

      await tester.tap(find.text('Places'));
      await settle(tester);

      expect(find.bySemanticsLabel('List view'), findsOneWidget);
      expect(find.bySemanticsLabel('Map view'), findsOneWidget);
      // The map is the starting view, not the list - and the toggle rides over it in every
      // state, including this one, since it is the only way back to the list. A lone place
      // still renders the no-map state rather than a single-node map, so the place is named
      // there instead of on a list card.
      expect(find.textContaining('Lisbon, Portugal'), findsOneWidget);
    });

    testWidgets(
        'is absent from the loading/empty/unsupported/error states, same as any '
        'other memories view', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'), api: _FakePlacesApi(places: const []));

      await tester.tap(find.text('Places'));
      await settle(tester);

      expect(find.text('No places yet.'), findsOneWidget);
      expect(find.bySemanticsLabel('Map view'), findsNothing);
    });

    testWidgets(
        'a group switched to mid-visit that lacks the capability shows its usual '
        'message with no toggle', (tester) async {
      // The hub entry itself is gated on the capability (see memories_places_test.dart's own
      // "hub capability gate" group), so the only way to reach _PlacesListView's own
      // unsupported branch is a group switch mid-visit, exactly as that file's own
      // equivalent test does.
      final capable = account('a.invalid');
      final incapable = account('b.invalid', placesCapable: false);
      await pumpOpenSurfaceMulti(tester, groups: [capable, incapable], apiFor: (id) {
        return _FakePlacesApi(
            places: id == 'a.invalid'
                ? [place(location: 'Lisbon, Portugal', lat: 38.7, lng: -9.1)]
                : const []);
      });

      await tester.tap(find.text('Places'));
      await settle(tester);
      await tester.tap(find.text('b.invalid')); // the header's own group selector pill
      await settle(tester);

      expect(find.text("This group doesn't support Places."), findsOneWidget);
      expect(find.bySemanticsLabel('Map view'), findsNothing);
    });

    testWidgets('a failed fetch shows its usual retry state with no toggle', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'), api: _FakePlacesApi(failPlaces: true));

      await tester.tap(find.text('Places'));
      await settle(tester);

      expect(find.text("Couldn't load your group's places."), findsOneWidget);
      expect(find.bySemanticsLabel('Map view'), findsNothing);
    });
  });

  group('the map itself', () {
    testWidgets(
        'renders a real, varied payload (world spread, unresolved place, home vs '
        'trip) without throwing', (tester) async {
      final places = [
        place(location: 'Lisbon, Portugal', lat: 38.7223, lng: -9.1393, homeArea: true),
        place(location: 'Tokyo, Japan', lat: 35.6762, lng: 139.6503, postCount: 12),
        place(location: 'Sydney, Australia', lat: -33.8688, lng: 151.2093, postCount: 2),
        place(location: 'Ocean City, United States', lat: null, lng: null),
      ];
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'), api: _FakePlacesApi(places: places));

      await openPlacesInMapMode(tester);

      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Lisbon, Portugal'), findsOneWidget);
      expect(find.bySemanticsLabel('Tokyo, Japan'), findsOneWidget);
      expect(find.bySemanticsLabel('Sydney, Australia'), findsOneWidget);
    });

    testWidgets('a group with only one place shows the tasteful no-map state, not a lone dot',
        (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'),
          api: _FakePlacesApi(
              places: [place(location: 'Lisbon, Portugal', lat: 38.7223, lng: -9.1393)]));

      await openPlacesInMapMode(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Every check-in has been in Lisbon, Portugal'), findsOneWidget);
      // No tappable marker was drawn - a single dot on an otherwise-empty outline is exactly
      // what the brief calls out as reading broken, so this state must render no marker at
      // all rather than a map with one dot on it.
      expect(find.bySemanticsLabel('Lisbon, Portugal'), findsNothing);
    });

    testWidgets(
        'places that all sit within the same small area also get the no-map state, '
        'not a lone dot for each', (tester) async {
      final places = [
        place(location: 'Lisbon, Portugal', lat: 38.7223, lng: -9.1393),
        place(location: 'Cascais, Portugal', lat: 38.6979, lng: -9.4215), // ~26km away
      ];
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'), api: _FakePlacesApi(places: places));

      await openPlacesInMapMode(tester);

      expect(find.textContaining("You've all stuck close together"), findsOneWidget);
      expect(find.bySemanticsLabel('Lisbon, Portugal'), findsNothing);
      expect(find.bySemanticsLabel('Cascais, Portugal'), findsNothing);
    });

    testWidgets(
        'a place with unresolved coordinates never silently disappears from the map '
        'screen - it is named in an honest note', (tester) async {
      final places = [
        place(location: 'Lisbon, Portugal', lat: 38.7223, lng: -9.1393),
        place(location: 'Porto, Portugal', lat: 41.1579, lng: -8.6291),
        place(location: 'Ocean City, United States', lat: null, lng: null),
      ];
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'), api: _FakePlacesApi(places: places));

      await openPlacesInMapMode(tester);

      expect(find.textContaining("Couldn't place on the map"), findsOneWidget);
      expect(find.textContaining('Ocean City, United States'), findsOneWidget);
    });

    testWidgets('every place unresolved shows the honest "none plotted" state plus the note',
        (tester) async {
      final places = [
        place(location: 'Ocean City, United States', lat: null, lng: null),
        place(location: 'Somewhere Else', lat: null, lng: null),
      ];
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'), api: _FakePlacesApi(places: places));

      await openPlacesInMapMode(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining("could be placed on a map yet"), findsOneWidget);
      expect(find.textContaining("Couldn't place on the map"), findsOneWidget);
    });

    testWidgets(
        'tapping a marker opens that place\'s own detail, reusing the shared photo '
        'grid route', (tester) async {
      final places = [
        place(location: 'London, United Kingdom', lat: 51.5074, lng: -0.1278, postCount: 8),
        place(location: 'Manchester, United Kingdom', lat: 53.4808, lng: -2.2426, postCount: 3),
      ];
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid'), api: _FakePlacesApi(places: places));

      await openPlacesInMapMode(tester);
      await tester.tap(find.bySemanticsLabel('Manchester, United Kingdom'));
      await settle(tester);

      expect(find.text('Manchester, United Kingdom'), findsOneWidget);
      expect(find.text('Places'), findsNothing,
          reason: 'the hub root/list is not showing while a place detail is open');
    });
  });

  group('all-groups scope', () {
    // All UK on purpose: places far enough apart to stay separate nodes at the fitted zoom,
    // rather than collapsing into clusters the way a London/Tokyo spread does - clustering
    // is correct behaviour there, but it hides the per-place labels this asserts on.
    final londonAndManchester = [
      place(location: 'London, United Kingdom', lat: 51.5074, lng: -0.1278),
      place(location: 'Manchester, United Kingdom', lat: 53.4808, lng: -2.2426),
    ];

    testWidgets('the map can show every group at once, and goes back to one', (tester) async {
      await pumpOpenSurfaceMulti(tester,
          groups: [account('a.invalid'), account('b.invalid')],
          apiFor: (id) => _FakePlacesApi(
              places: id == 'a.invalid'
                  ? londonAndManchester
                  : [place(location: 'Bristol, United Kingdom', lat: 51.4545, lng: -2.5879)]));

      await openPlacesInMapMode(tester);
      expect(find.bySemanticsLabel('London, United Kingdom'), findsOneWidget);
      expect(find.bySemanticsLabel('Bristol, United Kingdom'), findsNothing,
          reason: 'the map starts scoped to the selected group only');

      await tester.tap(find.bySemanticsLabel('Showing this group only'));
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Bristol, United Kingdom'), findsOneWidget,
          reason: "the other group's places must join the map");
      expect(find.bySemanticsLabel('London, United Kingdom'), findsOneWidget,
          reason: 'and must join it rather than replacing what was already there');

      await tester.tap(find.bySemanticsLabel('Showing all groups'));
      await settle(tester);

      expect(find.bySemanticsLabel('Bristol, United Kingdom'), findsNothing,
          reason: 'switching back must drop the other group again');
      expect(find.bySemanticsLabel('London, United Kingdom'), findsOneWidget);
    });

    testWidgets('one group failing does not take the whole all-groups map down', (tester) async {
      await pumpOpenSurfaceMulti(tester,
          groups: [account('a.invalid'), account('b.invalid')],
          apiFor: (id) => id == 'a.invalid'
              ? _FakePlacesApi(places: londonAndManchester)
              : _FakePlacesApi(failPlaces: true));

      await openPlacesInMapMode(tester);
      await tester.tap(find.bySemanticsLabel('Showing this group only'));
      await settle(tester);

      // Several servers are involved, so one being unreachable is ordinary. Showing the
      // groups that answered beats an error covering all of them.
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('London, United Kingdom'), findsOneWidget);
    });
  });

  group('group selector', () {
    testWidgets(
        'switching groups while in map mode is clean: the new group\'s own places '
        'load with no leftover markers from the group that was left', (tester) async {
      final groupA = account('a.invalid');
      final groupB = account('b.invalid');
      final placesA = [
        place(location: 'London, United Kingdom', lat: 51.5074, lng: -0.1278),
        place(location: 'Manchester, United Kingdom', lat: 53.4808, lng: -2.2426),
      ];
      final placesB = [
        place(location: 'Tokyo, Japan', lat: 35.6762, lng: 139.6503),
        place(location: 'Osaka, Japan', lat: 34.6937, lng: 135.5023),
      ];

      await pumpOpenSurfaceMulti(tester, groups: [groupA, groupB], apiFor: (id) {
        return _FakePlacesApi(places: id == 'a.invalid' ? placesA : placesB);
      });

      await openPlacesInMapMode(tester);
      expect(find.bySemanticsLabel('London, United Kingdom'), findsOneWidget);

      await tester.tap(find.text('b.invalid')); // the header's own group selector pill
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('London, United Kingdom'), findsNothing,
          reason: "the left group's markers must not linger");
      expect(find.bySemanticsLabel('Manchester, United Kingdom'), findsNothing);
      // The screen remounts fresh for the new group (a new ValueKey - the same convention
      // every other Memories list view already uses on a group switch), which lands it back
      // on its own default view. That default is the map, so the new group's places arrive
      // as map nodes rather than list rows.
      expect(find.bySemanticsLabel('Tokyo, Japan'), findsOneWidget);
    });
  });
}
