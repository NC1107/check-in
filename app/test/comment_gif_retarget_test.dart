import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/features/post/post_detail_screen.dart';
import 'package:checkin/state/app_state.dart';
import 'package:checkin/theme/tokens.dart';
import 'package:checkin/widgets/auth_image.dart';

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
    (groupId: 'alpha.invalid', postId: 1, likeCount: 0, commentCount: 0, likedByViewer: false),
    (groupId: 'beta.invalid', postId: 2, likeCount: 0, commentCount: 0, likedByViewer: false),
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
          gifDownloader: (url) async => const [1, 2, 3],
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

  testWidgets('a pending gif floats free of the composer bar', (tester) async {
    final alphaApi =
        _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1), uploadedMediaId: 100);
    final betaApi =
        _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2), uploadedMediaId: 200);
    await pumpCrossPost(tester, alphaApi: alphaApi, betaApi: betaApi);
    await attachAGif(tester);

    expect(find.byType(AuthImage), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(AuthImage),
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

  testWidgets('switching the target group via the chip clears a pending gif', (tester) async {
    final alphaApi =
        _FakeApi(groupId: 'alpha.invalid', post: post('alpha.invalid', 1), uploadedMediaId: 100);
    final betaApi =
        _FakeApi(groupId: 'beta.invalid', post: post('beta.invalid', 2), uploadedMediaId: 200);
    await pumpCrossPost(tester, alphaApi: alphaApi, betaApi: betaApi);

    expect(find.byType(AuthImage), findsNothing);
    await attachAGif(tester);
    // Attached against the default target (the first copy, alpha).
    expect(alphaApi.uploadCalls, 1);
    expect(betaApi.uploadCalls, 0);
    expect(find.byType(AuthImage), findsOneWidget, reason: 'the pending gif thumbnail');

    await tester.tap(find.text('Beta'));
    await tester.pump();

    expect(find.byType(AuthImage), findsNothing,
        reason: 'a gif uploaded to alpha must not survive a retarget to beta');
  });

  testWidgets('replying to a comment on a different group clears a pending gif', (tester) async {
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
    expect(find.byType(AuthImage), findsOneWidget, reason: 'the pending gif thumbnail');

    await tester.tap(find.text('Reply'));
    await tester.pump();

    expect(find.text('Replying to Robin'), findsOneWidget);
    expect(find.byType(AuthImage), findsNothing,
        reason: 'a reply that retargets to beta must drop the gif uploaded to alpha');
  });
}
