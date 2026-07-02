-- User blocks: a member silences another's content from their feed.
-- Bidirectional checks are not enforced by default; the app just filters the feed.
CREATE TABLE user_blocks (
	blocker_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	blocked_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
	PRIMARY KEY (blocker_id, blocked_id)
);
CREATE INDEX user_blocks_blocker_idx ON user_blocks (blocker_id);

-- Content reports: any member can flag a post or comment for the admin to review.
CREATE TABLE content_reports (
	id BIGSERIAL PRIMARY KEY,
	reporter_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	post_id BIGINT REFERENCES posts(id) ON DELETE CASCADE,
	comment_id BIGINT REFERENCES comments(id) ON DELETE CASCADE,
	reason TEXT NOT NULL,
	dismissed BOOLEAN NOT NULL DEFAULT FALSE,
	created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
	CONSTRAINT report_has_target CHECK (post_id IS NOT NULL OR comment_id IS NOT NULL)
);

-- Track when a user explicitly accepted the terms of service.
ALTER TABLE users ADD COLUMN terms_accepted_at TIMESTAMPTZ;
