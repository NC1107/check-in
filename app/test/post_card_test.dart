import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/post_card.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/theme/group_color.dart';

/// The post card shows a group marker (a colored dot, labelled with the group name for
/// screen readers, plus a left rail) only in the merged feed - i.e. when a groupColor is
/// passed. A single-group view passes null and shows no marker. A plain text post needs no
/// media, so nothing hits the network.
void main() {
  final user = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true);
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: user,
  );
  final post = Post(
    id: 5,
    authorId: 2,
    authorName: 'Ada',
    kind: 'text',
    body: 'hello',
    createdAt: DateTime(2026, 7, 1),
    likeCount: 0,
    commentCount: 0,
    likedByViewer: false,
    groupId: 'alpha.invalid',
  );

  // A recap post's cover reports real visibility through the `visibility_detector` package
  // (see recap_card.dart's _RecapCoverPageState). Zero here means its callbacks fire off a
  // post-frame callback instead of a real Timer - the package's own documented "useful for
  // automated tests" mode.
  setUpAll(() => VisibilityDetectorController.instance.updateInterval = Duration.zero);

  Future<void> pumpCard(WidgetTester tester, {Color? groupColor}) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(home: Scaffold(body: PostCard(post: post, groupColor: groupColor))),
    ));
    await tester.pump();
  }

  /// Same as [pumpCard] but for an arbitrary post - used by the recap-specific tests below,
  /// which need a `kind: 'recap'` post rather than the plain text one above. Scrollable
  /// because a recap card (deck plus header plus stats) is taller than the default 600px
  /// test surface.
  Future<void> pumpPost(WidgetTester tester, Post p) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: PostCard(post: p))),
      ),
    ));
    await tester.pump();
    // A recap post's cover keeps a debounce Timer (and, once visible, ambient
    // AnimationControllers - see recap_card.dart's _RecapCoverPageState and friends) alive
    // for as long as it stays mounted. Neither test below cares about that animation, so
    // this drains it once the test is done: flutter_test's own end-of-test checks (no
    // pending Timer, no still-ticking animation) would otherwise trip on it.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  /// A recap post shaped closely enough to the real wire format for the header/overflow-menu
  /// tests below: one collage panel with a single card, so RecapDeck renders its real deck
  /// (not the panel-less stats fallback).
  Post recapPost() => Post(
        id: 77,
        authorId: 9,
        authorName: 'Ridgeway Family', // the server aliases a recap's authorName to the group
        kind: 'recap',
        body: 'Your recap in Ridgeway Family.',
        createdAt: DateTime(2026, 7, 1),
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        groupId: 'alpha.invalid',
        recap: RecapPayload(
          periodLabel: 'Aug 10-16',
          cadence: 'weekly',
          groupName: 'Ridgeway Family',
          groupColor: 'coral',
          stats: RecapStats(
              posts: 5, photos: 2, clips: 0, likes: 10, comments: 3, places: 2, members: 3),
          panels: [
            RecapCollagePanel(title: 'The Wall', cards: [
              RecapCard(
                kind: 'quote',
                rank: 1,
                guaranteed: true,
                postId: 1,
                authorId: 2,
                authorName: 'Ada',
                body: 'Made it to the top.',
              ),
            ]),
          ],
        ),
      );

  testWidgets('shows the group marker only when a group color is set', (tester) async {
    await pumpCard(tester, groupColor: groupColorById('coral'));
    expect(find.bySemanticsLabel('Group: Alpha'), findsOneWidget);

    await pumpCard(tester, groupColor: null);
    expect(find.bySemanticsLabel('Group: Alpha'), findsNothing);
  });

  testWidgets('renders inside a ListView (regression: stretched rail Row blanked every card)',
      (tester) async {
    // The feed/profile put cards in a ListView, where item height is unbounded. The old
    // rail layout (Row + CrossAxisAlignment.stretch) forced an infinite height there and
    // every card rendered blank in release. Pump in a real list to lock the fix in.
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [multiSessionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            PostCard(post: post, groupColor: groupColorById('coral')),
            PostCard(post: post),
          ]),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Ada'), findsNWidgets(2));
    expect(find.text('hello'), findsNWidgets(2));
  });

  testWidgets('a recap post shows the group name in its header, not repeated on the cover',
      (tester) async {
    await pumpPost(tester, recapPost());

    // The RECAP badge plus the group-name label sit in the header now (see post_card.dart's
    // recapAccent header branch); the cover's own former headline duplicating it is gone -
    // recap_card_test.dart pins that half directly.
    expect(find.text('RECAP'), findsOneWidget);
    expect(find.text('Ridgeway Family'), findsOneWidget);
  });

  testWidgets(
      'a recap post saves through the overflow menu - the deck has no standalone save button',
      (tester) async {
    await pumpPost(tester, recapPost());

    // No download icon anywhere before the menu is opened - the deck's own dedicated save
    // button (a bare download icon next to the page dots) is gone.
    expect(find.byIcon(Icons.download_outlined), findsNothing);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    // Opening the overflow menu shows exactly one download-icon item: "Save this panel",
    // wired to the deck's current page via RecapDeckState.saveCurrentPage.
    expect(find.text('Save this panel'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);

    // Tap it too. The save can't be observed here - the rasterize never completes in a
    // test's fake-async zone, and Gal has no channel - but tapping still catches a deck key
    // pointed at the wrong widget, which throws on the way in. A silent no-op from a
    // mismatched onSelected value would slip through; that needs a device.
    await tester.tap(find.text('Save this panel'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
