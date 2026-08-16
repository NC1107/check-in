import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/recap_card.dart';
import 'package:checkin/state/app_state.dart';

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

  Future<void> pumpDeck(WidgetTester tester, RecapPayload recap) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        // A phone-width column, like the card the deck actually lives in (post_card.dart's
        // feed-width card). The deck's 4:5 AspectRatio page needs a bounded width to avoid
        // overflowing the test surface's fixed 600-tall viewport.
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 340, child: RecapDeck(recap: recap, groupId: account.id)),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// Swipes a PageView left, one page at a time - what a real viewer does to get past the
  /// cover page (always page 0) to a panel's own content.
  Future<void> swipeToPage(WidgetTester tester, Finder pageView, int index) async {
    for (var i = 0; i < index; i++) {
      await tester.drag(pageView, const Offset(-400, 0));
      await tester.pumpAndSettle();
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

    // The group name and stats line are on the cover, visible without swiping - and the
    // Wall's own content ("The Wall" panel title, "Ada") is not, because it sits on the
    // page after it.
    expect(find.text('Ridgeway Family'), findsOneWidget);
    expect(find.textContaining('check-ins'), findsOneWidget);
    expect(find.text('The Wall'), findsNothing);
    expect(find.text('Ada'), findsNothing);
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
    expect(find.text('Ridgeway Family'), findsOneWidget);
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

  testWidgets(
      'Wall panel renders cards with the author name overlaid, after swiping past the cover',
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

    expect(find.text('The Wall'), findsOneWidget);
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
    // Tall enough that both decks (each ~450-500px, per the 4:5 aspect ratio at this
    // width) sit inside the default cache extent - otherwise the second is never built,
    // which would make this a test of the viewport, not of the layout.
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            SizedBox(width: 340, child: RecapDeck(recap: recap, groupId: account.id)),
            SizedBox(width: 340, child: RecapDeck(recap: recap, groupId: account.id)),
          ]),
        ),
      ),
    ));
    await tester.pump();
    await swipeToPage(tester, find.byType(PageView).at(0), 1);
    await swipeToPage(tester, find.byType(PageView).at(1), 1);

    expect(tester.takeException(), isNull);
    expect(find.text('Ada'), findsNWidgets(2));
  });
}
