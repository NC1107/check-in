import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/admin/admin_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The host's member and invite lists are the only place a phone number is shown back to a
/// human, and the server stores numbers as bare digits with no punctuation. Shown verbatim
/// they arrive as an unbroken run - unreadable, and impossible to match against a contact,
/// which is the only thing the host is doing when they look at these lists.
///
/// The formatter itself is covered in stored_phone_format_test.dart. This is the other half:
/// that these two screens actually use it. A correct formatter nothing calls fixes nothing.
class _FakeApi extends ApiClient {
  _FakeApi({required this.invites, required this.users}) : super(baseUrl: '');

  final List<Invite> invites;
  final List<User> users;

  @override
  Future<List<Invite>> adminListAllowed() async => invites;

  @override
  Future<List<User>> adminListUsers() async => users;

  @override
  Future<List<ContentReport>> adminListReports() async => const [];
}

void main() {
  final admin = User(id: 1, name: 'Nick Conn', phone: '15550000001', isAdmin: true);

  Future<void> pump(WidgetTester tester, _FakeApi api) async {
    // The admin screen is a long scroll and its lists sit below the fold. A tall viewport
    // builds the whole thing, so a finder answers "is it rendered" rather than "did it
    // happen to be on screen".
    tester.view.physicalSize = const Size(500, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final account = ServerAccount(
      id: 'alpha.invalid',
      baseUrl: 'https://alpha.invalid',
      serverName: 'Alpha',
      token: 't1',
      user: admin,
    );
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        contentApiProvider('alpha.invalid').overrideWithValue(api),
      ],
      child: const MaterialApp(home: AdminScreen(groupId: 'alpha.invalid')),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  }

  testWidgets('the invite list shows a readable number, not the stored digits', (tester) async {
    await pump(
      tester,
      _FakeApi(
        invites: [Invite(phone: '15550000002', used: false)],
        users: [admin],
      ),
    );

    expect(find.text('+1 (555) 000-0002'), findsOneWidget);
    expect(find.text('15550000002'), findsNothing,
        reason: 'the raw stored form must not reach the screen');
  });

  testWidgets('the member list shows a readable number too', (tester) async {
    await pump(
      tester,
      _FakeApi(
        invites: const [],
        users: [admin, User(id: 2, name: 'Sam Tayler', phone: '15550000002', isAdmin: false)],
      ),
    );

    expect(find.text('+1 (555) 000-0002'), findsOneWidget);
    expect(find.text('15550000002'), findsNothing);
  });

  // The host's own row says "Host" rather than their number - the number is only useful for
  // matching someone you are about to invite or remove.
  testWidgets('the host row still says Host rather than a number', (tester) async {
    await pump(tester, _FakeApi(invites: const [], users: [admin]));

    expect(find.text('Host'), findsOneWidget);
    expect(find.text('+1 (555) 000-0001'), findsNothing);
  });
}
