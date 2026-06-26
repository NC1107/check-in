-- Manual people-tagging: who appears in a post, distinct from its author. Lets the feed
-- filter surface "posts they're in", not just "posts they wrote". No visibility impact —
-- the whole group already sees every post, so tags only add filterability.
CREATE TABLE post_people (
	post_id BIGINT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
	user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	PRIMARY KEY (post_id, user_id)
);
-- Drives the "posts a given person is tagged in" lookup.
CREATE INDEX post_people_user_idx ON post_people (user_id);
