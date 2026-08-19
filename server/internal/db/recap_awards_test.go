package db

import (
	"testing"
	"time"
)

// The per-award ranking rules had no coverage at all: swapping Night Owl's comparator for
// Early Bird's left the whole suite green. These exercise each rule directly, which is
// possible now that aggregateMemberActivity is a pure function over its inputs.

func at(hour, min int) time.Time {
	return time.Date(2026, 3, 14, hour, min, 0, 0, time.UTC)
}

// cand builds a candidate for one author with the fields the award rules read.
func cand(postID, authorID int64, created time.Time, likes, comments int, location string) recapCandidate {
	return recapCandidate{
		PostID:       postID,
		AuthorID:     authorID,
		CreatedAt:    created,
		LikeCount:    likes,
		CommentCount: comments,
		Location:     location,
	}
}

func oneMember(id int64) []recapMember {
	return []recapMember{{ID: id, Name: "Ada"}}
}

func TestAggregateNightOwlPicksLatestTimeOfDay(t *testing.T) {
	agg := aggregateMemberActivity(oneMember(1), []recapCandidate{
		cand(10, 1, at(9, 0), 0, 0, ""),
		cand(11, 1, at(23, 30), 0, 0, ""),
		cand(12, 1, at(14, 15), 0, 0, ""),
	})
	if got := agg[1].nightOwl.PostID; got != 11 {
		t.Errorf("night owl = post %d, want 11 (23:30, the latest)", got)
	}
}

func TestAggregateEarlyBirdPicksEarliestTimeOfDay(t *testing.T) {
	agg := aggregateMemberActivity(oneMember(1), []recapCandidate{
		cand(10, 1, at(9, 0), 0, 0, ""),
		cand(11, 1, at(23, 30), 0, 0, ""),
		cand(12, 1, at(5, 45), 0, 0, ""),
	})
	if got := agg[1].earlyBird.PostID; got != 12 {
		t.Errorf("early bird = post %d, want 12 (05:45, the earliest)", got)
	}
}

// Night Owl and Early Bird must not collapse onto the same post when several exist - the
// exact confusion a swapped comparator would produce.
func TestAggregateNightOwlAndEarlyBirdDiffer(t *testing.T) {
	agg := aggregateMemberActivity(oneMember(1), []recapCandidate{
		cand(10, 1, at(6, 0), 0, 0, ""),
		cand(11, 1, at(22, 0), 0, 0, ""),
	})
	a := agg[1]
	if a.nightOwl.PostID == a.earlyBird.PostID {
		t.Fatalf("night owl and early bird both = post %d", a.nightOwl.PostID)
	}
	if a.nightOwl.PostID != 11 || a.earlyBird.PostID != 10 {
		t.Errorf("night owl = %d (want 11), early bird = %d (want 10)",
			a.nightOwl.PostID, a.earlyBird.PostID)
	}
}

func TestAggregateMostLikedAndLongestThread(t *testing.T) {
	agg := aggregateMemberActivity(oneMember(1), []recapCandidate{
		cand(10, 1, at(9, 0), 12, 1, ""),
		cand(11, 1, at(10, 0), 3, 20, ""),
	})
	a := agg[1]
	if a.mostLiked.PostID != 10 {
		t.Errorf("most liked = post %d, want 10 (12 likes)", a.mostLiked.PostID)
	}
	if a.longestThread.PostID != 11 {
		t.Errorf("longest thread = post %d, want 11 (20 comments)", a.longestThread.PostID)
	}
}

// A tie on the headline number falls through to candidateOutranks, so the winner is stable
// rather than dependent on the order rows came back in.
func TestAggregateMostLikedTieIsStable(t *testing.T) {
	early := cand(10, 1, at(9, 0), 5, 0, "")
	late := cand(11, 1, at(17, 0), 5, 0, "")

	forward := aggregateMemberActivity(oneMember(1), []recapCandidate{early, late})
	reversed := aggregateMemberActivity(oneMember(1), []recapCandidate{late, early})

	if forward[1].mostLiked.PostID != reversed[1].mostLiked.PostID {
		t.Errorf("tie resolved by input order: %d vs %d",
			forward[1].mostLiked.PostID, reversed[1].mostLiked.PostID)
	}
	if got := forward[1].mostLiked.PostID; got != 10 {
		t.Errorf("most liked = post %d, want 10 (earlier wins the tie)", got)
	}
}

func TestAggregateCountsPostsLikesAndDistinctPlaces(t *testing.T) {
	agg := aggregateMemberActivity(oneMember(1), []recapCandidate{
		cand(10, 1, at(9, 0), 2, 0, "Denver"),
		cand(11, 1, at(10, 0), 3, 0, "Denver"),
		cand(12, 1, at(11, 0), 4, 0, "Baltimore"),
		cand(13, 1, at(12, 0), 1, 0, ""),
	})
	a := agg[1]
	if a.postCount != 4 {
		t.Errorf("postCount = %d, want 4", a.postCount)
	}
	if a.likesReceived != 10 {
		t.Errorf("likesReceived = %d, want 10", a.likesReceived)
	}
	// Denver twice is one place, and the empty location is not a place at all.
	if len(a.places) != 2 {
		t.Errorf("places = %d, want 2", len(a.places))
	}
}

// recapCandidates already excludes departed authors; this is the belt-and-braces path.
func TestAggregateSkipsCandidatesFromInactiveAuthors(t *testing.T) {
	agg := aggregateMemberActivity(oneMember(1), []recapCandidate{
		cand(10, 1, at(9, 0), 1, 0, ""),
		cand(11, 99, at(9, 0), 50, 0, ""),
	})
	if _, ok := agg[99]; ok {
		t.Error("aggregated activity for an author who is not an active member")
	}
	if agg[1].postCount != 1 {
		t.Errorf("postCount = %d, want 1", agg[1].postCount)
	}
}

func TestAveragePostCountIgnoresMembersWhoDidNotPost(t *testing.T) {
	agg := map[int64]*memberActivity{
		1: {postCount: 4},
		2: {postCount: 2},
		3: {postCount: 0}, // must not drag the average down
	}
	if got := averagePostCount(agg); got != 3 {
		t.Errorf("averagePostCount = %v, want 3", got)
	}
}

func TestAveragePostCountEmpty(t *testing.T) {
	if got := averagePostCount(map[int64]*memberActivity{}); got != 0 {
		t.Errorf("averagePostCount = %v, want 0", got)
	}
}

// Early Bird's Value is inverted so bestAwardPerMember's single "higher wins" rule means
// earliest; a straight minute-of-day would rank it backwards.
func TestAwardCandidateEarlyBirdValueIsInverted(t *testing.T) {
	a := &memberActivity{places: map[string]struct{}{}}
	early := cand(10, 1, at(5, 0), 0, 0, "")
	a.earlyBird = &early

	c := awardCandidateFor(recapMember{ID: 1, Name: "Ada"}, a, memberCounts{}, 0)
	if !c.EarlyBird.Qualifies {
		t.Fatal("early bird should qualify")
	}
	if want := 1440 - 300; c.EarlyBird.Value != want {
		t.Errorf("early bird value = %d, want %d", c.EarlyBird.Value, want)
	}
	if c.EarlyBird.DisplayValue != "5:00 AM" {
		t.Errorf("early bird display = %q, want \"5:00 AM\"", c.EarlyBird.DisplayValue)
	}
}

// Quiet Achiever is only open to members at or below the average post count.
func TestAwardCandidateQuietAchieverEligibility(t *testing.T) {
	for _, tc := range []struct {
		name      string
		postCount int
		avgPosts  float64
		qualifies bool
	}{
		{"below average", 2, 5, true},
		{"exactly average", 5, 5, true},
		{"above average", 8, 5, false},
		{"posted nothing", 0, 5, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := &memberActivity{
				places:        map[string]struct{}{},
				postCount:     tc.postCount,
				likesReceived: tc.postCount * 2,
			}
			c := awardCandidateFor(recapMember{ID: 1}, a, memberCounts{}, tc.avgPosts)
			if c.QuietAchiever.Qualifies != tc.qualifies {
				t.Errorf("qualifies = %v, want %v", c.QuietAchiever.Qualifies, tc.qualifies)
			}
		})
	}
}

// The three activity-on-others tallies are keyed by member, so one member's counts must
// never be read for another.
func TestAwardCandidateReadsItsOwnCounts(t *testing.T) {
	counts := memberCounts{
		commentsWritten: map[int64]int{1: 7, 2: 99},
		likesGiven:      map[int64]int{1: 4},
		timesTagged:     map[int64]int{2: 50},
	}
	a := &memberActivity{places: map[string]struct{}{}}
	c := awardCandidateFor(recapMember{ID: 1}, a, counts, 0)

	if c.Chatterbox.Value != 7 {
		t.Errorf("chatterbox = %d, want 7", c.Chatterbox.Value)
	}
	if c.BiggestFan.Value != 4 {
		t.Errorf("biggest fan = %d, want 4", c.BiggestFan.Value)
	}
	if c.MostTagged.Qualifies {
		t.Error("most tagged should not qualify: member 1 has no tags")
	}
}

// An award with a zero headline number is not worth showing, so it must not qualify.
func TestAwardCandidateZeroValuesDoNotQualify(t *testing.T) {
	unliked := cand(10, 1, at(9, 0), 0, 0, "")
	a := &memberActivity{
		places:        map[string]struct{}{},
		mostLiked:     &unliked,
		longestThread: &unliked,
	}
	c := awardCandidateFor(recapMember{ID: 1}, a, memberCounts{}, 0)

	if c.MostLiked.Qualifies {
		t.Error("most liked should not qualify with 0 likes")
	}
	if c.LongestThread.Qualifies {
		t.Error("longest thread should not qualify with 0 comments")
	}
	if c.MostTravelled.Qualifies {
		t.Error("most travelled should not qualify with no places")
	}
}
