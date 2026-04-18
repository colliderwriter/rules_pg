#!/usr/bin/env python3
"""
rules_pg test launcher.

Reads RULES_PG_MANIFEST (JSON), spins up an ephemeral Postgres cluster,
applies migrations + seed data, then exec's the test binary with PG* env vars.

Never imported; always exec'd by the wrapper shell script.
"""

import atexit
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _log(msg: str) -> None:
    print(f"[rules_pg] {msg}", file=sys.stderr, flush=True)


def _find_runfile(rel_path: str, workspace: str = "") -> str:
    """Resolve a runfile path relative to the runfiles root.

    Bazel uses two conventions for File.short_path:
      - External repo:  "../repo_name/path"  →  "<root>/repo_name/path"
      - Main workspace: "path/to/file"       →  "<root>/<workspace>/path/to/file"

    We try several candidates in order.
    """
    runfiles_dir = os.environ.get("RUNFILES_DIR") or (sys.argv[0] + ".runfiles")

    # Build candidate list.
    candidates = []
    if rel_path.startswith("../"):
        # External repo: strip "../" and look directly under the runfiles root.
        candidates.append(os.path.join(runfiles_dir, rel_path[3:]))
    else:
        # Workspace-local file: lives under <root>/<workspace>/<path>.
        if workspace:
            candidates.append(os.path.join(runfiles_dir, workspace, rel_path))
        # Fallback without workspace prefix (e.g. when running outside sandbox).
        candidates.append(os.path.join(runfiles_dir, rel_path))

    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate

    # Last resort: RUNFILES_MANIFEST_FILE (used in some execution modes).
    manifest_file = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_file and os.path.exists(manifest_file):
        with open(manifest_file) as f:
            for line in f:
                key, _, val = line.strip().partition(" ")
                if key == rel_path or (rel_path.startswith("../") and key == rel_path[3:]):
                    return val

    raise FileNotFoundError(f"Runfile not found: {rel_path} (tried: {candidates})")


def _allocate_port() -> tuple[int, socket.socket | None]:
    """
    Return (port, sock_or_None).

    On Python ≥ 3.9 and PG ≥ 14 we keep the socket open so the caller can
    pass --socket-fd to pg_ctl, eliminating the TOCTOU race.  On older
    combinations we close immediately and accept the (small) race.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    return port, s


def _is_port_conflict(log_path: str) -> bool:
    """Return True if the Postgres log shows a TCP port binding failure."""
    if not os.path.exists(log_path):
        return False
    try:
        with open(log_path) as f:
            content = f.read()
    except OSError:
        return False
    return "Address already in use" in content or "could not bind" in content


def _wait_ready(pg_isready: str, host: str, port: int, timeout: float = 15.0,
                lib_dir: str = "") -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            [pg_isready, "-h", host, "-p", str(port), "-q"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=_pg_env(lib_dir),
        )
        if result.returncode == 0:
            return
        time.sleep(0.2)
    raise TimeoutError(f"Postgres did not become ready within {timeout}s on port {port}")


def _pg_major_version(pg_ctl_bin: str, lib_dir: str = "") -> int:
    """Return the PostgreSQL major version by querying pg_ctl --version.

    Output is like "pg_ctl (PostgreSQL) 18.3"; we return 18.
    """
    result = subprocess.run(
        [pg_ctl_bin, "--version"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=_pg_env(lib_dir),
    )
    out = result.stdout.decode("utf-8", errors="replace").strip()
    for token in out.split():
        if token and token[0].isdigit():
            try:
                return int(token.split(".")[0])
            except ValueError:
                pass
    return 0


def _ensure_executable(path: str) -> None:
    """Ensure a file has the execute bit set for the owner."""
    st = os.stat(path)
    if not (st.st_mode & 0o100):
        os.chmod(path, st.st_mode | 0o111)


def _pg_env(lib_dir: str) -> dict:
    """
    Return a copy of os.environ with the PostgreSQL bundled lib dir prepended
    to the dynamic-linker search path so binaries find their shared libraries.
    """
    env = os.environ.copy()
    if not lib_dir or not os.path.isdir(lib_dir):
        return env
    if platform.system() == "Darwin":
        key = "DYLD_LIBRARY_PATH"
    else:
        key = "LD_LIBRARY_PATH"
    existing = env.get(key, "")
    env[key] = lib_dir + (":" + existing if existing else "")
    return env


def _psql(psql_bin: str, host: str, port: int, user: str, database: str,
          password: str, sql: str | None = None, file: str | None = None,
          lib_dir: str = "") -> None:
    env = _pg_env(lib_dir)
    env["PGPASSWORD"] = password
    cmd = [
        psql_bin,
        "-h", host,
        "-p", str(port),
        "-U", user,
        "-d", database,
        "--no-password",
        "-v", "ON_ERROR_STOP=1",
    ]
    if file:
        cmd += ["-f", file]
    elif sql:
        cmd += ["-c", sql]
    else:
        raise ValueError("Either sql= or file= must be provided")
    subprocess.run(cmd, check=True, env=env)


def _copy_csv(psql_bin: str, host: str, port: int, user: str, database: str,
              password: str, csv_path: str, lib_dir: str = "") -> None:
    table = os.path.splitext(os.path.basename(csv_path))[0]
    # Use \copy (client-side) so the file path is local to the test runner.
    sql = rf"\copy {table} FROM '{csv_path}' CSV HEADER"
    _psql(psql_bin, host, port, user, database, password, sql=sql, lib_dir=lib_dir)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    # -- Read manifest -------------------------------------------------------
    manifest_path = os.environ.get("RULES_PG_MANIFEST")
    if not manifest_path:
        sys.exit("[rules_pg] RULES_PG_MANIFEST not set")
    with open(manifest_path) as f:
        m = json.load(f)

    workspace   = m.get("workspace", "")
    pg_ctl      = _find_runfile(m["pgctl"], workspace)
    initdb_bin  = _find_runfile(m["initdb"], workspace)
    psql_bin    = _find_runfile(m["psql"], workspace)
    pg_isready  = _find_runfile(m["pg_isready"], workspace)
    pg_version  = int(m.get("pg_version", "14"))
    migrations  = [_find_runfile(p, workspace) for p in m.get("migrations", [])]
    seed_files  = [_find_runfile(p, workspace) for p in m.get("seed_files", [])]
    database    = m.get("database", "test")
    pg_user     = m.get("pg_user", "postgres")
    pg_password = m.get("pg_password", "postgres")

    # Derive the bundled lib/ directory from the pg_ctl path so shared
    # libraries (libpq, etc.) are found without a system-wide install.
    pg_lib_dir = os.path.join(os.path.dirname(os.path.dirname(pg_ctl)), "lib")

    # Ensure all PostgreSQL binaries are executable.  Zip-based archives
    # (macOS) don't always preserve execute bits; tar.gz usually does, but
    # this is a cheap safety net.
    for bin_path in (pg_ctl, initdb_bin, psql_bin, pg_isready):
        _ensure_executable(bin_path)

    # Detect the actual binary version at runtime.  --socket-fd was added in
    # PG 14 and removed in PG 18, so we must check the real binary rather than
    # trusting the manifest's declared version (which reflects the *requested*
    # version, not the binary that happens to be installed on this host).
    actual_pg_version = _pg_major_version(pg_ctl, pg_lib_dir)
    if actual_pg_version == 0:
        # Fall back to the manifest-declared version if detection fails.
        actual_pg_version = pg_version
    _log(f"Detected PostgreSQL binary version: {actual_pg_version}")

    # -- Workspace -----------------------------------------------------------
    test_tmpdir = os.environ.get("TEST_TMPDIR") or tempfile.mkdtemp(prefix="rules_pg_")
    pgdata = os.path.join(test_tmpdir, "pgdata")
    pg_log = os.path.join(test_tmpdir, "pg.log")
    os.makedirs(pgdata, exist_ok=True)
    # initdb requires the data directory to be mode 0700 (not world-readable).
    # os.makedirs() respects the process umask, so we set the mode explicitly.
    os.chmod(pgdata, 0o700)

    # -- Port allocation -----------------------------------------------------
    host = "127.0.0.1"
    port, reserved_sock = _allocate_port()
    # --socket-fd is supported in PG 14–17; it was removed in PG 18.
    use_socket_fd = 14 <= actual_pg_version <= 17 and reserved_sock is not None

    # -- initdb --------------------------------------------------------------
    _log(f"Running initdb in {pgdata}")
    subprocess.run(
        [
            initdb_bin,
            "-D", pgdata,
            "-U", pg_user,
            "--no-locale",
            "--encoding=UTF8",
            "--auth=scram-sha-256",
            "--pwfile=/dev/stdin",
        ],
        input=pg_password.encode(),
        check=True,
        stdout=subprocess.DEVNULL,
        env=_pg_env(pg_lib_dir),
    )

    # Tune postgresql.conf for a fast ephemeral server.
    conf_path = os.path.join(pgdata, "postgresql.conf")
    with open(conf_path, "a") as cf:
        cf.write("\n# rules_pg ephemeral overrides\n")
        cf.write(f"listen_addresses = '127.0.0.1'\n")
        cf.write(f"port = {port}\n")
        cf.write("fsync = off\n")
        cf.write("synchronous_commit = off\n")
        cf.write("full_page_writes = off\n")
        cf.write("log_min_messages = WARNING\n")
        cf.write("log_min_error_statement = ERROR\n")
        # Force all output to stderr so pg_ctl's -l file captures it.
        # PostgreSQL ≥ 15 defaults logging_collector to on, which redirects
        # logs to pgdata/log/ and makes our -l file nearly empty.
        cf.write("logging_collector = off\n")
        cf.write("log_destination = 'stderr'\n")
        # Disable Unix-domain socket creation.  The Bazel sandbox mounts
        # /var/run/postgresql read-only, and the sandbox path is too deep for
        # the 107-byte socket-path limit anyway.  We connect exclusively via
        # TCP (PGHOST=127.0.0.1), so Unix sockets are not needed.
        cf.write("unix_socket_directories = ''\n")

    # -- Start server --------------------------------------------------------
    start_cmd = [pg_ctl, "start", "-D", pgdata, "-l", pg_log, "-w"]
    if use_socket_fd:
        # Pass the already-bound fd to eliminate TOCTOU.
        start_cmd += ["-o", f"--socket-fd={reserved_sock.fileno()}"]

    proc = None

    def _stop_server() -> None:
        _log("Stopping Postgres …")
        subprocess.run(
            [pg_ctl, "stop", "-D", pgdata, "-m", "fast", "-w"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    atexit.register(_stop_server)

    max_attempts = 5
    for attempt in range(1, max_attempts + 1):
        try:
            _log(f"Starting Postgres on 127.0.0.1:{port} (attempt {attempt})")
            pg_run_env = _pg_env(pg_lib_dir)
            if use_socket_fd:
                subprocess.run(start_cmd, check=True, pass_fds=(reserved_sock.fileno(),),
                               stdout=subprocess.DEVNULL, env=pg_run_env)
                reserved_sock.close()
            else:
                # Close the reserved socket just before starting so Postgres
                # can bind the same port (small race, retried on failure).
                if reserved_sock:
                    reserved_sock.close()
                subprocess.run(start_cmd, check=True, stdout=subprocess.DEVNULL,
                               env=pg_run_env)

            _wait_ready(pg_isready, host, port, lib_dir=pg_lib_dir)
            _log("Postgres ready.")
            break
        except (subprocess.CalledProcessError, TimeoutError) as exc:
            _log(f"Attempt {attempt} failed: {exc}")
            # Dump the log for diagnosis.
            log_content = ""
            if os.path.exists(pg_log):
                with open(pg_log) as lf:
                    log_content = lf.read()

            if attempt == max_attempts:
                if log_content:
                    _log("Server log:\n" + log_content)
                sys.exit(1)

            # Only retry for TCP port-binding conflicts — all other errors
            # (config errors, permission problems, missing files) are fatal.
            if log_content and not _is_port_conflict(pg_log):
                _log("Non-retriable error detected. Server log:\n" + log_content)
                sys.exit(1)

            # Re-allocate port and retry.
            port, reserved_sock = _allocate_port()
            use_socket_fd = 14 <= actual_pg_version <= 17 and reserved_sock is not None
            # Update postgresql.conf with new port.
            with open(conf_path, "a") as cf:
                cf.write(f"port = {port}\n")  # last value wins in PG config

    # -- Create database and user --------------------------------------------
    _log(f"Creating database '{database}'")
    _psql(psql_bin, host, port, pg_user, "postgres", pg_password,
          sql=f"CREATE DATABASE \"{database}\";", lib_dir=pg_lib_dir)

    # -- Apply migrations ----------------------------------------------------
    for migration in migrations:
        _log(f"Applying migration: {os.path.basename(migration)}")
        _psql(psql_bin, host, port, pg_user, database, pg_password,
              file=migration, lib_dir=pg_lib_dir)

    # -- Load seed data ------------------------------------------------------
    for seed_file in seed_files:
        ext = os.path.splitext(seed_file)[1].lower()
        _log(f"Loading seed: {os.path.basename(seed_file)}")
        if ext == ".sql":
            _psql(psql_bin, host, port, pg_user, database, pg_password,
                  file=seed_file, lib_dir=pg_lib_dir)
        elif ext == ".csv":
            _copy_csv(psql_bin, host, port, pg_user, database, pg_password,
                      seed_file, lib_dir=pg_lib_dir)
        else:
            _log(f"Warning: unknown seed file type '{ext}', skipping.")

    # -- Exec test binary ----------------------------------------------------
    test_binary = os.environ.get("RULES_PG_TEST_BINARY")
    if not test_binary:
        sys.exit("[rules_pg] RULES_PG_TEST_BINARY not set")
    test_binary = _find_runfile(test_binary, workspace) if not os.path.isabs(test_binary) else test_binary

    env = _pg_env(pg_lib_dir)
    env["PGHOST"]     = host
    env["PGPORT"]     = str(port)
    env["PGDATABASE"] = database
    env["PGUSER"]     = pg_user
    env["PGPASSWORD"] = pg_password

    _log(f"Executing test binary: {test_binary}")
    os.execve(test_binary, [test_binary] + sys.argv[1:], env)
    # atexit teardown runs after the child exits (because execve replaces us,
    # so teardown runs in the *parent* — the wrapper shell — via the atexit
    # registered above, which Python fires before the final exit).


if __name__ == "__main__":
    main()
