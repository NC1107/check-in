import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/memories/memories_screen.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/photo_viewer.dart';

/// The Memories surface's "Places" hub entry: the hub gating it on its own capability,
/// the place list's loading/loaded/empty/error states, a place with unresolved
/// coordinates still rendering normally, drilling into one place's own photo grid, and a
/// group switch mid-fetch never painting a stale response - reusing the existing
/// full-screen viewer for the "go to post" route exactly as events and timeline already
/// do.
class _FakePlacesApi extends ApiClient {
  _FakePlacesApi({
    List<Place>? places,
    Map<String, List<Post>>? placePosts,
    this.hasMorePlaces = const {},
    this.failPlaces = false,
  })  : _places = places ?? const [],
        _placePosts = placePosts ?? const {},
        super(baseUrl: 'https://x.invalid');

  final List<Place> _places;
  final Map<String, List<Post>> _placePosts;

  /// Keyed by location - places whose fake response should report hasMore: true,
  /// mirroring a server that capped the page.
  final Set<String> hasMorePlaces;

  final bool failPlaces;

  @override
  Future<List<Place>> places() async {
    if (failPlaces) throw Exception('boom');
    return _places;
  }

  @override
  Future<({List<Post> posts, bool hasMore})> placePosts(String location) async {
    return (posts: _placePosts[location] ?? const [], hasMore: hasMorePlaces.contains(location));
  }

  @override
  Future<Post?> randomMemory() async => null;

  @override
  Future<List<Event>> events({int? limit}) async => const [];
}

/// A fake ApiClient whose places() doesn't resolve until the test completes [completer] -
/// lets a test hold a fetch open mid-flight to switch groups before letting it land.
class _DelayedPlacesApi extends ApiClient {
  _DelayedPlacesApi(this.completer) : super(baseUrl: 'https://x.invalid');

  final Completer<List<Place>> completer;

  @override
  Future<List<Place>> places() => completer.future;
}

/// A bounded stand-in for pumpAndSettle(): a real AuthImage's network fetch never resolves
/// in a widget test, so pumpAndSettle's "pump until nothing is scheduled" loop times out the
/// instant any screen here renders a cover photo or photo tile. A handful of explicit frames
/// is plenty to flush a fetch's own Future and let setState rebuild - 400ms total, with
/// margin past the hub's own 200ms AnimatedSwitcher transition (memories_screen.dart).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ServerAccount account(String id, {bool placesCapable = false, bool memoriesCapable = false}) =>
      ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't',
        placesCapable: placesCapable,
        memoriesCapable: memoriesCapable,
      );

  Place place({
    String location = 'Lisbon, Portugal',
    double? lat = 38.72509,
    double? lng = -9.1498,
    int postCount = 5,
    int photoCount = 3,
    int posterCount = 2,
    DateTime? firstSeen,
    DateTime? lastSeen,
    int? coverMediaId = 501,
    bool homeArea = false,
  }) =>
      Place(
        location: location,
        lat: lat,
        lng: lng,
        postCount: postCount,
        photoCount: photoCount,
        posterCount: posterCount,
        firstSeen: firstSeen ?? DateTime(2026, 6, 1),
        lastSeen: lastSeen ?? DateTime(2026, 8, 1),
        coverMediaId: coverMediaId,
        homeArea: homeArea,
      );

  Post photoPost(int id, {int mediaId = 501, int authorId = 1, String authorName = 'Ada'}) => Post(
        id: id,
        authorId: authorId,
        authorName: authorName,
        kind: 'image',
        body: '',
        createdAt: DateTime(2026, 8, 1),
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        mediaIds: [mediaId],
        media: [PostMedia(id: mediaId, mime: 'image/jpeg')],
      );

  /// Pumps a Memories surface already fully open (value: 1), wired to [serverAccount] as
  /// the one signed-in, shown group - the hub's own capability gate reads straight off it.
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

  /// Like [pumpOpenSurface] but wires up more than one shown group, each resolved to its
  /// own api via [apiFor] - what the group-switch tests need.
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

  /// Opens Places and switches to the LIST view.
  ///
  /// Places opens on the map now (see _PlacesListViewState._viewMode), and every test in
  /// this file is about the list. The toggle is only present when there are places to show
  /// two ways at all, so the loading/empty/unsupported/error states - which have no list to
  /// switch to either - fall through untouched.
  /// Switches to the list when the toggle is on screen, and does nothing when it isn't.
  ///
  /// Also needed after a group switch: the screen remounts on the new group's key and lands
  /// back on its own default view, which is the map.
  Future<void> switchToListIfOffered(WidgetTester tester) async {
    final toList = find.bySemanticsLabel('List view');
    if (toList.evaluate().isNotEmpty) {
      await tester.tap(toList);
      await settle(tester);
    }
  }

  Future<void> openPlacesList(WidgetTester tester) async {
    await tester.tap(find.text('Places'));
    await settle(tester);
    await switchToListIfOffered(tester);
  }

  group('hub capability gate', () {
    testWidgets('offers "Places" when the group advertises the places capability', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true), api: _FakePlacesApi());

      expect(find.text('Places'), findsOneWidget);
    });

    testWidgets('hides "Places" when the group predates the places capability', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: false), api: _FakePlacesApi());

      expect(find.text('Places'), findsNothing);
    });
  });

  group('places list', () {
    testWidgets('loads and renders places with server (most-check-ins-first) order preserved',
        (tester) async {
      final lisbon = place(location: 'Lisbon, Portugal', postCount: 5, posterCount: 2);
      final denver = place(
          location: 'Denver, United States', postCount: 12, posterCount: 4, lat: null, lng: null);
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true),
          api: _FakePlacesApi(places: [lisbon, denver]));

      await openPlacesList(tester);

      expect(find.text('Lisbon, Portugal'), findsOneWidget);
      expect(find.text('5 check-ins'), findsOneWidget);

      // The second card is a full card-height below - out of the default test viewport,
      // exactly like a real device that hasn't scrolled yet.
      await tester.drag(find.byType(ListView), const Offset(0, -1000));
      await settle(tester);

      expect(find.text('Denver, United States'), findsOneWidget);
      expect(find.text('12 check-ins'), findsOneWidget);
      expect(find.text('4 people'), findsOneWidget);
    });

    testWidgets('a place with no resolved coordinates still renders like any other',
        (tester) async {
      final unresolved = place(
          location: 'Ocean City, United States',
          lat: null,
          lng: null,
          postCount: 3,
          posterCount: 1);
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true),
          api: _FakePlacesApi(places: [unresolved]));

      await openPlacesList(tester);

      expect(find.text('Ocean City, United States'), findsOneWidget);
      expect(find.text('3 check-ins'), findsOneWidget);
    });

    testWidgets('the truthful empty state for a group with no located posts yet', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true),
          api: _FakePlacesApi(places: const []));

      await openPlacesList(tester);

      expect(find.text('No places yet.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an honest error state when the fetch fails, with a way to retry', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true),
          api: _FakePlacesApi(failPlaces: true));

      await openPlacesList(tester);

      expect(find.text("Couldn't load your group's places."), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the back chevron returns to the hub root', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true),
          api: _FakePlacesApi(places: [place()]));

      await openPlacesList(tester);
      expect(find.bySemanticsLabel('Back'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Back'));
      await settle(tester);

      expect(find.text('Places'), findsOneWidget);
      expect(find.bySemanticsLabel('Back'), findsNothing,
          reason: 'back at the hub root has nowhere left to step back to');
    });

    testWidgets('the GeoNames attribution is shown alongside the list', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true),
          api: _FakePlacesApi(places: [place()]));

      await openPlacesList(tester);

      expect(find.textContaining('GeoNames'), findsOneWidget);
    });
  });

  group('place detail', () {
    testWidgets(
        'tapping a place fetches its posts and renders one photo tile per image; tapping '
        'one opens the existing viewer with the right post id and group id', (tester) async {
      final lisbon = place(location: 'Lisbon, Portugal');
      final api = _FakePlacesApi(places: [
        lisbon
      ], placePosts: {
        'Lisbon, Portugal': [
          photoPost(11, mediaId: 501, authorId: 1, authorName: 'Ada'),
          photoPost(12, mediaId: 502, authorId: 2, authorName: 'Bea'),
        ],
      });
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true), api: api);

      await openPlacesList(tester);
      await tester.tap(find.text('Lisbon, Portugal'));
      await settle(tester);

      expect(find.byType(SliverGrid), findsOneWidget);
      final tiles = find.bySemanticsLabel('Open photo');
      expect(tiles, findsNWidgets(2));

      await tester.tap(tiles.first);
      await settle(tester);

      final viewer = tester.widget<PhotoViewerScreen>(find.byType(PhotoViewerScreen));
      expect(viewer.media.single.id, 501);
      expect(viewer.postId, 11);
      expect(viewer.groupId, 'a.invalid');
    });

    testWidgets('the go-to-post route from the viewer reaches the real post detail screen',
        (tester) async {
      final lisbon = place(location: 'Lisbon, Portugal');
      final api = _FakePlacesApi(places: [
        lisbon
      ], placePosts: {
        'Lisbon, Portugal': [photoPost(21, mediaId: 601)],
      });
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true), api: api);

      await openPlacesList(tester);
      await tester.tap(find.text('Lisbon, Portugal'));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Open photo'));
      await settle(tester);

      await tester.tap(find.text('Go to post'));
      await settle(tester);

      final detail = tester.widget<PostDetailScreen>(find.byType(PostDetailScreen));
      expect(detail.postId, 21);
      expect(detail.groupId, 'a.invalid');
    });

    testWidgets('a place with no photo-bearing posts shows an honest "no photos" line',
        (tester) async {
      final lisbon = place(location: 'Lisbon, Portugal', photoCount: 0, coverMediaId: null);
      final textPost = Post(
        id: 31,
        authorId: 1,
        authorName: 'Ada',
        kind: 'text',
        body: 'no photo here',
        createdAt: DateTime(2026, 8, 1),
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
      );
      final api = _FakePlacesApi(places: [
        lisbon
      ], placePosts: {
        'Lisbon, Portugal': [textPost],
      });
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true), api: api);

      await openPlacesList(tester);
      await tester.tap(find.text('Lisbon, Portugal'));
      await settle(tester);

      expect(find.text('No photos at this place.'), findsOneWidget);
    });

    testWidgets('a truncated place never claims more check-ins than the grid actually holds',
        (tester) async {
      final lisbon = place(location: 'Lisbon, Portugal', postCount: 205, posterCount: 3);
      final posts = [for (var i = 1; i <= 200; i++) photoPost(i, mediaId: 1000 + i)];
      final api = _FakePlacesApi(
        places: [lisbon],
        placePosts: {'Lisbon, Portugal': posts},
        hasMorePlaces: {'Lisbon, Portugal'},
      );
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true), api: api);

      await openPlacesList(tester);
      await tester.tap(find.text('Lisbon, Portugal'));
      await settle(tester);

      expect(find.text('200+ check-ins · 3 people'), findsOneWidget);
      expect(find.text('205 check-ins · 3 people'), findsNothing,
          reason: 'must never surface the list route\'s unbounded aggregate over a capped page');
    });

    testWidgets('the back chevron returns to the places list, not straight to the hub root',
        (tester) async {
      final lisbon = place(location: 'Lisbon, Portugal');
      final api = _FakePlacesApi(places: [
        lisbon
      ], placePosts: {
        'Lisbon, Portugal': [photoPost(11)],
      });
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', placesCapable: true), api: api);

      await openPlacesList(tester);
      await tester.tap(find.text('Lisbon, Portugal'));
      await settle(tester);
      expect(find.text('Lisbon, Portugal'), findsOneWidget);
      expect(find.text('Places'), findsNothing,
          reason: 'the hub root is not showing while a place is open');

      await tester.tap(find.bySemanticsLabel('Back'));
      await settle(tester);

      // One step back lands on the places LIST, with the tapped place's card still
      // there - not the hub root, which would need a second back to reach.
      expect(find.text('Lisbon, Portugal'), findsOneWidget);
      expect(find.text('Places'), findsNothing,
          reason: 'one back step from place detail must land on the list, not the hub root');
      expect(find.bySemanticsLabel('Back'), findsOneWidget,
          reason: 'the list is not the hub root, so back must still be offered');

      await tester.tap(find.bySemanticsLabel('Back'));
      await settle(tester);

      expect(find.text('Places'), findsOneWidget,
          reason: 'the second back step reaches the hub root');
      expect(find.bySemanticsLabel('Back'), findsNothing);
    });
  });

  group('group selector', () {
    testWidgets(
        'switching to a group lacking the places capability shows the explicit not-supported '
        'message, not a bare empty state', (tester) async {
      final groupA = account('a.invalid', memoriesCapable: true, placesCapable: true);
      final groupB = account('b.invalid', memoriesCapable: true, placesCapable: false);
      await pumpOpenSurfaceMulti(tester,
          groups: [groupA, groupB],
          apiFor: (id) => _FakePlacesApi(places: id == 'a.invalid' ? [place()] : const []));

      await openPlacesList(tester);
      expect(find.text('Lisbon, Portugal'), findsOneWidget);

      await tester.tap(find.text('b.invalid')); // the header's own group selector pill
      await settle(tester);

      expect(find.text("This group doesn't support Places."), findsOneWidget);
      expect(find.text('No places yet.'), findsNothing,
          reason: 'a group with no such capability at all must read as unsupported, not as '
              'an honest empty state - those mean different things');
    });

    testWidgets(
        'a group switch mid-fetch never paints a stale response from the group that was left',
        (tester) async {
      final completerA = Completer<List<Place>>();
      final groupA = account('a.invalid', memoriesCapable: true, placesCapable: true);
      final groupB = account('b.invalid', memoriesCapable: true, placesCapable: true);
      final placeB = place(location: 'Denver, United States', postCount: 9);

      await pumpOpenSurfaceMulti(tester, groups: [groupA, groupB], apiFor: (id) {
        if (id == 'a.invalid') return _DelayedPlacesApi(completerA);
        return _FakePlacesApi(places: [placeB]);
      });

      await openPlacesList(tester);
      // A's fetch is still in flight (the completer hasn't resolved) - the list view keys
      // off the group id, so switching to B remounts it fresh rather than waiting on A.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.text('b.invalid'));
      await settle(tester);
      await switchToListIfOffered(tester);

      expect(find.text('Denver, United States'), findsOneWidget,
          reason: "B's own places must render once its fetch lands");

      // A's fetch finally resolves, long after the switch - its result must never reach
      // the screen: the old _PlacesListView was unmounted (a new key), so its own
      // `if (!mounted) return;` guard discards this late arrival.
      completerA.complete([place(location: 'Lisbon, Portugal')]);
      await settle(tester);

      expect(find.text('Denver, United States'), findsOneWidget,
          reason: "B's places must still be showing");
      expect(find.text('Lisbon, Portugal'), findsNothing,
          reason: "A's late-arriving response must never paint over B's own group");
    });
  });
}
