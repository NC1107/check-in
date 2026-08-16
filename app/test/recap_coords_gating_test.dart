import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/home_shell.dart';
import 'package:checkin/features/settings/edit_group_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The guard preventing a 400 against a server that predates the recap feature: lat/lng
/// must never be sent unless the target server's own server-info has advertised
/// recapCapable, and the "Recaps" settings entry must never be offered on one either (it
/// has nowhere to send the settings PATCH). Both are pinned directly rather than only
/// indirectly through the full compose/settings flow, so neither can be quietly
/// refactored away.
void main() {
  ServerAccount account({required bool recapCapable, required bool isAdmin}) => ServerAccount(
        id: 'alpha.invalid',
        baseUrl: 'https://alpha.invalid',
        serverName: 'Alpha',
        token: 't1',
        recapCapable: recapCapable,
        user: User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: isAdmin),
      );

  group('recapCoordsFor', () {
    test('a server that has not advertised recapCapable never receives coordinates', () {
      final target = account(recapCapable: false, isAdmin: true);
      final coords = recapCoordsFor(target, 38.12, -9.99);
      expect(coords.lat, isNull);
      expect(coords.lng, isNull);
    });

    test('a recapCapable server receives the coordinates exactly as given', () {
      final target = account(recapCapable: true, isAdmin: true);
      final coords = recapCoordsFor(target, 38.12, -9.99);
      expect(coords.lat, 38.12);
      expect(coords.lng, -9.99);
    });

    test('no resolved location means nothing to send either way', () {
      expect(recapCoordsFor(account(recapCapable: true, isAdmin: true), null, null).lat, isNull);
      expect(recapCoordsFor(account(recapCapable: false, isAdmin: true), null, null).lat, isNull);
    });
  });

  group('the Recaps settings tile', () {
    Future<void> pumpEditor(WidgetTester tester, {required bool recapCapable}) async {
      final controller = MultiSessionController.seeded(
        MultiSession(groups: [account(recapCapable: recapCapable, isAdmin: true)], restored: true),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [multiSessionProvider.overrideWith(() => controller)],
        child: const MaterialApp(home: EditGroupScreen(groupId: 'alpha.invalid')),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('is offered to a host once the server has advertised recapCapable', (tester) async {
      await pumpEditor(tester, recapCapable: true);
      expect(find.text('Recaps'), findsOneWidget);
    });

    testWidgets('is absent for a server that has not advertised recapCapable', (tester) async {
      await pumpEditor(tester, recapCapable: false);
      expect(find.text('Recaps'), findsNothing);
    });
  });
}
