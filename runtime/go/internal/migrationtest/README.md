# Migration protocol regression harness

This package is independent of `teslrt` and is never embedded in applications.
It tests protocol mechanisms before their production executors exist. Passing it
does **not** mean that the migration feature, planner, or runtime has shipped.
The [implementation ledger](../../../../dev-docs/migrations-implementation.md)
tracks those delivery gates separately.

## Run the gates

From the repository root, inside the Nix development shell:

```sh
bash scripts/check-migration-models.sh
bash scripts/run-migration-tests.sh
```

The PostgreSQL script creates and removes its own cluster, using a private Unix
socket and no TCP listener. It runs the race detector. `go test` without
`TESL_MIGRATION_TEST_DSN` runs the pure model and controller tests and explicitly
skips database cases; that is not a PostgreSQL gate. The controller tests also
need permission to create a local Unix socket.

The control bootstrap is authored in `testdata/control-bootstrap.sql`, executed
by the database fixtures, and rendered into the normative roadmap. A sync test
compares those bytes on every run. After editing the fixture, update only that
marked transaction in the document from `runtime/go`:

```sh
TESL_UPDATE_MIGRATION_SQL_DOCS=1 \
go test ./internal/migrationtest -run '^TestControlBootstrapDocumentMatchesExecutedFixture$'
```

`testdata/contract-v8.sql` supplies the complete labelled contract fence. Its SQL
steps execute directly; named hooks and zero-row assertions cannot be silently
skipped. It has the same update command with
`-run '^TestContractDocumentMatchesExecutedFixture$'`. Tests terminate the
coordinator after every boundary and recover from database state, comparing the
resulting history, generations, jobs and catalog to independent expectations.

The renderers refuse missing or duplicate boundaries and preserve surrounding
prose. The remaining expansion template still needs its executed fixture;
these sync gates do not imply that the production executors exist.

Optional tiers:

```sh
TESL_MIGRATION_TEST_POOLERS=1 \
TESL_MIGRATION_TEST_CLUSTER_CRASH=1 \
TESL_MIGRATION_TEST_TRACE_SCALE=8 \
bash scripts/run-migration-tests.sh
```

Pooler tests require `pgbouncer` on PATH. Crash/replica tests require `initdb`,
`pg_ctl`, and `pg_basebackup` from the PostgreSQL major being tested. They own
additional temporary clusters; they never stop a shared service or developer
database. Trace scale is an integer from 1 through 16. Every random test has a
reproducible seed in its subtest name and prints the failing operation prefix.
CI sets `TESL_MIGRATION_TEST_POSTGRES_MAJOR` and checks the connected server's
actual major before creating fixtures, including the separately owned clusters.
Run the full compiler suite and this harness sequentially on machines with
limited disk bandwidth or cache space.

## What the independent comparisons establish

| Oracle | Implementation under observation | Scope |
|---|---|---|
| `Model` | Normative control SQL | Admission, expansion, retirement, contract and immutable repair history; actual persisted rows after successful and refused transitions |
| `BootstrapModel` | Control SQL, worker-owned application objects and session boot locks | V8/V9 initial-target races, every partial-DDL crash boundary, expired boot observability lease, initial-history commit/rollback and idempotent recovery |
| Catalog evidence and literal grammar | Server-parsed temporary expressions and live catalog mutations | CHECK/default/index equivalence, collation, isolated constraint/index properties, domain/cast/typmod refusals and nonunique-index write failures |
| `Model.Indexes` | PostgreSQL catalog, progress views and locks | Live INVALID build versus abandoned remnant, lease takeover, validity verification, backend death and terminal-before-drop recovery |
| Separate V7/V8/V9 processes | Emitted application SQL and runtime | Memory/PostgreSQL outcomes, shared additive rows, transaction ordering, imported entity ownership and absence of release failpoints |
| Read ordering argument and finite TLA+ model | Interposed PostgreSQL retirement/DDL | Query-first admission, six query shapes, old/surviving readers, commit ordering and lock retention |
| Committed lifecycle evidence | Backend death, immediate primary shutdown and WAL recovery | Atomic floor/lifecycle outcome, lock release and resumable coordinator work |
| Primary state | Paused physical replica | Counterexample to replica-local admission; catches up to both the new floor and changed physical schema |

The finite TLA+ kernel is in [dev-docs/models](../../../../dev-docs/models/README.md).
Its positive models and seven required counterexamples are a separate CI gate.

`Model.Rows` and `Model.Repairs` also check symbolic rejection/repair decisions:
only a rejected row enters an ordered repair chain, an accepted row is not
reinterpreted, the executor carries every recorded amendment, accepted batches
survive coordinator rollback, and quarantine cannot retain an old row revision
or reason. Row-function success/rejection is an **input** to this model; it does
not establish the semantics of a Tesl transformation. The row revision is an
unbounded-in-practice oracle identity, not an implementation of PostgreSQL's
bounded-age `xmin` protocol. Actual transformation/repair execution, ABI drift,
generation triggers, and multi-entity finality need their production regression
comparisons when implemented.

## Adding a scenario

Use named scheduler boundaries or observable PostgreSQL waits to establish an
interleaving. Never use a sleep, a guessed delay, or the production lease timeout.
Identify the actor and occurrence, put a deadline on every wait, and include the
fixture's lock/activity/lifecycle dump in failures. A signal sent to a backend is
not proof that it exited; wait for its activity and locks to disappear.

Keep model expectations independent from SQL and emitted runtime code. Compare
raw catalog and persisted data as well as the returned error. Check that a
refused operation leaves durable state unchanged and that an equal retry leaves
the caller's transaction usable. Include crashes on both sides of a commit and
stale participants resuming after recovery.

Tests name `INV-*` and `TR-*` identifiers in their declaration comments. The
[kernel inventory](../../../../dev-docs/migration-protocol-inventory.json) defines
each current ID. `TestProtocolTraceability` parses the actual Go declarations and
model operation switches to validate the
[generated coverage map](../../../../dev-docs/migration-protocol-coverage.json).
It rejects unregistered model operations/IDs, untested transitions, tests without
invariants, stale source references, unknown coverage layers, duplicate JSON keys,
and PostgreSQL fixtures labelled as model-only tests. Named failpoints in test
declarations and configured PostgreSQL lanes are included. Regenerate from
`runtime/go` after reviewing changed metadata:

```sh
TESL_UPDATE_MIGRATION_TRACEABILITY=1 \
go test ./internal/migrationtest -run '^TestProtocolTraceability$'
```

This inventory is explicitly scoped to the implemented harness kernel. The
complete normative inventory and production implementation/failpoint mapping
are still pending; the generated file lists those uncovered scopes. This partial
inventory does not satisfy the whole phase-0 traceability gate. Queue payload
migration/quarantine, staged uniqueness, offline/catch-up,
control-format upgrades and production executor correspondence remain incomplete.
The dedicated pinned-environment p99 performance gate also remains separate from
this functional harness.
