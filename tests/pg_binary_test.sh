#!/usr/bin/env bash
# pg_binary_test.sh
#
# Verifies that the PostgreSQL binary is properly installed and accessible.
# Connects to the ephemeral cluster started by the pg_test launcher and
# exercises basic DDL + DML to confirm the server is functional.

set -euo pipefail

require_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set" >&2
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

echo "--- pg_binary_test ---"
echo "Connecting to $PGDATABASE on $PGHOST:$PGPORT as $PGUSER"

# Verify server is running and reports a version.
server_version=$(psql -c "SELECT current_setting('server_version');")
if [[ -z "$server_version" ]]; then
    echo "FAIL: could not retrieve server_version" >&2
    exit 1
fi
echo "OK: PostgreSQL is running, server_version=$server_version"

# Verify server_version_num is a positive integer (e.g. 140009, 160003).
version_num=$(psql -c "SELECT current_setting('server_version_num');")
if [[ "$version_num" -lt 140000 ]]; then
    echo "FAIL: unexpected server_version_num=$version_num (expected >= 140000)" >&2
    exit 1
fi
echo "OK: server_version_num=$version_num"

# Verify basic DDL + DML round-trip.
psql -c "CREATE TABLE _pg_check (id SERIAL PRIMARY KEY, val INT NOT NULL);"
psql -c "INSERT INTO _pg_check (val) VALUES (42), (7);"
total=$(psql -c "SELECT SUM(val) FROM _pg_check;")
if [[ "$total" != "49" ]]; then
    echo "FAIL: expected SUM=49, got $total" >&2
    exit 1
fi
echo "OK: DDL/DML round-trip (SUM=$total)"

# Verify transactions work.
psql -c "BEGIN; INSERT INTO _pg_check (val) VALUES (999); ROLLBACK;"
count_after_rollback=$(psql -c "SELECT COUNT(*) FROM _pg_check;")
if [[ "$count_after_rollback" != "2" ]]; then
    echo "FAIL: ROLLBACK did not work, expected 2 rows, got $count_after_rollback" >&2
    exit 1
fi
echo "OK: ROLLBACK works"

echo "--- PASS ---"
