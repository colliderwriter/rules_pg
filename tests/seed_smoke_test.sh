#!/usr/bin/env bash
# seed_smoke_test.sh
#
# Verifies that seed data was loaded correctly by the pg_test launcher.

set -euo pipefail

require_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: required environment variable \$${var} is not set" >&2
        echo "       This script must be run via 'bazel test', not directly." >&2
        exit 1
    fi
}
require_env PGHOST
require_env PGPORT
require_env PGDATABASE
require_env PGUSER
require_env PGPASSWORD

psql() {
    PGPASSWORD="$PGPASSWORD" command psql \
        -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        --no-password -v ON_ERROR_STOP=1 -t -A "$@"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $label — expected '$expected', got '$actual'" >&2
        exit 1
    fi
    echo "OK: $label = $actual"
}

echo "--- seed_smoke_test ---"
echo "Connecting to $PGDATABASE on $PGHOST:$PGPORT as $PGUSER"

assert_eq "user count"     "2" "$(psql -c 'SELECT COUNT(*) FROM users;')"
assert_eq "post count"     "2" "$(psql -c 'SELECT COUNT(*) FROM posts;')"
assert_eq "tag count"      "3" "$(psql -c 'SELECT COUNT(*) FROM tags;')"
assert_eq "post_tag count" "4" "$(psql -c 'SELECT COUNT(*) FROM post_tags;')"

# Verify referential integrity: join across all tables
joined=$(psql -c "
    SELECT COUNT(*)
    FROM posts p
    JOIN users u ON u.id = p.user_id
    JOIN post_tags pt ON pt.post_id = p.id
    JOIN tags t ON t.id = pt.tag_id
    WHERE t.name = 'testing';
")
assert_eq "posts tagged 'testing'" "2" "$joined"

# Verify alice owns post 1
owner=$(psql -c "
    SELECT u.email FROM posts p JOIN users u ON u.id = p.user_id
    WHERE p.title = 'Hello Bazel';
")
assert_eq "Hello Bazel owner" "alice@example.com" "$owner"

echo "--- PASS ---"
