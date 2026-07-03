import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The feed's group switcher: All | each group | + Add group, bound to the active
/// group. Overrides the session with a seeded controller and the feed with a fixed
/// result so no network is touched.
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
        ],
        child: const MaterialApp(home: FeedScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('shows All, every group, and the add entry with two groups', (tester) async {
    await pump(tester,
        const MultiSession(groups: [alpha, beta], activeGroupId: 'alpha.invalid', restored: true));

    expect(find.text('All'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('+ Add group'), findsOneWidget);
  });

  testWidgets('hides the All chip with a single group', (tester) async {
    await pump(tester,
        const MultiSession(groups: [alpha], activeGroupId: 'alpha.invalid', restored: true));

    expect(find.text('All'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('+ Add group'), findsOneWidget);
  });

  testWidgets('tapping a group makes it active; tapping All clears the selection', (tester) async {
    final controller = await pump(tester,
        const MultiSession(groups: [alpha, beta], activeGroupId: 'alpha.invalid', restored: true));

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(controller.state.activeGroupId, 'beta.invalid');

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(controller.state.activeGroupId, isNull);
  });
}
