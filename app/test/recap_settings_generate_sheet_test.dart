import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/settings/recap_settings_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The on-demand generate sheet lost its panel picker entirely when Awards Night was
/// retired - "collage" (The Wall) is v1's only panel - and gained a "Bestow titles" toggle
/// that only appears once the server has advertised the titles capability.
class _FakeApi extends ApiClient {
  _FakeApi({required this.titlesCapable}) : super(baseUrl: '');

  final bool titlesCapable;

  @override
  Future<ServerInfo> serverInfo() async => ServerInfo(
        name: 'Alpha',
        initialized: true,
        recapCapable: true,
        titlesCapable: titlesCapable,
      );
}

void main() {
  ServerAccount account() => ServerAccount(
        id: 'alpha.invalid',
        baseUrl: 'https://alpha.invalid',
        serverName: 'Alpha',
        token: 't1',
        recapCapable: true,
        user: User(id: 1, name: 'Robin', phone: '+15550001111', isAdmin: true),
      );

  Future<void> pumpAndOpenSheet(WidgetTester tester, {required bool titlesCapable}) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account()], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        apiForGroupProvider('alpha.invalid')
            .overrideWithValue(_FakeApi(titlesCapable: titlesCapable)),
      ],
      child: const MaterialApp(home: RecapSettingsScreen(groupId: 'alpha.invalid')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Generate a recap now'));
    await tester.pumpAndSettle();
  }

  testWidgets('the generate sheet no longer offers a panel picker at all', (tester) async {
    await pumpAndOpenSheet(tester, titlesCapable: false);

    expect(find.text('Generate a recap'), findsOneWidget);
    expect(find.text('Awards Night'), findsNothing);
    expect(find.text('The Wall'), findsNothing);
    expect(find.text('PANELS'), findsNothing);
  });

  testWidgets('the "Bestow titles" toggle is hidden until the server advertises it',
      (tester) async {
    await pumpAndOpenSheet(tester, titlesCapable: false);
    expect(find.text('Bestow titles'), findsNothing);
  });

  testWidgets('the "Bestow titles" toggle appears once the server advertises the capability',
      (tester) async {
    await pumpAndOpenSheet(tester, titlesCapable: true);
    expect(find.text('Bestow titles'), findsOneWidget);
  });
}
