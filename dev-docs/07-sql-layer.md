# 07 — SQL Layer: Entities, Parameterized Queries, Newtype Coercion

> Audience: contributors working on the SQL runtime layer (`dsl/sql.rkt`).

The SQL layer lives in `dsl/sql.rkt`. It bridges Tesl's GDP proof system with
PostgreSQL (and provides an in-memory fallback for tests).

---

## Entity macro: `define-entity`

When the compiler encounters an `entity` declaration:

```tesl
entity Note table "notes" primaryKey id {
  id:        NoteId @db(text)
  title:     String @db(text)
  createdAt: PosixMillis
}
```

It emits:

```racket
(define-entity Note
  #:table "notes"
  #:primary-key id
  [Id        id        : NoteId     #:db-type text]
  [Title     title     : String     #:db-type text]
  [CreatedAt createdAt : PosixMillis])    ; no #:db-type — auto-mapped
```

The `define-entity` macro (in `sql.rkt`) creates:

- `Note-id-field`, `Note-title-field`, `Note-createdAt-field` — `field-spec` structs
- `Note-id`, `Note-title`, etc. — accessor functions returning the field-spec
- `Note?` — a predicate that checks if a hash has all required fields
- Registers `Note` as a runtime type

### `field-spec` struct

```racket
(struct field-spec
  (entity      ; symbol: 'Note
   proof-name  ; symbol: 'Id, 'Title, etc. (for GDP proofs)
   key         ; symbol: 'id, 'title, etc.
   type        ; type-datum: type-ref or symbol (for Maybe fields, this is the inner type)
   primary-key?; bool
   column      ; symbol or #f (defaults to snake_case of key)
   db-type     ; symbol or #f (from @db annotation)
   nullable?)  ; bool — true when the Tesl field type is (Maybe T)
  #:transparent)
```

`nullable?` is `#t` when the entity field is declared as `Maybe T` in Tesl. For these fields:
- The SQL column is created as `<inner-type> NULL` instead of `NOT NULL`.
- On read, SQL `NULL` → `(Nothing)` runtime value; non-NULL → `(Something v)`.
- On write, `Nothing` → SQL `NULL`; `Something v` → the inner value.
- The `type` field stores the *inner* type (e.g., `'String` for `Maybe String`).

### DB type annotation resolution

`field-db-type-annotation` determines the PostgreSQL column type for a field:

```racket
(define (field-db-type-annotation field)
  (or (field-spec-db-type field)           ; explicit @db(bigint) → 'bigint
      (default-field-db-type-annotation field)
      (error "needs explicit #:db-type")))

(define (default-field-db-type-annotation field)
  (define type-datum (field-spec-type field))
  (or (hash-ref built-in-db-type-registry type-datum #f)   ; String → text
      ; Newtype lookup: PosixMillis → Integer → bigint
      (let ([base (hash-ref newtype-registry type-datum #f)])
        (and base (hash-ref built-in-db-type-registry base #f)))
      (and (field-adt-type? field) 'jsonb)   ; ADT fields → jsonb
      #f))
```

The newtype lookup path handles `PosixMillis` (and any user-defined newtype
wrapping a built-in type) without requiring an explicit `@db` annotation.
For `nullable?` fields (`Maybe T`), the annotation is computed from the inner
type `T` and the column is emitted as `<type> NULL` in `CREATE TABLE`.

---

## Parameterized SQL queries

All user-supplied values go through `$1`, `$2`, … placeholders. The key is
`compile-predicate-sql`:

```racket
(define (compile-predicate-sql predicate index)
  ; Returns: (sql-fragment, list-of-params, next-index)
  (match predicate
    [(eq-predicate field operand)
     (values (format "\"~a\" = $~a"
                     (field-column-name field)
                     index)
             (list (field-runtime-value->db-value field operand-value))
             (add1 index))]
    [(comparison-predicate field operator operand)
     ...]
    [(or-predicate left right)
     ...]))
```

`compile-where-sql` accumulates multiple predicates:

```racket
(define (compile-where-sql predicates [start-index 1])
  ; Returns: (" WHERE col = $1 AND col2 = $2", params, next-index)
```

Then the actual query execution:

```racket
(apply query-rows conn sql params)
;; e.g. (query-rows conn "SELECT id, title FROM notes WHERE id = $1" "note-123")
```

The `db` library (Racket's database driver) handles parameter binding,
preventing SQL injection structurally.

---

## Reading from the database: `field-db-value->runtime-value`

When a row is read from PostgreSQL, each column's value is processed:

```racket
(define (field-db-value->runtime-value field value)
  (cond
    ; ADT field (stored as jsonb) → deserialize to adt-value
    [(field-adt-type? field)
     (jsexpr->typed-value (field-spec-type field) ...)]
    ; Newtype field (e.g. PosixMillis) → wrap in newtype
    [(hash-ref newtype-registry (field-spec-type field) #f)
     (jsexpr->typed-value (field-spec-type field) value 'sql)]
    ; Plain value → return as-is
    [else value]))
```

The `jsexpr->typed-value` for a newtype calls `(PosixMillis value)` or
`(UserId value)` to wrap the raw DB value.

---

## Writing to the database: `field-runtime-value->db-value`

The reverse: unwrap any Tesl value to a plain DB-compatible value:

```racket
(define (field-runtime-value->db-value field value [who 'sql])
  (cond
    ; ADT → serialize to JSON string
    [(field-adt-type? field)
     (bytes->string/utf-8 (jsexpr->bytes (runtime-value->jsexpr value)))]
    ; Newtype → unwrap to raw value
    [(newtype-value? value)
     (newtype-value-value value)]    ; PosixMillis(123) → 123
    [else value]))
```

---

## FromDb proofs

After a `select` or `insert`, the SQL layer automatically attaches GDP proofs:

```racket
(define (attach-query-proofs entity row predicates)
  (define entity-subject (gensym (entity-spec-name entity)))
  ; For each WHERE predicate (field == operand):
  ;   Creates fact: (FromDb (Id == operand-subject) entity-subject)
  ;   where operand-subject is the gensym of the WHERE value
  (attach-row entity row facts bindings entity-subject))
```

So `selectOne note from Note where note.id == noteId` produces a `Note`
named-value with subject `note-gensym` and fact:
`(FromDb (Id == noteId-gensym) note-gensym)`

This is the proof that the caller's `note` return type `Note ? FromDb (Id == noteId)`
checks at function return time.

---

## Auto-migration on startup

The Go backend resolves entity ownership across the whole project before emitting
queries. `Emit_go.project_entity_bindings` maps each module-qualified entity to the
application's database. Generated query modules resolve the compiled database
identity through `teslrt.ResolveDatabaseIdentity`; application initialization
registers that identity. This avoids an import cycle and keeps connections out of
schema modules. Qualified aliases of the same entity produce one table descriptor.

`Migration_schema` checks standalone schema modules, database-selected schema
families, and their complete import closure. The root module comes from the
current parsed buffer, so an unsaved edit cannot escape through a clean disk copy.
Entities, types, facts, codecs, and pure helpers belong there;
application declarations, connection configuration, effects, and tests do not.
Migration-family modules enforce the same separation while allowing pure record
and fixture constants. They cannot declare entities or import application code;
schema snapshots remain the source of entity ownership.
`Migration_schema.check_ownership` validates the whole parsed application graph:
one database per schema family, no combined families and no historical snapshot
bound to a connection. `Validation_common.resolve_project_entity` is shared with
Go database binding so the checks and queries resolve local and imported entities
consistently. New unsaved application files participate in the same graph checks.
The compiled process fixtures in `runtime/go/internal/migrationtest/testdata/`
exercise separate application, operation, and schema modules against shared
PostgreSQL rows.

`Migration_inventory` loads the complete checked schema closure and provides
field and entity impact projections. Use entity impact when checking a sparse
migration record: comparing fields alone misses table, primary-key and index
changes. Both projections follow nested record/ADT codecs and fact producers.
The internal `verify_same` API compares canonical declaration closures and returns
abstract equality evidence or the differing dependency's source locations.
`same_candidates` proposes equal types, facts and codecs, including private ones.
These APIs require the same compiler ABI; they do not authorize cross-version
proof casts, accept persisted history, classify online safety or execute DDL.
`stored_dependencies` distinguishes an unknown location from a primitive-only
field and returns each stored field's complete owned dependency closure.
`Migration_sparse.check` re-verifies the user-supplied identity pairs and checks
exact entity coverage, including private paths and duplicate aliases. It preserves
missing identities per stored occurrence: a `Same` for a JSONB record cannot hide
an omitted pair for one of its nested facts or codecs. Its result certifies only
coverage; `Additive` still needs a single-adapter check, and `Transform`/`Reset`
still need their row-function/offline checks. Planner classification and execution
integration are pending.
`Migration_additive.check` consumes the exact inventories bound into that coverage
result. It projects existing equal fields, new proof-free `Maybe` fields and
same-typed primitive literal defaults. It refuses field removals, changed contracts,
changed table/primary-key identities, misplaced defaults and invented proofs.
The result contains logical value sources and preserves index-change obligations;
it is not SQL or permission to expand. Nominal/Money defaults still need contextual
elaboration, and PostgreSQL assignments, physical column sets, index safety and
admission remain additional checks.
The source-history layer separately guards input bytes and import resolution.

`Migration_declaration.check` now connects the initial `Migration` source form to
these checks. `Migration_history_sources.adjacent_pair` loads the complete checked
schema chain without rereading the migration body, so an unsaved migration buffer
is checked against its actual text. The source checker validates root ownership,
required fields, sparse entity keys, literal defaults and Same claims. One Same
spelling covers all matching eligible namespaces, including a record and its
same-named codec. Helpers use non-version-root module names; each `Migrate.V<n>`
root requires its declaration. Contextual constants have no runtime value binding.

`Migration_seal` captures the complete checked inventory's raw source digests and
its compiler-bound semantic digest. Source verification checks the owned closure
and canonical import resolution without running an old compiler. Semantic
verification additionally requires the recorded ABI and reruns the full inventory
judgment. These records are committed metadata, not authenticated database history.
`Migration_header` stores predecessor and target seals, preserves surrounding
source on replacement, and verifies that they match the declaration's adjacent
roots. The contextual checker reports MIG001 for changed recorded VCurrent input
and MIG013 for changed frozen input or malformed metadata. It receives the actual
source text from the frontend, so unsaved header changes are not reread from disk.
The declaration result explicitly retains optional source-integrity evidence;
missing headers remain distinguishable from verified ones. A freeze must replace
the target seal after rewriting code references: token rewriting ignores comments.

`Source_input.with_overlays` supplies one read-only source view to import resolution,
the type/proof/validation passes, inventories and history discovery. It supports
new files and parent directories without creating them, so proposed frozen copies
and unsaved private dependencies receive the complete compiler judgment. Scopes
restore their inputs and invalidate semantic caches on normal or exceptional exit.
Paths must be canonical `.tesl` files inside the project; symlinks, special files,
duplicate entries and file/directory conflicts refuse. Input hashes describe that
view. Manifest application still needs separate saved-byte and editor-version
guards. The public manifest CLI is described below; editor application remains pending.

`Migration_manifest` captures saved bytes separately from the active source view,
including read-only dependencies and open-document versions. Parent/discovery
directory hashes and explicit import-resolution preconditions guard inputs that
could change what the compiler reads. Source bytes use hexadecimal in the version-1
JSON transport, preserving even non-UTF8 comments; editor application must check
representability. Manifest construction and verification perform no source writes.
Neither a manifest nor its hash establishes that its proposed source is correct.

`Migration_generate.start` consumes a selected family and current version. It
freezes the complete current closure, retargets the existing migration's code and
unshared helpers, recreates its target seal, and emits the next initially unchanged
Migration record. The entire proposal receives normal compiler checks in a source
view before its manifest is returned. Equal preexisting frozen files are guarded
even if they need no edit. Finalizing a recorded current target requires verifying
its semantic seal with the actual same compiler ABI; supplying an old tag does not
run an old compiler. A stale target selection or changed recorded current source
refuses. Completed migration closures and build ABI identity are checked; manifest
application and the rest of the command family are still required. This
source operation does not authorize DDL, ABI recovery or persisted-proof transport.

Generated Same claims now carry refresh ownership markers. `Migration_provenance`
compares their role-normalized data AST fingerprints and protects edited bodies
and added internal comments. `Migration_source_syntax` binds raw source, parsed AST
identities and tokens in one immutable view. It reparses an addressed expression
and measures the last consumed token, rather than treating broad diagnostic spans
as edit ranges. Unsupported expressions and stale ASTs refuse editing. Literal
collection bounds remain available beside arbitrary user expressions, so a
generated sibling can be edited without replacing the user's container.
`Migration_source_merge` reconciles direct members, removes only matching owned
spans, preserves handwritten bodies/comments and appends marked additions.
`Migration_sparse.requirements` provides complete checked
stored-occurrence obligations before the generator selects entries, and
`check_requirements` retains the same coverage judgment as `check`.

`Migration_generate.refresh` reads the declaration structurally through the same
`Migration_declaration.read_syntax` used by checking. It verifies completed schema
seals and the frozen predecessor, then refreshes an undeployed current target seal and
its generated Same/entity entries. A surface Same covering a record and its codec
requires both namespaces to match; deliberately omitted Same claims are never
auto-filled. Entity identities include the actual source key, so an edited alias
protects the entry. Requirements select New, Drop and checked additive adapters.
Unsupported decisions become contextual `todo` entries with MIG003; user-owned
stale entries stay and receive the ordinary diagnostic. Identical causes at one
Same location are reported once even if multiple namespaces fail there.

The preview includes full compiler diagnostics over the proposed view. Holes,
invalid user helpers and stale rules cannot pass as a compilable migration. The
same source/disk/import/directory/document guards used by start protect refresh;
neither operation writes files. General row-function holes, transformations,
public target/CLI/editor integration and atomic apply/recovery remain pending.

`Migration_closure` records the raw SHA-256 of a completed migration and every
transitive private migration helper. The root excludes only its own closure block;
its schema seals, comments and tests remain covered. Helpers are hashed byte for
byte. Start retargets all source first, then captures the completed closure in its
proposed view. Current references cannot enter a completed closure. Verification
checks canonical regular paths, exact bytes and import membership/resolution.
Direct helper queries, unsaved buffers and parse-error paths retain MIG013 for
changed source; application checking and start/refresh refuse it too. Removing
metadata from a completed declaration also refuses. Shared unchanged helpers can
be reused without rewriting them. Metadata can be edited together with source, so
persisted runtime history must still supply the independent execution backstop.

`Migration_application` makes declared database history a checking dependency of
the full application. It discovers current and completed edges, requires their
schema seals, and checks migration bodies and private helpers through the shared
frontend. Ordinary and implicit imports share dependency de-duplication and the
CLI batch skip predicate. Unsaved source views and whole-project editor snapshots
reach these checks. The callback restores unit aliases around nested checks and
adds no runtime imports or application names. Missing current migrations,
unresolved decisions and invalid history refuse Go emission as well as checking.
This validates source; it does not attest a persisted execution ABI.

`Migration_target` resolves an explicit application entry and a unique database
from its local import graph. A short database name is accepted only when unique;
otherwise the caller must select the module-qualified owner. Imported connection
owners remain application concerns. Legacy `entities:` configurations need the
separate ownership upgrade, and duplicate family owners refuse even with an
explicit selection. Resolution checks schema ownership and history inventories,
not the complete application or deployment state.

Target-bound start/refresh combine the original selection guards with generation
guards through `Migration_manifest.combine`. Composition never re-captures the
selected application's bytes: changed bindings, imported owners, resolution,
directory membership and document versions must invalidate the preview. Shared
guards/edits are deduplicated, conflicting preconditions and competing edits
refuse, and combined output paths are validated in a source view. Workspace
entry discovery/preferences and atomic source application remain integration work.

`Migration_abi` computes `tesl-source-abi-v1:<sha256>` from Dune-staged compiler
inputs, OCaml version, the embedded Go runtime, and the selected lifted stdlib
bytes. It does not read a Git revision or a development checkout at runtime. The
stdlib is captured with its module resolution and pinned during generation;
resource changes still present after checking invalidate the result. Temporary
changes followed by restoration cannot mix resource versions: the callback always
uses the captured bytes. This is a
conservative source identity, not yet the persisted processing ABI: executor,
Go toolchain and cross-ABI proof admission remain separate production obligations.

`Migration_preview` captures that context, selects the database, starts or
refreshes the revision, and checks the complete proposed application. It rechecks
the source/disk/document guards and compiler resources before returning. The
public compiler and native CLI expose it through `tesl migrate generate <entry>
--manifest-json [--database D] [--new-revision]`. Default generation starts V2 for
a new family and otherwise refreshes; starting another revision is explicit.
Selection follows the schema file actually imported by the connection owner,
including nested projects. An explicit `--project-root DIR` must name the same
schema history root. Enclosing Git/project markers cannot select another copy.

The version-1 `migration-source-preview` envelope contains `ok`, `operation`,
`compilerAbi`, `compilable`, selection metadata, complete application diagnostics
and `manifest`. Exit 0 means a preview was produced; `compilable: false` preserves
unresolved MIG003 decisions or application errors. Failure exits 1 and returns
`ok: false`, errors with database candidates, and `manifest: null`. Neither exit 0
nor a compilable proposal is a physical database plan or execution authorization.

Editor callers may add repeated `--overlay FILE VERSION CONTENTS_FILE` arguments
with `--project-root`. FILE is the canonical source path, VERSION is a signed
32-bit document version, and CONTENTS_FILE supplies the exact buffer bytes from a
regular file. Overlay-only entries and directories are supported without writes.
Their saved-byte and version guards remain independent.

Plain native `tesl migrate generate` now consumes the same preview through the
Go `internal/sourceedit` package. On Linux it applies saved files with guarded
atomic exchange/no-replace publication and a durable inverse journal. It refuses
open buffers and stale sources. `tesl migrate recover-source --project-root DIR`
resumes interrupted restoration or terminal cleanup. The result separately reports
source success, compilation diagnostics, and transaction outcome. See
[migration source writes](migration-source-writes.md) for the protocol, concurrency
and crash guarantees. Other-platform mutation, editor commands and the remaining
migration verbs are pending.

`tesl migrate plan` now derives a read-only PostgreSQL expansion history from the
selected application's complete checked sources. It retains dropped storage,
plans index work with compatibility obligations, and refuses unresolved semantic
changes even when the SQL carrier is unchanged. The actual application must pass
Go emission, including its storage codecs. See
[migration planning](migration-planning.md). Live catalog comparison and execution
are still pending; the report explicitly has `executable: false`.

`Parser.parse_module` reports lexer failures at the failing source file, including
imported buffers. `Frontend_check` owns diagnostics, the type/proof/validation
pipeline and dependency checks. `Compile` adds the migration judgment to the entry
and imported modules; schema inventories use the same base checks without an emitter
dependency. This avoids a weaker schema checking path or a compiler dependency cycle.
Recorded source integrity also reaches direct schema queries and application
imports, including private-only imports. The check derives revision ownership from
canonical paths, so a renamed or malformed module header cannot hide an edited
frozen input. Each reachable revision is checked once; migration declarations use
their actual source buffer instead of re-reading a saved header. Direct and app
queries anchor integrity errors in the queried file and retain the recorded header
and changed dependency locations. Structured LSP related information remains pending.
The current declaration result is still a logical adapter. A complete executable
history must require seals on every edge and verify persisted ABI identity,
transformation typing, physical planning and admission before a database transition.

The following startup notes describe the legacy bootstrap, not the versioned
migration executor being developed; delivery status is tracked in
[the migration implementation ledger](migrations-implementation.md).

The catalog test harness uses same-server parsing/deparsing for expected and live
expressions, with matching types and collations on disposable temporary tables.
Do not infer harmless defaults from `::type` syntax: a user-defined cast can execute
a function while deparsing that way. Nor does a domain column's plain text default
exclude constraints on assignment. The fixture's conservative scalar-constant
recognizer and column checks cover these cases, including typmod failures, without
evaluating computing defaults. Production catalog reconciliation remains pending.

`ensure-database-ready!` runs when a database is first connected (`call-with-database`, which `main`'s `App { database: X }` lowers to):

1. `(create schema if not exists schema-name)` — creates the schema
2. For each entity: `postgres-ensure-entity!`
   - If table doesn't exist → `CREATE TABLE IF NOT EXISTS`
   - If table exists → compare columns, add missing NOT NULL columns if table is empty, verify types match
3. `ensure-queue-tables!` — creates `tesl_jobs` and `tesl_pubsub_outbox`

---

## Transaction support

The Go runtime binds an explicit transaction to both its goroutine and the opened
PostgreSQL database. Query, write and pub/sub executors refuse a different database
before issuing SQL; a nested `with database` scope also refuses before opening its
pool or running bootstrap. Nested transactions are rejected before borrowing a
connection, including with a one-connection pool. This identity is a prerequisite
for applying migration admission and fences to the correct logical database.

`(call-with-queue-transaction thunk)` in `queue.rkt` wraps a database
transaction. Inside a `transaction { }` block:
1. `call-with-transaction conn thunk` opens a real PostgreSQL transaction
2. Queue `enqueue!` and pub-sub `publish-event!` calls defer their `pg_notify`
   to commit time using a `deferred` box
3. On commit, NOTIFY fires, waking LISTEN threads in other processes

---

## In-memory fallback

When `current-database-runtime` is `#f` (no database context), the SQL
operations fall back to in-memory hash tables. Entity operations use
`entity-spec-source` — a mutable hash provided at entity definition time
(or `#f` for production entities that require a real DB).

Tests can provide an in-memory source:

```racket
(define-entity TestNote
  #:source (lambda () (make-hash))  ; fresh hash each time
  #:primary-key id
  [Id id : String]
  [Title title : String])
```
