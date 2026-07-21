import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/state/unread.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'https://alpha.invalid');

  @override
  Future<List<Post>> feed(
          {int? authorId,
          Set<String> locations = const {},
          DateTime? before,
          int? beforeId}) async =>
      [];
}

void main() {
  const alpha = ServerAccount(
      id: 'alpha.invalid', baseUrl: 'https://alpha.invalid', serverName: 'Alpha', token: 't1');

  final now = DateTime.now();
  Post post(int id, DateTime created, String body) => Post(
        id: id,
        authorId: 1,
        authorName: 'Nick',
        kind: 'text',
        body: body,
        createdAt: created,
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        groupId: 'alpha.invalid',
      );

  Future<void> pump(WidgetTester tester, List<Post> posts) async {
    // Tall enough that the whole feed is laid out - the caught-up line sits mid-list and a
    // lazy ListView would otherwise not build it in the default 600px surface.
    tester.view.physicalSize = const Size(500, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          multiSessionProvider.overrideWith((ref) =>
              MultiSessionController.seeded(const MultiSession(groups: [alpha], restored: true))),
          feedProvider.overrideWith((ref) async => FeedResult(posts: posts)),
          apiForGroupProvider.overrideWith((ref, groupId) => _FakeApi()),
          locationsProvider.overrideWith((ref, groupId) async => []),
          groupMembersProvider.overrideWith((ref, groupId) async => []),
        ],
        child: const MaterialApp(home: FeedScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('seen markers', () {
    test('a group with no marker is absent (never visited = nothing to catch up on)', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadSeenMarkers(['alpha.invalid']), isEmpty);
    });

    test('markers round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final at = DateTime.utc(2026, 7, 10, 12);
      await saveSeenMarkers({'alpha.invalid': at});
      expect((await loadSeenMarkers(['alpha.invalid']))['alpha.invalid'], at);
    });

    test('markers only ever move forward, so seen posts never resurface', () async {
      SharedPreferences.setMockInitialValues({});
      final newer = DateTime.utc(2026, 7, 10, 12);
      final older = DateTime.utc(2026, 7, 1, 12);
      await saveSeenMarkers({'alpha.invalid': newer});
      // An older page loading in (or a group briefly unreachable) must not drag it back.
      await saveSeenMarkers({'alpha.invalid': older});
      expect((await loadSeenMarkers(['alpha.invalid']))['alpha.invalid'], newer);
    });
  });

  testWidgets('the caught-up line sits between new check-ins and already-seen ones',
      (tester) async {
    // Last visit ended 2 hours ago: the two recent posts are new, the older two are not.
    SharedPreferences.setMockInitialValues({
      'feed_seen_at_alpha.invalid':
          now.subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
    });
    await pump(tester, [
      post(4, now, 'brand new'),
      post(3, now.subtract(const Duration(minutes: 30)), 'also new'),
      post(2, now.subtract(const Duration(hours: 5)), 'already seen'),
      post(1, now.subtract(const Duration(hours: 9)), 'seen too'),
    ]);

    expect(find.text("You're all caught up"), findsOneWidget);

    // The line must fall below both new posts and above both seen ones.
    double y(String text) => tester.getCenter(find.text(text)).dy;
    final line = y("You're all caught up");
    expect(y('brand new'), lessThan(line));
    expect(y('also new'), lessThan(line));
    expect(y('already seen'), greaterThan(line));
    expect(y('seen too'), greaterThan(line));
  });

  testWidgets('no line on a first visit (no marker) - a whole first feed is not "unread"',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pump(tester, [
      post(2, now, 'a post'),
      post(1, now.subtract(const Duration(hours: 5)), 'another'),
    ]);
    expect(find.text("You're all caught up"), findsNothing);
  });

  testWidgets('no line when everything is new (nothing seen to sit below it)', (tester) async {
    SharedPreferences.setMockInitialValues({
      'feed_seen_at_alpha.invalid':
          now.subtract(const Duration(days: 30)).toUtc().toIso8601String(),
    });
    await pump(tester, [
      post(2, now, 'a post'),
      post(1, now.subtract(const Duration(hours: 5)), 'another'),
    ]);
    expect(find.text("You're all caught up"), findsNothing);
  });

  testWidgets('showing the feed advances the on-disk marker to the newest post', (tester) async {
    SharedPreferences.setMockInitialValues({
      'feed_seen_at_alpha.invalid':
          now.subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
    });
    final newest = now;
    await pump(tester, [
      post(2, newest, 'brand new'),
      post(1, now.subtract(const Duration(hours: 5)), 'already seen'),
    ]);

    // The line still shows for THIS visit (the in-memory snapshot is held fixed)...
    expect(find.text("You're all caught up"), findsOneWidget);
    // ...but the next visit will measure "new" from the newest post on show.
    final stored = (await loadSeenMarkers(['alpha.invalid']))['alpha.invalid']!;
    expect(stored.toUtc(), newest.toUtc());
  });

  testWidgets('no line while a filter is active - a filtered feed is not a reading position',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'feed_seen_at_alpha.invalid':
          now.subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
    });
    await pump(tester, [
      post(2, now, 'brand new'),
      post(1, now.subtract(const Duration(days: 40)), 'old one'),
    ]);
    expect(find.text("You're all caught up"), findsOneWidget);

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Today')));
    await tester.pump();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();

    expect(find.text("You're all caught up"), findsNothing);
  });
}
