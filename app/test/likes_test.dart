import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';

Post _post({
  required int id,
  required String group,
  String? crossPostId,
  int likes = 0,
  bool liked = false,
}) =>
    Post(
      id: id,
      authorId: 1,
      authorName: 'Alice',
      kind: 'text',
      body: 'hi',
      createdAt: DateTime(2026, 1, 1, 12),
      likeCount: likes,
      commentCount: 0,
      likedByViewer: liked,
      groupId: group,
      crossPostId: crossPostId,
    );

/// An ApiClient whose like/unlike are stubbed so LikesController can be driven without a
/// network. When [fail] is set they throw, exercising the optimistic rollback.
class _FakeApi extends ApiClient {
  _FakeApi({this.fail = false}) : super(baseUrl: '');

  final bool fail;
  int likeCalls = 0;
  int unlikeCalls = 0;

  @override
  Future<void> like(int postId) async {
    likeCalls++;
    if (fail) throw Exception('boom');
  }

  @override
  Future<void> unlike(int postId) async {
    unlikeCalls++;
    if (fail) throw Exception('boom');
  }
}

void main() {
  group('likeView', () {
    test('single post falls back to the server value when untouched', () {
      final p = _post(id: 1, group: 'a', likes: 4, liked: true);
      final v = likeView(p, const {});
      expect(v.liked, isTrue);
      expect(v.likes, 4);
    });

    test('an overlay like on an unliked post adds one', () {
      final p = _post(id: 1, group: 'a', likes: 4, liked: false);
      final v = likeView(p, const {'a:1': true});
      expect(v.liked, isTrue);
      expect(v.likes, 5);
    });

    test('an overlay unlike on a server-liked post removes one', () {
      final p = _post(id: 1, group: 'a', likes: 4, liked: true);
      final v = likeView(p, const {'a:1': false});
      expect(v.liked, isFalse);
      expect(v.likes, 3);
    });

    test('the delta survives a concurrent like by someone else', () {
      // The viewer liked (overlay true). Later the server count rose to 10 from other
      // members; the view should read 10, not a stale local number.
      final p = _post(id: 1, group: 'a', likes: 10, liked: true);
      final v = likeView(p, const {'a:1': true});
      expect(v.likes, 10);
    });

    group('cross-post', () {
      Post collapsed({bool aLiked = false, bool bLiked = false}) => collapseCrossPosts([
            _post(id: 1, group: 'a', crossPostId: 'x', likes: 3, liked: aLiked),
            _post(id: 2, group: 'b', crossPostId: 'x', likes: 5, liked: bLiked),
          ]).single;

      test('reads as liked only when every copy is liked, and sums counts', () {
        final v = likeView(collapsed(aLiked: true, bLiked: false), const {});
        expect(v.liked, isFalse);
        expect(v.likes, 8);
      });

      test(
          'an overlay that likes the remaining copy flips it fully liked, without double '
          'counting the viewer', () {
        final v = likeView(collapsed(aLiked: true, bLiked: false), const {'b:2': true});
        expect(v.liked, isTrue);
        // Raw sum would be 3 (a, already liked) + 6 (b: 5 + 1) = 9, but the viewer is one
        // person liking across both copies of the same cross-post, not two - so their
        // second appearance is subtracted: 9 - 1 = 8.
        expect(v.likes, 8);
      });

      // The reported bug: someone posts to two groups, a viewer who is in both likes it
      // once, and the count read 2 instead of 1. Server state already has the viewer as a
      // liker on every copy here (no overlay needed) - exactly what happens once the toggle
      // in _toggleLike, which likes every copy the viewer can reach, has landed everywhere.
      test('liking every copy of a cross-post only counts the viewer once', () {
        final v = likeView(collapsed(aLiked: true, bLiked: true), const {});
        expect(v.liked, isTrue);
        // Raw sum would be 3 + 5 = 8 (the viewer counted once per copy = twice); the real
        // distinct likers are 2 others on a, 4 others on b, plus the viewer once = 7.
        expect(v.likes, 7);
      });

      test('no correction applies when the viewer has not liked either copy', () {
        final v = likeView(collapsed(aLiked: false, bLiked: false), const {});
        expect(v.likes, 8); // 3 + 5, unchanged - nothing of the viewer's own to double count.
      });
    });
  });

  group('LikesController', () {
    test('keeps the optimistic like on success', () async {
      final api = _FakeApi();
      final container = ProviderContainer(overrides: [
        contentApiProvider('g').overrideWithValue(api),
      ]);
      addTearDown(container.dispose);
      await container.read(likesProvider.notifier).setLiked('g', 1, true);
      expect(api.likeCalls, 1);
      expect(container.read(likesProvider)['g:1'], isTrue);
    });

    test('rolls the entry back when the request fails', () async {
      final api = _FakeApi(fail: true);
      final container = ProviderContainer(overrides: [
        contentApiProvider('g').overrideWithValue(api),
      ]);
      addTearDown(container.dispose);
      await container.read(likesProvider.notifier).setLiked('g', 1, true);
      expect(api.likeCalls, 1);
      // No override remains, so likeView falls back to the server value again.
      expect(container.read(likesProvider).containsKey('g:1'), isFalse);
    });

    test('a no-op toggle to the current state does not call the server', () async {
      final api = _FakeApi();
      final container = ProviderContainer(overrides: [
        contentApiProvider('g').overrideWithValue(api),
      ]);
      addTearDown(container.dispose);
      await container.read(likesProvider.notifier).setLiked('g', 1, true);
      await container.read(likesProvider.notifier).setLiked('g', 1, true);
      expect(api.likeCalls, 1);
    });
  });

  group('Comment reply model', () {
    test('parses parentCommentId from JSON and preserves it through withGroup', () {
      final c = Comment.fromJson({
        'id': 7,
        'userId': 2,
        'authorName': 'Bob',
        'body': 'nice',
        'createdAt': '2026-01-01T12:00:00Z',
        'parentCommentId': 3,
      });
      expect(c.parentCommentId, 3);
      expect(c.withGroup('a').parentCommentId, 3);
    });

    test('a top-level comment has a null parentCommentId', () {
      final c = Comment.fromJson({
        'id': 7,
        'userId': 2,
        'authorName': 'Bob',
        'body': 'nice',
        'createdAt': '2026-01-01T12:00:00Z',
      });
      expect(c.parentCommentId, isNull);
    });
  });
}
