package db

import "time"

// User is a registered member of the server.
type User struct {
	ID    int64  `json:"id"`
	Phone string `json:"phone"`
	// Name is the display name shown throughout the app. FirstName/LastName are the
	// recorded full name, which may differ (some people prefer a nickname/first name only).
	Name           string    `json:"name"`
	FirstName      string    `json:"firstName"`
	LastName       string    `json:"lastName"`
	Birthday       time.Time `json:"birthday"`
	ProfileMediaID *int64    `json:"profileMediaId,omitempty"`
	IsAdmin        bool      `json:"isAdmin"`
	Status         string    `json:"status"`
	CreatedAt      time.Time `json:"createdAt"`
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

// CommentPreview is a lightweight comment (author + body) for inline feed previews.
type CommentPreview struct {
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
