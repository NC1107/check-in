import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// A session the server rejected must leave a notice that survives a restart and names the
/// group; a deliberate sign-out must not; signing back in clears it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secureStore;
  late HttpServer server;
  late int meStatus;
  final host = InternetAddress.loopbackIPv4.address;
  late String baseUrl;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secureStore = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
      switch (call.method) {
        case 'read':
          return secureStore[args['key'] as String];
        case 'write':
          secureStore[args['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          secureStore.remove(args['key'] as String);
          return null;
      }
      return null;
    });
    // flutter_test swaps in an HttpClient that answers 400 to everything; this suite needs
    // the real status codes /api/me produces.
    HttpOverrides.global = null;
    meStatus = 401;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://$host:${server.port}';
    server.listen((req) {
      req.response
        ..statusCode = meStatus
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'invalid or expired session'}));
      req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  /// Boots the stored session through a container and waits for the launch hydrate to finish.
  Future<ProviderContainer> launch() async {
    SharedPreferences.setMockInitialValues({
      'groups_json': jsonEncode([
        {'id': host, 'baseUrl': baseUrl, 'name': 'Family'},
      ]),
    });
    secureStore['token_$host'] = 'tok';
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.listen(multiSessionProvider, (_, __) {});
    c.listen(signOutNoticesProvider, (_, __) {});
    for (var i = 0; i < 100 && c.read(multiSessionProvider).byId(host)?.isSignedIn != false; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (meStatus != 401) break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return c;
  }

  test('a 401 on launch signs the group out and leaves a notice that survives a restart', () async {
    final c = await launch();

    expect(c.read(multiSessionProvider).byId(host)!.isSignedIn, isFalse);
    expect(c.read(signOutNoticesProvider), {host});
    expect(c.read(signedOutNoticeGroupsProvider).map((g) => g.displayName), ['Family']);

    final prefs = await SharedPreferences.getInstance();
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    expect(prefs.getString('signed_out_notice_ids'), jsonEncode([host]));
    restarted.listen(signOutNoticesProvider, (_, __) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(restarted.read(signOutNoticesProvider), {host});
  });

  test('a 403 (a proxy blocking the request) neither signs out nor leaves a notice', () async {
    meStatus = 403;
    final c = await launch();

    expect(c.read(multiSessionProvider).byId(host)!.isSignedIn, isTrue);
    expect(c.read(signOutNoticesProvider), isEmpty);
  });

  test('signing out on purpose leaves no notice', () async {
    meStatus = 200;
    final c = await launch();

    await c.read(multiSessionProvider.notifier).signOutGroup(host);

    expect(c.read(multiSessionProvider).byId(host)!.isSignedIn, isFalse);
    expect(c.read(signOutNoticesProvider), isEmpty);
  });

  test('signing back in clears the notice', () async {
    final c = await launch();
    expect(c.read(signOutNoticesProvider), {host});

    await c.read(multiSessionProvider.notifier).addGroup(
          baseUrl: baseUrl,
          serverName: 'Family',
          token: 'fresh',
          user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false),
        );

    expect(c.read(signOutNoticesProvider), isEmpty);
    expect(c.read(signedOutNoticeGroupsProvider), isEmpty);
  });

  group('feed', () {
    const alpha = ServerAccount(
        id: 'alpha.invalid', baseUrl: 'https://alpha.invalid', serverName: 'Alpha', token: 't1');
    const beta =
        ServerAccount(id: 'beta.invalid', baseUrl: 'https://beta.invalid', serverName: 'Beta');

    Future<ProviderContainer> pumpFeed(WidgetTester tester, Set<String> notices) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            multiSessionProvider.overrideWith(() => MultiSessionController.seeded(
                const MultiSession(groups: [alpha, beta], restored: true))),
            signOutNoticesProvider.overrideWith(() => SignOutNoticesController.seeded(notices)),
            feedProvider.overrideWith((ref) async => const FeedResult(posts: [])),
            apiForGroupProvider
                .overrideWith((ref, groupId) => ApiClient(baseUrl: 'https://alpha.invalid')),
            locationsProvider.overrideWith((ref, groupId) async => []),
            groupMembersProvider.overrideWith((ref, groupId) async => []),
          ],
          child: Consumer(builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(home: FeedScreen());
          }),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return container;
    }

    testWidgets('names the group and offers to sign in; dismissing removes it', (tester) async {
      final c = await pumpFeed(tester, {'beta.invalid'});

      expect(find.textContaining('You were signed out of Beta.'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();

      expect(find.textContaining('You were signed out of'), findsNothing);
      expect(c.read(signOutNoticesProvider), isEmpty);
    });

    testWidgets('shows nothing when no group was signed out behind the member', (tester) async {
      await pumpFeed(tester, {});

      expect(find.textContaining('You were signed out of'), findsNothing);
    });
  });
}
