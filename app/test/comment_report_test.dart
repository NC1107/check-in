import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';

import 'support/comment_actions.dart';

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

  /// The menu belonging to one comment, rather than whichever one a finder reaches first -
  /// the check-in carries its own now, and so does every other comment in the thread.
  Finder menuOn(String body) => find.descendant(
        of: find.ancestor(of: find.text(body), matching: find.byType(Row)).last,
        matching: find.byIcon(Icons.more_horiz),
      );

  // Reply is the only thing that waits for a tap. Reporting has to be findable by someone
  // who has no idea a comment can be tapped at all, because there is nowhere else in a
  // thread to report a comment from.
  testWidgets('a thread offers reporting at rest, and reply only once tapped', (tester) async {
    await pump(tester);

    expect(find.byIcon(Icons.reply_outlined), findsNothing);
    expect(menuOn('nice'), findsOneWidget, reason: "Robin's comment can be reported at rest");

    await openCommentActions(tester, find.text('nice'));
    expect(find.byIcon(Icons.reply_outlined), findsOneWidget);
    expect(menuOn('nice'), findsOneWidget, reason: 'and reporting did not go anywhere');
  });

  testWidgets('your own comment can be replied to but not reported', (tester) async {
    await pump(tester);

    expect(menuOn('ha'), findsNothing, reason: 'reporting your own comment is not a thing');

    await openCommentActions(tester, find.text('ha'));
    expect(find.byIcon(Icons.reply_outlined), findsOneWidget);
    expect(menuOn('ha'), findsNothing);
  });

  // Only one reply arrow at a time, so a thread cannot fill back up with chrome.
  testWidgets('tapping another comment moves the reply arrow to it', (tester) async {
    await pump(tester);

    await openCommentActions(tester, find.text('nice'));
    await openCommentActions(tester, find.text('ha'));
    expect(find.byIcon(Icons.reply_outlined), findsOneWidget,
        reason: 'exactly one, on the comment just tapped');
  });

  testWidgets('tapping the same comment again puts the reply arrow away', (tester) async {
    await pump(tester);

    await openCommentActions(tester, find.text('nice'));
    expect(find.byIcon(Icons.reply_outlined), findsOneWidget);

    await openCommentActions(tester, find.text('nice'));
    expect(find.byIcon(Icons.reply_outlined), findsNothing);
  });

  testWidgets('opening Report shows the reason list', (tester) async {
    await pump(tester);

    await tapCommentReport(tester, find.text('nice'));

    expect(find.text('Report this comment'), findsOneWidget);
    expect(find.text('Inappropriate or offensive content'), findsOneWidget);
    expect(find.text('Harassment or bullying'), findsOneWidget);
    expect(find.text('Spam'), findsOneWidget);
    expect(find.text('False information'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
  });

  testWidgets('choosing a reason reports the right comment', (tester) async {
    final api = await pump(tester);

    await tapCommentReport(tester, find.text('nice'));
    await tester.tap(find.text('Spam'));
    await tester.pumpAndSettle();

    expect(api.reportCalls, [(20, 'Spam')],
        reason: 'must report Robin\'s comment (id 20), not the viewer\'s own');
  });
}
