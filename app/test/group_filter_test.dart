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
