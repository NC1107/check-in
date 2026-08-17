import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';

/// A group-scoped ApiClient stub that answers a fixed thread and records every
/// reportComment call, so a test can assert the exact (commentId, reason) sent.
class _FakeApi extends ApiClient {
  _FakeApi({required this.post, required this.commentsList}) : super(baseUrl: '');

  final Post post;
  final List<Comment> commentsList;
  final reportCalls = <(int commentId, String reason)>[];

  @override
  Future<Post> getPost(int id) async => post;

  @override
  Future<List<Comment>> comments(int postId) async => commentsList;

  @override
  Future<void> reportComment(int commentId, String reason) async {
    reportCalls.add((commentId, reason));
  }
}

/// Comment reporting (Apple Guideline 1.2's flag-objectionable-content requirement) needs a
/// UI affordance the viewer can actually reach, on someone else's comment but never their
/// own, that opens the shared reason sheet and submits the exact comment id.
void main() {
  final me = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false);
  final account = ServerAccount(
    id: 'alpha.invalid',
    baseUrl: 'https://alpha.invalid',
    serverName: 'Alpha',
    token: 't1',
    user: me,
  );
  final post = Post(
    id: 5,
    authorId: 9,
    authorName: 'Ridgeway Family',
    kind: 'text',
    body: 'movie night',
    createdAt: DateTime(2026, 1, 1),
    likeCount: 0,
    commentCount: 2,
    likedByViewer: false,
    groupId: 'alpha.invalid',
  );

  // One comment authored by the viewer (id 1), one by someone else (id 5).
  final ownComment =
      Comment(id: 10, authorId: 1, authorName: 'Nick', body: 'ha', createdAt: DateTime(2026, 1, 1));
  final othersComment = Comment(
      id: 20, authorId: 5, authorName: 'Robin', body: 'nice', createdAt: DateTime(2026, 1, 1));

  Future<_FakeApi> pump(WidgetTester tester) async {
    final api = _FakeApi(post: post, commentsList: [ownComment, othersComment]);
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        contentApiProvider('alpha.invalid').overrideWithValue(api),
      ],
      child: const MaterialApp(
        home: PostDetailScreen(postId: 5, groupId: 'alpha.invalid'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return api;
  }

  testWidgets('Report appears on someone else\'s comment but not on your own', (tester) async {
    await pump(tester);

    // Exactly one comment (Robin's) offers Report; the viewer's own (Nick's) does not.
    expect(find.text('Report'), findsOneWidget);
    // Both Reply links are still there - Report is additive, not a replacement.
    expect(find.text('Reply'), findsNWidgets(2));
  });

  testWidgets('opening Report shows the reason list', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();

    expect(find.text('Report this comment'), findsOneWidget);
    expect(find.text('Inappropriate or offensive content'), findsOneWidget);
    expect(find.text('Harassment or bullying'), findsOneWidget);
    expect(find.text('Spam'), findsOneWidget);
    expect(find.text('False information'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
  });

  testWidgets('choosing a reason reports the right comment', (tester) async {
    final api = await pump(tester);

    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam'));
    await tester.pumpAndSettle();

    expect(api.reportCalls, [(20, 'Spam')],
        reason: 'must report Robin\'s comment (id 20), not the viewer\'s own');
  });
}
