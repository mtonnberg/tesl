# IR-1: Full Semantic Layer

## Context

This item should describe the next semantic-infrastructure step for the current compiler/editor stack, not a speculative post-rewrite system.

The current state is:

- the OCaml compiler is already the active frontend
- the compiler can parse, type-check, lint, format, and emit JSON diagnostics
- the editor stack is split between:
  - VS Code extension: `editor/vscode-tesl/extension.js`
  - Racket LSP server: `editor/tesl-lsp/tesl-lsp.rkt`
  - OCaml compiler invoked via `--check-json`
- the current Racket LSP already provides diagnostics, hover, go-to-definition, references, and rename
- one-shot compiler queries now exist: `--definition-json`, `--occurrences-json`, and
  `--type-at-json`; the LSP uses these for definition, references/occurrences, and rename
- the `--ir` flag emits an AST-level JSON schema used for code generation, not semantic queries
- those features are per-request compilations — no retained semantic state exists between requests
- those editor features are not backed by a first-class retained semantic model inside the compiler

That means IR-1 is no longer about enabling a new compiler rewrite. It is about replacing one-shot checking and editor-side heuristics with compiler-retained semantics and queryable program knowledge.

---

## Goal

Introduce a retained semantic layer inside the OCaml compiler that preserves enough information about the program to answer semantic queries directly, incrementally, and correctly.

IR-1 should become the foundation for:

- compiler-backed rename
- compiler-backed references
- type-driven completions
- compiler-backed field diagnostics
- richer hover
- incremental re-checking
- better editor responsiveness

This is not just a new internal data structure. It is the boundary that turns the compiler from a one-shot checker into a reusable semantic engine.

---

## Why this still matters

The current tooling stack proves that the compiler/editor integration works, but it also shows the limits of the current shape:

- `compiler/lib/compile.ml` is still essentially a one-shot pipeline per request
- one-shot queries (`--definition-json`, `--occurrences-json`, `--type-at-json`) exist but each
  triggers a full compile — there is no retained state between requests
- the Racket LSP still has to do some editor-side reasoning on its own (e.g., hover heuristics)
- `field_at` / field-target semantic queries and type-driven completions do not yet exist
- retained semantic state, module cache, and stable node identity do not yet exist

Without IR-1, advanced tooling either stalls or grows via duplicated logic in the editor layer.

IR-1 is the point where Tesl starts treating semantic knowledge as retained compiler state rather than recomputed transiently for each operation.

---

## What IR-1 must represent

IR-1 should retain enough information to answer semantic queries that the current editor stack cannot answer correctly or cheaply.

### Declarations

It should retain:

- modules
- imports and import resolution
- functions, handlers, workers, checks, authers, and establish declarations
- records, entities, ADTs, constructors, codecs, capabilities, and other named declarations
- declaration spans and declaration identity

### Expressions and types

It should retain:

- expression nodes with stable identity
- resolved/inferred types
- source spans
- enough structural context to recover the role of an expression inside its parent

### Use sites

It should retain:

- resolved names
- declaration/use-site links
- import-origin links where relevant
- all occurrence information for rename/references

### Expectation context

It should retain the expectation metadata defined by Item 04 once that checker work lands:

- expected type when known
- why that expectation existed
- where it came from

This is one of the main reasons Item 04 should stabilize before IR-1 implementation hardens.

### Proof flow

For Tesl-specific semantic tooling, IR-1 should eventually retain:

- proof/fact attachment points
- proof-producing declarations
- proof-relevant flows that matter for diagnostics and explanation

This does not require solving all proof UX at once, but the schema should leave room for it.

### Capability sets

IR-1 should be able to retain capability requirements and capability use sites well enough to support future capability-aware tooling.

### SQL shape

IR-1 should retain enough semantic information about queries and entities to support future query hover, field checking, and related database tooling.

---

## Architecture

### 1. Retained compiler state, not one-shot recomputation

Today the compiler is centered around one-shot operations. IR-1 should introduce retained semantic state that outlives a single diagnostic request.

That does not mean committing to one specific long-running server shape immediately. It means designing the semantic layer so it can be reused across operations rather than rebuilt from scratch as an implementation accident.

### 2. Module cache

IR-1 should include a cache keyed by module/file identity and invalidation rules that make incremental re-checking possible.

The cache should be driven by semantic dependencies, not just raw file timestamps.

### 3. Query-first design

The internal data structures should be designed from the query API backwards.

The right first question is not "what tree do we want to store?" The right first question is "what must the compiler be able to answer correctly for the editor and CLI?"

### 4. Compiler-owned semantics

Semantic truth should live in the compiler, not in duplicated LSP heuristics.

The editor layer should become a transport/adaptation layer over compiler-provided semantics, not a second semantic engine.

---

## Query API

IR-1 should be designed around a concrete query surface.

The near-term high-value queries are:

- `definition_at(file, line, col)`
- `hover_at(file, line, col)`
- `all_occurrences(file, line, col)`
- `type_at(file, line, col)`
- `field_at(file, line, col)` or equivalent field/type semantic query
- `diagnostics_for(file)` backed by retained semantic state rather than a fresh whole-pipeline run

Possible later queries include:

- capability queries
- proof/fact provenance queries
- SQL/entity shape queries
- completion queries that need expected-type context

The exact transport format can evolve, but the semantic contract should be designed early.

---

## Relationship to the current editor stack

The current Racket LSP in `editor/tesl-lsp/tesl-lsp.rkt` should be treated as the present integration layer, not as the long-term owner of semantic logic.

That means:

- hover and definition can continue to work during the transition
- code actions can land before full IR-1 if compiler fix payloads exist
- advanced semantic features should migrate toward compiler-backed queries rather than richer LSP heuristics

IR-1 does not require deleting the Racket LSP immediately. It requires changing what the LSP depends on.

---

## Relationship to other roadmap items

### `roadmap/next/01-fix-bool-return-type.md`

Item 01 should land early enough that retained semantic data, hover text, rename results, and future compiler-generated fixes all reflect the canonical surface language rather than legacy aliases.

### `roadmap/next/04-add-bidirectional-type-checking.md`

IR-1 should be built on the final checker shape, not on a temporary inference-only architecture.

In particular, expectation metadata from Item 04 should be designed into IR-1 rather than bolted on later.

IR-1 design can proceed in parallel with Item 04. IR-1 implementation should not freeze retained typing metadata until Item 04 stabilizes.

### `roadmap/next/05-improved-tooling.md`

Item 05 now splits into:

- near-term integration work that can happen before IR-1
- advanced semantic tooling that should be built on IR-1

Rename, type-driven completions, compiler-backed field diagnostics, and references are all much cleaner once IR-1 exists.

### `editor/protocol.md`

The existing protocol remains the current compatibility contract. IR-1 may eventually drive richer queries and transports, but those changes should be deliberate follow-on work, not accidental breakage.

---

## Design prerequisites

These can begin before full implementation:

- [x] 1. Write the current-state semantic gap clearly.
   Documented in this file, `roadmap/next/05-improved-tooling.md` (completed vs remaining slices),
   and `roadmap/next/01-05-item-plan.md`. One-shot query capabilities and their limitations are
   now described.

- [x] 2. Write the IR-1 schema draft.
   **Implemented**: `tesl --semantic-json <file>` emits version-1 module semantic snapshot JSON
   (`compiler/lib/compile.ml`, `semantic_json_of_module`).  The snapshot retains: module name,
   content hash (for cache invalidation), all record/field types, all ADT/constructor/field types,
   all function/handler/worker/check/auth/establish declarations with kind and declared signature,
   all local binding metadata with location, and all expression types with spans.  This is the
   concrete first step toward retained compiler semantics: the schema is now live and queryable.

- [x] 3. Define the first query set.
   The one-shot query surface is now: `--type-at-json`, `--definition-json`, `--occurrences-json`,
   `--local-bindings-json`, `--semantic-json`.  `--field-at-json` and `--completions-json` are the
   next two queries (see Item 05 remaining slices).

- [ ] 4. Record a baseline.
   Measure current per-file and multi-module checking behavior so IR-1 can later be judged against a real baseline rather than vague expectations.

---

## Implementation phases

### Phase 1 — Design and boundary definition

- semantic gap audit
- IR schema draft
- first query API draft
- baseline measurement
- explicit decision on what remains in the LSP versus what moves into compiler queries

### Phase 2 — Retained semantic foundation

- core retained semantic data structures in OCaml
- declaration and expression identity model
- module cache and invalidation rules
- retained typing metadata
- retained declaration/use-site links

This phase should begin only after the Item 04 checker metadata is stable enough to retain.

### Phase 3 — Query support

- implement the first compiler semantic queries
- make diagnostics queryable from retained state
- expose definition/hover/type/occurrence queries through a stable boundary

### Phase 4 — Tooling migration

- move rename onto compiler-backed occurrences
- move type-driven completions onto compiler-backed type queries
- move field diagnostics away from editor heuristics
- add richer semantic tooling such as references and capability-aware queries

---

## Non-goals

- Treating IR-1 as only an editor feature
- Rebuilding semantic logic inside the LSP instead of the compiler
- Freezing an IR schema before Item 04 stabilizes the checker metadata worth retaining
- Solving every future semantic/tooling feature in this one item

---

## Success criteria

- [x] `roadmap/next/03-ir-1-semantic-layer.md` reflects the current OCaml compiler + Racket LSP architecture
- [x] IR-1 is framed as retained compiler semantics, not as a leftover rewrite placeholder
- [x] the first query set is defined explicitly (`--type-at-json`, `--definition-json`, `--occurrences-json`, `--local-bindings-json`, `--semantic-json`; `--field-at-json`/`--completions-json` next)
- [x] IR-1 design accounts for expectation metadata coming from Item 04 (mentioned in schema; `expr_types` array in snapshot carries inferred types for all expressions)
- [x] the roadmap clearly separates near-term tooling integration from IR-1-dependent semantic tooling
- [x] rename, references, type-driven completions, and compiler-backed field diagnostics are all planned against compiler-owned semantics rather than editor duplication
