import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/recap_card.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/clip_poster.dart';
import 'package:checkin/widgets/feed_clip.dart';
import 'package:checkin/widgets/photo_viewer.dart';
import 'package:checkin/widgets/user_avatar.dart';

/// An ApiClient whose post/comment reads are stubbed, the same way
/// comment_gif_render_test.dart drives PostDetailScreen without a network - only the calls
/// the screen actually makes are overridden.
class _FakeApi extends ApiClient {
  _FakeApi({required this.post}) : super(baseUrl: '');

  final Post post;

  @override
  Future<Post> getPost(int id) async => post;

  @override
  Future<List<Comment>> comments(int postId) async => const [];
}

/// RecapDeck is the swipeable panel deck a recap post renders in place of ordinary media
/// (see post_card.dart's `if (recap != null)` branch). These tests build the payload from
/// plain model literals - no server, no fixtures - mirroring post_card_test.dart's style,
/// including a real ProviderScope + seeded MultiSessionController so a card that ever
/// reaches for a UserAvatar/MediaFrame image finds a working provider tree rather than
/// crashing on a missing one.
void main() {
  final user = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true);
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: user,
  );

  // The round-5 cover reports real visibility through the `visibility_detector` package
  // (see recap_card.dart's _RecapCoverPageState). Zero here means its callbacks fire off a
  // post-frame callback instead of a real Timer - the package's own documented "useful for
  // automated tests" mode - so pumping this file's decks never leaves one of the package's
  // own Timers pending the way its ordinary interval would.
  setUpAll(() => VisibilityDetectorController.instance.updateInterval = Duration.zero);

  // The cover's own debounce (a real 200ms Timer) and its ambient AnimationControllers
  // (the bubble entrance plays on mount; the float/backdrop cycle once visibility settles -
  // see _RecapCoverPageState, _BubbleClusterState, _CoverBackdropState) outlive a single
  // `pump()` unless the widget is unmounted. Almost none of the tests below care about that
  // animation at all, so every helper that pumps a deck registers this once it is done:
  // flutter_test's own end-of-test checks (no pending Timer, no still-ticking animation)
  // would otherwise trip on nearly every test in this file the moment a cover carried a
  // photo or a poster.
  void disposeCoverAfterTest(WidgetTester tester) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      // Longer than _RecapCoverPageState's own 200ms debounce: unmounting cancels it
      // synchronously when the widget was actually removed in time, but if a settle Timer
      // was mid-flight at that exact instant this instead just lets it fire naturally - its
      // own `if (!mounted) return;` guard makes that a no-op, and a fired one-shot Timer is
      // no longer "pending" either way.
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  Future<void> pumpDeck(WidgetTester tester, RecapPayload recap,
      {int postId = 1, List<Override> overrides = const []}) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller), ...overrides],
      child: MaterialApp(
        // A phone-width column, like the card the deck actually lives in (post_card.dart's
        // feed-width card). The deck's AspectRatio page needs a bounded width to avoid
        // overflowing the test surface's fixed 600-tall viewport.
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
                width: 340, child: RecapDeck(recap: recap, groupId: account.id, postId: postId)),
          ),
        ),
      ),
    ));
    await tester.pump();
    disposeCoverAfterTest(tester);
  }

  /// Swipes a PageView left, one page at a time - what a real viewer does to get past the
  /// cover page (always page 0) to a panel's own content.
  Future<void> swipeToPage(WidgetTester tester, Finder pageView, int index) async {
    for (var i = 0; i < index; i++) {
      await tester.drag(pageView, const Offset(-400, 0));
      await tester.pumpAndSettle();
    }
  }

  /// The same swipe as [swipeToPage], but for a page carrying a real photo card: its
  /// AuthImage's placeholder spinner animates indefinitely against an unresolvable network
  /// host, which never lets pumpAndSettle's "no frames scheduled" condition become true - the
  /// same reason photo_viewer_test.dart pumps a bounded number of fixed-duration frames
  /// instead.
  Future<void> swipeToPageWithMedia(WidgetTester tester, Finder pageView, int index) async {
    for (var i = 0; i < index; i++) {
      await tester.drag(pageView, const Offset(-400, 0));
      for (var j = 0; j < 10; j++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
  }

  RecapCard photoCard({required int authorId, required String authorName, int rank = 1}) =>
      RecapCard(
        kind: 'photo',
        rank: rank,
        guaranteed: true,
        postId: authorId,
        authorId: authorId,
        authorName: authorName,
        mediaId: 900 + authorId,
        mime: 'image/jpeg',
      );

  RecapCard quoteCard(
          {required int authorId, required String authorName, String body = 'hi', int rank = 1}) =>
      RecapCard(
        kind: 'quote',
        rank: rank,
        guaranteed: true,
        postId: authorId,
        authorId: authorId,
        authorName: authorName,
        body: body,
      );

  RecapCard clipCard({
    required int authorId,
    required String authorName,
    int rank = 1,
    bool hasPoster = true,
    int durationMs = 8000,
  }) =>
      RecapCard(
        kind: 'clip',
        rank: rank,
        guaranteed: true,
        postId: authorId,
        authorId: authorId,
        authorName: authorName,
        mediaId: 900 + authorId,
        mime: 'video/mp4',
        durationMs: durationMs,
        hasPoster: hasPoster,
      );

  RecapAward award(
          {required String id,
          required String label,
          required int userId,
          required String userName}) =>
      RecapAward(id: id, label: label, userId: userId, userName: userName, value: '9 likes');

  RecapStats stats() =>
      RecapStats(posts: 5, photos: 2, clips: 0, likes: 10, comments: 3, places: 2, members: 3);

  testWidgets('the cover page is always page 0, ahead of every panel', (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [quoteCard(authorId: 1, authorName: 'Ada')]),
      ],
    );
    await pumpDeck(tester, recap);

    // The stats line is on the cover, visible without swiping - and the Wall's own content
    // ("The Wall" panel title, "Ada") is not, because it sits on the page after it. The
    // group name is deliberately absent (see the dedicated test below) - it now lives only
    // in the post card's header, not duplicated onto the cover.
    expect(find.textContaining('check-ins'), findsOneWidget);
    expect(find.text('The Wall'), findsNothing);
    expect(find.text('Ada'), findsNothing);
  });

  testWidgets('the cover does not repeat the group name - that lives in the post header now',
      (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [quoteCard(authorId: 1, authorName: 'Ada')]),
      ],
    );
    await pumpDeck(tester, recap);
    expect(find.text('Ridgeway Family'), findsNothing);
  });

  testWidgets('the cover eyebrow reflects cadence, and the period label is shown too',
      (tester) async {
    final weekly = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [quoteCard(authorId: 1, authorName: 'Ada')]),
      ],
    );
    await pumpDeck(tester, weekly);
    expect(find.text('WEEKLY RECAP'), findsOneWidget);
    expect(find.text('Aug 10-16'), findsOneWidget);
  });

  testWidgets('the cover renders without a hero photo when the Wall\'s #1 pick has none',
      (tester) async {
    // A quote card (no attachment) as the guaranteed #1 pick - the cover must still render
    // (tinted background, no backdrop image) rather than crashing on a null media.
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'monthly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [
          quoteCard(authorId: 1, authorName: 'Ada', body: 'Rainy Tuesday.'),
        ]),
      ],
    );
    await pumpDeck(tester, recap);

    expect(tester.takeException(), isNull);
    expect(find.text('MONTHLY RECAP'), findsOneWidget);
    expect(find.text('Aug 10-16'), findsOneWidget);
  });

  testWidgets('the cover shows a hero backdrop when the Wall\'s #1 pick has a photo',
      (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [
          photoCard(authorId: 1, authorName: 'Ada'),
          quoteCard(authorId: 2, authorName: 'Ben', rank: 2),
        ]),
      ],
    );
    await pumpDeck(tester, recap);

    expect(tester.takeException(), isNull);
    // ImageFiltered wraps the blurred hero backdrop - present only when there is one to show.
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  /// The cover used to blend the group accent into its own background, which no other page
  /// did, so swiping off it read as the card changing colour underneath you. The accent
  /// belongs on the card's border and the RECAP pill, not washed across one page's surface.
  testWidgets('the cover shares the wall pages background, no accent wash', (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [
          photoCard(authorId: 1, authorName: 'Ada'),
        ]),
      ],
    );
    await pumpDeck(tester, recap);

    // A page's own surface fill: a flat colour with no gradient and no rounding, which
    // skips the RECAP pill (rounded) and the scrim above the backdrop (a gradient).
    final surfaceFill = find.byWidgetPredicate((w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color != null &&
        (w.decoration as BoxDecoration).gradient == null &&
        (w.decoration as BoxDecoration).borderRadius == null);

    Color colorOf(Finder f) =>
        ((tester.widget<DecoratedBox>(f).decoration) as BoxDecoration).color!;

    final coverColor = colorOf(find
        .descendant(of: find.byKey(const ValueKey('recap-cover-1')), matching: surfaceFill)
        .first);

    final pageView = find.byType(PageView);
    await swipeToPageWithMedia(tester, pageView, 1);
    final wallColor =
        colorOf(find.ancestor(of: find.byType(GridView), matching: surfaceFill).first);

    expect(coverColor, wallColor,
        reason: 'the cover must not tint its surface with the group accent');
  });

  RecapPayload payloadWithPeople(List<RecapPerson> people) => RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [quoteCard(authorId: 1, authorName: 'Ada')]),
        ],
        people: people,
      );

  /// The top-left of every avatar bubble currently on screen, in the order [find.byType]
  /// resolves them - used to compare a cluster's layout across two separate builds.
  List<Offset> bubblePositions(WidgetTester tester) {
    final finder = find.byType(UserAvatar);
    final count = finder.evaluate().length;
    return [for (var i = 0; i < count; i++) tester.getTopLeft(finder.at(i))];
  }

  testWidgets('the cover renders an avatar bubble per poster, sized by their post count',
      (tester) async {
    final recap = payloadWithPeople([
      RecapPerson(userId: 1, name: 'Ada', posts: 6),
      RecapPerson(userId: 2, name: 'Ben', posts: 3),
      RecapPerson(userId: 3, name: 'Cy', posts: 1),
    ]);
    await pumpDeck(tester, recap);

    expect(tester.takeException(), isNull);
    expect(find.byType(UserAvatar), findsNWidgets(3));
    final sizes = tester.widgetList<UserAvatar>(find.byType(UserAvatar)).map((w) => w.size).toSet();
    expect(sizes.length, greaterThan(1),
        reason: 'the top contributor (6 posts) must render a visibly bigger bubble than the '
            'others (3, 1 posts) - equal sizes would mean the metric was never applied');
  });

  testWidgets('a payload recorded before People existed falls back to no bubble cluster',
      (tester) async {
    // No `people:` given - RecapPayload's default is the empty list, exactly what
    // RecapPayload.fromJson produces when a stored payload predates this field.
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [quoteCard(authorId: 1, authorName: 'Ada')]),
      ],
    );
    await pumpDeck(tester, recap);

    // Must not throw - in particular, _BubbleCluster's empty-list guard must still be in
    // place, or reading `.first` off an empty shown-list below would.
    expect(tester.takeException(), isNull);
    expect(find.byType(UserAvatar), findsNothing);
  });

  testWidgets('posters past the cap collapse into a single "+N" overflow bubble', (tester) async {
    final recap = payloadWithPeople([
      for (var i = 1; i <= 10; i++) RecapPerson(userId: i, name: 'Member $i', posts: 11 - i),
    ]);
    await pumpDeck(tester, recap);

    expect(tester.takeException(), isNull);
    // 10 posters, cap 7: 7 avatar bubbles plus one "+3" overflow bubble for the rest.
    expect(find.byType(UserAvatar), findsNWidgets(7));
    expect(find.text('+3'), findsOneWidget);
  });

  testWidgets(
      'the bubble cluster lays out identically across two separate builds of the '
      'same recap', (tester) async {
    final recap = payloadWithPeople([
      RecapPerson(userId: 1, name: 'Ada', posts: 6),
      RecapPerson(userId: 2, name: 'Ben', posts: 4),
      RecapPerson(userId: 3, name: 'Cy', posts: 3),
      RecapPerson(userId: 4, name: 'Dee', posts: 1),
    ]);

    await pumpDeck(tester, recap, postId: 42);
    final first = bubblePositions(tester);
    expect(first, isNotEmpty);

    // A fresh pumpWidget tears down and rebuilds the whole tree - a brand new
    // _BubbleCluster.build() call, not merely a repaint of the same instance - so this
    // actually exercises whether the layout's seed is deterministic rather than cached.
    await pumpDeck(tester, recap, postId: 42);
    final second = bubblePositions(tester);

    expect(second, first,
        reason: 'the same recap (same postId, same people) must pack into the exact same '
            'positions every time - an unseeded math.Random() in the packer would fail this');
  });

  testWidgets(
      'Wall panel renders cards with the author name overlaid, after swiping past the cover - '
      'and never renders its own panel title (round 5: the founder called it redundant)',
      (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [
          quoteCard(authorId: 1, authorName: 'Ada', body: 'Made it to the top, barely.'),
          quoteCard(authorId: 2, authorName: 'Ben', body: 'Rainy Tuesday.', rank: 2),
        ]),
      ],
    );
    await pumpDeck(tester, recap);
    await swipeToPage(tester, find.byType(PageView), 1);

    // The panel title stays on the model (fed into RecapCollagePanel above) for a server
    // that still expects to read it back unchanged - it just must never reach the screen.
    expect(find.text('The Wall'), findsNothing);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Ben'), findsOneWidget);
    expect(find.text('Made it to the top, barely.'), findsOneWidget);
  });

  testWidgets(
      'Awards panel renders every award with its label and winner, after swiping past the cover - '
      'an already-published (pre-retirement) deck still renders exactly as before', (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapAwardsPanel(title: 'Awards Night', awards: [
          award(id: 'most_liked', label: 'Most Loved', userId: 1, userName: 'Ada'),
          award(id: 'night_owl', label: 'Night Owl', userId: 2, userName: 'Ben'),
        ]),
      ],
    );
    await pumpDeck(tester, recap);
    await swipeToPage(tester, find.byType(PageView), 1);

    expect(find.text('Awards Night'), findsOneWidget);
    expect(find.text('Most Loved'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Night Owl'), findsOneWidget);
    expect(find.text('Ben'), findsOneWidget);
    expect(find.text('9 likes'), findsNWidgets(2));
  });

  testWidgets('the deck holds one page per panel plus the cover page', (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [quoteCard(authorId: 1, authorName: 'Ada')]),
        RecapAwardsPanel(title: 'Awards Night', awards: [
          award(id: 'most_liked', label: 'Most Loved', userId: 1, userName: 'Ada'),
        ]),
      ],
    );
    await pumpDeck(tester, recap);

    expect(find.byType(PageView), findsOneWidget);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect((pageView.childrenDelegate as SliverChildBuilderDelegate).estimatedChildCount, 3);
  });

  testWidgets('an unrecognised panel type is dropped by parsing, not rendering', (tester) async {
    // Exercises the actual forward-compat contract: Post.fromJson/RecapPayload.fromJson
    // silently skip a panel type this client doesn't know (see RecapPanel.tryParse), so a
    // v1.5+ server can add new panels without this build ever seeing them, let alone
    // throwing on them.
    final json = {
      'period': {'label': 'Aug 10-16', 'cadence': 'weekly'},
      'group': {'name': 'Ridgeway Family', 'color': 'coral'},
      'stats': {
        'posts': 5,
        'photos': 2,
        'clips': 0,
        'likes': 10,
        'comments': 3,
        'places': 2,
        'members': 3
      },
      'panels': [
        {
          'type': 'map', // v1.5, unknown to this build
          'title': 'Where We Were',
          'bounds': {'minLat': 0, 'maxLat': 1, 'minLng': 0, 'maxLng': 1},
        },
        {
          'type': 'awards',
          'title': 'Awards Night',
          'awards': [
            {
              'id': 'most_liked',
              'label': 'Most Loved',
              'userId': 1,
              'userName': 'Ada',
              'value': '9 likes'
            },
          ],
        },
      ],
    };
    final recap = RecapPayload.fromJson(json);

    expect(recap.panels, hasLength(1),
        reason: 'the unknown "map" panel must be dropped, not crash parsing');
    expect(recap.panels.single, isA<RecapAwardsPanel>());

    await pumpDeck(tester, recap);
    await swipeToPage(tester, find.byType(PageView), 1);
    expect(tester.takeException(), isNull);
    expect(find.text('Awards Night'), findsOneWidget);
  });

  testWidgets(
      'a payload with zero recognised panels falls back to a stats summary without throwing',
      (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: const [], // every panel this payload had was unrecognised
    );
    await pumpDeck(tester, recap);

    expect(tester.takeException(), isNull);
    expect(find.byType(PageView), findsNothing);
    expect(find.textContaining('check-ins'), findsOneWidget);
  });

  testWidgets(
      'a photo/clip card with no attached media renders a removed-tile placeholder, not a crash',
      (tester) async {
    // A recap's payload is a frozen snapshot; if the underlying post is later deleted, its
    // media id can outlive the file it named (0018_recap.sql). This constructs that shape
    // directly - kind: 'photo' but no mediaId - the way a real "attachment gone" card would
    // look once the network 404 is already known, without needing a live network call.
    final card = RecapCard(
      kind: 'photo',
      rank: 1,
      guaranteed: true,
      postId: 1,
      authorId: 1,
      authorName: 'Ada',
    );
    expect(card.media, isNull);

    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [card]),
      ],
    );
    await pumpDeck(tester, recap);
    await swipeToPage(tester, find.byType(PageView), 1);

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
  });

  group('tapping a Wall card', () {
    // Matches the fake API's post below, so PostDetailScreen (wherever it's reached from)
    // loads real, recognisable content instead of an error state.
    final post = Post(
      id: 5,
      authorId: 1,
      authorName: 'Ada',
      kind: 'image',
      body: 'movie night',
      createdAt: DateTime(2026, 1, 1),
      likeCount: 0,
      commentCount: 0,
      likedByViewer: false,
      groupId: 'alpha.invalid',
    );
    final apiOverride = contentApiProvider('alpha.invalid').overrideWithValue(_FakeApi(post: post));

    testWidgets('with a photo pushes the full-screen viewer, not the post directly',
        (tester) async {
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [photoCard(authorId: 5, authorName: 'Ada')]),
        ],
      );
      await pumpDeck(tester, recap, overrides: [apiOverride]);
      await swipeToPageWithMedia(tester, find.byType(PageView), 1);

      await tester.tap(find.byType(ClipRRect).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(PhotoViewerScreen), findsOneWidget);
      expect(find.byType(PostDetailScreen), findsNothing);
    });

    testWidgets('with a quote pushes the post directly - there is nothing to show full screen',
        (tester) async {
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(
              title: 'The Wall',
              cards: [quoteCard(authorId: 5, authorName: 'Ada', body: 'Rainy Tuesday.')]),
        ],
      );
      await pumpDeck(tester, recap, overrides: [apiOverride]);
      await swipeToPage(tester, find.byType(PageView), 1);

      await tester.tap(find.byType(ClipRRect).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(PhotoViewerScreen), findsNothing);
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(tester.widget<PostDetailScreen>(find.byType(PostDetailScreen)).postId, 5);
      expect(find.text('movie night'), findsOneWidget);
    });

    testWidgets('with removed media pushes the post, not a broken viewer', (tester) async {
      // Same frozen-payload shape as the removed-tile placeholder test above: kind 'photo',
      // no mediaId - the attachment is gone, but the post itself (postId) might still exist.
      final card = RecapCard(
        kind: 'photo',
        rank: 1,
        guaranteed: true,
        postId: 5,
        authorId: 1,
        authorName: 'Ada',
      );
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [card])
        ],
      );
      await pumpDeck(tester, recap, overrides: [apiOverride]);
      await swipeToPage(tester, find.byType(PageView), 1);

      await tester.tap(find.byType(ClipRRect).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(PhotoViewerScreen), findsNothing);
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(tester.widget<PostDetailScreen>(find.byType(PostDetailScreen)).postId, 5);
    });

    testWidgets(
        'the viewer\'s "Go to post" button pushes PostDetailScreen with the card\'s own '
        'postId and the deck\'s groupId', (tester) async {
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [photoCard(authorId: 5, authorName: 'Ada')]),
        ],
      );
      await pumpDeck(tester, recap, overrides: [apiOverride]);
      await swipeToPageWithMedia(tester, find.byType(PageView), 1);

      await tester.tap(find.byType(ClipRRect).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(PhotoViewerScreen), findsOneWidget);

      await tester.tap(find.text('Go to post'));
      // A bounded pump loop, not a single fixed duration: the popped viewer's own exit
      // transition (its PageRouteBuilder's 180ms) has to fully finish - not just start -
      // before it actually leaves the tree, on top of the pushed PostDetailScreen's own
      // route settling in.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(PhotoViewerScreen), findsNothing);
      expect(find.byType(PostDetailScreen), findsOneWidget);
      final screen = tester.widget<PostDetailScreen>(find.byType(PostDetailScreen));
      expect(screen.postId, 5);
      expect(screen.groupId, 'alpha.invalid');
      expect(find.text('movie night'), findsOneWidget);
    });
  });

  // The server does support video clips on the Wall (kind: "clip" for a video/* mime, with
  // durationMs/hasPoster carried through - see recap_select.go's candidateToCard), and both
  // the tile and the round-5 cover montage render a clip's media through the same MediaFrame
  // every photo goes through. Before this group, not one fixture in this file ever used a
  // clip card - the video path was correct but entirely unprotected: swapping MediaFrame for
  // AuthImage in either place would make an mp4 silently fail to decode, and nothing here
  // would have failed.
  group('Wall clip cards', () {
    // Matches the fake API's post below, so PostDetailScreen loads real, recognisable
    // content instead of an error state.
    final post = Post(
      id: 5,
      authorId: 1,
      authorName: 'Ada',
      kind: 'video',
      body: 'movie night',
      createdAt: DateTime(2026, 1, 1),
      likeCount: 0,
      commentCount: 0,
      likedByViewer: false,
      groupId: 'alpha.invalid',
    );
    final apiOverride = contentApiProvider('alpha.invalid').overrideWithValue(_FakeApi(post: post));

    testWidgets(
        'a clip tile renders through ClipPoster: play badge, duration pill, no video player',
        (tester) async {
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [clipCard(authorId: 5, authorName: 'Ada')]),
        ],
      );
      await pumpDeck(tester, recap);
      await swipeToPageWithMedia(tester, find.byType(PageView), 1);

      expect(tester.takeException(), isNull);
      // The Wall is deliberately poster-only - the feed's single-live-player rule
      // (feed_autoplay.dart) is exactly why nothing here may ever build a real decoder.
      expect(find.byType(ClipPoster), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.byType(FeedClip), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('0:08'), findsOneWidget); // clipCard's default durationMs is 8000
    });

    testWidgets('a poster-less clip degrades cleanly in the tile - no crash, no blank hole',
        (tester) async {
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [
            clipCard(authorId: 5, authorName: 'Ada', hasPoster: false),
          ]),
        ],
      );
      await pumpDeck(tester, recap);
      await swipeToPage(tester, find.byType(PageView), 1);

      expect(tester.takeException(), isNull);
      // ClipPoster's own no-poster fallback (a flat backdrop under the badge) rather than a
      // broken-image icon or a blank hole where the tile should be.
      expect(find.byType(ClipPoster), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    });

    testWidgets('a clip card in the cover montage renders through ClipPoster, not a raw mp4 decode',
        (tester) async {
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [clipCard(authorId: 5, authorName: 'Ada')]),
        ],
      );
      await pumpDeck(tester, recap); // page 0 is the cover - no swipe needed

      expect(tester.takeException(), isNull);
      // The exact assertion that catches a MediaFrame -> AuthImage swap in the montage: a
      // raw AuthImage pointed straight at an mp4's own bytes would never decode, and
      // ClipPoster - the poster-only path MediaFrame actually resolves a clip to - simply
      // would not be there.
      expect(find.byType(ClipPoster), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
    });

    testWidgets('a poster-less clip in the cover montage degrades cleanly too', (tester) async {
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [
            clipCard(authorId: 5, authorName: 'Ada', hasPoster: false),
          ]),
        ],
      );
      await pumpDeck(tester, recap);

      expect(tester.takeException(), isNull);
      expect(find.byType(ClipPoster), findsOneWidget);
    });

    testWidgets(
        'tapping a clip card opens the viewer with the clip\'s own media, and "Go to post" '
        'still carries the right postId', (tester) async {
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [
          RecapCollagePanel(title: 'The Wall', cards: [clipCard(authorId: 5, authorName: 'Ada')]),
        ],
      );
      await pumpDeck(tester, recap, overrides: [apiOverride]);
      await swipeToPageWithMedia(tester, find.byType(PageView), 1);

      await tester.tap(find.byType(ClipRRect).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(PhotoViewerScreen), findsOneWidget);
      final viewer = tester.widget<PhotoViewerScreen>(find.byType(PhotoViewerScreen));
      expect(viewer.media, hasLength(1));
      expect(viewer.media.single.isVideo, isTrue,
          reason: 'a clip card must open the viewer on its own clip, not fall through to '
              'the photo/quote path');
      expect(viewer.postId, 5);

      await tester.tap(find.text('Go to post'));
      // A bounded pump loop, not a single fixed duration - see the identical photo-card
      // test above for why.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(PhotoViewerScreen), findsNothing);
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(tester.widget<PostDetailScreen>(find.byType(PostDetailScreen)).postId, 5);
    });

    testWidgets('a mixed Wall (photos, clips, a quote) paginates and stays reachable',
        (tester) async {
      final cards = [
        photoCard(authorId: 1, authorName: 'Ada', rank: 1),
        clipCard(authorId: 2, authorName: 'Ben', rank: 2),
        quoteCard(authorId: 3, authorName: 'Cy', body: 'Rainy Tuesday.', rank: 3),
        clipCard(authorId: 4, authorName: 'Dee', rank: 4, hasPoster: false),
        photoCard(authorId: 5, authorName: 'Eve', rank: 5),
      ];
      final recap = RecapPayload(
        periodLabel: 'Aug 10-16',
        cadence: 'weekly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [RecapCollagePanel(title: 'The Wall', cards: cards)],
      );
      await pumpDeck(tester, recap);

      // 5 cards at 4/page -> page 1 gets Ada/Ben/Cy/Dee (a photo, a clip, a quote, and
      // another clip), page 2 gets Eve alone - 3 pages total with the cover. Unlike the
      // existing all-quote-card pagination tests, this actually carries clips (and a photo)
      // through the chunker, so chunking isn't inadvertently photo-only.
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect((pageView.childrenDelegate as SliverChildBuilderDelegate).estimatedChildCount, 3);

      await swipeToPageWithMedia(tester, find.byType(PageView), 1);
      expect(tester.takeException(), isNull);
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('Cy'), findsOneWidget);
      expect(find.text('Rainy Tuesday.'), findsOneWidget);
      expect(find.text('Dee'), findsOneWidget);

      await swipeToPageWithMedia(tester, find.byType(PageView), 1);
      expect(tester.takeException(), isNull);
      expect(find.text('Eve'), findsOneWidget);
    });
  });

  testWidgets('renders inside a real ListView (regression class: unbounded-height blank cards)',
      (tester) async {
    final recap = RecapPayload(
      periodLabel: 'Aug 10-16',
      cadence: 'weekly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [
        RecapCollagePanel(title: 'The Wall', cards: [quoteCard(authorId: 1, authorName: 'Ada')]),
      ],
    );
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    // Tall enough that both decks (each ~250-350px, per the 4:3 aspect ratio at this
    // width) sit inside the default cache extent - otherwise the second is never built,
    // which would make this a test of the viewport, not of the layout.
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            SizedBox(width: 340, child: RecapDeck(recap: recap, groupId: account.id, postId: 1)),
            SizedBox(width: 340, child: RecapDeck(recap: recap, groupId: account.id, postId: 2)),
          ]),
        ),
      ),
    ));
    await tester.pump();
    disposeCoverAfterTest(tester);
    await swipeToPage(tester, find.byType(PageView).at(0), 1);
    await swipeToPage(tester, find.byType(PageView).at(1), 1);

    expect(tester.takeException(), isNull);
    expect(find.text('Ada'), findsNWidgets(2));
  });

  /// The founder-reported round-3 regression: the Wall's grid overflowed a single deck page,
  /// so with 4 cards only the top row was ever visible - the bottom row was clipped,
  /// unreachable, no scroll. The fix chunks the collage across its own deck pages (see
  /// RecapDeckState._buildPages) instead of overflowing one; these run it at every card
  /// count from 1 up to the monthly cap (20) and confirm every single card is reachable by
  /// swiping, with nothing throwing (no RenderFlex overflow) along the way.
  for (final n in [1, 2, 4, 5, 9, 20]) {
    testWidgets(
        'the Wall paginates across deck pages instead of clipping: $n card(s), every card '
        'reachable by swiping, nothing overflows', (tester) async {
      final cards = [
        for (var i = 1; i <= n; i++) quoteCard(authorId: i, authorName: 'Member $i', rank: i),
      ];
      final recap = RecapPayload(
        periodLabel: 'August 2026',
        cadence: 'monthly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [RecapCollagePanel(title: 'The Wall', cards: cards)],
      );
      await pumpDeck(tester, recap);
      expect(tester.takeException(), isNull);

      // The chunk size (4 cards/page) is load-bearing here, not incidental: reverting to a
      // single grid page per panel would make this itemCount 2 (cover + one Wall page)
      // regardless of n, failing this assertion for every n above 4.
      final wallPages = (n / 4).ceil();
      final totalPages = wallPages + 1;
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect((pageView.childrenDelegate as SliverChildBuilderDelegate).estimatedChildCount,
          totalPages);

      // Swipe through every page one at a time - the same gesture a real viewer uses -
      // asserting no exception (in particular no RenderFlex overflow) at each stop.
      for (var i = 1; i < totalPages; i++) {
        await tester.drag(find.byType(PageView), const Offset(-400, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'page $i of $totalPages must render without overflow/clipping ($n cards)');
      }

      // The deck's very last card must be reachable, not silently clipped off behind an
      // unreachable second grid row - the exact bug the founder hit.
      expect(find.text('Member $n'), findsOneWidget);
    });
  }

  /// Pins tile geometry, not just the absence of overflow - the gap that let the round-3
  /// clipping regression ship in the first place, and the same gap an earlier version of
  /// this very fix fell into: a single-row layout technically never clips, but it slices 4
  /// tiles sharing one page's full height into a roughly 1:3 sliver, unrecognisable as a
  /// photo. The Wall's tiles are a fixed-aspect 2x2 grid regardless of how many cards are on
  /// the page (1 to [_wallCardsPerPage]), so every tile at every count should land in the
  /// same sane portrait/landscape band.
  for (final n in [1, 2, 3, 4]) {
    testWidgets('the Wall tile aspect stays in a sane band at $n card(s) on a page',
        (tester) async {
      final cards = [for (var i = 1; i <= n; i++) quoteCard(authorId: i, authorName: 'Member $i')];
      final recap = RecapPayload(
        periodLabel: 'August 2026',
        cadence: 'monthly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [RecapCollagePanel(title: 'The Wall', cards: cards)],
      );
      await pumpDeck(tester, recap);
      await swipeToPage(tester, find.byType(PageView), 1);
      expect(tester.takeException(), isNull);

      // Every Wall tile's outer ClipRRect - nothing else in the deck uses one - so this
      // measures the tile's actual on-screen shape rather than trusting the GridView
      // delegate's childAspectRatio parameter at face value.
      final tiles = find.byType(ClipRRect);
      expect(tiles, findsNWidgets(n));
      for (var i = 0; i < n; i++) {
        final size = tester.getSize(tiles.at(i));
        final aspect = size.width / size.height;
        expect(aspect, inInclusiveRange(0.6, 1.4),
            reason: 'tile $i of $n rendered at $size (aspect ${aspect.toStringAsFixed(2)}) - '
                'outside the band a recognisable photo needs');
      }
    });
  }

  /// Pumps the deck at an explicit width and text scale - unlike [pumpDeck]'s fixed 340px,
  /// used for the clipping-under-text-scale tests below, which specifically need this app's
  /// narrowest supported width (320dp) and a scale beyond the platform default (this app
  /// never clamps textScaler - see _deckAspectRatio's doc comment).
  Future<void> pumpDeckScaled(WidgetTester tester, RecapPayload recap,
      {required double width, required double textScale}) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                  width: width, child: RecapDeck(recap: recap, groupId: account.id, postId: 1)),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    disposeCoverAfterTest(tester);
  }

  /// The gap the tile-aspect-band test above cannot see: tile size comes from the grid
  /// delegate and is blind to whether its ancestor can actually paint it. 4:5 (an earlier
  /// value tried for _deckAspectRatio) passed that aspect test cleanly while still clipping
  /// the second row's tiles by several px at 1.3x text scale on a 320dp-wide device - an
  /// ordinary accessibility setting this app never clamps against. These assert on each
  /// tile's actual painted bounds against the page's own bounds instead, at the platform
  /// default scale and two accessibility scales beyond it.
  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets(
        "the Wall's second row is never clipped at textScaler ${scale}x on a 320dp-wide "
        'device', (tester) async {
      final cards = [for (var i = 1; i <= 4; i++) quoteCard(authorId: i, authorName: 'Member $i')];
      final recap = RecapPayload(
        periodLabel: 'August 2026',
        cadence: 'monthly',
        groupName: 'Ridgeway Family',
        groupColor: 'coral',
        stats: stats(),
        panels: [RecapCollagePanel(title: 'The Wall', cards: cards)],
      );
      await pumpDeckScaled(tester, recap, width: 320, textScale: scale);
      await swipeToPage(tester, find.byType(PageView), 1);
      expect(tester.takeException(), isNull);

      // The page's own outer bound - what a viewer's eye treats as "the card" - against
      // each tile's actual painted rect. A tile whose bottom edge falls past the page's own
      // is clipped by the PageView/GridView's own Viewport, however clean its "logical"
      // aspect ratio (measured by the test above) looked.
      final pageRect = tester.getRect(find.byType(AspectRatio));
      final tiles = find.byType(ClipRRect);
      expect(tiles, findsNWidgets(4));
      for (var i = 0; i < 4; i++) {
        final tileRect = tester.getRect(tiles.at(i));
        expect(tileRect.bottom, lessThanOrEqualTo(pageRect.bottom),
            reason: 'tile $i bottom ${tileRect.bottom} exceeds the page bottom '
                '${pageRect.bottom} at ${scale}x text scale - clipped by '
                '${tileRect.bottom - pageRect.bottom}px');
      }
    });
  }

  testWidgets('no Wall page ever renders the panel title, on any chunk', (tester) async {
    // 5 cards -> 2 wall pages at 4/page. Neither page renders "The Wall" (round 5): the
    // title is gone entirely, not just deduplicated across chunks - the vertical space it
    // used to take is exactly what let _deckAspectRatio shrink.
    final cards = [for (var i = 1; i <= 5; i++) quoteCard(authorId: i, authorName: 'Member $i')];
    final recap = RecapPayload(
      periodLabel: 'August 2026',
      cadence: 'monthly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [RecapCollagePanel(title: 'The Wall', cards: cards)],
    );
    await pumpDeck(tester, recap);
    await swipeToPage(tester, find.byType(PageView), 1);
    expect(find.text('The Wall'), findsNothing);

    await swipeToPage(tester, find.byType(PageView), 1);
    expect(find.text('The Wall'), findsNothing);
  });

  testWidgets('the page-dot row compresses to a bounded window once page count is large',
      (tester) async {
    // Only reachable with an oversized group: collageCardCap's memberCount floor can push
    // the Wall's card cap (and so its page count) well past the 20-card monthly default -
    // here 36 members forces a 36-card cap, 9 wall pages, 10 pages total with the cover.
    final cards = [for (var i = 1; i <= 36; i++) quoteCard(authorId: i, authorName: 'Member $i')];
    final recap = RecapPayload(
      periodLabel: 'August 2026',
      cadence: 'monthly',
      groupName: 'Ridgeway Family',
      groupColor: 'coral',
      stats: stats(),
      panels: [RecapCollagePanel(title: 'The Wall', cards: cards)],
    );
    await pumpDeck(tester, recap);
    expect(tester.takeException(), isNull);

    // Every dot the row renders is a Container with an explicit 6px height (the inactive
    // dot's own height - the active one shares it too, just a wider width) - a marker no
    // other widget in the tree sets, so counting them is a direct read of how many dots are
    // actually on screen. 10 pages total (cover + 9 wall pages) is past the row's
    // uncompressed ceiling (9): it must render its bounded 7-dot window, not one dot per
    // page, or the row risks overflowing outright.
    final dots = find.byWidgetPredicate((w) => w is Container && w.constraints?.maxHeight == 6.0);
    expect(dots, findsNWidgets(7),
        reason: 'past the uncompressed ceiling the row must show its bounded window, not one '
            'dot per page');

    // Swipe to the last page and confirm it's still reachable without overflow, which is
    // what actually matters - the dot row degrading gracefully must never come at the cost
    // of a page becoming unreachable.
    for (var i = 0; i < 9; i++) {
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(find.text('Member 36'), findsOneWidget);
  });

  group('cover animation (round 5)', () {
    RecapPayload animatedRecap() => RecapPayload(
          periodLabel: 'Aug 10-16',
          cadence: 'weekly',
          groupName: 'Ridgeway Family',
          groupColor: 'coral',
          stats: stats(),
          panels: [
            RecapCollagePanel(title: 'The Wall', cards: [
              photoCard(authorId: 1, authorName: 'Ada'),
              photoCard(authorId: 2, authorName: 'Ben', rank: 2),
            ]),
          ],
          people: [
            RecapPerson(userId: 1, name: 'Ada', posts: 4),
            RecapPerson(userId: 2, name: 'Ben', posts: 2),
          ],
        );

    // People-only, no photo cards - the bubble float is what this needs; a photo card's
    // MediaFrame would pull in a real CachedNetworkImage, whose own indeterminate loading
    // spinner (against this test's unresolvable host) ticks forever on its own account and
    // would contaminate a transientCallbackCount reading with an animation that has nothing
    // to do with the cover's own lifecycle. RecapPerson has no photoId here either, so
    // UserAvatar renders plain initials - no network image anywhere in this tree.
    RecapPayload bubbleOnlyRecap() => RecapPayload(
          periodLabel: 'Aug 10-16',
          cadence: 'weekly',
          groupName: 'Ridgeway Family',
          groupColor: 'coral',
          stats: stats(),
          panels: [
            RecapCollagePanel(
                title: 'The Wall', cards: [quoteCard(authorId: 1, authorName: 'Ada')]),
          ],
          people: [
            RecapPerson(userId: 1, name: 'Ada', posts: 4),
            RecapPerson(userId: 2, name: 'Ben', posts: 2),
          ],
        );

    testWidgets(
        'reduced motion renders the static final state: no crossfade layer and no bubble '
        'drift, even once real time has passed', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(
              () => MultiSessionController.seeded(MultiSession(groups: [account], restored: true))),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                    width: 340,
                    child: RecapDeck(recap: animatedRecap(), groupId: account.id, postId: 1)),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      disposeCoverAfterTest(tester);

      final before = bubblePositions(tester);
      expect(before, isNotEmpty);
      // Only ever one backdrop layer at rest - a second (the crossfade partner) only exists
      // mid-transition, which reduced motion must never enter.
      expect(find.byType(ImageFiltered), findsOneWidget);

      // 5s would land well inside a crossfade window (each photo's segment is 6s, the last
      // ~28% of it spent fading) if the cycle were running at all - the exact instant that
      // would fail this assertion were the reduced-motion guard missing.
      await tester.pump(const Duration(seconds: 5));

      expect(tester.takeException(), isNull);
      expect(find.byType(ImageFiltered), findsOneWidget,
          reason: 'reduced motion must never start the backdrop crossfade');
      expect(bubblePositions(tester), before,
          reason: 'reduced motion must never start the bubble float - position at rest must '
              'be frame-invariant over time');
    });

    testWidgets('the backdrop montage advances over time once the cover is actually visible',
        (tester) async {
      await pumpDeck(tester, animatedRecap());

      // Settle the visibility gate (the 200ms debounce in _RecapCoverPageState) so the cycle
      // actually starts - a bare pump() never waits this out.
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(ImageFiltered), findsOneWidget,
          reason: 'still mid-segment, no crossfade partner yet');

      // Each photo's 6s segment starts crossfading to the next at 72% (4.32s) in - 5s total
      // (250ms already spent settling, 4.75s more here) lands inside that window.
      await tester.pump(const Duration(milliseconds: 4750));

      expect(tester.takeException(), isNull);
      expect(find.byType(ImageFiltered), findsNWidgets(2),
          reason: 'two photos should be layered mid-crossfade - the montage never advanced '
              'if this is still one');
    });

    testWidgets(
        'controllers stop ticking when visibility drops (not just avoid throwing) and are '
        'disposed when the widget is disposed - no leaked ticker either way', (tester) async {
      final controller =
          MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
      final hidden = ValueNotifier<bool>(false);
      addTearDown(hidden.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [multiSessionProvider.overrideWith(() => controller)],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: _OffstageToggle(
                hidden: hidden,
                child: SizedBox(
                    width: 340,
                    child: RecapDeck(recap: bubbleOnlyRecap(), groupId: account.id, postId: 1)),
              ),
            ),
          ),
        ),
      ));

      // Let visibility settle true, then run well past the bubble entrance's own bounded
      // 700ms so only the continuous float/backdrop cycle - the ones actually gated on
      // visibility - are what's left ticking for the rest of this test.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 600));
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0),
          reason: 'the backdrop cycle / bubble float should be ticking while on screen');

      hidden.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'going offscreen must actually stop the ticking animations, not merely '
              'avoid throwing while they keep running unseen');

      hidden.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0),
          reason: 'coming back on screen must resume the animation');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
      expect(SchedulerBinding.instance.transientCallbackCount, 0,
          reason: 'disposing the widget must not leave a ticker running behind it');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the float never perturbs the underlying packing: bubble positions return to the '
        'exact same values one full float period later', (tester) async {
      await pumpDeck(tester, bubbleOnlyRecap(), postId: 42);
      // Settles visibility and starts the float.
      await tester.pump(const Duration(milliseconds: 250));

      // An arbitrary, off-boundary instant into the float's timeline, not its t=0 rest phase
      // (a bug that reset something at exactly the period wrap could otherwise hide behind
      // a t=0-vs-t=0 comparison) and not the exact period boundary itself either (Ticker's
      // own simulation restarts its underlying curve there, which is precise but not always
      // bit-identical to a plain elapsed-time reading taken mid-cycle).
      await tester.pump(const Duration(seconds: 1));
      final atOneSecond = bubblePositions(tester);
      expect(atOneSecond, isNotEmpty);

      // Proves the float is actually running - otherwise a bug that stopped it dead (frozen
      // from the moment it started) would trivially "pass" the period-return assertion below.
      await tester.pump(const Duration(seconds: 1));
      expect(bubblePositions(tester), isNot(atOneSecond));

      // The float's own AnimationController repeats on a 4s period (_BubbleClusterState's
      // _floatSeconds) - three more seconds lands exactly one full period after the first
      // reading, where a repeating controller's value (and so this sine-based float) returns
      // to exactly where it was. If the packing itself - the [Offset]s _packCircles produced -
      // were being perturbed by anything animation-related, this would not land back on the
      // exact same values; it would drift.
      await tester.pump(const Duration(seconds: 3));
      expect(bubblePositions(tester), atOneSecond,
          reason: 'one full float period later, the same seeded packing plus the same '
              'periodic float phase must land on exactly the same painted positions - '
              'any drift here means the deterministic packing itself is being perturbed');
    });
  });
}

/// Toggles [child] between shown and fully offstage (still mounted, reporting zero visible
/// area) without unmounting it - the harness the animation-lifecycle tests above need to
/// drive [_RecapCoverPageState]'s visibility gate directly, the way a real scroll would,
/// without the flakiness of actually scrolling a real ListView in a widget test.
class _OffstageToggle extends StatefulWidget {
  const _OffstageToggle({required this.hidden, required this.child});

  final ValueNotifier<bool> hidden;
  final Widget child;

  @override
  State<_OffstageToggle> createState() => _OffstageToggleState();
}

class _OffstageToggleState extends State<_OffstageToggle> {
  @override
  void initState() {
    super.initState();
    widget.hidden.addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.hidden.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Offstage(offstage: widget.hidden.value, child: widget.child);
}
