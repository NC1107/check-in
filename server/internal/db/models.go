package db

import (
	"encoding/json"
	"time"
)

// User is a registered member of the server.
type User struct {
	ID    int64  `json:"id"`
	Phone string `json:"phone"`
	// Name is the display name shown throughout the app. FirstName/LastName are the
	// recorded full name, which may differ (some people prefer a nickname/first name only).
	Name           string    `json:"name"`
	FirstName      string    `json:"firstName"`
	LastName       string    `json:"lastName"`
	Birthday       time.Time `json:"-"` // exposed as month/day only, see MarshalJSON
	ProfileMediaID *int64    `json:"profileMediaId,omitempty"`
	IsAdmin        bool      `json:"isAdmin"`
	Status         string    `json:"status"`
	CreatedAt      time.Time `json:"createdAt"`
}

// MarshalJSON emits only the month and day of the birthday, never the year, so a member's
// age is never exposed over the API (the app only ever shows month + day).
func (u User) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		ID             int64     `json:"id"`
		Phone          string    `json:"phone"`
		Name           string    `json:"name"`
		FirstName      string    `json:"firstName"`
		LastName       string    `json:"lastName"`
		BirthdayMonth  int       `json:"birthdayMonth"`
		BirthdayDay    int       `json:"birthdayDay"`
		ProfileMediaID *int64    `json:"profileMediaId,omitempty"`
		IsAdmin        bool      `json:"isAdmin"`
		Status         string    `json:"status"`
		CreatedAt      time.Time `json:"createdAt"`
	}{
		ID:             u.ID,
		Phone:          u.Phone,
		Name:           u.Name,
		FirstName:      u.FirstName,
		LastName:       u.LastName,
		BirthdayMonth:  int(u.Birthday.Month()),
		BirthdayDay:    u.Birthday.Day(),
		ProfileMediaID: u.ProfileMediaID,
		IsAdmin:        u.IsAdmin,
		Status:         u.Status,
		CreatedAt:      u.CreatedAt,
	})
}

// NotifyPrefs is a member's notification settings: the three instant opt-outs, plus an
// optional daily digest that replaces per-check-in pushes with one summary.
type NotifyPrefs struct {
	Posts   bool `json:"posts"`
	Replies bool `json:"replies"`
	Likes   bool `json:"likes"`

	// DigestEnabled swaps new-post pushes for a single summary at DigestHour, the member's
	// local hour (0-23). DigestOffset is their UTC offset in minutes, refreshed by the app
	// on launch so a DST shift self-corrects. Replies and likes stay instant either way.
	DigestEnabled bool `json:"digestEnabled"`
	DigestHour    int  `json:"digestHour"`
	DigestOffset  int  `json:"digestOffset"`
}

// Normalize clamps the digest window to values the scheduler can act on, so a bad client
// can't park a member on an hour that never comes round.
func (p NotifyPrefs) Normalize() NotifyPrefs {
	if p.DigestHour < 0 || p.DigestHour > 23 {
		p.DigestHour = 20
	}
	// Real UTC offsets span -12:00 to +14:00.
	if p.DigestOffset < -12*60 || p.DigestOffset > 14*60 {
		p.DigestOffset = 0
	}
	return p
}

// Media is an uploaded file: a post image, a video clip, or a profile picture.
type Media struct {
	ID      int64  `json:"id"`
	OwnerID *int64 `json:"ownerId,omitempty"`
	Path    string `json:"-"`
	Mime    string `json:"mime"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
	// DurationMs is how long a clip runs; 0 for a still image.
	DurationMs int `json:"durationMs"`
	// PosterPath is the still frame shown for a video that is not playing. Empty when
	// there is none, which is also every image's state.
	PosterPath string    `json:"-"`
	CreatedAt  time.Time `json:"createdAt"`
}

// PostMedia is one attachment as a post carries it: everything a client needs to choose a
// renderer before it has fetched a single byte of the file.
type PostMedia struct {
	ID         int64  `json:"id"`
	Mime       string `json:"mime"`
	Width      int    `json:"width"`
	Height     int    `json:"height"`
	DurationMs int    `json:"durationMs"`
	HasPoster  bool   `json:"hasPoster"`
}

// Post is a single check-in: either a text-only update or an image with a caption.
type Post struct {
	ID        int64       `json:"id"`
	AuthorID  int64       `json:"authorId"`
	Kind      string      `json:"kind"`
	Body      string      `json:"body"`
	MediaID   *int64      `json:"mediaId,omitempty"`  // cover (first image), for older clients
	MediaIDs  []int64     `json:"mediaIds,omitempty"` // full ordered set, for clients predating Media
	Media     []PostMedia `json:"media,omitempty"`    // the same set, typed
	Location  *string     `json:"location,omitempty"` // coarse "City, Country", optional
	CreatedAt time.Time   `json:"createdAt"`

	// Lat/Lng are the coordinates behind Location: clamped to their valid range and
	// rounded to 2 decimal places (~1.1km) server-side regardless of what the client sent
	// (see normalizeCoord), so they are never more precise than the "City, Country" string
	// already carries. Stored for the v1.5 map panel; exposed now since a rounded
	// coordinate is no more sensitive than the place name sitting right next to it.
	Lat *float64 `json:"lat,omitempty"`
	Lng *float64 `json:"lng,omitempty"`

	// CrossPostID groups the copies of one post shared to several groups at once, so the
	// multi-group client can collapse them into a single card. Null for a single-group post.
	CrossPostID *string `json:"crossPostId,omitempty"`

	// Joined/derived fields populated by feed and detail queries.
	AuthorName      string           `json:"authorName,omitempty"`
	AuthorPhotoID   *int64           `json:"authorPhotoId,omitempty"`
	LikeCount       int              `json:"likeCount"`
	CommentCount    int              `json:"commentCount"`
	LikedByViewer   bool             `json:"likedByViewer"`
	CommentsPreview []CommentPreview `json:"commentsPreview,omitempty"`
	People          []TaggedPerson   `json:"people,omitempty"` // members tagged as appearing in the post

	// Recap is the panel-deck payload for a kind = 'recap' post, joined in from the recaps
	// table via recapExpr. Nil for every other post (the ~49 of 50 rows that aren't one).
	Recap *RecapPayload `json:"recap,omitempty"`
}

// RecapPayload is the denormalised snapshot a recap post renders as a swipeable deck of
// panels. It is a snapshot, not a list of ids to re-fetch: names, avatars and counts are
// frozen at generation time, so a recap stays a permanent artifact and later likes don't
// reshuffle last week's ranking.
type RecapPayload struct {
	V      int          `json:"v"`
	Period RecapPeriod  `json:"period"`
	Group  RecapGroup   `json:"group"`
	Stats  RecapStats   `json:"stats"`
	Panels []RecapPanel `json:"panels"`
}

// RecapPeriod describes the window a recap covers.
type RecapPeriod struct {
	Start   time.Time `json:"start"`
	End     time.Time `json:"end"`
	Label   string    `json:"label"`   // "Aug 10-16" (weekly) or "August 2026" (monthly)
	Cadence string    `json:"cadence"` // weekly | monthly | custom
}

// RecapGroup is the group identity a recap post is attributed to, in place of a person
// (see the serializer's authorName/authorPhotoId override for kind = 'recap' posts).
type RecapGroup struct {
	Name  string `json:"name"`
	Color string `json:"color"`
}

// RecapStats is the at-a-glance summary shown before the deck and used in the recap's
// fallback body text for a client too old to render panels.
type RecapStats struct {
	Posts    int `json:"posts"`
	Photos   int `json:"photos"`
	Clips    int `json:"clips"`
	Likes    int `json:"likes"`
	Comments int `json:"comments"`
	Places   int `json:"places"`
	Members  int `json:"members"`
	// Posters is how many distinct members posted, versus Members (the group's size) -
	// what the fallback body text's "all N of you" line is checking.
	Posters int `json:"posters"`
}

// RecapPanel is one page of the deck. Type is "collage" or "awards" in v1; a client must
// silently skip any type it doesn't recognise (forward-compat for v1.5's map and web
// panels) and fall back to Stats + body if it recognises none.
type RecapPanel struct {
	Type   string       `json:"type"`
	Title  string       `json:"title"`
	Cards  []RecapCard  `json:"cards,omitempty"`
	Awards []RecapAward `json:"awards,omitempty"`
}

// RecapCard is one entry in the collage ("The Wall") panel: a ranked photo/clip, or a
// quote card for a member whose guaranteed slot is text-only.
type RecapCard struct {
	Kind          string `json:"kind"` // "photo" | "clip" | "quote"
	Rank          int    `json:"rank"`
	Guaranteed    bool   `json:"guaranteed"`
	PostID        int64  `json:"postId"`
	AuthorID      int64  `json:"authorId"`
	AuthorName    string `json:"authorName"`
	AuthorPhotoID *int64 `json:"authorPhotoId,omitempty"`
	MediaID       *int64 `json:"mediaId,omitempty"`
	Mime          string `json:"mime,omitempty"`
	Width         int    `json:"w,omitempty"`
	Height        int    `json:"h,omitempty"`
	DurationMs    int    `json:"durationMs,omitempty"`
	HasPoster     bool   `json:"hasPoster,omitempty"`
	Body          string `json:"body,omitempty"` // quote card text; empty for photo/clip
	LikeCount     int    `json:"likeCount"`
	CommentCount  int    `json:"commentCount"`
	Location      string `json:"location,omitempty"`
}

// RecapAward is one superlative in the "Awards Night" panel.
type RecapAward struct {
	ID          string `json:"id"` // most_liked | night_owl | early_bird | ...
	Label       string `json:"label"`
	UserID      int64  `json:"userId"`
	UserName    string `json:"userName"`
	UserPhotoID *int64 `json:"userPhotoId,omitempty"`
	Value       string `json:"value"` // "9 likes" - already formatted for display
	PostID      *int64 `json:"postId,omitempty"`
	MediaID     *int64 `json:"mediaId,omitempty"`
}

// applyMedia decodes the attachment array a post query returns and derives the flat id
// list from it. Clients published before the typed array existed read only that list, so
// it has to keep being emitted - deriving it here rather than querying for it separately
// is what stops the two from ever disagreeing.
func (p *Post) applyMedia(raw []byte) {
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &p.Media)
	}
	if len(p.Media) == 0 {
		p.Media = nil // a text post carries no array at all, not an empty one
		return
	}
	p.MediaIDs = make([]int64, len(p.Media))
	for i, m := range p.Media {
		p.MediaIDs[i] = m.ID
	}
}

// applyRecap decodes a recap post's payload, when present. raw is NULL/empty for every
// post that isn't kind = 'recap'.
func (p *Post) applyRecap(raw []byte) {
	if len(raw) == 0 {
		return
	}
	var payload RecapPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return
	}
	p.Recap = &payload
}

// TaggedPerson is a member manually tagged as appearing in a post (id for filtering,
// name for display).
type TaggedPerson struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// Liker is one member who liked a post, for the author-only "who liked this" list.
type Liker struct {
	ID             int64  `json:"id"`
	Name           string `json:"name"`
	ProfileMediaID *int64 `json:"profileMediaId,omitempty"`
}

// CommentPreview is a lightweight comment (author + body) for inline feed previews.
type CommentPreview struct {
	AuthorID   int64  `json:"authorId"`
	AuthorName string `json:"authorName"`
	Body       string `json:"body"`
	// MediaID is the comment's gif attachment, if any. A client shows "GIF" in place of an
	// empty body when this is set - a gif-only comment has nothing else to preview.
	MediaID *int64 `json:"mediaId,omitempty"`
}

// Comment is a reply on a post. ParentCommentID, when set, points at the comment this one
// answers (both live on the same server), so the client can thread it and the author of the
// parent comment gets notified.
type Comment struct {
	ID              int64     `json:"id"`
	PostID          int64     `json:"postId"`
	UserID          int64     `json:"userId"`
	Body            string    `json:"body"`
	CreatedAt       time.Time `json:"createdAt"`
	ParentCommentID *int64    `json:"parentCommentId,omitempty"`
	AuthorName      string    `json:"authorName,omitempty"`
	AuthorPhotoID   *int64    `json:"authorPhotoId,omitempty"`
	// MediaID is a gif attached to the comment (re-hosted, never a hotlink). A comment may
	// carry one and no body at all - see the empty-body allowance in handleAddComment.
	MediaID *int64 `json:"mediaId,omitempty"`
}

// PreviewBody is what a plain-text summary of this comment should show: the body, or "GIF"
// for a gif-only comment (empty body, media attached) - the same fallback the app's own
// CommentPreview.previewText applies, used here by the debug dashboard's activity table.
func (c Comment) PreviewBody() string {
	if c.Body == "" && c.MediaID != nil {
		return "GIF"
	}
	return c.Body
}

// Birthday is a lightweight projection used by the upcoming-birthdays endpoint that
// powers on-device local notifications.
type Birthday struct {
	UserID int64  `json:"userId"`
	Name   string `json:"name"`
	Month  int    `json:"month"`
	Day    int    `json:"day"`
}

// ContentReport is a member's flag on objectionable content, visible to the admin.
type ContentReport struct {
	ID           int64     `json:"id"`
	ReporterID   int64     `json:"reporterId"`
	ReporterName string    `json:"reporterName,omitempty"`
	PostID       *int64    `json:"postId,omitempty"`
	CommentID    *int64    `json:"commentId,omitempty"`
	Reason       string    `json:"reason"`
	Dismissed    bool      `json:"dismissed"`
	ContentBody  string    `json:"contentBody,omitempty"` // preview of the reported content
	AuthorName   string    `json:"authorName,omitempty"`  // author of the reported content
	CreatedAt    time.Time `json:"createdAt"`
}
