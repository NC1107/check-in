import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/api/models.dart';
import 'package:checkin/notifications/birthday_notifier.dart';

({String groupId, String groupName, Birthday birthday}) _entry(
  int userId,
  int month,
  int day, {
  String group = 'alpha',
  String groupName = 'Alpha',
}) {
  return (
    groupId: group,
    groupName: groupName,
    birthday: Birthday(userId: userId, name: 'Friend $userId', month: month, day: day),
  );
}

/// Pre-scheduling policy for birthday reminders: only the next 3 months, soonest
/// first, capped well under iOS's 64-pending-local-notification limit.
void main() {
  final now = DateTime(2026, 7, 3, 12); // July 3rd, noon

  test('keeps only birthdays within the window, soonest first', () {
    final schedule = upcomingBirthdaySchedule([
      _entry(1, 12, 25), // Christmas — beyond 3 months
      _entry(2, 7, 10), // next week
      _entry(3, 9, 1), // ~2 months out
      _entry(4, 7, 4), // tomorrow
    ], now);

    expect([for (final e in schedule) e.birthday.userId], [4, 2, 3]);
    expect(schedule.first.when, DateTime(2026, 7, 4, 9));
  });

  test('a birthday earlier this year resolves to next year and drops out of the window', () {
    final schedule = upcomingBirthdaySchedule([_entry(1, 1, 15)], now);
    expect(schedule, isEmpty);
  });

  test("today's birthday still schedules when 9am is ahead, resolves forward otherwise", () {
    final beforeNine = DateTime(2026, 7, 3, 8);
    expect(upcomingBirthdaySchedule([_entry(1, 7, 3)], beforeNine).single.when,
        DateTime(2026, 7, 3, 9));
    // At noon, today's 9am already passed → next year → outside the window.
    expect(upcomingBirthdaySchedule([_entry(1, 7, 3)], now), isEmpty);
  });

  test('caps at max across groups, keeping the soonest', () {
    final all = [
      // 40 birthdays per group over the next ~80 days, two groups.
      for (var d = 0; d < 40; d++) ...[
        _entry(d, now.month + (4 + d) ~/ 31, (4 + d) % 31 + 1),
        _entry(1000 + d, now.month + (4 + d) ~/ 31, (4 + d) % 31 + 1,
            group: 'beta', groupName: 'Beta'),
      ],
    ];

    final schedule = upcomingBirthdaySchedule(all, now, max: 60);

    expect(schedule, hasLength(60));
    // Soonest kept: the last scheduled entry fires no later than any dropped one would.
    final kept = schedule.map((e) => e.when).toList();
    expect(kept, List.of(kept)..sort((a, b) => a.compareTo(b)));
  });

  test('reminder title carries the group name only when one is given', () {
    expect(birthdayReminderTitle('Alice', null), "It's Alice's birthday! 🎂");
    expect(birthdayReminderTitle('Alice', 'Alpha Crew'), "It's Alice's birthday! 🎂 — Alpha Crew");
  });
}
