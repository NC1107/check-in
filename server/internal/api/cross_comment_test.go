package api

import "testing"

// The push collapse id is what stops one comment, sent to three groups, arriving as three
// notifications on a device that belongs to all three. Each group is its own server and they
// cannot coordinate, so the only thing tying the copies together is the id the client
// generated - see applyCollapse for how it reaches APNs and Android.
func TestCollapseForSharedComment(t *testing.T) {
	if got := collapseFor("comment", ""); got != noCollapse {
		t.Errorf("a comment sent to one group must not collapse; got %q", got)
	}
	if got := collapseFor("comment", "shared-2f9c"); got != "comment:shared-2f9c" {
		t.Errorf("collapseFor = %q, want comment:shared-2f9c", got)
	}
}

// A comment that is also a reply fires BOTH notifyReply and notifyCommentReply. If they
// shared a collapse id, the second would replace the first on the device and the post's
// author would silently never learn about it.
func TestCollapseKindsStayDistinct(t *testing.T) {
	comment := collapseFor("comment", "shared-2f9c")
	reply := collapseFor("reply", "shared-2f9c")
	if comment == reply {
		t.Fatalf("both notifications for one comment collapsed onto %q - one would be lost", comment)
	}
}

// The id's exact shape is a contract between servers that never talk to each other: every
// copy has to derive a byte-identical string from the same shared id, or the copies simply
// do not collapse and the mechanism is a silent no-op. Pinning the literal is what catches a
// change to the format - comparing the function against itself would only ever be a
// tautology.
func TestCollapseIdFormatIsPinned(t *testing.T) {
	if got := collapseFor("comment", "abc"); got != "comment:abc" {
		t.Errorf("collapse id = %q, want comment:abc - a different shape on one server means "+
			"its copies never collapse against another's", got)
	}
	if got := collapseFor("reply", "abc"); got != "reply:abc" {
		t.Errorf("collapse id = %q, want reply:abc", got)
	}
}
