# PostgreSQL migration execution

> Audience: contributors implementing and testing the migration runtime.

The production runtime has an installer, a protected control interface and an
additive expansion executor. Versioned application startup consumes the linked
compiler history and publishes its request pool only after required expansion succeeds.
Every versioned SQL read and write checks permanent admission. The compiled binary
provides installation, status and separate worker commands. The Worker request/
executor split is covered below; automatic heartbeats, adoption, concurrent index
jobs, typed backfill and contract remain pending. The complete acceptance gates are tracked in
[the implementation ledger](migrations-implementation.md).

## Application startup and requests

`WithDatabase` selects versioned startup when the compiler attached migration
history to the application's connection. The application supplies its connection
and optional `PostgresConfig.controlOwner` (default `tesl_control`). These settings
stay outside the pure schema and migration modules. The operator must install the
protected control objects first; missing installation or unrecorded lookalike
storage refuses before the application's body runs. There is no fallback to legacy
bootstrap. Unversioned declarations retain their existing behavior.

A dedicated connection runs either the Embedded executor or Worker request
verification before the request pool is published. Pool initialization includes
the complete compiled history, topology and roles in
its cache identity; different revisions cannot mutate or reuse each other's
protocol binding. Failed initialization is removed so installation or repair can
be followed by a retry. Each new physical connection, including dedicated pub/sub
listeners, verifies the database UUID, fence allocation, format, protocol and
actual configured login, then checks admission. Whole startup is currently bounded by
`TESL_PG_POOL_LEASE_TIMEOUT_MS` (default ten seconds), independently of each DDL
operation's two-second lock timeout. Larger startup plans need a higher limit.

Versioned implicit statements use read-committed transactions. Writes first acquire
the version's shared transaction advisory fence, then call `tesl_admit` in a separate
statement with a fresh snapshot. The fence lasts through commit. Reads buffer and
scan their results first, call admission, and release results only after commit.
Reads hold no advisory fence. Explicit transactions reuse one physical connection
and check admission again before committing; a caught statement refusal leaves the
transaction aborted and cannot permit commit. Nested `with database` for the same
transaction reuses its connection even with a pool size of one.

Write-returning queries are explicitly classified as writes, including queue and
email claims. Queue lease renewal, pub/sub publication, pruning, legacy dispatch
and listener reads use the same gates. Refused operations report HTTP 503 rather
than returning data or acknowledging a write. Runtime-owned table installation is
still the legacy format; its versioned ownership and upgrade path are phase-2 work.

## Separate schema worker

`PostgresConfig.topology` is a literal `Worker` or `Embedded` constructor from
`Tesl.Database` (`MigrationTopology(..)`). If omitted, the existing `TESL_DEPLOYED`
environment flag selects Worker when present and Embedded otherwise. An explicit
setting wins. These fields are legal only with a versioned schema module:

| Field | Meaning |
|---|---|
| `requestRole` | Worker request login, default `tesl_app` |
| `workerRole` | Worker executor and entity owner, default `tesl_schema` |
| `ddlConnection` | Optional direct/session-affine DSN for the executor; omitted uses that process's normal connection settings |
| `controlOwner` | Separate NOLOGIN control owner, default `tesl_control` |

Role names are stable deployment identities, independent of the actual login
selected by each process's credentials. Request/worker role settings require
Worker topology. The DSN may use an environment value and is never printed by a
configuration parse error. Its session affinity is a trusted deployment
requirement; the runtime does not claim it can detect transaction poolers.
The installer also uses this dedicated DSN when configured, so its invocation
must supply the short-lived installer credentials there rather than a worker login.

Worker installation requires `--schema install --worker ROLE --request ROLE`,
matching the configured role identities. The short-lived installer establishes
the grant profile. Requests receive control-table SELECT and execution of only
`tesl_admit` and `tesl_heartbeat`; entity SELECT/INSERT/UPDATE/DELETE grants commit
with table creation before expansion progress. Requests have no namespace CREATE,
entity ownership, lifecycle transition authority or worker/control membership,
including indirect and NOINHERIT membership. The worker retains entity DDL and
narrow control transition authority; the control owner remains separate.
Neither long-lived login may own the connected database or reach its owner
through role membership, even with NOINHERIT. Database ownership would otherwise
provide authority outside the intended namespace grants, including implicit
`pg_database_owner` membership on newer PostgreSQL versions. The installer may
temporarily hold the authority needed for installation.
The same ownership restriction applies to Embedded's combined long-lived login.

`./app --schema worker --json` expands on its dedicated connection and emits one
`schema-worker-ready` JSON object after success. It then stays alive until SIGTERM
or SIGINT; it starts no HTTP handlers or application queue workers. The service
lifetime is independent of the startup lease. This initial worker runs additive
expansion; background transformation/index jobs and automatic heartbeats are not
implemented by waiting in that loop.

A request process observes fresh READ ONLY, repeatable-read snapshots while its
revision is pending, without acquiring the boot lock. Each snapshot checks role
isolation, immutable history, protected definitions, recorded entity storage and
DML grants. It never borrows executor credentials. On readiness it publishes the
request pool; identity changes or incompatible history refuse, and a missing
worker eventually reaches the bounded startup deadline.

Request catalog verification needs neither CREATE nor TEMPORARY privilege.
Closed expected control definitions and compiler storage shapes use builtin type
and operator-class metadata. Literal defaults preserve PostgreSQL's canonical
rendering; extra-column checks submit only parsed, whitelisted literal values to
builtin casts in SELECT statements. They preserve assignment semantics, including
varchar/char overflow and numeric rounding. No stored default expression executes.
The regression matrix cross-checks this path against the installer's independent
temporary-table probes, including actual READ ONLY transactions without TEMP.

The format number remains 2: Worker changes the explicit grant profile, not the
control function bodies or stored rows. An existing Embedded profile is not
silently converted by a Worker installer or request. Such a topology transition
needs a separate operator protocol. Embedded keeps one combined request/executor
login and reports that reduced isolation at startup. Worker startup and installation
refuse databases declaring durable queues, caches, email or SSE before connecting;
their protected storage installation is still pending. Declarations are tracked
per database, regardless of history-link order, and cannot be added after Worker
preflight. Lazy storage entry points also check the opened connection's topology.
This local restriction is not persisted proof about facilities used by older
binaries and cannot authorize epoch closure. Status remains available for inspection.

[Lesson 84](../example/learn/lesson84-worker-migrations.tesl) exercises the same
notes API across separate Worker deployments and retained old/new application
processes. Its regression includes request-before-worker startup, byte-identical
handlers, role-denied DDL/lifecycle calls and an old binary restart.

## Inspecting a compiled application

A versioned binary accepts `./app --schema status`, optionally with `--database
Module.Database` and `--json`. Multiple versioned PostgreSQL connections require
an exact compiled identity; Memory and unversioned connections are excluded.
Command parsing and dispatch precede both `main` and debug-service startup.
Malformed commands exit with status 2 and cannot fall through to serving.

Status uses a dedicated connection and one repeatable-read control snapshot. It
reports installation/current/admission versions, the compiler ABI, protocol and
format, object progress, lifecycle rows and recorded heartbeats. It verifies
protected catalog/role definitions and compares persisted history to the binary's
source plan. A source mismatch still yields the JSON observation plus
`historyError`, with an explanation on stderr and exit status 2. Connection,
control-integrity and output errors also exit nonzero. The snapshot and any Embedded
comparison objects are rolled back; Worker status uses the read-only catalog path.
Status never opens the application's pool,
expands, adopts or repairs. A status observation does not authorize later requests
and does not claim that entity storage is ready. Automatic application heartbeats
remain pending; this command reports the records that actually exist.

The JSON envelope is version 1 with kind `schema-status`. The complete native
lesson checks status before initial startup, with a newer binary's expansion
pending, and from an older binary while a later additive version runs. The
observed current version stays unchanged until an actual application starts.

## Installation and roles

`./app --schema install --worker ROLE [--database Module.Database] [--json]`
is the Embedded form and uses the application's configured connection as the short-lived installer. Supply
its credentials through the application's own configuration (for example
`NOTES_DB_USER` in lesson 83), then restore the worker credentials for normal
startup. The explicit `--worker` names the separately provisioned application
login; it is never inferred from the installer connection. The command creates no
roles, grants no role memberships and never starts the HTTP server. The operator
must grant and revoke the installer's temporary membership outside this command.

`InstallPgCompiledMigrationControl` validates the whole linked artifact, chooses
the current revision for a fresh database and verifies any existing protected
origin and persisted source history while holding the installer lock and snapshot.
An interrupted older baseline stays at that origin. A refused origin or changed
recorded source/ABI fails without altering history. Creation and final verification
share one commit; retries do not replace identity. The JSON result has version 1
and kind `schema-install`, with binary, initial, current and installing versions.
An output failure after commit exits nonzero; repeating the command verifies the
same installation. Installation success establishes protected control state;
application boot still performs and verifies pending entity DDL.

`InstallPgMigrationControl(ctx, conn, namespace, roles, initialVersion)` borrows a
dedicated installer connection. The operator provisions a no-login control owner,
a worker login and a short-lived installer with temporary control-owner
membership. The owner needs permission to create the namespace and the registry in
`public`; the worker needs connection and temporary-table privileges. Installation
grants the worker namespace usage/create, control-table reads and execution of the
closed control functions. It creates no entity tables. The operator must revoke
the installer's owner membership afterward; steady-state inspection refuses while
that membership remains available to an ordinary login.

Workers cannot own, alter or write control tables and functions, allocate fence
namespaces, inherit the control role, or inherit administrative capabilities.
Checks include effective table/column privileges and predefined roles such as
`pg_write_all_data`, which can grant authority without changing object ACLs.
Expansion also requires both `current_user` and `session_user` to equal the worker:
an administrator's `SET ROLE` is not an isolated worker login.

The bootstrap session lock `(32341, 0)` precedes the repeatable-read inspection
snapshot. Acquiring it inside that snapshot would allow a losing installer to
miss the winner's commit. The installer creates the closed definitions atomically
and records an immutable database UUID, allocated integer fence namespace and
`initial_version`. The first committed installer chooses this origin, even if
entity installation later stops. A newer executor must finish that baseline before
expanding subsequent revisions. Retries never replace the UUID or installation
origin and never adopt pre-existing objects by name.

Production format 2 contains the meta/state/version/instance tables, expansion
intents and ordered object progress. Its five security-definer functions admit a
version, begin an expansion, record an object, finalize expansion, and heartbeat.
Their search path is empty and their references are qualified. PostgreSQL verifies
each object identity and permits only an immutable consecutive prefix. Finalizing
the baseline records `expanded`, `contracting` and `contracted` together; later
additive revisions only record `expanded`, without advancing the admission floor.

Expansion intents and lifecycle rows record both the actual creator `source_abi`
and `stored_value_compatibility`. Finalization copies both from the immutable intent.
Format 1 installations and older compiled history formats refuse explicitly; there
is no automatic adoption of their missing compatibility metadata. Changing the
format number or relabelling their stored ABI is not an upgrade procedure.

These are additive production definitions, not the independent phase-0 fixture's
full future protocol. A format-upgrade executor, retirement, leases and later lifecycle
tables still require implementation. The inspector compares the installed format
exactly, including function bodies, ownership, ACLs, sequence definitions and
behavior-affecting catalog properties. Extra control columns are not treated like
benign extra entity columns. Live defaults are never evaluated during inspection.

## Ordered additive execution

`ExecutePgMigrationExpansion(ctx, conn, history, roles)` accepts an idle connection
authenticated as the worker. It validates the complete linked artifact before
using database state, acquires the session boot lock `(fence_ns, 2147483647)`, and
rechecks identity and state after waiting. The shared installer lock remains held
through execution. The connection is never returned to a pool while owning either
lock; ambiguous lock acquisition or failed cleanup closes it.

The executor obtains the origin from protected metadata and checks every recorded
intent, object hash and lifecycle row. Every installed revision needs complete
progress and exactly its supported lifecycle records. Known source snapshots and
step hashes must match the binary. A pending earlier expansion cannot be skipped.
An older binary may reopen a later additive database: its known history and storage
must still match, and additional columns must preserve omitted writes.

The whole-build source ABI identifies the actual compiler/runtime/stdlib build.
The separate stored-value contract binds an explicit compiler semantic revision
and active lifted stdlib digests. Its definition and maintainer obligations are in
[LANGUAGE-SPEC](../LANGUAGE-SPEC.md).
Retaining that revision promises compatible proof/type/check/establish semantics,
erasure, lowering, primitives, codecs and SQL-visible representation. This promise
must be reviewed when those implementations change; runtime string equality alone
does not establish semantic equivalence.
The September 2026 main merge strengthens proof ownership, server authentication
type checking and queue-worker proof admission. The semantic revision therefore
advances to 2; binaries from before those fixes are not silently declared
stored-value compatible. The full-app compiler-upgrade test still checks a harmless
query-only build change within this new contract and refusal across contracts.

A completed additive intent may have a different creator ABI when its contract
matches the current compiler and the checked source/storage/step identities,
complete progress, lifecycle provenance and live catalog agree. The compiler
rechecks the entire historical source closure under its actual semantics. Earlier
creator ABIs remain unchanged in protected history; a later step records its own
creator. Different contracts require explicit untrusted decoding/revalidation,
whose production executor is still pending.

Every unfinished intent requires the exact original ABI, including zero completed
objects and complete DDL awaiting its lifecycle commit. A different-ABI older
binary also refuses while an unknown future intent is pending. This conservative
rule applies to startup and status history validation; same-contract acceptance
is restricted to fully completed history. It grants no ability to resume another
build's work. Processing-ABI locking for typed transformations, including the
first target-generation application write with zero backfilled rows, remains
phase-3 work.

The supported operations are creation of a new table and its indexes, addition of
a nullable or constant-defaulted column, and retention of a dropped table. Index
changes on existing tables and non-additive changes refuse before entity work.
There is no `IF NOT EXISTS` adoption path. A conflicting unrecorded table, column or
index is an error even if its shape looks suitable.

An expansion intent commits first. Each operation then runs in a short
read-committed transaction with a two-second DDL lock timeout. The runtime compares
the resulting uncommitted catalog, records that object's identity, and commits the
DDL and progress together. Comparison savepoints remove their temporary objects
without rolling back the caller's DDL. After all operations, one transaction
verifies the complete catalog and finalizes the revision. A timeout or backend
death leaves a verifiable committed prefix; a retry validates that prefix before
continuing. Missing recorded storage is drift, never a request to recreate it.

Object identities are SHA-256 of the bytes `tesl-migration-object-v1`, the decoded
32-byte step hash and the ordinal as an unsigned big-endian 32-bit integer.
PostgreSQL derives this independently with `sha256`, `decode` and `int4send`.
The step identity already binds the ordered operations and resulting catalog.

## Regression evidence

The runtime tests use isolated databases, real worker logins and fsync-enabled
PostgreSQL. They retain rows through defaulted and nullable additions, exercise
unchanged old insert statements and old-binary restarts, check late installation
origins, reject control and entity drift, and verify retry and role isolation.
Backend termination covers every DDL and both sides of every transaction commit
in a six-operation revision: 22 boundaries. Another test queues ten executors from
three revisions behind a paused executor and verifies one ordered history.

The native regression generates three actual Tesl revisions, compiles standalone
executables, deletes the source tree and emitted projects, and runs those binaries
through the production executor against retained rows. This establishes the
compiler-to-executor connection. It does not replace the required full HTTP app
lessons for later migration phases. Lesson 83 adds the full application test for
an additive column: its source remains byte-identical, both generated API suites
run, and actual HTTP servers retain rows while old and new revisions write and
read concurrently, including an old-binary restart. Startup tests additionally cover retained rows across revisions, retries
after missing installation, concurrent opens, source/catalog/role refusal, and
replacement pooled and dedicated connections. Admission race tests pause actual
reads and writers around retirement and verify refusal without leaked rows,
commits, queue claims, lease renewals or pub/sub results. Retirement is simulated
by the installer under the exclusive version fence; production contract remains
pending.

The [lesson83 compiler-upgrade companion](../example/learn/lesson83-additive-migrations.md)
has a separate full-app regression. It builds actual compiler A, a query-only
variant B and a different-semantic-contract C in an isolated source copy. A authors
V1–V3; B recompiles unchanged V3 and authors V4. Both builds run unchanged API tests
and HTTP handlers against retained rows, and A restarts against B's later revision.
An interrupted A intent refuses B before mutation; A then completes it. Tampered
frozen source and C compilation/startup refuse. Protected history keeps every
creator ABI rather than replacing A with B. This regression passes with race
instrumentation; only the interruption executable uses the migration test hooks.

`scripts/run-migration-tests.sh` runs the independent harness plus production
control/executor/startup/admission tests when invoked without filtering arguments. The production
tests and their crash hooks participate in the PostgreSQL 14–18 matrix. Crash hooks
exist only in builds tagged `tesl_migration_test`.
