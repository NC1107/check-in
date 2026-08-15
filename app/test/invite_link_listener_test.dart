import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/onboarding/auth_screen.dart';
import 'package:checkin/features/onboarding/invite_link_listener.dart';
import 'package:checkin/features/onboarding/invite_links.dart';
import 'package:checkin/features/onboarding/terms_screen.dart';
import 'package:checkin/main.dart';
import 'package:checkin/state/app_state.dart';

/// Tapping an invite link is the whole point of the feature, and the platform hop that
/// starts it can only be checked on a device. What these cover is everything after it: that
/// the app, handed a route by the platform, puts the group's address where the auth screen
/// will find it - and does not do any of the things that used to happen instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const server = 'https://alpha.example.com';
  const invite = 'checkin://join?server=https%3A%2F%2Falpha.example.com';

  // Sessions are restored from prefs + secure storage on startup; mock both so the app
  // under test boots to a known state.
  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true});
  });

  /// Delivers [location] exactly the way the engine does, through the navigation channel,
  /// so the observer ordering under test is the real one.
  Future<void> deliver(WidgetTester tester, String location) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(
        MethodCall('pushRouteInformation', <String, dynamic>{'location': location}),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  ProviderContainer scopeOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(InviteLinkListener)), listen: false);

  /// The tree main() runs, so the assertions below are about the shipped widget order.
  Future<void> pumpApp(WidgetTester tester, {List<Override> overrides = const []}) async {
    await tester.pumpWidget(ProviderScope(overrides: overrides, child: const CheckInRoot()));
    await tester.pumpAndSettle();
  }

  group('cold start', () {
    // Android hands a cold-start link over as the initial route rather than as a route
    // push, so nothing would ever see it without this.
    test('an invite in the launch route seeds the pending invite', () {
      final container = ProviderContainer(overrides: inviteLinkOverrides(initialRoute: invite));
      addTearDown(container.dispose);
      expect(container.read(pendingInviteServerProvider), server);
    });

    test('an ordinary launch seeds nothing', () {
      expect(inviteLinkOverrides(initialRoute: '/'), isEmpty);
      expect(inviteLinkOverrides(initialRoute: 'checkin://join'), isEmpty);
    });
  });

  group('a delivered link', () {
    // The regression this guards: with the listener below MaterialApp instead of above it,
    // WidgetsApp is consulted first and pushes the link as a named route against an app
    // that has no routes table. That throws, and the invite is lost.
    testWidgets('is taken above MaterialApp, not pushed as a route', (tester) async {
      await pumpApp(tester);
      await deliver(tester, invite);

      expect(tester.takeException(), isNull,
          reason: 'the link must be consumed before MaterialApp tries to route it');
      expect(scopeOf(tester).read(pendingInviteServerProvider), server);
    });

    // Handing an unroutable checkin:// URL back to the framework is the same unhandled-route
    // push, and on iOS it also makes the engine re-open the URL through the system.
    testWidgets('is consumed even when it is not a valid invite', (tester) async {
      await pumpApp(tester);
      await deliver(tester, 'checkin://join?server=');

      expect(tester.takeException(), isNull);
      expect(scopeOf(tester).read(pendingInviteServerProvider), isNull);
    });

    // Only invites are intercepted. Claiming everything would starve any router mounted
    // below, which is how the app would grow real in-app routes later.
    testWidgets('reaches the app below when it is not an invite', (tester) async {
      final routed = <String?>[];
      await tester.pumpWidget(ProviderScope(
        child: InviteLinkListener(
          child: MaterialApp(
            onGenerateRoute: (settings) {
              routed.add(settings.name);
              return MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink());
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await deliver(tester, '/somewhere-else');

      expect(routed, contains('/somewhere-else'));
    });
  });

  group('the EULA gate', () {
    // The gate is what got the app through review, so an invite waits behind it. It is
    // parked, not dropped: AuthScreen picks it up as its prefill once the user accepts.
    testWidgets('is never pushed over', (tester) async {
      await pumpApp(tester);
      expect(find.byType(TermsScreen), findsOneWidget);

      await deliver(tester, invite);

      expect(find.byType(TermsScreen), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
      expect(scopeOf(tester).read(pendingInviteServerProvider), server);
    });
  });

  group('while already signed in', () {
    List<Override> signedIn() {
      SharedPreferences.setMockInitialValues({'seen_selfhost_intro': true, 'terms_accepted': true});
      return [
        multiSessionProvider.overrideWith((ref) => MultiSessionController.seeded(MultiSession(
              groups: [
                ServerAccount(
                  id: 'beta.example.com',
                  baseUrl: 'https://beta.example.com',
                  serverName: 'Beta',
                  token: 't1',
                  user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false),
                ),
              ],
              restored: true,
            ))),
      ];
    }

    testWidgets('an invite opens the add-group flow on the group it names', (tester) async {
      await pumpApp(tester, overrides: signedIn());
      expect(find.byType(AuthScreen), findsNothing);

      await deliver(tester, invite);

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text(server), findsOneWidget);
    });

    testWidgets('a second invite tops up the open flow instead of stacking another',
        (tester) async {
      await pumpApp(tester, overrides: signedIn());
      await deliver(tester, invite);
      await deliver(tester, 'checkin://join?server=https%3A%2F%2Fgamma.example.com');

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text('https://gamma.example.com'), findsOneWidget);
    });
  });

  group('an auth screen that is already open', () {
    testWidgets('takes a late invite as its server address', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AuthScreen()),
      ));
      await tester.pumpAndSettle();

      container.read(pendingInviteServerProvider.notifier).state = server;
      await tester.pumpAndSettle();

      expect(find.text(server), findsOneWidget);
      // Consumed, so backing out and joining a different group can't resurrect it.
      expect(container.read(pendingInviteServerProvider), isNull);
    });
  });
}
