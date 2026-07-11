import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../api/api_client.dart';
import '../api/models.dart';

/// On-device birthday reminders. The app fetches friends' birthdays from the server and
/// schedules a local notification on the morning of each birthday - no cloud push
/// infrastructure required. Re-running this each app open keeps the schedule fresh.
///
/// A reminder always fires on the birthday itself; the user can additionally opt into an
/// early heads-up some days ahead (see [birthdayLeadDays]).

final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
bool _initialized = false;

const _kBirthdayLeadDays = 'birthday_lead_days';

/// The largest early-reminder lead time we allow. Kept modest so that, with two reminders
/// per friend, the schedule stays under iOS's 64-pending-notification limit.
const birthdayMaxLeadDays = 30;

/// How many days before each birthday to also send an early reminder. 0 (the default)
/// means only the day-of reminder. Stored on-device because these are local
/// notifications, not server push - the preference is per device, not per account.
Future<int> birthdayLeadDays() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getInt(_kBirthdayLeadDays) ?? 0).clamp(0, birthdayMaxLeadDays);
}

/// Persists the early-reminder lead time (clamped to 0..[birthdayMaxLeadDays]). Callers
/// should re-run [scheduleBirthdayNotifications] afterwards to apply it.
Future<void> setBirthdayLeadDays(int days) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kBirthdayLeadDays, days.clamp(0, birthdayMaxLeadDays));
}

Future<void> _ensureInit() async {
  if (_initialized) return;
  tzdata.initializeTimeZones();
  const settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );
  await _plugin.initialize(settings);
  // Request Android 13+ notification permission (no-op on earlier versions).
  // iOS permission is deferred - request it explicitly via requestNotificationPermission()
  // so the system dialog only appears when the user has seen the feature.
  await _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  _initialized = true;
}

/// Call this once from a user-visible action (e.g. a "Enable birthday reminders" button)
/// to show the iOS permission dialog. Safe to call multiple times.
Future<void> requestNotificationPermission() async {
  await _plugin
      .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
      ?.requestPermissions(alert: true, badge: true, sound: true);
}

/// A deterministic 31-bit id for one friend's reminder. User ids are only unique per
/// group (server), so the id mixes in the group; FNV-1a keeps it stable across launches
/// (Dart's String.hashCode isn't guaranteed to be). [early] gives the early heads-up its
/// own id (bit 30 flipped) so it doesn't overwrite the day-of reminder for the same friend.
int birthdayNotificationId(String groupId, int userId, {bool early = false}) {
  var hash = 0x811c9dc5;
  for (final unit in '$groupId#$userId'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return early ? hash ^ 0x40000000 : hash;
}

/// One group whose birthdays should be scheduled: its client plus identity for the
/// notification id (stable [id]) and the reminder title ([name]).
typedef BirthdayGroup = ({ApiClient api, String id, String name});

/// One friend's reminder, resolved to its next 9am occurrence.
typedef BirthdayEntry = ({String groupId, String groupName, Birthday birthday, DateTime when});

/// Resolves each birthday to its next 9am occurrence after [now] and keeps only what
/// should be pre-scheduled: within [window] (default 3 months), soonest first, at most
/// [max]. iOS silently drops pending local notifications beyond 64 per app, so
/// scheduling a whole year of birthdays across several groups would lose the nearest
/// ones; the schedule refreshes on every app open, which rolls the window forward.
List<BirthdayEntry> upcomingBirthdaySchedule(
  List<({String groupId, String groupName, Birthday birthday})> all,
  DateTime now, {
  Duration window = const Duration(days: 90),
  int max = 60,
}) {
  final entries = <BirthdayEntry>[];
  for (final e in all) {
    var when = DateTime(now.year, e.birthday.month, e.birthday.day, 9);
    if (when.isBefore(now)) {
      when = DateTime(now.year + 1, e.birthday.month, e.birthday.day, 9);
    }
    if (when.isBefore(now.add(window))) {
      entries.add((groupId: e.groupId, groupName: e.groupName, birthday: e.birthday, when: when));
    }
  }
  entries.sort((a, b) => a.when.compareTo(b.when));
  return entries.length > max ? entries.sublist(0, max) : entries;
}

/// The reminder title. With several groups connected the same name can exist in more
/// than one of them, so the group's display name disambiguates; pass null otherwise.
String birthdayReminderTitle(String friendName, String? groupName) => groupName == null
    ? "It's $friendName's birthday! 🎂"
    : "It's $friendName's birthday! 🎂 - $groupName";

/// The early heads-up title, [leadDays] before the birthday (e.g. "in 3 days" / "tomorrow").
String birthdayEarlyReminderTitle(String friendName, int leadDays, String? groupName) {
  final when = leadDays == 1 ? 'tomorrow' : 'in $leadDays days';
  final base = "$friendName's birthday is $when 🎂";
  return groupName == null ? base : '$base - $groupName';
}

/// scheduleBirthdayNotifications syncs birthdays from every connected group and
/// (re)schedules reminders for each friend's birthday at 9am local time (next 3
/// months, see [upcomingBirthdaySchedule]). Groups that can't be reached right now
/// are simply skipped until the next launch.
Future<void> scheduleBirthdayNotifications(List<BirthdayGroup> groups) async {
  try {
    await _ensureInit();
    final leadDays = await birthdayLeadDays();
    final all = <({String groupId, String groupName, Birthday birthday})>[];
    for (final g in groups) {
      try {
        final birthdays = await g.api.upcomingBirthdays();
        all.addAll([for (final b in birthdays) (groupId: g.id, groupName: g.name, birthday: b)]);
      } catch (_) {
        // One offline group must not cost the others their reminders.
      }
    }
    await _plugin.cancelAll();

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'birthdays',
        'Birthday reminders',
        channelDescription: 'Reminds you to check in on friends on their birthday',
        importance: Importance.defaultImportance,
      ),
      iOS: DarwinNotificationDetails(),
    );

    final now = tz.TZDateTime.now(tz.local);
    final multiGroup = groups.length > 1;
    // With an early reminder too, each friend takes two slots - halve the cap to stay well
    // under iOS's 64-pending limit.
    for (final e in upcomingBirthdaySchedule(all, now, max: leadDays > 0 ? 30 : 60)) {
      final groupName = multiGroup ? e.groupName : null;
      await _plugin.zonedSchedule(
        // Stable id per (group, friend) so re-scheduling replaces, not duplicates.
        birthdayNotificationId(e.groupId, e.birthday.userId),
        birthdayReminderTitle(e.birthday.name, groupName),
        'Open Check-In to wish them a happy birthday.',
        tz.TZDateTime(tz.local, e.when.year, e.when.month, e.when.day, e.when.hour),
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dateAndTime,
      );
      if (leadDays > 0) {
        final early = e.when.subtract(Duration(days: leadDays));
        // Skip an early reminder whose date has already passed (birthday nearer than the
        // lead time); the day-of reminder above still fires.
        if (early.isAfter(now)) {
          await _plugin.zonedSchedule(
            birthdayNotificationId(e.groupId, e.birthday.userId, early: true),
            birthdayEarlyReminderTitle(e.birthday.name, leadDays, groupName),
            'A heads-up so you have time to plan something.',
            tz.TZDateTime(tz.local, early.year, early.month, early.day, early.hour),
            details,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.dateAndTime,
          );
        }
      }
    }
  } catch (_) {
    // Notifications are best-effort; never block app startup on them.
  }
}
