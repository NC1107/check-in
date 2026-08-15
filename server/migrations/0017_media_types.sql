-- Media stops being "always a still image". A client has to know what an attachment is
-- before it can pick a renderer, so every media row now carries the two facts that a
-- still image does not have: how long it runs, and whether a frame exists to show while
-- it is not playing.
--
-- Both use a sentinel rather than NULL, following the relay_key precedent in 0016: every
-- read path can treat them as a plain int/string with no null handling. duration_ms = 0
-- means "not a timed medium"; poster_path = '' means "no poster".
ALTER TABLE media ADD COLUMN duration_ms  INT  NOT NULL DEFAULT 0;
ALTER TABLE media ADD COLUMN poster_path  TEXT NOT NULL DEFAULT '';

-- Posts can now be videos. kind is derived from the attachments on write rather than
-- trusted from the client, but it is not dropped: published clients cast it non-null, so
-- the column (and the field) has to stay emitted forever.
ALTER TABLE posts DROP CONSTRAINT posts_kind_check;
ALTER TABLE posts ADD CONSTRAINT posts_kind_check CHECK (kind IN ('text', 'image', 'video'));
