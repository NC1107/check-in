-- Digest delivery. Instead of a push per check-in, a member can opt into a single daily
-- summary at a time they choose ("8 new check-ins"), which is the difference between a
-- feed that feels calm and one that feels like spam.
--
-- The member's local time is stored as an hour plus their UTC offset in minutes rather
-- than an IANA zone: the scheduler only ever asks "is it their chosen hour right now?",
-- which needs no timezone database, and the app refreshes the offset on every launch so a
-- DST shift self-corrects.
--
-- Digest replaces new-post pushes only. Replies and likes are directed at you personally,
-- are already rare, and stay instant.
ALTER TABLE users ADD COLUMN digest_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE users ADD COLUMN digest_hour SMALLINT NOT NULL DEFAULT 20; -- 0..23, member-local
ALTER TABLE users ADD COLUMN digest_offset SMALLINT NOT NULL DEFAULT 0; -- minutes east of UTC
ALTER TABLE users ADD COLUMN digest_sent_at TIMESTAMPTZ; -- last summary delivered; NULL = never

CREATE INDEX users_digest_idx ON users (digest_enabled) WHERE digest_enabled;
