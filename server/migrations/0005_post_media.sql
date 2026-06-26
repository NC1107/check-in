-- Multi-photo check-ins: a post can carry several images, ordered.
-- posts.media_id stays as the "cover" (first image) for backward compatibility with
-- older app builds; the full ordered set lives here.
CREATE TABLE post_media (
    post_id   BIGINT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    media_id  BIGINT NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    position  INT NOT NULL DEFAULT 0,
    PRIMARY KEY (post_id, position)
);
CREATE INDEX post_media_post_idx ON post_media (post_id, position);

-- Backfill existing single-image posts as position 0.
INSERT INTO post_media (post_id, media_id, position)
    SELECT id, media_id, 0 FROM posts WHERE media_id IS NOT NULL;
