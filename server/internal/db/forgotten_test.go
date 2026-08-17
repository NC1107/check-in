package db

import (
	"testing"
	"time"
)

// TestForgottenPhotoEligible pins forgottenPhotoEligible's three predicates (has-media, the
// age floor, the engagement ceiling) independently of any database, including their exact
// boundaries - the same edge cases ForgottenPhoto's SQL WHERE clause has to get right, but
// exercised here as plain Go so every case runs without Postgres.
func TestForgottenPhotoEligible(t *testing.T) {
	now := time.Date(2026, time.August, 17, 12, 0, 0, 0, time.UTC)
	old := now.Add(-forgottenAgeFloor - time.Hour)    // just past the floor
	recent := now.Add(-forgottenAgeFloor + time.Hour) // just short of the floor
	exactlyAtFloor := now.Add(-forgottenAgeFloor)     // the boundary itself

	tests := []struct {
		name         string
		hasMedia     bool
		createdAt    time.Time
		likeCount    int
		commentCount int
		want         bool
	}{
		{"old, no engagement, has media: eligible", true, old, 0, 0, true},
		{"old, at the engagement ceiling: still eligible", true, old, 1, 1, true},
		{"old, one over the engagement ceiling: not eligible", true, old, 2, 1, false},
		{"old, heavily engaged: not eligible", true, old, 12, 4, false},
		{"old but no media at all: not eligible - this is photos, not text", false, old, 0, 0, false},
		{"has media and no engagement but too recent: not eligible", true, recent, 0, 0, false},
		{"exactly at the floor is not yet old enough - the floor is exclusive", true, exactlyAtFloor, 0, 0, false},
		{"a single stray like from a small group still reads as forgotten", true, old, 1, 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := forgottenPhotoEligible(tt.hasMedia, tt.createdAt, now, tt.likeCount, tt.commentCount)
			if got != tt.want {
				t.Errorf("forgottenPhotoEligible(hasMedia=%v, age=%v, likes=%d, comments=%d) = %v, want %v",
					tt.hasMedia, now.Sub(tt.createdAt), tt.likeCount, tt.commentCount, got, tt.want)
			}
		})
	}
}

// TestForgottenEngagementCeilingIsNotZero pins the deliberate choice, argued in
// forgottenEngagementCeiling's own doc comment, that a single stray touch does not disqualify
// a post: requiring literal zero would be too strict for a small group, where one friend's
// passing like is still, in every practical sense, neglect.
func TestForgottenEngagementCeilingIsNotZero(t *testing.T) {
	if forgottenEngagementCeiling == 0 {
		t.Fatal("forgottenEngagementCeiling = 0, want > 0 - a small group's single stray like " +
			"must not disqualify an otherwise-forgotten photo")
	}
}
