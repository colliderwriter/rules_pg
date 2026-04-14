"""
Legacy WORKSPACE support.

Bzlmod users (MODULE.bazel) do not need this file.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# Mirrors _PG_VERSIONS from extensions.bzl for WORKSPACE users.
# Keep in sync.
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

_BUILD_TMPL = """
load("@rules_pg//private:binary.bzl", "postgres_binary_files")

postgres_binary_files(
    name = "pg_bins",
    version = "{version}",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "all_files",
    srcs = glob(["bin/**", "lib/**", "share/**"]),
    visibility = ["//visibility:public"],
)
"""

def rules_pg_dependencies(versions = None):
    """Download pre-built PostgreSQL tarballs.

    Args:
        versions: list of version strings to download. Default ["14"].
    """
    versions = versions or ["14"]
    for version in versions:
        for platform in _PLATFORMS:
            spec = _PG_VERSIONS[version][platform]
            name = "pg_{}_{}".format(version, platform)
            if not native.existing_rule(name):
                http_archive(
                    name         = name,
                    urls         = [spec.url],
                    sha256       = spec.sha256,
                    strip_prefix = spec.strip_prefix,
                    build_file_content = _BUILD_TMPL.format(version = version),
                )

def rules_pg_register_toolchains(versions = None):
    """Register pg toolchains for the given versions.

    Args:
        versions: list of version strings. Default ["14"].
    """
    versions = versions or ["14"]
    for version in versions:
        for platform in ["linux_amd64", "darwin_arm64", "darwin_amd64"]:
            native.register_toolchains(
                "@rules_pg//toolchain:pg_{}_{}_toolchain".format(version, platform),
            )
