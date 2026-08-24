import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/settings/blocked_people_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Blocking worked in one direction only: the button lives on the other person's profile,
/// and blocking them removes their check-ins and comments from every view you have - so the
/// route back to that button was to remember their name and find them in people search.
/// Which you cannot do if you blocked the wrong person and never knew their name.

class _FakeApi extends ApiClient {
  _FakeApi({this.blocked = const [], this.fail = false, this.unblockFails = false})
      : super(baseUrl: '');

  final List<User> blocked;
  final bool fail;
  final bool unblockFails;

  final unblocked = <int>[];
  late List<User> _remaining = [...blocked];

  @override
  Future<List<User>> blockedUsers() async {
    if (fail) throw Exception('unreachable');
    return _remaining;
  }

  @override
  Future<void> unblockUser(int userId) async {
    if (unblockFails) throw Exception('nope');
    unblocked.add(userId);
    _remaining = [
      for (final u in _remaining)
        if (u.id != userId) u
    ];
  }
}

void main() {
  User person(int id, String name) =>
      User(id: id, name: name, phone: '1555000000$id', isAdmin: false);

  ServerAccount account(String host) => ServerAccount(
        id: host,
        baseUrl: 'https://$host',
        serverName: host,
        token: 't',
        user: User(id: 1, name: 'Nick', phone: '15550000001', isAdmin: false),
      );

  Future<void> pump(
    WidgetTester tester, {
    required List<ServerAccount> accounts,
    required Map<String, _FakeApi> apis,
  }) async {
    final controller =
        MultiSessionController.seeded(MultiSession(groups: accounts, restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        for (final e in apis.entries) apiForGroupProvider(e.key).overrideWithValue(e.value),
      ],
      child: const MaterialApp(home: BlockedPeopleScreen()),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  }

  testWidgets('lists who you have blocked, by name', (tester) async {
    await pump(
      tester,
      accounts: [account('alpha.invalid')],
      apis: {
        'alpha.invalid': _FakeApi(blocked: [person(2, 'Sam Tayler'), person(3, 'Ada Okafor')]),
      },
    );

    expect(find.text('Sam Tayler'), findsOneWidget);
    expect(find.text('Ada Okafor'), findsOneWidget);
    expect(find.text('Unblock'), findsNWidgets(2));
  });

  testWidgets('unblocking removes them from the list', (tester) async {
    final api = _FakeApi(blocked: [person(2, 'Sam Tayler'), person(3, 'Ada Okafor')]);
    await pump(tester, accounts: [account('alpha.invalid')], apis: {'alpha.invalid': api});

    await tester.tap(find.text('Unblock').first);
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(api.unblocked, [2]);
    expect(find.text('Sam Tayler'), findsNothing);
    expect(find.text('Ada Okafor'), findsOneWidget,
        reason: 'unblocking one person must not touch the others');
  });

  testWidgets('a failed unblock says so and keeps them listed', (tester) async {
    final api = _FakeApi(blocked: [person(2, 'Sam Tayler')], unblockFails: true);
    await pump(tester, accounts: [account('alpha.invalid')], apis: {'alpha.invalid': api});

    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(find.textContaining('Could not unblock'), findsOneWidget);
    expect(find.text('Sam Tayler'), findsOneWidget,
        reason: 'the row must stay until the server has actually accepted the unblock');
  });

  testWidgets('an empty list says how blocking is done', (tester) async {
    await pump(
      tester,
      accounts: [account('alpha.invalid')],
      apis: {'alpha.invalid': _FakeApi()},
    );
    expect(find.textContaining("haven't blocked anyone"), findsOneWidget);
    expect(find.textContaining('from their profile'), findsOneWidget);
  });

  // Each group is its own server with its own block list, so the same person can be blocked
  // in one group and not another - the row has to say which.
  testWidgets('rows name their group when more than one is connected', (tester) async {
    await pump(
      tester,
      accounts: [account('alpha.invalid'), account('beta.invalid')],
      apis: {
        'alpha.invalid': _FakeApi(blocked: [person(2, 'Sam Tayler')]),
        'beta.invalid': _FakeApi(blocked: [person(9, 'Ada Okafor')]),
      },
    );

    expect(find.text('Sam Tayler'), findsOneWidget);
    expect(find.text('Ada Okafor'), findsOneWidget);
    expect(find.text('alpha.invalid'), findsOneWidget);
    expect(find.text('beta.invalid'), findsOneWidget);
  });

  testWidgets('one unreachable group does not hide the others', (tester) async {
    await pump(
      tester,
      accounts: [account('alpha.invalid'), account('beta.invalid')],
      apis: {
        'alpha.invalid': _FakeApi(fail: true),
        'beta.invalid': _FakeApi(blocked: [person(9, 'Ada Okafor')]),
      },
    );

    expect(find.text('Ada Okafor'), findsOneWidget);
    expect(find.textContaining("Couldn't reach alpha.invalid"), findsOneWidget);
  });

  // Unblocking goes to the group holding that block, never to whichever server happens to
  // be current - the ids mean different people on different servers.
  testWidgets('unblocking goes to the right group', (tester) async {
    final alpha = _FakeApi(blocked: [person(2, 'Sam Tayler')]);
    final beta = _FakeApi(blocked: [person(2, 'Someone Else')]);
    await pump(
      tester,
      accounts: [account('alpha.invalid'), account('beta.invalid')],
      apis: {'alpha.invalid': alpha, 'beta.invalid': beta},
    );

    // Groups list in connection order, so beta's row - and its Unblock - is the last one.
    final betaRow = find.ancestor(of: find.text('Someone Else'), matching: find.byType(Row));
    await tester.tap(find.descendant(of: betaRow.last, matching: find.text('Unblock')));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(beta.unblocked, [2]);
    expect(alpha.unblocked, isEmpty,
        reason: 'the same id is a different person on the other server');
  });
}
