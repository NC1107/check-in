package db

import "testing"

// TestFilterRecapForViewerNoBlocksIsNoOp pins the fast path: a viewer with no blocks at all
// gets the payload back untouched (same slices, same stats) rather than a needlessly
// rebuilt copy.
func TestFilterRecapForViewerNoBlocksIsNoOp(t *testing.T) {
	payload := RecapPayload{
		Stats:  RecapStats{Posts: 3, Posters: 2},
		People: []RecapPerson{{UserID: 1, Posts: 2}, {UserID: 2, Posts: 1}},
		Panels: []RecapPanel{{Type: "collage", Cards: []RecapCard{{AuthorID: 1}, {AuthorID: 2}}}},
	}
	got := FilterRecapForViewer(payload, nil)
	if len(got.Panels) != 1 || len(got.Panels[0].Cards) != 2 {
		t.Fatalf("panels/cards changed with no blocks: %+v", got.Panels)
	}
	if got.Stats.Posts != 3 || got.Stats.Posters != 2 {
		t.Fatalf("stats changed with no blocks: %+v", got.Stats)
	}
}

// TestFilterRecapForViewerDropsBlockedAuthorsCardAndRosterEntry is the core behavior: a
// blocked author's card and roster entry disappear, and Stats.Posts/Posters are recomputed
// to match what's left rather than still counting the hidden author's contribution.
func TestFilterRecapForViewerDropsBlockedAuthorsCardAndRosterEntry(t *testing.T) {
	payload := RecapPayload{
		Stats: RecapStats{Posts: 5, Posters: 2, Likes: 20, Comments: 4, Places: 3},
		People: []RecapPerson{
			{UserID: 10, Name: "Loud", Posts: 3},
			{UserID: 20, Name: "Quiet", Posts: 2},
		},
		Panels: []RecapPanel{{
			Type: "collage",
			Cards: []RecapCard{
				{Kind: "photo", AuthorID: 10, PostID: 1},
				{Kind: "photo", AuthorID: 10, PostID: 2},
				{Kind: "quote", AuthorID: 20, PostID: 3},
			},
		}},
	}

	got := FilterRecapForViewer(payload, map[int64]bool{10: true})

	if len(got.People) != 1 || got.People[0].UserID != 20 {
		t.Fatalf("People = %+v, want only the unblocked author (20)", got.People)
	}
	if len(got.Panels) != 1 {
		t.Fatalf("Panels = %+v, want the collage panel to survive (it still has a card)", got.Panels)
	}
	if len(got.Panels[0].Cards) != 1 || got.Panels[0].Cards[0].AuthorID != 20 {
		t.Fatalf("Cards = %+v, want only author 20's quote card", got.Panels[0].Cards)
	}
	if got.Stats.Posts != 2 {
		t.Errorf("Stats.Posts = %d, want 2 (only the unblocked author's post count)", got.Stats.Posts)
	}
	if got.Stats.Posters != 1 {
		t.Errorf("Stats.Posters = %d, want 1", got.Stats.Posters)
	}
	// Aggregate engagement totals are a deliberately accepted approximation - see
	// FilterRecapForViewer's doc comment for why they aren't narrowed to the filtered set.
	if got.Stats.Likes != 20 || got.Stats.Comments != 4 || got.Stats.Places != 3 {
		t.Errorf("Likes/Comments/Places changed unexpectedly: %+v", got.Stats)
	}
}

// TestFilterRecapForViewerDropsAPanelEmptiedEntirely pins the "no empty page" guarantee: if
// every card AND every award in a panel belonged to blocked authors, the whole panel is
// dropped rather than left in as a title with nothing under it - matching the client's own
// contract that a panel is never appended without at least one card (recap_card.dart).
func TestFilterRecapForViewerDropsAPanelEmptiedEntirely(t *testing.T) {
	payload := RecapPayload{
		People: []RecapPerson{{UserID: 10, Posts: 1}},
		Panels: []RecapPanel{
			{Type: "collage", Cards: []RecapCard{{AuthorID: 10}}},
			{Type: "awards", Awards: []RecapAward{{ID: "most_liked", UserID: 10}}},
		},
	}

	got := FilterRecapForViewer(payload, map[int64]bool{10: true})

	if len(got.Panels) != 0 {
		t.Fatalf("Panels = %+v, want both panels dropped (everything in them was blocked)", got.Panels)
	}
	if got.Stats.Posts != 0 || got.Stats.Posters != 0 {
		t.Errorf("Stats = %+v, want zeroed out when nobody survives filtering", got.Stats)
	}
}

// TestFilterRecapForViewerKeepsAPanelWithSomeSurvivingContent confirms a panel with a mix of
// blocked and unblocked cards keeps the panel and only drops the blocked entries.
func TestFilterRecapForViewerKeepsAPanelWithSomeSurvivingContent(t *testing.T) {
	payload := RecapPayload{
		People: []RecapPerson{{UserID: 10, Posts: 1}, {UserID: 20, Posts: 1}},
		Panels: []RecapPanel{{
			Type: "collage",
			Cards: []RecapCard{
				{AuthorID: 10, PostID: 1},
				{AuthorID: 20, PostID: 2},
			},
		}},
	}

	got := FilterRecapForViewer(payload, map[int64]bool{10: true})

	if len(got.Panels) != 1 || len(got.Panels[0].Cards) != 1 || got.Panels[0].Cards[0].AuthorID != 20 {
		t.Fatalf("Panels = %+v, want the panel to survive with only author 20's card", got.Panels)
	}
}
