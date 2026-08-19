package api

import (
	"testing"

	"github.com/nc1107/check-in/server/internal/db"
)

// The recap bounds had no coverage: widening recapHour to 0-99 and recapWeekday to 1-99
// left the whole api suite green. These pin each bound directly, which the extraction of
// recapPatch.applyTo out of handleUpdateServer makes possible without a request or a
// database.

func strp(s string) *string { return &s }
func intp(i int) *int       { return &i }

func TestRecapPatchPresent(t *testing.T) {
	if (recapPatch{}).present() {
		t.Error("an empty patch should not be present")
	}
	for name, p := range map[string]recapPatch{
		"cadence": {cadence: strp("weekly")},
		"weekday": {weekday: intp(3)},
		"hour":    {hour: intp(9)},
		"offset":  {offset: intp(0)},
	} {
		if !p.present() {
			t.Errorf("%s alone should count as present", name)
		}
	}
}

func TestRecapPatchHourBounds(t *testing.T) {
	for _, tc := range []struct {
		hour  int
		valid bool
	}{
		{-1, false}, {0, true}, {12, true}, {23, true}, {24, false}, {99, false},
	} {
		got, msg := recapPatch{hour: intp(tc.hour)}.applyTo(db.RecapSettings{})
		if tc.valid {
			if msg != "" {
				t.Errorf("hour %d rejected: %s", tc.hour, msg)
			} else if got.Hour != tc.hour {
				t.Errorf("hour %d applied as %d", tc.hour, got.Hour)
			}
			continue
		}
		if msg == "" {
			t.Errorf("hour %d accepted, want rejected", tc.hour)
		}
	}
}

func TestRecapPatchWeekdayBounds(t *testing.T) {
	for _, tc := range []struct {
		weekday int
		valid   bool
	}{
		{0, false}, {1, true}, {7, true}, {8, false}, {99, false},
	} {
		got, msg := recapPatch{weekday: intp(tc.weekday)}.applyTo(db.RecapSettings{})
		if tc.valid {
			if msg != "" {
				t.Errorf("weekday %d rejected: %s", tc.weekday, msg)
			} else if got.Weekday != tc.weekday {
				t.Errorf("weekday %d applied as %d", tc.weekday, got.Weekday)
			}
			continue
		}
		if msg == "" {
			t.Errorf("weekday %d accepted, want rejected", tc.weekday)
		}
	}
}

// Real UTC offsets span -12:00 to +14:00, the same bound NotifyPrefs.Normalize uses.
func TestRecapPatchOffsetBounds(t *testing.T) {
	for _, tc := range []struct {
		offset int
		valid  bool
	}{
		{-13 * 60, false}, {-12 * 60, true}, {0, true}, {14 * 60, true}, {15 * 60, false},
	} {
		got, msg := recapPatch{offset: intp(tc.offset)}.applyTo(db.RecapSettings{})
		if tc.valid {
			if msg != "" {
				t.Errorf("offset %d rejected: %s", tc.offset, msg)
			} else if got.Offset != tc.offset {
				t.Errorf("offset %d applied as %d", tc.offset, got.Offset)
			}
			continue
		}
		if msg == "" {
			t.Errorf("offset %d accepted, want rejected", tc.offset)
		}
	}
}

func TestRecapPatchCadence(t *testing.T) {
	for _, c := range []string{"off", "weekly", "monthly"} {
		got, msg := recapPatch{cadence: strp(c)}.applyTo(db.RecapSettings{})
		if msg != "" {
			t.Errorf("cadence %q rejected: %s", c, msg)
		} else if got.Cadence != c {
			t.Errorf("cadence %q applied as %q", c, got.Cadence)
		}
	}
	for _, c := range []string{"", "daily", "Weekly", "yearly"} {
		if _, msg := (recapPatch{cadence: strp(c)}).applyTo(db.RecapSettings{}); msg == "" {
			t.Errorf("cadence %q accepted, want rejected", c)
		}
	}
}

// Fields the request left out must survive untouched, since the handler writes back every
// field of what applyTo returns.
func TestRecapPatchLeavesAbsentFieldsAlone(t *testing.T) {
	current := db.RecapSettings{Cadence: "weekly", Weekday: 3, Hour: 9, Offset: -300}
	got, msg := recapPatch{hour: intp(18)}.applyTo(current)
	if msg != "" {
		t.Fatalf("unexpected rejection: %s", msg)
	}
	if got.Hour != 18 {
		t.Errorf("Hour = %d, want 18", got.Hour)
	}
	if got.Cadence != "weekly" || got.Weekday != 3 || got.Offset != -300 {
		t.Errorf("absent fields changed: %+v", got)
	}
}

// The first failing field decides the message, and nothing is applied on rejection.
func TestRecapPatchRejectsOnFirstInvalidField(t *testing.T) {
	current := db.RecapSettings{Cadence: "off"}
	_, msg := recapPatch{cadence: strp("daily"), hour: intp(99)}.applyTo(current)
	if msg == "" {
		t.Fatal("expected rejection")
	}
	if msg != "recapCadence must be 'off', 'weekly' or 'monthly'" {
		t.Errorf("message = %q, want the cadence one (it is validated first)", msg)
	}
}
