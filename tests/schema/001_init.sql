-- 001_init.sql: baseline schema

CREATE TABLE users (
    id         BIGSERIAL PRIMARY KEY,
    email      TEXT      NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE posts (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title      TEXT      NOT NULL,
    body       TEXT      NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX posts_user_id_idx ON posts (user_id);
