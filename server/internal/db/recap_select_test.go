package db

import (
	"testing"
	"time"
)

func t0(i int) time.Time {
	return time.Date(2026, 8, 10, 0, 0, 0, 0, time.UTC).Add(time.Duration(i) * time.Hour)
}

func mid(id int64) *int64 { return &id }

func TestCollageCardCap(t *testing.T) {
	tests := []struct {
		name        string
		cadence     string
		memberCount int
		want        int
	}{
		{"weekly base", "weekly", 4, 12},
		{"monthly base", "monthly", 4, 20},
		{"weekly rises to member count", "weekly", 15, 15},
		{"monthly rises to member count", "monthly", 25, 25},
		{"ceiling at 40 regardless of member count", "weekly", 100, 40},
		{"unknown cadence falls back to the weekly base", "custom", 4, 12},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := collageCardCap(tt.cadence, tt.memberCount); got != tt.want {
				t.Errorf("collageCardCap(%q, %d) = %d, want %d", tt.cadence, tt.memberCount, got, tt.want)
			}
		})
	}
}

// TestSelectCollageCardsEveryoneIncluded pins the everyone-included guarantee: with 6
// members who each posted at least once, every one of them has exactly one card in the
// result, even the two who never got a single like.
func TestSelectCollageCardsEveryoneIncluded(t *testing.T) {
	candidates := []recapCandidate{
		{PostID: 1, AuthorID: 1, MediaID: mid(101), LikeCount: 9, CreatedAt: t0(1)},
		{PostID: 2, AuthorID: 2, MediaID: mid(102), LikeCount: 5, CreatedAt: t0(2)},
		{PostID: 3, AuthorID: 3, MediaID: mid(103), LikeCount: 3, CreatedAt: t0(3)},
		{PostID: 4, AuthorID: 4, MediaID: mid(104), LikeCount: 0, CreatedAt: t0(4)},
		{PostID: 5, AuthorID: 5, MediaID: mid(105), LikeCount: 0, CreatedAt: t0(5)},
		{PostID: 6, AuthorID: 6, Body: "no photo, just words", LikeCount: 0, CreatedAt: t0(6)},
	}
	cards := selectCollageCards(candidates, 6, "weekly")
	if len(cards) != 6 {
		t.Fatalf("got %d cards, want 6 (one per member)", len(cards))
	}
	authors := make(map[int64]bool, 6)
	for _, c := range cards {
		authors[c.AuthorID] = true
		if !c.Guaranteed {
			t.Errorf("card for author %d should be marked guaranteed - every author's single "+
				"best post is guaranteed a slot", c.AuthorID)
		}
	}
	for id := int64(1); id <= 6; id++ {
		if !authors[id] {
			t.Errorf("author %d has no card - the everyone-included guarantee was violated", id)
		}
	}
}

// TestSelectCollageCardsRankingOrder pins that cards come back ranked by like count,
// highest first, with sequential 1-based ranks.
func TestSelectCollageCardsRankingOrder(t *testing.T) {
	candidates := []recapCandidate{
		{PostID: 1, AuthorID: 1, MediaID: mid(1), LikeCount: 3, CreatedAt: t0(1)},
		{PostID: 2, AuthorID: 2, MediaID: mid(2), LikeCount: 9, CreatedAt: t0(2)},
		{PostID: 3, AuthorID: 3, MediaID: mid(3), LikeCount: 5, CreatedAt: t0(3)},
	}
	cards := selectCollageCards(candidates, 3, "weekly")
	wantOrder := []int64{2, 3, 1} // by like count desc: 9, 5, 3
	if len(cards) != len(wantOrder) {
		t.Fatalf("got %d cards, want %d", len(cards), len(wantOrder))
	}
	for i, c := range cards {
		if c.AuthorID != wantOrder[i] {
			t.Errorf("card[%d].AuthorID = %d, want %d (rank order by likes desc)", i, c.AuthorID, wantOrder[i])
		}
		if c.Rank != i+1 {
			t.Errorf("card[%d].Rank = %d, want %d", i, c.Rank, i+1)
		}
	}
}

// TestSelectCollageCardsTiebreaks pins all three tiebreaks in order: comment count desc,
// then created_at asc (earlier wins), then post id asc. Each subtest holds the prior
// tiebreaks equal so it isolates exactly one rule.
func TestSelectCollageCardsTiebreaks(t *testing.T) {
	t.Run("comment count breaks a like-count tie, higher first", func(t *testing.T) {
		candidates := []recapCandidate{
			{PostID: 1, AuthorID: 1, MediaID: mid(1), LikeCount: 5, CommentCount: 1, CreatedAt: t0(1)},
			{PostID: 2, AuthorID: 2, MediaID: mid(2), LikeCount: 5, CommentCount: 4, CreatedAt: t0(2)},
		}
		cards := selectCollageCards(candidates, 2, "weekly")
		if cards[0].AuthorID != 2 {
			t.Errorf("first card author = %d, want 2 (more comments wins a like-count tie)", cards[0].AuthorID)
		}
	})

	t.Run("created_at breaks a like+comment tie, earlier first", func(t *testing.T) {
		candidates := []recapCandidate{
			{PostID: 1, AuthorID: 1, MediaID: mid(1), LikeCount: 5, CommentCount: 2, CreatedAt: t0(5)},
			{PostID: 2, AuthorID: 2, MediaID: mid(2), LikeCount: 5, CommentCount: 2, CreatedAt: t0(1)},
		}
		cards := selectCollageCards(candidates, 2, "weekly")
		if cards[0].AuthorID != 2 {
			t.Errorf("first card author = %d, want 2 (earlier created_at wins the remaining tie)", cards[0].AuthorID)
		}
	})

	t.Run("post id breaks a fully tied score, lower first", func(t *testing.T) {
		same := t0(1)
		candidates := []recapCandidate{
			{PostID: 9, AuthorID: 1, MediaID: mid(1), LikeCount: 5, CommentCount: 2, CreatedAt: same},
			{PostID: 2, AuthorID: 2, MediaID: mid(2), LikeCount: 5, CommentCount: 2, CreatedAt: same},
		}
		cards := selectCollageCards(candidates, 2, "weekly")
		if cards[0].PostID != 2 {
			t.Errorf("first card post id = %d, want 2 (lowest id wins a fully tied score)", cards[0].PostID)
		}
	})
}

// TestSelectCollageCardsPerAuthorFillCap pins the fill-pass cap: after their guaranteed
// slot, one prolific author can fill at most 2 more slots even when they have enough
// highly-liked posts to take every remaining one.
func TestSelectCollageCardsPerAuthorFillCap(t *testing.T) {
	var candidates []recapCandidate
	// Author 1 posted 6 times, every post beating everyone else's.
	for i := 0; i < 6; i++ {
		candidates = append(candidates, recapCandidate{
			PostID: int64(i + 1), AuthorID: 1, MediaID: mid(int64(i + 1)),
			LikeCount: 100 - i, CreatedAt: t0(i),
		})
	}
	// Two other members with a single ordinary post each.
	candidates = append(candidates,
		recapCandidate{PostID: 100, AuthorID: 2, MediaID: mid(100), LikeCount: 1, CreatedAt: t0(10)},
		recapCandidate{PostID: 101, AuthorID: 3, MediaID: mid(101), LikeCount: 1, CreatedAt: t0(11)},
	)
	// Cap high enough (weekly base 12) that the cap itself isn't the constraint being
	// tested - the per-author fill limit is.
	cards := selectCollageCards(candidates, 3, "weekly")
	authorOneCount := 0
	for _, c := range cards {
		if c.AuthorID == 1 {
			authorOneCount++
		}
	}
	// 1 guaranteed + 2 fill = 3, even though author 1 had 6 posts that all outscored
	// authors 2 and 3.
	if authorOneCount != 3 {
		t.Errorf("author 1 has %d cards, want 3 (1 guaranteed + fill capped at 2)", authorOneCount)
	}
	if len(cards) != 5 {
		t.Errorf("got %d cards, want 5 (3 from author 1, 1 each for authors 2 and 3)", len(cards))
	}
}

// TestSelectCollageCardsQuoteCard pins that a member whose only qualifying post is
// text-only still gets their guaranteed slot, rendered as a quote card rather than being
// dropped for having no attachment.
func TestSelectCollageCardsQuoteCard(t *testing.T) {
	candidates := []recapCandidate{
		{PostID: 1, AuthorID: 1, MediaID: mid(1), LikeCount: 9, CreatedAt: t0(1)},
		{PostID: 2, AuthorID: 2, Body: "made it to the top, barely", LikeCount: 2, CreatedAt: t0(2)},
	}
	cards := selectCollageCards(candidates, 2, "weekly")
	var quote *RecapCard
	for i := range cards {
		if cards[i].AuthorID == 2 {
			quote = &cards[i]
		}
	}
	if quote == nil {
		t.Fatal("author 2 (text-only post) has no card - the guarantee dropped a text-only member")
	}
	if quote.Kind != "quote" {
		t.Errorf("kind = %q, want %q", quote.Kind, "quote")
	}
	if quote.Body != "made it to the top, barely" {
		t.Errorf("body = %q, want the post's text", quote.Body)
	}
	if quote.MediaID != nil {
		t.Errorf("quote card carries a media id %v, want nil", *quote.MediaID)
	}
}

// TestSelectCollageCardsCapRisesToMemberCount pins that the cap rises to the member count
// when the group is larger than the cadence's base cap - the guarantee outranks the cap -
// but never rises above the 40-card ceiling.
func TestSelectCollageCardsCapRisesToMemberCount(t *testing.T) {
	t.Run("weekly base is 12, but 15 members each get a card", func(t *testing.T) {
		var candidates []recapCandidate
		for i := int64(1); i <= 15; i++ {
			candidates = append(candidates, recapCandidate{
				PostID: i, AuthorID: i, MediaID: mid(i), LikeCount: int(i), CreatedAt: t0(int(i)),
			})
		}
		cards := selectCollageCards(candidates, 15, "weekly")
		if len(cards) != 15 {
			t.Errorf("got %d cards, want 15 (cap rises to the member count)", len(cards))
		}
	})

	t.Run("ceiling holds at 40 even for a much larger group", func(t *testing.T) {
		var candidates []recapCandidate
		for i := int64(1); i <= 60; i++ {
			candidates = append(candidates, recapCandidate{
				PostID: i, AuthorID: i, MediaID: mid(i), LikeCount: int(i), CreatedAt: t0(int(i)),
			})
		}
		cards := selectCollageCards(candidates, 60, "weekly")
		if len(cards) != 40 {
			t.Errorf("got %d cards, want 40 (the hard ceiling)", len(cards))
		}
	})
}

func TestSelectCollageCardsEmpty(t *testing.T) {
	if got := selectCollageCards(nil, 5, "weekly"); got != nil {
		t.Errorf("selectCollageCards(nil, ...) = %v, want nil", got)
	}
}

// ---- Awards Night ----

func award(userID int64, qualifies bool, value int, display string, postID int64) awardEntry {
	if !qualifies {
		return awardEntry{}
	}
	return awardEntry{Qualifies: true, Value: value, DisplayValue: display, PostID: postID}
}

func TestSelectAwardsOnlyEmitsQualifyingCategories(t *testing.T) {
	candidates := []awardCandidate{
		{UserID: 1, UserName: "Ada", MostLiked: award(1, true, 9, "9 likes", 1)},
	}
	awards := selectAwards(candidates)
	if len(awards) != 1 {
		t.Fatalf("got %d awards, want 1 (only most_liked has a qualifier)", len(awards))
	}
	if awards[0].ID != "most_liked" || awards[0].UserID != 1 {
		t.Errorf("award = %+v, want most_liked for user 1", awards[0])
	}
}

func TestSelectAwardsEmptyInput(t *testing.T) {
	if got := selectAwards(nil); got != nil {
		t.Errorf("selectAwards(nil) = %v, want nil", got)
	}
}

// TestSelectAwardsSpreadsWhenPossible pins the spreading rule: when Ada is the top
// qualifier in two categories and Ben is a genuine (if lesser) qualifier in one of them,
// Ada keeps the category she leads outright and Ben gets the other rather than Ada
// sweeping both.
func TestSelectAwardsSpreadsWhenPossible(t *testing.T) {
	candidates := []awardCandidate{
		{
			UserID: 1, UserName: "Ada",
			MostLiked: award(1, true, 9, "9 likes", 1),
			NightOwl:  award(1, true, 1380, "11:00 PM", 1),
		},
		{
			UserID: 2, UserName: "Ben",
			NightOwl: award(2, true, 1200, "8:00 PM", 2),
		},
	}
	awards := selectAwards(candidates)
	byID := map[string]RecapAward{}
	for _, a := range awards {
		byID[a.ID] = a
	}
	if byID["most_liked"].UserID != 1 {
		t.Errorf("most_liked winner = %d, want 1 (Ada, the only qualifier)", byID["most_liked"].UserID)
	}
	if byID["night_owl"].UserID != 2 {
		t.Errorf("night_owl winner = %d, want 2 (Ben) - Ada should keep most_liked and let Ben "+
			"have night_owl rather than sweeping both", byID["night_owl"].UserID)
	}
}

// TestSelectAwardsNeverWithholdsASoleQualifier pins that spreading never costs an award
// its only qualifier: when Ada is the sole qualifier in two categories, she wins both.
func TestSelectAwardsNeverWithholdsASoleQualifier(t *testing.T) {
	candidates := []awardCandidate{
		{
			UserID: 1, UserName: "Ada",
			MostLiked: award(1, true, 9, "9 likes", 1),
			NightOwl:  award(1, true, 1380, "11:00 PM", 1),
		},
	}
	awards := selectAwards(candidates)
	if len(awards) != 2 {
		t.Fatalf("got %d awards, want 2 (both categories have exactly one qualifier: Ada)", len(awards))
	}
	for _, a := range awards {
		if a.UserID != 1 {
			t.Errorf("award %s went to user %d, want 1 (Ada, the sole qualifier)", a.ID, a.UserID)
		}
	}
}
