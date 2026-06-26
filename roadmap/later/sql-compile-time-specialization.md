# SQL compile-time specialization — blocked on a live PostgreSQL test env

**CORRECTION: We have access to a POSTGRES server through nix in the repo - see how we do it in scripts/init.sh, scripts/postgres-start.sh and scripts/postgres-stop.sh**


Carved out of `compile_time_specialization.md` (moved to `completed/` 2026-06-26).
Phases 0/1/2 shipped (codec benchmark; specialized primitive ENCODERS and
DECODERS, byte-identical-by-construction). **Phase 3 (SQL) is blocked here.**


## The work
Hoist the residual SQL `WHERE`-clause string-building to compile time: emit a
per-query-site SQL template (the `WHERE` clause pre-built, predicate columns
fixed) so the runtime only binds parameter VALUES, instead of assembling the
clause per request.

## Why it's blocked
Honest behavior-identity verification requires a **live PostgreSQL round-trip** on
both valid and malformed inputs (identical generated SQL strings **and** identical
query results / error behavior). No shared PostgreSQL is configured in the dev/CI
sandbox — the DB-dependent suites (`test_library_suite`, `apitest`, `loadtest`,
`httpclient_integration`) cannot run here. Specializing SQL without that gate would
violate the project's byte-identity / error-quality invariants.

## Plan (when a PG test env is available)
1. Wire a PostgreSQL service into CI (this also unblocks the parked DB test suites).
2. Emit the per-query-site template; keep the current runtime builder as a
   differential ORACLE.
3. Gate on: identical generated SQL strings AND identical results/errors on valid +
   malformed inputs, across the SQL-using lessons and the DB integration suites.
