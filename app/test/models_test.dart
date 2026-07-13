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

  test('Post parses optional location and tolerates its absence', () {
    final withLoc = Post.fromJson({
      'id': 1,
      'authorId': 1,
      'kind': 'image',
      'createdAt': '2026-06-24T09:00:00Z',
      'location': 'Brooklyn, United States',
    });
    expect(withLoc.location, 'Brooklyn, United States');

    final without = Post.fromJson({
      'id': 2,
      'authorId': 1,
      'kind': 'text',
      'createdAt': '2026-06-24T09:00:00Z',
    });
    expect(without.location, isNull);
  });

  test('Post parses tagged people and exposes ids + label', () {
    final post = Post.fromJson({
      'id': 1,
      'authorId': 1,
      'kind': 'image',
      'createdAt': '2026-06-24T09:00:00Z',
      'people': [
        {'id': 2, 'name': 'Bob'},
        {'id': 3, 'name': 'Carol'},
      ],
    });
    expect(post.people.length, 2);
    expect(post.peopleIds, [2, 3]);
    expect(post.peopleLabel, 'with Bob & Carol');
  });

  test('Post.peopleLabel summarizes by count and is empty when untagged', () {
    Post tagged(List<String> names) => Post.fromJson({
          'id': 1,
          'authorId': 1,
          'kind': 'text',
          'createdAt': '2026-06-24T09:00:00Z',
          'people': [
            for (var i = 0; i < names.length; i++) {'id': i + 2, 'name': names[i]},
          ],
        });
    expect(tagged([]).peopleLabel, '');
    expect(tagged(['Bob']).peopleLabel, 'with Bob');
    expect(tagged(['Bob', 'Carol']).peopleLabel, 'with Bob & Carol');
    expect(tagged(['Bob', 'Carol', 'Dee', 'Eve']).peopleLabel, 'with Bob, Carol & 2 others');
  });

  test('Invite parses phone, used flag, and date', () {
    final joined = Invite.fromJson({
      'phone': '12025550142',
      'used': true,
      'createdAt': '2026-06-25T11:00:00Z',
    });
    expect(joined.phone, '12025550142');
    expect(joined.used, isTrue);
    expect(joined.createdAt, isNotNull);

    final pending = Invite.fromJson({'phone': '13015550000'});
    expect(pending.used, isFalse);
    expect(pending.createdAt, isNull);
  });

  test('User.birthdayLabel shows month and day (the server never sends the year)', () {
    final withBday = User.fromJson({
      'id': 1,
      'name': 'Nick',
      'phone': '+15550001111',
      'isAdmin': false,
      'birthdayMonth': 3,
      'birthdayDay': 14,
    });
    expect(withBday.birthdayLabel, 'March 14');

    final leapDay = User.fromJson({'id': 2, 'name': 'Ada', 'birthdayMonth': 2, 'birthdayDay': 29});
    expect(leapDay.birthdayLabel, 'February 29');

    final noBday = User.fromJson({'id': 3, 'name': 'Bo'});
    expect(noBday.birthdayLabel, '');
  });

  test('NotifyPrefs defaults to instant delivery, and reads back a digest window', () {
    final instant = NotifyPrefs.fromJson({'posts': true, 'replies': true, 'likes': true});
    expect(instant.digestEnabled, isFalse);
    expect(instant.digestHour, 20); // the default window, unused while instant

    final digest = NotifyPrefs.fromJson({
      'posts': true,
      'replies': false,
      'likes': true,
      'digestEnabled': true,
      'digestHour': 8,
      'digestOffset': -300,
    });
    expect(digest.digestEnabled, isTrue);
    expect(digest.digestHour, 8);
    expect(digest.digestOffset, -300);
    expect(digest.replies, isFalse);
  });

  test('NotifyPrefs.digestLabel renders the chosen hour', () {
    NotifyPrefs at(int hour) => NotifyPrefs.fromJson({'digestEnabled': true, 'digestHour': hour});
    // intl separates the meridiem with a narrow no-break space; normalize so the test is
    // about the time, not the whitespace codepoint.
    String label(int hour) => at(hour).digestLabel.replaceAll(RegExp(r'[  ]'), ' ');
    expect(label(20), '8:00 PM');
    expect(label(8), '8:00 AM');
    expect(label(0), '12:00 AM');
  });
}
