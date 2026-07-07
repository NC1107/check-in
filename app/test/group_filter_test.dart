import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Group visibility lives in the "group bubble" left of the search bar: a globe when every
/// group is shown, opening a popover of live multi-select toggles (All groups | each group
/// | Add group). The old feed-top switcher and the filter-sheet GROUPS section are gone.
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
          locationsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: FeedScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> openBubble(WidgetTester tester) async {
    // The bubble is the only globe on screen until the menu opens.
    await tester.tap(find.byIcon(Icons.public));
    await tester.pumpAndSettle();
  }

  testWidgets('the feed header has no group switcher; the bubble opens the group menu',
      (tester) async {
    await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    // No switcher chips or filter icon on the feed itself while merged.
    expect(find.text('All'), findsNothing);
    expect(find.byIcon(Icons.filter_list), findsNothing);
    // The bubble (a globe) is present because more than one group is connected.
    expect(find.byIcon(Icons.public), findsOneWidget);

    await openBubble(tester);
    expect(find.text('All groups'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Add group'), findsOneWidget);
  });

  testWidgets('hides the bubble entirely with a single connected group', (tester) async {
    await pump(tester, const MultiSession(groups: [alpha], restored: true));

    // No bubble; instead the per-group filter button is available.
    expect(find.byIcon(Icons.public), findsNothing);
    expect(find.byIcon(Icons.filter_list), findsOneWidget);
  });

  testWidgets('toggling a group hides it live; All groups resets', (tester) async {
    final controller =
        await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openBubble(tester);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    // Live update, menu stays open, and the shown set drops Beta.
    expect(controller.state.hiddenGroupIds, {'beta.invalid'});
    expect(controller.state.shownGroups.map((g) => g.id), ['alpha.invalid']);
    expect(find.text('All groups'), findsOneWidget); // still open

    await tester.tap(find.text('All groups'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, isEmpty);
  });

  testWidgets("can't hide the last shown group", (tester) async {
    final controller =
        await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openBubble(tester);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, {'alpha.invalid'});

    // Hiding Beta too would empty the feed - refused.
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(controller.state.hiddenGroupIds, {'alpha.invalid'});
    expect(controller.state.shownGroups.map((g) => g.id), ['beta.invalid']);
  });

  testWidgets('a signed-out group appears in the menu offering re-login, not a toggle',
      (tester) async {
    const gammaOut = ServerAccount(
        id: 'gamma.invalid', baseUrl: 'https://gamma.invalid', serverName: 'Gamma', token: null);
    await pump(
        tester, const MultiSession(groups: [alpha, beta, gammaOut], restored: true));

    // Two groups are signed in, so the bubble shows and the menu is reachable.
    await openBubble(tester);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget); // the re-login affordance
  });

  testWidgets('the filter sheet no longer carries a GROUPS section', (tester) async {
    await pump(tester, const MultiSession(groups: [alpha], restored: true));

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    expect(find.text('GROUPS'), findsNothing);
    expect(find.text('DATE'), findsOneWidget);
  });
}
