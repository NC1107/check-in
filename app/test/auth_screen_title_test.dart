import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/features/onboarding/auth_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Tapping Sign in on a signed-out group used to open a screen titled "Add a group", which
/// reads like it will create a second copy of a group the member is already in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true});
  });

  const signedIn = ServerAccount(
      id: 'alpha.invalid', baseUrl: 'https://alpha.invalid', serverName: 'Alpha', token: 't1');
  const signedOut =
      ServerAccount(id: 'beta.invalid', baseUrl: 'https://beta.invalid', serverName: 'Beta');

  Future<void> pumpAuth(WidgetTester tester, {String? initialServer}) async {
    final controller = MultiSessionController.seeded(
        const MultiSession(groups: [signedIn, signedOut], restored: true));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [multiSessionProvider.overrideWith(() => controller)],
        child: MaterialApp(home: AuthScreen(initialServer: initialServer)),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('signing back into a group on this device is titled Sign in', (tester) async {
    await pumpAuth(tester, initialServer: 'https://beta.invalid');
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Add a group'), findsNothing);
  });

  testWidgets('a server not on this device is still Add a group', (tester) async {
    await pumpAuth(tester, initialServer: 'https://gamma.invalid');
    expect(find.text('Add a group'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
  });
}
