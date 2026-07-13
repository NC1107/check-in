package api

import "testing"

func TestDigestBody(t *testing.T) {
	tests := []struct {
		n    int
		want string
	}{
		{1, "1 new check-in while you were away"},
		{8, "8 new check-ins while you were away"},
	}
	for _, tt := range tests {
		if got := digestBody(tt.n); got != tt.want {
			t.Errorf("digestBody(%d) = %q, want %q", tt.n, got, tt.want)
		}
	}
}
