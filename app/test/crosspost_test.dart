import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';

Post _post({
  required int id,
  required String group,
  String? crossPostId,
  int likes = 0,
  int comments = 0,
  bool liked = false,
  DateTime? at,
}) =>
    Post(
      id: id,
      authorId: 1,
      authorName: 'Alice',
      kind: 'text',
      body: 'hi',
      createdAt: at ?? DateTime(2026, 1, 1, 12),
      likeCount: likes,
      commentCount: comments,
      likedByViewer: liked,
      groupId: group,
      crossPostId: crossPostId,
    );

void main() {
  group('collapseCrossPosts', () {
    test('copies sharing a cross-post id collapse into one card', () {
      final posts = [
        _post(id: 42, group: 'family', crossPostId: 'x', likes: 3, comments: 2),
        _post(id: 17, group: 'climbing', crossPostId: 'x', likes: 5, comments: 1),
      ];
      final out = collapseCrossPosts(posts);
      expect(out, hasLength(1));
      final card = out.single;
      expect(card.isCrossPost, isTrue);
      expect(card.copies, hasLength(2));
      // Comment engagement sums every group's own count (see likes_test.dart for the like
      // aggregate, which needs a same-viewer correction totalComments does not).
      expect(card.totalComments, 3);
    });

    test('a post shared to only one visible group is not collapsed', () {
      // The viewer is only in "family", so they see one copy - it must render as normal.
      final out = collapseCrossPosts([
        _post(id: 42, group: 'family', crossPostId: 'x', likes: 3),
      ]);
      expect(out, hasLength(1));
      expect(out.single.isCrossPost, isFalse);
    });

    test('posts without a cross-post id pass through untouched', () {
      final out = collapseCrossPosts([
        _post(id: 1, group: 'family', likes: 1),
        _post(id: 2, group: 'climbing', likes: 2),
      ]);
      expect(out, hasLength(2));
      expect(out.every((p) => !p.isCrossPost), isTrue);
    });

    test('the newest copy represents the collapsed card', () {
      final out = collapseCrossPosts([
        _post(id: 42, group: 'family', crossPostId: 'x', at: DateTime(2026, 1, 1, 10)),
        _post(id: 17, group: 'climbing', crossPostId: 'x', at: DateTime(2026, 1, 1, 11)),
      ]);
      expect(out.single.id, 17);
      expect(out.single.groupId, 'climbing');
    });
  });

  group('mergeFeeds', () {
    test('collapses cross-posts and sorts newest first', () {
      final pages = [
        [
          _post(id: 1, group: 'family', at: DateTime(2026, 1, 1, 9)),
          _post(id: 42, group: 'family', crossPostId: 'x', at: DateTime(2026, 1, 1, 10)),
        ],
        [
          _post(id: 17, group: 'climbing', crossPostId: 'x', at: DateTime(2026, 1, 1, 11)),
        ],
      ];
      final out = mergeFeeds(pages);
      // The two cross-post copies become one; the standalone post remains: 2 cards total.
      expect(out, hasLength(2));
      // Newest first: the collapsed cross-post (repr at 11:00) leads.
      expect(out.first.isCrossPost, isTrue);
      expect(out.last.id, 1);
    });
  });
}
