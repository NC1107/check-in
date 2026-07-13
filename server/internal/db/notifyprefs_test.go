package db

import "testing"

// A bad or buggy client must not be able to park a member on a digest hour that never
// comes round - the scheduler only ever matches an exact local hour.
func TestNotifyPrefsNormalize(t *testing.T) {
	tests := []struct {
		name       string
		in         NotifyPrefs
		wantHour   int
		wantOffset int
	}{
		{"valid values are left alone", NotifyPrefs{DigestHour: 8, DigestOffset: -300}, 8, -300},
		{"midnight is a real hour", NotifyPrefs{DigestHour: 0, DigestOffset: 0}, 0, 0},
		{"hour 23 is a real hour", NotifyPrefs{DigestHour: 23, DigestOffset: 0}, 23, 0},
		{"hour past the clock falls back to 8pm", NotifyPrefs{DigestHour: 24}, 20, 0},
		{"negative hour falls back to 8pm", NotifyPrefs{DigestHour: -1}, 20, 0},
		{"offset beyond +14:00 falls back to UTC", NotifyPrefs{DigestHour: 9, DigestOffset: 900}, 9, 0},
		{"offset beyond -12:00 falls back to UTC", NotifyPrefs{DigestHour: 9, DigestOffset: -800}, 9, 0},
		{"the real extremes are kept", NotifyPrefs{DigestHour: 9, DigestOffset: 840}, 9, 840},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.in.Normalize()
			if got.DigestHour != tt.wantHour {
				t.Errorf("DigestHour = %d, want %d", got.DigestHour, tt.wantHour)
			}
			if got.DigestOffset != tt.wantOffset {
				t.Errorf("DigestOffset = %d, want %d", got.DigestOffset, tt.wantOffset)
			}
		})
	}
}
