# Combined format5 cache, email and SSE installation

`--schema install` installs all declared extensions in the same transaction as a
fresh format5 baseline, or adds all missing extensions to an existing baseline.
It commits only after every extension and the combined catalog pass verification.
Existing extensions are verified, not recreated. Helpers restore the transaction's
entry role after using Owner; `SET LOCAL` is also reverted on commit/rollback.

The extensions preserve the checks on the closed App row/queue inventory,
compiler ABI, stored-value compatibility and retained migration history. Updating
the compiler/runtime still changes the compiler ABI in the usual way. The shared
`pgRowFacilityCatalog` supplies exact relation names to both row catalog verifiers
and exact functions to the global Owner-function inventory, independently of the
current App's declarations. Request readiness additionally requires storage for
each declared facility before publishing its pool.

| Storage | Owner | Worker | Request |
| --- | --- | --- | --- |
| `tesl_cache_artifacts` (unlogged) | Owns table | None | SELECT, INSERT, UPDATE, DELETE |
| `tesl_email_runtime` | Owns table | SELECT | SELECT |
| `tesl_email_messages` | Owns table | None | None directly |
| `tesl_sse_clock`, `tesl_sse_broadcast` | Owns tables | None | SELECT |

Only Request receives execution grants on these exact Owner-defined functions:

- `tesl_email_enqueue(integer,text,text,text,text,text)`
- `tesl_email_claim(integer,integer)`
- `tesl_email_outcome(integer,bigint,text,boolean)`
- `tesl_email_messages(integer)`
- `tesl_email_prune(integer,bigint)`
- `tesl_sse_publish(integer,text,text,jsonb)`
- `tesl_sse_prune(integer,bigint)`

Cache has no protected SQL functions: its values are disposable and isolated by
the emitted artifact digest. Email and SSE mutations use exact protected functions.
Their verifiers reject orphaned routines and extra overloads as well as changed
definitions/grants. Removing a declaration does not remove stored mail or events.

`TestWorkerCombinedFacilitiesInstaller` covers fresh, existing-with-no-extensions,
and existing-email catalogs. One public Installer call must install all missing
extensions. It checks Worker inspection, Request readiness, all three backend
operations, exact role permissions, repeat installation, and complete stored-row
preservation through Installer/Worker retries. Existing catalogs are modeled by
removing optional storage from a checked fixture, without reopening App registration.

Mandatory runner routes: `cache-runtime`, `email-runtime`, `sse-broadcast`, and
`combined-facilities`. Compiler emission tests check artifact identity and inclusion
of all six new runtime files. The generator and dune dependency list include them.

## Targeted verification

On 2026-10-18, the integrated implementation passed all 16 selected runtime tests
with the race detector against a private PostgreSQL cluster (80.573 seconds):

```sh
go test -p 1 -race -count=1 -timeout=300s -tags=tesl_migration_test ./teslrt \
  -run '^Test(ArtifactCache|PgEmail|WorkerBroadcast|WorkerCombinedFacilities)' -v
```

The first run exposed an ambiguous `id` reference in the email functions' shared
admission SQL. Qualifying the metadata/state columns fixed it; the complete selected
suite then passed. Compiler build and the four cache/email/SSE emission cases passed.
The artifact-identity case additionally compiles the emitted PostgreSQL runtime
dependency closure. Dune regenerated the embedded runtime from the integrated sources.
Existing facility-refusal, cache, outbox and pubsub regression tests also passed
with the race detector (8.957 seconds), and `go vet ./teslrt` passed.

These targeted results are not a full CI or supported-PostgreSQL-major matrix pass.
Archived pre-extension binary interoperability is not established by these tests.
