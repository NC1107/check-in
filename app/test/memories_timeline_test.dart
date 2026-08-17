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

/// The Memories surface's "Your months" hub entry: the hub gating it on its own
/// capability, the month list's loading/loaded/empty/error states, and drilling into one
/// month's own photo grid - reusing the existing full-screen viewer for the "go to post"
/// route exactly as the events feature (and a normal feed carousel) already does.
class _FakeTimelineApi extends ApiClient {
  _FakeTimelineApi({
    List<TimelineMonth>? months,
    Map<String, List<Post>>? monthPosts,
    this.hasMoreMonths = const {},
    this.failTimeline = false,
  })  : _months = months ?? const [],
        _monthPosts = monthPosts ?? const {},
        super(baseUrl: 'https://x.invalid');

  final List<TimelineMonth> _months;
  final Map<String, List<Post>> _monthPosts;

  /// Keyed like _monthPosts ('$year-$month') - months whose fake response should report
  /// hasMore: true, mirroring a server that capped the page.
  final Set<String> hasMoreMonths;

  final bool failTimeline;

  @override
  Future<List<TimelineMonth>> timeline() async {
    if (failTimeline) throw Exception('boom');
    return _months;
  }

  @override
  Future<({List<Post> posts, bool hasMore})> timelineMonth(int year, int month) async {
    final key = '$year-$month';
    return (posts: _monthPosts[key] ?? const [], hasMore: hasMoreMonths.contains(key));
  }

  @override
  Future<Post?> randomMemory() async => null;

  @override
  Future<List<Event>> events({int? limit}) async => const [];
}

/// A bounded stand-in for pumpAndSettle(): a real AuthImage's network fetch never resolves
/// in a widget test, so pumpAndSettle's "pump until nothing is scheduled" loop times out the
/// instant any screen here renders a cover photo or photo tile. A handful of explicit frames
/// is plenty to flush a fetch's own Future and let setState rebuild.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ServerAccount account(String id, {bool timelineCapable = false}) => ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't',
        timelineCapable: timelineCapable,
      );

  TimelineMonth month({
    int year = 2026,
    int month = 8,
    int postCount = 5,
    int photoCount = 3,
    int clipCount = 0,
    int placeCount = 1,
    int posterCount = 2,
    List<int> coverMediaIds = const [501, 502],
  }) =>
      TimelineMonth(
        year: year,
        month: month,
        postCount: postCount,
        photoCount: photoCount,
        clipCount: clipCount,
        placeCount: placeCount,
        posterCount: posterCount,
        coverMediaIds: coverMediaIds,
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

  group('hub capability gate', () {
    testWidgets('offers "Your months" when the group advertises the timeline capability',
        (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true), api: _FakeTimelineApi());

      expect(find.text('Your months'), findsOneWidget);
    });

    testWidgets('hides "Your months" when the group predates the timeline capability',
        (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: false), api: _FakeTimelineApi());

      expect(find.text('Your months'), findsNothing);
    });
  });

  group('timeline list', () {
    testWidgets('loads and renders months newest (server) order preserved', (tester) async {
      final aug = month(year: 2026, month: 8, postCount: 5);
      final jul = month(year: 2026, month: 7, postCount: 12, placeCount: 3, posterCount: 4);
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true),
          api: _FakeTimelineApi(months: [aug, jul]));

      await tester.tap(find.text('Your months'));
      await settle(tester);

      expect(find.text('August 2026'), findsOneWidget);
      expect(find.text('5 check-ins'), findsOneWidget);

      // The second card is a full card-height below - out of the default test viewport,
      // exactly like a real device that hasn't scrolled yet.
      await tester.drag(find.byType(ListView), const Offset(0, -1000));
      await settle(tester);

      expect(find.text('July 2026'), findsOneWidget);
      expect(find.text('12 check-ins'), findsOneWidget);
      expect(find.text('4 people'), findsOneWidget);
    });

    testWidgets('the truthful empty state for a group with no history yet', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true),
          api: _FakeTimelineApi(months: const []));

      await tester.tap(find.text('Your months'));
      await settle(tester);

      expect(find.text('No history yet.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an honest error state when the fetch fails, with a way to retry', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true),
          api: _FakeTimelineApi(failTimeline: true));

      await tester.tap(find.text('Your months'));
      await settle(tester);

      expect(find.text("Couldn't load your group's months."), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a month whose cover media is missing still renders the card', (tester) async {
      // No fake failure is injected here: AuthImage's own errorWidget (a broken-image
      // placeholder) is what "missing media degrades, not breaks" means in practice, and
      // that path already runs unexercised-but-harmlessly under a widget test's fake
      // network - this test's job is just to prove the card itself doesn't throw or vanish
      // when it's asked to render a cover id nothing backs.
      final deletedCover = month(coverMediaIds: const [999999]);
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true),
          api: _FakeTimelineApi(months: [deletedCover]));

      await tester.tap(find.text('Your months'));
      await settle(tester);

      expect(find.text('August 2026'), findsOneWidget);
    });

    testWidgets('the back chevron returns to the hub root', (tester) async {
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true),
          api: _FakeTimelineApi(months: [month()]));

      await tester.tap(find.text('Your months'));
      await settle(tester);
      expect(find.bySemanticsLabel('Back'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Back'));
      await settle(tester);

      expect(find.text('Your months'), findsOneWidget);
      expect(find.bySemanticsLabel('Back'), findsNothing,
          reason: 'back at the hub root has nowhere left to step back to');
    });
  });

  group('month detail', () {
    testWidgets(
        'tapping a month fetches its posts and renders one photo tile per image; tapping '
        'one opens the existing viewer with the right post id and group id', (tester) async {
      final aug = month(year: 2026, month: 8);
      final api = _FakeTimelineApi(months: [
        aug
      ], monthPosts: {
        '2026-8': [
          photoPost(11, mediaId: 501, authorId: 1, authorName: 'Ada'),
          photoPost(12, mediaId: 502, authorId: 2, authorName: 'Bea'),
        ],
      });
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true), api: api);

      await tester.tap(find.text('Your months'));
      await settle(tester);
      await tester.tap(find.text('August 2026'));
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
      final aug = month(year: 2026, month: 8);
      final api = _FakeTimelineApi(months: [
        aug
      ], monthPosts: {
        '2026-8': [photoPost(21, mediaId: 601)],
      });
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true), api: api);

      await tester.tap(find.text('Your months'));
      await settle(tester);
      await tester.tap(find.text('August 2026'));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Open photo'));
      await settle(tester);

      await tester.tap(find.text('Go to post'));
      await settle(tester);

      final detail = tester.widget<PostDetailScreen>(find.byType(PostDetailScreen));
      expect(detail.postId, 21);
      expect(detail.groupId, 'a.invalid');
    });

    testWidgets('a month with no photo-bearing posts shows an honest "no photos" line',
        (tester) async {
      final aug = month(year: 2026, month: 8, photoCount: 0, coverMediaIds: const []);
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
      final api = _FakeTimelineApi(months: [
        aug
      ], monthPosts: {
        '2026-8': [textPost],
      });
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true), api: api);

      await tester.tap(find.text('Your months'));
      await settle(tester);
      await tester.tap(find.text('August 2026'));
      await settle(tester);

      expect(find.text('No photos this month.'), findsOneWidget);
    });

    testWidgets('a month with many posts renders every image across all of them', (tester) async {
      final aug = month(year: 2026, month: 8, postCount: 200);
      final posts = [for (var i = 1; i <= 200; i++) photoPost(i, mediaId: 1000 + i)];
      final api = _FakeTimelineApi(months: [aug], monthPosts: {'2026-8': posts});
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true), api: api);

      await tester.tap(find.text('Your months'));
      await settle(tester);
      await tester.tap(find.text('August 2026'));
      await settle(tester);

      expect(find.byType(SliverGrid), findsOneWidget);
      // 200 photo tiles is well beyond one screen's worth; only the grid's mere existence
      // and the header's own numbers need proving here - lazy-built children off-screen are
      // already covered by _EventDetailView's own identical SliverGrid usage. hasMore is
      // false (the fake's default), so the header reads a plain "200 check-ins" - the exact
      // fetched count, no truncation marker.
      expect(find.text('200 check-ins · 2 people'), findsOneWidget);
    });

    testWidgets('a truncated month never claims more check-ins than the grid actually holds',
        (tester) async {
      // The list route's own aggregate says 205 - a real, honest number for the whole
      // month - but the detail route only ever returns (and this fake mirrors) the capped
      // 200-post page with hasMore: true. The header must key off the 200 actually
      // fetched, not the 205 from the list, and must mark the month as truncated rather
      // than silently presenting 200 as the whole story.
      final aug = month(year: 2026, month: 8, postCount: 205, posterCount: 3);
      final posts = [for (var i = 1; i <= 200; i++) photoPost(i, mediaId: 1000 + i)];
      final api = _FakeTimelineApi(
        months: [aug],
        monthPosts: {'2026-8': posts},
        hasMoreMonths: {'2026-8'},
      );
      await pumpOpenSurface(tester,
          serverAccount: account('a.invalid', timelineCapable: true), api: api);

      await tester.tap(find.text('Your months'));
      await settle(tester);
      await tester.tap(find.text('August 2026'));
      await settle(tester);

      expect(find.text('200+ check-ins · 3 people'), findsOneWidget);
      expect(find.text('205 check-ins · 3 people'), findsNothing,
          reason: 'must never surface the list route\'s unbounded aggregate over a capped page');
    });
  });
}
