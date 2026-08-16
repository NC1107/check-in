package db

import (
	"encoding/json"
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

// ---- title bestowal ----

func award(userID int64, qualifies bool, value int, display string, postID int64) awardEntry {
	if !qualifies {
		return awardEntry{}
	}
	return awardEntry{Qualifies: true, Value: value, DisplayValue: display, PostID: postID}
}

func TestBestAwardPerMemberOnlyIncludesQualifyingMembers(t *testing.T) {
	candidates := []awardCandidate{
		{UserID: 1, UserName: "Ada", MostLiked: award(1, true, 9, "9 likes", 1)},
		{UserID: 2, UserName: "Ben"}, // qualifies for nothing
	}
	best := bestAwardPerMember(candidates)
	if len(best) != 1 {
		t.Fatalf("got %d entries, want 1 (only Ada qualifies for anything)", len(best))
	}
	if best[1] != "most_liked" {
		t.Errorf("best[1] = %q, want most_liked", best[1])
	}
	if _, ok := best[2]; ok {
		t.Error("Ben has an entry despite qualifying for no award")
	}
}

func TestBestAwardPerMemberEmptyInput(t *testing.T) {
	if got := bestAwardPerMember(nil); got != nil {
		t.Errorf("bestAwardPerMember(nil) = %v, want nil", got)
	}
}

// TestBestAwardPerMemberDoesNotSpread pins the deliberate behaviour difference from the
// retired Awards Night panel: bestAwardPerMember never resolves contention between
// members, so when Ada is the top qualifier in two categories, both are her "best" and
// both come back for her - even though Ben also qualifies in one of them. A title is each
// member's own best showing, never redirected to spread coverage.
func TestBestAwardPerMemberDoesNotSpread(t *testing.T) {
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
	best := bestAwardPerMember(candidates)
	if best[1] != "most_liked" {
		t.Errorf("best[1] = %q, want most_liked (Ada's strongest of her two qualifying categories)", best[1])
	}
	if best[2] != "night_owl" {
		t.Errorf("best[2] = %q, want night_owl (Ben's only qualifying category, regardless of Ada)", best[2])
	}
}

// TestBestAwardPerMemberTiebreaksByAwardOrder pins that when a member ranks equally well
// (rank 0, i.e. sole or top qualifier) in more than one category, awardOrder's position -
// not qualification order - decides which one wins as their "best".
func TestBestAwardPerMemberTiebreaksByAwardOrder(t *testing.T) {
	candidates := []awardCandidate{
		{
			UserID: 1, UserName: "Ada",
			// Ada is the sole qualifier in both, so she ranks 0th in each - a genuine tie
			// that only awardOrder's position (most_liked before longest_thread) can break.
			LongestThread: award(1, true, 4, "4 comments", 1),
			MostLiked:     award(1, true, 9, "9 likes", 1),
		},
	}
	best := bestAwardPerMember(candidates)
	if best[1] != "most_liked" {
		t.Errorf("best[1] = %q, want most_liked (earlier in awardOrder than longest_thread)", best[1])
	}
}

// TestRecapPeopleOrdersByPostCountDesc pins the cover roster's ranking: each distinct
// author's post count, highest first - the metric the client scales its avatar bubbles by
// (see recapPeople's doc comment for why post count rather than best-post likes).
func TestRecapPeopleOrdersByPostCountDesc(t *testing.T) {
	candidates := []recapCandidate{
		{PostID: 1, AuthorID: 1, AuthorName: "Ada", CreatedAt: t0(1)},
		{PostID: 2, AuthorID: 2, AuthorName: "Ben", CreatedAt: t0(2)},
		{PostID: 3, AuthorID: 2, AuthorName: "Ben", CreatedAt: t0(3)},
		{PostID: 4, AuthorID: 2, AuthorName: "Ben", CreatedAt: t0(4)},
		{PostID: 5, AuthorID: 3, AuthorName: "Cy", CreatedAt: t0(5)},
		{PostID: 6, AuthorID: 3, AuthorName: "Cy", CreatedAt: t0(6)},
	}
	people := recapPeople(candidates)
	wantOrder := []int64{2, 3, 1} // Ben (3 posts), Cy (2 posts), Ada (1 post)
	if len(people) != len(wantOrder) {
		t.Fatalf("got %d people, want %d", len(people), len(wantOrder))
	}
	for i, p := range people {
		if p.UserID != wantOrder[i] {
			t.Errorf("people[%d].UserID = %d, want %d", i, p.UserID, wantOrder[i])
		}
	}
	if people[0].Posts != 3 {
		t.Errorf("people[0].Posts = %d, want 3", people[0].Posts)
	}
	if people[0].Name != "Ben" {
		t.Errorf("people[0].Name = %q, want %q", people[0].Name, "Ben")
	}
}

// TestRecapPeopleTiebreaksByUserIDAsc pins the deterministic tiebreak for equal post
// counts: lower user id first, matching every other recap ranking's tiebreak convention.
func TestRecapPeopleTiebreaksByUserIDAsc(t *testing.T) {
	candidates := []recapCandidate{
		{PostID: 1, AuthorID: 9, AuthorName: "Zed", CreatedAt: t0(1)},
		{PostID: 2, AuthorID: 2, AuthorName: "Ada", CreatedAt: t0(2)},
	}
	people := recapPeople(candidates)
	if people[0].UserID != 2 {
		t.Errorf("people[0].UserID = %d, want 2 (lower id wins an equal-post-count tie)", people[0].UserID)
	}
}

// TestRecapPeopleCarriesPhotoID pins that a member's profile photo id survives into the
// roster - it is what the cover's avatar bubbles render as an image instead of an initial.
func TestRecapPeopleCarriesPhotoID(t *testing.T) {
	candidates := []recapCandidate{
		{PostID: 1, AuthorID: 1, AuthorName: "Ada", AuthorPhotoID: mid(77), CreatedAt: t0(1)},
	}
	people := recapPeople(candidates)
	if people[0].PhotoID == nil || *people[0].PhotoID != 77 {
		t.Errorf("people[0].PhotoID = %v, want 77", people[0].PhotoID)
	}
}

// TestCandidateToCardClip pins the video/* branch of candidateToCard: a candidate whose
// attachment is a clip becomes a "clip" card (not "photo"), and its DurationMs/HasPoster -
// the fields the app's Wall tile and cover montage need to show a play badge, a duration
// pill, and pick the poster-only render path rather than a raw AuthImage decode of the
// mp4 - survive the mapping. The video/photo branch itself (candidateToCard's if) has no
// other direct test; every other recap_select_test.go case exercises it implicitly through
// an empty Mime, which trivially takes the "photo" branch.
func TestCandidateToCardClip(t *testing.T) {
	c := recapCandidate{
		PostID: 1, AuthorID: 2, AuthorName: "Ada",
		MediaID: mid(500), Mime: "video/mp4", Width: 1080, Height: 1920,
		DurationMs: 8400, HasPoster: true,
		LikeCount: 3, CommentCount: 1,
	}
	card := candidateToCard(c, 1, true)

	if card.Kind != "clip" {
		t.Fatalf(`Kind = %q, want "clip" - a video/* mime must not fall through to "photo"`, card.Kind)
	}
	if card.MediaID == nil || *card.MediaID != 500 {
		t.Errorf("MediaID = %v, want 500", card.MediaID)
	}
	if card.Mime != "video/mp4" {
		t.Errorf("Mime = %q, want %q", card.Mime, "video/mp4")
	}
	if card.DurationMs != 8400 {
		t.Errorf("DurationMs = %d, want 8400 - dropped between the candidate and the card", card.DurationMs)
	}
	if !card.HasPoster {
		t.Error("HasPoster = false, want true - dropped between the candidate and the card")
	}

	// Round-tripped through JSON the same way the API actually serves it, checked against
	// the exact keys the client's RecapCard.fromJson reads (app/lib/api/models.dart) - a
	// struct-tag typo here would silently drop the field client-side with no compile error
	// on either end, which is exactly what would make the duration pill quietly never render.
	raw, err := json.Marshal(card)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal: %v", err)
	}
	if decoded["kind"] != "clip" {
		t.Errorf(`JSON "kind" = %v, want "clip"`, decoded["kind"])
	}
	if decoded["durationMs"] != float64(8400) {
		t.Errorf(`JSON "durationMs" = %v, want 8400`, decoded["durationMs"])
	}
	if decoded["hasPoster"] != true {
		t.Errorf(`JSON "hasPoster" = %v, want true`, decoded["hasPoster"])
	}
}
