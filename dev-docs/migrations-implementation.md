# Migration implementation ledger

> Audience: contributors implementing, reviewing, and verifying schema migrations.

This ledger tracks the work in `roadmap/next/database-migrations.md`,
`queue-payload-migrations.md`, and `staged-uniqueness-guard.md`. The history file is
non-normative. An unchecked row is not delivered.

| Delivery gate | Implementation | Regression gate | First review | Final review |
|---|---|---|---|---|
| 0: deterministic harness, independent model and traceability | pending | pending | pending | pending |
| 1: schema history, planner, additive executor, permanent admission, editor | pending | pending | pending | pending |
| 2: worker roles, concurrent indexes, durable queues and effects | pending | pending | pending | pending |
| 3: typed transformations, compatibility, backfill, epoch closure | pending | pending | pending | pending |
| 4: contract, repairs, pruning, offline and catch-up | pending | pending | pending | pending |
| 5: JSONB codec integration | pending | pending | pending | pending |
| Queue payload migration language and executor | pending | pending | pending | pending |
| Staged uniqueness runtime guard | pending | pending | pending | pending |
| Dev docs, manual, and runnable scenario lessons | pending | pending | pending | pending |

## Documentation acceptance

The maintainer added this completion requirement on 2026-09-05: update the
developer documentation and manual, and teach migrations through several major
lessons that compile and run in CI. The initial lesson split is:

1. Schema ownership, adoption, and an additive column.
2. Typed transformations, renames, defaults, and row proofs.
3. Rolling deployments, admission, epoch closure, and contract.
4. Quarantine, repair, and compiler ABI consistency.
5. Queue payloads, outboxes, and idempotent external effects.
6. Staged uniqueness and promotion.
7. Offline changes and restoring an old database through catch-up.
8. JSONB codec history and evidence-backed pruning.

Each lesson must exercise its actual generated runtime and refusal cases; source
checking alone does not meet this gate. This is a planned inventory, not a claim
that these scenarios currently work.

The maintainer also requires full-application scenarios: migrations are difficult
to learn if examples show only entities and row functions. Lessons 1–4 and 6 will
evolve the same runnable notes HTTP app. Each scenario will identify the changed
files, preserve application handlers/routes/codecs byte-for-byte where behavior is
unchanged, and run the same API assertions against the app before and after the
migration. PostgreSQL cases must retain existing rows through the actual executor;
starting a fresh Memory store is not evidence of migration compatibility. A
scenario that adds a derived value maintained by application writes must show the
necessary handler change and explain why it is necessary. Database connection
settings stay in the application; versioned schema and migration modules contain
no handlers or effects. These comparisons are regression assertions, not just prose.

The JSONB lesson also uses that app. It compares a representation-only codec
adapter with a typed record/ADT transformation under the same migration history.
It must demonstrate both reader/writer directions during a roll and an untouched
old JSON value surviving later deployments. Retiring an old binary does not prove
that its JSON representation is gone; decoder pruning requires final rewrite
evidence. The clarified rules are in the main roadmap's section 10. Integration
with the planner, backfill and pruning is pending.

The first part of [lesson82-database-migrations](../example/learn/lesson82-database-migrations.tesl)
now compiles and runs through `tesl test`: five direct tests cover schema-owned title
proofs, rejected writes, length boundaries, Unicode and missing rows. Its thin
schema root exports nothing and imports a child entity module; the application
owns the database declaration and effects. It is also a runnable notes HTTP app:
four API tests cover create/read, validation failure without insertion, malformed
JSON without insertion, and isolated test state. HTTP request/reply records and
codecs live in the application, separately from the stored entity. All three source files pass
agent-context and formatting. Generated Go snapshots and the manual lesson index
are included. Adoption, additive execution and the remaining lessons are pending.

## Slices under development

- Saved-source history discovery now derives `VCurrent`'s version and loads every
  consecutive frozen schema through the checked semantic inventory. It records
  raw-byte guards for private schema dependencies and transitive migration helpers,
  including import diamonds and cycles. Missing intermediate snapshots/migrations,
  invalid version numbering, noncanonical paths, symlinks, special files and local
  import shadowing refuse discovery. Rechecking an inventory also checks revision
  directory membership and import resolution, so adding a shadowing source file
  cannot redirect an existing import silently. Fifteen regression groups pass.
  This is an internal saved-source API, not the public generator or editor overlay
  API: migration modules are parsed and checked for ownership and declaration
  purity, but their records/types and amendment files still need elaboration.
  Frozen-header verification, prune evidence and atomic manifest application remain
  pending. Discovery failures retain their own categories; a schema type error is
  not mislabeled as MIG013 edited-history evidence.
- Ordinary application modules and their imported libraries now reject historical
  schema imports with MIG015, including nested modules and unsaved buffers.
  Adding a test block grants no exception. Pure tests are permitted in migration
  modules as the roadmap specifies; capability declarations, connection selection
  and implicit effects are rejected. The multi-version nominal-type regression
  now runs in a migration test module instead of an ordinary application. The
  focused import suite and diagnostic registry pass. MIG015 now carries a single
  source-verified action for the import, qualified types and qualified expressions,
  including interpolations. It shares the frozen-copy token walk and preserves
  comments, literals, Unicode, tabs and CRLF. Tests check the unsaved buffer even
  when the file does not exist, and applying the action produces a valid application.
  Generated compatibility-store authority and the versioned diagnostic metadata
  protocol remain pending.
- Recursive ADT JSONB emission now reserves recursive decoder names, boxes decoded
  self-fields and unwraps them during encoding. Recursive encoders use a forwarder
  without changing nonrecursive helper names. Explicit `adtJson` codecs now retain
  constructor payloads and check their children. The regression executes recursive
  HTTP responses, codec round trips, raw SQL scans and invalid nested inputs using
  both flat and boxed Go layouts. It also found structural OCaml type equality in
  `expect`, which failed on recursive types; that site now uses nominal type equality.
  The complete compiler suite and tracked corpus build pass for this slice.
  A second review found imported boxed payload types losing their declaring package,
  explicit forbidden ADT codec directions being bypassed, and generic columns losing
  their type arguments. These are fixed. The expanded matrix keeps different
  instantiations separate within one row and through nested/optional fields; it also
  checks imported boxed constructors, single-constructor values and tagless runtime
  tuples. A generic boxed comparison exposed an unguarded inactive payload access;
  its disjunction now stays inside the tag guard. All 17 JSONB regression groups
  pass, including emitted HTTP responses, raw scanner refusals and Memory round trips.
  The codec-direction check also walks nested generic arguments before its nominal
  recursion guard; forbidden codecs cannot hide behind `Envelope (Envelope State)`.
  Explicit codecs on generic ADT declarations and additional container payloads still
  require dedicated coverage and implementation; this does not certify every ADT shape.
- A full root CI run exposed failures in NilAway, generated-file synchronization,
  documentation count checks, corpus inventory and clean installation. Model clone
  maps now remain writable when empty, and repair/registry tests establish their
  non-nil inputs explicitly. NilAway and the subsequent model race run pass.
  The documentation counts and corpus inventory are corrected. The clean-install
  failure came from Go probing an incomplete parent `.git` above generated output;
  container builds disable automatic VCS stamping and keep the explicit image source
  revision. The scrubbed-environment regression creates that condition and passes.
  The subsequent committed-tree root CI run passed 22 of 23 phases, including the
  full compiler suite, exact snapshots, shipped clean installation and browser tests.
  Its migration harness failed during database setup; the other runtime static-analysis
  checks and all five skipped fuzz targets subsequently passed. Both timed-out cases
  pass in isolation, and the complete PostgreSQL 17 suite passes in 79 seconds with
  poolers, replica and owned-cluster crash cases. The setup failure is intermittent;
  its cause has not been established. SQL failures now dump activity, blockers and
  transaction/query start times, and a failed private-cluster run preserves the full
  server log with slow-statement and lock-wait diagnostics. Timeouts and durability
  settings are unchanged. A later full compiler run passed the language/runtime
  suites but exposed stale Dune input in the suite-registration meta-test: its
  copied configuration omitted newly registered suites. The test now declares its
  configuration and test-file dependencies, and its focused gate passes. The
  expanded compiler slices require the next full gate;
  neither feature-wide review is complete.

- The deterministic scheduler, independent model, real control-template tests,
  and compiled V7/V8/V9 process oracle run against disposable PostgreSQL 17.
  The process oracle explicitly prepares its catalog; it is not the production
  migration executor. Release binaries are checked for absence of test controls.
- An independent bootstrap catalog model now compares first-install state with
  PostgreSQL after each committed object and lifecycle step. V8/V9 races cover
  every partial-install crash boundary, a lease expiring while its backend still
  holds the boot lock, a newer executor finishing the persisted target, equal
  recorder retries, and death before/after the initial history commit. A V8 winner
  permits additive V9 expansion; a V9 winner never invents V8 history. The fixture
  creates application objects as the worker role and checks their actual types,
  nullability, primary key, defaults and ownership. The production installer and
  control-format upgrade recovery remain pending.
- The reference model now includes append-only repair chains, prefix-compatible
  admission, whole-chain executor checks, ordered repairs of rejected rows only,
  and quarantine revision/reason checks after retirement aborts. Symbolic row
  function results exercise protocol decisions; they do not replace generated
  Tesl transformation tests. PostgreSQL repair-history traces compare every
  success, refusal, rollback and persisted chain against the separate model.
  Those traces found the normative recorder accepting an empty repair hash; the
  recorder now refuses an empty artefact identity before writing history.
- Index model cases distinguish catalog validity, active server statements,
  scheduling leases and shared DDL-job locks. Actual PostgreSQL builds are paused
  by an existing writer while a lease expires and a successor arrives. A successful
  build is retained; a terminated build leaves an invalid remnant that is rebuilt.
  Contract waits for catalog verification and records terminal before dropping,
  including coordinator death between those steps and a surviving stale worker.
  Creation, executor-admission and removal versions are distinct: a V9 worker can
  finish a V8 index while V8 retires, and a V9 removal waits for V9's plan switch.
  The model and actual PostgreSQL case cover those boundaries. The control fixture
  persists `terminal_version`; recovery refuses a changed removal target before
  updating any job or dropping an object. These cases caught the model incorrectly
  using the creating version for both the worker fence and the contract target.
  These remain protocol fixtures, not the production index executor. Nightly
  model traces run eight times the per-PR trace length with recorded seeds.
  A deterministic first-scan pause also lets an old writer insert a duplicate;
  PostgreSQL then leaves a ready-but-invalid unique index after validation fails.
  The test proves that it rejects further duplicate writes until the remnant is
  dropped, pinning the documented rolling-deployment risk independently of readiness.
- A machine-checked harness inventory now maps registered `INV-*`/`TR-*` IDs to
  model guards/operations, actual test declarations, named test events and configured
  PostgreSQL lanes. It rejects unmapped operations, untested transitions, tests with
  no invariant, duplicate definitions and incorrectly labelled direct database tests.
  It currently covers 54 invariants, 57 transitions and 81 top-level test declarations.
  This is explicitly a kernel inventory with uncovered scopes listed in the generated
  report; the complete normative inventory and production path mapping are still pending.
- The control bootstrap now has one executable SQL fixture under the harness's
  `testdata/`. Its documentation sync gate renders the exact transaction into a
  marked region of the normative roadmap, refusing ambiguous boundaries and
  preserving surrounding statements. Other normative templates still need this
  fixture/execution correspondence.
- Registry fixtures run in separate databases and compare the normative CREATE
  against an independently specified temporary catalog. They refuse wrong owners,
  writable table/column/sequence grants, changed constraints or identity sequences,
  unlogged storage, inheritance and rewrite rules, while keeping the caller's
  transaction usable. Ten family allocations are observed waiting at the bootstrap
  lock before release; their namespaces and UUIDs remain distinct. Rollback consumes
  a namespace without publishing it, and exhaustion fails before a reserved key can
  be registered. These cases pass on PostgreSQL 14–18. This is a test implementation
  of the registry hook; the production installer and full role-membership audit
  remain pending.
- Catalog-expression fixtures compare CHECKs, defaults, generated columns, index
  expressions and predicates using one server and matching temporary column types
  and collations. Equal deparsed text still requires matching column collation.
  Default tests exposed an unsafe roadmap assumption: a volatile user-defined cast
  can deparse as a literal followed by `::type`. The fixture recognizer now accepts
  only a closed scalar-constant grammar, and column checks reject domains and invalid
  typmod assignments. Tests demonstrate both the cast's side effect and a domain's
  deceptively plain stored default. Computing defaults are never evaluated during
  classification; recognized constants are probed only on temporary tables. The
  normative acceptance rule now includes these refusals. The production catalog
  verifier and full drift classifier remain pending.
  Raw catalog evidence also covers table flags, column identity/generation,
  constraints, indexes, triggers and policies. Paired tests change exactly one
  index/constraint property and require every other property to stay equal;
  recreating an equivalent CHECK must not differ merely because its OID changes.
  Another regression disproves the roadmap's blanket benign-nonunique-index rule:
  expression and predicate errors, and oversized plain B-tree keys, reject rows
  the table previously accepted. Unrecorded indexes now require explicit adoption;
  generated plain indexes need an old-key domain proof to remain epoch-preserving.
  Implementing that proof and the resulting planner classification remains pending.
- The documented V8 contract is also an executed, labelled fixture. Each SQL
  boundary and callback is followed by database/model checks; backend death at
  every boundary resumes from durable database evidence. Tests retain accepted
  row values, compare server-parsed CHECK definitions, validate before NOT NULL,
  check removal of temporary objects, and enforce settled constraints. Running
  it under the worker role found missing progress/observability grants in the
  normative control bootstrap; the grants now match the declared role boundary,
  with negative tests for direct state, history, activation and barrier writes.
  Initial-history boundary tests also found the SQL recorder accepting nonpositive
  versions; it now rejects those, the reserved boot-lock version, missing snapshot
  hashes and invalid protocol identities before publishing any lifecycle rows.
  Recipe hooks use a small stand-in row function and pending/dead job restamps;
  generated Tesl transforms, processing-claim semantics and production contract
  orchestration remain separate delivery gates.
- The direct compiler now routes `tesl test` through every emitted test package.
  Name and kind must match the same test, and a missing selection fails.
- Durable queue claims have monotone attempts, stored expiry, renewal, and stale
  outcome checks. Transaction-owned claims retain their row-lock guarantee only
  in the exact claiming transaction. Versioned decoders and admission remain pending.
- SHA-256 has published and independent binary/padding vectors. Dotted schema
  module headers, directory resolution, qualified calls, constructors, and nominal
  version separation have executable regression coverage. Qualified-only migration
  imports support constructor patterns, including nested `Maybe`, with negative
  cases for version mismatches, missing cases and arity. Semantic IR freezing and
  the planner remain pending.
- Canonical encoding format 1 is specified in LANGUAGE-SPEC, with independent
  Python/hashlib wire/hash vectors and a separate test decoder. Schema references
  retain `from`/`to` roles while alpha-renaming revision numbers; otherwise switching
  between old/new same-named helpers could go undetected. This is the wire layer,
  not yet the typed AST elaborator or a verified semantic closure.
  The checker now offers opt-in expression-identity capture with each node's final
  function-local substitution, since editor source positions are not unique IR
  identities. Tests keep numeric/text `Nothing` nodes distinct at coincident spans,
  resolve earlier branch types after later unification, and retain let-polymorphism.
- Typed declaration encoding now covers pure expressions, signatures, proofs,
  schema mappings and codecs. Its dependency graph follows private helpers, all
  conservative fact owners, constructor definitions and type-to-codec reverse
  dependencies, with cycle and missing-definition checks. Fourteen focused regression
  groups pass, including an independently constructed typed wire/SHA-256 golden,
  semantic mutations, alpha-renaming and frozen-copy invariance. These low-level
  APIs do not assert that their caller has supplied a complete schema inventory.
  The subsequent saved-source loader now constructs that inventory from its root,
  validates every private module with the public compiler judgment, resolves
  declaration/builtin identities, and wraps results with the compiler ABI. Its
  abstract result prevents callers from omitting a private fact producer. Thirteen
  regression groups pass. They found stale cached import interfaces admitting a
  newly ill-typed helper, physical table collisions hidden in private modules,
  ambiguous builtin predicate resolution, and an omitted regex-literal gate. All
  four cases now refuse or resolve correctly. Nested record/ADT and codec edits
  change the containing entity's closure even when its SQL JSONB field is unchanged.
  Contextual Same verification, compiler ABI allocation, source-history identity,
  editor overlays and manifest/runtime-history integration remain pending.
- Four generated codec API tests now run in the compiler gate. They demonstrate
  the asymmetry of a legacy decoder, failure after premature decoder removal,
  ordered fallback behavior and corrupt JSON refusal, and incompatible nested ADT
  constructors in both directions. These are serialization counterexamples, not
  PostgreSQL rewrite or production migration tests. The roadmap's JSONB section
  now requires a unified plan, bidirectional rolling compatibility and durable
  evidence before removing a decoder.
- Record JSONB storage now uses an explicit bidirectional codec. Five compiler
  regression groups execute emitted scanners and codecs for local/private/transitive
  records, nested records/ADTs, nullable fields, exact large integers, ordered
  fallback selection, proof failures, and missing/forbidden codec directions.
  The declaration is refused even without queries or with `@db(jsonb)` when its
  record codec contract is incomplete. Review regressions caught a missing
  transitive Go import, same-named ADTs sharing a decoder, and an annotation
  bypassing the record contract; those cases are fixed.
- The checked inventory now projects semantic contracts for every stored entity
  field using the same IR lowering as complete declarations. A changed codec,
  nested ADT, or fact producer reaches all containing fields, including private
  entities, optional fields and newtype wrappers. Nine regression groups cover
  exact affected locations, fallback removal/order, proof subjects, annotations,
  additions/removals, frozen copies, same-named private types, ABI/family refusals,
  and one codec shared by 300 private entities. Unstored records/codecs and
  unrelated fields remain outside the change report. Field proof subjects use
  stable names so adding or reordering a sibling does not create spurious changes.
  This is planner input; physical catalog diffing, compatibility classification,
  persisted ABI/history checks, queue occurrences and decoder-pruning gates are
  still pending.
- A complete V7/V8/V9 HTTP app now runs in separate generated binaries against
  PostgreSQL with byte-identical application source. Raw JSONB checks and unchanged
  HTTP assertions cover old/new read directions, untouched old values surviving
  later versions, partial rewrites leaving nullable/ADT occurrences behind, complete
  application re-encoding, and proof-invalid rows in all three positions. This
  exposed pgx's pointer JSON scan conflating JSON null with SQL NULL; generated
  scans now preserve the distinction. Runtime tests also exercise pgx's JSON and
  JSONB scan plans in text and binary formats, legacy JSON wrapping, malformed
  input and checked rejection. The focused PostgreSQL 17 regression passes with
  the race detector. The production migration executor and JSONB lesson are pending.
  A compatible V8 bridge writes both keys and remains readable by V7 and V9 with
  identical handlers; a late V7 write reintroduces legacy-only JSON and demonstrates
  why a rewrite alone is insufficient evidence. Versioned processes now coexist
  throughout the trace, eliminating per-request process/race-detector shutdown cost.
  This preserves the existing hard deadline; it does not relax a protocol timeout.
- Compiling the roadmap's optional establish example exposed a pre-existing
  rejection of `Maybe (value: T ::: P value)`. This return form now accepts bare
  proof attachment and checks every successful payload with path-sensitive return
  discharge; it retains the restrictions on HTTP `ok`/`fail`. The regression matrix
  rejects wrong subjects, wrong predicates, missing conjunctions, unproven branches
  and aliases, discarded evidence, and minting from an ordinary fn. Generated Go
  preserves successful values and Nothing, and a caller requiring the proof runs.
  Check/auth return matching now resolves decomposed witnesses from each returning
  branch's semantic environment. Regression cases cover nested optional subjects,
  alias chains, sibling branches, conjunction projection and delegated auth. This
  also removed an unsafe assumption that a check's distinct result binder aliases
  its first argument. The roadmap's establish/check snippet is read directly by a
  compiler regression and executed in generated Go, including Nothing and HTTP
  failure. Its indentation and declared return binder were corrected to match the
  language. The full compiler suite passes after these changes; the final snippet
  additions also pass the focused compiler/Go suite.
- Source-preserving freeze previews include the whole owned import closure, private
  declarations and cycles. The tests cover interpolation, literals, CRLF, tabs,
  idempotence, edited history, missing modules, and symlinks (including dangling
  directory symlinks). Applying a manifest and semantic history checks remain pending.
- The maintainer clarified that fixtures must model the same ownership boundary
  as production: `app.tesl` owns connections, `operations.tesl` owns effects, and
  `schema/notes/v-current.tesl` owns entities. Separating the fixtures exposed
  imported entities incorrectly emitting Memory-only queries. The project-wide
  database binding fix and schema-content rejection tests pass, including three
  separately compiled applications sharing PostgreSQL rows. The schema files contain
  no database, environment access, application operations, or tests.
  The same boundary now applies when checking a schema file directly, before an
  App binds it to a database, and to unsaved schema buffers. Ten focused compiler
  regression groups pass, including the generated multi-module Go applications.
  Migration-family modules now also reject application declarations, connections,
  effects, entity declarations and application imports, while allowing pure
  migration/fixture constants. Standalone, imported and unsaved checks pass in
  the expanded eleven-group suite. Generated test/support modules still need
  their explicit test-build capability boundary before that surface ships.
  The twelfth group verifies whole-application schema ownership: splitting child
  modules between database declarations, combining families and binding historical
  entities are refused before emission. The checker and emitter share entity
  resolution, preserving local declarations versus qualified-only imports. A new
  unsaved-file test exposed the graph walk skipping files without a disk copy;
  it now checks the parsed entry and its imports, including ownership, in that case.
  Module references now select the complete private entity closure and keep the
  physical PostgreSQL namespace separate in `PostgresConfig.namespace`. Source,
  unsaved-file and direct project entrypoints resolve the same ownership; the
  single-module emitter refuses an unresolved reference. Tests cover private
  membership, diamonds, cycles, duplicate tables, same-named local and imported
  declarations, empty roots, malformed config, and App capability wiring. They
  caught imported metadata replacing a local entity and omitting its table, and
  legacy config validation accepting private or nonexistent entities. Both are
  fixed with regression cases. V7–V9 now use module references; all nine source
  files pass agent-context. The updated PostgreSQL process run passes, including
  shared rows and transaction pauses. An earlier attempt timed out during fixture
  role creation before application queries; server logs are now retained in the
  failure output. The complete compiler gate passes after correcting older GET/POST
  fixtures that incorrectly listed a plain record in `Database.entities`. The
  PostgreSQL 17 database, replica and crash cases pass; pooler cases also pass after
  supplying the installed PgBouncer path. Optional test dependencies are now checked
  before cluster setup. History/executor integration remains pending. The later
  import-boundary slice below implements the general MIG015 refusal.
- A storage-identity review found that distinct Tesl fields such as `userID` and
  `userId` map to one SQL column, and overlong PostgreSQL identifiers can silently
  truncate. Validation and emission now share the column-name conversion; checks
  reject these collisions and overlong/NUL table names, including private schema
  members. Focused tests pass for ASCII and Unicode byte boundaries, acronym and
  underscore aliases, and names that grow during conversion. The whole ownership
  projection is also checked for explicit index-name collisions across modules.
  The expanded compiler gate passes, including all seventeen migration import,
  ownership and source-freeze groups. The private-index case checks that the
  diagnostic identifies both declaring modules.
- PostgreSQL tests interpose retirement between a read and its admission, for old
  and surviving versions and six query forms: rows, a missing key, constant false,
  LIMIT 0, an empty aggregate, and EXISTS. They verify that contract DDL
  waits for the reader's transaction and that backend termination before/after commit
  rolls back/preserves the floor and lifecycle evidence together.
  Disposable primary clusters also pass immediate-shutdown/WAL-recovery cases on
  both sides of that commit, followed by exactly-once coordinator resumption.
  Nightly/manual matrix runs select matching-major server binaries for these
  owned clusters; they never stop the shared matrix service or a developer server.
  A paused physical replica also demonstrates stale admission and physical schema
  across retirement/DDL, then catches up to both. This is a protocol counterexample
  to replica-local admission, not support for routing application reads to replicas.
- Private PgBouncer session/transaction fixtures pass on PostgreSQL 17 and are wired
  into the PostgreSQL major-version CI matrix. The transaction case forces backend
  reuse and checks that fences and refused transactions do not leak. These exercise
  the protocol oracle; generated runtime admission remains pending.
- The independent TLA+ admission/contract kernel passes exhaustive finite checks:
  1,404 states for three-version admission and 6,288 for two-version queue attempts.
  Seven deliberately broken protocols must produce their specific invariant or
  action-property counterexample. Mutation testing caught an initially unreachable
  transforming-expansion branch in the model; it now exercises both expansion
  forms. The locked Nix toolchain, root CI and dedicated workflow run this gate.
  Production correspondence, complete INV/TR mappings and both reviews remain
  pending; finite model checks do not establish unbounded progress or PostgreSQL
  implementation correctness. See `dev-docs/models/README.md` for assumptions.
- The complete root CI gate is not yet green. Its generated Memory-only analyzer
  failure was fixed by moving renewal logic into the PostgreSQL runtime file.
  The full compiler regression suite passed after the fixture split and project-wide
  binding changes and again after qualified-pattern, canonical wire and typed-node
  capture changes, then again after statement-position let capture and typed IR.
  The subsequent generic-type encoding adjustment passes its focused suite. The full
  PostgreSQL harness, runtime lint gate, and direct compiler test-command regressions
  pass. Local gate runs disable
  Go VCS stamping because the sandbox exposes an empty `/tmp/.git` mount.
  A later run exhausted disk space; only this task's disposable Go cache was removed.
  Its replacement compiler run passed the language suites but timed out in one
  mutation baseline while rebuilding the cache; the isolated warmed-cache rerun
  passed all four mutation tests. The latest queue decoder attempt-ownership fix
  also passes the complete runtime lint gate.
  Running the compiler suite concurrently with PostgreSQL later saturated host I/O;
  PostgreSQL timed out in WALWrite. The isolated rerun passed the full protocol
  harness, compiled applications and both pooler modes in 35 seconds. Keep these
  disk-heavy local gates sequential.
  A subsequent complete compiler run exposed Alcotest's shared `latest` symlink
  race between emission shards. Each shard now uses its own log directory and
  the complete compiler suite passes. Old entries in this task's disposable Go
  cache were pruned when disk filled again; source files and other caches were
  left intact.
  The later full PostgreSQL harness passes in 51 seconds with repair, index,
  quarantine-model, pooler, primary recovery and replica cases; runtime lint is
  clean. The standalone schema-boundary change passes its focused compiler suite
  and the complete compiler gate. That gate caught an auth proof fixture living
  in a schema namespace; it now uses an application module and still checks
  proof-specific refusals. All nine V7/V8/V9 fixture files also pass direct
  `agent-context` checks with zero diagnostics.
  The PostgreSQL 17 nightly-length run also passes (107 seconds): 512,000 model
  operations plus poolers, owned primary crashes and a lagged replica. The matrix
  now verifies the actual connected PostgreSQL major, including owned clusters.
  The later complete local matrix also passes on PostgreSQL 14.23 (85 seconds),
  15.18 (86 seconds), 16.14 (93 seconds), 17.10 (89 seconds), and 18.4 (88 seconds).
  Every lane includes the race detector, compiled fixture applications, both
  PgBouncer modes, a lagged replica and owned-cluster crash recovery. Matching-major
  tools initialise, back up and restart each cluster. These functional results do
  not satisfy the separately pinned performance gate.
  The bootstrap/contract extension passes the full PostgreSQL harness in 62 seconds
  and lint with zero issues. Subsequent lifecycle identity guards pass the focused
  PostgreSQL bootstrap, contract, repair and control-template tests in 21 seconds.
  After the migration-module boundary change, the complete compiler gate and doc
  integrity gate pass again. The complete PostgreSQL suite with lifecycle identity
  fixes, all compiled fixtures, poolers, replica and owned-cluster crash cases also
  passes (89 seconds).
  The subsequent catalog slice passes on PostgreSQL 14–18, including the native
  NULLS NOT DISTINCT identity cases on 15–18. Runtime lint remains clean. The manual
  coherence gate found the new ledger's missing audience banner; after adding it,
  that gate also passes. These checks still leave the complete root CI and both
  feature-wide reviews pending.
  Whole-application ownership and new unsaved-file checking then pass the complete
  compiler gate, the manual coherence gate and all nine fixture agent-context checks.
  The following full PostgreSQL 17 run, including the target-write ABI model, passes
  in 56 seconds with poolers, replica and owned-primary crash cases; lint is clean.
  The subsequent schema-reference corpus refresh also passes Kanel's seven API
  tests through the public CLI. Imported queries now honor the application's
  database binding; the refreshed Kanel snapshot includes its PostgreSQL statements
  and decoders. Registry membership refusal tests pass on PostgreSQL 14, 16, 17 and
  18, including indirect and NOINHERIT membership and a temporary installer role.
  The migration package lint gate passes with those membership checks included.
  The JSONB storage slice passes the complete compiler suite, runtime race suite,
  full runtime lint and manual coherence check. The 192-file snapshot refresh
  changes Kanel's imported ADT helper names and reuses its declared InvoiceStatus
  encoder; its direct and API suites pass. The first combined
  PostgreSQL 17 run with JSONB cases fails only during the owned replica's backup
  setup deadline; the isolated replica test subsequently passes in seven seconds.
  This is recorded as a setup failure, not a successful combined gate.
  A subsequent combined run exposed the per-request process exit cost in the new
  JSONB trace. After switching to coexisting app processes, the full PostgreSQL 17
  harness passes in 95 seconds, including the compatible codec bridge, PgBouncer
  modes, replica and owned-primary crash tests. The race detector remains enabled
  and the existing fixture deadline is unchanged. Migration-package lint is clean.
  The final JSONB app trace, including the compatible bridge and late old-writer
  counterexample, also passes on PostgreSQL 14 and 18. A second codec-ownership
  review removes redundant inherited metadata copying, and the complete compiler
  suite passes again. These are completed slice checks; the delivery table above
  still records the remaining implementation and feature-wide review gates.
  The next compiler run, with field-impact tests, found two unrelated tuple-arity
  failures. An isolated regression established the cause: import suggestions
  parsed an unimported malformed sibling and replaced the real type diagnostic
  with its lexer error. Discovery now skips lexer-invalid candidates, while
  checking the broken source still fails. The suggestion tests and original
  tuple/type regression suite pass. Test directories now use unique temporary names
  and cleanup; PID reuse previously caused collisions on repeated isolated runs.

## Implementation decisions

The authoritative target-mechanisms table remains the baseline except for the
execution-model decision below. Computed columns initially use
materialisation, and their introducing-version SQL restrictions remain in force.
The speculative overfetch refinement is not part of the initial implementation.

Execution model (maintainer preference, 2026-09-05): record the compiler ABI rather
than freezing stdlib implementations or retaining historical lowerings. Record
`processing_abi` atomically with the first processed batch or application write at
the target generation. A different ABI may be selected only before either kind of
write and before any provisional pass;
after that, it is refused. Recovery uses the original ABI executor or a new entity
generation that reprocesses every row. Frozen source closure hashes still detect
edited history. Catch-up records one ABI for every replayed version. The superseded
frozen-slice passages in the original proposal require reconciliation in phase 3.
That reconciliation must also cover persisted proofs and `Same`: locking an ABI
for backfill batches does not justify interpreting facts established by another
ABI as facts under the current one. A new-generation recovery must re-establish
those facts without trusting an old proof under changed semantics. Until that
boundary is specified and checked, the execution-ABI model is only a consistency
oracle, not an end-to-end proof of cross-compiler migration soundness.
The model now distinguishes a committed target-generation application write from
backfill progress. It locks the ABI even when `rows_done` is zero and no provisional
pass exists, requires that application's admitted fence, survives a crash and rejects
a different ABI in another entity or pass. The actual write/ABI transaction and
persisted-proof typing remain production gates.

The permanent entity generation is a PostgreSQL `smallint`; generation 32767 is
the last legal generation. Generation allocation refuses overflow before producing
an edit manifest or executing DDL. Schema versions are positive signed 32-bit
integers; 2147483647 is reserved for the boot fence and cannot be allocated.

Module references are contextual to `Database.schema` and `Database.migrations`,
as specified in section 1. They cannot escape into ordinary value expressions.
The schema's import closure defines membership, including unexported entities.

Tests must distinguish executable coverage from planned coverage. In particular,
passing a model test does not demonstrate that PostgreSQL obeys that model, and
local microbenchmarks do not satisfy the pinned-environment latency release gate.

## Baseline observations

- The tree initially has a user move of `reduce_keywords.md` from `next` to `later`.
- The compiler builds using `nix develop --command …`.
- Existing queues and email outboxes already have random claim tokens and stale
  outcome regression tests. Monotone attempts, fenced renewal, versioned codecs,
  and retirement remain separate requirements.
- PostgreSQL 14–18 and PgBouncer are available locally; the complete functional
  matrix, including owned primary/replica clusters, passes. The pinned performance
  environment remains a separate, unfulfilled gate.
