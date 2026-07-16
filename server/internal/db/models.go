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

// Media is an uploaded image (post image or profile picture).
type Media struct {
	ID        int64     `json:"id"`
	OwnerID   *int64    `json:"ownerId,omitempty"`
	Path      string    `json:"-"`
	Mime      string    `json:"mime"`
	Width     int       `json:"width"`
	Height    int       `json:"height"`
	CreatedAt time.Time `json:"createdAt"`
}

// Post is a single check-in: either a text-only update or an image with a caption.
type Post struct {
	ID        int64     `json:"id"`
	AuthorID  int64     `json:"authorId"`
	Kind      string    `json:"kind"`
	Body      string    `json:"body"`
	MediaID   *int64    `json:"mediaId,omitempty"`  // cover (first image), for older clients
	MediaIDs  []int64   `json:"mediaIds,omitempty"` // full ordered set for multi-photo posts
	Location  *string   `json:"location,omitempty"` // coarse "City, Country", optional
	CreatedAt time.Time `json:"createdAt"`

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
}

// Comment is a reply on a post.
type Comment struct {
	ID            int64     `json:"id"`
	PostID        int64     `json:"postId"`
	UserID        int64     `json:"userId"`
	Body          string    `json:"body"`
	CreatedAt     time.Time `json:"createdAt"`
	AuthorName    string    `json:"authorName,omitempty"`
	AuthorPhotoID *int64    `json:"authorPhotoId,omitempty"`
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
