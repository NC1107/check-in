package db

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// commentPreviewExpr is a SELECT-list fragment returning the 2 most recent comments on
// post p as a JSON array (oldest-of-the-two first), for inline feed previews.
const commentPreviewExpr = `, COALESCE((
		SELECT json_agg(json_build_object('authorName', t.name, 'body', t.body) ORDER BY t.created_at)
		FROM (SELECT u2.name, c.body, c.created_at FROM comments c JOIN users u2 ON u2.id = c.user_id
		      WHERE c.post_id = p.id ORDER BY c.created_at DESC LIMIT 2) t), '[]'::json)`

// ErrNotFound is returned when a row does not exist.
var ErrNotFound = errors.New("not found")

// ---- server config ----

// ServerInitialized reports whether the first admin has been created.
func (d *DB) ServerInitialized(ctx context.Context) (bool, error) {
	var initialized bool
	err := d.Pool.QueryRow(ctx, `SELECT initialized FROM server_config WHERE id = 1`).Scan(&initialized)
	return initialized, err
}

// MarkInitialized flags the server as having an admin.
func (d *DB) MarkInitialized(ctx context.Context) error {
	_, err := d.Pool.Exec(ctx, `UPDATE server_config SET initialized = TRUE WHERE id = 1`)
	return err
}

// ---- users ----

// CreateUser inserts a new user and returns it.
func (d *DB) CreateUser(ctx context.Context, phone, name, firstName, lastName string, birthday time.Time, profileMediaID *int64, passwordHash string, isAdmin bool) (User, error) {
	var u User
	err := d.Pool.QueryRow(ctx, `
		INSERT INTO users (phone, name, first_name, last_name, birthday, profile_media_id, password_hash, is_admin)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		RETURNING id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at`,
		phone, name, firstName, lastName, birthday, profileMediaID, passwordHash, isAdmin,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt)
	return u, err
}

// GetUserByPhone returns the user (and password hash) for login.
func (d *DB) GetUserByPhone(ctx context.Context, phone string) (User, string, error) {
	var u User
	var hash string
	err := d.Pool.QueryRow(ctx, `
		SELECT id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at, password_hash
		FROM users WHERE phone = $1`, phone,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return u, "", ErrNotFound
	}
	return u, hash, err
}

// GetUser returns an active user by id. Returns ErrNotFound for revoked users.
func (d *DB) GetUser(ctx context.Context, id int64) (User, error) {
	var u User
	err := d.Pool.QueryRow(ctx, `
		SELECT id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at
		FROM users WHERE id = $1 AND status = 'active'`, id,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return u, ErrNotFound
	}
	return u, err
}

// SearchUsers returns users whose name matches the query (case-insensitive), ordered
// by name. An empty query returns all users.
func (d *DB) SearchUsers(ctx context.Context, query string, limit int) ([]User, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at
		FROM users
		WHERE status = 'active' AND ($1 = '' OR name ILIKE '%' || $1 || '%')
		ORDER BY name ASC
		LIMIT $2`, query, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// ListAllUsers returns all users including revoked ones for the admin view.
func (d *DB) ListAllUsers(ctx context.Context) ([]User, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at
		FROM users ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// UpdateUserName changes a user's display name and returns the updated user.
func (d *DB) UpdateUserName(ctx context.Context, id int64, name string) (User, error) {
	var u User
	err := d.Pool.QueryRow(ctx, `
		UPDATE users SET name = $2 WHERE id = $1
		RETURNING id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at`,
		id, name,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt)
	return u, err
}

// SetUserStatus updates a user's status (e.g. 'revoked'), used by admin to kick users.
func (d *DB) SetUserStatus(ctx context.Context, id int64, status string) error {
	ct, err := d.Pool.Exec(ctx, `UPDATE users SET status = $2 WHERE id = $1`, id, status)
	if err != nil {
		return err
	}
	if ct.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ---- allowed phones (the allowlist) ----

// PhoneAllowed reports whether a phone is on the allowlist and whether it is unused.
func (d *DB) PhoneAllowed(ctx context.Context, phone string) (allowed, used bool, err error) {
	err = d.Pool.QueryRow(ctx,
		`SELECT used FROM allowed_phones WHERE phone = $1`, phone,
	).Scan(&used)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	return true, used, nil
}

// AddAllowedPhones inserts allowlist entries, ignoring duplicates. Returns the count
// of newly inserted numbers. Uses a single bulk statement to avoid N round-trips.
func (d *DB) AddAllowedPhones(ctx context.Context, phones []string, addedBy int64) (int, error) {
	if len(phones) == 0 {
		return 0, nil
	}
	ct, err := d.Pool.Exec(ctx,
		`INSERT INTO allowed_phones (phone, added_by)
		 SELECT unnest($1::text[]), $2
		 ON CONFLICT (phone) DO NOTHING`,
		phones, addedBy)
	if err != nil {
		return 0, err
	}
	return int(ct.RowsAffected()), nil
}

// MarkPhoneUsed flags an allowlist entry as consumed by a signup.
func (d *DB) MarkPhoneUsed(ctx context.Context, phone string) error {
	_, err := d.Pool.Exec(ctx, `UPDATE allowed_phones SET used = TRUE WHERE phone = $1`, phone)
	return err
}

// AllowedPhone is one allowlist entry, for the debug view.
type AllowedPhone struct {
	Phone     string
	Used      bool
	CreatedAt time.Time
}

// ListAllowedPhones returns every allowlist entry, newest first (debug view).
func (d *DB) ListAllowedPhones(ctx context.Context) ([]AllowedPhone, error) {
	rows, err := d.Pool.Query(ctx,
		`SELECT phone, used, created_at FROM allowed_phones ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AllowedPhone
	for rows.Next() {
		var a AllowedPhone
		if err := rows.Scan(&a.Phone, &a.Used, &a.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ---- debug / maintenance ----

// Stats is a snapshot of row counts for the debug dashboard.
type Stats struct {
	Initialized   bool
	Users         int
	Admins        int
	AllowedPhones int
	UsedPhones    int
	Posts         int
	Comments      int
	Likes         int
	Sessions      int
	Media         int
}

// Stats returns aggregate counts across the database in a single round-trip.
func (d *DB) Stats(ctx context.Context) (Stats, error) {
	var s Stats
	err := d.Pool.QueryRow(ctx, `
		SELECT
			COALESCE((SELECT initialized FROM server_config WHERE id = 1), FALSE),
			(SELECT count(*) FROM users),
			(SELECT count(*) FROM users WHERE is_admin),
			(SELECT count(*) FROM allowed_phones),
			(SELECT count(*) FROM allowed_phones WHERE used),
			(SELECT count(*) FROM posts),
			(SELECT count(*) FROM comments),
			(SELECT count(*) FROM likes),
			(SELECT count(*) FROM sessions),
			(SELECT count(*) FROM media)
	`).Scan(&s.Initialized, &s.Users, &s.Admins, &s.AllowedPhones, &s.UsedPhones,
		&s.Posts, &s.Comments, &s.Likes, &s.Sessions, &s.Media)
	return s, err
}

// ResetDatabase wipes all user data and returns the server to its fresh, uninitialized
// state so the next signup becomes the first admin. Destructive — debug use only.
func (d *DB) ResetDatabase(ctx context.Context) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	// One TRUNCATE with CASCADE handles the circular users<->media FK and resets identities.
	if _, err := tx.Exec(ctx,
		`TRUNCATE comments, likes, posts, sessions, allowed_phones, users, media RESTART IDENTITY CASCADE`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE server_config SET initialized = FALSE WHERE id = 1`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ---- sessions ----

// CreateSession stores a hashed session token for a user.
func (d *DB) CreateSession(ctx context.Context, userID int64, tokenHash string, expiresAt time.Time) error {
	_, err := d.Pool.Exec(ctx,
		`INSERT INTO sessions (user_id, token_hash, expires_at) VALUES ($1, $2, $3)`,
		userID, tokenHash, expiresAt)
	return err
}

// UserForToken returns the active user owning a (hashed) session token, if valid.
func (d *DB) UserForToken(ctx context.Context, tokenHash string) (User, error) {
	var u User
	err := d.Pool.QueryRow(ctx, `
		SELECT u.id, u.phone, u.name, u.birthday, u.profile_media_id, u.is_admin, u.status, u.created_at
		FROM sessions s
		JOIN users u ON u.id = s.user_id
		WHERE s.token_hash = $1 AND s.expires_at > now() AND u.status = 'active'`, tokenHash,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return u, ErrNotFound
	}
	return u, err
}

// DeleteSession removes a single session token (logout).
func (d *DB) DeleteSession(ctx context.Context, tokenHash string) error {
	_, err := d.Pool.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, tokenHash)
	return err
}

// DeleteUserSessions removes all sessions for a user (called on account revocation).
func (d *DB) DeleteUserSessions(ctx context.Context, userID int64) error {
	_, err := d.Pool.Exec(ctx, `DELETE FROM sessions WHERE user_id = $1`, userID)
	return err
}

// ---- media ----

// CreateMedia records an uploaded file.
func (d *DB) CreateMedia(ctx context.Context, ownerID *int64, path, mime string, width, height int) (Media, error) {
	var m Media
	err := d.Pool.QueryRow(ctx, `
		INSERT INTO media (owner_id, path, mime, width, height)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, owner_id, path, mime, width, height, created_at`,
		ownerID, path, mime, width, height,
	).Scan(&m.ID, &m.OwnerID, &m.Path, &m.Mime, &m.Width, &m.Height, &m.CreatedAt)
	return m, err
}

// GetMedia returns media metadata by id.
func (d *DB) GetMedia(ctx context.Context, id int64) (Media, error) {
	var m Media
	err := d.Pool.QueryRow(ctx, `
		SELECT id, owner_id, path, mime, width, height, created_at FROM media WHERE id = $1`, id,
	).Scan(&m.ID, &m.OwnerID, &m.Path, &m.Mime, &m.Width, &m.Height, &m.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return m, ErrNotFound
	}
	return m, err
}

// SetUserProfileMedia attaches a profile picture to a user.
func (d *DB) SetUserProfileMedia(ctx context.Context, userID, mediaID int64) error {
	_, err := d.Pool.Exec(ctx, `UPDATE users SET profile_media_id = $2 WHERE id = $1`, userID, mediaID)
	return err
}

// ---- posts ----

// CreatePost inserts a post.
func (d *DB) CreatePost(ctx context.Context, authorID int64, kind, body string, mediaID *int64) (Post, error) {
	var p Post
	err := d.Pool.QueryRow(ctx, `
		INSERT INTO posts (author_id, kind, body, media_id)
		VALUES ($1, $2, $3, $4)
		RETURNING id, author_id, kind, body, media_id, created_at`,
		authorID, kind, body, mediaID,
	).Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.CreatedAt)
	return p, err
}

// Feed returns posts in reverse-chronological order with engagement counts, optionally
// filtered to a single author and/or to posts created strictly before a cursor time.
func (d *DB) Feed(ctx context.Context, viewerID int64, authorID *int64, before *time.Time, limit int) ([]Post, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.created_at,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE ($2::bigint IS NULL OR p.author_id = $2)
		  AND ($3::timestamptz IS NULL OR p.created_at < $3)
		  AND u.status = 'active'
		ORDER BY p.created_at DESC
		LIMIT $4`, viewerID, authorID, before, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var posts []Post
	for rows.Next() {
		var p Post
		var preview []byte
		if err := rows.Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.CreatedAt,
			&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview); err != nil {
			return nil, err
		}
		if len(preview) > 0 {
			_ = json.Unmarshal(preview, &p.CommentsPreview)
		}
		posts = append(posts, p)
	}
	return posts, rows.Err()
}

// SearchPosts returns posts whose caption OR any of their comments match the query
// (case-insensitive substring), newest first — powering full-content feed search.
func (d *DB) SearchPosts(ctx context.Context, viewerID int64, query string, limit int) ([]Post, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.created_at,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE u.status = 'active' AND (
		      p.body ILIKE '%' || $2 || '%'
		   OR EXISTS (SELECT 1 FROM comments c WHERE c.post_id = p.id AND c.body ILIKE '%' || $2 || '%')
		)
		ORDER BY p.created_at DESC
		LIMIT $3`, viewerID, query, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var posts []Post
	for rows.Next() {
		var p Post
		var preview []byte
		if err := rows.Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.CreatedAt,
			&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview); err != nil {
			return nil, err
		}
		if len(preview) > 0 {
			_ = json.Unmarshal(preview, &p.CommentsPreview)
		}
		posts = append(posts, p)
	}
	return posts, rows.Err()
}

// GetPost returns a single post with engagement counts from the viewer's perspective.
func (d *DB) GetPost(ctx context.Context, viewerID, postID int64) (Post, error) {
	var p Post
	var preview []byte
	err := d.Pool.QueryRow(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.created_at,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+`
		FROM posts p JOIN users u ON u.id = p.author_id
		WHERE p.id = $2 AND u.status = 'active'`, viewerID, postID,
	).Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.CreatedAt,
		&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, ErrNotFound
	}
	if err == nil && len(preview) > 0 {
		_ = json.Unmarshal(preview, &p.CommentsPreview)
	}
	return p, err
}

// DeletePost removes a post if owned by the given author. Returns ErrNotFound if no
// matching row (wrong owner or missing).
func (d *DB) DeletePost(ctx context.Context, postID, authorID int64) error {
	ct, err := d.Pool.Exec(ctx, `DELETE FROM posts WHERE id = $1 AND author_id = $2`, postID, authorID)
	if err != nil {
		return err
	}
	if ct.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ---- likes ----

// LikePost adds a like, ignoring duplicates.
func (d *DB) LikePost(ctx context.Context, postID, userID int64) error {
	_, err := d.Pool.Exec(ctx,
		`INSERT INTO likes (post_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		postID, userID)
	return err
}

// UnlikePost removes a like.
func (d *DB) UnlikePost(ctx context.Context, postID, userID int64) error {
	_, err := d.Pool.Exec(ctx, `DELETE FROM likes WHERE post_id = $1 AND user_id = $2`, postID, userID)
	return err
}

// ---- comments ----

// AddComment inserts a comment and returns it.
func (d *DB) AddComment(ctx context.Context, postID, userID int64, body string) (Comment, error) {
	var c Comment
	err := d.Pool.QueryRow(ctx, `
		INSERT INTO comments (post_id, user_id, body) VALUES ($1, $2, $3)
		RETURNING id, post_id, user_id, body, created_at`,
		postID, userID, body,
	).Scan(&c.ID, &c.PostID, &c.UserID, &c.Body, &c.CreatedAt)
	return c, err
}

// ListComments returns comments on a post in chronological order with author info.
func (d *DB) ListComments(ctx context.Context, postID int64) ([]Comment, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT c.id, c.post_id, c.user_id, c.body, c.created_at, u.name, u.profile_media_id
		FROM comments c JOIN users u ON u.id = c.user_id
		WHERE c.post_id = $1
		ORDER BY c.created_at ASC`, postID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var comments []Comment
	for rows.Next() {
		var c Comment
		if err := rows.Scan(&c.ID, &c.PostID, &c.UserID, &c.Body, &c.CreatedAt, &c.AuthorName, &c.AuthorPhotoID); err != nil {
			return nil, err
		}
		comments = append(comments, c)
	}
	return comments, rows.Err()
}

// ---- birthdays ----

// UpcomingBirthdays returns every active user's birthday month/day so the client can
// schedule local notifications. (Small friend groups — returning all is fine.)
func (d *DB) UpcomingBirthdays(ctx context.Context) ([]Birthday, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT id, name, EXTRACT(MONTH FROM birthday)::int, EXTRACT(DAY FROM birthday)::int
		FROM users WHERE status = 'active'
		ORDER BY EXTRACT(MONTH FROM birthday), EXTRACT(DAY FROM birthday)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Birthday
	for rows.Next() {
		var b Birthday
		if err := rows.Scan(&b.UserID, &b.Name, &b.Month, &b.Day); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}
