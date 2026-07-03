import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/app_state.dart';

Post _post(int id, DateTime createdAt, {String? group}) {
  final p = Post(
    id: id,
    authorId: 1,
    authorName: 'A',
    kind: 'text',
    body: 'post $id',
    createdAt: createdAt,
    likeCount: 0,
    commentCount: 0,
    likedByViewer: false,
  );
  return group == null ? p : p.withGroup(group);
}

/// The combined All-groups feed: pages merge newest-first with a stable id tie-break,
/// and every post keeps its origin group tag.
void main() {
  final t0 = DateTime.utc(2026, 7, 1, 12);

  test('mergeFeeds orders across pages by createdAt descending', () {
    final alpha = [
      _post(3, t0.add(const Duration(hours: 3)), group: 'alpha'),
      _post(1, t0.add(const Duration(hours: 1)), group: 'alpha'),
    ];
    final beta = [
      _post(4, t0.add(const Duration(hours: 4)), group: 'beta'),
      _post(2, t0.add(const Duration(hours: 2)), group: 'beta'),
    ];

    final merged = mergeFeeds([alpha, beta]);

    expect([for (final p in merged) p.id], [4, 3, 2, 1]);
    expect([for (final p in merged) p.groupId], ['beta', 'alpha', 'beta', 'alpha']);
  });

  test('mergeFeeds breaks createdAt ties on id so refreshes are stable', () {
    final a = [_post(1, t0, group: 'alpha')];
    final b = [_post(2, t0, group: 'beta')];

    expect([
      for (final p in mergeFeeds([a, b])) p.id
    ], [
      2,
      1
    ]);
    expect([
      for (final p in mergeFeeds([b, a])) p.id
    ], [
      2,
      1
    ]);
  });

  test('mergeFeeds tolerates empty pages', () {
    expect(mergeFeeds([]), isEmpty);
    expect(
        mergeFeeds([
          [],
          [_post(1, t0)]
        ]).single.id,
        1);
  });

  test('withGroup tags a post without altering its content', () {
    final p = Post(
      id: 7,
      authorId: 2,
      authorName: 'Bee',
      kind: 'image',
      body: 'hi',
      createdAt: t0,
      likeCount: 3,
      commentCount: 1,
      likedByViewer: true,
      mediaIds: const [11, 12],
      location: 'Lisbon, Portugal',
      people: const [(id: 5, name: 'Cee')],
    );
    final tagged = p.withGroup('alpha.example.com');

    expect(tagged.groupId, 'alpha.example.com');
    expect(p.groupId, isNull); // the original is untouched
    expect(tagged.id, 7);
    expect(tagged.images, [11, 12]);
    expect(tagged.location, 'Lisbon, Portugal');
    expect(tagged.peopleIds, [5]);
    expect(tagged.likedByViewer, isTrue);
  });
}
