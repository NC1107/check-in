-- Comments can now carry a GIF attachment (re-hosted media, never a Klipy hotlink),
-- alongside or instead of a text body. ON DELETE SET NULL rather than CASCADE: losing the
-- media a comment pointed at (once it's orphaned and cleaned up) should leave the comment
-- behind with no picture, not delete the comment itself - the same relationship a post has
-- with its own cover.
ALTER TABLE comments ADD COLUMN media_id BIGINT REFERENCES media(id) ON DELETE SET NULL;
