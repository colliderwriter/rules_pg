"""
rules_pg public API.

Load everything you need from this file:

    load("@rules_pg//:defs.bzl",
        "pg_test",
        "pg_server",
        "pg_health_check",
        "postgres_schema",
        "pg_seed_data",
        "postgres_binary",
        "PostgresBinaryInfo",
        "PostgresSchemaInfo",
        "PostgresSeedInfo",
    )
"""

load("//private:binary.bzl",
    _postgres_binary     = "postgres_binary",
    _PostgresBinaryInfo  = "PostgresBinaryInfo",
)
load("//private:schema.bzl",
    _postgres_schema    = "postgres_schema",
    _PostgresSchemaInfo = "PostgresSchemaInfo",
)
load("//private:seed.bzl",
    _pg_seed_data      = "pg_seed_data",
    _PostgresSeedInfo  = "PostgresSeedInfo",
)
load("//private:test.bzl",
    _pg_test = "pg_test",
)
load("//private:server.bzl",
    _pg_server       = "pg_server",
    _pg_health_check = "pg_health_check",
)

# Re-export rules
postgres_binary = _postgres_binary
postgres_schema = _postgres_schema
pg_seed_data    = _pg_seed_data
pg_test         = _pg_test
pg_server       = _pg_server
pg_health_check = _pg_health_check

# Re-export providers (for downstream rules that want to depend on pg targets)
PostgresBinaryInfo  = _PostgresBinaryInfo
PostgresSchemaInfo  = _PostgresSchemaInfo
PostgresSeedInfo    = _PostgresSeedInfo
