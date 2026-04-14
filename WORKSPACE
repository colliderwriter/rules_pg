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

load("//:repositories.bzl", "rules_pg_dependencies", "rules_pg_register_toolchains")

rules_pg_dependencies()
rules_pg_register_toolchains()
