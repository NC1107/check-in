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

  /// Every comment this group's server was asked to store.
  final received = <({String body, int? parentId, String? crossId, int postId, int? mediaId})>[];

  /// Gif bytes this group's server was asked to re-host. Media ids are per-server, so a
  /// comment carrying a gif has to upload it to each server it is sent to.
  int uploadCalls = 0;

  /// The media id THIS server hands back - deliberately different per group, so a comment
  /// storing another group's id is visible rather than coincidentally right.
  int get uploadedMediaId => groupId == 'alpha.invalid' ? 111 : 222;

  @override
  Future<int> uploadImageBytes(List<int> bytes, {String filename = 'upload.jpg'}) async {
    uploadCalls++;
    return uploadedMediaId;
  }

  @override
  Future<GifSearchPage> gifSearch({String query = '', int page = 1}) async => GifSearchPage(
        gifs: [
          GifResult(
            id: '$groupId-gif',
            title: 'pick',
            previewUrl: 'https://static.klipy.invalid/$groupId.webp',
            previewWidth: 100,
            previewHeight: 100,
            gifUrl: 'https://static.klipy.invalid/$groupId.gif',
            width: 100,
            height: 100,
          ),
        ],
        hasNext: false,
      );

  @override
  Future<Post> getPost(int id) async => post;

  @override
  Future<List<Comment>> comments(int postId) async => commentsList;

  /// When set, this group's server refuses every comment - a partial fan-out failure.
  bool failComments = false;

  @override
  Future<Comment> addComment(int postId, String body,
      {int? parentCommentId, int? mediaId, String? crossCommentId}) async {
    if (failComments) throw Exception('server down');
    received.add((
      body: body,
      parentId: parentCommentId,
      crossId: crossCommentId,
      postId: postId,
      mediaId: mediaId
    ));
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

/// A valid 1x1 transparent GIF - the smallest thing that actually decodes.
final _onePixelGif = <int>[
  71,
  73,
  70,
  56,
  57,
  97,
  1,
  0,
  1,
  0,
  128,
  0,
  0,
  0,
  0,
  0,
  255,
  255,
  255,
  33,
  249,
  4,
  1,
  0,
  0,
  0,
  0,
  44,
  0,
  0,
  0,
  0,
  1,
  0,
  1,
  0,
  0,
  2,
  1,
  68,
  0,
  59
];

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

  ServerAccount account(String id, {required bool crossComments, bool commentMedia = true}) =>
      ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: 't-$id',
        user: me,
        crossComments: crossComments,
        commentMedia: commentMedia,
        gifSearch: true,
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
      child: MaterialApp(
        home: PostDetailScreen(
          postId: 1,
          groupId: 'alpha.invalid',
          copies: copies,
          gifDownloader: (url) async => _onePixelGif,
        ),
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

  testWidgets('a gif is re-hosted on every server the comment goes to', (tester) async {
    // Media ids are per-server. A comment carrying one group's media id to another group's
    // server points at whatever unrelated row happens to hold that number there - so the
    // gif has to be uploaded separately to each, and each comment must carry the id THAT
    // server issued. This is the whole reason the gif is staged as bytes rather than as an
    // already-uploaded id.
    final alpha = _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1));
    final beta = _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2));
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: true),
    ]);

    // Pick a gif, then send with no text at all - a gif-only comment is allowed.
    await tester.tap(find.byIcon(Icons.gif_box_outlined));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byType(Image).first);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(alpha.uploadCalls, 1, reason: 'the gif must be re-hosted on alpha');
    expect(beta.uploadCalls, 1, reason: 'and separately on beta');
    expect(alpha.received.single.mediaId, 111,
        reason: "alpha's comment must carry the id alpha issued");
    expect(beta.received.single.mediaId, 222,
        reason: "beta's comment must carry BETA's id - 111 means something else on its server");
  });

  testWidgets('a gif never costs a group the comment text itself', (tester) async {
    // A server predating comment media rejects an unknown mediaId field, and that rejection
    // fails the WHOLE request - so attaching a gif would cost that group the words too. It
    // would happily have taken the text on its own.
    //
    // mediaId therefore has to be withheld per target exactly as the shared id already is:
    // that group gets the comment without the picture, rather than nothing at all.
    final alpha = _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1));
    final beta = _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2));
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: true, commentMedia: false),
    ]);

    await tester.tap(find.byIcon(Icons.gif_box_outlined));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byType(Image).first);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.enterText(find.byType(TextField).last, 'look at this');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(alpha.received.single.mediaId, isNotNull, reason: 'alpha can take the gif');
    expect(beta.received, hasLength(1),
        reason: "beta must still receive the comment - losing a member's words because a "
            'picture was attached is the worst possible trade');
    expect(beta.received.single.mediaId, isNull,
        reason: 'the gif is withheld from the server that would reject the field');
    expect(beta.received.single.body, 'look at this');
    expect(beta.uploadCalls, 0, reason: 'and not uploaded there in the first place');
  });

  testWidgets('a partial failure names how many groups missed out', (tester) async {
    // Silence here would leave the member believing every group had seen it. The count is
    // stated rather than assumed: saying "1 group" when two failed is its own small lie.
    final alpha = _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1));
    final beta = _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2))
      ..failComments = true;
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: true),
    ]);

    await sendComment(tester, 'did everyone get this');

    expect(alpha.received, hasLength(1));
    expect(find.textContaining("didn't get it"), findsOneWidget,
        reason: 'a group that refused the comment has to be surfaced, not swallowed');
    expect(find.textContaining('1 group'), findsOneWidget);
  });

  testWidgets('cancelling a reply releases the group it pinned', (tester) async {
    // Starting a reply pins the target to the parent's group. Cancelling used to leave that
    // pin in place, so the next ordinary comment silently went to that one group instead of
    // all of them - with the picker showing the truth, but easy to miss.
    final alpha = _FakeApi(
      groupId: 'alpha.invalid',
      post: post('alpha.invalid', 1),
      commentsList: [
        Comment(
          id: 10,
          authorId: 2,
          authorName: 'Robin',
          body: 'just here',
          createdAt: DateTime.utc(2026, 1, 2),
          groupId: 'alpha.invalid',
        )
      ],
    );
    final beta = _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2));
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: true),
    ]);

    await tester.tap(find.text('Reply').first);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close).last); // cancel the reply
    await tester.pump();

    await sendComment(tester, 'ordinary comment');

    expect(alpha.received, hasLength(1));
    expect(beta.received, hasLength(1),
        reason: 'after cancelling, the next comment must go to every group again rather '
            'than staying pinned to the one that was being replied to');
    expect(alpha.received.single.parentId, isNull, reason: 'and it is not still a reply');
  });

  testWidgets('"Replying to X" survives a parent that was collapsed away', (tester) async {
    // A shared comment shows as ONE representative, but a reply written by someone who only
    // sees group B points at B's copy - which is not the representative. Matching on the
    // representative's id alone dropped the label, so a merged thread showed a reply with no
    // indication of what it answered, while the parent sat visible right above it.
    Comment sharedParent(int id, String group) => Comment(
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
      commentsList: [sharedParent(10, 'alpha.invalid')],
    );
    final beta = _FakeApi(
      groupId: 'beta.invalid',
      post: post('beta.invalid', 2),
      commentsList: [
        sharedParent(15, 'beta.invalid'),
        // Written in beta by someone who never saw alpha, so it answers BETA's copy (15).
        // Collapsing keeps alpha's copy (10) as the representative and drops 15.
        Comment(
          id: 16,
          authorId: 3,
          authorName: 'Sam',
          body: 'Mathias',
          createdAt: DateTime.utc(2026, 1, 3),
          groupId: 'beta.invalid',
          parentCommentId: 15,
        ),
      ],
    );
    await pump(tester, alpha: alpha, beta: beta, accounts: [
      account('alpha.invalid', crossComments: true),
      account('beta.invalid', crossComments: true),
    ]);

    expect(find.text('Mathias'), findsOneWidget, reason: 'the reply itself is in the thread');
    expect(find.textContaining('Replying to Robin'), findsOneWidget,
        reason: 'its parent is visible in the merged thread under a different id, so the '
            'label must resolve through the collapsed copies rather than vanish');
  });
}
