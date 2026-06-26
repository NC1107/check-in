package db

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// commentPreviewExpr is a SELECT-list fragment returning the 2 most recent comments on
// post p as a JSON array (oldest-of-the-two first), for inline feed previews.
const commentPreviewExpr = `, COALESCE((
		SELECT json_agg(json_build_object('authorName', t.name, 'body', t.body) ORDER BY t.created_at)
		FROM (SELECT u2.name, c.body, c.created_at FROM comments c JOIN users u2 ON u2.id = c.user_id
		      WHERE c.post_id = p.id ORDER BY c.created_at DESC LIMIT 2) t), '[]'::json)`

// postMediaExpr appends the post's full ordered set of image ids as a bigint[]. Empty for
// text posts and (until backfill clients re-save) old single-image posts keep their cover.
const postMediaExpr = `, COALESCE(ARRAY(
		SELECT pm.media_id FROM post_media pm WHERE pm.post_id = p.id ORDER BY pm.position), '{}')`

// ErrNotFound is returned when a row does not exist.
var ErrNotFound = errors.New("not found")

// ErrNotOwned is returned when a request references media the caller does not own.
var ErrNotOwned = errors.New("media not owned by caller")

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

// SetResetCode stores a hashed, expiring recovery code for a user (overwriting any prior).
func (d *DB) SetResetCode(ctx context.Context, userID int64, codeHash string, expires time.Time) error {
	_, err := d.Pool.Exec(ctx,
		`UPDATE users SET reset_code_hash = $2, reset_code_expires = $3, reset_code_attempts = 0 WHERE id = $1`,
		userID, codeHash, expires)
	return err
}

// ResetCode returns the active user's stored reset-code hash, expiry, and failed-attempt
// count for a phone, so a redeem attempt can be verified and throttled. Returns
// ErrNotFound when there's no active user or no pending code.
func (d *DB) ResetCode(ctx context.Context, phone string) (userID int64, codeHash string, expires time.Time, attempts int, err error) {
	var ch *string
	var exp *time.Time
	err = d.Pool.QueryRow(ctx,
		`SELECT id, reset_code_hash, reset_code_expires, reset_code_attempts FROM users WHERE phone = $1 AND status = 'active'`,
		phone).Scan(&userID, &ch, &exp, &attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, "", time.Time{}, 0, ErrNotFound
	}
	if err != nil {
		return 0, "", time.Time{}, 0, err
	}
	if ch == nil || exp == nil {
		return 0, "", time.Time{}, 0, ErrNotFound
	}
	return userID, *ch, *exp, attempts, nil
}

// BumpResetAttempt records a failed reset-code attempt and, once the limit is reached,
// invalidates the code so it can no longer be guessed (the host must re-issue one).
func (d *DB) BumpResetAttempt(ctx context.Context, userID int64, maxAttempts int) error {
	_, err := d.Pool.Exec(ctx, `
		UPDATE users SET
			reset_code_attempts = reset_code_attempts + 1,
			reset_code_hash    = CASE WHEN reset_code_attempts + 1 >= $2 THEN NULL ELSE reset_code_hash END,
			reset_code_expires = CASE WHEN reset_code_attempts + 1 >= $2 THEN NULL ELSE reset_code_expires END
		WHERE id = $1`, userID, maxAttempts)
	return err
}

// SetPasswordAndClearReset sets a new password hash and consumes the reset code (single-use).
func (d *DB) SetPasswordAndClearReset(ctx context.Context, userID int64, passwordHash string) error {
	_, err := d.Pool.Exec(ctx,
		`UPDATE users SET password_hash = $2, reset_code_hash = NULL, reset_code_expires = NULL WHERE id = $1`,
		userID, passwordHash)
	return err
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

// UpdateUserProfile changes a user's display name and (legal) first/last name, returning
// the updated user. First/last are stored as given; the display name is what others see.
func (d *DB) UpdateUserProfile(ctx context.Context, id int64, name, firstName, lastName string) (User, error) {
	var u User
	err := d.Pool.QueryRow(ctx, `
		UPDATE users SET name = $2, first_name = $3, last_name = $4 WHERE id = $1
		RETURNING id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at`,
		id, name, firstName, lastName,
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

// SetUserAdmin promotes (or demotes) a user. Used by the operator dashboard.
func (d *DB) SetUserAdmin(ctx context.Context, id int64, isAdmin bool) error {
	ct, err := d.Pool.Exec(ctx, `UPDATE users SET is_admin = $2 WHERE id = $1`, id, isAdmin)
	if err != nil {
		return err
	}
	if ct.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ---- allowed phones (the allowlist) ----

// PhoneRegistered reports whether an account already exists for this phone (in any
// status). Used to route a returning member to login instead of signup. Note this
// also catches the host, whose number is never on the allowlist.
func (d *DB) PhoneRegistered(ctx context.Context, phone string) (bool, error) {
	var exists bool
	err := d.Pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM users WHERE phone = $1)`, phone,
	).Scan(&exists)
	return exists, err
}

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

// AddAllowedPhonesNoUser adds allowlist entries with no "added by" attribution (added_by
// NULL), for the operator dashboard, which acts without a logged-in member.
func (d *DB) AddAllowedPhonesNoUser(ctx context.Context, phones []string) (int, error) {
	if len(phones) == 0 {
		return 0, nil
	}
	ct, err := d.Pool.Exec(ctx,
		`INSERT INTO allowed_phones (phone)
		 SELECT unnest($1::text[])
		 ON CONFLICT (phone) DO NOTHING`,
		phones)
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

// RemoveAllowedPhone deletes an allowlist entry. Returns ErrNotFound if the phone was
// not on the list. Does not affect any account that already signed up with it.
func (d *DB) RemoveAllowedPhone(ctx context.Context, phone string) error {
	ct, err := d.Pool.Exec(ctx, `DELETE FROM allowed_phones WHERE phone = $1`, phone)
	if err != nil {
		return err
	}
	if ct.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// AllowedPhone is one allowlist entry (the admin's invite list).
type AllowedPhone struct {
	Phone     string    `json:"phone"`
	Used      bool      `json:"used"`
	CreatedAt time.Time `json:"createdAt"`
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
		SELECT u.id, u.phone, u.name, u.first_name, u.last_name, u.birthday, u.profile_media_id, u.is_admin, u.status, u.created_at
		FROM sessions s
		JOIN users u ON u.id = s.user_id
		WHERE s.token_hash = $1 AND s.expires_at > now() AND u.status = 'active'`, tokenHash,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt)
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

// ---- push notifications ----

// UpsertDeviceToken records (or refreshes) an FCM token for a user. Tokens are globally
// unique; if one moves to a different account, it's reassigned.
func (d *DB) UpsertDeviceToken(ctx context.Context, userID int64, token, platform string) error {
	_, err := d.Pool.Exec(ctx, `
		INSERT INTO device_tokens (user_id, token, platform)
		VALUES ($1, $2, $3)
		ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform`,
		userID, token, platform)
	return err
}

// DeleteDeviceToken removes a single token (e.g. on logout).
func (d *DB) DeleteDeviceToken(ctx context.Context, token string) error {
	_, err := d.Pool.Exec(ctx, `DELETE FROM device_tokens WHERE token = $1`, token)
	return err
}

// NotificationPrefs reports a user's opt-out toggles.
func (d *DB) NotificationPrefs(ctx context.Context, userID int64) (posts, replies bool, err error) {
	err = d.Pool.QueryRow(ctx,
		`SELECT notify_posts, notify_replies FROM users WHERE id = $1`, userID,
	).Scan(&posts, &replies)
	return posts, replies, err
}

// SetNotificationPrefs updates a user's notification toggles.
func (d *DB) SetNotificationPrefs(ctx context.Context, userID int64, posts, replies bool) error {
	_, err := d.Pool.Exec(ctx,
		`UPDATE users SET notify_posts = $2, notify_replies = $3 WHERE id = $1`, userID, posts, replies)
	return err
}

// TokensForNewPost returns the device tokens of every active member who wants new-post
// notifications, excluding the post's author.
func (d *DB) TokensForNewPost(ctx context.Context, authorID int64) ([]string, error) {
	return d.scanTokens(ctx, `
		SELECT dt.token FROM device_tokens dt
		JOIN users u ON u.id = dt.user_id
		WHERE u.status = 'active' AND u.notify_posts = TRUE AND u.id <> $1`, authorID)
}

// TokensForReply returns the post author's device tokens when they want reply
// notifications and aren't the one who just commented.
func (d *DB) TokensForReply(ctx context.Context, postID, commenterID int64) ([]string, error) {
	return d.scanTokens(ctx, `
		SELECT dt.token FROM device_tokens dt
		JOIN posts p ON p.id = $1
		JOIN users u ON u.id = p.author_id
		WHERE dt.user_id = p.author_id AND u.status = 'active'
		  AND u.notify_replies = TRUE AND p.author_id <> $2`, postID, commenterID)
}

func (d *DB) scanTokens(ctx context.Context, sql string, args ...any) ([]string, error) {
	rows, err := d.Pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tokens []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		tokens = append(tokens, t)
	}
	return tokens, rows.Err()
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

// GetVisibleMedia returns a media item only if the viewer is allowed to see it: they
// uploaded it, it's attached to a post (the feed is shared within the group), or it's
// someone's profile photo. This prevents enumerating arbitrary media ids (e.g. another
// member's not-yet-posted upload or media from a deleted post). Returns ErrNotFound
// otherwise, so existence isn't confirmed.
func (d *DB) GetVisibleMedia(ctx context.Context, id, viewerID int64) (Media, error) {
	var m Media
	err := d.Pool.QueryRow(ctx, `
		SELECT m.id, m.owner_id, m.path, m.mime, m.width, m.height, m.created_at
		FROM media m
		WHERE m.id = $1 AND (
			m.owner_id = $2
			OR EXISTS (SELECT 1 FROM posts p WHERE p.media_id = m.id)
			OR EXISTS (SELECT 1 FROM post_media pm WHERE pm.media_id = m.id)
			OR EXISTS (SELECT 1 FROM users u WHERE u.profile_media_id = m.id)
		)`, id, viewerID,
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
func (d *DB) CreatePost(ctx context.Context, authorID int64, kind, body string, mediaIDs []int64, location *string) (Post, error) {
	var p Post
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return p, err
	}
	defer tx.Rollback(ctx)

	// The author must own every referenced media item. Without this an author could
	// attach another member's media id, which GetVisibleMedia would then expose to the
	// whole group (an IDOR / privacy leak). Treat unowned or non-existent ids the same.
	if len(mediaIDs) > 0 {
		uniq := make(map[int64]struct{}, len(mediaIDs))
		for _, m := range mediaIDs {
			uniq[m] = struct{}{}
		}
		var owned int
		if err := tx.QueryRow(ctx,
			`SELECT count(DISTINCT id) FROM media WHERE id = ANY($1) AND owner_id = $2`,
			mediaIDs, authorID).Scan(&owned); err != nil {
			return p, err
		}
		if owned != len(uniq) {
			return p, ErrNotOwned
		}
	}

	// posts.media_id holds the cover (first image) for older clients; the full set lives
	// in post_media.
	var cover *int64
	if len(mediaIDs) > 0 {
		cover = &mediaIDs[0]
	}
	err = tx.QueryRow(ctx, `
		INSERT INTO posts (author_id, kind, body, media_id, location)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, author_id, kind, body, media_id, location, created_at`,
		authorID, kind, body, cover, location,
	).Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt)
	if err != nil {
		return p, err
	}
	for i, mid := range mediaIDs {
		if _, err := tx.Exec(ctx,
			`INSERT INTO post_media (post_id, media_id, position) VALUES ($1, $2, $3)`,
			p.ID, mid, i); err != nil {
			return p, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return p, err
	}
	p.MediaIDs = mediaIDs
	return p, nil
}

// Feed returns posts in reverse-chronological order with engagement counts, optionally
// filtered to a single author and/or to posts created strictly before a cursor time.
func (d *DB) Feed(ctx context.Context, viewerID int64, authorID *int64, location *string, before *time.Time, beforeID *int64, limit int) ([]Post, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE ($2::bigint IS NULL OR p.author_id = $2)
		  AND ($3::text IS NULL OR p.location = $3)
		  AND ($4::timestamptz IS NULL
		       OR ($6::bigint IS NULL AND p.created_at < $4)
		       OR ($6::bigint IS NOT NULL AND (p.created_at, p.id) < ($4, $6)))
		  AND u.status = 'active'
		ORDER BY p.created_at DESC, p.id DESC
		LIMIT $5`, viewerID, authorID, location, before, limit, beforeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var posts []Post
	for rows.Next() {
		var p Post
		var preview []byte
		if err := rows.Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt,
			&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview, &p.MediaIDs); err != nil {
			return nil, err
		}
		if len(preview) > 0 {
			_ = json.Unmarshal(preview, &p.CommentsPreview)
		}
		posts = append(posts, p)
	}
	return posts, rows.Err()
}

// LocationCount is a distinct place label plus how many check-ins carry it.
type LocationCount struct {
	Location string `json:"location"`
	Count    int    `json:"count"`
}

// Locations returns the distinct place labels across all check-ins from active members,
// most-used first — used to populate the feed's location filter.
func (d *DB) Locations(ctx context.Context) ([]LocationCount, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT p.location, count(*) AS n
		FROM posts p
		JOIN users u ON u.id = p.author_id
		WHERE p.location IS NOT NULL AND p.location <> '' AND u.status = 'active'
		GROUP BY p.location
		ORDER BY n DESC, p.location ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LocationCount
	for rows.Next() {
		var lc LocationCount
		if err := rows.Scan(&lc.Location, &lc.Count); err != nil {
			return nil, err
		}
		out = append(out, lc)
	}
	return out, rows.Err()
}

// SearchPosts returns posts whose caption OR any of their comments match the query
// (case-insensitive substring), newest first — powering full-content feed search.
func (d *DB) SearchPosts(ctx context.Context, viewerID int64, query string, limit int) ([]Post, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+`
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
		if err := rows.Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt,
			&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview, &p.MediaIDs); err != nil {
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
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at,
		       u.name, u.profile_media_id,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+`
		FROM posts p JOIN users u ON u.id = p.author_id
		WHERE p.id = $2 AND u.status = 'active'`, viewerID, postID,
	).Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt,
		&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview, &p.MediaIDs)
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
// DeletePost removes a member's own post, plus any media that becomes orphaned as a
// result, and returns the stored paths of the now-unreferenced files so the caller can
// delete them from disk. Comments, likes, and post_media cascade via their foreign keys.
func (d *DB) DeletePost(ctx context.Context, postID, authorID int64) ([]string, error) {
	return d.deletePost(ctx, postID, &authorID)
}

// AdminDeletePost removes any post regardless of owner (operator dashboard moderation),
// with the same orphaned-media cleanup as DeletePost.
func (d *DB) AdminDeletePost(ctx context.Context, postID int64) ([]string, error) {
	return d.deletePost(ctx, postID, nil)
}

// deletePost deletes a post (optionally constrained to an author) and garbage-collects any
// media it referenced that is no longer used anywhere, returning their file paths.
func (d *DB) deletePost(ctx context.Context, postID int64, authorID *int64) ([]string, error) {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	candidates, err := collectPostMedia(ctx, tx, postID)
	if err != nil {
		return nil, err
	}
	var ct pgconn.CommandTag
	if authorID != nil {
		ct, err = tx.Exec(ctx, `DELETE FROM posts WHERE id = $1 AND author_id = $2`, postID, *authorID)
	} else {
		ct, err = tx.Exec(ctx, `DELETE FROM posts WHERE id = $1`, postID)
	}
	if err != nil {
		return nil, err
	}
	if ct.RowsAffected() == 0 {
		return nil, ErrNotFound
	}
	paths, err := deleteOrphanMedia(ctx, tx, candidates)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return paths, nil
}

// collectPostMedia returns the media ids a post references — its cover plus every
// post_media entry — so they can be re-checked for orphan status after the post is gone.
func collectPostMedia(ctx context.Context, tx pgx.Tx, postID int64) ([]int64, error) {
	rows, err := tx.Query(ctx, `
		SELECT media_id FROM post_media WHERE post_id = $1
		UNION
		SELECT media_id FROM posts WHERE id = $1 AND media_id IS NOT NULL`, postID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// deleteOrphanMedia removes any candidate media rows no longer referenced by a post cover,
// post_media, or a profile photo, returning their stored file paths. Run after the post is
// deleted so its own references are already gone.
func deleteOrphanMedia(ctx context.Context, tx pgx.Tx, candidates []int64) ([]string, error) {
	var paths []string
	for _, mid := range candidates {
		var path string
		err := tx.QueryRow(ctx, `
			DELETE FROM media m WHERE m.id = $1
			  AND NOT EXISTS (SELECT 1 FROM posts p WHERE p.media_id = m.id)
			  AND NOT EXISTS (SELECT 1 FROM post_media pm WHERE pm.media_id = m.id)
			  AND NOT EXISTS (SELECT 1 FROM users u WHERE u.profile_media_id = m.id)
			RETURNING m.path`, mid).Scan(&path)
		if errors.Is(err, pgx.ErrNoRows) {
			continue // still referenced elsewhere; keep it
		}
		if err != nil {
			return nil, err
		}
		paths = append(paths, path)
	}
	return paths, nil
}

// AdminDeleteComment removes any comment by id (operator dashboard moderation).
func (d *DB) AdminDeleteComment(ctx context.Context, commentID int64) error {
	ct, err := d.Pool.Exec(ctx, `DELETE FROM comments WHERE id = $1`, commentID)
	if err != nil {
		return err
	}
	if ct.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// RecentComments returns the latest comments across all posts with their author name,
// for the operator dashboard's activity view.
func (d *DB) RecentComments(ctx context.Context, limit int) ([]Comment, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT c.id, c.post_id, c.user_id, c.body, c.created_at, u.name
		FROM comments c JOIN users u ON u.id = c.user_id
		ORDER BY c.created_at DESC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Comment
	for rows.Next() {
		var c Comment
		if err := rows.Scan(&c.ID, &c.PostID, &c.UserID, &c.Body, &c.CreatedAt, &c.AuthorName); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ---- likes ----

// PostVisible reports whether a post exists and is visible to members — i.e. its author
// is still active. Used to reject likes/comments on missing or hidden posts with a clean
// 404 instead of leaking a foreign-key 500 or letting members interact with content the
// feed hides.
func (d *DB) PostVisible(ctx context.Context, postID int64) (bool, error) {
	var ok bool
	err := d.Pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM posts p JOIN users u ON u.id = p.author_id
			WHERE p.id = $1 AND u.status = 'active')`, postID).Scan(&ok)
	return ok, err
}

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
