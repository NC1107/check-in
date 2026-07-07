import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Group visibility lives in the filter sheet's GROUPS section: multi-select pills
/// (All | each group | + Add group) applied together with people/date/place via
/// "Show results". There is no group bubble or chip anywhere on the feed itself, and
/// every group can be toggled off (the feed then shows a "no groups shown" state).
/// Overrides the session with a seeded controller and the feed/locations with fixed
/// results so no network is touched.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const alpha = ServerAccount(
      id: 'alpha.invalid', baseUrl: 'https://alpha.invalid', serverName: 'Alpha', token: 't1');
  const beta = ServerAccount(
      id: 'beta.invalid', baseUrl: 'https://beta.invalid', serverName: 'Beta', token: 't2');

  Future<MultiSessionController> pump(WidgetTester tester, MultiSession seed,
      {List<Post> posts = const [], Map<String, List<User>> members = const {}}) async {
    final controller = MultiSessionController.seeded(seed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith((ref) => controller),
          // Mirror production: the feed only carries posts from currently-shown groups.
          feedProvider.overrideWith((ref) async {
            final shown = {for (final g in ref.watch(multiSessionProvider).shownGroups) g.id};
            return FeedResult(posts: [
              for (final p in posts)
                if (shown.contains(p.groupId)) p
            ]);
          }),
          locationsProvider.overrideWith((ref, groupId) async => []),
          groupMembersProvider.overrideWith((ref, groupId) async => members[groupId] ?? []),
        ],
        child: const MaterialApp(home: FeedScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> openFilter(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
  }

  testWidgets('no group UI on the feed itself; the filter sheet carries GROUPS', (tester) async {
    await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    // Nothing group-shaped on the feed: no bubble, no chips.
    expect(find.byIcon(Icons.public), findsNothing);
    expect(find.text('All'), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    // The filter button is present even in the merged view.
    expect(find.byIcon(Icons.filter_list), findsOneWidget);

    await openFilter(tester);
    expect(find.text('GROUPS'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('+ Add group'), findsOneWidget);
    expect(find.text('DATE'), findsOneWidget);
  });

  testWidgets('single group: no All pill, still Add group', (tester) async {
    await pump(tester, const MultiSession(groups: [alpha], restored: true));

    await openFilter(tester);
    expect(find.text('All'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('+ Add group'), findsOneWidget);
  });

  testWidgets('deselecting a group applies with Show results; no chip appears', (tester) async {
    final controller =
        await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openFilter(tester);
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, {'beta.invalid'});
    expect(controller.state.shownGroups.map((g) => g.id), ['alpha.invalid']);
    // The group scope never shows as a chip under the search bar.
    expect(find.text('Beta'), findsNothing);
    expect(find.text('Alpha'), findsNothing);

    // The All pill resets the scope.
    await openFilter(tester);
    await tester.tap(find.text('All'));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, isEmpty);
  });

  testWidgets('every group can be toggled off; the feed says no groups are shown', (tester) async {
    final controller =
        await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openFilter(tester);
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, {'alpha.invalid', 'beta.invalid'});
    expect(controller.state.nothingShown, isTrue);
    expect(find.text('No groups shown'), findsOneWidget);

    // The filter sheet stays reachable - it's the way back.
    await openFilter(tester);
    expect(find.text('GROUPS'), findsOneWidget);
  });

  testWidgets('a signed-out group appears locked in GROUPS (re-login, not a toggle)',
      (tester) async {
    const gammaOut = ServerAccount(
        id: 'gamma.invalid', baseUrl: 'https://gamma.invalid', serverName: 'Gamma', token: null);
    await pump(tester, const MultiSession(groups: [alpha, beta, gammaOut], restored: true));

    await openFilter(tester);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('the same person in two groups merges into one People pill by phone', (tester) async {
    Post post(int id, String groupId, int authorId, String authorName) => Post(
          id: id,
          authorId: authorId,
          authorName: authorName,
          kind: 'text',
          body: 'hi',
          createdAt: DateTime(2026, 7, id),
          likeCount: 0,
          commentCount: 0,
          likedByViewer: false,
          groupId: groupId,
        );
    // Nick is user 1 on alpha and user 7 on beta - same phone. Ada is alpha-only.
    await pump(
      tester,
      const MultiSession(groups: [alpha, beta], restored: true),
      posts: [
        post(3, 'beta.invalid', 7, 'Nick'),
        post(2, 'alpha.invalid', 1, 'Nick'),
        post(1, 'alpha.invalid', 2, 'Ada'),
      ],
      members: {
        'alpha.invalid': [
          User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true),
          User(id: 2, name: 'Ada', phone: '+15550002222', isAdmin: false),
        ],
        'beta.invalid': [
          User(id: 7, name: 'Nick', phone: '+15550001111', isAdmin: false),
        ],
      },
    );

    await openFilter(tester);
    // Scope to the sheet: the feed behind it also renders author names.
    final sheet = find.byType(BottomSheet);
    // One Nick pill, not two; Ada unaffected.
    expect(find.descendant(of: sheet, matching: find.text('Nick')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Ada')), findsOneWidget);

    // Selecting the merged Nick matches his posts from BOTH groups.
    await tester.tap(find.descendant(of: sheet, matching: find.text('Nick')));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(find.text('hi'), findsNWidgets(2)); // Nick's alpha + beta posts
    expect(find.text('Ada'), findsNothing); // Ada's post filtered out
  });

  testWidgets('the All pill toggles: all on <-> all off', (tester) async {
    final controller =
        await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openFilter(tester);
    // Everything is shown, so tapping All turns everything OFF...
    await tester.tap(find.text('All'));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, {'alpha.invalid', 'beta.invalid'});
    expect(find.text('No groups shown'), findsOneWidget);

    // ...and tapping it again turns everything back ON.
    await openFilter(tester);
    await tester.tap(find.text('All'));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, isEmpty);
  });

  testWidgets('People scopes live to the selected groups; scoped-out selections are pruned',
      (tester) async {
    Post post(int id, String groupId, int authorId, String authorName) => Post(
          id: id,
          authorId: authorId,
          authorName: authorName,
          kind: 'text',
          body: 'hi',
          createdAt: DateTime(2026, 7, id),
          likeCount: 0,
          commentCount: 0,
          likedByViewer: false,
          groupId: groupId,
        );
    // Nick is in both groups; Ada only in alpha.
    final controller = await pump(
      tester,
      const MultiSession(groups: [alpha, beta], restored: true),
      posts: [
        post(3, 'beta.invalid', 7, 'Nick'),
        post(2, 'alpha.invalid', 1, 'Nick'),
        post(1, 'alpha.invalid', 2, 'Ada'),
      ],
      members: {
        'alpha.invalid': [
          User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true),
          User(id: 2, name: 'Ada', phone: '+15550002222', isAdmin: false),
        ],
        'beta.invalid': [
          User(id: 7, name: 'Nick', phone: '+15550001111', isAdmin: false),
        ],
      },
    );

    await openFilter(tester);
    final sheet = find.byType(BottomSheet);
    // Select Ada, then deselect her only group: her pill vanishes live.
    await tester.tap(find.descendant(of: sheet, matching: find.text('Ada')));
    await tester.pump();
    await tester.tap(find.descendant(of: sheet, matching: find.text('Alpha')));
    await tester.pump();
    expect(find.descendant(of: sheet, matching: find.text('Ada')), findsNothing);
    // Nick is still a member of Beta, so he stays.
    expect(find.descendant(of: sheet, matching: find.text('Nick')), findsOneWidget);

    // Deselecting the last group keeps the section (with a hint) instead of collapsing
    // the sheet - no layout jump.
    await tester.tap(find.descendant(of: sheet, matching: find.text('Beta')));
    await tester.pump();
    expect(find.text('PEOPLE'), findsOneWidget);
    expect(find.text('Select a group to filter by people.'), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Nick')), findsNothing);
    // Bring Alpha back for the apply step below.
    await tester.tap(find.descendant(of: sheet, matching: find.text('Beta')));
    await tester.pump();
    expect(find.text('Select a group to filter by people.'), findsNothing);

    // Applying prunes the now-invisible Ada selection: only the group scope filters.
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, {'alpha.invalid'});
    expect(find.text('hi'), findsOneWidget); // Nick's beta post (alpha hidden)
    // No stale person chip under the search bar for the pruned Ada.
    expect(find.text('Ada'), findsNothing);
  });

  testWidgets('Clear resets the group scope back to All', (tester) async {
    final controller = await pump(
        tester,
        const MultiSession(
            groups: [alpha, beta], hiddenGroupIds: {'beta.invalid'}, restored: true));

    await openFilter(tester);
    await tester.tap(find.text('Clear'));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, isEmpty);
  });
}
