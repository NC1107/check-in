import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/api_client.dart';
import 'package:checkin/api/models.dart';

/// The block list needs names to be usable at all, and a self-hosted server that has not
/// updated yet sends only ids. Falling back to resolving them one at a time is what keeps
/// the screen working against those groups instead of showing a column of numbers.
void main() {
  User person(int id, String name) => User(id: id, name: name, phone: '1', isAdmin: false);

  Map<String, dynamic> named(List<User> us) => {
        'blockedIds': [for (final u in us) u.id],
        'blocked': [
          for (final u in us) {'id': u.id, 'name': u.name},
        ],
      };

  test('a server that names them needs no lookups at all', () async {
    final asked = <int>[];
    final got = await blocksFrom(named([person(2, 'Sam'), person(3, 'Ada')]), (id) async {
      asked.add(id);
      return person(id, 'should not be reached');
    });

    expect(got.map((u) => u.name), ['Sam', 'Ada']);
    expect(asked, isEmpty, reason: 'the response already carried the names');
  });

  test('an older server sending only ids has them resolved', () async {
    final asked = <int>[];
    final got = await blocksFrom({
      'blockedIds': [2, 3]
    }, (id) async {
      asked.add(id);
      return person(id, 'Person $id');
    });

    expect(asked, [2, 3]);
    expect(got.map((u) => u.name), ['Person 2', 'Person 3']);
  });

  // An id that will not resolve means the account is gone, so there is nothing left to
  // unblock - a blank row would only be something to tap at with no effect.
  test('an id that cannot be resolved is dropped, not shown blank', () async {
    final got = await blocksFrom({
      'blockedIds': [2, 3]
    }, (id) async => id == 2 ? null : person(id, 'Ada'));

    expect(got.map((u) => u.name), ['Ada']);
  });

  test('nobody blocked reads as an empty list either way', () async {
    expect(await blocksFrom({'blockedIds': <int>[], 'blocked': <dynamic>[]}, (_) async => null),
        isEmpty);
    expect(await blocksFrom(const {}, (_) async => null), isEmpty);
  });

  // "blocked" present but empty is a real answer - nobody is blocked - and must not fall
  // through to the id path and start resolving whatever blockedIds happens to hold.
  test('an empty named list is an answer, not a reason to fall back', () async {
    final asked = <int>[];
    final got = await blocksFrom({
      'blockedIds': [2, 3],
      'blocked': <dynamic>[],
    }, (id) async {
      asked.add(id);
      return person(id, 'x');
    });

    expect(got, isEmpty);
    expect(asked, isEmpty);
  });
}
