import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/settings/settings_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The settings screen behind the profile's gear: account actions live here, with
/// member management visible only to the group's host.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ServerAccount account({required bool isAdmin}) => ServerAccount(
        id: 'alpha.invalid',
        baseUrl: 'https://alpha.invalid',
        serverName: 'Alpha',
        token: 't1',
        user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: isAdmin),
      );

  Future<void> pump(WidgetTester tester, {required bool isAdmin}) async {
    final controller = MultiSessionController.seeded(MultiSession(
      groups: [account(isAdmin: isAdmin)],
      restored: true,
    ));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [multiSessionProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: SettingsScreen(groupId: 'alpha.invalid')),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows every account action for the host', (tester) async {
    await pump(tester, isAdmin: true);

    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('hides member management from non-hosts', (tester) async {
    await pump(tester, isAdmin: false);

    expect(find.text('Members'), findsNothing);
    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('group rename sets a local nickname; empty restores the server name', (tester) async {
    final controller = MultiSessionController.seeded(MultiSession(
      groups: [account(isAdmin: false)],
      restored: true,
    ));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [multiSessionProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: SettingsScreen(groupId: 'alpha.invalid')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Group name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'College crew');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final renamed = controller.state.byId('alpha.invalid')!;
    expect(renamed.displayName, 'College crew');
    expect(renamed.serverName, 'Alpha'); // the server's own name is untouched

    // Clearing the field falls back to the server's own name.
    await tester.tap(find.text('Group name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final cleared = controller.state.byId('alpha.invalid')!;
    expect(cleared.displayName, 'Alpha');
    expect(cleared.nickname, isNull);
  });
}
