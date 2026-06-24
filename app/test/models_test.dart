import 'package:checkin/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Post.fromJson parses a feed post', () {
    final post = Post.fromJson({
      'id': 1,
      'authorId': 7,
      'authorName': 'Ada',
      'kind': 'image',
      'body': 'Hello world',
      'createdAt': '2026-06-24T09:00:00Z',
      'likeCount': 3,
      'commentCount': 2,
      'likedByViewer': true,
      'mediaId': 42,
    });
    expect(post.authorName, 'Ada');
    expect(post.kind, 'image');
    expect(post.likeCount, 3);
    expect(post.likedByViewer, isTrue);
    expect(post.mediaId, 42);
  });

  test('ServerInfo defaults when fields missing', () {
    final info = ServerInfo.fromJson({});
    expect(info.name, 'Check-In');
    expect(info.initialized, isFalse);
  });

  test('AuthResult parses token and user', () {
    final res = AuthResult.fromJson({
      'token': 'abc',
      'user': {'id': 1, 'name': 'Grace', 'phone': '+15551234567', 'isAdmin': true},
    });
    expect(res.token, 'abc');
    expect(res.user.name, 'Grace');
    expect(res.user.isAdmin, isTrue);
  });

  test('Birthday parses month and day', () {
    final b = Birthday.fromJson({'userId': 2, 'name': 'Lin', 'month': 12, 'day': 25});
    expect(b.month, 12);
    expect(b.day, 25);
  });
}
