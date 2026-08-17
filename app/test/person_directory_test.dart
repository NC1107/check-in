import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/person_directory.dart';

/// The phone-based cross-group identity join. A peer view carries [User.phoneKey] (a
/// one-way hash - see its doc comment) rather than the number itself; exact string equality
/// of that key is the contract, and anything unknown falls back to a per-group key (a
/// mismatch can only split people, never wrongly join them).
void main() {
  User member(int id, String name, String phone) =>
      User(id: id, name: name, phone: phone, isAdmin: false);

  User peer(int id, String name, String phoneKey) =>
      User(id: id, name: name, phoneKey: phoneKey, isAdmin: false);

  test('same phoneKey on two servers joins to one key; different keys stay apart', () {
    final dir = PersonDirectory.fromMemberLists({
      'alpha.invalid': [peer(1, 'Nick', 'hash-nick'), peer(2, 'Ada', 'hash-ada')],
      'beta.invalid': [peer(7, 'Nick', 'hash-nick'), peer(8, 'Grace', 'hash-grace')],
    });

    // Nick: user 1 on alpha, user 7 on beta - one identity, via the hashed key.
    expect(dir.keyFor('alpha.invalid', 1), dir.keyFor('beta.invalid', 7));
    expect(dir.keyFor('alpha.invalid', 1), 'phone:hash-nick');
    expect(dir.groupsFor('phone:hash-nick'), {'alpha.invalid', 'beta.invalid'});

    // Ada and Grace are distinct people.
    expect(dir.keyFor('alpha.invalid', 2), isNot(dir.keyFor('beta.invalid', 8)));
  });

  // A member list from an older server that hasn't been upgraded yet still sends the raw
  // phone and no phoneKey at all; the join must keep working off that instead of breaking.
  test('falls back to the raw phone when phoneKey is absent (older server)', () {
    final dir = PersonDirectory.fromMemberLists({
      'alpha.invalid': [member(1, 'Nick', '+15550001111'), member(2, 'Ada', '+15550002222')],
      'beta.invalid': [member(7, 'Nick', '+15550001111'), member(8, 'Grace', '+15550003333')],
    });

    // Nick: user 1 on alpha, user 7 on beta - one identity.
    expect(dir.keyFor('alpha.invalid', 1), dir.keyFor('beta.invalid', 7));
    expect(dir.keyFor('alpha.invalid', 1), 'phone:+15550001111');
    expect(dir.groupsFor('phone:+15550001111'), {'alpha.invalid', 'beta.invalid'});

    // Ada and Grace are distinct people.
    expect(dir.keyFor('alpha.invalid', 2), isNot(dir.keyFor('beta.invalid', 8)));
    expect(dir.groupsFor(dir.keyFor('alpha.invalid', 2)), {'alpha.invalid'});
  });

  test('unknown (group, user) falls back to a per-group key', () {
    final dir = PersonDirectory.fromMemberLists({
      'alpha.invalid': [member(1, 'Nick', '+15550001111')],
    });

    // Beta's member list was unreachable: its user 7 stays split from alpha's Nick.
    expect(dir.keyFor('beta.invalid', 7), 'local:beta.invalid~7');
    expect(dir.groupsFor('local:beta.invalid~7'), {'beta.invalid'});
    // Same id on alpha is known and phone-keyed - no collision with beta's local key.
    expect(dir.keyFor('alpha.invalid', 1), 'phone:+15550001111');
  });

  test('empty phones are skipped and the empty directory is all-fallback', () {
    final dir = PersonDirectory.fromMemberLists({
      'alpha.invalid': [member(1, 'Ghost', '')],
    });
    expect(dir.keyFor('alpha.invalid', 1), 'local:alpha.invalid~1');

    const empty = PersonDirectory.empty();
    expect(empty.keyFor('alpha.invalid', 1), 'local:alpha.invalid~1');
    expect(empty.groupsFor('phone:+15550001111'), isEmpty);
  });
}
