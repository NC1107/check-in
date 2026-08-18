package db

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// commentPreviewExpr is a SELECT-list fragment returning the 2 most recent comments on
// post p as a JSON array (oldest-of-the-two first), for inline feed previews.
const commentPreviewExpr = `, COALESCE((
		SELECT json_agg(json_build_object('authorId', t.user_id, 'authorName', t.name, 'body', t.body, 'mediaId', t.media_id) ORDER BY t.created_at)
		FROM (SELECT c.user_id, u2.name, c.body, c.media_id, c.created_at FROM comments c JOIN users u2 ON u2.id = c.user_id
		      WHERE c.post_id = p.id
		        AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)
		      ORDER BY c.created_at DESC LIMIT 2) t), '[]'::json)`

// postMediaExpr appends the post's full ordered set of attachments as a JSON array of
// {id, mime, width, height, durationMs, hasPoster}. Empty for text posts. The bare id list
// older clients read is derived from this in Go rather than fetched a second time, so the
// two can never disagree about order or membership.
const postMediaExpr = `, COALESCE((
		SELECT json_agg(json_build_object(
			'id', m.id, 'mime', m.mime, 'width', m.width, 'height', m.height,
			'durationMs', m.duration_ms, 'hasPoster', m.poster_path <> '') ORDER BY pm.position)
		FROM post_media pm JOIN media m ON m.id = pm.media_id
		WHERE pm.post_id = p.id), '[]'::json)`

// recapExpr appends a recap post's panel-deck payload verbatim (it is already the shape
// RecapPayload unmarshals into). NULL for the ~49 of 50 rows that aren't a recap, which is
// why the payload lives in its own table rather than a column on the hot feed row.
const recapExpr = `, (SELECT r.payload FROM recaps r WHERE r.post_id = p.id)`

// postPeopleExpr appends the members tagged in post p as a JSON array of {id, name},
// name-sorted. Empty array when no one is tagged.
const postPeopleExpr = `, COALESCE((
		SELECT json_agg(json_build_object('id', pp.user_id, 'name', tu.name) ORDER BY tu.name)
		FROM post_people pp JOIN users tu ON tu.id = pp.user_id
		WHERE pp.post_id = p.id), '[]'::json)`

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

// GetServerName returns the group's display name (what clients show for this server).
func (d *DB) GetServerName(ctx context.Context) (string, error) {
	var name string
	err := d.Pool.QueryRow(ctx, `SELECT name FROM server_config WHERE id = 1`).Scan(&name)
	return name, err
}

// SetServerName updates the group's display name. Admin-controlled, so it's the one
// name every member sees.
func (d *DB) SetServerName(ctx context.Context, name string) error {
	_, err := d.Pool.Exec(ctx, `UPDATE server_config SET name = $1 WHERE id = 1`, name)
	return err
}

// GetServerColor returns the group's admin-set palette color id, or "" if none is set
// (clients then fall back to a deterministic color derived from the group id).
func (d *DB) GetServerColor(ctx context.Context) (string, error) {
	var color string
	err := d.Pool.QueryRow(ctx, `SELECT color FROM server_config WHERE id = 1`).Scan(&color)
	return color, err
}

// SetServerColor updates the group's palette color id. An empty string clears it back to
// the client-side automatic color.
func (d *DB) SetServerColor(ctx context.Context, color string) error {
	_, err := d.Pool.Exec(ctx, `UPDATE server_config SET color = $1 WHERE id = 1`, color)
	return err
}

// GetRelayKey returns the push-relay key this server registered with, or "" if it hasn't
// registered yet.
func (d *DB) GetRelayKey(ctx context.Context) (string, error) {
	var key string
	err := d.Pool.QueryRow(ctx, `SELECT relay_key FROM server_config WHERE id = 1`).Scan(&key)
	return key, err
}

// SetRelayKey stores the key issued by the push relay so it's reused across restarts.
func (d *DB) SetRelayKey(ctx context.Context, key string) error {
	_, err := d.Pool.Exec(ctx, `UPDATE server_config SET relay_key = $1 WHERE id = 1`, key)
	return err
}

// SeedServerName copies the configured CHECKIN_SERVER_NAME into the database exactly
// once, while the stored name is still the schema default. This migrates existing
// env-configured installs to the DB-backed name without clobbering a name an admin has
// since chosen (renaming back to the literal default 'Check-In' is the sole edge case).
func (d *DB) SeedServerName(ctx context.Context, envName string) error {
	if envName == "" || envName == "Check-In" {
		return nil
	}
	_, err := d.Pool.Exec(ctx,
		`UPDATE server_config SET name = $1 WHERE id = 1 AND name = 'Check-In'`, envName)
	return err
}

// ---- users ----

// CreateUser inserts a new user and returns it.
func (d *DB) CreateUser(ctx context.Context, phone, name, firstName, lastName string, birthday time.Time, profileMediaID *int64, passwordHash string, isAdmin bool) (User, error) {
	var u User
	err := d.Pool.QueryRow(ctx, `
		INSERT INTO users (phone, name, first_name, last_name, birthday, profile_media_id, password_hash, is_admin)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		RETURNING id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at, title, title_set_at`,
		phone, name, firstName, lastName, birthday, profileMediaID, passwordHash, isAdmin,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt, &u.Title, &u.TitleSetAt)
	return u, err
}

// GetUserByPhone returns the user (and password hash) for login.
func (d *DB) GetUserByPhone(ctx context.Context, phone string) (User, string, error) {
	var u User
	var hash string
	err := d.Pool.QueryRow(ctx, `
		SELECT id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at, title, title_set_at, password_hash
		FROM users WHERE phone = $1`, phone,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt, &u.Title, &u.TitleSetAt, &hash)
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
		SELECT id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at, title, title_set_at
		FROM users WHERE id = $1 AND status = 'active'`, id,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt, &u.Title, &u.TitleSetAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return u, ErrNotFound
	}
	return u, err
}

// SearchUsers returns users whose name matches the query (case-insensitive), ordered
// by name. An empty query returns all users.
func (d *DB) SearchUsers(ctx context.Context, query string, limit int) ([]User, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at, title, title_set_at
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
		if err := rows.Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt, &u.Title, &u.TitleSetAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// ListAllUsers returns all users including revoked ones for the admin view.
func (d *DB) ListAllUsers(ctx context.Context) ([]User, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at, title, title_set_at
		FROM users ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt, &u.Title, &u.TitleSetAt); err != nil {
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
		RETURNING id, phone, name, first_name, last_name, birthday, profile_media_id, is_admin, status, created_at, title, title_set_at`,
		id, name, firstName, lastName,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt, &u.Title, &u.TitleSetAt)
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
		SELECT u.id, u.phone, u.name, u.first_name, u.last_name, u.birthday, u.profile_media_id, u.is_admin, u.status, u.created_at, u.title, u.title_set_at
		FROM sessions s
		JOIN users u ON u.id = s.user_id
		WHERE s.token_hash = $1 AND s.expires_at > now() AND u.status = 'active'`, tokenHash,
	).Scan(&u.ID, &u.Phone, &u.Name, &u.FirstName, &u.LastName, &u.Birthday, &u.ProfileMediaID, &u.IsAdmin, &u.Status, &u.CreatedAt, &u.Title, &u.TitleSetAt)
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

// NotificationPrefs reports a user's notification settings.
func (d *DB) NotificationPrefs(ctx context.Context, userID int64) (NotifyPrefs, error) {
	var p NotifyPrefs
	err := d.Pool.QueryRow(ctx,
		`SELECT notify_posts, notify_replies, notify_likes,
		        digest_enabled, digest_hour, digest_offset
		   FROM users WHERE id = $1`, userID,
	).Scan(&p.Posts, &p.Replies, &p.Likes, &p.DigestEnabled, &p.DigestHour, &p.DigestOffset)
	return p, err
}

// SetNotificationPrefs updates a user's notification settings. Changing the digest window
// clears digest_sent_at so a member who just set "8pm" gets tonight's summary rather than
// being locked out by a send that already happened under the old window.
func (d *DB) SetNotificationPrefs(ctx context.Context, userID int64, p NotifyPrefs) error {
	_, err := d.Pool.Exec(ctx, `
		UPDATE users SET
			notify_posts = $2, notify_replies = $3, notify_likes = $4,
			digest_enabled = $5, digest_hour = $6, digest_offset = $7,
			digest_sent_at = CASE
				WHEN digest_enabled IS DISTINCT FROM $5
				  OR digest_hour    IS DISTINCT FROM $6
				  OR digest_offset  IS DISTINCT FROM $7 THEN NULL
				ELSE digest_sent_at
			END
		WHERE id = $1`,
		userID, p.Posts, p.Replies, p.Likes, p.DigestEnabled, p.DigestHour, p.DigestOffset)
	return err
}

// TokensForNewPost returns the device tokens of every active member who wants new-post
// notifications, excluding the post's author. Members on a digest are excluded: their
// check-ins arrive as one summary at their chosen hour instead of a ping each.
func (d *DB) TokensForNewPost(ctx context.Context, authorID int64) ([]string, error) {
	return d.scanTokens(ctx, `
		SELECT dt.token FROM device_tokens dt
		JOIN users u ON u.id = dt.user_id
		WHERE u.status = 'active' AND u.notify_posts = TRUE
		  AND u.digest_enabled = FALSE AND u.id <> $1`, authorID)
}

// DigestDue is one member whose digest hour has arrived, with the window to summarize.
type DigestDue struct {
	UserID int64
	Since  time.Time
}

// DigestTargets finds active members whose chosen local hour is the current hour and who
// haven't had a summary in the last 20 hours (so each member gets at most one a day, while
// still tolerating a scheduler tick that runs late).
//
// now() is converted to the member's wall clock by adding their stored UTC offset; the
// AT TIME ZONE 'UTC' pins the arithmetic to UTC regardless of the session's timezone.
func (d *DB) DigestTargets(ctx context.Context) ([]DigestDue, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT id, COALESCE(digest_sent_at, now() - interval '24 hours')
		  FROM users
		 WHERE digest_enabled AND status = 'active'
		   AND EXTRACT(HOUR FROM ((now() AT TIME ZONE 'UTC')
		         + make_interval(mins => digest_offset))) = digest_hour
		   AND (digest_sent_at IS NULL OR digest_sent_at < now() - interval '20 hours')`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DigestDue
	for rows.Next() {
		var t DigestDue
		if err := rows.Scan(&t.UserID, &t.Since); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// CountPostsSince counts check-ins visible to [userID] since [since] - what that member has
// missed in the window their digest covers. Applies the same active-author, not-blocked-by-
// viewer predicate the feed uses, so the digest can never tell someone about a check-in they
// couldn't actually open (a revoked member's, or one from someone they've since blocked) -
// and excludes kind = 'recap': a recap is the group's own periodic summary of everyone
// else's check-ins, not a check-in itself, and counting it here would both double-count the
// activity it already tallies and could fire on a period whose only underlying posts came
// from an author this member has blocked.
func (d *DB) CountPostsSince(ctx context.Context, userID int64, since time.Time) (int, error) {
	var n int
	err := d.Pool.QueryRow(ctx, `
		SELECT count(*) FROM posts p JOIN users u ON u.id = p.author_id
		WHERE p.author_id <> $1 AND p.created_at > $2
		  AND u.status = 'active' AND p.kind <> 'recap'
		  AND p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)`,
		userID, since,
	).Scan(&n)
	return n, err
}

// TokensForUser returns every device token registered by one member.
func (d *DB) TokensForUser(ctx context.Context, userID int64) ([]string, error) {
	return d.scanTokens(ctx, `SELECT token FROM device_tokens WHERE user_id = $1`, userID)
}

// MarkDigestSent records that this member's summary has been delivered for today. It is
// set even when there was nothing to report, so the window advances and the scheduler
// doesn't re-examine them for the rest of the hour.
func (d *DB) MarkDigestSent(ctx context.Context, userID int64) error {
	_, err := d.Pool.Exec(ctx, `UPDATE users SET digest_sent_at = now() WHERE id = $1`, userID)
	return err
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

// TokensForCommentReply returns the parent comment author's device tokens when someone
// replies to their comment. It reuses the notify_replies opt-out, skips the replier, and
// skips the post's author because notifyReply already pings them for any new comment — so a
// reply to your own post's comment doesn't double-buzz.
func (d *DB) TokensForCommentReply(ctx context.Context, parentCommentID, replierID int64) ([]string, error) {
	return d.scanTokens(ctx, `
		SELECT dt.token FROM device_tokens dt
		JOIN comments pc ON pc.id = $1
		JOIN posts p ON p.id = pc.post_id
		JOIN users u ON u.id = pc.user_id
		WHERE dt.user_id = pc.user_id AND u.status = 'active'
		  AND u.notify_replies = TRUE AND pc.user_id <> $2 AND pc.user_id <> p.author_id`,
		parentCommentID, replierID)
}

// TokensForLike returns the post author's device tokens when they want like
// notifications and aren't the one who just liked.
func (d *DB) TokensForLike(ctx context.Context, postID, likerID int64) ([]string, error) {
	return d.scanTokens(ctx, `
		SELECT dt.token FROM device_tokens dt
		JOIN posts p ON p.id = $1
		JOIN users u ON u.id = p.author_id
		WHERE dt.user_id = p.author_id AND u.status = 'active'
		  AND u.notify_likes = TRUE AND p.author_id <> $2`, postID, likerID)
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

// mediaColumns is the column list every media read shares, in Media field order.
const mediaColumns = `id, owner_id, path, mime, width, height, duration_ms, poster_path, created_at`

// CreateMedia records an uploaded file.
func (d *DB) CreateMedia(ctx context.Context, ownerID *int64, path, mime string, width, height, durationMs int) (Media, error) {
	var m Media
	err := d.Pool.QueryRow(ctx, `
		INSERT INTO media (owner_id, path, mime, width, height, duration_ms)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING `+mediaColumns,
		ownerID, path, mime, width, height, durationMs,
	).Scan(&m.ID, &m.OwnerID, &m.Path, &m.Mime, &m.Width, &m.Height, &m.DurationMs, &m.PosterPath, &m.CreatedAt)
	return m, err
}

// GetMedia returns media metadata by id.
func (d *DB) GetMedia(ctx context.Context, id int64) (Media, error) {
	var m Media
	err := d.Pool.QueryRow(ctx,
		`SELECT `+mediaColumns+` FROM media WHERE id = $1`, id,
	).Scan(&m.ID, &m.OwnerID, &m.Path, &m.Mime, &m.Width, &m.Height, &m.DurationMs, &m.PosterPath, &m.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return m, ErrNotFound
	}
	return m, err
}

// SetMediaPoster attaches a still frame to a clip the caller owns, returning the path of
// the poster it replaced (empty when there was none) so the caller can delete the old
// file. Returns ErrNotFound when the item does not exist, belongs to someone else, or is
// not a video - an image never needs a poster, and allowing one would let hasPoster mean
// something no client is prepared for.
func (d *DB) SetMediaPoster(ctx context.Context, mediaID, ownerID int64, posterPath string) (string, error) {
	var previous string
	// The CTE runs against the statement's snapshot, so it still sees the row as it was
	// before the UPDATE - which is the only way to learn the path being orphaned.
	err := d.Pool.QueryRow(ctx, `
		WITH old AS (SELECT poster_path FROM media WHERE id = $1 AND owner_id = $2)
		UPDATE media SET poster_path = $3
		WHERE id = $1 AND owner_id = $2 AND mime LIKE 'video/%'
		RETURNING COALESCE((SELECT poster_path FROM old), '')`,
		mediaID, ownerID, posterPath).Scan(&previous)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return previous, err
}

// GetVisibleMedia returns a media item only if the viewer is allowed to see it: they
// uploaded it, it's attached to a post or comment whose author is active and not blocked
// by the viewer (the feed's own visibility rule - see Feed/GetPost/ListComments), or it's
// someone's profile photo. This prevents enumerating arbitrary media ids (e.g. another
// member's not-yet-posted upload or media from a deleted post) and, just as importantly,
// stops the two mechanisms the app offers for controlling exposure to a person - blocking
// and an admin revoke - from being bypassable by fetching /api/media/{id} directly, since
// media ids are sequential and this route has no other access check. Returns ErrNotFound
// otherwise, so existence isn't confirmed.
func (d *DB) GetVisibleMedia(ctx context.Context, id, viewerID int64) (Media, error) {
	var m Media
	err := d.Pool.QueryRow(ctx, `
		SELECT m.id, m.owner_id, m.path, m.mime, m.width, m.height, m.duration_ms, m.poster_path, m.created_at
		FROM media m
		WHERE m.id = $1 AND (
			m.owner_id = $2
			OR EXISTS (
				SELECT 1 FROM posts p JOIN users pu ON pu.id = p.author_id
				WHERE p.media_id = m.id AND pu.status = 'active'
				  AND pu.id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $2)
			)
			OR EXISTS (
				SELECT 1 FROM post_media pm
				JOIN posts p ON p.id = pm.post_id
				JOIN users pu ON pu.id = p.author_id
				WHERE pm.media_id = m.id AND pu.status = 'active'
				  AND pu.id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $2)
			)
			OR EXISTS (
				SELECT 1 FROM comments c JOIN users cu ON cu.id = c.user_id
				WHERE c.media_id = m.id AND cu.status = 'active'
				  AND cu.id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $2)
			)
			OR EXISTS (SELECT 1 FROM users u WHERE u.profile_media_id = m.id)
		)`, id, viewerID,
	).Scan(&m.ID, &m.OwnerID, &m.Path, &m.Mime, &m.Width, &m.Height, &m.DurationMs, &m.PosterPath, &m.CreatedAt)
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

// CreatePost inserts a post. Its kind is derived from what is attached rather than taken
// from the caller: the attachments are already being read here to check ownership, and a
// post whose kind disagrees with its contents is a rendering bug on every client.
//
// lat/lng are the coordinates the client claims to have read at capture time; nil for a
// post with no GPS, and always nil for a text post (mirrors location). They are clamped
// and rounded here - at the write boundary, not trusted from any caller - so a modified
// client or a raw API call can never store more precision than the app itself ever sends.
// Stored for the v1.5 map panel.
func (d *DB) CreatePost(ctx context.Context, authorID int64, body string, mediaIDs []int64, location *string, peopleIDs []int64, crossPostID *string, lat, lng *float64) (Post, error) {
	lat, lng = normalizeCoords(lat, lng)

	var p Post
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return p, err
	}
	defer tx.Rollback(ctx)

	// The author must own every referenced media item. Without this an author could
	// attach another member's media id, which GetVisibleMedia would then expose to the
	// whole group (an IDOR / privacy leak). Treat unowned or non-existent ids the same.
	attached, err := ownedMedia(ctx, tx, mediaIDs, authorID)
	if err != nil {
		return p, err
	}
	kind := kindFor(attached)

	cover := coverFor(attached)
	err = tx.QueryRow(ctx, `
		INSERT INTO posts (author_id, kind, body, media_id, location, cross_post_id, lat, lng)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		RETURNING id, author_id, kind, body, media_id, location, created_at, cross_post_id, lat, lng`,
		authorID, kind, body, cover, location, crossPostID, lat, lng,
	).Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt, &p.CrossPostID, &p.Lat, &p.Lng)
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

	// Manual people-tags: members the author marked as appearing in the post. Dedupe, drop
	// the author (implicit), and insert only ids that resolve to an active user so a bad id
	// silently no-ops rather than poisoning the post. Then read names back for the response.
	if ids := dedupeExcluding(peopleIDs, authorID); len(ids) > 0 {
		if _, err := tx.Exec(ctx, `
			INSERT INTO post_people (post_id, user_id)
			SELECT $1, u.id FROM users u WHERE u.id = ANY($2) AND u.status = 'active'`,
			p.ID, ids); err != nil {
			return p, err
		}
		rows, err := tx.Query(ctx, `
			SELECT pp.user_id, tu.name FROM post_people pp JOIN users tu ON tu.id = pp.user_id
			WHERE pp.post_id = $1 ORDER BY tu.name`, p.ID)
		if err != nil {
			return p, err
		}
		for rows.Next() {
			var tp TaggedPerson
			if err := rows.Scan(&tp.ID, &tp.Name); err != nil {
				rows.Close()
				return p, err
			}
			p.People = append(p.People, tp)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return p, err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return p, err
	}
	p.MediaIDs = mediaIDs
	p.Media = attached
	return p, nil
}

// ownedMedia returns the given media items in the order asked for, and ErrNotOwned unless
// every one of them belongs to the author.
func ownedMedia(ctx context.Context, tx pgx.Tx, mediaIDs []int64, authorID int64) ([]PostMedia, error) {
	if len(mediaIDs) == 0 {
		return nil, nil
	}
	rows, err := tx.Query(ctx, `
		SELECT id, mime, width, height, duration_ms, poster_path <> ''
		FROM media WHERE id = ANY($1) AND owner_id = $2`, mediaIDs, authorID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	byID := make(map[int64]PostMedia, len(mediaIDs))
	for rows.Next() {
		var m PostMedia
		if err := rows.Scan(&m.ID, &m.Mime, &m.Width, &m.Height, &m.DurationMs, &m.HasPoster); err != nil {
			return nil, err
		}
		byID[m.ID] = m
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make([]PostMedia, 0, len(mediaIDs))
	for _, id := range mediaIDs {
		m, ok := byID[id]
		if !ok {
			return nil, ErrNotOwned
		}
		out = append(out, m)
	}
	return out, nil
}

// coverFor picks the legacy posts.media_id cover: the first IMAGE attached, never a clip.
// A published client renders whatever this id serves as a picture, so pointing it at a
// clip would paint broken-image icons where degrading to caption-only is the intended
// old-client behaviour. Nil when nothing attached is an image at all.
func coverFor(media []PostMedia) *int64 {
	for i := range media {
		if strings.HasPrefix(media[i].Mime, "image/") {
			return &media[i].ID
		}
	}
	return nil
}

// kindFor derives a post's kind from what is attached to it. Video wins over image so a
// mixed post still tells an old client it has something it cannot render.
func kindFor(media []PostMedia) string {
	if len(media) == 0 {
		return "text"
	}
	for _, m := range media {
		if strings.HasPrefix(m.Mime, "video/") {
			return "video"
		}
	}
	return "image"
}

// normalizeCoords clamps lat/lng into their valid ranges and rounds each to 2 decimal
// places (~1.1km), or returns (nil, nil) unless both are present - a lone coordinate is
// meaningless. The client already rounds before sending (home_shell.dart's _roundCoord),
// but that is advisory only; this is the actual guarantee, since the data accumulates
// permanently once a post exists.
func normalizeCoords(lat, lng *float64) (*float64, *float64) {
	if lat == nil || lng == nil {
		return nil, nil
	}
	nlat := normalizeCoord(*lat, -90, 90)
	nlng := normalizeCoord(*lng, -180, 180)
	return &nlat, &nlng
}

// normalizeCoord clamps v to [min, max] and rounds it to 2 decimal places.
func normalizeCoord(v, min, max float64) float64 {
	if v < min {
		v = min
	}
	if v > max {
		v = max
	}
	return math.Round(v*100) / 100
}

// dedupeExcluding returns the unique ids in order, dropping any equal to exclude.
func dedupeExcluding(ids []int64, exclude int64) []int64 {
	if len(ids) == 0 {
		return nil
	}
	seen := make(map[int64]struct{}, len(ids))
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if id == exclude {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out
}

// Feed returns posts in reverse-chronological order with engagement counts, optionally
// filtered to a single author, to one or more locations (a post matches if its location is
// any of them; empty/nil means no location filter), and/or to posts created strictly before
// a cursor time.
//
// excludeRecap drops kind = 'recap' posts entirely - used for a member's personal profile
// timeline (handleUserPosts), where a recap is a group artifact attributed to the admin
// rather than something they personally posted, and does not belong in their history. The
// main feed passes false: recaps belong there like any other post.
func (d *DB) Feed(ctx context.Context, viewerID int64, authorID *int64, locations []string, before *time.Time, beforeID *int64, limit int, excludeRecap bool) ([]Post, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at, p.cross_post_id, p.lat, p.lng,
		       CASE WHEN p.kind = 'recap' THEN sc.name ELSE u.name END,
		       CASE WHEN p.kind = 'recap' THEN NULL ELSE u.profile_media_id END,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
		        AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+postPeopleExpr+recapExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		JOIN server_config sc ON sc.id = 1
		WHERE ($2::bigint IS NULL OR p.author_id = $2)
		  AND ($3::text[] IS NULL OR p.location = ANY($3::text[]))
		  AND ($4::timestamptz IS NULL
		       OR ($6::bigint IS NULL AND p.created_at < $4)
		       OR ($6::bigint IS NOT NULL AND (p.created_at, p.id) < ($4, $6)))
		  AND u.status = 'active'
		  AND (p.kind = 'recap' OR p.author_id NOT IN (
		      SELECT blocked_id FROM user_blocks WHERE blocker_id = $1))
		  AND ($7::bool = FALSE OR p.kind <> 'recap')
		ORDER BY p.created_at DESC, p.id DESC
		LIMIT $5`, viewerID, authorID, locations, before, limit, beforeID, excludeRecap)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var posts []Post
	for rows.Next() {
		var p Post
		var preview, media, people, recap []byte
		if err := rows.Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt, &p.CrossPostID, &p.Lat, &p.Lng,
			&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview, &media, &people, &recap); err != nil {
			return nil, err
		}
		if len(preview) > 0 {
			_ = json.Unmarshal(preview, &p.CommentsPreview)
		}
		if len(people) > 0 {
			_ = json.Unmarshal(people, &p.People)
		}
		p.applyMedia(media)
		p.applyRecap(recap)
		posts = append(posts, p)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return d.applyRecapVisibility(ctx, viewerID, posts)
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
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at, p.cross_post_id, p.lat, p.lng,
		       CASE WHEN p.kind = 'recap' THEN sc.name ELSE u.name END,
		       CASE WHEN p.kind = 'recap' THEN NULL ELSE u.profile_media_id END,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
		        AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+postPeopleExpr+recapExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		JOIN server_config sc ON sc.id = 1
		WHERE u.status = 'active'
		  AND (p.kind = 'recap' OR p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1))
		  AND (
		      p.body ILIKE '%' || $2 || '%'
		   OR EXISTS (SELECT 1 FROM comments c WHERE c.post_id = p.id AND c.body ILIKE '%' || $2 || '%'
		              AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1))
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
		var preview, media, people, recap []byte
		if err := rows.Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt, &p.CrossPostID, &p.Lat, &p.Lng,
			&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview, &media, &people, &recap); err != nil {
			return nil, err
		}
		if len(preview) > 0 {
			_ = json.Unmarshal(preview, &p.CommentsPreview)
		}
		if len(people) > 0 {
			_ = json.Unmarshal(people, &p.People)
		}
		p.applyMedia(media)
		p.applyRecap(recap)
		posts = append(posts, p)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return d.applyRecapVisibility(ctx, viewerID, posts)
}

// GetPost returns a single post with engagement counts from the viewer's perspective.
func (d *DB) GetPost(ctx context.Context, viewerID, postID int64) (Post, error) {
	var p Post
	var preview, media, people, recap []byte
	err := d.Pool.QueryRow(ctx, `
		SELECT p.id, p.author_id, p.kind, p.body, p.media_id, p.location, p.created_at, p.cross_post_id, p.lat, p.lng,
		       CASE WHEN p.kind = 'recap' THEN sc.name ELSE u.name END,
		       CASE WHEN p.kind = 'recap' THEN NULL ELSE u.profile_media_id END,
		       (SELECT count(*) FROM likes l WHERE l.post_id = p.id),
		       (SELECT count(*) FROM comments c WHERE c.post_id = p.id
		        AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1)),
		       EXISTS(SELECT 1 FROM likes l WHERE l.post_id = p.id AND l.user_id = $1)`+commentPreviewExpr+postMediaExpr+postPeopleExpr+recapExpr+`
		FROM posts p
		JOIN users u ON u.id = p.author_id
		JOIN server_config sc ON sc.id = 1
		WHERE p.id = $2 AND u.status = 'active'
		  AND (p.kind = 'recap' OR p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $1))`,
		viewerID, postID,
	).Scan(&p.ID, &p.AuthorID, &p.Kind, &p.Body, &p.MediaID, &p.Location, &p.CreatedAt, &p.CrossPostID, &p.Lat, &p.Lng,
		&p.AuthorName, &p.AuthorPhotoID, &p.LikeCount, &p.CommentCount, &p.LikedByViewer, &preview, &media, &people, &recap)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, ErrNotFound
	}
	if err == nil && len(preview) > 0 {
		_ = json.Unmarshal(preview, &p.CommentsPreview)
	}
	if err == nil && len(people) > 0 {
		_ = json.Unmarshal(people, &p.People)
	}
	if err == nil {
		p.applyMedia(media)
		p.applyRecap(recap)
	}
	if err != nil {
		return p, err
	}
	if p.Recap != nil {
		blocked, berr := d.blockedSet(ctx, viewerID)
		if berr != nil {
			return p, berr
		}
		if len(blocked) > 0 {
			filtered := FilterRecapForViewer(*p.Recap, blocked)
			p.Recap = &filtered
		}
	}
	return p, nil
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
// post_media, a comment, or a profile photo, returning their stored file paths. Run after
// the referencing row is deleted so its own reference is already gone.
//
// A video row owns two files, so the poster comes back alongside the clip. Returning only
// the clip would leave a file on disk that nothing references and nothing will ever look
// for again, and the only symptom is a media volume that slowly fills.
func deleteOrphanMedia(ctx context.Context, tx pgx.Tx, candidates []int64) ([]string, error) {
	var paths []string
	for _, mid := range candidates {
		var path, poster string
		err := tx.QueryRow(ctx, `
			DELETE FROM media m WHERE m.id = $1
			  AND NOT EXISTS (SELECT 1 FROM posts p WHERE p.media_id = m.id)
			  AND NOT EXISTS (SELECT 1 FROM post_media pm WHERE pm.media_id = m.id)
			  AND NOT EXISTS (SELECT 1 FROM comments c WHERE c.media_id = m.id)
			  AND NOT EXISTS (SELECT 1 FROM users u WHERE u.profile_media_id = m.id)
			RETURNING m.path, m.poster_path`, mid).Scan(&path, &poster)
		if errors.Is(err, pgx.ErrNoRows) {
			continue // still referenced elsewhere; keep it
		}
		if err != nil {
			return nil, err
		}
		paths = append(paths, path)
		if poster != "" {
			paths = append(paths, poster)
		}
	}
	return paths, nil
}

// AdminDeleteComment removes any comment by id (operator dashboard moderation), plus its
// media if that leaves it orphaned, returning the stored file path to remove (empty when
// the comment carried no attachment or its media is still used elsewhere - by another
// comment, a post, or a profile photo).
func (d *DB) AdminDeleteComment(ctx context.Context, commentID int64) ([]string, error) {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	var mediaID *int64
	err = tx.QueryRow(ctx, `SELECT media_id FROM comments WHERE id = $1`, commentID).Scan(&mediaID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	ct, err := tx.Exec(ctx, `DELETE FROM comments WHERE id = $1`, commentID)
	if err != nil {
		return nil, err
	}
	if ct.RowsAffected() == 0 {
		return nil, ErrNotFound
	}

	var candidates []int64
	if mediaID != nil {
		candidates = []int64{*mediaID}
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

// RecentComments returns the latest comments across all posts with their author name,
// for the operator dashboard's activity view.
func (d *DB) RecentComments(ctx context.Context, limit int) ([]Comment, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT c.id, c.post_id, c.user_id, c.body, c.created_at, c.media_id, u.name
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
		if err := rows.Scan(&c.ID, &c.PostID, &c.UserID, &c.Body, &c.CreatedAt, &c.MediaID, &c.AuthorName); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ---- likes ----

// PostVisible reports whether a post exists and is visible to a specific viewer for
// ordinary interaction: its author is still active AND the viewer hasn't blocked them - the
// same predicate the feed already applies. Used by handleLike and handleAddComment (and
// handleListComments) to refuse the action on a missing or hidden post with a clean 404
// instead of leaking a foreign-key 500 or, just as important, letting a member like,
// comment on, or read the comments of a post from someone they've specifically blocked just
// because they still know (or can guess) its id. Viewer-scoped for the same reason
// GetVisibleMedia is: "visible" has to mean visible to *someone*, and a blocked author's
// posts are exactly the case where that differs per caller.
//
// Deliberately NOT used by handleReportPost - see ReportablePost below for why reporting
// gets its own, viewer-independent check instead of this one.
func (d *DB) PostVisible(ctx context.Context, postID, viewerID int64) (bool, error) {
	var ok bool
	err := d.Pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM posts p JOIN users u ON u.id = p.author_id
			WHERE p.id = $1 AND u.status = 'active'
			  AND p.author_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $2))`,
		postID, viewerID).Scan(&ok)
	return ok, err
}

// ReportablePost reports whether a post exists and its author's account is still active -
// deliberately independent of the reporter's own block list, unlike PostVisible. Reporting
// abusive content to the host must not get harder, or start silently 404ing, the moment a
// member protects themselves by blocking that content's author: "I blocked them AND
// reported this" is the expected pair of actions a safety feature should support, and a
// member who already blocked someone specifically because of a post is exactly who most
// needs to still be able to flag it. A revoked author's post still 404s here, same as
// PostVisible - there's no host left to receive a report about content whose author the
// host already removed.
func (d *DB) ReportablePost(ctx context.Context, postID int64) (bool, error) {
	var ok bool
	err := d.Pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM posts p JOIN users u ON u.id = p.author_id
			WHERE p.id = $1 AND u.status = 'active')`, postID).Scan(&ok)
	return ok, err
}

// PostAuthorID returns the id of the member who created a post, or ErrNotFound.
func (d *DB) PostAuthorID(ctx context.Context, postID int64) (int64, error) {
	var authorID int64
	err := d.Pool.QueryRow(ctx, `SELECT author_id FROM posts WHERE id = $1`, postID).Scan(&authorID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	}
	return authorID, err
}

// PostLikers returns the members who liked a post, most recent first. Used by the
// author-only "who liked this" list.
func (d *DB) PostLikers(ctx context.Context, postID int64) ([]Liker, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT u.id, u.name, u.profile_media_id
		FROM likes l JOIN users u ON u.id = l.user_id
		WHERE l.post_id = $1 AND u.status = 'active'
		ORDER BY l.created_at DESC`, postID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	likers := []Liker{}
	for rows.Next() {
		var lk Liker
		if err := rows.Scan(&lk.ID, &lk.Name, &lk.ProfileMediaID); err != nil {
			return nil, err
		}
		likers = append(likers, lk)
	}
	return likers, rows.Err()
}

// LikePost adds a like, ignoring duplicates. Returns whether a new like was actually
// inserted (false when the post was already liked) so callers can skip a redundant push.
func (d *DB) LikePost(ctx context.Context, postID, userID int64) (bool, error) {
	tag, err := d.Pool.Exec(ctx,
		`INSERT INTO likes (post_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		postID, userID)
	return tag.RowsAffected() > 0, err
}

// UnlikePost removes a like.
func (d *DB) UnlikePost(ctx context.Context, postID, userID int64) error {
	_, err := d.Pool.Exec(ctx, `DELETE FROM likes WHERE post_id = $1 AND user_id = $2`, postID, userID)
	return err
}

// ---- comments ----

// AddComment inserts a comment and returns it. parentID, when non-nil, links it to the
// comment it replies to (validated by the caller to belong to the same post). mediaID, when
// non-nil, attaches a gif the caller must own - the same IDOR protection CreatePost applies
// to its attachments, since without it a member could point a comment at someone else's
// not-yet-posted upload and have it exposed to the whole group.
func (d *DB) AddComment(ctx context.Context, postID, userID int64, body string, parentID, mediaID *int64) (Comment, error) {
	var c Comment
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return c, err
	}
	defer tx.Rollback(ctx)

	if err := commentMediaOwned(ctx, tx, mediaID, userID); err != nil {
		return c, err
	}

	// Return the author's name + photo alongside the new row (via CTE) so the response
	// matches ListComments — otherwise the client renders the just-posted comment with an
	// empty name and a placeholder avatar.
	err = tx.QueryRow(ctx, `
		WITH ins AS (
			INSERT INTO comments (post_id, user_id, body, parent_comment_id, media_id) VALUES ($1, $2, $3, $4, $5)
			RETURNING id, post_id, user_id, body, created_at, parent_comment_id, media_id
		)
		SELECT ins.id, ins.post_id, ins.user_id, ins.body, ins.created_at, ins.parent_comment_id, ins.media_id, u.name, u.profile_media_id
		FROM ins JOIN users u ON u.id = ins.user_id`,
		postID, userID, body, parentID, mediaID,
	).Scan(&c.ID, &c.PostID, &c.UserID, &c.Body, &c.CreatedAt, &c.ParentCommentID, &c.MediaID, &c.AuthorName, &c.AuthorPhotoID)
	if err != nil {
		return c, err
	}
	return c, tx.Commit(ctx)
}

// commentMediaOwned reports ErrNotOwned unless mediaID belongs to userID; a nil mediaID
// (no attachment) always passes. Mirrors ownedMedia's ownership check for post attachments.
func commentMediaOwned(ctx context.Context, tx pgx.Tx, mediaID *int64, userID int64) error {
	if mediaID == nil {
		return nil
	}
	var owner *int64
	err := tx.QueryRow(ctx, `SELECT owner_id FROM media WHERE id = $1`, *mediaID).Scan(&owner)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotOwned
	}
	if err != nil {
		return err
	}
	if owner == nil || *owner != userID {
		return ErrNotOwned
	}
	return nil
}

// ListComments returns comments on a post in chronological order with author info.
func (d *DB) ListComments(ctx context.Context, postID, viewerID int64) ([]Comment, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT c.id, c.post_id, c.user_id, c.body, c.created_at, c.parent_comment_id, c.media_id, u.name, u.profile_media_id
		FROM comments c JOIN users u ON u.id = c.user_id
		WHERE c.post_id = $1
		  AND c.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = $2)
		ORDER BY c.created_at ASC`, postID, viewerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var comments []Comment
	for rows.Next() {
		var c Comment
		if err := rows.Scan(&c.ID, &c.PostID, &c.UserID, &c.Body, &c.CreatedAt, &c.ParentCommentID, &c.MediaID, &c.AuthorName, &c.AuthorPhotoID); err != nil {
			return nil, err
		}
		comments = append(comments, c)
	}
	return comments, rows.Err()
}

// ParentCommentForPost returns the post a comment belongs to and its author, so a reply
// handler can check the parent is real and on the same post before threading to it. found
// is false (with a nil error) when no such comment exists.
func (d *DB) ParentCommentForPost(ctx context.Context, commentID int64) (postID, authorID int64, found bool, err error) {
	err = d.Pool.QueryRow(ctx,
		`SELECT post_id, user_id FROM comments WHERE id = $1`, commentID,
	).Scan(&postID, &authorID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, 0, false, nil
	}
	if err != nil {
		return 0, 0, false, err
	}
	return postID, authorID, true, nil
}

// ---- blocks ----

// BlockUser records that blocker wants to hide blocked's content from their feed.
// Silently ignored if the block already exists.
func (d *DB) BlockUser(ctx context.Context, blockerID, blockedID int64) error {
	_, err := d.Pool.Exec(ctx,
		`INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		blockerID, blockedID)
	return err
}

// UnblockUser removes a block. No-ops if it didn't exist.
func (d *DB) UnblockUser(ctx context.Context, blockerID, blockedID int64) error {
	_, err := d.Pool.Exec(ctx,
		`DELETE FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2`, blockerID, blockedID)
	return err
}

// IsBlocked reports whether blockerID has blocked blockedID.
func (d *DB) IsBlocked(ctx context.Context, blockerID, blockedID int64) (bool, error) {
	var ok bool
	err := d.Pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2)`,
		blockerID, blockedID).Scan(&ok)
	return ok, err
}

// ListBlockedIDs returns the ids of all users blocked by blockerID.
func (d *DB) ListBlockedIDs(ctx context.Context, blockerID int64) ([]int64, error) {
	rows, err := d.Pool.Query(ctx,
		`SELECT blocked_id FROM user_blocks WHERE blocker_id = $1 ORDER BY created_at DESC`, blockerID)
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

// blockedSet returns the ids blocked by viewerID as a set. Used where a query's own SQL
// predicate can't reach the thing that needs filtering - currently only a recap post's
// frozen payload (see applyRecapVisibility and FilterRecapForViewer in recap.go), since its
// collage cards and roster are document content joined in as one opaque JSON blob, not rows
// a WHERE clause can exclude by author the way every other query's blocked-author predicate
// does.
func (d *DB) blockedSet(ctx context.Context, viewerID int64) (map[int64]bool, error) {
	ids, err := d.ListBlockedIDs(ctx, viewerID)
	if err != nil {
		return nil, err
	}
	set := make(map[int64]bool, len(ids))
	for _, id := range ids {
		set[id] = true
	}
	return set, nil
}

// applyRecapVisibility filters the Recap payload of every recap post in posts down to what
// viewerID may see (see FilterRecapForViewer), fetching the viewer's block list only if at
// least one recap post is actually present in the page — an ordinary feed page, the common
// case, never pays for the extra round trip.
func (d *DB) applyRecapVisibility(ctx context.Context, viewerID int64, posts []Post) ([]Post, error) {
	hasRecap := false
	for i := range posts {
		if posts[i].Recap != nil {
			hasRecap = true
			break
		}
	}
	if !hasRecap {
		return posts, nil
	}
	blocked, err := d.blockedSet(ctx, viewerID)
	if err != nil {
		return nil, err
	}
	if len(blocked) == 0 {
		return posts, nil
	}
	for i := range posts {
		if posts[i].Recap != nil {
			filtered := FilterRecapForViewer(*posts[i].Recap, blocked)
			posts[i].Recap = &filtered
		}
	}
	return posts, nil
}

// ---- content reports ----

// CommentExists reports whether a comment id refers to a real comment.
func (d *DB) CommentExists(ctx context.Context, commentID int64) (bool, error) {
	var exists bool
	err := d.Pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM comments WHERE id = $1)`, commentID).Scan(&exists)
	return exists, err
}

// ReportPost stores a member's flag on a post. A member reporting the same post more than
// once is a no-op (see the unique index in migration 0010) so the admin queue can't be
// flooded with duplicates.
func (d *DB) ReportPost(ctx context.Context, reporterID, postID int64, reason string) error {
	_, err := d.Pool.Exec(ctx,
		`INSERT INTO content_reports (reporter_id, post_id, reason) VALUES ($1, $2, $3)
		 ON CONFLICT DO NOTHING`,
		reporterID, postID, reason)
	return err
}

// ReportComment stores a member's flag on a comment. Duplicate reports on the same comment
// by the same member are a no-op (see migration 0010).
func (d *DB) ReportComment(ctx context.Context, reporterID, commentID int64, reason string) error {
	_, err := d.Pool.Exec(ctx,
		`INSERT INTO content_reports (reporter_id, comment_id, reason) VALUES ($1, $2, $3)
		 ON CONFLICT DO NOTHING`,
		reporterID, commentID, reason)
	return err
}

// ListReports returns all open (non-dismissed) reports with joined context for the admin.
func (d *DB) ListReports(ctx context.Context) ([]ContentReport, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT
			cr.id, cr.reporter_id, ru.name,
			cr.post_id, cr.comment_id,
			cr.reason, cr.dismissed, cr.created_at,
			COALESCE(p.body, c.body, '') AS content_body,
			COALESCE(pu.name, cu.name, '') AS author_name
		FROM content_reports cr
		JOIN users ru ON ru.id = cr.reporter_id
		LEFT JOIN posts p ON p.id = cr.post_id
		LEFT JOIN users pu ON pu.id = p.author_id
		LEFT JOIN comments c ON c.id = cr.comment_id
		LEFT JOIN users cu ON cu.id = c.user_id
		WHERE cr.dismissed = FALSE
		ORDER BY cr.created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ContentReport
	for rows.Next() {
		var r ContentReport
		if err := rows.Scan(&r.ID, &r.ReporterID, &r.ReporterName,
			&r.PostID, &r.CommentID,
			&r.Reason, &r.Dismissed, &r.CreatedAt,
			&r.ContentBody, &r.AuthorName); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// DismissReport marks a report as handled (dismissed by the admin).
func (d *DB) DismissReport(ctx context.Context, reportID int64) error {
	ct, err := d.Pool.Exec(ctx, `UPDATE content_reports SET dismissed = TRUE WHERE id = $1`, reportID)
	if err != nil {
		return err
	}
	if ct.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ---- account deletion ----

// OtherAdminExists reports whether any admin other than excludeUserID exists. Used to stop
// the sole admin from deleting themselves, which would leave the server with no one able to
// invite members, review reports, or remove content.
func (d *DB) OtherAdminExists(ctx context.Context, excludeUserID int64) (bool, error) {
	var exists bool
	err := d.Pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM users WHERE is_admin = TRUE AND id <> $1)`,
		excludeUserID).Scan(&exists)
	return exists, err
}

// DeleteAccount permanently removes a user and all their content. Returns the file paths
// of any media that became orphaned so the caller can remove them from disk.
func (d *DB) DeleteAccount(ctx context.Context, userID int64) ([]string, error) {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// Collect media owned by this user so we can check for orphans after deletion.
	mediaRows, err := tx.Query(ctx, `SELECT id FROM media WHERE owner_id = $1`, userID)
	if err != nil {
		return nil, err
	}
	var mediaIDs []int64
	for mediaRows.Next() {
		var id int64
		if err := mediaRows.Scan(&id); err != nil {
			mediaRows.Close()
			return nil, err
		}
		mediaIDs = append(mediaIDs, id)
	}
	mediaRows.Close()
	if err := mediaRows.Err(); err != nil {
		return nil, err
	}

	// Remove auth + notification data.
	for _, sql := range []string{
		`DELETE FROM sessions WHERE user_id = $1`,
		`DELETE FROM device_tokens WHERE user_id = $1`,
	} {
		if _, err := tx.Exec(ctx, sql, userID); err != nil {
			return nil, err
		}
	}

	// Remove engagement from other people's content.
	for _, sql := range []string{
		`DELETE FROM likes WHERE user_id = $1`,
		`DELETE FROM comments WHERE user_id = $1`,
		`DELETE FROM post_people WHERE user_id = $1`,
		`DELETE FROM user_blocks WHERE blocker_id = $1 OR blocked_id = $1`,
		`DELETE FROM content_reports WHERE reporter_id = $1`,
	} {
		if _, err := tx.Exec(ctx, sql, userID); err != nil {
			return nil, err
		}
	}

	// Collect posts before deleting them (for media cleanup).
	postRows, err := tx.Query(ctx, `SELECT id FROM posts WHERE author_id = $1`, userID)
	if err != nil {
		return nil, err
	}
	var postIDs []int64
	for postRows.Next() {
		var id int64
		if err := postRows.Scan(&id); err != nil {
			postRows.Close()
			return nil, err
		}
		postIDs = append(postIDs, id)
	}
	postRows.Close()
	if err := postRows.Err(); err != nil {
		return nil, err
	}

	// Collect post media ids for orphan check.
	for _, pid := range postIDs {
		more, err := collectPostMedia(ctx, tx, pid)
		if err != nil {
			return nil, err
		}
		mediaIDs = append(mediaIDs, more...)
	}

	// Delete posts (cascades to post_media, post_people, likes, comments on those posts).
	if _, err := tx.Exec(ctx, `DELETE FROM posts WHERE author_id = $1`, userID); err != nil {
		return nil, err
	}

	// Remove from the allowlist so the phone can't be re-used without re-invite.
	if _, err := tx.Exec(ctx, `DELETE FROM allowed_phones WHERE phone = (SELECT phone FROM users WHERE id = $1)`, userID); err != nil {
		return nil, err
	}

	// Delete the user record itself.
	if _, err := tx.Exec(ctx, `DELETE FROM users WHERE id = $1`, userID); err != nil {
		return nil, err
	}

	// Clean up orphaned media files.
	paths, err := deleteOrphanMedia(ctx, tx, mediaIDs)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return paths, nil
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
