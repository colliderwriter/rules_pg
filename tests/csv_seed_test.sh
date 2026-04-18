#!/usr/bin/env bash
# csv_seed_test.sh
#
# Verifies that CSV seed data is loaded correctly by the pg_test launcher.
# Uses tags.csv which loads into the `tags` table.

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

echo "--- csv_seed_test ---"
echo "Connecting to $PGDATABASE on $PGHOST:$PGPORT as $PGUSER"

assert_eq "tag count" "3" "$(psql -c 'SELECT COUNT(*) FROM tags;')"

# Verify the specific tag names from tags.csv were loaded.
for tag in bazel postgres testing; do
    count=$(psql -c "SELECT COUNT(*) FROM tags WHERE name='$tag';")
    assert_eq "tag '$tag' exists" "1" "$count"
done

# Verify no other tables were seeded (schema-only; no SQL seed mixed in).
assert_eq "users table empty" "0" "$(psql -c 'SELECT COUNT(*) FROM users;')"
assert_eq "posts table empty" "0" "$(psql -c 'SELECT COUNT(*) FROM posts;')"

echo "--- PASS ---"
