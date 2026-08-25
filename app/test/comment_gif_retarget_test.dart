import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/theme/tokens.dart';

import 'support/comment_actions.dart';

/// A group-scoped ApiClient stub: getPost/comments answer this group's own thread, gifSearch
/// hands back one canned result, and uploadImageBytes records that this group's server (not
/// some other group's) is the one that actually received the upload.
class _FakeApi extends ApiClient {
  _FakeApi({
    required this.groupId,
    required this.post,
    this.commentsList = const [],
    required this.uploadedMediaId,
  }) : super(baseUrl: '');

  final String groupId;
  final Post post;
  final List<Comment> commentsList;
  final int uploadedMediaId;
  int uploadCalls = 0;

  @override
  Future<Post> getPost(int id) async => post;

  @override
  Future<List<Comment>> comments(int postId) async => commentsList;

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
  Future<int> uploadImageBytes(List<int> bytes, {String filename = 'upload.jpg'}) async {
    uploadCalls++;
    return uploadedMediaId;
  }
}

/// The reported bug: a gif is attached while one cross-post target is active, the target is
/// then switched (group chip, or a reply that retargets to a different group's comment),
/// and the stale mediaId - which only means something on the *first* group's server - must
/// not silently carry over to the new target. Media ids are only unique per server (see
/// AuthImage's own doc comment), so leaking one across groups is either a broken thumbnail
/// or, worse, an id collision attaching the wrong media entirely.
/// A valid 1x1 transparent GIF - the smallest thing Image.memory will actually decode.
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
  final me = User(id: 1, name: 'Nick', phone: '+15550001111', isAdmin: false);

  Post post(String groupId, int postId) => Post(
        id: postId,
        authorId: 2,
        authorName: 'Ada',
        kind: 'text',
        body: 'movie night',
        createdAt: DateTime(2026, 1, 1),
        likeCount: 0,
        commentCount: 0,
        sharedCommentCount: 0,
        likedByViewer: false,
        groupId: groupId,
      );

  ServerAccount account(String id, String name) => ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: name,
        token: 't-$id',
        user: me,
        gifSearch: true,
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

  Future<void> pumpCrossPost(
    WidgetTester tester, {
    required _FakeApi alphaApi,
    required _FakeApi betaApi,
  }) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = MultiSessionController.seeded(MultiSession(
      groups: [account('alpha.invalid', 'Alpha'), account('beta.invalid', 'Beta')],
      restored: true,
    ));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        multiSessionProvider.overrideWith(() => controller),
        contentApiProvider('alpha.invalid').overrideWithValue(alphaApi),
        contentApiProvider('beta.invalid').overrideWithValue(betaApi),
      ],
      child: MaterialApp(
        home: PostDetailScreen(
          postId: 1,
          groupId: 'alpha.invalid',
          copies: copies,
          // No network: the download step is stubbed the same way search and upload are.
          // Real (if tiny) gif bytes rather than three arbitrary numbers - the staged gif is
          // now decoded locally for its preview, so undecodable filler would only ever
          // exercise the error path.
          gifDownloader: (url) async => _onePixelGif,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  // Bounded pumps rather than pumpAndSettle: the gif tiles are real Image.network widgets
  // against an unresolvable host and never let "no frames scheduled" become true on their own.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Opens the comment gif picker and taps its one tile, landing the pick back in the
  /// composer - the same path a member takes on device.
  Future<void> attachAGif(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.gif_box_outlined));
    await settle(tester);
    await tester.tap(find.byType(Image).first);
    await settle(tester);
  }

  /// The staged gif's own preview. It is rendered straight from the picked bytes now - the
  /// gif is not uploaded anywhere until send, precisely so it can go to several servers -
  /// so it is a memory image rather than an AuthImage fetched back from one of them.
  Finder pendingGifThumb() => find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage);

  testWidgets('a pending gif floats free of the composer bar', (tester) async {
    final alphaApi =
        _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1), uploadedMediaId: 100);
    final betaApi =
        _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2), uploadedMediaId: 200);
    await pumpCrossPost(tester, alphaApi: alphaApi, betaApi: betaApi);
    await attachAGif(tester);

    expect(pendingGifThumb(), findsOneWidget);
    expect(
      find.ancestor(
        of: pendingGifThumb(),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == kBgMain),
      ),
      findsNothing,
      reason:
          'the thumbnail sits outside the bar surface, so no full-width panel appears behind it',
    );
  });

  testWidgets('a pending gif survives switching the target group', (tester) async {
    final alphaApi =
        _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1), uploadedMediaId: 100);
    final betaApi =
        _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2), uploadedMediaId: 200);
    await pumpCrossPost(tester, alphaApi: alphaApi, betaApi: betaApi);

    expect(pendingGifThumb(), findsNothing);
    await attachAGif(tester);
    // Nothing is uploaded at pick time any more: the gif is staged as bytes so it can be
    // re-hosted on whichever servers the comment actually goes to.
    expect(alphaApi.uploadCalls, 0);
    expect(betaApi.uploadCalls, 0);
    expect(pendingGifThumb(), findsOneWidget, reason: 'the pending gif thumbnail');

    await tester.tap(find.text('Beta'));
    await tester.pump();

    // The old behaviour dropped it here, because the id belonged to alpha's server and
    // meant nothing on beta's. Bytes belong to no server, so there is nothing to drop.
    expect(pendingGifThumb(), findsOneWidget,
        reason: 'a staged gif is server-agnostic and must survive a retarget');
  });

  testWidgets('replying to a comment on a different group keeps a pending gif', (tester) async {
    final alphaApi =
        _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1), uploadedMediaId: 100);
    final betaApi = _FakeApi(
      groupId: 'beta.invalid',
      post: post('beta.invalid', 2),
      uploadedMediaId: 200,
      commentsList: [
        Comment(
            id: 20,
            authorId: 5,
            authorName: 'Robin',
            body: 'nice',
            createdAt: DateTime(2026, 1, 1)),
      ],
    );
    await pumpCrossPost(tester, alphaApi: alphaApi, betaApi: betaApi);

    await attachAGif(tester);
    expect(pendingGifThumb(), findsOneWidget, reason: 'the pending gif thumbnail');

    await tapCommentReply(tester, find.text('nice').first);

    expect(find.text('Replying to Robin'), findsOneWidget);
    expect(pendingGifThumb(), findsOneWidget,
        reason: 'the staged gif belongs to no server, so pinning the reply to beta keeps it');
  });
}
