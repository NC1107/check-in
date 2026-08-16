import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/widgets/auth_image.dart';

/// An ApiClient whose post/comment reads are stubbed so PostDetailScreen can be driven
/// without a network - only the calls the screen actually makes are overridden.
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
    authorId: 2,
    authorName: 'Ada',
    kind: 'text',
    body: 'movie night',
    createdAt: DateTime(2026, 1, 1),
    likeCount: 0,
    commentCount: 1,
    likedByViewer: false,
    groupId: 'alpha.invalid',
  );
  final gifComment = Comment(
    id: 9,
    authorId: 3,
    authorName: 'Sam',
    body: '',
    createdAt: DateTime(2026, 1, 1),
    mediaId: 55,
  );

  Future<void> pump(
    WidgetTester tester, {
    required List<Comment> comments,
    bool gifSearch = true,
    bool commentMedia = true,
  }) async {
    final account = ServerAccount(
      id: 'alpha.invalid',
      baseUrl: 'https://alpha.invalid',
      serverName: 'Alpha',
      token: 't1',
      user: me,
      gifSearch: gifSearch,
      commentMedia: commentMedia,
    );
    final controller =
        MultiSessionController.seeded(MultiSession(groups: [account], restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        contentApiProvider('alpha.invalid')
            .overrideWithValue(_FakeApi(post: post, commentsList: comments)),
      ],
      child: const MaterialApp(home: PostDetailScreen(postId: 1, groupId: 'alpha.invalid')),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a gif-only comment (empty body) renders the gif widget, not blank space',
      (tester) async {
    await pump(tester, comments: [gifComment]);
    // The comment carries no body text, so the only thing marking its presence is the gif
    // widget - if the mediaId branch were dropped, this comment would render nothing at all.
    expect(find.byType(AuthImage), findsOneWidget);
  });

  testWidgets('a comment with a body and no media renders no gif widget', (tester) async {
    final textOnly = Comment(
      id: 10,
      authorId: 3,
      authorName: 'Sam',
      body: 'lol',
      createdAt: DateTime(2026, 1, 1),
    );
    await pump(tester, comments: [textOnly]);
    expect(find.byType(AuthImage), findsNothing);
    expect(find.text('lol'), findsOneWidget);
  });

  testWidgets('the comment gif icon appears only when the group allows commentMedia',
      (tester) async {
    await pump(tester, comments: [], gifSearch: true, commentMedia: true);
    expect(find.byIcon(Icons.gif_box_outlined), findsOneWidget);
  });

  testWidgets('the comment gif icon is hidden when the server predates commentMedia',
      (tester) async {
    await pump(tester, comments: [], gifSearch: true, commentMedia: false);
    expect(find.byIcon(Icons.gif_box_outlined), findsNothing);
  });

  testWidgets('the comment gif icon is hidden when the group has no gif search', (tester) async {
    await pump(tester, comments: [], gifSearch: false, commentMedia: true);
    expect(find.byIcon(Icons.gif_box_outlined), findsNothing);
  });
}
