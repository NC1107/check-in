-- Opt-out toggle for like notifications, mirroring notify_posts / notify_replies. Default
-- on: a like is a light, welcome ping, and members who want quiet can turn it off.
ALTER TABLE users ADD COLUMN notify_likes BOOLEAN NOT NULL DEFAULT TRUE;
