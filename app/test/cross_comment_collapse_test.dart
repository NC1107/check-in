import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';

/// One comment sent to every group holding a copy of the same cross-posted check-in.
///
/// Each group is a separate server, so the copies arrive as separate rows with separate ids
/// and no knowledge of each other. Only the client-generated shared id ties them together,
/// and collapsing on it is what stops the author being shown their own comment three times
/// and a member of two groups being shown the same sentence twice.
void main() {
  Comment comment(
    int id, {
    String? crossCommentId,
    String? groupId,
    String body = 'hello',
    int authorId = 1,
    int minute = 0,
  }) =>
      Comment(
        id: id,
        authorId: authorId,
        authorName: 'Nick',
        body: body,
        createdAt: DateTime.utc(2026, 1, 1, 12, minute),
        groupId: groupId,
        crossCommentId: crossCommentId,
      );

  test('copies of one comment collapse to a single entry', () {
    final collapsed = collapseCrossComments([
      comment(1, crossCommentId: 'shared', groupId: 'a', minute: 0),
      comment(2, crossCommentId: 'shared', groupId: 'b', minute: 0),
      comment(3, crossCommentId: 'shared', groupId: 'c', minute: 0),
    ]);

    expect(collapsed, hasLength(1));
    expect(collapsed.single.body, 'hello');
  });

  test('the earliest copy represents the group', () {
    // Not the newest: the copies are one thing said in one action, so the first to land is
    // the closest to when it was actually said, and picking it keeps a merged thread's
    // ordering stable rather than letting a slow server shuffle it later than it belongs.
    final collapsed = collapseCrossComments([
      comment(2, crossCommentId: 'shared', groupId: 'b', minute: 9),
      comment(1, crossCommentId: 'shared', groupId: 'a', minute: 1),
    ]);

    expect(collapsed.single.id, 1);
    expect(collapsed.single.groupId, 'a');
  });

  test('comments with no shared id are left alone', () {
    // Every comment on a single-group post, and every comment made before this existed.
    final collapsed = collapseCrossComments([
      comment(1, groupId: 'a', body: 'one'),
      comment(2, groupId: 'a', body: 'two', minute: 1),
    ]);

    expect(collapsed.map((c) => c.body), ['one', 'two']);
  });

  test('two different comments are never merged just for sharing a thread', () {
    final collapsed = collapseCrossComments([
      comment(1, crossCommentId: 'first', groupId: 'a', body: 'one'),
      comment(2, crossCommentId: 'second', groupId: 'a', body: 'two', minute: 1),
    ]);

    expect(collapsed.map((c) => c.body), ['one', 'two']);
  });

  test('two people saying the same word stay two comments', () {
    // The shared id is random per send, never derived from the text - otherwise this would
    // silently delete somebody's contribution.
    final collapsed = collapseCrossComments([
      comment(1, crossCommentId: 'nick-said-it', groupId: 'a', authorId: 1, body: 'ha'),
      comment(2, crossCommentId: 'robin-said-it', groupId: 'a', authorId: 2, body: 'ha'),
    ]);

    expect(collapsed, hasLength(2));
  });

  test('a collapsed thread stays in chronological order', () {
    final collapsed = collapseCrossComments([
      comment(3, groupId: 'a', body: 'third', minute: 30),
      comment(1, crossCommentId: 'shared', groupId: 'b', body: 'first', minute: 10),
      comment(2, groupId: 'a', body: 'second', minute: 20),
      comment(4, crossCommentId: 'shared', groupId: 'a', body: 'first', minute: 11),
    ]);

    expect(collapsed.map((c) => c.body), ['first', 'second', 'third']);
  });

  test('an empty shared id is treated as no id at all', () {
    // A blank string reaching here would otherwise gather every unrelated comment carrying
    // one into a single entry, hiding all but the first.
    final collapsed = collapseCrossComments([
      comment(1, crossCommentId: '', groupId: 'a', body: 'one'),
      comment(2, crossCommentId: '', groupId: 'a', body: 'two', minute: 1),
    ]);

    expect(collapsed.map((c) => c.body), ['one', 'two']);
  });

  test('an empty thread stays empty', () {
    expect(collapseCrossComments(const []), isEmpty);
  });

  group('the comment count on a collapsed card', () {
    Post crossPost(List<PostCopy> copies) => Post(
          id: 1,
          authorId: 1,
          authorName: 'Nick',
          kind: 'text',
          body: 'hi',
          createdAt: DateTime.utc(2026, 1, 1),
          likeCount: 0,
          commentCount: copies.first.commentCount,
          likedByViewer: false,
        ).withCopies(copies);

    PostCopy copy(String g, {required int comments, required int shared}) => (
          groupId: g,
          postId: 1,
          likeCount: 0,
          commentCount: comments,
          sharedCommentCount: shared,
          likedByViewer: false,
        );

    test('a comment sent to every group is counted once, not once per group', () {
      // The whole point of item 2: one thing said once must not read as three comments.
      final post = crossPost([
        copy('a', comments: 1, shared: 1),
        copy('b', comments: 1, shared: 1),
        copy('c', comments: 1, shared: 1),
      ]);
      expect(post.totalComments, 1);
    });

    test('group-only comments still add up across groups', () {
      // Someone replying in just one group is a real, separate comment everywhere else
      // cannot see - it has to keep counting.
      final post = crossPost([
        copy('a', comments: 3, shared: 1), // 2 group-only + the shared one
        copy('b', comments: 2, shared: 1), // 1 group-only + the shared one
      ]);
      expect(post.totalComments, 4);
    });

    test('a partly failed fan-out reports what was actually said', () {
      // The comment reached two groups and not the third. Taking the largest shared figure
      // counts it once rather than dropping it to the unluckiest server's view.
      final post = crossPost([
        copy('a', comments: 2, shared: 2),
        copy('b', comments: 2, shared: 2),
        copy('c', comments: 0, shared: 0),
      ]);
      expect(post.totalComments, 2);
    });

    test('with nothing shared it is still a plain sum', () {
      // Every comment made before this feature existed, and every one deliberately sent to
      // a single group.
      final post = crossPost([
        copy('a', comments: 2, shared: 0),
        copy('b', comments: 3, shared: 0),
      ]);
      expect(post.totalComments, 5);
    });

    test('a server predating the field contributes its comments as group-only', () {
      // sharedCommentCount defaults to 0 there, which is correct for it: such a server has
      // no shared comments to report.
      final post = crossPost([
        copy('a', comments: 2, shared: 1),
        copy('old', comments: 4, shared: 0),
      ]);
      // One group-only in a, four in old, plus the shared one counted once.
      expect(post.totalComments, 6);
    });
  });
}
