import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Group visibility lives in the filter sheet's GROUPS section: multi-select pills
/// (All | each group) applied together with people/date/place via "Show results".
/// Adding a group lives in Settings > Edit groups, not here. There is no group bubble or
/// chip anywhere on the feed itself, and every group can be toggled off (the feed then
/// shows a "no groups shown" state).
/// Overrides the session with a seeded controller and the feed/locations with fixed
/// results so no network is touched.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const alpha = ServerAccount(
      id: 'alpha.invalid', baseUrl: 'https://alpha.invalid', serverName: 'Alpha', token: 't1');
  const beta = ServerAccount(
      id: 'beta.invalid', baseUrl: 'https://beta.invalid', serverName: 'Beta', token: 't2');

  Future<MultiSessionController> pump(WidgetTester tester, MultiSession seed,
      {List<Post> posts = const [],
      Map<String, List<User>> members = const {},
      List<({String location, int count})> locations = const []}) async {
    final controller = MultiSessionController.seeded(seed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith(() => controller),
          // Mirror production: the feed only carries posts from currently-shown groups.
          feedProvider.overrideWith((ref) async {
            final shown = {for (final g in ref.watch(multiSessionProvider).shownGroups) g.id};
            return FeedResult(posts: [
              for (final p in posts)
                if (shown.contains(p.groupId)) p
            ]);
          }),
          locationsProvider.overrideWith((ref, groupId) async => locations),
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
    // Adding a group moved to Settings > Edit groups.
    expect(find.text('+ Add group'), findsNothing);
    expect(find.text('DATE'), findsOneWidget);
  });

  testWidgets('single group: the GROUPS section is hidden entirely', (tester) async {
    await pump(tester, const MultiSession(groups: [alpha], restored: true));

    await openFilter(tester);
    // One group = nothing to scope: no section, no pills, no All.
    expect(find.text('GROUPS'), findsNothing);
    expect(find.text('All'), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    // The rest of the filter is untouched.
    expect(find.text('DATE'), findsOneWidget);
  });

  testWidgets('two groups with one signed out: GROUPS stays (re-login is reachable)',
      (tester) async {
    const betaOut = ServerAccount(
        id: 'beta.invalid', baseUrl: 'https://beta.invalid', serverName: 'Beta', token: null);
    await pump(tester, const MultiSession(groups: [alpha, betaOut], restored: true));

    await openFilter(tester);
    expect(find.text('GROUPS'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    // Only one signed-in group, so no All pill.
    expect(find.text('All'), findsNothing);
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

  testWidgets(
      'DATE offers presets + a custom range; a preset filters the feed and reveals the '
      'download button', (tester) async {
    Post dated(int id, DateTime created, String body) => Post(
          id: id,
          authorId: 1,
          authorName: 'Nick',
          kind: 'text',
          body: body,
          createdAt: created,
          likeCount: 0,
          commentCount: 0,
          likedByViewer: false,
          groupId: 'alpha.invalid',
        );
    final now = DateTime.now();
    await pump(
      tester,
      const MultiSession(groups: [alpha], restored: true),
      posts: [
        dated(2, now, 'today post'),
        dated(1, now.subtract(const Duration(days: 40)), 'old post'),
      ],
    );

    // Both posts show, and with no filter there is no bulk-download button.
    expect(find.text('today post'), findsOneWidget);
    expect(find.text('old post'), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);

    await openFilter(tester);
    // Presets plus the new custom-range option (scoped to the sheet: the feed behind it
    // renders a "Today" date divider too).
    final sheet = find.byType(BottomSheet);
    expect(find.descendant(of: sheet, matching: find.text('Today')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('This week')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('This month')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Custom range')), findsOneWidget);

    // Picking "Today" keeps only today's post...
    await tester.tap(find.descendant(of: sheet, matching: find.text('Today')));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(find.text('today post'), findsOneWidget);
    expect(find.text('old post'), findsNothing);
    // ...and an active filter reveals the compact download button.
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
  });

  testWidgets('the custom range pill opens the in-theme calendar sheet', (tester) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pump(tester, const MultiSession(groups: [alpha], restored: true));

    await openFilter(tester);
    await tester
        .tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Custom range')));
    await tester.pumpAndSettle();
    // The custom dark range sheet is on screen (title + Apply, not the Material picker).
    expect(find.text('Select dates'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Select a start date'), findsOneWidget);
  });

  const places = [(location: 'Paris', count: 3), (location: 'Tokyo', count: 1)];

  testWidgets('PLACE shows a compact field, not a wall of pills, and opens a picker on tap',
      (tester) async {
    await pump(tester, const MultiSession(groups: [alpha], restored: true), locations: places);

    await openFilter(tester);
    expect(find.text('PLACE'), findsOneWidget);
    // The field, not a pill per place - place names aren't in the main sheet at all yet.
    expect(find.text('All places'), findsOneWidget);
    expect(find.text('Paris'), findsNothing);

    await tester.tap(find.text('All places'));
    await tester.pumpAndSettle();
    // The picker sheet lists every place with its count, as checkable rows.
    expect(find.text('Paris'), findsOneWidget);
    expect(find.text('Tokyo'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // Paris's count
    expect(find.text('Apply'), findsOneWidget);
  });

  testWidgets('selecting several places applies them as a count; All places clears them all',
      (tester) async {
    await pump(tester, const MultiSession(groups: [alpha], restored: true), locations: places);

    await openFilter(tester);
    await tester.tap(find.text('All places'));
    await tester.pumpAndSettle();
    // Toggling both rows stages a count in the picker's own header before Apply.
    await tester.tap(find.text('Paris'));
    await tester.pump();
    await tester.tap(find.text('Tokyo'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    // Back in the filter sheet, the field now reads a count rather than either name.
    expect(find.text('2 places'), findsOneWidget);
    expect(find.text('All places'), findsNothing);
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();

    // Reopening shows both applied places persisted through Show results (active-filter
    // chips for them now also sit on the feed itself, so scope to the sheet specifically).
    await openFilter(tester);
    final sheet = find.byType(BottomSheet);
    expect(find.descendant(of: sheet, matching: find.text('2 places')), findsOneWidget);

    // The picker's own "All places" clears every selection at once, regardless of what was
    // staged.
    await tester.tap(find.descendant(of: sheet, matching: find.text('2 places')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All places'));
    await tester.pumpAndSettle();
    expect(find.text('All places'), findsOneWidget);
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();

    await openFilter(tester);
    expect(find.text('All places'), findsOneWidget);
  });

  testWidgets('Clear and Show results stay reachable even when GROUPS fills the sheet',
      (tester) async {
    // A realistic phone height, not an oversized test viewport - the bug only shows up
    // once content actually exceeds the visible area.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final manyGroups = [
      for (var i = 0; i < 20; i++)
        ServerAccount(
            id: 'g$i.invalid', baseUrl: 'https://g$i.invalid', serverName: 'Group $i', token: 't')
    ];
    await pump(tester, MultiSession(groups: manyGroups, restored: true));

    await openFilter(tester);
    // With 20 groups the GROUPS section alone is taller than the sheet's capped height, so
    // if the footer were still inside the scrolling body (the reported bug) it would be
    // scrolled out of the built range and undiscoverable here without manually scrolling to
    // it first - finding it directly proves it is pinned outside the scrollable area.
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Show results'), findsOneWidget);
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
  });
}
