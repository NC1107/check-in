import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../api/api_client.dart';
import '../api/models.dart';

/// On-device birthday reminders. The app fetches friends' birthdays from the server and
/// schedules a local notification on the morning of each birthday — no cloud push
/// infrastructure required. Re-running this each app open keeps the schedule fresh.

final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
bool _initialized = false;

Future<void> _ensureInit() async {
  if (_initialized) return;
  tzdata.initializeTimeZones();
  const settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );
  await _plugin.initialize(settings);
  // Request Android 13+ notification permission (no-op on earlier versions).
  // iOS permission is deferred — request it explicitly via requestNotificationPermission()
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
/// (Dart's String.hashCode isn't guaranteed to be).
int birthdayNotificationId(String groupId, int userId) {
  var hash = 0x811c9dc5;
  for (final unit in '$groupId#$userId'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

/// scheduleBirthdayNotifications syncs birthdays from every connected group and
/// (re)schedules reminders for the next occurrence of each friend's birthday at 9am
/// local time. [apis] and [groupIds] run parallel (one entry per group). Groups that
/// can't be reached right now are simply skipped until the next launch.
Future<void> scheduleBirthdayNotifications(List<ApiClient> apis, List<String> groupIds) async {
  try {
    await _ensureInit();
    final all = <({String groupId, Birthday birthday})>[];
    for (var i = 0; i < apis.length; i++) {
      try {
        final birthdays = await apis[i].upcomingBirthdays();
        all.addAll([for (final b in birthdays) (groupId: groupIds[i], birthday: b)]);
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
    for (final e in all) {
      final b = e.birthday;
      var when = tz.TZDateTime(tz.local, now.year, b.month, b.day, 9);
      if (when.isBefore(now)) {
        when = tz.TZDateTime(tz.local, now.year + 1, b.month, b.day, 9);
      }
      await _plugin.zonedSchedule(
        // Stable id per (group, friend) so re-scheduling replaces, not duplicates.
        birthdayNotificationId(e.groupId, b.userId),
        "It's ${b.name}'s birthday! 🎂",
        'Open Check-In to wish them a happy birthday.',
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dateAndTime,
      );
    }
  } catch (_) {
    // Notifications are best-effort; never block app startup on them.
  }
}
