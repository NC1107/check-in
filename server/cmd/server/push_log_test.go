package main

import (
	"strings"
	"testing"
)

// The boot line is the only place a host is told whether push actually reaches their members.
// It used to warn unconditionally, including on the servers where delivery works, which reads
// as "push is broken" to anyone scanning their logs.
func TestDirectPushLog(t *testing.T) {
	t.Run("the published project reports that delivery works", func(t *testing.T) {
		got := directPushLog(publishedFirebaseProject)
		if strings.Contains(got, "were not") || strings.Contains(got, "get nothing") {
			t.Errorf("credentials for the published project must not warn: %q", got)
		}
		if !strings.Contains(got, "receive notifications") {
			t.Errorf("expected confirmation that members are reached: %q", got)
		}
		if !strings.Contains(got, publishedFirebaseProject) {
			t.Errorf("expected the project id in the line: %q", got)
		}
	})

	t.Run("any other project keeps the warning", func(t *testing.T) {
		got := directPushLog("someone-elses-project")
		if !strings.Contains(got, "were not") {
			t.Errorf("a self-hoster's own project must still be warned: %q", got)
		}
		if !strings.Contains(got, "CHECKIN_FCM_CREDENTIALS_FILE") {
			t.Errorf("expected the way out to be named: %q", got)
		}
	})
}

// The published project id has to match what the shipped apps are built with, or the check
// above silently picks the wrong branch. Guarded here so a typo cannot pass unnoticed;
// app/android/app/google-services.json and app/ios/Runner/GoogleService-Info.plist are the
// source of truth.
func TestPublishedFirebaseProjectMatchesTheShippedApps(t *testing.T) {
	if publishedFirebaseProject != "check-in-48fdc" {
		t.Errorf("publishedFirebaseProject = %q, but the shipped apps use check-in-48fdc",
			publishedFirebaseProject)
	}
}
