import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:checkin/api/models.dart';
import 'package:checkin/notifications/birthday_notifier.dart';

typedef _Scheduled = ({
  int id,
  String title,
  tz.TZDateTime when,
  AndroidScheduleMode mode,
  DateTimeComponents match,
});

({String groupId, String groupName, Birthday birthday}) _entry(int userId, int month, int day) => (
      groupId: 'alpha',
      groupName: 'Alpha',
      birthday: Birthday(userId: userId, name: 'Friend $userId', month: month, day: day),
    );

void main() {
  late tz.Location tokyo;

  setUpAll(() {
    tzdata.initializeTimeZones();
    tokyo = tz.getLocation('Asia/Tokyo');
  });

  Future<List<_Scheduled>> run(
    List<({String groupId, String groupName, Birthday birthday})> all, {
    required int leadDays,
    required tz.TZDateTime now,
    bool multiGroup = false,
  }) async {
    final out = <_Scheduled>[];
    await scheduleBirthdayReminders(
      all: all,
      location: tokyo,
      now: now,
      leadDays: leadDays,
      multiGroup: multiGroup,
      schedule: ({
        required id,
        required title,
        required body,
        required scheduledDate,
        required androidScheduleMode,
        required matchDateTimeComponents,
      }) async {
        out.add((
          id: id,
          title: title,
          when: scheduledDate,
          mode: androidScheduleMode,
          match: matchDateTimeComponents,
        ));
      },
    );
    return out;
  }

  test('schedules the day-of reminder at 9am in the given zone, not UTC', () async {
    final now = tz.TZDateTime(tokyo, 2026, 7, 3, 12);
    final out = await run([_entry(1, 7, 10)], leadDays: 0, now: now);

    expect(out, hasLength(1));
    expect(out.single.when.location, tokyo);
    expect(out.single.when.hour, 9);
    expect((out.single.when.year, out.single.when.month, out.single.when.day), (2026, 7, 10));
    expect(out.single.when.toUtc().hour, 0); // 9am JST is midnight UTC
    expect(out.single.id, birthdayNotificationId('alpha', 1));
    expect(out.single.match, DateTimeComponents.dateAndTime);
    expect(out.single.mode, AndroidScheduleMode.inexactAllowWhileIdle);
  });

  test('adds an early reminder at 9am, lead days before, with its own id', () async {
    final now = tz.TZDateTime(tokyo, 2026, 7, 3, 12);
    final out = await run([_entry(1, 7, 10)], leadDays: 3, now: now);

    expect(out, hasLength(2));
    final early = out.last;
    expect((early.when.month, early.when.day, early.when.hour), (7, 7, 9));
    expect(early.id, birthdayNotificationId('alpha', 1, early: true));
    expect(early.id, isNot(out.first.id));
    expect(early.title, contains('in 3 days'));
  });

  test('skips the early reminder when its date has already passed', () async {
    final now = tz.TZDateTime(tokyo, 2026, 7, 3, 12);
    final out = await run([_entry(1, 7, 5)], leadDays: 7, now: now);

    expect(out, hasLength(1));
    expect(out.single.id, birthdayNotificationId('alpha', 1));
  });

  test('group name appears in titles only when several groups are connected', () async {
    final now = tz.TZDateTime(tokyo, 2026, 7, 3, 12);
    final single = await run([_entry(1, 7, 10)], leadDays: 0, now: now);
    final multi = await run([_entry(1, 7, 10)], leadDays: 0, now: now, multiGroup: true);

    expect(single.single.title, isNot(contains('Alpha')));
    expect(multi.single.title, contains('Alpha'));
  });

  test('notification ids are stable across launches', () {
    expect(birthdayNotificationId('alpha', 1), birthdayNotificationId('alpha', 1));
    expect(birthdayNotificationId('alpha', 1), isNot(birthdayNotificationId('beta', 1)));
    expect(birthdayNotificationId('alpha', 1), lessThan(0x80000000));
  });
}
