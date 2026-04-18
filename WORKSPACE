workspace(name = "rules_pg")

# This file exists for compatibility with projects that have not migrated to
# Bzlmod (MODULE.bazel). Bzlmod users should ignore this file entirely.
#
# Legacy WORKSPACE usage:
#
#   load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
#
#   http_archive(
#       name = "rules_pg",
#       urls = ["https://github.com/example/rules_pg/archive/v0.1.0.tar.gz"],
#       sha256 = "...",
#       strip_prefix = "rules_pg-0.1.0",
#   )
#
#   load("@rules_pg//:repositories.bzl", "rules_pg_dependencies")
#   rules_pg_dependencies()
#
#   load("@rules_pg//:repositories.bzl", "rules_pg_register_toolchains")
#   rules_pg_register_toolchains()

load("//:repositories.bzl", "pg_system_dependencies", "rules_pg_register_toolchains")

# Use system-installed PostgreSQL instead of downloading from the CDN.
# Switch back to rules_pg_dependencies() once real SHA-256 checksums are
# pinned in repositories.bzl and the EnterpriseDB CDN is reachable.
pg_system_dependencies(
    versions = ["14", "15", "16"],
    # bin_dir and lib_dir are auto-detected via pg_config / PATH if omitted.
)
# rules_pg_register_toolchains() omitted: toolchain targets in
# //toolchain/BUILD.bazel are not yet declared; the pg_test macro
# uses postgres_binary directly and does not require toolchain resolution.
