-- A comment written once and sent to every group holding a copy of the same cross-posted
-- check-in. Client-generated and opaque, exactly like posts.cross_post_id: each group is a
-- separate server, so nothing here can coordinate the copies - the id is simply stored so
-- the multi-group client can collapse them back into one comment, and so the push layer can
-- collapse their notifications into one (see applyCollapse).
--
-- Nullable and unindexed on purpose. A comment on a single-group post has none, which is the
-- overwhelming majority, and nothing ever queries BY this column on the server - only the
-- client groups on it, over comments it has already fetched for one post.
ALTER TABLE comments ADD COLUMN cross_comment_id TEXT;
