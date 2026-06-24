import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../api/api_client.dart';

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
  await _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  await _plugin
      .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
      ?.requestPermissions(alert: true, badge: true, sound: true);
  _initialized = true;
}

/// scheduleBirthdayNotifications syncs birthdays and (re)schedules reminders for the
/// next occurrence of each friend's birthday at 9am local time.
Future<void> scheduleBirthdayNotifications(ApiClient api) async {
  try {
    await _ensureInit();
    final birthdays = await api.upcomingBirthdays();
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
    for (final b in birthdays) {
      var when = tz.TZDateTime(tz.local, now.year, b.month, b.day, 9);
      if (when.isBefore(now)) {
        when = tz.TZDateTime(tz.local, now.year + 1, b.month, b.day, 9);
      }
      await _plugin.zonedSchedule(
        b.userId, // stable id per friend so re-scheduling replaces, not duplicates
        "It's ${b.name}'s birthday! 🎂",
        'Open Check-In to wish them a happy birthday.',
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dateAndTime,
      );
    }
  } catch (_) {
    // Notifications are best-effort; never block app startup on them.
  }
}
