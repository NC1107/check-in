import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../api/api_client.dart';
import '../api/models.dart';
import 'local_notifications.dart';

/// On-device birthday reminders. The app fetches friends' birthdays from the server and
/// schedules a local notification on the morning of each birthday - no cloud push
/// infrastructure required. Re-running this each app open keeps the schedule fresh.
///
/// A reminder always fires on the birthday itself; the user can additionally opt into an
/// early heads-up some days ahead (see [birthdayLeadDays]).

bool _timezoneReady = false;

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

/// The timezone database knows every zone but not which one the phone is in; without
/// [tz.setLocalLocation] `tz.local` is UTC and a "9am" reminder fires at 9am UTC.
Future<void> _ensureInit() async {
  await ensureLocalNotificationsInitialized();
  if (_timezoneReady) return;
  tzdata.initializeTimeZones();
  try {
    final zone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(zone.identifier));
  } catch (_) {
    // Unknown zone: stay on UTC rather than skip the reminders entirely.
  }
  _timezoneReady = true;
  // Request Android 13+ notification permission (no-op on earlier versions).
  // iOS permission is deferred - request it explicitly via requestNotificationPermission()
  // so the system dialog only appears when the user has seen the feature.
  await localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

/// Call this once from a user-visible action (e.g. a "Enable birthday reminders" button)
/// to show the iOS permission dialog. Safe to call multiple times.
Future<void> requestNotificationPermission() async {
  await localNotifications
      .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
      ?.requestPermissions(alert: true, badge: true, sound: true);
}

/// A deterministic 31-bit id for one friend's reminder. User ids are only unique per
/// group (server), so the id mixes in the group; FNV-1a keeps it stable across launches
/// (see [stableNotificationId]). [early] gives the early heads-up its
/// own id (bit 30 flipped) so it doesn't overwrite the day-of reminder for the same friend.
int birthdayNotificationId(String groupId, int userId, {bool early = false}) {
  final hash = stableNotificationId('$groupId#$userId');
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

/// The slice of the notifications plugin that scheduling needs, so tests can capture what
/// would be scheduled without a platform channel.
typedef ReminderScheduler = Future<void> Function({
  required int id,
  required String title,
  required String body,
  required tz.TZDateTime scheduledDate,
  required AndroidScheduleMode androidScheduleMode,
  required DateTimeComponents matchDateTimeComponents,
});

const _details = NotificationDetails(
  android: AndroidNotificationDetails(
    'birthdays',
    'Birthday reminders',
    channelDescription: 'Reminds you to check in on friends on their birthday',
    importance: Importance.defaultImportance,
  ),
  iOS: DarwinNotificationDetails(),
);

// Inexact: a birthday reminder doesn't need to-the-second delivery, and it avoids the
// exact-alarm permission. dateAndTime repeats it every year.
const _scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;
const _repeat = DateTimeComponents.dateAndTime;

Future<void> _scheduleOnPlugin({
  required int id,
  required String title,
  required String body,
  required tz.TZDateTime scheduledDate,
  required AndroidScheduleMode androidScheduleMode,
  required DateTimeComponents matchDateTimeComponents,
}) =>
    localNotifications.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      notificationDetails: _details,
      androidScheduleMode: androidScheduleMode,
      matchDateTimeComponents: matchDateTimeComponents,
    );

/// Schedules the day-of reminder (and the early heads-up when [leadDays] > 0) for every
/// birthday within the window, at 9am wall-clock time in [location].
Future<void> scheduleBirthdayReminders({
  required List<({String groupId, String groupName, Birthday birthday})> all,
  required tz.Location location,
  required tz.TZDateTime now,
  required int leadDays,
  required bool multiGroup,
  required ReminderScheduler schedule,
}) async {
  // Birthdays are wall-clock dates, so compare in wall-clock terms rather than instants.
  final wallNow = DateTime(now.year, now.month, now.day, now.hour, now.minute);
  // With an early reminder too, each friend takes two slots - halve the cap to stay well
  // under iOS's 64-pending limit.
  for (final e in upcomingBirthdaySchedule(all, wallNow, max: leadDays > 0 ? 30 : 60)) {
    final groupName = multiGroup ? e.groupName : null;
    await schedule(
      // Stable id per (group, friend) so re-scheduling replaces, not duplicates.
      id: birthdayNotificationId(e.groupId, e.birthday.userId),
      title: birthdayReminderTitle(e.birthday.name, groupName),
      body: 'Open Check-In to wish them a happy birthday.',
      scheduledDate: tz.TZDateTime(location, e.when.year, e.when.month, e.when.day, e.when.hour),
      androidScheduleMode: _scheduleMode,
      matchDateTimeComponents: _repeat,
    );
    if (leadDays > 0) {
      final early = e.when.subtract(Duration(days: leadDays));
      // Skip an early reminder whose date has already passed (birthday nearer than the
      // lead time); the day-of reminder above still fires.
      if (early.isAfter(wallNow)) {
        await schedule(
          id: birthdayNotificationId(e.groupId, e.birthday.userId, early: true),
          title: birthdayEarlyReminderTitle(e.birthday.name, leadDays, groupName),
          body: 'A heads-up so you have time to plan something.',
          scheduledDate: tz.TZDateTime(location, early.year, early.month, early.day, early.hour),
          androidScheduleMode: _scheduleMode,
          matchDateTimeComponents: _repeat,
        );
      }
    }
  }
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
    await localNotifications.cancelAllPendingNotifications();
    await scheduleBirthdayReminders(
      all: all,
      location: tz.local,
      now: tz.TZDateTime.now(tz.local),
      leadDays: leadDays,
      multiGroup: groups.length > 1,
      schedule: _scheduleOnPlugin,
    );
  } catch (_) {
    // Notifications are best-effort; never block app startup on them.
  }
}
