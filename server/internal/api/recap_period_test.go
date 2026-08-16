package api

import (
	"testing"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// utc is a small helper for building exact instants without a timezone-dependent literal.
func utc(y int, m time.Month, d, hh, mm int) time.Time {
	return time.Date(y, m, d, hh, mm, 0, 0, time.UTC)
}

// TestRecapDuePeriod is table-driven over recapDuePeriod's period-boundary math: whether
// "now" is due, and - when it is - the exact [start, end) it computes. Asserting the exact
// instants (not just the due bool) is what catches a flipped offset sign or a week-start
// arithmetic mistake; a wrong sign or a swapped +/-7 days would land on a visibly different
// date, not merely "still roughly right".
func TestRecapDuePeriod(t *testing.T) {
	settings := func(cadence string, weekday, hour, offset int) db.RecapSettings {
		return db.RecapSettings{Cadence: cadence, Weekday: weekday, Hour: hour, Offset: offset}
	}

	tests := []struct {
		name      string
		settings  db.RecapSettings
		now       time.Time
		wantDue   bool
		wantStart time.Time
		wantEnd   time.Time
	}{
		{
			// 2026-01-05 is a Monday (2026-01-01 is a Thursday).
			name:      "weekly, offset 0, fires on the configured weekday and hour",
			settings:  settings("weekly", 1, 19, 0),
			now:       utc(2026, 1, 5, 19, 7),
			wantDue:   true,
			wantStart: utc(2025, 12, 29, 19, 0),
			wantEnd:   utc(2026, 1, 5, 19, 0),
		},
		{
			name:     "weekly, wrong hour does not fire",
			settings: settings("weekly", 1, 19, 0),
			now:      utc(2026, 1, 5, 18, 59),
			wantDue:  false,
		},
		{
			name:     "weekly, right hour wrong weekday does not fire",
			settings: settings("weekly", 1, 19, 0),
			now:      utc(2026, 1, 6, 19, 0), // Tuesday
			wantDue:  false,
		},
		{
			// +780 minutes (UTC+13, e.g. Tonga) pushes the shifted "local" date a full day
			// ahead of now's own UTC date - Sunday in UTC, Monday once shifted - so this
			// pins that isoWeekday/hour are judged on the shifted local time, not on now's
			// own UTC weekday, and that the offset's sign in both directions (into local,
			// and back out to end) is correct. Hour 6 (rather than 19) is what forces the
			// rollover: 6 - 13 < 0, so the UTC instant behind "local Monday 06:00" falls on
			// the previous day (Sunday) in UTC.
			name:      "weekly, extreme positive offset (+780) crosses a date boundary",
			settings:  settings("weekly", 1, 6, 780),
			now:       utc(2026, 1, 4, 17, 37), // Sunday 17:37 UTC; minutes must not matter
			wantDue:   true,
			wantStart: utc(2025, 12, 28, 17, 0),
			wantEnd:   utc(2026, 1, 4, 17, 0),
		},
		{
			// -720 minutes (UTC-12, e.g. Baker Island) - the other extreme, and paired with
			// a monthly cadence so the same test sweep also covers the day-of-month check.
			name:      "monthly, extreme negative offset (-720) crosses a date boundary",
			settings:  settings("monthly", 1, 0, -720),
			now:       utc(2026, 3, 1, 12, 15),
			wantDue:   true,
			wantStart: utc(2026, 2, 1, 12, 0),
			wantEnd:   utc(2026, 3, 1, 12, 0),
		},
		{
			name:     "monthly, not the first of the (shifted local) month does not fire",
			settings: settings("monthly", 1, 19, 0),
			now:      utc(2026, 1, 2, 19, 0),
			wantDue:  false,
		},
		{
			name:      "monthly, Jan 1 rolls the period start back into December of the prior year",
			settings:  settings("monthly", 1, 0, 0),
			now:       utc(2027, 1, 1, 0, 45),
			wantDue:   true,
			wantStart: utc(2026, 12, 1, 0, 0),
			wantEnd:   utc(2027, 1, 1, 0, 0),
		},
		{
			// 2026 is not a leap year, so this Feb has 28 days - AddDate's day=1 arithmetic
			// does not depend on the month length either way, but this pins that no overflow
			// quirk sneaks in at that boundary.
			name:      "monthly, Mar 1 after a 28-day Feb (non-leap 2026)",
			settings:  settings("monthly", 1, 0, 0),
			now:       utc(2026, 3, 1, 0, 0),
			wantDue:   true,
			wantStart: utc(2026, 2, 1, 0, 0),
			wantEnd:   utc(2026, 3, 1, 0, 0),
		},
		{
			// 2028 is a leap year (28 / 4, not a century), so this Feb has 29 days.
			name:      "monthly, Mar 1 after a 29-day Feb (leap 2028)",
			settings:  settings("monthly", 1, 0, 0),
			now:       utc(2028, 3, 1, 0, 0),
			wantDue:   true,
			wantStart: utc(2028, 2, 1, 0, 0),
			wantEnd:   utc(2028, 3, 1, 0, 0),
		},
		{
			name:     "cadence 'off' never fires",
			settings: settings("off", 1, 19, 0),
			now:      utc(2026, 1, 5, 19, 0),
			wantDue:  false,
		},
		{
			name:     "cadence 'custom' never fires (no standing schedule for it)",
			settings: settings("custom", 1, 19, 0),
			now:      utc(2026, 1, 5, 19, 0),
			wantDue:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotStart, gotEnd, gotDue := recapDuePeriod(tt.settings, tt.now)
			if gotDue != tt.wantDue {
				t.Fatalf("due = %v, want %v", gotDue, tt.wantDue)
			}
			if !gotDue {
				return
			}
			if !gotStart.Equal(tt.wantStart) {
				t.Errorf("start = %v, want %v", gotStart, tt.wantStart)
			}
			if !gotEnd.Equal(tt.wantEnd) {
				t.Errorf("end = %v, want %v", gotEnd, tt.wantEnd)
			}
		})
	}
}

// TestIsoWeekday pins Go's Sunday=0 weekday converted to ISO's Monday=1..Sunday=7, which is
// recap_weekday's stored convention (0018_recap.sql). A wrong conversion here would silently
// shift every weekly recap's day by one, or make Sunday unreachable.
func TestIsoWeekday(t *testing.T) {
	// 2026-01-01 is a Thursday.
	tests := []struct {
		date time.Time
		want int
	}{
		{utc(2026, 1, 1, 0, 0), 4}, // Thursday
		{utc(2026, 1, 2, 0, 0), 5}, // Friday
		{utc(2026, 1, 3, 0, 0), 6}, // Saturday
		{utc(2026, 1, 4, 0, 0), 7}, // Sunday
		{utc(2026, 1, 5, 0, 0), 1}, // Monday
		{utc(2026, 1, 6, 0, 0), 2}, // Tuesday
		{utc(2026, 1, 7, 0, 0), 3}, // Wednesday
	}
	for _, tt := range tests {
		if got := isoWeekday(tt.date); got != tt.want {
			t.Errorf("isoWeekday(%s) = %d, want %d", tt.date.Weekday(), got, tt.want)
		}
	}
}
