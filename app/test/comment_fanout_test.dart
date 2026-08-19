import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';

/// Where a comment actually goes when a check-in was shared to several groups.
///
/// Each group is a separate server, so the fan-out is the client sending the same words to
/// each in turn. Every test here records what each group's server was really asked to store,
/// because that is the only thing that decides whether a member's words arrived.
class _FakeApi extends ApiClient {
  _FakeApi({required this.groupId, required this.post, this.commentsList = const []})
      : super(baseUrl: '');

  final String groupId;
  final Post post;
  final List<Comment> commentsList;

  /// Every comment this group's server was asked to store: body, parent, shared id.
  final received = <({String body, int? parentId, String? crossId, int postId})>[];

  @override
  Future<Post> getPost(int id) async => post;

  @override
  Future<List<Comment>> comments(int postId) async => commentsList;

  @override
  Future<Comment> addComment(int postId, String body,
      {int? parentCommentId, int? mediaId, String? crossCommentId}) async {
    received.add((body: body, parentId: parentCommentId, crossId: crossCommentId, postId: postId));
    return Comment(
      id: 900 + received.length,
      authorId: 1,
      authorName: 'Nick',
      body: body,
      createdAt: DateTime.utc(2026, 2, 1),
      parentCommentId: parentCommentId,
      crossCommentId: crossCommentId,
    );
  }
}

void main() {
  Post post(String groupId, int id) => Post(
        id: id,
        authorId: 1,
        authorName: 'Nick',
        kind: 'text',
        body: 'trip',
        createdAt: DateTime.utc(2026, 1, 1),
        likeCount: 0,
        commentCount: 0,
        likedByViewer: false,
        groupId: groupId,
      );

  final me = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false);

  ServerAccount account(String id, {required bool crossComments}) => ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't-$id',
        user: me,
        crossComments: crossComments,
        commentMedia: true,
      );

  const copies = [
    (
      groupId: 'alpha.invalid',
      postId: 1,
      likeCount: 0,
      commentCount: 0,
      sharedCommentCount: 0,
      likedByViewer: false
    ),
    (
      groupId: 'beta.invalid',
      postId: 2,
      likeCount: 0,
      commentCount: 0,
      sharedCommentCount: 0,
      likedByViewer: false
    ),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required _FakeApi alpha,
    required _FakeApi beta,
    required List<ServerAccount> accounts,
  }) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final controller =
        MultiSessionController.seeded(MultiSession(groups: accounts, restored: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        contentApiProvider('alpha.invalid').overrideWithValue(alpha),
        contentApiProvider('beta.invalid').overrideWithValue(beta),
      ],
      child: const MaterialApp(
        home: PostDetailScreen(postId: 1, groupId: 'alpha.invalid', copies: copies),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> sendComment(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a group on an older server still receives the comment, just without the id',
      (tester) async {
    // The bug this replaces: such a group was dropped from the fan-out entirely, so the
    // member's words never arrived there and nothing said so - no error, no cue, nothing.
    final alpha = _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1));
    final beta = _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2));
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: false), // host has not updated
    ]);

    await sendComment(tester, 'hello everyone');

    expect(alpha.received, hasLength(1));
    expect(beta.received, hasLength(1),
        reason: 'the older server must still get the comment - silently skipping it loses '
            'the member\'s words with no failure anywhere');
    expect(alpha.received.single.crossId, isNotNull);
    expect(beta.received.single.crossId, isNull,
        reason: 'it would reject the unknown field, so the id is withheld from it alone');
  });

  testWidgets('a comment to all groups carries one shared id everywhere it is understood',
      (tester) async {
    final alpha = _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1));
    final beta = _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2));
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: true),
    ]);

    await sendComment(tester, 'hello everyone');

    expect(alpha.received.single.crossId, isNotNull);
    expect(alpha.received.single.crossId, beta.received.single.crossId,
        reason: 'the copies only collapse - on screen and in notifications - if the id is '
            'byte-identical on every server');
    expect(alpha.received.single.postId, 1);
    expect(beta.received.single.postId, 2,
        reason: "each group must be sent its own copy's post id, never another group's");
  });

  testWidgets('replying to a shared comment reaches every group that can see it', (tester) async {
    // The gap the audit found: a shared comment collapses to one representative, so a reply
    // used to reach only the representative's group - chosen by which server answered first.
    // The other groups saw the comment and never the answer.
    Comment shared(int id, String group) => Comment(
          id: id,
          authorId: 2,
          authorName: 'Robin',
          body: 'where was this?',
          createdAt: DateTime.utc(2026, 1, 2),
          groupId: group,
          crossCommentId: 'shared-1',
        );

    final alpha = _FakeApi(
        groupId: 'alpha.invalid',
        post: post('alpha.invalid', 1),
        commentsList: [shared(10, 'alpha.invalid')]);
    final beta = _FakeApi(
        groupId: 'beta.invalid',
        post: post('beta.invalid', 2),
        commentsList: [shared(15, 'beta.invalid')]);
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: true),
    ]);

    await tester.tap(find.text('Reply').first);
    await tester.pump();
    await sendComment(tester, 'Mathias');

    expect(alpha.received, hasLength(1));
    expect(beta.received, hasLength(1),
        reason: 'both groups saw the question, both get the answer');
    expect(alpha.received.single.parentId, 10,
        reason: "each group must be given ITS OWN parent comment id - 15 means something "
            "else entirely on alpha's server, or nothing at all");
    expect(beta.received.single.parentId, 15);
  });

  testWidgets('replying to a single-group comment stays in that group', (tester) async {
    // The behaviour the founder asked for, and the one a parentCommentId forces: a reply to
    // something said in one group only can go nowhere else.
    final alpha = _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1), commentsList: [
      Comment(
        id: 10,
        authorId: 2,
        authorName: 'Robin',
        body: 'just here',
        createdAt: DateTime.utc(2026, 1, 2),
        groupId: 'alpha.invalid',
      )
    ]);
    final beta = _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2));
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: true),
    ]);

    await tester.tap(find.text('Reply').first);
    await tester.pump();
    await sendComment(tester, 'nice');

    expect(alpha.received, hasLength(1));
    expect(alpha.received.single.parentId, 10);
    expect(beta.received, isEmpty,
        reason: 'beta never held that comment, so a reply to it has nothing to attach to');
    expect(alpha.received.single.crossId, isNull, reason: 'a single target needs no shared id');
  });
}
