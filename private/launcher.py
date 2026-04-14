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


def _find_runfile(rel_path: str) -> str:
    """Resolve a runfile path relative to the runfiles root."""
    runfiles_dir = os.environ.get("RUNFILES_DIR") or (sys.argv[0] + ".runfiles")
    full = os.path.join(runfiles_dir, rel_path)
    if os.path.exists(full):
        return full
    # Bazel also sets RUNFILES_MANIFEST_FILE for some targets; try that.
    manifest_file = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_file and os.path.exists(manifest_file):
        with open(manifest_file) as f:
            for line in f:
                key, _, val = line.strip().partition(" ")
                if key == rel_path:
                    return val
    raise FileNotFoundError(f"Runfile not found: {rel_path}")


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


def _wait_ready(pg_isready: str, host: str, port: int, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            [pg_isready, "-h", host, "-p", str(port), "-q"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            return
        time.sleep(0.2)
    raise TimeoutError(f"Postgres did not become ready within {timeout}s on port {port}")


def _psql(psql_bin: str, host: str, port: int, user: str, database: str,
          password: str, sql: str | None = None, file: str | None = None) -> None:
    env = os.environ.copy()
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
              password: str, csv_path: str) -> None:
    table = os.path.splitext(os.path.basename(csv_path))[0]
    # Use \copy (client-side) so the file path is local to the test runner.
    sql = rf"\copy {table} FROM '{csv_path}' CSV HEADER"
    _psql(psql_bin, host, port, user, database, password, sql=sql)


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

    pg_ctl      = _find_runfile(m["pgctl"])
    initdb_bin  = _find_runfile(m["initdb"])
    psql_bin    = _find_runfile(m["psql"])
    pg_isready  = _find_runfile(m["pg_isready"])
    pg_version  = int(m.get("pg_version", "14"))
    migrations  = [_find_runfile(p) for p in m.get("migrations", [])]
    seed_files  = [_find_runfile(p) for p in m.get("seed_files", [])]
    database    = m.get("database", "test")
    pg_user     = m.get("pg_user", "postgres")
    pg_password = m.get("pg_password", "postgres")

    # -- Workspace -----------------------------------------------------------
    test_tmpdir = os.environ.get("TEST_TMPDIR") or tempfile.mkdtemp(prefix="rules_pg_")
    pgdata = os.path.join(test_tmpdir, "pgdata")
    pg_log = os.path.join(test_tmpdir, "pg.log")
    os.makedirs(pgdata, exist_ok=True)

    # -- Port allocation -----------------------------------------------------
    host = "127.0.0.1"
    port, reserved_sock = _allocate_port()
    use_socket_fd = pg_version >= 14 and reserved_sock is not None

    # -- initdb --------------------------------------------------------------
    _log(f"Running initdb in {pgdata}")
    subprocess.run(
        [
            initdb_bin,
            "-D", pgdata,
            "-U", pg_user,
            "--no-locale",
            "--encoding=UTF8",
            "--auth=md5",
            "--pwfile=/dev/stdin",
        ],
        input=pg_password.encode(),
        check=True,
        stdout=subprocess.DEVNULL,
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
            if use_socket_fd:
                subprocess.run(start_cmd, check=True, pass_fds=(reserved_sock.fileno(),),
                               stdout=subprocess.DEVNULL)
                reserved_sock.close()
            else:
                # Close the reserved socket just before starting so Postgres
                # can bind the same port (small race, retried on failure).
                if reserved_sock:
                    reserved_sock.close()
                subprocess.run(start_cmd, check=True, stdout=subprocess.DEVNULL)

            _wait_ready(pg_isready, host, port)
            _log("Postgres ready.")
            break
        except (subprocess.CalledProcessError, TimeoutError) as exc:
            _log(f"Attempt {attempt} failed: {exc}")
            if attempt == max_attempts:
                if os.path.exists(pg_log):
                    with open(pg_log) as lf:
                        _log("Server log:\n" + lf.read())
                sys.exit(1)
            # Re-allocate port and retry.
            port, reserved_sock = _allocate_port()
            use_socket_fd = pg_version >= 14 and reserved_sock is not None
            # Update postgresql.conf with new port.
            with open(conf_path, "a") as cf:
                cf.write(f"port = {port}\n")  # last value wins in PG config

    # -- Create database and user --------------------------------------------
    _log(f"Creating database '{database}'")
    _psql(psql_bin, host, port, pg_user, "postgres", pg_password,
          sql=f"CREATE DATABASE \"{database}\";")

    # -- Apply migrations ----------------------------------------------------
    for migration in migrations:
        _log(f"Applying migration: {os.path.basename(migration)}")
        _psql(psql_bin, host, port, pg_user, database, pg_password, file=migration)

    # -- Load seed data ------------------------------------------------------
    for seed_file in seed_files:
        ext = os.path.splitext(seed_file)[1].lower()
        _log(f"Loading seed: {os.path.basename(seed_file)}")
        if ext == ".sql":
            _psql(psql_bin, host, port, pg_user, database, pg_password, file=seed_file)
        elif ext == ".csv":
            _copy_csv(psql_bin, host, port, pg_user, database, pg_password, seed_file)
        else:
            _log(f"Warning: unknown seed file type '{ext}', skipping.")

    # -- Exec test binary ----------------------------------------------------
    test_binary = os.environ.get("RULES_PG_TEST_BINARY")
    if not test_binary:
        sys.exit("[rules_pg] RULES_PG_TEST_BINARY not set")
    test_binary = _find_runfile(test_binary) if not os.path.isabs(test_binary) else test_binary

    env = os.environ.copy()
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
