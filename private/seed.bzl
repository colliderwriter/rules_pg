"pg_seed_data rule and PostgresSeedInfo provider."

load("//private:schema.bzl", "PostgresSchemaInfo")

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

PostgresSeedInfo = provider(
    doc = "Carries seed data files to be loaded after schema migrations.",
    fields = {
        "seed_files": "depset: .sql or .csv files applied after migrations",
        "schema":     "PostgresSchemaInfo: the schema that must exist before seeding",
    },
)

# ---------------------------------------------------------------------------
# Rule
# ---------------------------------------------------------------------------

def _pg_seed_data_impl(ctx):
    schema_info = ctx.attr.schema[PostgresSchemaInfo]

    seed_files = depset(
        ctx.files.srcs,
        order = "preorder",
    )

    return [
        DefaultInfo(files = depset(transitive = [schema_info.migrations, seed_files])),
        PostgresSeedInfo(
            seed_files = seed_files,
            schema     = schema_info,
        ),
    ]

pg_seed_data = rule(
    implementation = _pg_seed_data_impl,
    doc = """\
Declares seed data to be loaded into the test database after schema migrations.

Accepts .sql files (executed via psql) and .csv files (loaded via COPY).
For .csv files the filename (without extension) is used as the table name:
  users.csv  →  COPY users FROM '/path/to/users.csv' CSV HEADER;
""",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".sql", ".csv"],
            mandatory = True,
            doc = ".sql or .csv seed files applied in order after schema migrations.",
        ),
        "schema": attr.label(
            mandatory = True,
            providers = [PostgresSchemaInfo],
            doc = "The postgres_schema target whose migrations run before seeding.",
        ),
    },
)
