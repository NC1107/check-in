package api

import (
	"context"
	"errors"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/nc1107/check-in/server/internal/db"
)

// recapTick is how often the scheduler checks whether a standing recap is due. Well inside
// an hour, so the truncated period computed within the target hour (see recapDuePeriod) is
// stable across ticks - a restart or a repeated tick in the same hour can't miscompute a
// different period_start and slip past the idempotency guard.
const recapTick = 10 * time.Minute

// recapV1Panels is every panel a scheduled recap carries in v1. There's no per-cadence
// panel picker for the standing schedule (unlike the on-demand endpoint, which lets an
// admin choose) - the map and social-graph panels are v1.5. Awards Night was retired in
// favour of profile titles (see generateScheduledRecap's BestowTitles call).
var recapV1Panels = []string{"collage"}

// recapMaxManualSpan bounds an on-demand recap's custom period: a year plus a day of slack
// for the query's exclusive end, generous enough for any legitimate "this year" request
// while ruling out an accidental (or malicious) span that would scan the whole table.
const recapMaxManualSpan = 366 * 24 * time.Hour

// StartRecapScheduler runs the periodic-recap loop until ctx is cancelled. Unlike
// StartDigestScheduler it is NOT gated on push being configured: a recap is a feed post,
// not a push-only feature, so a push-less self-hoster still gets one - only the
// notification itself is skipped (see notifyRecap).
func (s *Server) StartRecapScheduler(ctx context.Context) {
	go func() {
		t := time.NewTicker(recapTick)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				s.runRecapTick(ctx)
			}
		}
	}()
}

// runRecapTick checks whether the group's standing cadence is due this hour and, if so,
// generates it. Off the request path and outside chi's Recoverer, like runDigest: recover,
// and bound the work so a slow query can't wedge the ticker.
func (s *Server) runRecapTick(ctx context.Context) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("runRecapTick: recovered: %v", rec)
		}
	}()
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	settings, err := s.db.GetRecapSettings(ctx)
	if err != nil {
		log.Printf("runRecapTick: settings: %v", err)
		return
	}
	if settings.Cadence == "off" {
		return
	}
	start, end, due := recapDuePeriod(settings, time.Now())
	if !due {
		return
	}
	if start.Before(settings.Since) {
		return // backfill guard: this period predates the feature being turned on
	}
	// Cheap pre-check before the heavier BuildRecap work: the tick fires every 10 minutes
	// for the whole target hour, and CreateRecapPost's advisory lock only needs to run once
	// the answer is actually "not yet generated".
	exists, err := s.db.RecapExistsForPeriod(ctx, settings.Cadence, start)
	if err != nil {
		log.Printf("runRecapTick: exists check: %v", err)
		return
	}
	if exists {
		return
	}
	s.generateScheduledRecap(ctx, settings.Cadence, start, end)
}

// recapDuePeriod reports whether now is the group's chosen recap moment and, if so, the
// [start, end) window the recap should cover. end is truncated to the top of the target
// local hour (not the tick's actual minute), so every tick within that hour - a restart, a
// double fire - computes the exact same instant and therefore the same period_start.
func recapDuePeriod(settings db.RecapSettings, now time.Time) (start, end time.Time, due bool) {
	local := now.UTC().Add(time.Duration(settings.Offset) * time.Minute)
	if local.Hour() != settings.Hour {
		return time.Time{}, time.Time{}, false
	}
	switch settings.Cadence {
	case "weekly":
		if isoWeekday(local) != settings.Weekday {
			return time.Time{}, time.Time{}, false
		}
	case "monthly":
		if local.Day() != 1 {
			return time.Time{}, time.Time{}, false
		}
	default:
		return time.Time{}, time.Time{}, false
	}
	endLocal := time.Date(local.Year(), local.Month(), local.Day(), settings.Hour, 0, 0, 0, time.UTC)
	end = endLocal.Add(-time.Duration(settings.Offset) * time.Minute)
	if settings.Cadence == "monthly" {
		start = end.AddDate(0, -1, 0)
	} else {
		start = end.AddDate(0, 0, -7)
	}
	return start, end, true
}

// isoWeekday converts Go's Sunday=0 weekday to ISO's Monday=1..Sunday=7, matching
// recap_weekday's stored convention (see 0018's doc comment).
func isoWeekday(t time.Time) int {
	if wd := int(t.Weekday()); wd != 0 {
		return wd
	}
	return 7
}

// generateScheduledRecap builds and stores one standing-cadence recap, pushing a
// notification only when it is genuinely new (never on a raced no-op).
func (s *Server) generateScheduledRecap(ctx context.Context, cadence string, start, end time.Time) {
	spec := db.RecapSpec{PeriodStart: start, PeriodEnd: end, Panels: recapV1Panels, Cadence: cadence, Origin: "scheduled"}
	payload, err := s.db.BuildRecap(ctx, spec)
	if errors.Is(err, db.ErrRecapEmpty) {
		return // quality bar not met: say nothing, same philosophy as runDigest
	}
	if err != nil {
		log.Printf("generateScheduledRecap: build: %v", err)
		return
	}
	adminID, err := s.db.AdminUserID(ctx)
	if err != nil {
		log.Printf("generateScheduledRecap: admin: %v", err)
		return
	}
	postID, inserted, _, err := s.db.CreateRecapPost(ctx, adminID, spec, payload, nil)
	if err != nil {
		log.Printf("generateScheduledRecap: create: %v", err)
		return
	}
	if !inserted {
		return // another tick or process already generated this period
	}
	// Titles are bestowed in the same flow as every scheduled recap, unconditionally - unlike
	// the on-demand endpoint there's no per-request opt-in for the standing schedule. A
	// failure here doesn't unwind the post: the recap itself already exists and is more
	// valuable than the titles are timely.
	if err := s.db.BestowTitles(ctx, start, end); err != nil {
		log.Printf("generateScheduledRecap: bestow titles: %v", err)
	}
	go s.notifyRecap(postID)
}

// notifyRecap pushes a recap-ready notification to every active member's devices. It fires
// independently of each member's digest setting (0013: digest "replaces new-post pushes
// only", and a recap is neither), and there is no recap-specific opt-out yet - that's
// v1.5's NotifyPrefs.recap toggle. collapseID keys on the post so a duplicate delivery
// attempt collapses to one notification; a replace never calls this at all.
func (s *Server) notifyRecap(postID int64) {
	if s.push == nil {
		return
	}
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("notifyRecap: recovered: %v", rec)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tokens, err := s.db.TokensForAllActive(ctx)
	if err != nil || len(tokens) == 0 {
		return
	}
	s.push.Send(ctx, tokens, s.serverName(ctx), "Your recap is ready",
		s.pushData("recap", postID), "recap-"+strconv.FormatInt(postID, 10))
}

// recapValidPanels is every panel type the on-demand endpoint accepts in v1. Awards Night
// was retired in favour of profile titles - "awards" is no longer accepted here even though
// a payload already generated with it (before this version) still round-trips fine.
var recapValidPanels = map[string]bool{"collage": true}

type generateRecapReq struct {
	PeriodStart string   `json:"periodStart"` // RFC3339
	PeriodEnd   string   `json:"periodEnd"`   // RFC3339, exclusive
	Panels      []string `json:"panels"`
	// Replace, when true and a manual recap already exists for the same period and panel
	// set, deletes it and inserts the new one in one transaction instead of returning 409.
	Replace bool `json:"replace"`
	// BestowTitles, when true, runs the same title-bestowal pass a scheduled recap tick
	// runs automatically (see generateScheduledRecap) for this manual recap's period.
	// Omitted (never sent as false) by a client until the server has advertised the
	// "titles" capability on /api/server-info - this server rejects unknown JSON fields, and
	// an older server has nowhere to put it.
	BestowTitles bool `json:"bestowTitles,omitempty"`
}

// handleGenerateRecap is the on-demand recap endpoint: admin-only, alongside
// PATCH /api/admin/server. A duplicate request for the same (periodStart, periodEnd,
// panels) is confirmed, never silently duplicated - see FindManualRecap.
func (s *Server) handleGenerateRecap(w http.ResponseWriter, r *http.Request) {
	var req generateRecapReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	start, err := time.Parse(time.RFC3339, req.PeriodStart)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "periodStart must be RFC3339")
		return
	}
	end, err := time.Parse(time.RFC3339, req.PeriodEnd)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "periodEnd must be RFC3339")
		return
	}
	if !end.After(start) {
		writeErr(w, http.StatusBadRequest, "periodEnd must be after periodStart")
		return
	}
	if end.Sub(start) > recapMaxManualSpan {
		writeErr(w, http.StatusBadRequest, "the period can't be longer than 366 days")
		return
	}
	// requested keeps the order the client asked for - it becomes spec.Panels, which
	// BuildRecap renders pages in verbatim (see RecapSpec.Panels' doc comment). sorted is a
	// separate, canonical (alphabetical) view of the exact same set, used only as the
	// order-independent lookup/storage key FindManualRecap and CreateRecapPost key duplicate
	// detection on - it must never be the one handed to BuildRecap, or render order would
	// silently collapse to alphabetical regardless of what was requested.
	requested := orderedUniquePanels(req.Panels)
	if len(requested) == 0 {
		writeErr(w, http.StatusBadRequest, "panels must include at least one of: collage")
		return
	}
	for _, p := range requested {
		if !recapValidPanels[p] {
			writeErr(w, http.StatusBadRequest, "unknown panel type: "+p)
			return
		}
	}
	sorted := sortedUniquePanels(req.Panels)

	ctx := r.Context()
	existingID, found, err := s.db.FindManualRecap(ctx, start, end, sorted)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if found && !req.Replace {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":  "a recap for this period and these panels already exists",
			"postId": existingID,
		})
		return
	}

	spec := db.RecapSpec{PeriodStart: start, PeriodEnd: end, Panels: requested, Cadence: "custom", Origin: "manual"}
	payload, err := s.db.BuildRecap(ctx, spec)
	if errors.Is(err, db.ErrRecapEmpty) {
		writeErr(w, http.StatusUnprocessableEntity, "not enough activity in this period yet")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}

	var replacePostID *int64
	if found && req.Replace {
		replacePostID = &existingID
	}
	me := userFrom(r)
	postID, inserted, conflictID, err := s.db.CreateRecapPost(ctx, me.ID, spec, payload, replacePostID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if !inserted {
		// The pre-check above (FindManualRecap) found nothing, or replace was requested
		// against a stale id - but CreateRecapPost's own lock-guarded check, which is the
		// authoritative one, found a duplicate anyway: another request for this exact
		// period and panel set won the race between the pre-check and here. Same 409 shape
		// either way, so the client's replace flow handles it identically.
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":  "a recap for this period and these panels already exists",
			"postId": conflictID,
		})
		return
	}
	// A replace is a correction, not a new event - it never re-pushes.
	if replacePostID == nil {
		go s.notifyRecap(postID)
	}
	// Manual generation never touches titles unless the admin explicitly opted in for this
	// request - unlike the scheduler, there's no standing default here. A bestowal failure
	// doesn't fail the request: the recap post itself already exists.
	if req.BestowTitles {
		if err := s.db.BestowTitles(ctx, start, end); err != nil {
			log.Printf("handleGenerateRecap: bestow titles: %v", err)
		}
	}
	post, err := s.db.GetPost(ctx, me.ID, postID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusCreated, post)
}

// sortedUniquePanels trims, dedupes and sorts a requested panel list, so the same set
// requested in any order compares equal (both to itself across requests and to how
// CreateRecapPost stores recaps.panels).
func sortedUniquePanels(panels []string) []string {
	seen := make(map[string]bool, len(panels))
	out := make([]string, 0, len(panels))
	for _, p := range panels {
		p = strings.TrimSpace(p)
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// orderedUniquePanels trims and dedupes a requested panel list while preserving the order
// it was requested in - the order the generated deck renders its pages in (see
// RecapSpec.Panels). Distinct from sortedUniquePanels, which normalises to a canonical
// (alphabetical) order for the duplicate-recap lookup/storage key: that's a different
// concern from render order, and conflating the two (passing the sorted list to BuildRecap)
// was the bug behind a recap coming back with its panels in alphabetical order regardless
// of what was requested - see TestOrderedUniquePanelsPreservesRequestOrder.
func orderedUniquePanels(panels []string) []string {
	seen := make(map[string]bool, len(panels))
	out := make([]string, 0, len(panels))
	for _, p := range panels {
		p = strings.TrimSpace(p)
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	return out
}
