-- The activity log ("what happened about me") is derived at read time from likes and
-- comments rather than written to a table of its own, so it needs no storage of its own -
-- only a marker for how far a member has read, and one missing index.
--
-- activity_seen_at lives on the server, not the device, so clearing the bell on a phone
-- also clears it on a tablet. DEFAULT now() rather than NULL is what stops everyone who
-- upgrades into this feature from being handed a badge counting their entire history as
-- unread: an existing member starts caught up, and a new one has nothing to be behind on.
ALTER TABLE users ADD COLUMN activity_seen_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- The replies-to-my-comments branch of the activity query starts by finding MY comments,
-- and comments is indexed only by post and by parent. Without this it scans every comment
-- in the group on every read.
CREATE INDEX comments_user_idx ON comments(user_id, created_at DESC);
