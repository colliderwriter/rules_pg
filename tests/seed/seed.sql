-- seed.sql: test fixture data

INSERT INTO users (email) VALUES
    ('alice@example.com'),
    ('bob@example.com');

INSERT INTO tags (name) VALUES
    ('bazel'),
    ('postgres'),
    ('testing');

INSERT INTO posts (user_id, title, body) VALUES
    (1, 'Hello Bazel', 'Bazel is great for hermetic builds.'),
    (2, 'Hello Postgres', 'Postgres is a solid relational database.');

INSERT INTO post_tags (post_id, tag_id) VALUES
    (1, 1),  -- Hello Bazel  / bazel
    (2, 2),  -- Hello Postgres / postgres
    (1, 3),  -- Hello Bazel  / testing
    (2, 3);  -- Hello Postgres / testing
