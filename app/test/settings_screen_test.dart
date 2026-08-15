import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/settings/settings_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The settings screen behind the profile's gear: account actions live here, with
/// member management visible only to the group's host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Leave group deletes the per-group token from secure storage; mock the channel.
  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
  });

  ServerAccount account({required bool isAdmin}) => ServerAccount(
        id: 'alpha.invalid',
        baseUrl: 'https://alpha.invalid',
        serverName: 'Alpha',
        token: 't1',
        user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: isAdmin),
      );

  Future<MultiSessionController> pump(WidgetTester tester,
      {required bool isAdmin, List<ServerAccount> extraGroups = const []}) async {
    final controller = MultiSessionController.seeded(MultiSession(
      groups: [account(isAdmin: isAdmin), ...extraGroups],
      restored: true,
    ));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [multiSessionProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: SettingsScreen(groupId: 'alpha.invalid')),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  /// Navigates Settings → Edit groups → the given group's editor.
  Future<void> openEditor(WidgetTester tester, String groupName) async {
    await tester.tap(find.text('Edit groups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(groupName));
    await tester.pumpAndSettle();
  }

  testWidgets('host: Edit groups lists the group and its editor carries the shared settings',
      (tester) async {
    await pump(tester, isAdmin: true);

    expect(find.text('Edit profile'), findsOneWidget);
    // Appearance moved into Edit profile; not a top-level settings entry anymore.
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Edit groups'), findsOneWidget);
    // Everything group-shaped lives in Edit groups now.
    expect(find.text('Members'), findsNothing);
    expect(find.text('Group color'), findsNothing);
    expect(find.text('Group name'), findsNothing);
    expect(find.text('Leave group'), findsNothing);
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);

    await tester.tap(find.text('Edit groups'));
    await tester.pumpAndSettle();
    // The list marks hosted groups and carries Add group.
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.textContaining('Host ·'), findsOneWidget);
    expect(find.text('Add group'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Group name'), findsOneWidget);
    expect(find.text('Group color'), findsOneWidget);
    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Leave group'), findsOneWidget);
  });

  testWidgets('non-host: Edit groups is visible; the editor offers nickname + leave only',
      (tester) async {
    await pump(tester, isAdmin: false);

    // Any member manages (and can leave) their groups from here.
    expect(find.text('Edit groups'), findsOneWidget);
    expect(find.text('Group name'), findsNothing); // moved into the editor

    await openEditor(tester, 'Alpha');
    expect(find.text('Group name'), findsOneWidget); // local nickname
    expect(find.text('Leave group'), findsOneWidget);
    // No shared settings without the host role.
    expect(find.text('Group color'), findsNothing);
    expect(find.text('Members'), findsNothing);
  });

  testWidgets('group rename sets a local nickname; empty restores the server name', (tester) async {
    final controller = await pump(tester, isAdmin: false);
    await openEditor(tester, 'Alpha');

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

  testWidgets('leave group (single group): editor confirm removes it from the device',
      (tester) async {
    final controller = await pump(tester, isAdmin: false);
    await openEditor(tester, 'Alpha');

    await tester.tap(find.text('Leave group'));
    await tester.pumpAndSettle();
    expect(find.text('Leave Alpha?'), findsOneWidget);
    expect(find.textContaining('only group'), findsOneWidget); // last-group warning

    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(controller.state.byId('alpha.invalid'), isNull);
    expect(controller.state.groups, isEmpty);
  });

  testWidgets('leave group (multi group): pick from the list, others untouched', (tester) async {
    final beta = ServerAccount(
      id: 'beta.invalid',
      baseUrl: 'https://beta.invalid',
      serverName: 'Beta',
      token: 't2',
      user: User(id: 9, name: 'Nick', phone: '+15550001111', isAdmin: false),
    );
    final controller = await pump(tester, isAdmin: false, extraGroups: [beta]);
    await openEditor(tester, 'Beta');

    await tester.tap(find.text('Leave group'));
    await tester.pumpAndSettle();
    expect(find.text('Leave Beta?'), findsOneWidget);
    // Not the last group, so no connect-screen warning.
    expect(find.textContaining('only group'), findsNothing);

    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(controller.state.byId('beta.invalid'), isNull);
    // Alpha is untouched, token intact.
    expect(controller.state.byId('alpha.invalid')!.isSignedIn, isTrue);
  });

  // A 401 signs a group out but keeps its entry so the feed filter can offer re-login.
  // That read the same whether the session merely expired or the host removed you, and
  // Edit groups only listed signed-in groups - so the one group you'd want gone was the
  // one you could not reach Leave from.
  group('a signed-out group', () {
    ServerAccount signedOutBeta() => const ServerAccount(
          id: 'beta.invalid',
          baseUrl: 'https://beta.invalid',
          serverName: 'Beta',
        );

    testWidgets('is listed in Edit groups so it is reachable at all', (tester) async {
      await pump(tester, isAdmin: false, extraGroups: [signedOutBeta()]);

      await tester.tap(find.text('Edit groups'));
      await tester.pumpAndSettle();

      expect(find.text('Beta'), findsOneWidget);
      expect(find.textContaining('Signed out'), findsOneWidget);
    });

    testWidgets('can be removed from the device without calling its server', (tester) async {
      final controller = await pump(tester, isAdmin: false, extraGroups: [signedOutBeta()]);
      expect(controller.state.byId('beta.invalid'), isNotNull);

      await tester.tap(find.text('Edit groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove from this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      // Gone from the device, and the signed-in group is untouched.
      expect(controller.state.byId('beta.invalid'), isNull);
      expect(controller.state.byId('alpha.invalid'), isNotNull);
    });

    testWidgets('keeps its entry when the remove dialog is cancelled', (tester) async {
      final controller = await pump(tester, isAdmin: false, extraGroups: [signedOutBeta()]);

      await tester.tap(find.text('Edit groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove from this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(controller.state.byId('beta.invalid'), isNotNull);
    });
  });
}
