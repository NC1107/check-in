package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/nc1107/check-in/server/internal/auth"
	"github.com/nc1107/check-in/server/internal/db"
)

// peerUser is how another member appears to an ordinary member: everything db.User carries
// except the phone number, which this invite-only app treats as a credential (see
// docs/self-hosting/security.md) - handing it back for the whole roster in one request is
// what CRITICAL 2 of the pre-submission audit flagged. Only the caller's own record
// (GET /api/me and friends) and the admin-only user list legitimately return db.User with
// Phone still on it.
//
// PhoneKey stands in for Phone so the app's one legitimate use of a peer's number - joining
// the same human across the several groups a device is signed into, client-side - keeps
// working; see auth.PhoneMatchKey's doc comment for what it does and doesn't protect
// against.
type peerUser struct {
	ID             int64      `json:"id"`
	PhoneKey       string     `json:"phoneKey"`
	Name           string     `json:"name"`
	FirstName      string     `json:"firstName"`
	LastName       string     `json:"lastName"`
	BirthdayMonth  int        `json:"birthdayMonth"`
	BirthdayDay    int        `json:"birthdayDay"`
	ProfileMediaID *int64     `json:"profileMediaId,omitempty"`
	IsAdmin        bool       `json:"isAdmin"`
	Status         string     `json:"status"`
	CreatedAt      time.Time  `json:"createdAt"`
	Title          *string    `json:"title,omitempty"`
	TitleSetAt     *time.Time `json:"titleSetAt,omitempty"`
}

// newPeerUser converts a db.User to the shape a peer may see.
func newPeerUser(u db.User) peerUser {
	return peerUser{
		ID:             u.ID,
		PhoneKey:       auth.PhoneMatchKey(u.Phone),
		Name:           u.Name,
		FirstName:      u.FirstName,
		LastName:       u.LastName,
		BirthdayMonth:  int(u.Birthday.Month()),
		BirthdayDay:    u.Birthday.Day(),
		ProfileMediaID: u.ProfileMediaID,
		IsAdmin:        u.IsAdmin,
		Status:         u.Status,
		CreatedAt:      u.CreatedAt,
		Title:          u.Title,
		TitleSetAt:     u.TitleSetAt,
	}
}

// newPeerUsers converts a list the same way, never returning nil (an absent list should
// serialize as "[]", matching every other list handler in this package).
func newPeerUsers(users []db.User) []peerUser {
	out := make([]peerUser, len(users))
	for i, u := range users {
		out[i] = newPeerUser(u)
	}
	return out
}

func (s *Server) handleFeed(w http.ResponseWriter, r *http.Request) {
	viewer := userFrom(r)
	limit := parseLimit(r, 30, 100)

	var authorID *int64
	if a := r.URL.Query().Get("author"); a != "" {
		if id, err := strconv.ParseInt(a, 10, 64); err == nil {
			authorID = &id
		}
	}
	var before *time.Time
	if b := r.URL.Query().Get("before"); b != "" {
		if t, err := time.Parse(time.RFC3339, b); err == nil {
			before = &t
		}
	}
	// Optional id tiebreaker so posts sharing the boundary timestamp aren't skipped or
	// repeated across pages (composite (created_at, id) cursor).
	var beforeID *int64
	if b := r.URL.Query().Get("before_id"); b != "" {
		if n, err := strconv.ParseInt(b, 10, 64); err == nil {
			beforeID = &n
		}
	}
	// Repeated ?location=A&location=B selects posts matching any of them; absent = no filter.
	var locations []string
	for _, l := range r.URL.Query()["location"] {
		if l = strings.TrimSpace(l); l != "" {
			locations = append(locations, l)
		}
	}

	posts, err := s.db.Feed(r.Context(), viewer.ID, authorID, locations, before, beforeID, limit, false)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": posts})
}

// handleLocations lists the distinct place labels across all check-ins (most-used first),
// powering the feed's location filter.
func (s *Server) handleLocations(w http.ResponseWriter, r *http.Request) {
	locs, err := s.db.Locations(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"locations": locs})
}

// handleSearch is full-content search: it returns check-ins whose caption or comments
// match, plus people whose name matches. Queries shorter than 2 chars return empty.
func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if len([]rune(q)) < 2 {
		writeJSON(w, http.StatusOK, map[string]any{"posts": []any{}, "people": []any{}})
		return
	}
	posts, err := s.db.SearchPosts(r.Context(), userFrom(r).ID, q, parseLimit(r, 30, 50))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	people, err := s.db.SearchUsers(r.Context(), q, 10)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": posts, "people": newPeerUsers(people)})
}

func (s *Server) handleSearchUsers(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("search"))
	users, err := s.db.SearchUsers(r.Context(), q, parseLimit(r, 50, 200))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": newPeerUsers(users)})
}

func (s *Server) handleGetUser(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	user, err := s.db.GetUser(r.Context(), id)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "user not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, newPeerUser(user))
}

// handleUserPosts returns one person's timeline (git-history style): their posts in
// reverse-chronological order with cursor pagination. Recap posts are excluded even for
// the admin whose id authors them - a recap is a group artifact, not something they
// personally posted, and does not belong on their profile.
func (s *Server) handleUserPosts(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	var before *time.Time
	if b := r.URL.Query().Get("before"); b != "" {
		if t, err := time.Parse(time.RFC3339, b); err == nil {
			before = &t
		}
	}
	posts, err := s.db.Feed(r.Context(), userFrom(r).ID, &id, nil, before, nil, parseLimit(r, 30, 100), true)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": posts})
}

// createPostReq mostly gains no fields as media types are added: this server rejects
// unknown fields (decodeJSON's DisallowUnknownFields), so anything new here would make a
// new client unable to post to a server that has not been updated yet. Lat/Lng are the one
// exception, and the client is required to gate them the same way: it only sends them to a
// server whose /api/server-info advertises the "recap" capability, so an old server never
// sees a field it doesn't understand.
type createPostReq struct {
	Kind      string  `json:"kind"`      // client's claim about the post; validated, not stored
	Body      string  `json:"body"`      // text body or image caption
	MediaID   *int64  `json:"mediaId"`   // legacy single image (older app builds)
	MediaIDs  []int64 `json:"mediaIds"`  // one or more images, ordered
	Location  *string `json:"location"`  // optional coarse "City, Country" from the photo
	PeopleIDs []int64 `json:"peopleIds"` // members tagged as appearing in the post
	// CrossPostID ties this copy to the same post shared to other groups. Client-generated
	// and opaque; the server only stores it so the multi-group client can collapse copies.
	CrossPostID *string `json:"crossPostId"`
	// Lat/Lng are the coordinates behind Location, rounded client-side to 2 decimal places
	// (~1.1km) - strictly coarser than the place string itself. Stored for the v1.5 map
	// panel; nothing reads them back yet.
	Lat *float64 `json:"lat"`
	Lng *float64 `json:"lng"`
}

// createPostFields is a create-post request after validation: the media list the claimed
// kind actually implies, plus the optional fields once trimmed and bounded.
type createPostFields struct {
	body        string
	mediaIDs    []int64
	location    *string
	crossPostID *string
	lat, lng    *float64
}

// normalizeMediaIDs collapses the new mediaIds list and the legacy single mediaId into one
// ordered list, so everything downstream sees the same shape.
func normalizeMediaIDs(req createPostReq) []int64 {
	if len(req.MediaIDs) > 0 {
		return req.MediaIDs
	}
	if req.MediaID != nil {
		return []int64{*req.MediaID}
	}
	return nil
}

// checkPostKind treats the client's kind as a claim to check rather than a value to store:
// CreatePost derives the stored kind from what is actually attached, so a post can never
// describe itself as something it is not.
func checkPostKind(kind, body string, mediaCount int) string {
	switch kind {
	case "text":
		if body == "" {
			return "text posts need a body"
		}
	case "image", "video":
		if mediaCount == 0 {
			return "media posts need at least one attachment"
		}
		if mediaCount > 10 {
			return "too many attachments (max 10)"
		}
	default:
		return "kind must be 'text', 'image' or 'video'"
	}
	return ""
}

// boundedCrossPostID bounds the opaque client-generated group id and drops it if blank, so
// a stray empty string doesn't create a one-member "cross-post".
func boundedCrossPostID(v *string) *string {
	if v == nil {
		return nil
	}
	id := strings.TrimSpace(*v)
	if id == "" || len(id) > 64 {
		return nil
	}
	return &id
}

// boundedLocation trims and caps the coarse place label, dropping it if blank.
func boundedLocation(v *string) *string {
	if v == nil {
		return nil
	}
	loc := strings.TrimSpace(*v)
	if loc == "" {
		return nil
	}
	if len(loc) > 120 {
		loc = loc[:120]
	}
	return &loc
}

// validateCreatePost checks and normalizes the request, returning the message for the first
// failure. Pure, so every bound here is testable without a request or a database.
func validateCreatePost(req createPostReq) (createPostFields, string) {
	f := createPostFields{
		body:     strings.TrimSpace(req.Body),
		mediaIDs: normalizeMediaIDs(req),
	}
	if msg := checkPostKind(req.Kind, f.body, len(f.mediaIDs)); msg != "" {
		return f, msg
	}
	if req.Kind == "text" {
		f.mediaIDs = nil
	}
	if len(f.body) > 5000 {
		return f, "body too long"
	}
	if len(req.PeopleIDs) > 30 {
		return f, "too many tagged people (max 30)"
	}
	f.crossPostID = boundedCrossPostID(req.CrossPostID)
	// Location and coordinates are allowed on any post with an attachment, and are dropped
	// together when there is none to have carried GPS in the first place. Video mirrors
	// photos: the member chose to share where the clip was taken, and the file itself is
	// stripped either way. Whatever the client sent is clamped and rounded to 2 decimal
	// places in CreatePost itself, not here - so a modified client or a raw API call cannot
	// smuggle full-precision GPS past this handler by any other path into CreatePost.
	if len(f.mediaIDs) > 0 {
		f.location = boundedLocation(req.Location)
		f.lat, f.lng = req.Lat, req.Lng
	}
	return f, ""
}

func (s *Server) handleCreatePost(w http.ResponseWriter, r *http.Request) {
	var req createPostReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	f, msg := validateCreatePost(req)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}

	me := userFrom(r)
	post, err := s.db.CreatePost(r.Context(), me.ID, f.body, f.mediaIDs, f.location, req.PeopleIDs, f.crossPostID, f.lat, f.lng)
	if errors.Is(err, db.ErrNotOwned) {
		writeErr(w, http.StatusBadRequest, "one or more attachments are not yours")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not create post")
		return
	}
	sharedID := ""
	if post.CrossPostID != nil {
		sharedID = *post.CrossPostID
	}
	go s.notifyPost(me.ID, me.Name, post.ID, sharedID)
	writeJSON(w, http.StatusCreated, post)
}

func (s *Server) handleGetPost(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	post, err := s.db.GetPost(r.Context(), userFrom(r).ID, id)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, msgPostNotFound)
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, post)
}

func (s *Server) handleDeletePost(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	orphans, err := s.db.DeletePost(r.Context(), id, userFrom(r).ID)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "post not found or not yours")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	// Remove now-unreferenced media files from disk (best-effort; the rows are gone).
	for _, p := range orphans {
		_ = s.store.Delete(p)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleLike(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	me := userFrom(r)
	if visible, err := s.db.PostVisible(r.Context(), id, me.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	} else if !visible {
		writeErr(w, http.StatusNotFound, msgPostNotFound)
		return
	}
	inserted, err := s.db.LikePost(r.Context(), id, me.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	// Only push on a genuinely new like, so re-liking an already-liked post is silent.
	if inserted {
		go s.notifyLike(me.Name, id, me.ID)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleUnlike(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	if err := s.db.UnlikePost(r.Context(), id, userFrom(r).ID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleListLikers returns who liked a post. Only the post's author may see this, so a
// non-author (or a stranger) gets 403 rather than the list.
func (s *Server) handleListLikers(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	authorID, err := s.db.PostAuthorID(r.Context(), id)
	if errors.Is(err, db.ErrNotFound) {
		writeErr(w, http.StatusNotFound, msgPostNotFound)
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	if authorID != userFrom(r).ID {
		writeErr(w, http.StatusForbidden, "only the author can see who liked this")
		return
	}
	likers, err := s.db.PostLikers(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"likers": likers})
}

func (s *Server) handleListComments(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	viewerID := userFrom(r).ID
	// Gate on the post itself the same way handleLike and handleAddComment do - without
	// this, a post hidden from the viewer's feed (its author blocked or revoked) still
	// served its whole comment thread to anyone who knew or guessed the post id, even though
	// GET /api/posts/{id} correctly 404s for that same post. ListComments' own predicate only
	// ever excluded blocked *commenters*, never checked the post's own author.
	if visible, err := s.db.PostVisible(r.Context(), id, viewerID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	} else if !visible {
		writeErr(w, http.StatusNotFound, msgPostNotFound)
		return
	}
	comments, err := s.db.ListComments(r.Context(), id, viewerID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"comments": comments})
}

type addCommentReq struct {
	Body string `json:"body"`
	// ParentCommentID, when set, makes this a reply to that comment (which must be on the
	// same post). It notifies the parent's author on top of the post's author.
	ParentCommentID *int64 `json:"parentCommentId"`
	// MediaID attaches a gif the caller uploaded to this comment. A gif-only comment (no
	// body at all) is allowed - see the empty-body check below - so a member can reply with
	// just a reaction gif the way the app's own compose treats a photo-only check-in.
	MediaID *int64 `json:"mediaId"`
	// CrossCommentID ties this copy to the same comment sent to other groups. Client-
	// generated and opaque; the server only stores it so the multi-group client can collapse
	// copies, and passes it to the push layer so the copies collapse into one notification.
	// This server rejects unknown JSON fields (DisallowUnknownFields), so a client must only
	// send it once /api/server-info has advertised "crossComments".
	CrossCommentID *string `json:"crossCommentId"`
}

func (s *Server) handleAddComment(w http.ResponseWriter, r *http.Request) {
	id, err := pathInt(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidID)
		return
	}
	var req addCommentReq
	if err := decodeJSON(w, r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, msgInvalidBody)
		return
	}
	req.Body = strings.TrimSpace(req.Body)
	if msg := validateComment(req); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}

	me := userFrom(r)
	if visible, err := s.db.PostVisible(r.Context(), id, me.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	} else if !visible {
		writeErr(w, http.StatusNotFound, msgPostNotFound)
		return
	}
	// A reply must point at a real comment on this same post.
	if req.ParentCommentID != nil {
		parentPostID, _, found, err := s.db.ParentCommentForPost(r.Context(), *req.ParentCommentID)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, msgServerError)
			return
		}
		if !found || parentPostID != id {
			writeErr(w, http.StatusBadRequest, "reply target not found")
			return
		}
	}
	comment, err := s.db.AddComment(r.Context(), id, me.ID, req.Body, req.ParentCommentID, req.MediaID, crossCommentIDFrom(req.CrossCommentID))
	if errors.Is(err, db.ErrNotOwned) {
		writeErr(w, http.StatusBadRequest, "that attachment is not yours")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not add comment")
		return
	}
	// The shared id doubles as the push collapse key: one comment sent to three groups is
	// three servers each pushing, and without this a member of all three gets three
	// notifications for one thing said once (see applyCollapse).
	sharedComment := ""
	if comment.CrossCommentID != nil {
		sharedComment = *comment.CrossCommentID
	}
	go s.notifyReply(me.Name, id, me.ID, sharedComment)
	if req.ParentCommentID != nil {
		go s.notifyCommentReply(me.Name, id, *req.ParentCommentID, me.ID, sharedComment)
	}
	writeJSON(w, http.StatusCreated, comment)
}

// validateComment returns the error message for a comment that cannot be accepted, or "" when
// it is fine. Split out of the handler so the handler reads as the sequence of steps it
// performs rather than interleaving field checks with them.
func validateComment(req addCommentReq) string {
	if req.Body == "" && req.MediaID == nil {
		return "comment must have a body or a gif"
	}
	if len(req.Body) > 2000 {
		return "comment must be 1-2000 characters"
	}
	return ""
}

// crossCommentIDFrom normalizes the opaque client-generated group id: bounded in length, and
// dropped when blank so a stray empty string cannot create a one-member "cross-comment". The
// same handling crossPostId gets.
func crossCommentIDFrom(raw *string) *string {
	if raw == nil {
		return nil
	}
	id := strings.TrimSpace(*raw)
	if id == "" || len(id) > 64 {
		return nil
	}
	return &id
}

func (s *Server) handleUpcomingBirthdays(w http.ResponseWriter, r *http.Request) {
	birthdays, err := s.db.UpcomingBirthdays(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, msgServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"birthdays": birthdays})
}

func parseLimit(r *http.Request, def, max int) int {
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 {
			if n > max {
				return max
			}
			return n
		}
	}
	return def
}
