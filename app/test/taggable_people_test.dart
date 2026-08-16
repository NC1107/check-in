import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/taggable_people.dart';

/// The compose tag picker's roster: every selected group's members merged into one entry
/// per human, each carrying the id that human holds on each of those servers. Getting the
/// per-group ids wrong is the whole risk here - user 5 in one group is a different person
/// than user 5 in another.
void main() {
  User member(int id, String name, String phone, {int? photo}) =>
      User(id: id, name: name, phone: phone, isAdmin: false, profileMediaId: photo);

  test('one entry per human, holding the id they have in each selected group', () {
    final people = mergeTaggablePeople({
      'alpha.invalid': [member(1, 'Nick', '+15550001111'), member(2, 'Ada', '+15550002222')],
      'beta.invalid': [member(7, 'Nick', '+15550001111'), member(8, 'Grace', '+15550003333')],
    });

    expect([for (final p in people) p.name], ['Ada', 'Grace', 'Nick']); // sorted by name

    final nick = people.firstWhere((p) => p.name == 'Nick');
    // One human, two accounts: alpha knows him as 1, beta as 7.
    expect(nick.idsByGroup, {'alpha.invalid': 1, 'beta.invalid': 7});
    expect(nick.idIn('alpha.invalid'), 1);
    expect(nick.idIn('beta.invalid'), 7);
    expect(nick.missingFrom(['alpha.invalid', 'beta.invalid']), isEmpty);
  });

  test('someone in only some of the selected groups is taggable, and says where they are not', () {
    final people = mergeTaggablePeople({
      'alpha.invalid': [member(2, 'Ada', '+15550002222')],
      'beta.invalid': [member(8, 'Grace', '+15550003333')],
      'gamma.invalid': [member(4, 'Ada', '+15550002222')],
    });

    final ada = people.firstWhere((p) => p.name == 'Ada');
    expect(ada.idsByGroup, {'alpha.invalid': 2, 'gamma.invalid': 4});
    // Beta has no account for her: nothing to tag there, and the picker says so.
    expect(ada.idIn('beta.invalid'), isNull);
    expect(ada.missingFrom(['alpha.invalid', 'beta.invalid', 'gamma.invalid']), ['beta.invalid']);

    final grace = people.firstWhere((p) => p.name == 'Grace');
    expect(grace.idsByGroup, {'beta.invalid': 8});
    expect(grace.missingFrom(['alpha.invalid', 'beta.invalid', 'gamma.invalid']),
        ['alpha.invalid', 'gamma.invalid']);
  });

  test('a colliding id in another group never leaks into a person entry', () {
    // Both servers issued id 5, to different humans. Merging by id instead of identity would
    // hand one person both accounts and tag a stranger on the other server.
    final people = mergeTaggablePeople({
      'alpha.invalid': [member(5, 'Ada', '+15550002222')],
      'beta.invalid': [member(5, 'Grace', '+15550003333')],
    });

    expect(people, hasLength(2));
    expect(people.firstWhere((p) => p.name == 'Ada').idsByGroup, {'alpha.invalid': 5});
    expect(people.firstWhere((p) => p.name == 'Grace').idsByGroup, {'beta.invalid': 5});
  });

  test('the author is excluded per server - the post is implicitly theirs', () {
    final people = mergeTaggablePeople(
      {
        'alpha.invalid': [member(1, 'Nick', '+15550001111'), member(2, 'Ada', '+15550002222')],
        'beta.invalid': [member(7, 'Nick', '+15550001111'), member(8, 'Grace', '+15550003333')],
      },
      // The same human, with a different id on each server.
      excludeByGroup: {'alpha.invalid': 1, 'beta.invalid': 7},
    );

    expect([for (final p in people) p.name], ['Ada', 'Grace']);
  });

  test('phones a server does not know only split a person, they never join the wrong two', () {
    final people = mergeTaggablePeople({
      'alpha.invalid': [member(2, 'Ada', '+15550002222')],
      'beta.invalid': [member(9, 'Ada', '')], // no phone: cannot be proven to be the same Ada
    });

    expect(people, hasLength(2));
    expect([
      for (final p in people) p.idsByGroup
    ], [
      {'alpha.invalid': 2},
      {'beta.invalid': 9},
    ]);
  });

  test('the first group that knows a person supplies the name and photo, with its own group', () {
    final people = mergeTaggablePeople({
      'alpha.invalid': [member(2, 'Ada L.', '+15550002222')],
      'beta.invalid': [member(4, 'Ada Lovelace', '+15550002222', photo: 77)],
    });

    final ada = people.single;
    expect(ada.name, 'Ada L.');
    // Media is per-server, so the photo id is useless without the group that stores it.
    expect(ada.photoId, 77);
    expect(ada.photoGroupId, 'beta.invalid');
  });

  test('an unreachable group contributes nobody', () {
    final people = mergeTaggablePeople({
      'alpha.invalid': [member(2, 'Ada', '+15550002222')],
      'beta.invalid': <User>[],
    });

    expect(people.single.idsByGroup, {'alpha.invalid': 2});
    expect(mergeTaggablePeople(const {}), isEmpty);
  });
}
