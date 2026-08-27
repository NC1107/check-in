import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/feed/post_card.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Commenting moved out of the feed card and into the thread.
///
/// The inline composer could only ever post a plain top-level comment to the default group:
/// it had no reply, no gif, and no cross-post group picker, so anyone who commented from
/// the feed silently got less than the thread offers. These pin that the entry point still
/// exists and leads somewhere, rather than the feature just being deleted.
class _FakeApi extends ApiClient {
  _FakeApi({required this.post}) : super(baseUrl: '');

  final Post post;

  @override
  Future<Post> getPost(int id) async => post;

  @override
  Future<List<Comment>> comments(int postId) async => const [];
}

void main() {
  User me({bool isAdmin = false}) =>
      User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: isAdmin);

  ServerAccount account({bool isAdmin = false}) => ServerAccount(
        id: 'alpha.invalid',
        baseUrl: 'https://alpha.invalid',
        serverName: 'Alpha',
        token: 't1',
        user: me(isAdmin: isAdmin),
      );

  final post = Post(
    id: 5,
    authorId: 2,
    authorName: 'Ada',
    kind: 'text',
    body: 'hello',
    createdAt: DateTime(2026, 7, 1),
    likeCount: 0,
    commentCount: 0,
    likedByViewer: false,
    groupId: 'alpha.invalid',
  );

  Future<_FakeApi> pumpCard(WidgetTester tester, {bool isAdmin = false}) async {
    final api = _FakeApi(post: post);
    final controller = MultiSessionController.seeded(
        MultiSession(groups: [account(isAdmin: isAdmin)], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        contentApiProvider('alpha.invalid').overrideWithValue(api),
      ],
      child: MaterialApp(home: Scaffold(body: PostCard(post: post))),
    ));
    await tester.pump();
    return api;
  }

  testWidgets('the feed card no longer takes comments itself', (tester) async {
    await pumpCard(tester);

    expect(
        find.descendant(of: find.byType(PostCard), matching: find.byType(TextField)), findsNothing,
        reason: 'an inline composer here can only post a lesser comment than the thread can');
    expect(find.text('Post'), findsNothing);
  });

  testWidgets('the card still offers a way in, and it opens the thread ready to type',
      (tester) async {
    await pumpCard(tester);

    expect(find.text('Add a comment…'), findsOneWidget,
        reason: 'removing the composer must not remove the affordance');

    await tester.tap(find.text('Add a comment…'));
    await tester.pumpAndSettle();

    final screen = tester.widget<PostDetailScreen>(find.byType(PostDetailScreen));
    expect(screen.postId, post.id);
    expect(screen.focusComposer, isTrue,
        reason: 'tapping "Add a comment" should land on the composer, not ask for a second tap');
  });

  testWidgets('an admin can delete another member\'s check-in from the feed', (tester) async {
    await pumpCard(tester, isAdmin: true);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget,
        reason: 'the one person who acts on reports has to be able to remove what was reported');
  });

  testWidgets('a plain member gets no delete on someone else\'s check-in', (tester) async {
    await pumpCard(tester);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing,
        reason: 'the admin bypass must not become a general one');
    expect(find.text('Report'), findsOneWidget);
  });
}
