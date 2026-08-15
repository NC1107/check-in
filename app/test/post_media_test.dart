import 'dart:convert';

import 'package:checkin/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The client half of the media wire-format pair. Its twin is
/// `TestPostMediaWireFormat` in server/internal/db/postmedia_test.go, which pins the same
/// literal from the marshalling end: a field renamed or retyped on either side fails the
/// pair here rather than shipping a feed the app renders as broken images.
void main() {
  test('parses the media array the server pins in TestPostMediaWireFormat', () {
    const wire = '[{"id":7,"mime":"image/jpeg","width":1600,"height":1200,"durationMs":0,'
        '"hasPoster":false},{"id":8,"mime":"video/mp4","width":1080,"height":1920,'
        '"durationMs":9500,"hasPoster":true}]';

    final media = (jsonDecode(wire) as List)
        .map((e) => PostMedia.fromJson(e as Map<String, dynamic>))
        .toList();

    expect(media.length, 2);

    expect(media[0].id, 7);
    expect(media[0].mime, 'image/jpeg');
    expect(media[0].width, 1600);
    expect(media[0].height, 1200);
    expect(media[0].durationMs, 0);
    expect(media[0].hasPoster, isFalse);
    expect(media[0].isImage, isTrue);
    expect(media[0].isVideo, isFalse);

    expect(media[1].id, 8);
    expect(media[1].mime, 'video/mp4');
    expect(media[1].width, 1080);
    expect(media[1].height, 1920);
    expect(media[1].durationMs, 9500);
    expect(media[1].hasPoster, isTrue);
    expect(media[1].isVideo, isTrue);
    expect(media[1].isImage, isFalse);
  });

  test('a post carries its attachments typed and in order', () {
    final post = Post.fromJson({
      'id': 1,
      'authorId': 2,
      'kind': 'video',
      'createdAt': '2026-08-14T09:00:00Z',
      'mediaIds': [7, 8],
      'media': [
        {'id': 7, 'mime': 'image/gif', 'width': 400, 'height': 400},
        {'id': 8, 'mime': 'video/mp4', 'width': 1080, 'height': 1920, 'durationMs': 9500},
      ],
    });

    expect([for (final m in post.media) m.id], [7, 8]);
    expect(post.media[0].isGif, isTrue);
    expect(post.media[1].isVideo, isTrue);
    // mediaIds keeps its own meaning: published clients read only that list.
    expect(post.mediaIds, [7, 8]);
    expect(post.images, [7, 8]);
  });

  test('an old server sending only mediaIds still yields image attachments', () {
    final post = Post.fromJson({
      'id': 1,
      'authorId': 2,
      'kind': 'image',
      'createdAt': '2026-08-14T09:00:00Z',
      'mediaIds': [3, 4],
    });

    expect([for (final m in post.media) m.id], [3, 4]);
    expect(post.media.every((m) => m.isImage), isTrue);
    expect(post.media.every((m) => m.isVideo), isFalse);
  });

  test('an old server sending only the legacy cover yields one image attachment', () {
    final post = Post.fromJson({
      'id': 1,
      'authorId': 2,
      'kind': 'image',
      'createdAt': '2026-08-14T09:00:00Z',
      'mediaId': 42,
    });

    expect(post.media.length, 1);
    expect(post.media.single.id, 42);
    expect(post.media.single.isImage, isTrue);
  });

  test('a text post has no attachments at all', () {
    final post = Post.fromJson({
      'id': 1,
      'authorId': 2,
      'kind': 'text',
      'body': 'hello',
      'createdAt': '2026-08-14T09:00:00Z',
    });

    expect(post.media, isEmpty);
    expect(post.imageMedia, isEmpty);
  });

  test('only images are offered to the gallery', () {
    final post = Post.fromJson({
      'id': 1,
      'authorId': 2,
      'kind': 'video',
      'createdAt': '2026-08-14T09:00:00Z',
      'media': [
        {'id': 8, 'mime': 'video/mp4', 'durationMs': 9500},
        {'id': 9, 'mime': 'image/jpeg'},
      ],
    });

    expect([for (final m in post.imageMedia) m.id], [9]);
  });

  test('a clip reports its length as m:ss, rounded up so it is never 0:00', () {
    String label(int ms) => PostMedia(id: 1, mime: 'video/mp4', durationMs: ms).durationLabel;
    expect(label(9500), '0:10');
    expect(label(9000), '0:09');
    expect(label(200), '0:01');
    expect(label(62000), '1:02');
    // A still is not a timed medium, so it has nothing to show.
    expect(const PostMedia(id: 1, mime: 'image/jpeg').durationLabel, '');
  });

  test('stored dimensions give a ratio before anything has decoded', () {
    expect(const PostMedia(id: 1, mime: 'video/mp4', width: 1080, height: 1920).aspectRatio,
        closeTo(1080 / 1920, 0.0001));
    expect(const PostMedia(id: 1, mime: 'image/jpeg').aspectRatio, isNull);
  });

  test('ServerInfo reads the media types a server accepts', () {
    final modern = ServerInfo.fromJson({
      'name': 'Alpha',
      'initialized': true,
      'mediaTypes': ['image', 'gif', 'video'],
    });
    expect(modern.mediaTypes, ['image', 'gif', 'video']);

    // A server predating typed media only ever accepted stills, so the absent key must not
    // be read as "anything goes" - it is what stops a clip being offered to a server that
    // would reject it.
    final old = ServerInfo.fromJson({'name': 'Beta', 'initialized': true});
    expect(old.mediaTypes, ['image']);
  });
}
