import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/onboarding/auth_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/theme/accent_picker.dart';

/// The accent color is a per-device theme and the picker persists on tap, so signup may
/// only offer it on a device's first-ever signup. A second group join that re-offered it
/// would let one tap silently replace the theme the user already lives with.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The multi-session store reads tokens from secure storage; mock the channel.
  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
  });

  ServerAccount account() => ServerAccount(
        id: 'alpha.invalid',
        baseUrl: 'https://alpha.invalid',
        serverName: 'Alpha',
        token: 't1',
        user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false),
      );

  /// Pumps the auth screen and drives it to the profile step: type a server and a valid
  /// number, then Continue. The fake client answers both onboarding probes.
  Future<void> pumpToProfile(WidgetTester tester, {required List<ServerAccount> groups}) async {
    final controller = MultiSessionController.seeded(MultiSession(groups: groups, restored: true));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [multiSessionProvider.overrideWith((ref) => controller)],
        child: MaterialApp(home: AuthScreen(clientFactory: (_, {token}) => _FakeApi())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'alpha.invalid');
    await tester.enterText(find.byType(TextField).at(1), '2025550186');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  testWidgets('joining a second group does not re-ask for the accent color', (tester) async {
    // Established device: a group is already connected, and the intro dialog is spent.
    SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true});

    await pumpToProfile(tester, groups: [account()]);

    expect(find.text('Full name'), findsOneWidget); // the profile step did render
    expect(find.text('Accent color'), findsNothing);
    expect(find.text('Pick a color - it themes the app for you and updates live.'), findsNothing);
  });

  testWidgets('a first-ever signup still gets to pick an accent', (tester) async {
    SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true});

    await pumpToProfile(tester, groups: const []);

    expect(find.text('Full name'), findsOneWidget);
    expect(find.text('Accent color'), findsOneWidget);
  });

  testWidgets('picking a color does not pull the section out from under the user', (tester) async {
    SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true});

    await pumpToProfile(tester, groups: const []);
    expect(find.text('Accent color'), findsOneWidget);

    // The picker persists on tap, so a gate re-read from storage on every build would
    // hide the section the instant it was used. It is latched at step entry to stop that.
    final swatches = find.descendant(
      of: find.byType(AccentPicker),
      matching: find.byType(GestureDetector),
    );
    final tapped = swatches.at(1);
    // Guard against a vacuous pass: assert the tap actually moved the selection, so the
    // section surviving below means it survived a real write rather than a dead tap.
    expect(find.descendant(of: tapped, matching: find.byIcon(Icons.check)), findsNothing);
    await tester.tap(tapped);
    await tester.pumpAndSettle();
    expect(find.descendant(of: tapped, matching: find.byIcon(Icons.check)), findsOneWidget);

    expect(find.text('Accent color'), findsOneWidget);
    expect(find.byType(AccentPicker), findsOneWidget);
  });
}

/// Answers the two unauthenticated onboarding calls the entry step makes. Signup itself
/// is never reached, so nothing else needs overriding.
class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'https://fake.invalid');

  @override
  Future<ServerInfo> serverInfo() async => ServerInfo(name: 'Alpha', initialized: true);

  @override
  Future<({bool allowed, bool registered, bool isFirstAdmin})> checkPhone(String phone) async =>
      (allowed: true, registered: false, isFirstAdmin: false);
}
