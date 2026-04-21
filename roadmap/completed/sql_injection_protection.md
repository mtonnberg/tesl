# Systematic SQL Injection Protection

> **Verified and tested** — SQL injection protection was already structurally sound; adversarial tests added to prevent regressions.

## Architecture (already in place)

Tesl's SQL layer in `dsl/sql.rkt` uses Racket's `db` library which parameterizes all user-supplied values:

- **WHERE clause values**: compiled as `$1`, `$2`, … placeholders via `compile-predicate-sql`. User values are bound parameters, never interpolated into the SQL string.
- **INSERT / UPDATE values**: all use `$N` positional placeholders. Never string-interpolated.
- **Table and column names**: validated against `^[A-Za-z_][A-Za-z0-9_]*$` and double-quoted (`"column_name"`). Any name containing SQL-injection characters (spaces, semicolons, quotes, operators) is rejected at the validation boundary.

This architecture makes SQL injection structurally impossible from Tesl code: user-controlled data can only flow through the parameterized value path, never the structural SQL path.

## Adversarial tests added

Ten regression tests (`SQL-INJ-001` through `SQL-INJ-010`) in `tests/thsl-test.rkt` verify:

1. `identifier-value->string` rejects semicolons, spaces, single quotes in column names.
2. Classic `' OR '1'='1` injection payload appears as a bound parameter, never in the SQL string.
3. `' UNION SELECT password FROM users--` is safely bound, not in SQL.
4. Multiple predicates in a WHERE clause all use `$1`, `$2`, … — never string interpolation.
5. Comparison predicates (`>=`, `!=`, etc.) also use placeholders.
6. OR predicates with injection payloads are fully parameterized.
7. Null bytes and control characters in values are safely bound.

## Queue / pub-sub protection

Queue job payloads are serialized to JSON and stored in `tesl_jobs.payload (jsonb)`. JSON serialization escapes all special characters, preventing injection at the queue boundary. Pub-sub event payloads use the same path via `tesl_pubsub_outbox.payload (jsonb)`.
