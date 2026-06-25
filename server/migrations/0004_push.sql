-- Push notifications: one row per device a member has registered an FCM token from,
-- plus simple opt-out preferences (default on, since a quiet feed is the main thing
-- that kills these apps — members who want calm can turn either off).
CREATE TABLE device_tokens (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token      TEXT NOT NULL UNIQUE,
    platform   TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX device_tokens_user_idx ON device_tokens (user_id);

ALTER TABLE users ADD COLUMN notify_posts   BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE users ADD COLUMN notify_replies BOOLEAN NOT NULL DEFAULT TRUE;
