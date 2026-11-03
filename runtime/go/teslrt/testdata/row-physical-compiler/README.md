These three files are unchanged compiler outputs for the V1/V2 fixture in
`compiler/test/test_migration_row_storage.ml`: `Note` keeps its `id` and `title`,
renames `author` to `owner`, and computes `count` while retaining old storage.
They were generated with that test binary's `TESL_PHYSICAL_TEST_EXPORT` hook.

The standalone Go tests use these as canonical parser/registration inputs. They
contain no executable callbacks and do not authorize a database connection.
Fresh hashes are computed for mutated canonical documents so semantic refusals
cannot be hidden behind a stale hash. Actual generated callback and PostgreSQL
execution remain covered by the compiler's native migration suites.
