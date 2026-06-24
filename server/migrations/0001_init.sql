-- Initial schema for Check-In.

CREATE TABLE server_config (
    id          INT PRIMARY KEY DEFAULT 1,
    name        TEXT NOT NULL DEFAULT 'Check-In',
    initialized BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT server_config_singleton CHECK (id = 1)
);
INSERT INTO server_config (id) VALUES (1);

CREATE TABLE media (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id   BIGINT,
    path       TEXT NOT NULL,
    mime       TEXT NOT NULL,
    width      INT NOT NULL DEFAULT 0,
    height     INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone           TEXT NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    birthday        DATE NOT NULL,
    profile_media_id BIGINT REFERENCES media(id) ON DELETE SET NULL,
    password_hash   TEXT NOT NULL,
    is_admin        BOOLEAN NOT NULL DEFAULT FALSE,
    status          TEXT NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- media.owner_id references users, added after users exists.
ALTER TABLE media ADD CONSTRAINT media_owner_fk
    FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE;

-- Phone numbers (E.164) the admin has allowed to sign up. The number itself is the
-- access code: a user may register only if their number appears here and is unused.
CREATE TABLE allowed_phones (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone      TEXT NOT NULL UNIQUE,
    added_by   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    used       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX sessions_user_idx ON sessions(user_id);

CREATE TABLE posts (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    author_id  BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK (kind IN ('text', 'image')),
    body       TEXT NOT NULL DEFAULT '',
    media_id   BIGINT REFERENCES media(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX posts_created_idx ON posts(created_at DESC);
CREATE INDEX posts_author_idx ON posts(author_id, created_at DESC);

CREATE TABLE likes (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    post_id    BIGINT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (post_id, user_id)
);

CREATE TABLE comments (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    post_id    BIGINT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX comments_post_idx ON comments(post_id, created_at);
