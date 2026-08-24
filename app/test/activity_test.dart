import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/activity/activity_bell.dart';
import 'package:checkin/features/activity/activity_screen.dart';
import 'package:checkin/state/app_state.dart';

/// The activity list is what makes a missed notification recoverable. Its merge across
/// groups is where the multi-group hazards live: ids are only unique per server, so an item
/// that loses track of which group it came from cannot be opened at all.

/// An ApiClient whose activity read is stubbed. [fail] makes the group unreachable, which
/// is the case a merged list has to survive rather than showing nothing.
class _FakeApi extends ApiClient {
  _FakeApi({this.page, this.fail = false}) : super(baseUrl: '');

  final ActivityPage? page;
  final bool fail;

  int seenCalls = 0;

  @override
  Future<ActivityPage> activity({String? cursor, int? limit}) async {
    if (fail) throw Exception('unreachable');
    return page ?? ActivityPage(items: const [], unreadCount: 0);
  }

  @override
  Future<void> markActivitySeen() async => seenCalls++;
}

void main() {
  final me = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false);

  ServerAccount account(String host, {bool activityCapable = true}) => ServerAccount(
        id: host,
        baseUrl: 'https://$host',
        serverName: host,
        token: 't',
        user: me,
        activityCapable: activityCapable,
      );

  ActivityItem item(String kind, {required int minutesAgo, String actor = 'Sam', int? commentId}) =>
      ActivityItem(
        kind: kind,
        postId: 5,
        commentId: commentId,
        actorId: 2,
        actorName: actor,
        preview: kind == 'like' ? '' : 'said something',
        createdAt: DateTime(2026, 5, 1, 12).subtract(Duration(minutes: minutesAgo)),
      );

  group('ActivityItem.fromJson', () {
    test('reads what the server sends', () {
      final got = ActivityItem.fromJson({
        'kind': 'reply',
        'postId': 5,
        'commentId': 9,
        'actorId': 2,
        'actorName': 'Sam',
        'actorPhotoId': 7,
        'preview': 'Lisbon',
        'createdAt': '2026-05-01T12:00:00Z',
      });
      expect(got.kind, 'reply');
      expect(got.commentId, 9);
      expect(got.actorName, 'Sam');
      expect(got.preview, 'Lisbon');
    });

    test('a like carries no comment id, and that is not an error', () {
      final got = ActivityItem.fromJson({
        'kind': 'like',
        'postId': 5,
        'actorId': 2,
        'actorName': 'Sam',
        'createdAt': '2026-05-01T12:00:00Z',
      });
      expect(got.commentId, isNull);
      expect(got.preview, isEmpty);
    });
  });

  group('activityLine', () {
    test('says what happened, plainly', () {
      expect(activityLine(item('comment', minutesAgo: 0)), 'Sam commented on your check-in');
      expect(activityLine(item('reply', minutesAgo: 0)), 'Sam replied to your comment');
      expect(activityLine(item('like', minutesAgo: 0)), 'Sam liked your check-in');
    });

    test('an unknown kind from a newer server degrades to the name, not a crash', () {
      expect(activityLine(item('mention', minutesAgo: 0)), 'Sam');
    });
  });

  group('activityGroups', () {
    test('leaves out a group whose server predates the route', () {
      final session = MultiSession(
        groups: [account('alpha.invalid'), account('beta.invalid', activityCapable: false)],
        restored: true,
      );
      expect(activityGroups(session).map((g) => g.id), ['alpha.invalid']);
    });
  });

  group('mergeActivity', () {
    test('sorts newest first across groups, whatever order they arrived in', () {
      final merged = mergeActivity({
        'alpha.invalid': [item('like', minutesAgo: 30), item('comment', minutesAgo: 90)],
        'beta.invalid': [item('reply', minutesAgo: 5), item('like', minutesAgo: 60)],
      });
      expect(merged.map((i) => i.kind), ['reply', 'like', 'like', 'comment']);
    });

    test('stamps every item with its group, so a tap knows which server to open', () {
      final merged = mergeActivity({
        'alpha.invalid': [item('like', minutesAgo: 30)],
        'beta.invalid': [item('reply', minutesAgo: 5)],
      });
      expect(merged.first.groupId, 'beta.invalid');
      expect(merged.last.groupId, 'alpha.invalid');
    });

    test('an empty group contributes nothing rather than a gap', () {
      final merged = mergeActivity({
        'alpha.invalid': [],
        'beta.invalid': [item('reply', minutesAgo: 5)],
      });
      expect(merged, hasLength(1));
    });
  });

  group('badgeLabel', () {
    test('caps at 99+, past which the exact number is not information', () {
      expect(badgeLabel(1), '1');
      expect(badgeLabel(99), '99');
      expect(badgeLabel(100), '99+');
    });
  });

  group('ActivityScreen', () {
    Future<_FakeApi> pump(
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
        child: const MaterialApp(home: ActivityScreen()),
      ));
      await tester.pump();
      await tester.pump();
      return apis.values.first;
    }

    testWidgets('lists what happened, newest first', (tester) async {
      await pump(
        tester,
        accounts: [account('alpha.invalid')],
        apis: {
          'alpha.invalid': _FakeApi(
            page: ActivityPage(
              items: [
                item('reply', minutesAgo: 5, actor: 'Ada', commentId: 9),
                item('like', minutesAgo: 60),
              ],
              unreadCount: 2,
            ),
          ),
        },
      );

      expect(find.text('Ada replied to your comment'), findsOneWidget);
      expect(find.text('Sam liked your check-in'), findsOneWidget);
      // A like has no content of its own, so nothing is previewed under it.
      expect(find.text('said something'), findsOneWidget);
    });

    testWidgets('opening the list marks it seen, which is what clears the bell', (tester) async {
      final api = await pump(
        tester,
        accounts: [account('alpha.invalid')],
        apis: {
          'alpha.invalid': _FakeApi(
            page: ActivityPage(items: [item('like', minutesAgo: 5)], unreadCount: 1),
          ),
        },
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(api.seenCalls, 1);
    });

    testWidgets('an empty list explains itself rather than showing a blank page', (tester) async {
      await pump(
        tester,
        accounts: [account('alpha.invalid')],
        apis: {'alpha.invalid': _FakeApi()},
      );
      expect(find.textContaining('Nothing yet'), findsOneWidget);
    });

    testWidgets('one unreachable group does not hide the others', (tester) async {
      await pump(
        tester,
        accounts: [account('alpha.invalid'), account('beta.invalid')],
        apis: {
          'alpha.invalid': _FakeApi(fail: true),
          'beta.invalid': _FakeApi(
            page: ActivityPage(items: [item('like', minutesAgo: 5)], unreadCount: 1),
          ),
        },
      );

      expect(find.text('Sam liked your check-in'), findsOneWidget);
      expect(find.textContaining("Couldn't reach alpha.invalid"), findsOneWidget);
    });

    testWidgets('a group whose server predates the route is never asked', (tester) async {
      final old = _FakeApi(fail: true);
      await pump(
        tester,
        accounts: [account('alpha.invalid'), account('beta.invalid', activityCapable: false)],
        apis: {
          'alpha.invalid': _FakeApi(
            page: ActivityPage(items: [item('like', minutesAgo: 5)], unreadCount: 1),
          ),
          'beta.invalid': old,
        },
      );

      // No "couldn't reach" notice: the old group was skipped, not failed.
      expect(find.textContaining("Couldn't reach"), findsNothing);
      expect(find.text('Sam liked your check-in'), findsOneWidget);
    });
  });

  group('ActivityBell', () {
    Future<void> pumpBell(
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
        child: const MaterialApp(home: Scaffold(appBar: null, body: ActivityBell())),
      ));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('sums the unread count across groups', (tester) async {
      await pumpBell(
        tester,
        accounts: [account('alpha.invalid'), account('beta.invalid')],
        apis: {
          'alpha.invalid': _FakeApi(page: ActivityPage(items: const [], unreadCount: 2)),
          'beta.invalid': _FakeApi(page: ActivityPage(items: const [], unreadCount: 3)),
        },
      );
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('an unreachable group counts zero rather than hiding the badge', (tester) async {
      await pumpBell(
        tester,
        accounts: [account('alpha.invalid'), account('beta.invalid')],
        apis: {
          'alpha.invalid': _FakeApi(fail: true),
          'beta.invalid': _FakeApi(page: ActivityPage(items: const [], unreadCount: 3)),
        },
      );
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('nothing unread means no badge at all', (tester) async {
      await pumpBell(
        tester,
        accounts: [account('alpha.invalid')],
        apis: {'alpha.invalid': _FakeApi(page: ActivityPage(items: const [], unreadCount: 0))},
      );
      expect(find.byType(IconButton), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('the bell hides entirely when no group can answer', (tester) async {
      await pumpBell(
        tester,
        accounts: [account('alpha.invalid', activityCapable: false)],
        apis: {'alpha.invalid': _FakeApi()},
      );
      expect(find.byType(IconButton), findsNothing);
    });
  });
}
