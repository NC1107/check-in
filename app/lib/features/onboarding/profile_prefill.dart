import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/app_state.dart';

/// The last birthday entered at signup on this device. The server never returns a birth
/// year (`db.User.Birthday` is marshalled to month/day only so a member's age is never
/// exposed over the API), but signup requires a full date - so the only way to carry an
/// exact birthday into the next group is to remember it locally.
const _kSignupBirthday = 'signup_birthday';

String _digits(String raw) => raw.replaceAll(RegExp(r'\D'), '');

/// The account whose profile the signup form should copy for someone joining another
/// group with [fullPhone], or null when nothing on this device may be copied.
///
/// The phone match is a privacy gate, not a convenience. Nothing otherwise ties the
/// number typed on the entry step to the accounts already on the device, so without it,
/// handing your phone to a friend so they can join your group would pre-fill your name
/// and face into their signup. It is exact digit-for-digit with no suffix or fuzzy
/// fallback, and it runs before any network request, so a mismatch produces no traffic.
///
/// Most-recently-joined wins: [MultiSessionController.addGroup] appends, and Check-In has
/// no concept of a primary account. [MultiSession.current] is deliberately not consulted -
/// it tracks which group the feed is looking at, which is a view concern, not identity.
///
/// An account with no name and no photo is skipped rather than returned empty, so the
/// "filled in from your group profile" note only ever appears when something was.
ServerAccount? prefillSourceFor(MultiSession session, String fullPhone) {
  final wanted = _digits(fullPhone);
  if (wanted.isEmpty) return null;
  for (final group in session.signedIn.reversed) {
    final user = group.user;
    if (user == null) continue;
    if (_digits(user.phone) != wanted) continue;
    final hasSomethingToGive =
        user.firstName.isNotEmpty || user.lastName.isNotEmpty || user.profileMediaId != null;
    if (hasSomethingToGive) return group;
  }
  return null;
}

/// Combines the birthday remembered on this device with the month and day the source
/// server reports, yielding the date to fill in ([value], null when it can't be known)
/// and the date the picker should open on ([seed]).
///
/// The two can disagree: [stored] is whatever was last typed at signup on this device,
/// while the month/day came from the account being copied. When they conflict the server
/// is the authority on which day it is, but only the device ever knew the year, so the
/// result is a picker parked on the right day with the year left for the user.
({DateTime? value, DateTime? seed}) resolveBirthday({
  required DateTime? stored,
  required int month,
  required int day,
  required DateTime now,
}) {
  final hasMonthDay = month >= 1 && day >= 1;
  if (stored == null) {
    if (!hasMonthDay) return (value: null, seed: null);
    return (value: null, seed: DateTime(now.year - 25, month, day));
  }
  if (!hasMonthDay || (stored.month == month && stored.day == day)) {
    return (value: stored, seed: stored);
  }
  return (value: null, seed: DateTime(stored.year, month, day));
}

/// Reads back [rememberSignupBirthday]. A corrupt value degrades to "no prefill" rather
/// than throwing, because this runs on the join path where a crash would block signup
/// entirely over a field the user can simply fill in.
Future<DateTime?> lastSignupBirthday() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kSignupBirthday);
  if (raw == null) return null;
  return DateTime.tryParse(raw);
}

Future<void> rememberSignupBirthday(DateTime birthday) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kSignupBirthday, DateFormat('yyyy-MM-dd').format(birthday));
}
