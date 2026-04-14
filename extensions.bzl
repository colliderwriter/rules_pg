"Module extension: downloads pre-built PostgreSQL tarballs for each platform/version."

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# ---------------------------------------------------------------------------
# Version manifest
#
# Each entry maps (version, platform) -> (url, sha256, strip_prefix).
# Tarballs are the "binaries-only" distributions from the Postgres project or
# from https://github.com/theory/pgenv.  Update these when cutting a new
# supported version.
#
# URL scheme: PostgreSQL binary distributions for Linux come from the
# EnterpriseDB "pg_binaries" builds; macOS from Postgres.app releases.
# Both ship pg_ctl, initdb, psql, pg_isready and the shared libraries needed
# to run a server without a full OS-level install.
# ---------------------------------------------------------------------------

_PG_VERSIONS = {
    "14": {
        "linux_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-14.11-1-linux-x64-binaries.tar.gz",
            sha256 = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            strip_prefix = "pgsql",
        ),
        "darwin_arm64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-14.11-1-osx-binaries.zip",
            sha256 = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
            strip_prefix = "pgsql",
        ),
        "darwin_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-14.11-1-osx-binaries.zip",
            sha256 = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
            strip_prefix = "pgsql",
        ),
    },
    "15": {
        "linux_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-15.6-1-linux-x64-binaries.tar.gz",
            sha256 = "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
            strip_prefix = "pgsql",
        ),
        "darwin_arm64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-15.6-1-osx-binaries.zip",
            sha256 = "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5",
            strip_prefix = "pgsql",
        ),
        "darwin_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-15.6-1-osx-binaries.zip",
            sha256 = "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5",
            strip_prefix = "pgsql",
        ),
    },
    "16": {
        "linux_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-16.2-1-linux-x64-binaries.tar.gz",
            sha256 = "e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6",
            strip_prefix = "pgsql",
        ),
        "darwin_arm64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-16.2-1-osx-binaries.zip",
            sha256 = "f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1",
            strip_prefix = "pgsql",
        ),
        "darwin_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-16.2-1-osx-binaries.zip",
            sha256 = "f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1",
            strip_prefix = "pgsql",
        ),
    },
}

_PLATFORMS = ["linux_amd64", "darwin_arm64", "darwin_amd64"]

# ---------------------------------------------------------------------------
# BUILD template injected into each downloaded repo
# ---------------------------------------------------------------------------

_BUILD_TMPL = """
load("@rules_pg//private:binary.bzl", "postgres_binary_files")

postgres_binary_files(
    name = "pg_bins",
    version = "{version}",
    visibility = ["//visibility:public"],
)

# Also expose raw filegroups for advanced users.
filegroup(
    name = "all_files",
    srcs = glob(["bin/**", "lib/**", "share/**"]),
    visibility = ["//visibility:public"],
)
"""

def _pg_binary_repo_impl(rctx):
    spec = rctx.attr.spec
    rctx.download_and_extract(
        url = spec.url,
        sha256 = spec.sha256,
        stripPrefix = spec.strip_prefix,
    )
    rctx.file(
        "BUILD.bazel",
        _BUILD_TMPL.format(version = rctx.attr.pg_version),
    )

_pg_binary_repo = repository_rule(
    implementation = _pg_binary_repo_impl,
    attrs = {
        "pg_version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
        "spec": attr.label(mandatory = False),  # passed as a struct via tag
        # We carry the struct fields directly instead:
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(default = ""),
    },
)

# ---------------------------------------------------------------------------
# Module extension
# ---------------------------------------------------------------------------

_version_tag = tag_class(attrs = {
    "versions": attr.string_list(default = ["14"]),
})

def _pg_extension_impl(module_ctx):
    requested = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.version:
            for v in tag.versions:
                requested[v] = True

    for version in requested.keys():
        if version not in _PG_VERSIONS:
            fail("Unsupported PostgreSQL version: {}. Supported: {}".format(
                version,
                ", ".join(_PG_VERSIONS.keys()),
            ))
        for platform in _PLATFORMS:
            spec = _PG_VERSIONS[version][platform]
            repo_name = "pg_{}_{}".format(version, platform)
            _pg_binary_repo(
                name = repo_name,
                pg_version = version,
                platform = platform,
                url = spec.url,
                sha256 = spec.sha256,
                strip_prefix = spec.strip_prefix,
            )

pg = module_extension(
    implementation = _pg_extension_impl,
    tag_classes = {"version": _version_tag},
)
