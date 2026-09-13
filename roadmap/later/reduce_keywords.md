# Reduce reserved words without hiding semantics

> **Status: design roadmap, not yet approved for implementation.** The first three
> phases preserve existing source syntax and semantics. Any visible grammar change is
> a separate, evidence-gated decision.

## Summary

Tesl should reduce accidental lexical reservation and arbitrary syntax exceptions,
but **the smallest keyword count is not the goal**. The goal is a language with fewer
concepts and fewer special cases, where syntax still makes proof, capability, schema,
routing, and execution boundaries visible.

The current lexer gives special tokens to **76 source spellings**: 74 entries in
`compiler/lib/lexer.mll` plus `api-test` and `load-test`. That number is not a useful
measure by itself. It combines:

- structural syntax such as `module`, `import`, `let`, `if`, and `case`;
- semantically privileged declarations such as `check`, `auth`, and `establish`;
- domain declaration and clause words;
- literals;
- compatibility aliases and rejected legacy syntax;
- ordinary standard-library constructors, types, and functions.

Those categories should not all have the same lexical treatment. The recommended
sequence is:

1. Inventory and classify every special spelling from one compiler-owned source.
2. Stop reserving ordinary library names, dead words, and locally unambiguous clause
   words while preserving the current source spelling and AST.
3. Make contextual parsing, recovery, diagnostics, completion, hover, and semantic
   highlighting strong enough that demotion improves rather than hides discoverability.
4. Consider one visible surface-syntax pilot only if measured human and LLM tasks show
   that a duplicated declaration pattern is a real obstacle.

Do **not** revive the previously deferred proposal to collapse every block onto one
annotated-record grammar. That is a large breaking redesign, not a keyword cleanup.

## The three separate questions

This work must keep three axes distinct:

| Axis | Question | Example | This roadmap |
|---|---|---|---|
| lexical reservation | May this spelling be used as an identifier outside its special context? | `index` is contextual; `schema` is currently reserved | primary scope |
| surface patterns | How many declaration and expression shapes must a user learn? | `database D = Database { ... }` repeats the kind on both sides | possible later pilot |
| compiler core | How many primitive AST/emitter forms implement the language? | effect forms lowering to `ERuntimeCall` | out of scope; see `roadmap/completed/reduce_language_size.md` |

Demoting a hard keyword to a contextual word can preserve every program byte for byte.
Conversely, replacing `database D = Database { ... }` with a record-looking binding is a
surface redesign even if it removes only one token.

## Review of the current surface

### What already works

Tesl already demonstrates that contextual syntax can be clear and safe:

- HTTP methods (`get`, `post`, `put`, `delete`, `patch`) are ordinary identifiers
  recognised in handler position. A handler may still be named `get`.
- Entity clauses such as `index`, `unique`, and `as` are recognised by position and do
  not reserve useful field or variable names.
- SQL words are ordinary application identifiers recovered structurally by the SQL
  checker rather than globally reserved.
- `agent` and `secret` are contextual top-level declaration words selected with
  lookahead.

This is the model for lexical simplification: retain the meaningful source form, but
reserve a spelling only when local context cannot identify it reliably.

### What is inconsistent today

The lexical table currently mixes public syntax and implementation conveniences.
The first inventory must verify and dispose of at least these cases:

| Class | Current spellings | Initial disposition |
|---|---|---|
| ordinary stdlib constructors | `Nothing`, `Something` | demote to imported identifiers; preserve constructor precedence and import diagnostics |
| ordinary stdlib type | `PosixMillis` | demote to an imported type identifier |
| ordinary stdlib functions | `forgetFact`, `detachFact`, `attachFact` | demote to imported function identifiers |
| stale or questionable library name | `extractFact` | verify whether it has any supported surface; remove or demote, never reserve it only for parser convenience |
| config record fields | `backend`, `schema`, `smtp` | demote; fields should not need token-specific exceptions |
| likely dead reservation | `workers` | verify corpus/parser use, then remove; worker mappings are folded into `Queue` |
| rejected legacy syntax | `const` | stop globally reserving it; retain a targeted diagnostic only for the old declaration shape if needed |
| rejected legacy pragma payload | `tesl` | stop globally reserving it; `#lang` already identifies the legacy pragma |
| compatibility aliases | `channel`/`sseChannel`, `capture`/`capturer` | select one canonical spelling and give the other a coded migration diagnostic before removal |
| test/body words | `expect`, `expectFail`, `expectHasProof`, `property`, `seed`, `publish`, `sse` | strong contextual-demotion candidates; several parser paths already accept identifier forms |
| unresolved literals | `null`, `true`, `false` | settle semantics before lexical work; the implementation and specification currently need an explicit reconciliation |

This table is a starting hypothesis, not permission to bulk-edit the lexer. Each entry
must pass the gates below.

### Records and types are not automatically ordinary values

`Database`, `Queue`, `SseChannel`, `Cache`, `Email`, and `App` already use typed
record-shaped configuration. The compiler has field schemas for validation and editor
help. That is the strongest candidate family for reducing duplicated surface patterns.

However, most of these are currently **compiler-owned folded declarations**, not
ordinary records:

- their marker types may have no runtime binding;
- the compiler produces distinct declaration nodes and wiring-graph edges;
- their names are referenced by capabilities and runtime configuration;
- some have header-only information such as key parameters or `requires`;
- users cannot necessarily bind, pass, return, or construct them wherever an ordinary
  value is allowed.

Calling them ordinary records without changing those semantics would make the language
less transparent. A future design may infer a folded declaration from its right-hand
constructor, but the specification must call that contextual elaboration, not ordinary
value semantics.

The migration roadmap reached the same distinction: a record-looking `Migration { ... }`
still needs compiler-known elaboration when its fields are typed contextually.

## Goals

1. A user who learns one pattern can transfer it to the next feature without learning
   arbitrary reservation exceptions.
2. Ordinary types, constructors, functions, fields, and variables behave like ordinary
   identifiers unless the language semantics require otherwise.
3. Every remaining hard-reserved word has a documented grammatical or safety reason.
4. Contextual forms are at least as discoverable and diagnosable as hard-keyword forms,
   including while the file is incomplete.
5. Human users and coding agents can reach a clean compile with fewer syntax-reference
   lookups, fewer reserved-name failures, and no loss of proof quality.
6. Proof, capability, schema, codec, routing, and execution guarantees remain unchanged.

## Non-goals

- Reaching an arbitrary keyword-count target.
- Making every compiler intrinsic look like an ordinary function.
- Hiding trusted proof introduction behind library calls. `check`, `auth`, and
  `establish` remain semantically distinct even if their lexical status is reconsidered.
- Replacing nominal types, entities, facts, capabilities, codecs, APIs, handlers, or
  tests with records merely because records use fewer keywords.
- Collapsing all top-level and block grammars into one universal annotated-record form.
- Reducing internal AST or emitter variants; that is the separate smaller-core work.
- Treating general diagnostic, documentation, LSP, MCP, or extension improvements as
  part of this item unless they are required to make a demoted form safe and usable.

## Design rules

### 1. Optimize concepts, not the lexer table

A contextual word still names a concept. Moving it from `KEYWORD` to `IDENT` improves
identifier freedom and parser consistency, but does not by itself make the language
easier to learn. Report both:

- lexically reserved spellings;
- distinct user-visible declaration/expression patterns.

### 2. Preserve visible semantic privilege

Dedicated syntax is justified when it marks authority or static ownership that an
ordinary call does not have. In particular:

- `establish` is a trusted fact-introduction boundary;
- `check` and `auth` have proof-producing and boundary-specific rules;
- `entity`, `database`, `api`, `server`, queues, and channels participate in static
  schema or wiring validation;
- test forms select compilation and execution behaviour.

Lexical demotion may be possible for some of these, but semantic lowering to an ordinary
function is a different decision and must not happen accidentally.

### 3. A contextual form must be locally decidable

The parser must recognise the form from bounded local context and recover from an
incomplete form without swallowing the next declaration. Contextual recognition must be
centralised rather than duplicated across normal parsing, strict recovery, resilient
editor parsing, formatting, and syntax highlighting.

### 4. A record conversion requires value semantics

Describe a construct as an ordinary record only if it can obey the ordinary type rules:
it can be bound, passed, returned, imported, and constructed in every legal value
position without a hidden declaration-only interpretation.

If those properties are undesirable, keep a dedicated declaration or specify an
explicit folded-declaration elaboration rule. Record-shaped syntax alone is not enough.

### 5. Tooling precedes visible syntax removal

Hard keywords are easy for a text editor to colour but poor as a discoverability system.
Before a declaration introducer is demoted or removed, the editor and agent interfaces
must provide:

- declaration-position completion with canonical snippets;
- field completion and hover from the same schema used for validation;
- useful completion in normal incomplete states, including a missing field or brace;
- semantic classification of contextual words without globally colouring ordinary uses;
- targeted typo diagnostics with stable codes and structured fixes;
- rename, definition, occurrence, and document-symbol behaviour based on semantics;
- the same help through LSP and MCP rather than an editor-only implementation.

### 6. No silent compatibility parser

If old syntax has shipped and compatibility is required, support it for a declared
window with a coded diagnostic and machine-applicable rewrite. The formatter emits one
canonical form. Remove the old parser branch after the corpus and compatibility window
are complete; do not retain aliases indefinitely without a concrete external need.

## Proposed disposition

### Keep as dedicated semantics

The initial plan does not attempt to turn these into ordinary values or calls:

- module structure: `module`, `exposing`, `import`;
- control and binding: `let`, `if`/`then`/`else`, `case`/`of`;
- proof/result control: `ok`, `fail`;
- nominal and static declarations: `type`, `record`, `entity`, `fact`, `capability`,
  `codec`;
- function kinds with distinct contracts: `fn`, `handler`, `check`, `auth`,
  `establish`, `worker`, `deadWorker`;
- execution and boundary declarations: `api`, `server`, `test`, `api-test`,
  `load-test`.

This does not require all of those spellings to remain globally reserved forever. It
only says their semantic distinction stays visible and represented in the checked AST.

### Demote without changing source syntax

The high-value, low-churn direction is to make these ordinary identifiers or contextual
words while preserving accepted programs:

1. Standard-library constructors, types, and functions currently tokenised specially.
2. Record-field and clause words used only after an already-recognised construct.
3. Test and domain-operation words whose parser context already determines their role.
4. Top-level declaration introducers only after contextual declaration recovery is
   centralised and proven on incomplete files.

### Remove obsolete spellings

Dead reservations and compatibility aliases should be removed, not merely moved to a
second hand-maintained "soft keyword" list. Each removal needs:

- evidence that no supported syntax needs it;
- a compatibility decision based on shipped use;
- a stable diagnostic and fix when users may still encounter it;
- removal from tokens, parser branches, formatter rules, docs, playground, TextMate
  grammar, tests, and generated fixtures.

### Defer surface-pattern collapse

The repeated folded declaration shape is the only plausible first pilot:

```tesl
database MainDatabase = Database { ... }
queue EmailQueue requires [queueRead] = Queue { ... }
cache Profiles = Cache { ... }
```

A pilot may compare that with constructor-led declarations such as:

```tesl
MainDatabase = Database { ... }
EmailQueue requires [queueRead] = Queue { ... }
Profiles = Cache { ... }
```

This is **not yet target syntax**. Before selecting it, the design must explain:

- how it differs from an ordinary top-level constant;
- where `requires` and channel key parameters live;
- how the declaration kind is inferred when a constructor is imported or shadowed;
- whether these config values can appear in ordinary value positions;
- how declaration completion works before the constructor has been typed;
- whether removing the introducer reduces confusion more than it removes searchability;
- how malformed records retain today's config-specific diagnostics.

If those answers require many exceptions, keep the introducers and make them contextual.
That still restores identifier freedom without pretending the declarations are ordinary
records.

## Delivery plan

### Phase 0: inventory, source of truth, and baseline

1. Add a compiler-owned inventory for every special spelling with:
   canonical spelling, lexical class, valid contexts, semantic kind, aliases,
   deprecation state, and documentation reference.
2. Generate or verify the lexer table, token rendering, formatter classification,
   syntax highlighting, playground lists, and the specification's reserved-word table
   from that inventory. A CI test rejects drift.
3. Reconcile known ambiguities before changing tokens: lowercase versus capitalised Bool
   literals, `null`, `const`, `extractFact`, and the canonical channel/capturer spellings.
4. Record the current number of hard-reserved spellings and distinct surface patterns.
5. Add a binding-position matrix for each candidate spelling: function name, parameter,
   local binding, top-level binding, record field, field projection, import, and export.
6. Establish fixed human and LLM tasks covering a normal function, a record, a
   proof-producing check/establish pair, an API endpoint, and one infrastructure
   declaration.

**Exit gate:** the compiler, specification, formatter, editor, and playground agree on
the inventory, and the baseline tasks and thresholds are recorded before syntax changes.

### Phase 1: source-preserving lexical cleanup

1. Remove verified dead reservations and stale token constructors.
2. Demote ordinary stdlib names. Their existing import, qualification, constructor, type,
   and proof behaviour must remain unchanged.
3. Demote config field names and other unambiguous local clause words, deleting the
   parser's keyword-as-field exceptions made unnecessary by the change.
4. Demote already dual-parsed test/body words one at a time.
5. Keep the checked AST and generated output unchanged.

**Exit gate:** all existing valid source compiles identically; every demoted word passes
the binding-position matrix; import and unknown-name failures remain specific; proof and
capability denial tests are unchanged.

### Phase 2: contextual parsing and discoverability

1. Introduce one parser abstraction for contextual words and one authoritative
   top-level-declaration-start predicate used by strict parsing and editor recovery.
2. Add recovery tests for truncated headers, records, capability lists, and blocks,
   followed by valid declarations that must remain visible to the LSP/MCP snapshot.
3. Expose config/declaration completion and hover through the versioned editor protocol
   and MCP surface, sourced from the compiler's validation schemas.
4. Replace global text-only keyword colouring for demoted words with semantic or
   context-anchored classification.
5. Add stable diagnostics and structured fixes for misspelled contextual words and
   removed aliases.

**Exit gate:** a contextual form is no less discoverable during incomplete editing than
its hard-keyword predecessor, and malformed forms do not degrade later diagnostics or
symbols.

### Phase 3: optional folded-declaration pilot

Start this phase only if the baseline identifies a repeated declaration shape as a
material source of errors or learning cost.

1. Write an exact semantics for one candidate family, including name resolution,
   shadowing, value semantics, capabilities, elaboration, and recovery.
2. Prototype the alternative without deleting the current form.
3. Normalize both forms to the same surface-aware AST declaration kind before proof,
   capability, schema, and wiring validation.
4. Provide one canonical formatter output and a machine-applicable migration.
5. Run paired human and fixed-model LLM tasks before selecting or rejecting the new
   syntax.

**Exit gate:** adopt the pilot only if it improves the predeclared task thresholds and
preserves all semantic and diagnostic gates. Otherwise remove the prototype and retain
contextual introducers.

### Phase 4: migration and removal

If a visible syntax pilot is adopted:

1. Migrate examples, lessons, manual pages, tests, generated fixtures, and templates.
2. Apply the declared compatibility window, if any.
3. Remove old parser branches, tokens, formatter paths, highlighting, and docs together.
4. Re-run the human and LLM benchmarks after removal.

## Verification

### Language and compiler

- Every remaining reserved spelling has a tested rationale.
- Every contextual spelling works as an ordinary identifier outside its defining
  context.
- Demotion does not change AST declaration kinds or emitted behaviour.
- Imported stdlib constructors and types still require the correct imports.
- Formatter parse/format/parse is idempotent and preserves the semantic AST.
- Strict and recovering parsers agree on contextual declaration boundaries.

### Proofs and capabilities

- Trusted fact introduction remains restricted to the same declaration kinds.
- Negative proof-fabrication, missing-proof, and missing-capability tests are unchanged.
- `agent`, queue, database, API, handler, auth, codec, and worker wiring checks retain
  the same accepted and rejected programs.
- `agent-context` reports the same obligations for equivalent old and new forms.

### Diagnostics and tooling

- Diagnostic snapshots retain or improve message specificity, source spans, error codes,
  and structured fixes.
- One malformed contextual declaration does not hide subsequent symbols or diagnostics.
- Completion and hover work in syntactically incomplete config records.
- LSP semantic tokens, document symbols, rename, definition, and occurrences distinguish
  a contextual use from an ordinary identifier use.
- MCP exposes the same completion, diagnostics, symbols, and proof information used by
  the editor.
- TextMate and playground fallback lists are generated from, or checked against, the
  compiler-owned inventory.

### Human and LLM outcomes

Define thresholds in Phase 0; do not choose them after seeing the result. At minimum,
measure:

- task completion and median time for unassisted newcomers;
- syntax-reference lookups and reserved-name failures;
- compile success on the first attempt for a fixed set of model/task/version inputs;
- iterations and tokens required to reach `agent-context.ok = true`;
- proof obligations correctly created and discharged, not merely programs made to
  compile by weakening types or facts.

No regression is allowed on proof tasks. Keyword count is reported only as an outcome.

## Decisions required before implementation

1. What source-compatibility window, if any, applies to released Tesl syntax?
2. Are `True`/`False` or `true`/`false` canonical, and what should `null` mean?
3. Which spellings are canonical: `sseChannel` or `channel`, and `capturer` or the legacy
   top-level `capture`?
4. Is `extractFact` supported, deprecated, or dead?
5. Should compiler-owned config markers ever become genuine first-class values, or stay
   folded declarations with contextual introducers?
6. Which incomplete-source representation will power declaration and field completion?
7. What measured improvement is large enough to justify a visible grammar migration?

No phase may start while a decision owned by that phase remains open.

## References

- `compiler/lib/lexer.mll` - current lexical reservation table.
- `compiler/lib/token.ml` - token inventory, including stale constructors to audit.
- `compiler/lib/parser.ml` - top-level dispatch, contextual forms, and recovery.
- `compiler/lib/stdlib_config_names.ml` - compiler-only config markers and lowered names.
- `compiler/lib/compile.ml` - config-context schemas used for completion and validation.
- `LANGUAGE-SPEC.md` sections 8.4, 10.4, 11, and 11.9 - identifiers, stdlib/core boundary,
  declarations, and folded records.
- `roadmap/discarded/smaller_core_and_emit_targets.md` - deferred universal grammar
  collapse and its breaking-change warning.
- `roadmap/completed/reduce_language_size.md` - separate internal core-lowering work.
- `roadmap/completed/app_simplification.md` - precedent for removing concepts rather than
  merely renaming syntax.
- `roadmap/next/database-migrations.md` and its history - ordinary functions plus
  record-shaped, compiler-elaborated declarations without new keywords.
