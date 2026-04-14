"PostgreSQL toolchain type and registration helpers."

load("//private:binary.bzl", "PostgresBinaryInfo")

# ---------------------------------------------------------------------------
# Toolchain type
# ---------------------------------------------------------------------------

POSTGRES_TOOLCHAIN_TYPE = Label("//toolchain:postgres")

# ---------------------------------------------------------------------------
# pg_toolchain rule
# Wraps a postgres_binary target as a Bazel toolchain.
# ---------------------------------------------------------------------------

def _pg_toolchain_impl(ctx):
    binary_info = ctx.attr.binary[PostgresBinaryInfo]
    return [
        platform_common.ToolchainInfo(
            pg = binary_info,
        ),
        DefaultInfo(files = binary_info.all_files),
    ]

pg_toolchain = rule(
    implementation = _pg_toolchain_impl,
    doc = "Declares a PostgreSQL toolchain from a postgres_binary target.",
    attrs = {
        "binary": attr.label(
            mandatory = True,
            providers = [PostgresBinaryInfo],
            doc = "postgres_binary target for this toolchain.",
        ),
    },
)

# ---------------------------------------------------------------------------
# Convenience macro: registers toolchains for all supported versions/platforms
# ---------------------------------------------------------------------------

_PLATFORM_CONSTRAINTS = {
    "linux_amd64":  ["@platforms//os:linux",  "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:macos",  "@platforms//cpu:aarch64"],
    "darwin_amd64": ["@platforms//os:macos",  "@platforms//cpu:x86_64"],
}

def register_pg_toolchains(versions = None, name = ""):
    """Registers pg_toolchain targets for each supported version/platform.

    Call from MODULE.bazel or WORKSPACE after loading this file:

        load("@rules_pg//toolchain:toolchain.bzl", "register_pg_toolchains")
        register_pg_toolchains(versions = ["14", "15", "16"])
    """
    versions = versions or ["14"]
    for version in versions:
        for platform, constraints in _PLATFORM_CONSTRAINTS.items():
            repo = "pg_{}_{}".format(version, platform)
            native.toolchain(
                name = "pg_{}_{}_toolchain".format(version, platform),
                toolchain_type = str(POSTGRES_TOOLCHAIN_TYPE),
                toolchain = "@{}//:{}_bins".format(repo, repo),
                target_compatible_with = constraints,
            )
