# Checked transforming declarations

> Audience: contributors implementing and verifying the migration source checker.

The source checker now accepts a bounded `Migrate rowFunction rules` and
`Derived rules` vocabulary in a family's adjacent migration declaration. This
is an internal compiler prerequisite. A PostgreSQL application containing any
retained transforming edge still cannot be built: physical expansion rejects
`Transform` and `Reset` before deriving any installation origin. Selecting a
fresh installation at a later version cannot bypass that refusal.

`Migrated a = Row a | Reject String` remains an ordinary result type. Pure
migration functions and their Tesl tests can compile and run independently of a
Database. The tests in `compiler/test/test_migration_transform.ml` exercise actual
emitted Go under the race detector after removing every Tesl source file.

## Source judgment

`Migration_checked_graph` supplies the shared checked source graph for inventories
and the transform semantic linker. It preserves the original AST objects and
their inferred types, checks the complete captured import closure, and lowers
those objects afresh under explicit Snapshot, From or To roles. Private codecs
and fact producers remain part of semantic closure. Unlowered declarations,
including ordinary constants, are refused explicitly. The linker omits only its
exact checked root Migration constant and ordinary test declarations after full
frontend validation. Other contextual-looking constants do not qualify. This extraction preserves
the pre-existing inventory digest; it does not produce an executable callback.

`Migration_declaration` binds the sparse entity inventory and passes its exact
checked pair to `Migration_transform_rules`. `Rename oldField newField` requires
an old-only source, a new-only destination, and an unchanged stored contract.
Table and primary-key changes are refused. Unchanged fields retain their stored
contracts; changing a proof or JSONB codec is not an identity operation even if
the SQL column type remains the same. Rule conflicts, undeclared old-field
removal, and missing `Same` dependency evidence remain errors.

`Migration_transform` checks each requested row function in its declaration's
own import scope. A function must be an ordinary, monomorphic, capability-free
`fn` with exactly one unproven `From.E` argument and a `Migrated To.E` result.
The entity owners must match the exact adjacent inventory. Local functions and
functions exported by a direct import in the same migration family are accepted;
qualified and explicitly exposed spellings bind the same identity. Lambdas,
function aliases, application functions, and another family's helpers are refused.

Every successful return must contain a complete target entity literal. The
checker follows every conditional/case branch and the tail of local bindings.
A renamed field must be exactly `old.oldField`; an unchanged field must be exactly
`old.field`. Aliasing a projection, changing it and changing it back, shadowing
the original row argument, or hiding the complete result behind a helper cannot
establish that identity. A declared `Default` must also appear as that exact
primitive literal, including arbitrary-size signed integers. Newly computed
fields use ordinary type and proof checking. `Reject reason` supplies no row.

The full ordinary frontend checks every captured module, including helpers and
tests. A separate traversal follows named executable dependencies with lexical
and declaration-owner scopes. Direct HTTP failure, user `check` helpers, and
stdlib check-shaped functions are refused, including through functions and
constants. An optional `establish` can return a newly proved field or lead to an
explicit `Reject`; proof authority stays with the schema's fact owner.

Every `Migrate` entry requires at least one parameterless fixture function
returning its exact previous entity. Duplicates, unrelated entities, and functions
with arguments are refused. These are representative source fixtures, not yet
the full generated compatibility, dual-write, decoder, or PostgreSQL harness.
`Derived` has no user row callback: its descriptor retains the compiler-owned
identity/default/empty-optional mapping.

The descriptor retains the original parsed function/owner AST, exact checked rule
mapping, fixture bindings, and complete raw source preconditions. Dependent
frontend checks run in one captured source view, so a helper importing the root
sees the supplied root buffer instead of an older saved signature. Changed input
bytes refuse publication. Present history seals continue to use their existing
source integrity checks.

## Explicit remaining boundaries

A source descriptor is not an emitted callback, a physical generation assignment,
or persisted execution authority. `Migration_transform.t` remains the checked
source judgment. `Migration_transform_link.link` now constructs a separate opaque
semantic result from that judgment, rechecking its complete original source graph
and lowering it afresh with explicit From/To roles. The link retains its exact
checked source descriptor, so subsequent emission obtains the row/function AST
and semantic identity from one bound value.

The versioned canonical payload includes the exact old/new entity type closures,
checked Copy/Rename/default/computed field mapping, row-function and fixture
closures, verified Same identities and the current compiler ABI. Private helpers,
fact producers and codecs remain dependencies even when they are not exported.
The shared closure traversal follows reverse dependencies from types to codecs
and from predicates to their producers. Function and fixture mutations change the
hash; source paths, formatting, local binder names and ordinary test descriptions
do not. Unsupported ordinary constants fail instead of silently disappearing.

Raw source bytes, import-owner resolution, proof-context sites and source locations
remain validity guards outside the semantic payload. Linking and subsequent
`revalidate` reject stale source inputs or compiler resources. The graph factory
requires an explicit context for Same evidence; a context-free call suspends any
ambient grants. A token must match the complete captured graph, and lower checks
its mutable preconditions again. Complexity checks precede recursive graph
comparison. This semantic result grants no callback registration, row generation,
storage installation or database admission.

Verified `Same` now transports a primitive field's existing self-subject proof
at its exact checked `Copy` or `Rename` projection in a successful `Row` literal.
For example, `old.title` can satisfy the identical `To.ValidTitle` predicate when
the migration explicitly supplies the checked `Same` pair. This derives the
previous entity's field evidence and changes only the qualified predicate owner;
subjects, arguments, and conjunctions remain intact. Intermediate constructors,
other row receivers, computed projections, nominal values outside the key judgment below, and annotations about
sibling fields receive no such grant. Proof strengthening still needs a new
validation step.

Prepared rule/source evidence and fully checked transformations are separate
opaque types. The temporary context is tied to the complete original AST/source
graph, every import's resolved owner, and the exact validated return sites.
Source bytes and import resolution are checked before and after use, including
root backing-file changes, helper deletion, new shadow files and symlink
retargeting. Unsaved editor buffers compose with compiler resource snapshots.
Public helper-only checks suspend ambient grants, and all scopes restore state
and clear semantic caches even on exceptions. An app importing several migration
roots selects the unique context for each helper; it never unions their facts.
Additive-only roots also retain the complete helper graph so `Default True`
cannot acquire a different constructor meaning during checking.

The regression suite executes a compiled helper after removing all Tesl sources,
and checks two sealed adjacent migration edges through one application's history.
These checks establish compiler behavior only; the physical executor remains a
separate requirement.

The generated callback registry described below binds the semantic descriptor to
its actual old/new structs and a direct typed function reference. Emission uses
the retained checked source graph and bindings and rechecks source/import
preconditions at publication. Physical storage and SQL projection mappings still
require their own checked inputs. Persisted processing must
pin the exact execution ABI on the first committed target-generation write; the
semantic link alone does not permit a different compiler build to resume that work.

`Revalidate`, reset execution,
persisted row generations, lazy reads, backfill, concurrent old writes,
dual writes, and contract cleanup remain
separate required judgments.
The source checker neither installs storage nor changes database admission.

## Checked row source companions (internal prerequisite)

`Migration_row_history.check` consumes every consecutive checked schema and
migration declaration, starting at V1. It assigns generations per entity: initial
and genuinely new entities start at 1, unchanged/additive entries retain their
generation, and each linked transformation advances that entity exactly once.
The judgment rejects smallint overflow, the reserved physical column `_tesl_v`,
dropped/reintroduced identities, table reuse, and table/primary-key changes.
Its per-version storage descriptions are source projections, not installed
catalogs, SQL decoder projection orders, or evidence that a marker exists.

`Compile.compile_row_source_artifacts` is an internal compiler test/emitter seam;
no CLI command uses it. Its complete `compiled-migration-source-history` v4
inventory and `compiled-row-transform-history` v1 companion retain unsupported
physical expansion errors. These envelope versions are distinct from PostgreSQL
control format 4 and queue candidate format 4. Public compilation still refuses
retained Transform/Reset histories, and runtime expansion still refuses v4 source
metadata before accessing a database.

Artifact emission runs only inside an active `Migration_program.with_source_history`
capture. Before and after emission, the compiler rechecks the complete lowered
AST graph, private helper bodies, source bytes, editor overlays, import resolution,
directory membership, and ABI resources. Pins cannot hide a newer source view.
An escaped source-history value cannot emit artifacts. Helper-owned Same checks
use the original checked root contexts; checking a helper publicly on its own
continues to refuse those root-specific proof grants.

The companion binds each database, family, version, entity, adjacent schema/storage
contract and explicit generation pair to the retained checked row binding. Actual
Go module environments supply the exact nominal From/To names and private callback
bridge names. Both use the existing identifier allocator. Every database receives
an exact source-identity binding even when it has no transforming rows. Generated
registrations use explicit generic types, and the runtime checks their nominal
identities before sealing the complete set at local application preflight. A
sealed typed handle can evaluate the pure callback; it grants no SQL, row selection,
persisted processing ABI, admission, or migration execution authority.

This emitter slice requires Migrate callbacks. Derived metadata is checked, but
emission refuses it until a compiler-generated typed identity adapter exists.
Retained nonempty queue inventories and lifted `Tesl.CivilTime` modules also refuse
explicitly here; public queue and ordinary Go compilation paths remain separate.
The native regressions cover actual Tesl Row/Reject branches, private helpers,
Same-assisted proof copies, multiple database owners, reordered fields, quoted
physical tables, and a new JSONB record field computed from an old primitive field with
a checked output codec. That earlier test does not demonstrate existing-field
JSONB migration. The checked Retype/WriteBack slice below now covers explicit
nominal record and ADT reconstruction; physical shadow-column execution remains
required by `roadmap/next/database-migrations.md`.

## Typed logical storage adapters

The internal `Compile.compile_row_source_artifacts ~storage:true` seam additionally
emits row companion v2 and nominal SQL codecs. V1 remains a closed format and does
not acquire adapter registrations. V2 adds complete `sourceProjection` and
`targetProjection` field orders, taken from the same owner environments that emit
the positional scanners. These orders are code layout metadata outside the
location-free semantic callback hash. Canonical snapshot column order is not a
scanner order.

The compiler verifies each emitted field, SQL type, nullability, primary key and
source-schema column name against the checked history. It emits decoder/encoder
bridges inside every participating schema owner, where private codecs and their
proof checks are available. The complete captured graph and ABI guards run before
and after emission. `RegisterCompiledRowStorage` attaches four concrete functions
to the exact typed transform: From decoder/encoder and To decoder/encoder. No
callback or record crosses an erased cast or a JSON conversion between nominal
types. Primitive columns, primitive newtypes, optional columns and records with
checked bidirectional JSON codecs are supported. Direct ADT column adapters refuse
explicitly until their SQL codec path has separate checked coverage.

Opaque source and target projections retain independent identity even when their
fields and SQL types coincide. `CheckOrder` requires the entire compiler order;
`Decode` and `DecodeTarget` additionally check actual PostgreSQL result aliases,
count and OIDs before calling `Scan`. Encoded parameters require the exact matching
projection plan. A plan from another database or the opposite direction refuses.
No method returns mutable owned projection metadata. V2 preflight requires complete storage attachments before atomic sealing; a
missing adapter leaves every database and callback open for a complete retry.
Duplicate, nil and late attachments refuse. V1 callback-only preflight and pure
`PgRowTransform.Run` remain supported without storage adapters.

SQL NULL is represented separately from JSON `null`: optional JSONB scanners use
raw bytes, where nil means SQL NULL and bytes containing `null` reach the nominal
codec. Invalid stored values, codec proof failures and decoding panics produce
value-safe adapter errors. The PostgreSQL regression reads and writes historical
record codecs directly and executes primitive source decoding, the actual Tesl
Row/Reject callback, target encoding and target decoding, using distinct values,
quoted physical test names and deliberately reordered projections. Sources and
loose JSON files are absent during the native race-tested run.

This is a logical codec/projection prerequisite. It allocates no retained or
shadow physical columns and grants no row selection, generation installation,
transaction, admission or migration execution authority. Reconstructing an
existing field without Retype remains rejected with MIG018 because Copy requires
its exact original projection. Same transports primitive field proofs and the exact nominal field copies
described below; Retype uses explicit nominal constructors.

## Retained physical storage planning

`Migration_retained_storage.plan` consumes the exact checked row history, including
its adjacent additive default judgments. It describes expansion while historical
columns and indexes remain retained. A schema's current columns alone cannot
supply this catalog: a rename keeps the predecessor column, introduces a nullable
target, and records every target-to-historical-column write obligation. These
obligations belong to each entity, persist through additive revisions, and compose
across successive renames. Predecessor finality does not remove historical NOT NULL
constraints; only explicit contraction can release these writes. A computed/defaulted
transform target also stays physically nullable until its row marker establishes
the complete target row. Previously installed additive SQL defaults remain intact.

Each window retains its exact callback binding, both logical-to-physical layouts,
and all predecessor columns whose changes can invalidate its row marker. The
predecessor generation is an explicit finality prerequisite for expansion, not
proof that finality has occurred. Logical decoder order is requested explicitly
and must include every field exactly once; canonical catalog order is not a SQL
projection. Retained column/index name reuse is rejected, including implicit
primary-key index collisions. Unaffected and newly introduced entities keep
generation one independently of the schema revision.

This internal planner does not emit SQL or change public migration support. A
consumer still needs source/ABI publication guards, exact live catalog and stored
inventory checks, lifecycle/lease/finality authority, and a separate physical
projection after contraction. In particular it does not claim that an old column
still exists after a contract has removed it. Retype physical planning and the
executor must consume the new checked mapping and typed write-back bindings
described below; the earlier planner explicitly refuses that unsupported mapping.


## Checked Retype and typed WriteBack

A changed stored record/ADT contract, including its codec or proof dependencies,
can now use `Retype metadata` with `WriteBack metadata metadata backward`.
`backward` must be an owned, pure `fn (To.Entity) -> OldFieldType`; ordinary nominal
constructors and their proof obligations are checked in the original owner scope.
There is no nominal Same cast, JSON conversion between versions, or erased
callback. Direct predicates attached to the entity field's return type currently
refuse; old entity predicates mentioning sibling fields also require a separate
whole-entity reverse proof and currently refuse. Nested proof-bearing record/ADT
constructors are supported. This bounded
online source slice requires WriteBack for every Retype; acknowledged windows
without a reverse value remain unsupported.

Refresh proposes `@column("metadata__v2")` on the selected VCurrent field, using
the introducing schema version. The source and editor guards cover that edit and
the refreshed seal together. The exact full history validates its Retype origin;
wrong names, baseline annotations and unowned new-field annotations refuse.
Unannotated canonical field encodings retain their existing bytes. A storage
annotation alone cannot justify Retype: the stored type/proof/codec contract must
change. Rename may pair a differently named Retype source; removed/added fields
may use WriteBack without a same-name Retype.

The internal storage artifact route emits row companion v3 for a history with
WriteBack. V1 and v2 remain closed formats. V3 retains exact source/target logical
projections and adds checked `writeBacks` endpoints, cross-checked with the full
function closures in the semantic link. The emitter exports private-owner
function bridges and constructs one statically typed `To.Entity -> From.Entity`
reverse adapter from Copy/Rename projections and the checked WriteBack functions.
`RegisterCompiledRowWriteBack(storage, reverse)` binds it to the exact existing
nominal `PgRowStorage[From, To]`. Completeness is required before atomic preflight
sealing. `Reverse` returns the old nominal row; `Encode` uses the original owner's
encoder and its original ordered source projection.

Actual PostgreSQL regressions decode an old JSONB record or ADT, run the emitted
Tesl callback, encode the new versioned column, run the real reverse constructor,
and read its old-format output with the original codec. They also cover private
proof codecs, two Retype fields, SQL NULL versus JSON null, distinct field values,
actual Reject, callback closure hashing and generated storage annotations. This
slice supplies typed values and logical projections. It does not select or update
persisted rows, grant physical mappings, install generation state, admit a
transforming application, or establish rolling compatibility/finality on its own.


## Ordinary typed entity queries in the physical artifact route

Physical artifacts bind each transforming current entity to a generated
`PgRowAccessSlot[CurrentEntity]` in its schema owner. The application attaches the
exact `PgRowStorage[PreviousEntity, CurrentEntity]` with
`RegisterCompiledRowAccess`; the slot indexes bindings by the actual database
pointer. Callback, storage, WriteBack and access completeness are checked before
atomic application preflight seals any owner. Missing, duplicate, foreign and
late bindings cannot fall through to the old SQL path.

Ordinary `select`, `selectOne`, `insert`, `insertMany`, `update` and
`updateAndReturnOne` use these statically typed closures. SQL query fragments
retain explicit logical field holes until the admitted retained physical plan
resolves them. Copy and Rename predicates/orderings use storage whose value is
valid for both generations. Computed/Retype predicates, aggregates and joins in
either direction currently refuse. SQL text is constructed from the checked
query and physical plan; it is not rewritten after emission.

A read performs one retained-projection SELECT and decodes each marker with its
original nominal codec before invoking the actual Tesl callback when needed. A
multi-row update declares one server-side NO SCROLL cursor over SELECT FOR UPDATE.
FETCH uses TESL_RMW_BATCH (default 2000); each result is drained and closed before
that batch is written in the same admitted transaction. The original cursor owns
one target snapshot, so rows inserted between batches cannot enter the update.
Ordinary updates retain only the current batch; updateAndReturnOne fetches at
most two rows to reject ambiguity before writing. Each SET operand is captured once,
then WHERE operands are evaluated once, including zero-match updates. Reject,
decode errors and SQL write errors roll back the whole update and a tentative
first processing-ABI latch. Existing insertMany per-row transaction semantics
remain unchanged. The normal PostgreSQL lease timeout bounds each logical
operation. Debug artifacts retain the existing DebugPgSql capture of the actual
physical statement, already evaluated parameters and completed row count.

The native regression emits authentic V1 and V2 applications with the same
handlers and a versioned schema constructor helper. It runs their actual Main
and HTTP servers against PostgreSQL, then checks old writes, lazy reads, new
inserts, multiple locked rows, late old writes, Rename predicates, first-write
rollback, timeout recovery, precise debug capture and operand evaluation order.
Original Tesl sources and loose metadata are absent when these programs run.

The physical query slice requires one exact transforming binding ending at the
current schema. A later window also requires the checked predecessor Contract
source, bound to this database and its exact window and settled descriptions.
Keeping that source does not prove deployment completion: the protected runtime
receipt must independently authorize opening the next window. An additive tail
still requires a checked typed access composition; it cannot silently reuse
legacy dispatch.
Physical Retype/WriteBack materialization and checked window-to-settled dispatch
are described below. MIG031 warns when a rewritten update lacks a primary-key equality. It names the
checked migration and explains the matched-row cost; the suggested warning does
not block compilation. Invalid TESL_RMW_BATCH settings refuse before cursor DML.
Cursor tests use batch size one, prove multiple fetches and a fixed target
snapshot through a concurrent old-app insert, and roll back prior batches on
SQL errors or Reject. The ordinary public compiler route remains gated independently
from this internal, fully checked artifact route.


### Physical Retype and settled descriptions

The internal checked artifact route materializes a Retype through two nominal
codecs. Its new nullable column receives the target codec; every retained old
column receives the checked WriteBack result encoded with the original source
codec. Equal PostgreSQL JSONB carriers do not imply equal JSON representations.
The physical inventory binds each reverse obligation to its exact previous field,
current field and old storage column. Same-value Rename aliases remain separate.

The compiler-generated application regression builds V1 before V2 exists, keeps
its HTTP handlers running, and tests record JSON keys and ADT constructor changes.
It covers lazy conversion, new inserts, whole-row updates, late V1 invalidation,
reverse compatibility, nullary ADTs, SQL-error rollback, Reject and lock timeouts.
Freshly hashed mutations must fail when they omit, duplicate or reassign reverse
bindings or alter the proposed settled columns, provenance, indexes or marker.
Both migration PostgreSQL gates run this generated application regression.

A settled description contains only current columns and indexes, current source
nullability and the current generation default. Parsing or validating this
source-bound description grants no runtime permission to drop storage. The pure
planner records the exact previous transforming revision as a contraction
prerequisite before opening another window; retained format v3 carries that
prerequisite explicitly. Runtime observation must still prove the corresponding
completed Contract. This description support alone does not implement worker
finality, contraction, settled query dispatch or public feature activation.


### Serving through a checked Contract

A compiled current entity keeps its original typed access slot for the lifetime
of the process. Each operation admits the original window, then selects either
its window projection or the exact registered settled projection using the
protected compatibility floor and matching Contract receipt. The floor alone
cannot authorize another SQL shape. The token keeps the original window identity
for ABI checks even when its active SELECT, UPDATE and INSERT use settled storage.
Rename predicates then select the current physical column; retired aliases and
reverse columns are absent from settled writes.

The operation holds a shared compatibility fence through transaction completion.
The contraction coordinator tries the exclusive fence without queuing ahead of
unrelated requests. It publishes the changed compatibility floor only after
existing window operations finish. This preserves already captured SET and WHERE
parameters and avoids replaying application effects. The checked global
preparation prefix relaxes retired required columns before this switch, allowing
settled INSERTs while those columns still exist and await their approved drops.

The PostgreSQL regression runs actual compiler-generated V1 and V2 Main/HTTP
applications with their source and loose metadata removed. An independent
connection verifies durable provisional worker conversion. A late V1 write is
then covered by the final pass. The test pauses an original V2 transaction,
observes contraction waiting while independent requests keep succeeding, and
uses those same server processes before and after each SQL projection switch.
It checks inserts during the prepared-but-not-dropped interval, exact removal
and tightening, current Rename predicates, one-time operand effects, and refusal
of retired V1 writes. Separate first-write rollback tests expand an empty database
before the still-running V1 app inserts rows, preserving their tentative-ABI
witness independently of worker backfill.

This remains the bounded internal compiler artifact route. Public activation,
checked access composition across later revisions, and additional lifecycle
protocol scenarios have separate completion gates.

### Primary-key carrier regression boundaries

The actual generated worker regression now pauses after conversion and lets the
still-running V1 application update the source row. A missed xmin CAS commits the
scan cursor with zero materialized rows and no processing ABI latch. Its terminal
empty batch marks the pass provisional and clears the cursor; the explicit final
pass rescans the keyspace and preserves that newer source value before retirement.
This is separate from a successful write, which publishes row, ABI, and progress
in the same transaction.

An unchanged record or ADT field can be copied as the exact original row
projection when the migration supplies the complete verified `Same` closure.
The checker grants this only at successful final `Row` entity constructors. It
keeps the original projection's nominal type; ordinary helpers, intermediate
constructors, reconstructed copied values, another field or receiver, and shadowed row
parameters do not receive a conversion. Copy and Rename use the same judgment for
primary and non-primary fields. A shared external key type still cannot escape the sealed
schema boundary, and `List String` still lacks a checked primary-key storage
carrier (MIG016).

Go lowering consumes opaque site metadata only after Program validates the exact
captured source graph against the lowered modules. Each changed nominal owner
must match a verified declaration pair. Record fields and ADT variants/payloads
are copied through concrete typed helpers, including supported nested lists.
No JSON roundtrip or native cast performs the transport. In particular, a lossy
codec may omit a field: the typed copy preserves its original value rather than
substituting the decoder's default. Unsupported nested representations refuse
emission; this does not widen ordinary nominal unification.

The mandatory native regression retains separately compiled V1/V2 applications,
then deletes their Tesl sources, generated Go and loose metadata. Record and ADT
keys (including a nullary variant) pass through an actual Worker, durable JSONB
cursor/progress/ABI publication, a late old writer, lazy reads and the explicit
final pass before Contract. The same handlers continue after cleanup; the retired
V1 writer refuses. Tests compare actual encoded SQL key values as well as codec
input, and cover changed codecs, exact graph substitution and expired captures.

A separate real
PostgreSQL carrier assertion demonstrates why worker cursor SQL uses direct
JSONB comparison: SQL NULL means an absent cursor, whereas JSON literal `null`
is an ordered JSONB value; `jsonb_populate_record` would erase that distinction.


Compiler-synthesized Legacy/WriteBack reverse rows reuse the exact source-site
certificate for each copied nominal field. The original migration module emits
a private inverse structural helper using its concrete old/current owner tables;
export metadata retains the opaque context-and-site identity. The reverse-row
constructor checks that identity, original parameter/field, target entity/field,
and both declaration locations before selecting the helper. Only verified Same
pairs are inverted; source checking grants no inverse cast to ordinary code.
Derived adapters require their own checked mapping authority and cannot invent a
source expression site. The original-to-lowered graph guard and pre/post source
revalidation continue to enclose both directions.

### Repeated current bindings

The internal artifact regression freezes V2 through the normal migration
generator, updates VCurrent, then generates the V3 edge. Its unchanged App
handlers use the current nominal entity slot while the artifact retains separate
checked V2 and V3 callback/storage bindings. Copy and Rename query fragments use
the exact registered settled predecessor projection. Computed predicates remain
refused.

The native fixture compiles original V1, V2 and V3 applications, with checked
Contracts present before the relevant build, then deletes their Tesl sources and
loose metadata. V3 publication refuses before the actual V2 Contract completes.
The same V2 servers then read and write generation-3 rows through their original
nominal codecs. Membership comes from the exact verified immediate successor and
its preserved projection, within a live admitted transaction; an unrecorded
marker is refused even when its number is larger.

Publication waits for an original V2 `transaction` that has already read data
and emitted an observable effect before its update. The effect executes once,
and other admitted requests continue. The second actual Contract also waits for
a retained V2 reader before dropping its old column, while V3 requests continue.
The retired reader returns admission status 503; the same V3 process serves CRUD
after cleanup. A fresh size-one request pool with a caller-held row lock verifies
that catalog observation neither borrows another pool slot nor changes the
caller's transaction isolation. Public transforming feature activation remains
independent of this internal checked artifact route.


## Logical field removal and old-reader values

The checked source route accepts `Legacy field literal` and `LegacyWith field fn`
for an old-only field. Legacy supplies a primitive constant of its exact previous
unproven type; LegacyWith names an owned pure function with the exact signature
`To.Entity -> From` field type. Neither rule invents a new-field endpoint. They
cannot change a primary key or overlap Rename, WriteBack, Retype or another legacy
rule. Both reverse forms refuse old cross-field predicates that the per-field
adapter cannot establish. Nested nominal values use ordinary checked constructors
in the original owner; they are encoded by the original private storage codec.

The linker includes each literal or complete helper closure in both source and
ABI-independent behavior identities. Row companion format 4 contains a distinct
`legacyWrites` inventory, while formats 1–3 remain closed. Retained physical
format 4 records each legacy obligation as `[previous logical field, old physical
column]`; ordinary WriteBack keeps its three-part mapping. The optional exact
preceding Contract version is represented separately. Parsing and compiler binding
independently require each previous field's complete physical lineage. The runtime
receives one typed reverse row constructor, requires its registration before
preflight, and encodes old-only values through the previous source adapter.

The current logical row omits removed fields. During coexistence, backfill and new
writes supply their legacy values so original readers remain valid. Contract then
removes the old columns and their obsolete indexes. Its preparation relaxes old
required columns before current-only inserts; the same current app process serves
before and after cleanup. The actual PostgreSQL regression covers a constant text
field plus a computed JSONB record field and an index on the removed text field.
This is still the internal source route; public command activation is separate.
