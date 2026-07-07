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

  testWidgets('host: group settings live in the Edit groups submenu (list → editor)',
      (tester) async {
    await pump(tester, isAdmin: true);

    expect(find.text('Edit profile'), findsOneWidget);
    // Appearance moved into Edit profile; not a top-level settings entry anymore.
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Edit groups'), findsOneWidget);
    // Consolidated into Edit groups; the local-nickname tile is for non-admins.
    expect(find.text('Members'), findsNothing);
    expect(find.text('Group color'), findsNothing);
    expect(find.text('Group name'), findsNothing);
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);

    // Edit groups → the list of hosted groups → one group's editor.
    await tester.tap(find.text('Edit groups'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Group name'), findsOneWidget);
    expect(find.text('Group color'), findsOneWidget);
    expect(find.text('Members'), findsOneWidget);
  });

  testWidgets('hides group management from non-hosts (nickname tile stays)', (tester) async {
    await pump(tester, isAdmin: false);

    expect(find.text('Edit groups'), findsNothing);
    expect(find.text('Members'), findsNothing);
    expect(find.text('Group name'), findsOneWidget); // local nickname
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
