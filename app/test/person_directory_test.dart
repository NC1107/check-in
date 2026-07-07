import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/state/person_directory.dart';

/// The phone-based cross-group identity join. Phones are stored server-normalized, so
/// exact string equality is the contract; anything unknown falls back to a per-group key
/// (a mismatch can only split people, never wrongly join them).
void main() {
  User member(int id, String name, String phone) =>
      User(id: id, name: name, phone: phone, isAdmin: false);

  test('same phone on two servers joins to one key; different phones stay apart', () {
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
