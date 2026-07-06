import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Group selection lives in the feed's filter sheet (GROUPS: All | each group |
/// + Add group); the active group shows as a removable chip under the search bar.
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

  Future<void> openFilter(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
  }

  testWidgets('the feed header has no group row; the filter sheet lists All, every group, and add',
      (tester) async {
    await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    // No switcher chips on the feed itself.
    expect(find.text('All'), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('+ Add group'), findsNothing);

    await openFilter(tester);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('+ Add group'), findsOneWidget);
  });

  testWidgets('hides the All pill with a single group', (tester) async {
    await pump(tester,
        const MultiSession(groups: [alpha], activeGroupId: 'alpha.invalid', restored: true));

    await openFilter(tester);
    expect(find.text('All'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('+ Add group'), findsOneWidget);
  });

  testWidgets('picking a group applies it and shows a removable chip', (tester) async {
    final controller =
        await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openFilter(tester);
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(controller.state.activeGroupId, 'beta.invalid');

    // The active group is a removable filter chip; removing it returns to All.
    expect(find.text('Beta'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(controller.state.activeGroupId, isNull);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('the combined view hides per-group filter sections behind a hint', (tester) async {
    await pump(tester, const MultiSession(groups: [alpha, beta], restored: true));

    await openFilter(tester);
    expect(find.text('People, date, and place filters are set while viewing one group.'),
        findsOneWidget);
    expect(find.text('DATE'), findsNothing);

    // With a single group active the full sections come back.
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    await openFilter(tester);
    expect(find.text('DATE'), findsOneWidget);
  });
}
