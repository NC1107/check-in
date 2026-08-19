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

  group('collapsing keeps every copy addressable', () {
    // A comment id means something on exactly one server. Collapsing used to keep only the
    // representative and drop the rest, which left a shared comment addressable in one group
    // only - so a reply to it could reach whichever server merely happened to answer first.
    test('the representative carries one copy per group', () {
      final collapsed = collapseCrossComments([
        comment(10, crossCommentId: 'shared', groupId: 'a', minute: 1),
        comment(15, crossCommentId: 'shared', groupId: 'b', minute: 2),
        comment(21, crossCommentId: 'shared', groupId: 'c', minute: 3),
      ]);

      expect(collapsed, hasLength(1));
      final only = collapsed.single;
      expect(only.isShared, isTrue);
      expect(only.copies.map((c) => '${c.groupId}:${c.commentId}'),
          containsAll(['a:10', 'b:15', 'c:21']),
          reason: 'each group must keep the id its own server issued');
    });

    test('an ordinary single-group comment is not marked shared', () {
      final collapsed = collapseCrossComments([comment(3, groupId: 'a')]);
      expect(collapsed.single.isShared, isFalse);
      expect(collapsed.single.copies, isEmpty);
    });

    test('a shared comment reaching only one group is not treated as shared', () {
      // A fan-out where every other leg failed. There is one place to reply, so it must
      // behave exactly like an ordinary comment rather than claiming to span groups.
      final collapsed = collapseCrossComments([
        comment(10, crossCommentId: 'shared', groupId: 'a'),
      ]);
      expect(collapsed.single.isShared, isFalse);
    });
  });

  group('the comment count never claims more than exists', () {
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

    // The property that actually matters. The badge is an estimate assembled from counts
    // alone - no copy knows which shared comments the others hold - so exactness is not
    // available. What must never happen is the badge promising comments that do not exist:
    // a member tapping "5 comments" and finding four has been lied to, whereas finding six
    // is merely a pleasant surprise.
    test('a known undercount is pinned, not glossed over', () {
      // Three comments, each of which reached two of the three groups (a different one
      // missed each time - a group that bounces intermittently). Three distinct comments
      // exist, and the badge says TWO.
      //
      // That gap cannot be closed from counts alone: every copy reports "2 of mine are
      // shared" and none of them knows WHICH, so no arithmetic over these six numbers can
      // recover the answer. Closing it would mean each server returning the shared ids
      // themselves for the client to union, which is a lot of payload on every feed card to
      // correct a badge in a case that needs alternating failures to occur at all.
      //
      // So the exact value is asserted rather than bounded. A loose bound here would pass
      // just as happily on 2 as on 3 and quietly hide the very thing this documents; if the
      // arithmetic ever changes, this should fail and be reconsidered on purpose.
      final post = crossPost([
        copy('a', comments: 2, shared: 2),
        copy('b', comments: 2, shared: 2),
        copy('c', comments: 2, shared: 2),
      ]);
      expect(post.totalComments, 2, reason: 'the true distinct total is 3 - see above');
      expect(post.totalComments, lessThanOrEqualTo(3),
          reason: 'it must never round the other way and promise comments that do not exist');
    });

    test('it is exact when every shared comment reached every group', () {
      // The ordinary case, and the one the whole feature is built for.
      final post = crossPost([
        copy('a', comments: 4, shared: 2), // 2 group-only + 2 shared
        copy('b', comments: 3, shared: 2), // 1 group-only + 2 shared
      ]);
      expect(post.totalComments, 5);
    });

    test('a group that has not been reached at all never inflates the total', () {
      final post = crossPost([
        copy('a', comments: 3, shared: 3),
        copy('b', comments: 0, shared: 0),
      ]);
      expect(post.totalComments, 3);
    });

    test('the merged total is never below what a single group already shows', () {
      // The lower bound that is actually observable by a member: someone in group B alone
      // sees B's own comment count. If joining group A made that number go DOWN, the merged
      // view would be visibly claiming comments had disappeared.
      for (final copies in [
        [copy('a', comments: 2, shared: 2), copy('b', comments: 7, shared: 2)],
        [copy('a', comments: 9, shared: 0), copy('b', comments: 1, shared: 1)],
        [copy('a', comments: 0, shared: 0), copy('b', comments: 4, shared: 4)],
      ]) {
        final largestSingleGroup =
            copies.fold(0, (m, c) => c.commentCount > m ? c.commentCount : m);
        expect(crossPost(copies).totalComments, greaterThanOrEqualTo(largestSingleGroup),
            reason: 'merging groups must never make the count smaller than one group alone');
      }
    });
  });
}
