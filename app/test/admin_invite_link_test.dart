import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/admin/admin_screen.dart';
import 'package:checkin/features/onboarding/invite_links.dart';
import 'package:checkin/state/app_state.dart';

/// Nothing in the app used to produce a /join URL, so the one person meant to send invite
/// links had no way to get one. These cover the admin's copy button and the shape of the
/// link it hands over.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({});
  });

  test('the invite link is the group server plus /join', () {
    expect(joinLinkFor('https://alpha.example.com'), 'https://alpha.example.com/join');
    // Stored base URLs are normalized without one, but a hand-entered address can carry a
    // trailing slash and "//join" would 404.
    expect(joinLinkFor('https://alpha.example.com/'), 'https://alpha.example.com/join');
  });

  testWidgets('the admin invite panel copies this group\'s join link', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final controller = MultiSessionController.seeded(MultiSession(
      groups: [
        ServerAccount(
          id: 'alpha.example.com',
          baseUrl: 'https://alpha.example.com',
          serverName: 'Alpha',
          token: 't1',
          user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: true),
        ),
      ],
      restored: true,
    ));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith((ref) => controller),
        apiForGroupProvider('alpha.example.com').overrideWithValue(_EmptyAdminApi()),
      ],
      child: const MaterialApp(home: AdminScreen(groupId: 'alpha.example.com')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('https://alpha.example.com/join'), findsOneWidget);

    await tester.tap(find.text('https://alpha.example.com/join'));
    await tester.pumpAndSettle();

    expect(copied, ['https://alpha.example.com/join']);
    expect(find.text('Invite link copied'), findsOneWidget);
  });
}

/// A group with nothing in it yet, so the screen settles without reaching the network.
class _EmptyAdminApi extends ApiClient {
  _EmptyAdminApi() : super(baseUrl: 'https://alpha.example.com');

  @override
  Future<List<Invite>> adminListAllowed() async => [];

  @override
  Future<List<User>> adminListUsers() async => [];

  @override
  Future<List<ContentReport>> adminListReports() async => [];
}
