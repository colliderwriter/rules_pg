# rules_pg

Bazel rules for running PostgreSQL in tests. Provides hermetic, parallel-safe
PostgreSQL clusters for `*_test` targets with zero external dependencies.

## Repo layout

```
rules_pg/
├── MODULE.bazel              # Bzlmod module definition
├── WORKSPACE                 # Legacy workspace (compatibility shim)
├── defs.bzl                  # Public API re-exports
├── extensions.bzl            # Module extension: downloads pg binaries
├── private/
│   ├── binary.bzl            # postgres_binary rule + PostgresBinaryInfo provider
│   ├── schema.bzl            # postgres_schema rule + PostgresSchemaInfo provider
│   ├── seed.bzl              # pg_seed_data rule + PostgresSeedInfo provider
│   ├── test.bzl              # pg_test macro
│   └── launcher.py           # Test launcher: initdb → migrate → seed → exec → teardown
├── toolchain/
│   └── toolchain.bzl         # Toolchain type + register helpers
└── tests/
    ├── BUILD.bazel
    ├── schema/               # Example migration SQL files
    └── seed/                 # Example seed SQL/CSV files
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
- A randomly assigned port via Postgres `--socket-fd` (PG ≥ 14) or `:0`-then-retry fallback
- Env vars injected: `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`

No shared state between tests → full `--jobs` parallelism is safe.

### Port allocation

The launcher uses Python's `socket.bind(('', 0))` to get a free port, then passes
the open fd directly to `pg_ctl` via `--socket-fd` (PG ≥ 14) to eliminate the
TOCTOU race window. For PG < 14 it falls back to close-then-retry with up to
5 attempts.

### Binary fetching

`extensions.bzl` downloads pre-built tarballs for each supported platform:
- `linux_amd64`
- `darwin_arm64`
- `darwin_amd64`

Checksums are pinned in `extensions.bzl`. Run `tools/update_checksums.sh` to
regenerate them against a new PG version.

## Supported PostgreSQL versions

- 14 (default)
- 15
- 16

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
    srcs = ["seed.sql"],
)

pg_test(
    name = "my_test",
    srcs = ["my_test.go"],
    schema = ":my_schema",          # required
    seed = ":my_seed",              # optional
    postgres_version = "16",        # optional, default "14"
    database = "testdb",            # optional, default "test"
    deps = [...],
)
```

## Development

### Running the self-tests

```sh
bazel test //tests/...
```

### Adding a new Postgres version

1. Find the tarball URLs and sha256 sums for linux_amd64, darwin_arm64, darwin_amd64.
2. Add entries to the `_PG_VERSIONS` dict in `extensions.bzl`.
3. Run `bazel test //tests/...` with `--test_env=PG_VERSION=<new>`.

### Launcher script

`private/launcher.py` is the heart of `pg_test`. It:
1. Creates `$TEST_TMPDIR/pgdata`
2. Runs `initdb -U postgres -D $PGDATA --no-locale --encoding=UTF8`
3. Binds a free TCP port, starts `pg_ctl` with `--socket-fd` (PG ≥ 14)
4. Polls `pg_isready` until the server accepts connections (max 10s)
5. Creates the test database and user
6. Applies schema migrations in order via `psql`
7. Applies seed data (if any) via `psql` / `\copy`
8. `os.execve`s the wrapped test binary with `PG*` env vars set
9. `atexit` handler runs `pg_ctl stop -m fast` on exit

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
