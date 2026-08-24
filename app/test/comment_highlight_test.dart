import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/notifications/notification_route.dart';
import 'package:checkin/state/app_state.dart';

/// "Tapping a notification doesn't take me to the comment" was the report, and this is the
/// half of the fix that lives in the app: a notification names one comment, and the thread
/// has to land on THAT comment rather than on the top of the thread.
///
/// A long thread is the whole point - on a short one, scrolling to the comment section and
/// scrolling to the comment look identical, which is why this builds twenty of them.

class _FakeApi extends ApiClient {
  _FakeApi({required this.post, required this.commentsList}) : super(baseUrl: '');

  final Post post;
  final List<Comment> commentsList;

  @override
  Future<Post> getPost(int id) async => post;

  @override
  Future<List<Comment>> comments(int postId) async => commentsList;
}

void main() {
  final me = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false);
  final post = Post(
    id: 1,
    authorId: 1,
    authorName: 'Nick',
    kind: 'text',
    body: 'movie night',
    createdAt: DateTime(2026, 1, 1),
    likeCount: 0,
    commentCount: 20,
    likedByViewer: false,
    groupId: 'alpha.invalid',
  );

  // Twenty comments, so the target is well off screen when the thread opens.
  final thread = [
    for (var i = 0; i < 20; i++)
      Comment(
        id: 100 + i,
        authorId: 2,
        authorName: 'Sam',
        body: 'comment number $i',
        createdAt: DateTime(2026, 1, 1).add(Duration(minutes: i)),
      ),
  ];

  Future<void> pumpThread(WidgetTester tester, List<Comment> comments, Widget home) async {
    final account = ServerAccount(
      id: 'alpha.invalid',
      baseUrl: 'https://alpha.invalid',
      serverName: 'Alpha',
      token: 't1',
      user: me,
    );
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        contentApiProvider('alpha.invalid')
            .overrideWithValue(_FakeApi(post: post, commentsList: comments)),
      ],
      child: MaterialApp(home: home),
    ));
    await tester.pump();
    await tester.pump();
    // The scroll walks the list a screen at a time, waiting for the frame that builds the
    // next stretch, so this needs frames to run rather than a single pump.
    await tester.pumpAndSettle(const Duration(milliseconds: 20));
  }

  Future<void> pump(WidgetTester tester, Widget home) => pumpThread(tester, thread, home);

  testWidgets('a notification naming a comment scrolls that comment into view', (tester) async {
    await pump(
      tester,
      const PostDetailScreen(postId: 1, groupId: 'alpha.invalid', highlightCommentId: 117),
    );
    expect(find.text('comment number 17'), findsOneWidget,
        reason: 'the named comment must be on screen, not merely built');
  });

  testWidgets('and highlights it, so you can see which one you were sent to', (tester) async {
    await pump(
      tester,
      const PostDetailScreen(postId: 1, groupId: 'alpha.invalid', highlightCommentId: 117),
    );

    // The row's own Container is the closest one above the text; an unlit row leaves its
    // colour null rather than painting a transparent one.
    Color? tintOf(String text) => tester
        .widgetList<Container>(find.ancestor(
          of: find.text(text),
          matching: find.byType(Container),
        ))
        .first
        .color;

    expect(tintOf('comment number 17'), isNotNull,
        reason: 'the comment the notification was about should be tinted');
    expect(tintOf('comment number 16'), isNull, reason: 'only the named comment is highlighted');
  });

  testWidgets('the highlight fades, rather than staying lit forever', (tester) async {
    await pump(
      tester,
      const PostDetailScreen(postId: 1, groupId: 'alpha.invalid', highlightCommentId: 117),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    final container = tester
        .widgetList<Container>(find.ancestor(
          of: find.text('comment number 17'),
          matching: find.byType(Container),
        ))
        .first;
    expect(container.color, isNull);
  });

  testWidgets('without a named comment it falls back to the top of the thread', (tester) async {
    // What a push from a server too old to send a comment id can still manage.
    await pump(
      tester,
      const PostDetailScreen(postId: 1, groupId: 'alpha.invalid', focusComments: true),
    );
    expect(find.text('20 comments'), findsOneWidget);
    expect(find.text('comment number 17'), findsNothing,
        reason: 'nothing named a comment, so nothing should have scrolled to one');
  });

  testWidgets('opened plainly, it lands on the post', (tester) async {
    await pump(tester, const PostDetailScreen(postId: 1, groupId: 'alpha.invalid'));
    expect(find.text('movie night'), findsOneWidget);
    expect(find.text('comment number 17'), findsNothing);
  });

  testWidgets('a cross-post notification finds the comment through its copies', (tester) async {
    // A comment sent to several groups is shown once, and the merged row keeps only one
    // group's id as its own. A notification from the group whose copy did NOT win still
    // names its own id, so matching on the row's id alone would miss it and fall back to
    // the top of the thread - the exact failure this whole change is about.
    final merged = Comment(
      id: 900,
      authorId: 2,
      authorName: 'Sam',
      body: 'said it everywhere',
      createdAt: DateTime(2026, 1, 1).add(const Duration(minutes: 30)),
      groupId: 'beta.invalid',
    ).withCopies(const [
      (groupId: 'beta.invalid', commentId: 900),
      (groupId: 'alpha.invalid', commentId: 117),
    ]);

    await pumpThread(
      tester,
      [...thread.where((c) => c.id != 117), merged],
      const PostDetailScreen(postId: 1, groupId: 'alpha.invalid', highlightCommentId: 117),
    );

    expect(find.text('said it everywhere'), findsOneWidget,
        reason: 'the notification named alpha\'s copy, which is this row');
  });

  testWidgets('routeForNotification carries the comment through to the screen', (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(PostDetailScreen.routeForNotification(
              const NotificationRoute(
                groupId: 'alpha.invalid',
                postId: 1,
                commentId: 117,
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(find.text('comment number 17'), findsOneWidget,
        reason: 'the route the activity list and the push tap share must land on the '
            'comment, or only one of the two entry points actually works');
  });
}
