import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/features/onboarding/profile_prefill.dart';
import 'package:checkin/state/app_state.dart';

/// Every Check-In group is a separate server with its own account, so joining another one
/// starts from a blank profile. These cover the rules for copying an existing account
/// into that form - above all the phone match, which is what stops a friend borrowing the
/// device from being handed the owner's name and face.
void main() {
  ServerAccount account(
    String id, {
    String phone = '+12025550186',
    String firstName = 'Nick',
    String lastName = 'Conn',
    String? displayName,
    int? profileMediaId,
    bool signedIn = true,
    bool hydrated = true,
  }) =>
      ServerAccount(
        id: id,
        baseUrl: 'https://$id',
        serverName: id,
        token: signedIn ? 't' : null,
        user: hydrated
            ? User(
                id: 1,
                name: displayName ?? '$firstName $lastName'.trim(),
                firstName: firstName,
                lastName: lastName,
                phone: phone,
                isAdmin: false,
                profileMediaId: profileMediaId,
              )
            : null,
      );

  MultiSession session(List<ServerAccount> groups) => MultiSession(groups: groups, restored: true);

  group('prefillSourceFor', () {
    test('the most recently joined matching account wins', () {
      // addGroup appends and there is no primary-account concept, so "latest" is the best
      // available stand-in for "most current".
      final s = session([
        account('alpha.invalid', firstName: 'Old'),
        account('beta.invalid', firstName: 'New'),
      ]);

      expect(prefillSourceFor(s, '+12025550186')?.id, 'beta.invalid');
    });

    test('a different number gets nothing, however many accounts are on the device', () {
      final s = session([account('alpha.invalid'), account('beta.invalid')]);

      expect(prefillSourceFor(s, '+12025550187'), isNull);
    });

    test('formatting differences still match', () {
      final s = session([account('alpha.invalid', phone: '+1 (202) 555-0186')]);

      expect(prefillSourceFor(s, '+12025550186')?.id, 'alpha.invalid');
    });

    test('a blank number matches nothing', () {
      // The entry step's number is empty until typed; an empty-vs-empty digit comparison
      // would otherwise match an account with no stored phone.
      final s = session([account('alpha.invalid', phone: '')]);

      expect(prefillSourceFor(s, ''), isNull);
    });

    test('signed-out groups are skipped', () {
      final s = session([account('alpha.invalid', signedIn: false)]);

      expect(prefillSourceFor(s, '+12025550186'), isNull);
    });

    test('a group whose user has not been fetched yet is skipped', () {
      // user is not persisted; it is refetched at launch, so a cold start against an
      // unreachable server simply yields no prefill.
      final s = session([account('alpha.invalid', hydrated: false)]);

      expect(prefillSourceFor(s, '+12025550186'), isNull);
    });

    test('an account with no name and no photo is not a source', () {
      // Returning it would show the "filled in from your group profile" note over a form
      // that is still entirely blank.
      final s = session([account('alpha.invalid', firstName: '', lastName: '')]);

      expect(prefillSourceFor(s, '+12025550186'), isNull);
    });

    test('an account with only a photo is still a source', () {
      final s = session([
        account('alpha.invalid', firstName: '', lastName: '', profileMediaId: 7),
      ]);

      expect(prefillSourceFor(s, '+12025550186')?.id, 'alpha.invalid');
    });

    test('a non-matching newer account does not shadow an older matching one', () {
      final s = session([
        account('alpha.invalid'),
        account('beta.invalid', phone: '+12025550999'),
      ]);

      expect(prefillSourceFor(s, '+12025550186')?.id, 'alpha.invalid');
    });
  });

  group('resolveBirthday', () {
    final now = DateTime(2026, 8, 14);

    test('nothing known leaves both the value and the picker unseeded', () {
      final r = resolveBirthday(stored: null, month: 0, day: 0, now: now);

      expect(r.value, isNull);
      expect(r.seed, isNull);
    });

    test('month and day alone seed the picker but never commit a date', () {
      // The year is the one part the API deliberately never returns, so it stays the
      // user's to enter.
      final r = resolveBirthday(stored: null, month: 3, day: 14, now: now);

      expect(r.value, isNull);
      expect(r.seed, DateTime(2001, 3, 14));
    });

    test('a stored date with no month or day to check against is used as is', () {
      final r = resolveBirthday(stored: DateTime(1990, 3, 14), month: 0, day: 0, now: now);

      expect(r.value, DateTime(1990, 3, 14));
      expect(r.seed, DateTime(1990, 3, 14));
    });

    test('a stored date the server agrees with fills the field', () {
      final r = resolveBirthday(stored: DateTime(1990, 3, 14), month: 3, day: 14, now: now);

      expect(r.value, DateTime(1990, 3, 14));
      expect(r.seed, DateTime(1990, 3, 14));
    });

    test('a disagreement keeps the server day and drops the stored one', () {
      // Only the device ever knew the year, but the account being copied is the authority
      // on which day it is, so the picker opens on that day with the year carried over.
      final r = resolveBirthday(stored: DateTime(1990, 3, 14), month: 7, day: 2, now: now);

      expect(r.value, isNull);
      expect(r.seed, DateTime(1990, 7, 2));
    });
  });

  group('the remembered signup birthday', () {
    test('round-trips', () async {
      SharedPreferences.setMockInitialValues({});

      await rememberSignupBirthday(DateTime(1990, 3, 14));

      expect(await lastSignupBirthday(), DateTime(1990, 3, 14));
    });

    test('is absent before any signup on this device', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await lastSignupBirthday(), isNull);
    });

    test('degrades to nothing rather than throwing on a corrupt value', () async {
      // This is read on the join path, where an exception would block signup entirely over
      // a field the user can just fill in.
      SharedPreferences.setMockInitialValues({'signup_birthday': 'not-a-date'});

      expect(await lastSignupBirthday(), isNull);
    });
  });
}
