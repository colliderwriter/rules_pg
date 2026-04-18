# rules_pg

Bazel rules for running PostgreSQL in tests. Provides hermetic, parallel-safe
PostgreSQL clusters for `*_test` targets with zero external dependencies at
runtime (uses the host-installed PostgreSQL; no CDN downloads required in CI).

## Repo layout

```
rules_pg/
├── MODULE.bazel              # Bzlmod module definition
├── WORKSPACE                 # Legacy workspace (compatibility shim)
├── defs.bzl                  # Public API re-exports
├── extensions.bzl            # Module extension: pg binary repos (download or system)
├── repositories.bzl          # Legacy WORKSPACE equivalents of extensions.bzl
├── private/
│   ├── binary.bzl            # postgres_binary rule + PostgresBinaryInfo provider
│   ├── schema.bzl            # postgres_schema rule + PostgresSchemaInfo provider
│   ├── seed.bzl              # pg_seed_data rule + PostgresSeedInfo provider
│   ├── test.bzl              # pg_test macro + _pg_launcher_test rule
│   └── launcher.py           # Test launcher: initdb → migrate → seed → exec → teardown
├── toolchain/
│   └── toolchain.bzl         # Toolchain type + register helpers
└── tests/
    ├── BUILD.bazel
    ├── schema/               # Example migration SQL files (001_init.sql, 002_seed.sql)
    └── seed/                 # Example seed files (seed.sql, tags.csv)
```

## Key concepts

### Providers (chain)

```
PostgresBinaryInfo
  └─ PostgresSchemaInfo   (carries a PostgresBinaryInfo)
       └─ PostgresSeedInfo  (carries a PostgresSchemaInfo)
            └─ consumed by pg_test launcher
```

### `pg_test` isolation model

Every `pg_test` target gets:
- Its own `initdb`'d cluster under `$TEST_TMPDIR/pgdata`
- A randomly assigned free TCP port (TOCTOU-safe on PG 14–17; retried on PG 18+)
- Env vars injected: `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`

No shared state between tests → full `--jobs` parallelism is safe.

### Port allocation

The launcher uses Python's `socket.bind(('127.0.0.1', 0))` to get a free port.
On PostgreSQL 14–17 it passes the open socket fd directly to `pg_ctl` via
`--socket-fd`, eliminating the TOCTOU race. PostgreSQL 18 removed `--socket-fd`,
so on PG 18+ the socket is closed just before `pg_ctl` starts; up to 5 retries
handle the rare race.

Retries are only attempted on TCP port-binding conflicts (detected by scanning
the server log for "Address already in use"). Any other fatal error (config
problem, missing file, permission error) causes immediate failure with the
full server log printed.

Unix-domain sockets are disabled (`unix_socket_directories = ''`). Bazel
sandboxes mount `/var/run/postgresql` read-only, and the sandbox path is too
long for the 107-byte Unix socket path limit. All connections use TCP via
`PGHOST=127.0.0.1`.

### Binary source (distribution-independent)

`extensions.bzl` (Bzlmod) and `repositories.bzl` (WORKSPACE) both support two
modes, selected per version:

| Tag / function         | Behavior                                               |
|------------------------|--------------------------------------------------------|
| `pg.version()`         | Downloads a pre-built tarball from the EnterpriseDB CDN |
| `pg.system()`          | Symlinks the host-installed PostgreSQL binaries        |
| `pg_system_dependencies()` | WORKSPACE equivalent of `pg.system()`            |

**Auto-detection** — when `bin_dir` and `lib_dir` are omitted (the default),
the repository rule resolves them automatically:

1. `bin_dir`: runs `command -v pg_ctl`; falls back to probing
   `/usr/bin`, `/usr/local/bin`, `/usr/local/pgsql/bin`, `/opt/homebrew/bin`.
2. `lib_dir`: queries `pg_config --libdir`; falls back to searching
   `/usr/lib64`, `/usr/lib`, `/usr/local/lib`, and Debian/Ubuntu multiarch paths
   for `libpq.so*`.

If `pg_ctl` cannot be found, the build fails immediately with a clear error
message pointing to the missing binary and suggested install commands.

Platforms supported for downloaded tarballs: `linux_amd64`, `darwin_arm64`,
`darwin_amd64`.

## Supported PostgreSQL versions

- 14 (default)
- 15
- 16

The launcher detects the actual installed binary version at runtime via
`pg_ctl --version`, so it works correctly even when the host has a different
PostgreSQL version than what was declared in `postgres_version =`.

## Public API

```python
load("@rules_pg//defs.bzl", "pg_test", "postgres_schema", "pg_seed_data")

postgres_schema(
    name = "my_schema",
    srcs = glob(["migrations/*.sql"]),
    # Files are applied in the order listed. Use numeric prefixes: 001_init.sql
)

pg_seed_data(
    name = "my_seed",
    schema = ":my_schema",
    srcs = ["seed.sql"],          # .sql or .csv files; mixed lists are fine
)

pg_test(
    name = "my_test",
    srcs = ["my_test.go"],
    schema = ":my_schema",          # required
    seed = ":my_seed",              # optional
    postgres_version = "16",        # optional, default "14"
    database = "testdb",            # optional, default "test"
    pg_user = "postgres",           # optional
    pg_password = "postgres",       # optional
    test_rule = go_test,            # optional; default native.sh_test
    deps = [...],
)
```

### MODULE.bazel (Bzlmod)

```python
bazel_dep(name = "rules_pg", version = "0.1.0")

pg = use_extension("@rules_pg//:extensions.bzl", "pg")

# Use the host-installed PostgreSQL (auto-detects bin_dir and lib_dir):
pg.system(versions = ["14", "15", "16"])

# Or specify paths explicitly when auto-detection is unavailable:
# pg.system(versions = ["16"], bin_dir = "/usr/pgsql-16/bin", lib_dir = "/usr/pgsql-16/lib")

# Or download pre-built tarballs (requires CDN access + real SHA-256 sums):
# pg.version(versions = ["14"])

use_repo(pg, "pg_14_linux_amd64", "pg_14_darwin_arm64", "pg_14_darwin_amd64")
```

### WORKSPACE (legacy)

```python
load("@rules_pg//:repositories.bzl", "pg_system_dependencies")

# Auto-detect; or pass bin_dir/lib_dir for explicit paths:
pg_system_dependencies(versions = ["14", "15", "16"])
```

## Development

### Running the self-tests

```sh
bazel test //tests/...
```

### Test results (last full run: 2026-04-18)

All 8 tests passed in ~8 s on Linux x86_64 with PostgreSQL 18.3 system install.

| Test target                  | What it verifies                                        | Result |
|------------------------------|---------------------------------------------------------|--------|
| `//tests:schema_smoke_test`  | Schema migrations applied; DDL/DML round-trip           | PASSED |
| `//tests:seed_smoke_test`    | SQL seed data loaded; referential integrity join        | PASSED |
| `//tests:pg14_smoke_test`    | pg_test macro with `postgres_version = "14"`            | PASSED |
| `//tests:pg15_smoke_test`    | pg_test macro with `postgres_version = "15"`            | PASSED |
| `//tests:pg16_smoke_test`    | pg_test macro with `postgres_version = "16"`            | PASSED |
| `//tests:pg_binary_test`     | PG binary present, version ≥ 14, DDL/DML, ROLLBACK     | PASSED |
| `//tests:csv_seed_test`      | CSV seed loading via `\copy`; exact row counts          | PASSED |
| `//tests:custom_db_test`     | Custom `database =` and `pg_user =` attributes          | PASSED |

### Adding a new Postgres version

1. Find the tarball URLs and sha256 sums for `linux_amd64`, `darwin_arm64`, `darwin_amd64`.
2. Add entries to the `_PG_VERSIONS` dict in both `extensions.bzl` and `repositories.bzl`.
3. Add a smoke test target in `tests/BUILD.bazel` with `postgres_version = "<new>"`.
4. Run `bazel test //tests/...`.

### Launcher script

`private/launcher.py` is the heart of `pg_test`. It:

1. Reads the JSON manifest written by the Bazel rule (`RULES_PG_MANIFEST`).
2. Resolves all runfile paths (external repos use `../repo/path`; workspace files use `<workspace>/path`).
3. Ensures all PostgreSQL binaries have the execute bit set.
4. Detects the actual binary version via `pg_ctl --version` (needed for `--socket-fd` gating).
5. Creates `$TEST_TMPDIR/pgdata` (mode 0700) and runs `initdb --auth=scram-sha-256`.
6. Writes ephemeral `postgresql.conf` overrides: port, `fsync=off`, `logging_collector=off`, `unix_socket_directories=''`.
7. Starts `pg_ctl`, passing `--socket-fd` on PG 14–17 (eliminated in PG 18).
8. Polls `pg_isready` until the server accepts connections (max 15 s).
9. Retries startup on port conflicts only; fails immediately on all other errors.
10. Creates the test database, applies migrations in order, loads seed data.
11. `os.execve`s the wrapped test binary with `PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD` set.
12. `atexit` handler runs `pg_ctl stop -m fast` on exit.

### Test script requirements

All test shell scripts must:
- Begin with `set -euo pipefail`.
- Use a `require_env VAR` guard for every `PG*` variable before first use.
- Use `command psql` (not bare `psql`) to avoid alias expansion.
- Pass `-v ON_ERROR_STOP=1` so SQL errors terminate the script immediately.

### Style

- All `.bzl` files use 4-space indentation.
- Provider fields are documented with inline comments.
- Public rules/macros have docstrings.
- `private/` contains implementation details; only `defs.bzl` is the stable API.

## Known limitations

- Windows is not supported (no pre-built binary source; PRs welcome).
- `pg_test` adds ~0.5–1 s overhead per test for `initdb`. For very large test
  suites, consider a shared-server mode (not yet implemented).
- Schema migration ordering relies on the caller listing files explicitly or
  using `glob()` with numeric prefixes. There is no automatic dependency solver.
- Downloaded tarball SHA-256 checksums in `extensions.bzl`/`repositories.bzl`
  are placeholder values. Run `tools/update_checksums.sh` (not yet implemented)
  to pin real values before enabling `pg.version()`.
