-- A reply points at the comment it answers, so the client can show a "replying to X" line
-- and the server can notify that comment's author (not just the post's author). The parent
-- always lives on the same server as the reply - a cross-post's copies are independent, and
-- a comment (and its reply) only ever exist on one group's database. Null for a top-level
-- comment. ON DELETE CASCADE so deleting a comment takes its replies with it.
ALTER TABLE comments ADD COLUMN parent_comment_id BIGINT REFERENCES comments(id) ON DELETE CASCADE;

CREATE INDEX comments_parent_idx ON comments (parent_comment_id) WHERE parent_comment_id IS NOT NULL;
