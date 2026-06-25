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
	MediaID   *int64    `json:"mediaId,omitempty"`
	CreatedAt time.Time `json:"createdAt"`

	// Joined/derived fields populated by feed and detail queries.
	AuthorName      string           `json:"authorName,omitempty"`
	AuthorPhotoID   *int64           `json:"authorPhotoId,omitempty"`
	LikeCount       int              `json:"likeCount"`
	CommentCount    int              `json:"commentCount"`
	LikedByViewer   bool             `json:"likedByViewer"`
	CommentsPreview []CommentPreview `json:"commentsPreview,omitempty"`
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
