import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/feed_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Infinite scroll in the merged ("All") view: scrolling near the bottom must keep loading
/// older posts from every shown group, not just stop after the first page - that was the
/// reported bug (pagination was hard-disabled whenever more than one group was shown).
class _PagedFakeApi extends ApiClient {
  _PagedFakeApi(this.pages) : super(baseUrl: 'https://x.invalid');

  /// Each entry is the page returned by the Nth call past the (synthetic) first page.
  final List<List<Post>> pages;
  int calls = 0;
  int get callCount => calls;

  @override
  Future<List<Post>> feed(
      {int? authorId, Set<String> locations = const {}, DateTime? before, int? beforeId}) async {
    if (calls >= pages.length) return [];
    return pages[calls++];
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const signedInA =
      ServerAccount(id: 'a.invalid', baseUrl: 'https://a.invalid', serverName: 'A', token: 't');
  const signedInB =
      ServerAccount(id: 'b.invalid', baseUrl: 'https://b.invalid', serverName: 'B', token: 't');

  Post post(int id, String groupId, DateTime created) => Post(
        id: id,
        authorId: 1,
        authorName: 'Nick',
        kind: 'text',
        body: 'post $groupId-$id',
        createdAt: created,
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        groupId: groupId,
      );

  /// Repeatedly scrolls to the (growing) bottom of the feed, which is what drives
  /// _loadMore in the real app (a ListView.builder only builds items near the visible
  /// range, so the scroll position has to actually follow the list as it grows for the
  /// newly-appended tail posts to exist as widgets at all).
  Future<void> scrollToEnd(WidgetTester tester, {int rounds = 6}) async {
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    for (var i = 0; i < rounds; i++) {
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('both shown groups keep paging past the first page in the merged view',
      (tester) async {
    final now = DateTime.now();
    final apiA = _PagedFakeApi([
      [post(2, 'a.invalid', now.subtract(const Duration(hours: 2)))], // a's page 2
    ]); // nothing past that: a's page 3 comes back empty via the default []
    final apiB = _PagedFakeApi([
      [post(2, 'b.invalid', now.subtract(const Duration(hours: 3)))], // b's page 2
    ]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => MultiSessionController.seeded(
            const MultiSession(groups: [signedInA, signedInB], restored: true))),
        feedProvider.overrideWith((ref) async => FeedResult(posts: [
              post(1, 'a.invalid', now.subtract(const Duration(minutes: 1))),
              post(1, 'b.invalid', now),
            ])),
        apiForGroupProvider.overrideWith((ref, groupId) => groupId == 'a.invalid' ? apiA : apiB),
        locationsProvider.overrideWith((ref, groupId) async => []),
        groupMembersProvider.overrideWith((ref, groupId) async => []),
      ],
      child: const MaterialApp(home: FeedScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('post a.invalid-1'), findsOneWidget);
    expect(find.textContaining('post b.invalid-1'), findsOneWidget);

    await scrollToEnd(tester);

    // Both groups' second pages made it in - the merged view kept paging both, not just
    // one, and not none.
    expect(find.textContaining('post a.invalid-2'), findsOneWidget);
    expect(find.textContaining('post b.invalid-2'), findsOneWidget);
    expect(apiA.callCount, greaterThanOrEqualTo(1));
    expect(apiB.callCount, greaterThanOrEqualTo(1));

    // Once every shown group has reported empty, further scrolling must not keep calling
    // either - a well-behaved "reached the end", not a runaway poll.
    final aCallsAtEnd = apiA.callCount;
    final bCallsAtEnd = apiB.callCount;
    await scrollToEnd(tester);
    expect(apiA.callCount, aCallsAtEnd);
    expect(apiB.callCount, bCallsAtEnd);
  });

  testWidgets('a group that runs out keeps deferring to the one that still has more',
      (tester) async {
    final now = DateTime.now();
    // 'a' has exactly one more page; 'b' has two more pages - a runs out first.
    final apiA = _PagedFakeApi([
      [post(2, 'a.invalid', now.subtract(const Duration(hours: 1)))],
    ]);
    final apiB = _PagedFakeApi([
      [post(2, 'b.invalid', now.subtract(const Duration(hours: 2)))],
      [post(3, 'b.invalid', now.subtract(const Duration(hours: 4)))],
    ]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => MultiSessionController.seeded(
            const MultiSession(groups: [signedInA, signedInB], restored: true))),
        feedProvider.overrideWith((ref) async => FeedResult(posts: [
              post(1, 'a.invalid', now.subtract(const Duration(minutes: 1))),
              post(1, 'b.invalid', now),
            ])),
        apiForGroupProvider.overrideWith((ref, groupId) => groupId == 'a.invalid' ? apiA : apiB),
        locationsProvider.overrideWith((ref, groupId) async => []),
        groupMembersProvider.overrideWith((ref, groupId) async => []),
      ],
      child: const MaterialApp(home: FeedScreen()),
    ));
    await tester.pumpAndSettle();

    await scrollToEnd(tester);

    // Every page from both groups eventually loaded, including b's third page - which only
    // arrives if the feed kept asking b after a had already run dry, i.e. one group running
    // out didn't stop the other from continuing to page.
    expect(find.textContaining('post a.invalid-2'), findsOneWidget);
    expect(find.textContaining('post b.invalid-2'), findsOneWidget);
    expect(find.textContaining('post b.invalid-3'), findsOneWidget);
    // 'a' was never asked more than once past its single extra page.
    expect(apiA.callCount, 1);

    final bCallsAtEnd = apiB.callCount;
    await scrollToEnd(tester);
    expect(apiA.callCount, 1);
    expect(apiB.callCount, bCallsAtEnd);
  });
}
