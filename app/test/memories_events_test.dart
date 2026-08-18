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

/// The Memories surface's "Group trips" hub entry: the hub itself gating each entry on
/// its own capability, the events list's loading/loaded/empty/error states, and drilling
/// into one event's own photos - reusing the existing full-screen viewer for the "go to
/// post" route exactly as a normal feed carousel does.
class _FakeEventsApi extends ApiClient {
  _FakeEventsApi({List<Event>? events, Map<int, Post>? posts, this.failEvents = false})
      : _events = events ?? const [],
        _posts = posts ?? const {},
        super(baseUrl: 'https://x.invalid');

  final List<Event> _events;
  final Map<int, Post> _posts;
  final bool failEvents;

  @override
  Future<List<Event>> events({int? limit}) async {
    if (failEvents) throw Exception('boom');
    return _events;
  }

  @override
  Future<Post> getPost(int id) async {
    final p = _posts[id];
    if (p == null) throw Exception('not found');
    return p;
  }

  @override
  Future<Post?> randomMemory() async => null;
}

/// A bounded stand-in for pumpAndSettle(): a real AuthImage's network fetch never resolves
/// in a widget test (CachedNetworkImage keeps its own retry/placeholder animation going),
/// so pumpAndSettle's "pump until nothing is scheduled" loop times out the instant any
/// screen here renders a cover photo or photo tile. A handful of explicit frames is plenty
/// to flush a fetch's own Future and let setState rebuild - nothing else here animates past
/// that.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ServerAccount account(String id, {bool memoriesCapable = false, bool eventsCapable = false}) =>
      ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't',
        memoriesCapable: memoriesCapable,
        eventsCapable: eventsCapable,
      );

  EventParticipant participant(int id, String name) => EventParticipant(id: id, name: name);

  Event event({
    String kind = 'trip',
    String place = 'Lisbon, Portugal',
    List<EventParticipant>? participants,
    List<int> postIds = const [1, 2],
    int photoCount = 2,
    int? coverMediaId = 501,
  }) =>
      Event(
        kind: kind,
        place: place,
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 3),
        participants: participants ?? [participant(1, 'Ada'), participant(2, 'Bea')],
        postIds: postIds,
        photoCount: photoCount,
        coverMediaId: coverMediaId,
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

  /// Pumps a Memories surface already fully open (value: 1), wired to [account] as the
  /// one signed-in, shown group - the hub's own capability gate reads straight off it.
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
  /// own api via [apiFor] - what the header's own group selector tests need in order to
  /// switch between groups.
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

  group('hub capability gate', () {
    testWidgets('offers both entries when both capabilities are advertised', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: true),
          api: _FakeEventsApi());

      expect(find.text('Random check-in'), findsOneWidget);
      expect(find.text('Group trips'), findsOneWidget);
    });

    testWidgets('hides "Group trips" when the group predates the events capability',
        (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: false),
          api: _FakeEventsApi());

      expect(find.text('Random check-in'), findsOneWidget);
      expect(find.text('Group trips'), findsNothing);
    });

    testWidgets('hides "Random check-in" when the group has events but not memories',
        (tester) async {
      // Not reachable through the real handle (which gates on memoriesCapable alone), but
      // the hub's own per-entry gate has to hold regardless of how it was reached.
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: false, eventsCapable: true),
          api: _FakeEventsApi());

      expect(find.text('Random check-in'), findsNothing);
      expect(find.text('Group trips'), findsOneWidget);
    });
  });

  group('events list', () {
    testWidgets('loads and renders detected events, newest (server) order preserved',
        (tester) async {
      final trip = event(kind: 'trip', place: 'Lisbon, Portugal');
      final gathering = event(
          kind: 'gathering',
          place: 'Austin, USA',
          postIds: const [3, 4, 5],
          participants: [participant(1, 'Ada'), participant(2, 'Bea'), participant(3, 'Cid')]);
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: true),
          api: _FakeEventsApi(events: [trip, gathering]));

      await tester.tap(find.text('Group trips'));
      await settle(tester);

      expect(find.text('Lisbon, Portugal'), findsOneWidget);
      expect(find.text('TRIP'), findsOneWidget);
      // The trip card lists both participants by name.
      expect(find.text('Ada & Bea'), findsOneWidget);

      // The second card is one full card-height below - out of the default test
      // viewport, exactly like a real device that hasn't scrolled yet, so it has to be
      // scrolled into view before it and its own content exist in the tree at all.
      await tester.drag(find.byType(ListView), const Offset(0, -1000));
      await settle(tester);

      expect(find.text('Austin, USA'), findsOneWidget);
      expect(find.text('GATHERING'), findsOneWidget);
      // The gathering's 3 participants name the first two and count the rest.
      expect(find.text('Ada, Bea & 1 others'), findsOneWidget);
    });

    testWidgets('the truthful empty state for a group with no detected events', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: true),
          api: _FakeEventsApi(events: const []));

      await tester.tap(find.text('Group trips'));
      await settle(tester);

      expect(find.text('No trips or gatherings yet.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an honest error state when the fetch fails, with a way to retry', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: true),
          api: _FakeEventsApi(failEvents: true));

      await tester.tap(find.text('Group trips'));
      await settle(tester);

      expect(find.text("Couldn't load your group's events."), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the back chevron returns to the hub root', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: true),
          api: _FakeEventsApi(events: [event()]));

      await tester.tap(find.text('Group trips'));
      await settle(tester);
      expect(find.bySemanticsLabel('Back'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Back'));
      await settle(tester);

      expect(find.text('Random check-in'), findsOneWidget);
      expect(find.text('Group trips'), findsOneWidget);
      expect(find.bySemanticsLabel('Back'), findsNothing,
          reason: 'back at the hub root has nowhere left to step back to');
    });
  });

  group('event detail', () {
    testWidgets(
        'drilling into an event fetches its posts and renders one photo tile per '
        'image; tapping one opens the existing viewer scoped to that post', (tester) async {
      final ev = event(postIds: const [11, 12]);
      final api = _FakeEventsApi(events: [
        ev
      ], posts: {
        11: photoPost(11, mediaId: 501, authorId: 1, authorName: 'Ada'),
        12: photoPost(12, mediaId: 502, authorId: 2, authorName: 'Bea'),
      });
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: true),
          api: api);

      await tester.tap(find.text('Group trips'));
      await settle(tester);
      await tester.tap(find.text('Lisbon, Portugal'));
      await settle(tester);

      expect(find.byType(SliverGrid), findsOneWidget);
      final tiles = find.bySemanticsLabel('Open photo');
      expect(tiles, findsNWidgets(2));

      await tester.tap(tiles.first);
      await settle(tester);

      final viewer = tester.widget<PhotoViewerScreen>(find.byType(PhotoViewerScreen));
      expect(viewer.media.single.id, 501);
      expect(viewer.postId, 11,
          reason: 'the viewer must be scoped to the tapped photo\'s own post, not the whole '
              'event');
    });

    testWidgets('the go-to-post route from the viewer reaches the real post detail screen',
        (tester) async {
      final ev = event(postIds: const [21]);
      final api = _FakeEventsApi(events: [ev], posts: {21: photoPost(21, mediaId: 601)});
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: true),
          api: api);

      await tester.tap(find.text('Group trips'));
      await settle(tester);
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

    testWidgets('an event with nothing photo-bearing shows an honest "no photos" line',
        (tester) async {
      final ev = event(postIds: const [31], coverMediaId: null);
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
      final api = _FakeEventsApi(events: [ev], posts: {31: textPost});
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', memoriesCapable: true, eventsCapable: true),
          api: api);

      await tester.tap(find.text('Group trips'));
      await settle(tester);
      await tester.tap(find.text('Lisbon, Portugal'));
      await settle(tester);

      expect(find.text('No photos in this one.'), findsOneWidget);
    });
  });

  group('group selector', () {
    testWidgets(
        'switching to a group lacking the events capability shows the explicit '
        'not-supported message, not a bare empty state', (tester) async {
      final groupA = account('a.invalid', memoriesCapable: true, eventsCapable: true);
      final groupB = account('b.invalid', memoriesCapable: true, eventsCapable: false);
      await pumpOpenSurfaceMulti(tester,
          groups: [groupA, groupB],
          apiFor: (id) => _FakeEventsApi(events: id == 'a.invalid' ? [event()] : const []));

      await tester.tap(find.text('Group trips'));
      await settle(tester);
      expect(find.text('Lisbon, Portugal'), findsOneWidget);

      // The group filter is a menu in the header now, so switching is two steps:
      // open it, then pick.
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Filter by group')));
      await settle(tester);
      await tester.tap(find.text('b.invalid').last);
      await settle(tester);

      expect(find.text("This group doesn't support Group trips."), findsOneWidget);
      expect(find.text('No trips or gatherings yet.'), findsNothing,
          reason: 'a group with no such capability at all must read as unsupported, not as '
              'an honest empty state - those mean different things');
    });
  });
}
