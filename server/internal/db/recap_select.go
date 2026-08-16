package db

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// recapCandidate is one post considered for the collage panel: enough about it, its
// author, and its best attachment (if any) to rank it and render a card. Gathered by
// BuildRecap; ranked by selectCollageCards. A nil MediaID means a text-only post, which
// renders as a quote card rather than being excluded.
type recapCandidate struct {
	PostID        int64
	AuthorID      int64
	AuthorName    string
	AuthorPhotoID *int64
	Body          string
	MediaID       *int64
	Mime          string
	Width, Height int
	DurationMs    int
	HasPoster     bool
	Location      string
	LikeCount     int
	CommentCount  int
	CreatedAt     time.Time
}

// collageCardCap returns the Wall panel's card limit for a cadence and group size: 12
// weekly / 20 monthly, but never below the group's member count - the everyone-included
// guarantee outranks the cap - and never above 40, so a very large group still gets a
// bounded deck.
func collageCardCap(cadence string, memberCount int) int {
	base := 12
	if cadence == "monthly" {
		base = 20
	}
	n := base
	if memberCount > n {
		n = memberCount
	}
	if n > 40 {
		n = 40
	}
	return n
}

// candidateOutranks reports whether a ranks strictly ahead of b: by like count (desc),
// then comment count (desc), then created_at (asc - whoever posted first wins a tie),
// then post id (asc) so the order is fully deterministic.
func candidateOutranks(a, b recapCandidate) bool {
	if a.LikeCount != b.LikeCount {
		return a.LikeCount > b.LikeCount
	}
	if a.CommentCount != b.CommentCount {
		return a.CommentCount > b.CommentCount
	}
	if !a.CreatedAt.Equal(b.CreatedAt) {
		return a.CreatedAt.Before(b.CreatedAt)
	}
	return a.PostID < b.PostID
}

// selectCollageCards ranks candidates into the Wall panel's cards.
//
// Membership and ranking are separate concerns. Pass 1: every distinct author's single
// best post is guaranteed a slot, so nobody who checked in is left out of their own
// group's recap. Pass 2: the remaining slots up to the cap are filled from the leftover
// pool by score, capped at 2 more per author so one prolific member can't dominate the
// panel. Pass 3: the guaranteed and filled sets are merged and sorted by score - the
// guarantee decides who's in, the ranking decides the order.
func selectCollageCards(candidates []recapCandidate, memberCount int, cadence string) []RecapCard {
	if len(candidates) == 0 {
		return nil
	}
	ranked := make([]recapCandidate, len(candidates))
	copy(ranked, candidates)
	sort.Slice(ranked, func(i, j int) bool { return candidateOutranks(ranked[i], ranked[j]) })

	limit := collageCardCap(cadence, memberCount)

	guaranteed := make([]recapCandidate, 0, memberCount)
	seenAuthor := make(map[int64]bool, memberCount)
	for _, c := range ranked {
		if seenAuthor[c.AuthorID] {
			continue
		}
		seenAuthor[c.AuthorID] = true
		guaranteed = append(guaranteed, c)
	}

	selected := make([]recapCandidate, len(guaranteed))
	copy(selected, guaranteed)
	inSelected := make(map[int64]bool, len(guaranteed)) // by post id
	for _, c := range guaranteed {
		inSelected[c.PostID] = true
	}
	fillCount := make(map[int64]int, memberCount) // per author, fill-pass posts only
	for _, c := range ranked {
		if len(selected) >= limit {
			break
		}
		if inSelected[c.PostID] {
			continue
		}
		if fillCount[c.AuthorID] >= 2 {
			continue
		}
		selected = append(selected, c)
		inSelected[c.PostID] = true
		fillCount[c.AuthorID]++
	}

	sort.Slice(selected, func(i, j int) bool { return candidateOutranks(selected[i], selected[j]) })
	if len(selected) > limit {
		selected = selected[:limit]
	}

	cards := make([]RecapCard, len(selected))
	for i, c := range selected {
		cards[i] = candidateToCard(c, i+1, guaranteedPost(guaranteed, c.PostID))
	}
	return cards
}

// guaranteedPost reports whether postID is one of the guaranteed-slot posts.
func guaranteedPost(guaranteed []recapCandidate, postID int64) bool {
	for _, c := range guaranteed {
		if c.PostID == postID {
			return true
		}
	}
	return false
}

// candidateToCard renders one ranked candidate as a card: a quote card for a text-only
// post (nil MediaID), otherwise a photo or clip card keyed off the attachment's mime type.
func candidateToCard(c recapCandidate, rank int, guaranteed bool) RecapCard {
	card := RecapCard{
		Rank:          rank,
		Guaranteed:    guaranteed,
		PostID:        c.PostID,
		AuthorID:      c.AuthorID,
		AuthorName:    c.AuthorName,
		AuthorPhotoID: c.AuthorPhotoID,
		LikeCount:     c.LikeCount,
		CommentCount:  c.CommentCount,
		Location:      c.Location,
	}
	if c.MediaID == nil {
		card.Kind = "quote"
		card.Body = c.Body
		return card
	}
	if strings.HasPrefix(c.Mime, "video/") {
		card.Kind = "clip"
	} else {
		card.Kind = "photo"
	}
	card.MediaID = c.MediaID
	card.Mime = c.Mime
	card.Width = c.Width
	card.Height = c.Height
	card.DurationMs = c.DurationMs
	card.HasPoster = c.HasPoster
	return card
}

// ---- Awards Night ----

// awardEntry is one member's qualifying showing for one superlative, or the zero value
// when they don't qualify at all (Qualifies false) - selectAwards never invents a winner
// for an award nobody earned. Value ranks candidates within an award (higher wins);
// DisplayValue is the already-formatted label ("9 likes") BuildRecap computed for it.
type awardEntry struct {
	Qualifies    bool
	Value        int
	DisplayValue string
	PostID       int64 // 0 when the award isn't tied to one specific post
	MediaID      *int64
}

// awardCandidate is one active member's showing across every superlative Awards Night can
// hand out, gathered by BuildRecap and judged by selectAwards.
type awardCandidate struct {
	UserID      int64
	UserName    string
	UserPhotoID *int64

	MostLiked     awardEntry
	NightOwl      awardEntry
	EarlyBird     awardEntry
	MostTravelled awardEntry
	Chatterbox    awardEntry
	BiggestFan    awardEntry
	QuietAchiever awardEntry
	MostTagged    awardEntry
	LongestThread awardEntry
}

// awardType names one superlative and how to read its entry off an awardCandidate.
type awardType struct {
	id, label string
	entry     func(awardCandidate) awardEntry
}

// awardOrder is the fixed judging order Awards Night hands out superlatives in. It drives
// both the guarantee pass (a member's award is whichever type they're rank 1 in that comes
// first here) and the panel's display order, so results are fully deterministic.
var awardOrder = []awardType{
	{"most_liked", "Most Loved", func(c awardCandidate) awardEntry { return c.MostLiked }},
	{"night_owl", "Night Owl", func(c awardCandidate) awardEntry { return c.NightOwl }},
	{"early_bird", "Early Bird", func(c awardCandidate) awardEntry { return c.EarlyBird }},
	{"most_travelled", "Most Travelled", func(c awardCandidate) awardEntry { return c.MostTravelled }},
	{"chatterbox", "Chatterbox", func(c awardCandidate) awardEntry { return c.Chatterbox }},
	{"biggest_fan", "Biggest Fan", func(c awardCandidate) awardEntry { return c.BiggestFan }},
	{"quiet_achiever", "Quiet Achiever", func(c awardCandidate) awardEntry { return c.QuietAchiever }},
	{"most_tagged", "Most Tagged", func(c awardCandidate) awardEntry { return c.MostTagged }},
	{"longest_thread", "Longest Thread", func(c awardCandidate) awardEntry { return c.LongestThread }},
}

// selectAwards judges every superlative and returns the ones with a qualifying winner, in
// awardOrder. Only emits an award that has at least one qualifying candidate - it never
// posts a "winner" nobody actually earned.
//
// With few members and nine awards, one person can easily lead every category they
// qualify for. selectAwards prefers spreading them out, using the same two-pass shape as
// the collage: pass 1 lets each member (in a deterministic order) claim the single
// category they rank best in, as long as nobody has claimed it already; pass 2 emits
// every category that has a qualifying winner, resolving it to whichever qualifier
// claimed it in pass 1, or its outright top candidate when nobody did. An award is never
// withheld - a category with only one qualifier always goes to them, sweep or not.
func selectAwards(candidates []awardCandidate) []RecapAward {
	if len(candidates) == 0 {
		return nil
	}
	// Rank each award type's qualifying candidates once, best first (value desc, then
	// user id asc for a deterministic tiebreak), and index each qualifier's rank within
	// it (0 = best) so pass 1 can find a member's single best category.
	ranked := make(map[string][]awardCandidate, len(awardOrder))
	rankOf := make(map[string]map[int64]int, len(awardOrder)) // award id -> user id -> rank
	for _, at := range awardOrder {
		var qualifying []awardCandidate
		for _, c := range candidates {
			if at.entry(c).Qualifies {
				qualifying = append(qualifying, c)
			}
		}
		sort.Slice(qualifying, func(i, j int) bool {
			vi, vj := at.entry(qualifying[i]).Value, at.entry(qualifying[j]).Value
			if vi != vj {
				return vi > vj
			}
			return qualifying[i].UserID < qualifying[j].UserID
		})
		ranked[at.id] = qualifying
		byUser := make(map[int64]int, len(qualifying))
		for i, c := range qualifying {
			byUser[c.UserID] = i
		}
		rankOf[at.id] = byUser
	}

	// Pass 1: each member, in user-id order, claims the category they rank best in
	// (ties broken by awardOrder position), if it's still unclaimed.
	byMember := make([]awardCandidate, len(candidates))
	copy(byMember, candidates)
	sort.Slice(byMember, func(i, j int) bool { return byMember[i].UserID < byMember[j].UserID })

	claimedBy := make(map[string]int64, len(awardOrder)) // award id -> the user who claimed it
	for _, c := range byMember {
		bestType, bestRank := "", -1
		for _, at := range awardOrder {
			r, ok := rankOf[at.id][c.UserID]
			if !ok {
				continue
			}
			if bestRank == -1 || r < bestRank {
				bestType, bestRank = at.id, r
			}
		}
		if bestType == "" {
			continue // qualifies for nothing
		}
		if _, taken := claimedBy[bestType]; !taken {
			claimedBy[bestType] = c.UserID
		}
	}

	// Pass 2: emit every category with a qualifying winner.
	var out []RecapAward
	for _, at := range awardOrder {
		top := ranked[at.id]
		if len(top) == 0 {
			continue
		}
		winner := top[0]
		if claimant, ok := claimedBy[at.id]; ok {
			for _, c := range top {
				if c.UserID == claimant {
					winner = c
					break
				}
			}
		}
		entry := at.entry(winner)
		award := RecapAward{
			ID:          at.id,
			Label:       at.label,
			UserID:      winner.UserID,
			UserName:    winner.UserName,
			UserPhotoID: winner.UserPhotoID,
			Value:       entry.DisplayValue,
		}
		if entry.PostID != 0 {
			award.PostID = &entry.PostID
			award.MediaID = entry.MediaID
		}
		out = append(out, award)
	}
	return out
}

// pluralize renders "%d word" or "%d words" - the recap payload's small formatting helper
// for award and stat labels ("9 likes", "1 place").
func pluralize(n int, singular string) string {
	if n == 1 {
		return fmt.Sprintf("1 %s", singular)
	}
	return fmt.Sprintf("%d %ss", n, singular)
}
