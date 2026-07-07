import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Group visibility lives in the "group bubble" left of the search bar: a globe that opens
/// a bottom sheet of live multi-select toggles (All groups | each group | Add group).
/// Every group can be toggled off - the feed then shows a "no groups shown" state.
/// The filter button stays available in the merged view (its data merges across groups).
/// Overrides the session with a seeded controller and the feed/locations with fixed
/// results so no network is touched.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const alpha = ServerAccount(
      id: 'alpha.invalid', baseUrl: 'https://alpha.invalid', serverName: 'Alpha', token: 't1');
  const beta = ServerAccount(
      id: 'beta.invalid', baseUrl: 'https://beta.invalid', serverName: 'Beta', token: 't2');

  Future<MultiSessionController> pump(WidgetTester tester, MultiSession seed,
      {List<Post> posts = const []}) async {
    final controller = MultiSessionController.seeded(seed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith((ref) => controller),
          feedProvider.overrideWith((ref) async => FeedResult(posts: posts)),
          locationsProvider.overrideWith((ref, groupId) async => []),
        ],
        child: const MaterialApp(home: FeedScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> openBubble(WidgetTester tester) async {
    // The bubble is the only globe on screen until the sheet opens.
    await tester.tap(find.byIcon(Icons.public));
    await tester.pumpAndSettle();
  }

  testWidgets('the bubble opens the group sheet with All + every group + Add group',
      (tester) async {
    await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    // No switcher chips on the feed; the filter button stays even while merged.
    expect(find.text('All'), findsNothing);
    expect(find.byIcon(Icons.filter_list), findsOneWidget);
    expect(find.byIcon(Icons.public), findsOneWidget);

    await openBubble(tester);
    expect(find.text('Groups'), findsOneWidget); // sheet title
    expect(find.text('All groups'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Add group'), findsOneWidget);
  });

  testWidgets('hides the bubble entirely with a single connected group', (tester) async {
    await pump(tester, const MultiSession(groups: [alpha], restored: true));

    expect(find.byIcon(Icons.public), findsNothing);
    expect(find.byIcon(Icons.filter_list), findsOneWidget);
  });

  testWidgets('toggling a group hides it live; All groups resets', (tester) async {
    final controller =
        await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openBubble(tester);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    // Live update, sheet stays open, and the shown set drops Beta.
    expect(controller.state.hiddenGroupIds, {'beta.invalid'});
    expect(controller.state.shownGroups.map((g) => g.id), ['alpha.invalid']);
    expect(find.text('All groups'), findsOneWidget); // still open

    await tester.tap(find.text('All groups'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, isEmpty);
  });

  testWidgets('every group can be toggled off; the feed says no groups are shown', (tester) async {
    final controller =
        await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openBubble(tester);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, {'alpha.invalid', 'beta.invalid'});
    expect(controller.state.shownGroups, isEmpty);
    expect(controller.state.nothingShown, isTrue);

    // Close the sheet - the feed explains the empty selection.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('No groups shown'), findsOneWidget);
    expect(find.byIcon(Icons.public_off), findsWidgets);
  });

  testWidgets('a signed-out group appears in the sheet offering re-login, not a toggle',
      (tester) async {
    const gammaOut = ServerAccount(
        id: 'gamma.invalid', baseUrl: 'https://gamma.invalid', serverName: 'Gamma', token: null);
    await pump(tester, const MultiSession(groups: [alpha, beta, gammaOut], restored: true));

    await openBubble(tester);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget); // the re-login affordance
  });

  testWidgets('the filter sheet opens in the merged view (no GROUPS section)', (tester) async {
    await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    expect(find.text('GROUPS'), findsNothing);
    expect(find.text('DATE'), findsOneWidget);
  });
}
