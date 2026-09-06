# PostgreSQL migration planning

> Audience: compiler, database runtime and editor contributors.

`tesl migrate plan <entry.tesl> [--database D] [--initial-version N]` reports an expansion plan for a
selected PostgreSQL connection. It reads source only. The version-1
`migration-plan-preview` response has `ok`, `executable: false`, `compilerAbi`,
`planHash`, the selected database and namespace, `initialVersion` (default 1),
and ordered `steps` from that initial installation version.
Errors preserve the response kind and carry MIG/type diagnostics. Neither a
successful report nor `epochPreserving` grants execution or admission authority.

## Checked inputs

`Migration_expansion` contains the shared physical derivation over already checked
inventories and declarations. It verifies that every supplied schema is exactly
the one checked by its adjacent edges, including semantic and compiler-ABI
identity. `Migration_plan` wraps this core with source discovery, whole-application
Go emission, actual ABI pinning and source guards. The core alone supplies none
of those outer checks or database authority. Canonical prior steps retain their
identity when `VCurrent` is frozen for a later revision.

Go builds with versioned PostgreSQL connections also write
`migration-history.json` into their generated project. `Migration_program`
captures every reachable connection, including imported owners, pins the exact
application/history bytes and active compiler resources during compilation, and
rechecks source, disk, import and directory guards afterward. The supplied entry
bytes and editor overlays take precedence over saved files. The complete app must
pass Go emission before its artifact is returned. `Migration_selection` provides
the shared read-only selection beneath both this build boundary and the source
generator; it has no dependency on the compiler driver.

The version-3 `compiled-migration-history` artifact carries the actual compiler ABI,
the explicit `storedValueCompatibility` contract, and each database's family,
namespace, current revision and per-installation-origin
steps. Its compact steps omit `catalog`; the runtime reconstructs it from the
baseline and subsequent operations. Source previews remain version 1 and include
full catalogs for inspection. Omitting repeated catalogs keeps transported history
quadratic rather than cubic when each revision adds a column and every possible
installation origin is retained. A physical collision specific
to one origin is recorded with `steps: null` and explicit errors, while other valid
origins remain available. It does not serialize deployment credentials or source
paths. Memory and legacy builds emit no history artifact. Generated Go also links
these exact bytes into the runtime and registers each checked family with its
application-owned connection. A missing family, conflicting registration or
namespace mismatch refuses initialization. The binding is passed explicitly
through schema lowering, which erases the contextual schema reference.

`Database.CompiledMigrationHistory()` returns a value copy of this source
information without connecting to PostgreSQL. Standalone binary tests remove
both the source tree and adjacent JSON before inspecting the linked history.
`PgCompiledMigrationHistory.ExpansionPlan(initialVersion)` checks the closed wire
format, linked connection, ABI and compatibility contract, complete origins and consecutive versions. It
replays operations into independent catalog snapshots, checks physical contracts,
and recomputes every step identity using the compiler's length-framed canonical
encoding. Each revision must have the same source snapshot in every origin.
Malformed unselected origins and other connection owners also refuse; a supported
origin remains usable when another origin carries an explicit compiler refusal.
An error releases no partial plan. Returned plans have no shared mutable state.
The caller must obtain the origin from trusted database control state.

The [additive executor](migration-execution.md) now consumes this source input
after checking protected installation provenance. Source metadata alone is still
not evidence that a database has been installed or migrated. Application boot and
permanent request admission remain pending.

`Migration_target` resolves the explicit entry and connection, including imported
connection owners. Its immutable source guards cover application dependencies,
schema and migration files, directories and import resolution. The plan checks
the entire application through Go emission, then checks every adjacent migration
declaration with its required schema seals. Completed migration closures remain
frozen. Actual compiler/resource ABI identity is pinned throughout the judgment;
source, disk, directory, document-version and ABI guards are rechecked on return.

This matters for JSONB: a checked type inventory alone does not prove that its
record or ADT storage codec can be emitted. Nor does an unchanged JSONB carrier
establish semantic equality of records, codecs or stored proofs. Those changes
remain subject to the contextual migration checker and currently produce
transformation decisions, not an additive storage shortcut.

## Storage and identity

`Migration_storage` derives PostgreSQL columns and plain B-tree indexes from the
complete owned inventory, including private modules. Its bounded mapping covers
primitive scalars, scalar newtypes, direct nullable fields, records and supported
ADTs. Unsupported containers, nested optional representations, custom database
types and unchecked carrier changes refuse. The plan also requires valid codec
emission. PostgreSQL identifier byte limits and shared relation names are checked.

Built-in `Int32` retains the emitter's existing default `NUMERIC` layout; explicit
integer/bigint annotations use its checked range. An application-owned type named
`Int32` follows its own base. The emitter previously chose `INTEGER` for that
spelling even when its base was `String`; a compiled PostgreSQL regression now
round-trips Unicode text alongside built-in integer boundary values and checks
the actual catalog types.

Snapshot identities include the full canonical semantic inventory and the storage
mapping version. The plan hash additionally binds every ordered operation, its
compatibility classification, compiler ABI, selected database and namespace.
Canonical literals preserve integer text, float bits, booleans and string bytes.
Each step also carries `stepHash`, covering its version, snapshot identity,
compatibility classification, ordered operations and resulting catalog. Unlike
the complete preview hash, it survives connection renaming and later appended
revisions. A changed default changes this identity even when the schema snapshot
is unchanged; installing a revision fresh differs from expanding to that revision.
Its canonical domain is `Migration`, with payload
`Seq [Bytes "postgres-expansion-step-v1"; step_node step]`. A runtime must still
bind a step to the trusted logical database and recorded installation origin.
Defaults must fit their supported PostgreSQL carrier; embedded NUL in text and
integers exceeding PostgreSQL's integral numeric capacity refuse.

## Expansion and retained storage

The initial installation creates its declared tables and indexes together. Later checked `New` entries
create tables; `Additive` entries add nullable columns with physical NULL or
primitive constant defaults. Existing columns retain their complete contracts.
`Drop` retains the table. A later entity cannot reuse a retained table name, even
if the immediately preceding schema no longer declares it. Implicit primary-key
index names participate in relation collision checks; overly long names currently
refuse until explicit primary-key naming is implemented.

Index changes on existing tables produce `build-index-concurrently` operations
with versioned physical names and a pending concurrent-builder requirement.
Equivalent retained indexes are reused regardless of name. Removed indexes stay
recorded as retained storage; subsequent unchanged revisions do not repeat the
removal operation.

The initial version is the revision at which the database was first installed,
not its present version or admission floor. A database installed at V3 never
creates a table already dropped in V2 and does not inherit a default added solely
to adapt V1 writers. The planner derives the physical chain again from the chosen
baseline; it cannot merely slice a V1 plan. For example, an index removed in V2
and reintroduced in V3 is retained and reusable in a V1 installation, but requires
a concurrent build and compatibility classification in a V2 installation. A fresh
V3 installation creates it with its table. Every source edge from V1 is still
checked, including earlier defaults, source seals and retained-name collisions;
the origin option does not authorize source pruning or bypass invalid history.
The canonical initial version is included in the plan hash and must not exceed
the current source revision. This read-only option supplies an assumption for
review; the executor uses the trusted recorded installation version.

The initial compatibility classifier accepts a plain index over supported fixed
width built-in carriers, or an index whose every old key is NULL because every
column is newly introduced, nullable, default-free and absent from every earlier
admitted source schema. Composite keys containing an old-written column and
defaulted new columns do not pass the latter test. Unbounded text/numeric keys and
old-written unique keys require epoch closure. A removed index that still imposes
uniqueness or unproven key restrictions also reports its retained write restriction
and the retirement/contract work needed to remove it. Supported B-tree indexes
have at most 32 key columns.

## Verification and execution boundary

The regression suite exercises complete generated histories, native CLI
generation/refresh/plan, storage assignment, retained names and indexes,
compatibility classifications, JSONB decisions, missing codecs, frozen-source
edits, complete app errors, overlays and stale guards. A V3 refresh regression
found that checking completed V2 also visited V3's stale target seal. Refresh now
verifies V2's own frozen seals first, then checks completed bodies in the proposed
view containing the refreshed V3 header. It neither reseals nor ignores old bytes.

Each step also carries `catalog`, the expected physical superset after its checked
operations. It retains dropped tables, removed indexes, allocated physical index
names and defaults installed in earlier revisions. Projections are independent
values: projecting V3 does not change V1's expected columns. The plan hash covers
these projections as well as the operations and semantic snapshot identities.

## Live catalog inspection

`teslrt.InspectPgMigrationCatalog` compares a projected catalog with PostgreSQL
14–18 through an exclusively borrowed idle connection. It reports missing objects,
behavior-affecting drift and benign extra columns by name. This API observes
storage; it does not create missing entity objects, admit a binary or authorize
execution. The caller must decide whether a missing object belongs to a pending
expansion or indicates loss of recorded storage.

The inspector reads semantic catalog attributes and creates temporary expected
tables/indexes on the same server. Both sides use `pg_get_expr` under an empty
search path and fixed rendering settings. Equality of those deparsed expressions
is the expression comparator; arbitrary SQL equivalence is not assumed. Index
comparison covers ordered keys, uniqueness, access method, opclasses, collations,
included columns, predicates, expressions, constraint ownership and live/ready/
valid state. An equivalent index need not have the source-declared name. The
observation fingerprint normalizes physical column ordinals and equivalent index
and constraint names. Schema/table identity, expected entity owner and observed
semantics remain represented. Fingerprints are local catalog observations, not
portable proof of compatible stored values or a substitute for history checks.

Unexpected indexes, constraints, triggers, policies, rewrite rules, RLS,
partitioning, inheritance, generated/identity columns, ownership changes and
declared-column differences refuse. A supported extra column is benign only when
omitted writes can succeed without a computing default. Domains, arrays and user
types refuse even when nullable. The constant reader accepts only a closed literal
language and a matching built-in type annotation, also accepting PostgreSQL's
integer-constant rendering for numeric defaults. The original integer input type
is preserved so its range is checked before lossless widening. It never evaluates
the original default text. It binds the decoded value to a checked built-in input type and
tests assignment into a temporary column with the actual typmod/nullability;
conversion and constraint failures refuse. Nullable `nextval`, immutable calls,
operators, nested casts and volatile user casts remain drift.

Every probe and local setting is rolled back. Existing caller transactions are
refused without alteration; pre-canceled requests preserve the idle connection.
Failure to roll back closes the connection. No live entity row is selected or
written by inspection. Regression tests also retain caller-owned temporary tables,
exercise SQL identifier quoting, and observe sequence counters to establish that
computing defaults never run. The compiled storage fixture passes the compiler's
actual plan projection directly into this inspector after its generated app writes
typed values, then verifies those stored values remain intact.

The additive executor now uses this inspector inside the transaction that commits
DDL and object progress, after checking protected control state and source history.
Application boot, permanent admission/write fences and the separate Worker's
concurrent-index service now use the production history and control interface.
Typed processing-ABI rules, epoch closure and contract execution remain pending.
An inspection report is not an adoption report and cannot authorize pruning.
The complete delivery gates remain in
[the implementation ledger](migrations-implementation.md).
