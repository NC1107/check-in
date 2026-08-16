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
