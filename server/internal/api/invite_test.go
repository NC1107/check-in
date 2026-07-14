package api

import "testing"

func TestInviteStateFor(t *testing.T) {
	tests := []struct {
		name       string
		allowed    bool
		registered bool
		want       inviteState
	}{
		{"not invited", false, false, inviteNone},
		{"invited, unclaimed", true, false, inviteOpen},
		{"invited, account exists", true, true, inviteClaimed},
		// The host is never on the allowlist, so signup must still turn them away rather
		// than report the number as free.
		{"host, not on the list", false, true, inviteNone},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := inviteStateFor(tt.allowed, tt.registered); got != tt.want {
				t.Errorf("inviteStateFor(allowed=%v, registered=%v) = %v, want %v",
					tt.allowed, tt.registered, got, tt.want)
			}
		})
	}
}

// A used invite whose account no longer exists is stale - a user row removed outside
// DeleteAccount (which deletes the invite with it) leaves it behind. The number is still
// invited and nobody holds it, so it must remain claimable; treating the flag as gospel
// dead-ends that number forever behind a false "already registered" that no admin screen
// can clear.
func TestInviteStateForStaleUsedInvite(t *testing.T) {
	if got := inviteStateFor(true, false); got != inviteOpen {
		t.Errorf("stale used invite = %v, want inviteOpen", got)
	}
}
