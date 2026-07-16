-- A cross-post id groups the independent copies of one post that a member shared to
-- several groups at once. Each group is a separate server, so the copies live on
-- different databases; the client generates one id and sends it to every target, and
-- the multi-group client uses it to collapse the copies into a single card. Null for an
-- ordinary single-group post.
ALTER TABLE posts ADD COLUMN cross_post_id TEXT;

CREATE INDEX posts_cross_post_idx ON posts (cross_post_id) WHERE cross_post_id IS NOT NULL;
