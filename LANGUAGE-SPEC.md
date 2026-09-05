# Tesl language specification (draft)

## Table of Contents

Hand-maintained index of the top-level sections. Section **numbers** (e.g. `§7.4`,
`§14b.2`) are a stability contract — see the `language-spec` entry in
[`manual/anchors.md`](manual/anchors.md) for how compiler diagnostics and tests cite them.

- [1. Purpose and scope](#1-purpose-and-scope)
- [2. Product goals](#2-product-goals-non-normative-but-guiding)
- [3. Reference lineage](#3-reference-lineage-non-normative)
- [Why a language, not a library](#why-a-language-not-a-library)
- [4. Language layers](#4-language-layers)
- [5. Effect model and operational stance](#5-effect-model-and-operational-stance)
- [6. Core semantic model](#6-core-semantic-model)
- [7. Global soundness invariants](#7-global-soundness-invariants)
- [8. Lexical structure](#8-lexical-structure)
- [9. Expression grammar](#9-expression-grammar)
- [10. Modules, imports, qualification, and standard library](#10-modules-imports-qualification-and-standard-library)
- [11. Surface grammar for top-level declarations](#11-surface-grammar-for-top-level-declarations)
- [12. Function bodies and expressions](#12-function-bodies-and-expressions)
- [13. Static semantics](#13-static-semantics)
- [14. Dynamic semantics](#14-dynamic-semantics)
- [14b. Structural type system](#14b-structural-type-system)
- [15. Proof composition and decomposition](#15-proof-composition-and-decomposition)
- [16. Open design areas](#16-open-design-areas)
- [17. Worked examples](#17-worked-examples)
- [18. Canonical guidance for future language changes](#18-canonical-guidance-for-future-language-changes)
- [19. Native Cache](#19-native-cache)
- [20. Email Support](#20-email-support)
- [21. Standard Library Extensions](#21-standard-library-extensions)
- [22. Step Debugger](#22-step-debugger)
- [23. Single sign-on (SSO)](#23-single-sign-on-sso-and-third-party-auth)
- [Appendix A. Current implementation divergences](#appendix-a-current-implementation-divergences)

## 1. Purpose and scope
This document is the canonical draft specification for the `.tesl` surface language.

Its primary job is to describe **what Tesl should be as a language**. When the current implementation diverges from that goal, the intended language should remain normative and the implementation difference should be called out explicitly.

This document uses three status words:

- **Accepted design**: part of the intended language design.
- **Implemented**: already present in the current compiler/runtime.
- **Open**: not yet settled, or not yet implemented on the `.tesl` surface.

Unless stated otherwise, examples use intended `.tesl` syntax. Known implementation divergences are collected near the end of the document.

The `.tesl` frontend is the primary user-facing language. The compiler emits a self-contained Go module (the program plus a vendored copy of the `teslrt` runtime); the generated Go is an artefact a reviewer can read, not a second public surface.

Important implementation note on guarantees: when this specification says that proof verification or the declared-context capability check is enforced at compile time, that is literal — the compiler is the sole contract for those, with no runtime re-check behind them. Proofs, facts and capabilities are **erased** by the Go emitter: a `check` function returns a plain `teslrt.Check[T]`, a proof-annotated record is a plain struct, and a `requires [...]` list leaves no trace in the generated program. The Go runtime therefore performs no "Missing capabilities" check and no existential-witness escape check at run time (both were dynamic checks of the retired Racket substrate). What the runtime does enforce, because it is part of how a request is executed at its boundary, is handler parameter decoding/validation (codecs, `check` functions, captures) and handler response encoding. Soundness of everything else rests on the compiler and on the two storage backends agreeing (see §11.9).

## 2. Product goals (non-normative, but guiding)
**Scope:** the product-level pitch — who Tesl is for and why it exists — lives in the
[README](README.md#what-tesl-is-trying-to-achieve). This section keeps only the design-review
guidelines that constrain normative decisions below. They are not syntax rules; they are the
tie-breakers the spec appeals to.

- The primary authoring surface should be readable, explicit, and unsurprising.
- The language should make important API knowledge visible in declarations rather than hiding it in handler bodies.
- The language should make invalid states hard to express without attempting full dependent typing.
- Proofs should be easy to work with, but not magical or theory-free.
- Hidden GDP names should be present by default; value unwrapping is handled implicitly by the compiler.
- Trusted proof introduction should happen at clear, auditable boundaries.
- The language should be intentionally opinionated: one obvious style, enforced by a built-in linter/formatter.
- Ordinary side effects should be capability-governed. Telemetry is the deliberate ambient exception.
- Observability should follow OpenTelemetry semantic conventions (OpenTelemetry-shaped). Telemetry is configured declaratively through the `TelemetryConfig` field of `App`; the legacy `initTelemetry` startup form remains accepted for existing programs. With a real `endpoint` URL, telemetry is exported over OTLP/HTTP+JSON to `<endpoint>/v1/logs` (Logs signal, `dsl/otel.rkt`) and `<endpoint>/v1/metrics` (Metrics signal, `dsl/metrics.rkt`) and — with `traces True` — `<endpoint>/v1/traces` (Traces signal, `dsl/traces.rkt`); with no endpoint it emits structured JSON locally. W3C trace-context propagation is unconditional, so logs are joinable to a caller's trace even with span export off. The protobuf/gRPC transport is a non-goal, as is any user-facing span API.

The language is in active development; breaking changes carry **no** backward-compatibility burden.
We keep the language as tight and small as possible. Earlier architectural notes may use older
syntax (`unchecked-name`, `Requires`, `*name`, older route notation) — useful as design context,
not normative.

## 3. Reference lineage (non-normative)
**Scope:** conceptual ancestors, not templates — see the [README](README.md#what-tesl-is-trying-to-achieve)
for the framing. Tesl is directly inspired by two lines of work:

- the GDP paper, *Ghosts of Departed Proofs* — preconditions are checked early and then carried as ghost evidence rather than re-handled as optional values everywhere;
- the earlier `servant-gdp` work — API declarations can carry named route inputs and rich domain facts.

### Proofs vs Facts
Proofs and Facts are used interchangeably in this document. In GDP they are called proofs but in Tesl they are called facts in an attempt to make the subject of using them less daunting.

## Why a language, not a library

The original *Ghosts of Departed Proofs* technique is a **library** technique: it encodes ghost
evidence inside a host type system (Haskell's) using rank-2 types, phantom parameters, and
newtype discipline. Tesl deliberately is **not** that. The three guarantees below are the reason
Tesl earns its keep as a standalone language rather than a package you `import` — each one is
either impossible or unenforceable from inside a library, because a library cannot constrain the
program that hosts it.

**Erasure is the sole runtime mode, not an optimization.** In a library, ghost values are ordinary
host values the compiler *happens* to be able to erase; nothing stops a caller from reflecting over
them, printing them, or branching on their presence. In Tesl, the standard `check`/`fn`/`handler`
path performs **no runtime proof-verification and carries no inspectable proof object** in the
default and `--debug` builds — verification is entirely compile-time (§7.10). A small enumerated set
of carriers is deliberately retained (detached proofs, existential packages, newtype wrappers,
`FromDb` proofs, and the ≤1-alloc proof-annotated parameter — see §4.3); outside that closed set
there is no proof object to inspect, serialize, or forge at runtime because the language, not a
convention, guarantees it does not exist. A library cannot make that promise about code it does not
own.

**Host-wide no-shadowing is a whole-program invariant (§7.4).** GDP soundness depends on a hidden
subject naming exactly one value; the moment a name can be shadowed, a fact about the outer binding
can be silently re-read as a fact about a different inner value. A library can only refuse to
shadow *its own* names — it cannot forbid the *host program* from shadowing. Tesl makes name
shadowing **illegal program-wide** (§7.4), which is a property of the language's binding rules, not
of any single API. This is the single most load-bearing reason GDP-in-a-library leaks and
GDP-as-a-language does not.

**`:::` fabrication is restricted to trusted function kinds (§7.12).** The one place a proof is
minted from nothing — the `:::` annotation that asserts a fact holds — must be auditable and
un-spoofable. In a library, any caller can construct the "smart-constructor" wrapper, so the
trusted boundary is only as strong as documentation and review. Tesl makes fabrication a
**syntactic privilege of trusted declaration kinds** (`check`, `auth`, `proof`, and library-owned
predicates) and a compile error everywhere else (§7.12). The set of places a fact can enter the
system is closed and mechanically checked — a guarantee about *who may write `:::`*, which only the
grammar and checker of a real language can enforce.

Together these define Tesl's right to exist: erasure-as-sole-mode, host-wide no-shadowing, and
trusted-only fabrication are **whole-language invariants**, not API-local conventions. A library
can offer the ergonomics of GDP; only a language can offer its guarantees.

## 4. Language layers
Tesl currently has three relevant layers.

### 4.1 Surface `.tesl` layer
This is the intended authoring surface. Users write modules, imports, records, entities, functions, captures, APIs, servers, and `main` blocks here.

### 4.2 OCaml frontend and Go emission layer

The OCaml compiler parses the surface language, resolves the module graph, performs structural type checking and proof/capability validation, and emits a Go module. Each Tesl module becomes a Go package under the generated module; a module containing `main` also gets `cmd/app/main.go`, and Tesl test forms become Go `_test.go` functions.

Emission is directly from the checked Tesl module representation. The generated project includes `go.mod`, generated application packages, and the runtime sources required by the program. Optional external Go dependencies are version-pinned in the generated module.

**Historical architecture:** Tesl formerly lowered surface forms to a Racket macro DSL with forms such as `define/pow`, `define-checker`, `define-auther`, and `define-handler`. That Racket emitter/runtime architecture has been retired; references to those forms describe historical behavior, not the current compilation path.

### 4.3 Go runtime and erased evidence layer

The compiler vendors the required embedded `teslrt` Go sources into `internal/teslrt/` in the generated module. Runtime files for features such as HTTP, PostgreSQL, debugging, agents, regexes, and time zones are selected only when the generated program needs them. The checked-in runtime source and the compiler's embedded snapshot are kept in sync by compiler tests and CI.

Proofs, facts, existential witnesses, and capability declarations are compile-time information and have no evidence-bearing runtime representation in generated Go:

- proof attachment, detachment, decomposition, and `Fact` values erase;
- proof-annotated values, fields, collection elements, and function returns use their ordinary Go value representation;
- existential quantifiers erase to the representation of their body value;
- `requires [...]` declarations leave no runtime capability row or grant check.

A `check` or `auth` still returns `teslrt.Check[T]` because success/failure and its status/message are observable runtime control flow. That value does not contain a proof identity. Nominal newtypes and ordinary ADTs/records retain representations because they are value types, not proof evidence.

**Erased under `--debug` too.** Debug builds add source checkpoints, metadata, and the required debug runtime files, but they do not restore proof objects. The debugger displays runtime values alongside compiler-provided source/type information; proof verification remains entirely in the frontend.

### 4.4 Public interface

The `.tesl` files are the only supported authoring interface. Generated Go is deliberately readable and can be inspected or processed with ordinary Go tooling, but manually changing it is outside the language guarantee and those changes are overwritten by the next emission.

The OCaml frontend and Go emitter are the compile-time authority for syntax, types, proofs, capabilities, and backend-supported forms. The generated `teslrt` code owns runtime boundary behavior such as request decoding, check rejection, database access, and response encoding. Inherent environmental failures, such as an unavailable database, remain runtime failures at those boundaries.

Go is the sole current execution backend. The retired Racket files and DSL forms are relevant only to explicitly historical comparisons; they are not an alternate public interface or a runtime fallback.

## 5. Effect model and operational stance
This section is normative for the public language design.

### 5.1 Capabilities govern ordinary side effects
**Accepted design.**

The capability system is the only public mechanism for ordinary side effects.

This means:

- effectful operations should be introduced through capability-governed primitives or helpers;
- code that performs ordinary side effects should declare the relevant capabilities;
- unrestricted ambient side effects are not part of the intended language model.

### 5.2 Telemetry is the ambient exception
**Implemented.**

Telemetry is the one deliberate exception to the ordinary capability rule.

The intended model is:

- Tesl telemetry is OpenTelemetry-shaped (follows OpenTelemetry semantic conventions); a native OTLP exporter is implemented (`dsl/otel.rkt`): with a configured `endpoint` it exports over OTLP/HTTP+JSON (Logs signal), and with no endpoint it emits structured JSON locally (see the Export paragraph below);
- telemetry is ambient and does not require an explicit capability in ordinary code;
- this exception exists because observability is considered part of the platform foundation rather than an arbitrary user-defined effect.

**Declarative setup.** An application normally configures telemetry in its returned `App` record:

```tesl
import Tesl.Telemetry exposing [TelemetryConfig]

main() -> App requires [appService] =
  App {
    database: MainDatabase
    api: AppServer
    port: 8080
    telemetry: TelemetryConfig {
      service: "orders"
      endpoint: "in-memory"
      console: True
    }
  }
```

`service`, `endpoint`, and `console` are required fields. `metrics` and `metricsInterval` are
optional overrides. `endpoint "in-memory"` (or an empty endpoint) keeps export local. `initTelemetry`
is a compatibility form for older programs; new code should use the record field so configuration
is checked like the other `App` fields.

**Export.** When `initTelemetry` is given a real `endpoint` URL, events are exported to it over OTLP/HTTP+JSON (Logs signal): each event becomes a log record (message → `body`, `timestampMs` → `timeUnixNano`, `service` → the `service.name` resource attribute, attributes → OTLP `KeyValue`s), POSTed in batches to `<endpoint>/v1/logs`. Export is opt-in purely by the presence of a configured endpoint — the outbound network egress is intentionally kept ambient (no `httpClient` capability), consistent with telemetry being platform infrastructure. Export is asynchronous and resilient: events are buffered in a bounded queue (drop-oldest on overflow) flushed by a background timer, and an unreachable/erroring collector degrades to a dropped batch — it never blocks or fails the request path. The sentinel `endpoint "in-memory"` (and the empty string) means "no remote export"; `console True` additionally prints events to the console for local dev. The protobuf/gRPC transport is a non-goal; the Traces signal is described below.

**Metrics.** The Metrics signal shares the pipeline (`dsl/metrics.rkt`). Three ambient instruments are importable from `Tesl.Telemetry` — `counter name amount attrs` (monotonic sum, `Int`), `histogram name sample attrs` (explicit-bucket distribution, `Float`, durations in seconds per semantic conventions), and `gauge name value attrs` (last value, `Float`) — where `attrs` is a `List (Tuple2 String String)` of low-cardinality labels (e.g. `[Tuple2 "plan" plan]`). Aggregation is in-process and cumulative; a snapshot is POSTed to `<endpoint>/v1/metrics` on a fixed interval (default 60 s, `metricsInterval` in milliseconds). Metrics default ON when a real endpoint is configured and OFF otherwise; `metrics True|False` overrides (with `endpoint "in-memory"`, `metrics True` records locally with no export — useful in tests). The record path never raises and never blocks, and each instrument is capped at 2000 distinct attribute sets — overflow folds into a single `{otel.metric.overflow="true"}` series, so an unbounded label (a user ID) cannot grow memory without bound. The runtime also records a built-in catalog automatically (HTTP request duration by operation/status, SQL operation duration, DB pool wait/timeouts/size, queue enqueue/job-duration/dead-letters, SSE active-connections/sent/dropped, cache hit/miss, LLM calls/latency/token-usage, per-tool agent latency, and the exporter's own drops) — see `example/learn/lesson73-metrics.tesl` for the full list. Host-level CPU/memory metrics are out of scope by design: they belong to the host's own agent, not the application.

**Traces.** The Traces signal (`dsl/trace-context.rkt`, `dsl/traces.rkt`) has no user-facing surface at all, by design, and comes in two halves. The first is unconditional and free: an inbound W3C `traceparent` header is parsed and carried as the ambient trace context, so **every** log record gains `trace.id` / `span.id` / `trace.sampled` (lifted into the OTLP log record's first-class `traceId`/`spanId`/`flags` fields, which is what a collector joins on) and **every** outbound HTTP call carries `traceparent` (plus the inbound `tracestate`, unmodified) onward — a caller-supplied `traceparent` always wins and is never overwritten. With no inbound header a fresh crypto-random trace id is minted, so the fields are always present; `request.id` is unrelated and unchanged (it is the human-readable handle, not a trace id). Malformed inbound headers never raise: the app simply starts a new trace. The second half is span export, enabled by `traces True` (**default `False`**, unlike `metrics` — spans are per-request and unaggregated, so the volume and the ambient egress are opt-in) with optional `traceRatio` head sampling (`0.0`–`1.0`, default `1.0`). Spans are POSTed to `<endpoint>/v1/traces` over OTLP/HTTP+JSON with the same never-block/never-raise/bounded-buffer discipline as the other signals. Sampling is **parent-respecting**: an inbound decision is never second-guessed, so `traceRatio` only decides for traces that start in this app. The propagated `sampled` bit is deliberately independent of `traces` — an app with span export off still tells downstream services "record this", because stamping `00` on every outbound header would silence other teams' tracing merely by being in the request path; lowering `traceRatio` does suppress it downstream too, which is what consistent head sampling means. The span tree is produced entirely by the framework — one `SERVER` span per request, one `CLIENT` span per SQL statement, `db.pool.lease` for connection waits, one `CLIENT` span per outbound HTTP call, one `CONSUMER` span per queue job attempt (parented on the enqueuing request via a `traceparent` carried in the job row, so it survives a restart or another replica), one `CLIENT` span per LLM call, one `INTERNAL` span per agent tool execution, and cache get/set — see `example/learn/lesson77-traces.tesl`. An `sse` subscription is deliberately not traced: its stream outlives the request that opened it, so a span would measure how long the client stayed connected (SSE has its own metrics instead). There is deliberately **no** user-facing `span` / `startSpan` API or `trace { }` form: the spans worth having are framework spans, and an inner boundary of your own is a `telemetry` event, which the first half already stamps with `trace.id`/`span.id`. Span attributes carry shape, not payload — no bound SQL parameters, request/response bodies, LLM prompts, tool arguments or query strings, and a `secret` used as an attribute renders `[redacted]` because every signal shares one attribute renderer (`dsl/otlp-value.rkt`). The parameterized SQL statement is available on db spans behind `TESL_TRACE_DB_STATEMENT=1`. With `traces False` an instrumented call site costs one flag read and evaluates neither its span name nor its attributes.

### 5.3 Opinionated foundation
**Accepted design.**

Tesl is intentionally opinionated. The language should reduce the number of stylistic and architectural decisions each developer must make.

That includes:

- explicit imports for unqualified names; module imports (`import Module`) for qualified-only access;
- a small number of canonical ways to express the same idea;
- a built-in opinionated linter and auto-formatter (`--lint`, `--fmt`, `--fmt-check`) enforcing a single canonical style.

## 6. Core semantic model
This is the most important part of the specification for soundness review.

### 6.1 Raw values
A raw value is an ordinary runtime payload with no attached proof facts.

Examples: an integer, a string, a record payload, a list.

### 6.2 Hidden subjects / GDP names
**Implemented.**

Every ordinary bound value in proof-aware Tesl code is associated with a hidden fresh subject identity.

The important point is that this subject identity is not the same thing as the surface spelling of the variable.

- Two values with the same raw payload still have different subjects if they were bound separately.
- Renaming a variable does not change what subject a proof is about.
- Shadowing is forbidden because it would blur the mapping from visible names to hidden subjects.

### 6.3 Named values
A named value is a runtime value together with:

- its hidden subject identity;
- its raw payload;
- zero or more attached proof facts;
- a binding environment that lets detached proofs continue to talk about the subject they were originally about.

A named value is the default proof-relevant carrier in the runtime.

### 6.4 Proof facts
A proof fact is a GDP expression such as:

- `ValidPort port`
- `Positive x`
- `OwnedBy user task`
- `FromDb taskId`
- `Positive x && ValidPort x`

The proof vocabulary is open. Tesl does not hard-code a closed set of propositions.

### 6.5 Detached proofs
A detached proof is a first-class proof value. It carries:

- one fact (can be a combined value since Proofs are recursive, such as `IsPositive x && IsBelow20 x`);
- the hidden-subject bindings needed to interpret that fact later.

Detached proofs exist so proofs can be transported explicitly when needed.

### 6.6 Existential packages
An existential package contains:

- one or more hidden witness bindings;
- a body value whose proof meaning may mention those witnesses.

Witnesses are scoped. They are not allowed to escape.

## 7. Global soundness invariants
These invariants should be treated as the backbone of Tesl's proof/name design.

### 7.1 Fresh hidden subjects for ordinary values
**Accepted design, Implemented.**

Every ordinary non-raw binder introduces or preserves a hidden subject identity.

### 7.2 Users may not fabricate or replay hidden subjects directly
**Accepted design. Implemented**

The user never writes the actual hidden name. Surface code only writes ordinary variable names, and the compiler/runtime map them to hidden subjects internally.

### 7.3 Facts attach to subjects, not to surface spellings
**Accepted design, Implemented.**

A proof about `x` is a proof about the hidden subject currently denoted by `x` at the point where the proof was formed. It is not a fungible proof that can be retargeted by reusing the same surface spelling elsewhere.

### 7.4 Name shadowing is illegal
**Accepted design, Implemented.**

Shadowing is forbidden for proof-relevant binders. This is a deliberate language rule, not a style preference.

The reason is semantic, not cosmetic: once values implicitly carry hidden subjects, reusing a visible name in the same scope chain becomes proof-relevant ambiguity.

### 7.5 `forgetFact` drops proofs but preserves the subject
**Accepted design, Implemented.**

`forgetFact(v)` removes attached facts from `v`, but it does not change which subject the value refers to.

This means `forgetFact` is not the same thing as dropping to raw space. It forgets evidence, not identity.

### 7.6 `detachFact` preserve the original subject identity
**Accepted design, Implemented.**

Detached proofs continue to refer to the subject they were originally attached to, even after transport.

### 7.7 `attachFact` does not retarget a proof to a new subject
**Accepted design, Implemented.**

A detached proof may be physically attached to another named value, but that does not change what subject the proof fact is about. Therefore reattachment is not a way to forge a proof obligation for a different subject.

### 7.8 Unbound GDP names in proof templates are rejected
**Accepted design, Implemented.**

Proof annotations and proof templates must only refer to names that are in scope under the relevant proof-binding rules.

A GDP **name** is always a value binding, and a value binding cannot start with an uppercase letter. So an uppercase-initial argument in a proof template is not a name at all — it is a **constant**, most usefully an ADT constructor. A fact may therefore be *indexed* by a constructor: given `fact MayUse (c: Caller) (p: Permission)`, the templates `MayUse c WriteCostRates` and `MayUse c ReadProjects` are distinct, non-interchangeable proofs about the same subject `c`, so one `check` per constructor replaces one fact per capability. A constructor argument must name a constructor of the ADT the fact declares at that position; a misspelled or wrong-ADT constructor is a compile error.

### 7.9 Existential witnesses may not escape
**Accepted design, Implemented**

A hidden existential witness is scoped to its package/elimination context. Returning or storing it directly is a Skolem escape and is rejected.

### 7.10 Proof verification is compile-time; some runtime semantics remain
**Accepted design, Implemented.**

The `.tesl` frontend performs proof-aware static checking when it has enough information. In the current implementation, structural type checking and proof-aware checking run as separate frontend passes before lowering to the Racket DSL.

**Proof verification is compile-time only** (excluding the retained carriers noted in §4.3). The runtime evidence structs are erased for standard `check`/`fn` paths — in release and `--debug` alike — so proof verification is a purely compile-time guarantee with zero runtime cost. The compiler is the sole contract for it; there is no runtime evidence layer behind it to toggle on, and the same holds for the declared-context capability check.

This does **not** mean the runtime performs no validation. A handful of checks remain as **core runtime semantics**, because they govern how a request crosses the runtime's boundaries rather than duplicating a compile-time proof:

- the ambient capability-grant check — a "Missing capabilities" error if a required capability is not granted at runtime;
- handler parameter type validation;
- handler return type/shape validation;
- the existential-witness escape check (§7.9).

### 7.11 Newtype nominal identity is enforced at runtime
**Accepted design, Implemented.**

`type Name = BaseType` creates a nominal wrapper. Two newtypes over the same base type are distinct runtime types. The runtime predicate for `Name` checks for the `newtype-value` wrapper with the correct type tag, not just for a value satisfying `BaseType`. This ensures `UserId` and `ProjectId` (both wrapping `String`) cannot be accidentally interchanged.

### 7.12 Proof fabrication via `:::` is restricted to trusted function kinds
**Accepted design, Implemented.**

The `:::` operator in expression context outside `establish`, `check`, and `auth` function bodies may only attach existing proof values. Using a raw GDP predicate expression (e.g. `value ::: IsPositive x`) in a `fn` or `handler` body is rejected at compile time. This closes the bypass path that would otherwise let any function kind fabricate a proof fact without passing through a validation boundary.

### 7.13 The `?` pack operator for named return values
**Accepted design, Implemented.**

`-> Todo ? FromDb (Id == todoId)` declares a **named-pack** return. The returned value is automatically named by the caller's `let` binder:

```tesl
# function declaration (new canonical infix syntax)
handler get getTodo(...) -> Todo ? FromDb (Id == todoId) requires [...] = ...

# callsite: the let binder `todo` becomes the GDP name
let todo = getTodo(requestUser, todoId)
# todo :: Todo todo ::: FromDb (Id == todoId) todo

# functions requiring the named 2-arg proof
fn process(t: Todo ::: FromDb (Id == id) t) -> ...
process(todo)   # works: todo carries FromDb (Id == todoId) todo
```

**Syntax.** The canonical form is `Type ? EntityProofs [::: OtherProofs]`:

- `Type ? EntityProofs` — entity proof group only; `_entity` is auto-appended to every leaf predicate
- `Type ? EntityProofs ::: OtherProofs` — entity proof group plus independent proofs
- `Int ? Positive && Small` — compound entity proof; both get `_entity` appended
- `Int ? Positive ::: Admin user` — entity proof `(Positive _entity)` plus independent proof `(Admin user)`

**The entity-append rule.** Every leaf predicate in the `?` group (left of `:::`) gets `_entity` appended as its last argument. `&&` distributes:

```
FromDb (Id == todoId)  →  (FromDb (Id == todoId) _entity)
Positive               →  (Positive _entity)
Positive && Small      →  ((Positive _entity) && (Small _entity))
```

The `:::` group (other proofs) is left untouched — no `_entity` appended.

**Removed syntax.** The old prefix syntax `-> ?Type ::: proof` has been removed. Use the canonical infix syntax `-> Type ? Proof` instead.

The `?` annotation auto-extends the proof with the entity's own subject identifier. The SQL layer produces **two-argument `FromDb` facts** `(FromDb (Id == pk-subject) entity-subject)` so that both the primary-key binding and the entity identity appear in the proof. A backward-compatible one-argument fact `(FromDb (Id == pk-subject))` is also produced, so existing code using `binding` return specs (`-> item: Todo ::: FromDb (Id == id)`) continues to work.

The `?` annotation is also valid in `api` endpoint declarations:

```tesl
api MyApi {
  get "/todos/:todoId"
    capture todoId: String ::: TodoId todoId via todoIdCapture
    -> Todo ? FromDb (Id == todoId)
}
```

**Relationship to `check` functions.** For the common pattern of "validate an input and return the same value with proof," `check` functions are the right tool — their binding return spec already returns the same GDP identity as the input:

```tesl
check isSafeTitle(title: String) -> title: String ::: TitleSafe title =
  if String.length(title) <= 120 then
    ok title ::: TitleSafe title
  else
    fail 400 "title too long"
```

The `?` operator is for cases where the value is already proof-carrying and the caller needs to receive it named. For non-optional validation, `check` is preferred.

**Proof-carrying `Maybe` return** — `-> Maybe (v: T ::: P v)`.
**Accepted design, Implemented.**

When a function may or may not produce a proof-carrying value, use the named-binding
form inside `Maybe`. This is most useful with ADTs or domain types where the value and
its proof are produced together inside the function:

```tesl
# A binary tree where every node value is positive
type Tree
  = Leaf
  | Node left:Tree value:Int right:Tree

fact AllPositive (t: Tree)

check checkAllPositive(t: Tree) -> t: Tree ::: AllPositive t =
  case t of
    Leaf -> ok t ::: AllPositive t
    Node l v r ->
      if v <= 0 then
        fail 400 "node value not positive"
      else
        let l2 = check checkAllPositive l
        let r2 = check checkAllPositive r
        ok t ::: AllPositive t

# Returns the tree only if every node value is positive — proof flows through case
fn validateTree(t: Tree) -> Maybe (v: Tree ::: AllPositive v) =
  if True then                     # real implementation would examine the tree
    let valid = check checkAllPositive t
    Something valid
  else
    Nothing

fn processPositiveTree(t: Tree ::: AllPositive t) -> Int = 42

fn useTree(raw: Tree) -> Int =
  let m = validateTree raw
  case m of
    Nothing -> 0
    Something v ->
      processPositiveTree v   # v carries AllPositive v — proof flows automatically
```

**Syntax**: `-> Maybe (binder: T ::: P binder)` — the inner binder name identifies the
proof subject. The proof annotation is compile-time only; at runtime `Maybe (v: T ::: P v)`
is plain `Maybe T`.

The older `Maybe (Fact (P x))` idiom works when the caller already holds `x` and needs
only the detached fact to attach elsewhere. The `Maybe (v: T ::: P v)` form is idiomatic
when the returned value itself is produced at the proof boundary and the caller pattern-matches
on the result.

**Note — canonical proof-return forms (D7).** The compiler accepts five spellings of a
proof-carrying return, so this note records which are canonical and which are legacy/specialized.
This is style guidance, not a soundness distinction — all five compile today and are equally sound.

- **Canonical, non-optional:** `check … -> x: T ::: P x` (binding return spec, the preferred form for
  "validate an input and return it carrying its proof") and `-> T ? EntityProofs` (the named-pack
  operator, §7.13, for entity/DB results the caller receives named).
- **Canonical, optional:** `-> Maybe (v: T ::: P v)` — the proof-carrying `Maybe` return above.
- **Legacy / specialized:** the bare `-> Fact (…)` and `-> Maybe (Fact (…))` forms return a *detached*
  fact rather than a proof-carrying value. They remain supported for detached-proof transport (the
  caller already holds the subject and needs only the fact to attach elsewhere), but they are not the
  one obvious way to return a validated value; prefer the canonical forms above for new code.

## 8. Lexical structure
### 8.1 File prologue
**Accepted design, Implemented.**

A Tesl source file starts directly with its `module` header (blank lines and
comments may precede it). The historical `#lang tesl` pragma is **not
accepted**: a file containing a `#lang` line is rejected with error `E002`,
whose diagnostic carries a delete-line fix.

### 8.2 Comments
**Accepted design, Implemented.**

`#` starts a single-line comment, except:

- `#` inside string literals is preserved.

### 8.3 Indentation and braces
**Accepted design, Implemented.**

Tesl uses two structural mechanisms:

- indentation for function bodies and nested body constructs such as `if`, `case`, and existential packing bodies;
- braces for top-level blocks such as `record`, `entity`, `database`, `api`, `server`, the `App { ... }` record returned by `main`, and for the `transaction { ... }` body block.

Unexpected indentation is a parse error.

### 8.4 Identifiers and qualification
**Accepted design, Implemented.**

Informally:

- `identifier ::= [A-Za-z_][A-Za-z0-9_]*`
- `dotted-identifier ::= identifier ("." identifier)+`

Module names are dotted identifiers.

Dotted identifiers are used for **qualification and namespacing**, not for receiver-style extension methods. For example:

- `String.length title` is in scope as a desired form;
- `title.length` is not part of the intended language;
- `title.startsWith("x")` is not part of the intended language.

Explicit import/export names may additionally use the constructor-family form `Type(..)`.

### 8.5 Literals

**Accepted design, Implemented.**

**Integer literals** (`Int`): arbitrary decimal sequences, optionally preceded by a minus sign. `Int` is **arbitrary-precision** (unbounded): values are Racket integers, which transparently span fixnums and bignums.

- **Range**: unbounded. There is no minimum or maximum magnitude; integer literals of any size are accepted.
- Literals whose magnitude exceeds the native fixnum range are carried by the compiler as a canonical decimal string (`LBigInt`) and emitted as ordinary Racket integer literals; there is no compile-time range check.
- Arithmetic on `Int` values never overflows: results that exceed the native fixnum range are automatically represented as bignums.

**Float literals**: decimal literals containing a `.` (e.g., `3.14`, `-0.5`). Maps to Racket inexact floats (IEEE 754 double precision).

**String literals**: delimited by `"`. Support `\n`, `\t`, `\\`, `\"` escape sequences. Multi-line strings are not supported; embed `\n` for newlines.

**Bool literals**: `True` and `False` (capitalised). Lower-case `true`/`false` are not keywords.

**List literals**: `[e1, e2, e3]`. Nested lists require explicit brackets.

## 9. Expression grammar

Tesl currently uses one lightweight GDP expression grammar for both type expressions and proof facts.

### 9.1 GDP expressions
**Accepted design, Implemented.**

```text
<gdp-expr> ::= <gdp-infix>
<gdp-infix> ::= <gdp-application>
              | <gdp-application> <gdp-op> <gdp-application>
              | <gdp-application> <gdp-op> <gdp-application> <gdp-op> ...
<gdp-op> ::= "&&" | "==" | "!=" | "<=" | ">=" | "<" | ">"
<gdp-application> ::= <gdp-atom> { <gdp-atom> }
<gdp-atom> ::= <identifier>
             | <dotted-identifier>
             | <integer>
             | <string>
             | "(" <gdp-expr> ")"
```

Notes:

- application is by whitespace, e.g. `ValidPort x`;
- infix operators are also allowed inside type/proof syntax;
- `Fact (Predicate x)` is ordinary GDP application syntax;
- `:::` is not part of GDP syntax itself; it is annotation syntax surrounding values, bindings, and return types.

### 9.2 Meaning of `&&` in proof facts
**Accepted design, Implemented.**

Inside proof facts and proof obligations:

- `P && Q` means both facts must hold.

This operator is used by both the static checker and the runtime proof checker.

Note: `||` (disjunction) is not supported in proof, by design (It was intentionally removed from the language). When a value may carry one of several proofs, use `Either` instead: `Either (Int a ::: IsPositive a) (Int b ::: IsNegative b)`.

## 10. Modules, imports, qualification, and standard library
### 10.1 Module header
**Accepted design, Implemented.**

```text
module <Module.Name> exposing [<explicit-name>, ...]
```

The header is mandatory and may only appear once.

Wildcards are not supported. Exports must be listed explicitly.

### 10.2 Imports
**Accepted design, Implemented.**

```text
import <Module.Name> exposing [<explicit-name>, ...]
import <Module.Name>
```

Two import forms are supported:

- **Explicit imports** list the names to bring into the unqualified scope. The constructor-family form `Type(..)` imports an ADT name together with all of its constructors.
- **Constructors are import-scoped too.** Naming a stdlib constructor anywhere — as a value (`Nothing`, `TextBody body`, `Monday`) **or** in a pattern (`case d of Monday -> …`) — requires its module to be imported, either wholesale (`import Tesl.Maybe`), through the family form (`exposing [Maybe(..)]`), or by naming the constructor itself (`exposing [Nothing]`). Listing the bare type (`exposing [Maybe]`) imports the type only — not its constructors. Without the import the compiler reports `constructor \`Nothing\` requires \`import Tesl.Maybe\``. In value position the import is what makes the name exist at all (the emitted module's `require` list is built from the imports, so an unimported constructor would be unbound at load time); in pattern position it is the same one rule, so a module's import list stays a complete, greppable inventory of the stdlib surface it uses. A module that *declares* its own type with the same constructor names uses its own — declaring is not importing, and declaring **and** importing the same name is the separate shadowing error.
- **Module imports** (no `exposing` clause) load the module without importing any names into the unqualified scope. All exported names from the module are accessible via qualified `Module.Name` syntax in both type annotations and function call positions.
- **Proof predicates** — upper-case names such as `ValidPort` or `IsPositive` used in `:::` proof annotations are first-class exportable names, exactly like functions and types. A module that declares a predicate through an `establish`, `check`, or `auth` function must list it in `exposing [...]` to make it importable. Any other module that explicitly names the predicate in its own function annotations must import it. This makes every proof predicate greppable: searching the codebase for `ValidPort` in an `exposing [...]` list finds its home module immediately.
- **Top-level constants** — a bare binding (`kMax = 5`) can be exported and imported like a function **when its value's type is syntactically evident**: an `Int`/`Float`/`Bool`/`String` literal (including interpolated strings and negated numbers) or a homogeneous list of such literals. Cross-module signatures are annotation-driven and a bare constant carries no annotation, so a constant with any other value (a record literal, a constructor application, a computed expression) does not bind in the importing module; the importer's error explains the fix — wrap it in a zero-arg function (`fn kMax() -> T = ...`).

**Import ordering.** All `import` declarations must appear immediately after the `module` header, before any type, function, capability, or other top-level declaration. An `import` that appears after any other declaration is a **compile-time error**:

```tesl
# WRONG — import after a function definition
module Bad exposing []
import Tesl.Prelude exposing [Int]
fn f() -> Int = 1
import Tesl.Bool exposing [Bool]   # error: import must come before all definitions
```

**Module file resolution.** When a user module is imported (e.g. `import MyDomain`), the compiler looks for the file `my-domain.tesl` (PascalCase-to-kebab-case conversion) in the same directory as the importing file. If the file does not exist the compiler emits a clear error naming the path that was searched. This is a compile-time error, not a missing-name error downstream.

Module headers may contain several uppercase namespace segments, for example
`module NotesSchema.VCurrent exposing [Note]`. Schema-family imports also resolve
the conventional paths `schema/notes/v-current.tesl`, `schema/notes/v7.tesl`, and
`schema/notes/v-current/shared.tesl` for `NotesSchema.VCurrent.Shared`. The migration
namespace `NotesSchema.Migrate.V8` resolves to `migrations/notes/v8.tesl`. The family
stem before `Schema` is converted to kebab case. Resolution searches ancestors of
the importing file and stops at the nearest `tesl.toml`, `tesl.json`, or `.git`
project boundary. Existing same-directory kebab-case and PascalCase files retain
precedence. Qualified calls and type annotations retain the complete namespace;
two versions' same-named functions or newtypes remain separate.

**Schema content boundary.** Every schema module in a `FamilySchema.VCurrent` or
`FamilySchema.V<n>` namespace, including child modules, owns only
entities, records, types, facts, codecs, and pure `fn`, `check`, and `establish`
functions. This rule applies to the complete schema import closure, including
unexported declarations. The rule applies to standalone compilation and unsaved
editor buffers before any application binds the schema to a database. Its local imports must stay within the same family's
version; `Tesl.*` imports are allowed. Database declarations and connection
settings belong to the application, as do handlers, workers, `main`, capabilities,
effects, and test blocks. During the legacy `Database.entities` transition, an
entity imported from a schema family also selects this boundary. Ordinary
application modules retain their existing rules.

Modules in `FamilySchema.Migrate.*` also exclude connection configuration,
application declarations and effects. They may contain pure constants for
migration records and fixtures, pure functions, supporting types, and ordinary
`test` blocks over those functions. Such tests cannot declare capabilities or a
database connection; undeclared effects still fail normal capability checking. Entity
declarations belong in the schema. Imports stay within the same schema/migration
family or `Tesl.*`. This applies to standalone checks and unsaved buffers too.
Generated compatibility/support modules will require an explicit test-build
boundary; a module name alone does not grant historical storage operations.

Ordinary application modules, including their imported libraries and modules
containing tests, cannot import a historical `FamilySchema.V<n>` root or child
module (MIG015). They import `VCurrent`. Pure tests that construct historical
values belong in the family's `Migrate` namespace; this does not grant access to
the generated compatibility store.

The application binds an imported entity to its database before any module's
queries are generated. Query modules resolve that database by its compiled owner
identity at runtime; the schema does not import the application or carry a DSN.
Each versioned schema family has one database owner across the complete application
import graph. Splitting different entities of that family between two database
declarations is an error, as is combining different families in one database.
Historical `V<n>` entities cannot be bound to a connection; use `VCurrent` for
application data. These ownership checks also apply during the legacy
`Database.entities` transition and to new, unsaved application files. Local
application entities retain their legacy rules and are distinguished from
same-named, qualified-only schema imports.

**Frozen-copy reference rewrite.** Freezing replaces the version segment in the
owned module header, imports, and qualified references (`NotesSchema.VCurrent`
and its children become `NotesSchema.V<n>` and the corresponding children).
Comments and string literal text are preserved byte for byte. References inside
string interpolations are rewritten as expressions. Another family's references,
longer identifiers such as `VCurrentExtra`, and a nested prefix such as
`Wrapper.NotesSchema.VCurrent` are untouched. No formatter runs during this copy.
The source-edit layer returns the complete proposed text; applying the manifest
and verifying semantic history are separate checks.

**Canonical migration encoding, format 1.** Semantic hashes use a domain-separated
tree of byte strings and ordered lists. A byte string is `s<N>:<bytes>`, where `N`
is its UTF-8 byte count in unsigned decimal without leading zeroes. A list is
`l<N>:<children>`, where `N` counts children and each child uses this same encoding.
There is no whitespace or terminator between children. An empty string is `s0:`;
an empty list is `l0:`. Lengths count bytes, never Unicode characters. The hash
input is the encoding of `["tesl-migration-canonical", "1", domain, payload]`;
SHA-256 renders as lowercase hexadecimal. Domains are `snapshot`, `migration`,
`same`, `repair`, `contract`, and `provenance`; the same payload in two domains
has different identity. This wire format is independent of OCaml's runtime and
does not use an AST's printed source, memory representation, or source locations.

Schema symbols are fully resolved before encoding. A schema reference encodes as
`["schema", family, role, [remaining path segments]]`; other resolved global
references encode as `["global", [path segments]]`. A standalone snapshot or
`Same` closure uses role `snapshot`, replacing exactly its family's version
segment. A migration/repair/contract closure uses roles `from` and `to`, determined
by its contextual source and target modules. Those roles remain distinct: changing
a call from the old helper to the new same-named helper must change the migration
hash. Replacing `VCurrent` with its frozen `V<n>` keeps the role and hash unchanged.
References to an unbound schema revision are errors. Local binders use a separate
node kind and cannot impersonate global or schema references.

Scalar nodes carry a type tag. Ints use signed canonical decimal with no leading
zeroes and no negative zero; integer syntax and host integer width do not affect
the encoding. Float literals use exactly 16 lowercase hexadecimal digits for their
IEEE-754 binary64 bits, preserving negative zero. Non-finite literals are refused.
Strings retain their decoded bytes without Unicode normalization; Bools encode as
`true` or `false`. Field order is specified by each typed node's schema; consumers
must not serialize unordered maps directly. These encoding primitives alone do
not constitute semantic elaboration or a verified `Same` closure.

The typed declaration layer uses tagged lists with a fixed field order. A reference
is `["reference", namespace, identity]`, with namespace `value`, `type`, `predicate`,
or `codec`. A compiler primitive has identity `["primitive", semantic-ABI-tag]`;
an unresolved name or missing tag is an error. The compiler records every referenced
declaration, including private helpers and predicates minted by checks. A declaration
node by itself is not a closure: closure construction must additionally follow these
references and include all owners that can mint a referenced fact.

Every expression is `["expr", checked-type, operation]`. The checked type comes from
that AST node's identity and final function-local type substitution; source spans
are insufficient because distinct expressions can share a span. Named types use
`["named", reference]`, applications `["apply", head, argument]`, and arrows
`["arrow", domain, codomain]`. Inferred type variables are numbered by first
occurrence in the final declaration tree, traversed from left to right. Declared
type variables use a separate first-occurrence scope. Fresh-variable allocation
in an earlier compiler operation cannot affect a persistent hash.

An application spine uses `["call", callee, [arguments]]`; arguments retain source
order and intermediate application syntax has no independent type instantiation.
A zero-argument call uses `["call-zero", callee]`. The parser's empty-list sentinel
is omitted only when the checked callee is not an arrow or unresolved variable;
an actual empty-list argument remains an ordinary typed argument. Inline record
construction uses `["construct-fields", constructor-reference, [[field, value], …]]`;
the syntax-only constructor and record wrapper do not invent inferred types.

Local value and proof binders use `["local", lexical-depth]`, with depth starting
at zero. Parameter, let, lambda, case-pattern, and existential binders extend their
lexical scope; sibling branches do not share bindings. Their spelling and locations
are absent. Constructor subpatterns retain positional order; the surface AST's
pattern keys are not field selectors and are omitted, matching type checking and
Go emission. Declaration field names, argument order, case-arm order, guards, literal values,
return proof shapes, check versus establish kind, rejection status/message, codec
alternatives, table/column/index mappings, and explicit SQL type overrides are
retained. Record fields, ADT variants, and indexes retain declaration order. Pure
operations receive distinct tags; an effectful or not-yet-lowered form is refused
instead of receiving a placeholder hash. Comments, documentation, inferred record
type hints, and desugaring source locations are not semantic nodes.

A semantic closure encodes as `["closure", [roots], [[definition-key, node], …]]`.
Both roots and definitions are sorted by their complete encoded bytes and deduplicated;
an ambiguous definition is an error, not a last-writer-wins map entry. Constructor
references reach the defining newtype, ADT, record, or entity. Reaching a type also
reaches its codecs; reaching a fact also reaches every schema-owned check or establish
that can mint it. The initial owner analysis conservatively includes trusted functions
that mention that predicate, so it can require additional revalidation but cannot
omit an owner. Recursive helpers and fact/owner cycles are visited once. A missing
non-primitive definition refuses the closure. Building this inventory requires all
checked modules in the ownership boundary, including private declarations; an export
list is not an inventory of semantic dependencies.

The saved-source inventory loader starts at a schema revision root and follows
every owned local import, including private modules, diamonds and cycles. It
applies the ordinary compiler judgment to every member and checks storage
identities across the whole schema before publishing an abstract inventory.
Imported interfaces are refreshed for each load; a changed source file cannot
borrow an earlier load's type information. Changes detected across the load's
checking passes refuse the inventory.

An inventory result wraps its closure as
`["compiler-semantics", compiler-abi, closure]`. Its builtin references identify
the existing compiler's module and symbol; the outer ABI covers execution
semantics, including lowered operators, codecs and stdlib implementations.
No historical lowering or separate primitive-version registry is retained.
Even an empty inventory requires an ABI. A snapshot roots every declaration;
a per-type closure roots that declaration and its dependencies, including codecs
of nested record/ADT fields. Thus an unchanged SQL `jsonb` column can have a
different semantic closure. This loader does not yet implement historical
manifest checks, the contextual `Same` rule or a cross-ABI data transition.

The field-impact projection has one location per declared entity field, including
private entities in child modules. It uses the same typed lowering as the complete
declaration. Each contract is
`["compiler-semantics", compiler-abi, ["stored-field", field-node, dependency-closure]]`.
In this standalone field node, proof subjects referring to entity fields use
`["field-subject", field-name]`; adding or reordering a sibling must not rename an
existing proof subject by shifting its positional index. The complete declaration
encoding above is unchanged. The location identity is
`["stored-location", schema-entity-reference, field-name]`, with the same revision
alpha-renaming as snapshots.

Comparison reports added and removed locations, changed field definitions, and
changed dependencies under unchanged field text. A record codec, nested ADT, or
fact producer can therefore affect several entity fields while all their SQL types
remain `jsonb`. An unreferenced record or codec has no stored location. Comparison
refuses different schema families or compiler ABIs. The ABI supplied to the loader
identifies the compiler performing that load; it cannot request historical
execution semantics. This field projection neither checks persisted history nor
establishes rolling compatibility, physical catalog equivalence, a verified `Same`
bridge, or permission to remove a decoder. Those remain planner/runtime duties.

Type-like declarations are module-scoped. If two modules both define a name such as `User`, `Task`, or `Status`, those declarations remain distinct even when they share the same surface spelling. Loading one module must not change the meaning of an unqualified type name in another module.

If a module needs to use same-named imported type-like declarations from different modules, the ambiguity must be resolved by module qualification/prefixing. The compiler should reject unqualified ambiguous uses rather than merging declarations by bare name.

When modules form a cyclic import group (SCC), the compiler detects conflicting names across the group and mangles them internally. Qualified type annotations such as `Sandbox2.ARecord2` resolve correctly within the SCC, and field access on values of qualified types works via the existing record/entity runtime.

### 10.3 Qualification instead of extension methods
**Accepted design, Implemented.**

Functions should not be magically attached to values.

The canonical style is namespaced function calls, for example:

- `String.length(title)`
- `String.startsWith(title, "prefix")`
- `Int.parse(raw)`
- `List.isEmpty(xs)`

Receiver-style syntax such as `title.length` or `title.startsWith("x")` is not part of the language.

### 10.4 Standard library vs core language
**Accepted design.**

The specification distinguishes:

- **core syntax and semantics**;
- **standard library / Prelude names**.

`Maybe` and `Result` should be treated as ordinary standard-library ADTs, not as special language forms. If the current implementation bootstraps them specially during lowering or import resolution, that is an implementation detail rather than a language fact.

Similarly, names such as `Int`, `String`, `Fact`, `time`, `dbRead`, `dbWrite`, and common helper functions may be provided by Prelude, but they should be understood as library-level names unless the language explicitly requires otherwise.

### 10.5 Current special module names
**Implemented, but non-normative.**

The current frontend gives special treatment to these module names:

**Core infrastructure**

- `Tesl.Prelude` — core type symbols (`Int`, `Bool`, `String`, `List`, `Fact`, etc.), and fact operations (`attachFact`, `detachFact`, `forgetFact`, `andLeft`, `andRight`, `introAnd`)
- `Tesl.Id` — ID generation (`generatePrefixedId`). Requires the `random` capability — callers must import `random` from `Tesl.Random` and declare it in their capability's `implies` chain.
- `Tesl.Random` — randomness capability (`random`) and functions (`randomInt`). The `random` capability gates all non-deterministic operations. Import it alongside `Tesl.Id` when using `generatePrefixedId`, or standalone when calling `randomInt`.
- `Tesl.Tuple` — tuple constructors and accessors (`Tuple2`, `Tuple3`, `Tuple2.first`, `Tuple2.second`, `Tuple3.first`, `Tuple3.second`, `Tuple3.third`).
- `Tesl.Env` — environment variable access (`env`, `envInt`)
- `Tesl.DB` — database capability constructors (`dbRead`, `dbWrite`). Imports keep those bare names,
  for example `import Tesl.DB exposing [dbRead, dbWrite]`, but every grant, `requires` entry, and
  `implies` target must apply one to an entity: `dbRead Order` or `dbWrite Order`.
- `Tesl.Http` — HTTP request type (`HttpRequest`). Dot-access fields, each a `Dict String String`: `request.cookies`, `request.headers` (names lowercased), `request.queryParameters` (URL-query values are form-url-decoded; repeated keys are last-wins; keys are case-sensitive). Also `request.body` (a `String`, not a `Dict`): the raw request body exactly as it arrived, decoded as UTF-8. It exists for verifying an inbound signature — a MAC must be computed over the bytes that arrived, not over a re-encoded record — and it is not a way to skip a codec: a `String` still cannot become a record without one. Also `request.clientAddress` (a `String`, not a `Dict`): the trustworthy client IP — with no `trustedProxies` declaration (§23) it is the socket peer; with one it is the rightmost untrusted `X-Forwarded-For` hop, and a disagreeing chain is refused. An api-test supplies query parameters inline in the path, e.g. `get "/search?q=hello%20world"`. Also the **session cookie**: `Http.setSessionCookie`, `Http.clearSessionCookie`, `Http.sessionToken` and the `cookieCap` capability. See §21.8.
- `Tesl.Telemetry` — `TelemetryConfig`, the legacy startup form `initTelemetry`, the ambient span/log
  form `telemetry`, and the metric instruments (`counter`, `histogram`, `gauge`). See §5.2.
- `Tesl.Queue` — queue capabilities (`queueRead`, `queueWrite`, `pubsub`), proof predicates (`FromQueue`, `FromDeadQueue`)
- `Tesl.Crypto` — password storage, message authentication, digests and secrets (`PasswordHash`, `Signature`, `Secret`; facts `HashFor`, `PasswordVerified`, `Authentic`). Every primitive is libsodium. Reuses `random` for the two operations that draw randomness; introduces no capability of its own. See §21.7.
- `Tesl.UUID` — UUID generation and validation: `UUID.v4`, `UUID.v7`, `UUID.validate`, `IsUuid` proof predicate, `uuidV4Codec`, `uuidV7Codec`. The `uuid` capability gates generation; `UUID.validate` requires no capability. See §21.1.
- `Tesl.JWT` — JSON Web Token support: `JWT.sign`, `JWT.verify`, `JWT.decode`, and the nominal newtype `JwtToken`. The signing key is `Tesl.Crypto`'s `Secret` — one key-material type for the whole language. The `jwt` capability gates all operations; `JWT.sign` also requires `time`. Algorithm: HS256. Tokens are **session** tokens: `JWT.sign` stamps a fixed one-hour `exp` in epoch **seconds** (RFC 7519) and the expiry is not a parameter. `JWT.verify` mints `Authentic` on the claims. See §21.2.
- `Tesl.HttpClient` — outgoing HTTP requests: `HttpClient.get`, `HttpClient.post`, `HttpClient.put`, `HttpClient.delete`, the `HttpResponse` record, and the `httpClient` capability. See §21.3.

**String and number utilities**

- `Tesl.String` — string functions: `String.length`, `String.isEmpty`, `String.trim` (→ `IsTrimmed`), `String.toUpper` (→ `IsUpperCase`), `String.toLower` (→ `IsLowerCase`), `String.startsWith`, `String.endsWith`, `String.contains`, `String.split`, `String.join`, `String.replace`, `String.slice`, `String.padLeft`, `String.padRight`, `String.indexOf`, `String.toInt`, `String.fromInt`, and more. Also exports check function `String.requireNonEmpty` (→ `IsNonEmpty`) and proof predicate name constants `IsTrimmed`, `IsUpperCase`, `IsLowerCase`, `IsNonNegative`, `IsNonEmpty`.
- `Tesl.Regex` — regular expressions over `String`: `Regex.matches`, `Regex.find`, `Regex.findAll`, `Regex.captures`, `Regex.replace`, `Regex.split`. The pattern is argument 1 of every function and must be a **string literal** — it is parsed and safety-checked at compile time (`VREGEX001`–`VREGEX004`), so there is no dynamic-pattern form. Pure — no capability. See §21.6.
- `Tesl.Url` — URL component parsing: the opaque `Url` type plus `Url.parse`, `Url.scheme`, `Url.host`, `Url.port`, `Url.effectivePort`, `Url.path`, `Url.query`, `Url.fragment`, `Url.userInfo`, `Url.toString`. `Url.parse` is the only constructor, so `Url.host` is always canonical (lowercased, trailing dot stripped, unbracketed, IP literals folded) and never carries the port. Pure — no capability. See §21.9.
- `Tesl.Net` — host classification: the `HostClass` ADT (`Loopback`, `PrivateIp`, `LinkLocal`, `Cgnat`, `Multicast`, `Unspecified`, `PublicIp`, `DomainName`, `InvalidHost`) with `Net.classifyHost`, `Net.normalizeHost`, `Net.isForbiddenHost` and the per-range predicates. Every `inet_aton` and IPv4-mapped spelling of an address folds to one canonical form before classification. Pure — no capability. See §21.9.
- `Tesl.Int` — integer functions: `Int.parse`, `Int.abs`, `Int.min`, `Int.max`, `Int.clamp`, `Int.pow`, `Int.gcd`, `Int.lcm`, `Int.isPositive`, `Int.isNegative`, `Int.isEven`, `Int.isOdd`, `Int.toString`, `Int.sign`, `Int.toFloat`. Also `Int.nonZero` (check function → `IsNonZero`), `Int.nonNegative` (check function → `IsNonNegative`), and `Int.divide` (requires `IsNonZero` on the denominator). Exports `IsNonNegative`, `IsNonZero`.
- `Tesl.Float` — floating-point functions: `Float.parse`, `Float.abs`, `Float.min`, `Float.max`, `Float.clamp`, `Float.ceil`, `Float.floor`, `Float.round`, `Float.sqrt`, `Float.pow`, `Float.log`, `Float.exp`, `Float.sin`, `Float.cos`, `Float.tan`, `Float.isNaN`, `Float.isInfinite`, and more. Also `Float.requireNonZero` (check function → `FloatNonZero`) and `Float.div` (proof-total, requires `FloatNonZero` on the denominator). Exports `FloatNonZero`.

**Collection utilities**

- `Tesl.List` — list functions: `List.length`, `List.isEmpty`, `List.head`, `List.tail`, `List.last`, `List.nth`, `List.map`, `List.filter`, `List.filterMap`, `List.foldl`, `List.foldr`, `List.append`, `List.concat`, `List.reverse`, `List.sort` (→ `IsSorted`), `List.sortBy` (→ `IsSorted`), `List.contains`, `List.find`, `List.findIndex`, `List.take` / `List.drop` / `List.repeat` (proof-total and require `IsNonNegative` on the count argument), `List.zip`, `List.zipWith`, `List.unzip`, `List.sum`, `List.product`, `List.maximum`, `List.minimum`, `List.any`, `List.all`, `List.count`, `List.partition`, `List.range`, `List.unique`, `List.filterCheck` (→ `ForAll P`), `List.allCheck` (→ `Maybe (List T ::: ForAll P)`), and more. Exports `IsSorted`, `IsNonNegative`.
- `Tesl.Maybe` — the `Maybe` ADT with constructors `Something` and `Nothing`
- `Tesl.Result` — the `Result` ADT with constructors `Ok` and `Err`
- `Tesl.Either` — the `Either` type (Left/Right): `Left`, `Right`, `Left?`, `Right?`, `Left-value`, `Right-value`, `Either.map`, `Either.mapLeft`, `Either.andThen`, `Either.withDefault`, `Either.toMaybe`, `Either.fromMaybe`, `Either.partition`
- `Tesl.Dict` — immutable key-value map: `Dict.empty`, `Dict.singleton`, `Dict.insert`, `Dict.remove`, `Dict.lookup` (Maybe-returning lookup), `Dict.requireKey` (check function → `HasKey key dict`), `Dict.get` (proof-total and requires `HasKey key dict`), `Dict.member`, `Dict.size`, `Dict.isEmpty`, `Dict.map`, `Dict.filter`, `Dict.union`, `Dict.unionWith`, `Dict.intersection`, `Dict.difference`, `Dict.fromList`, `Dict.toList`. Also exports the proof predicate name `HasKey`.
- `Tesl.Set` — immutable unique-element set: `Set.empty`, `Set.singleton`, `Set.insert`, `Set.remove`, `Set.member`, `Set.size`, `Set.isEmpty`, `Set.union`, `Set.intersection`, `Set.difference`, `Set.isSubset`, `Set.map`, `Set.filter`, `Set.foldl`, `Set.any`, `Set.all`, `Set.partition`, `Set.fromList`, `Set.toList`, `Set.filterCheck` (→ `ForAll P`), `Set.allCheck` (→ `Maybe (Set T ::: ForAll P)`)

**Time**

- `Tesl.Time` — time functions and the `PosixMillis` newtype:
  - `PosixMillis` — newtype wrapping `Int` (milliseconds since Unix epoch). Automatically maps to `BIGINT` in PostgreSQL — **no `@db(bigint)` annotation needed** for `PosixMillis` fields.
  - `nowMillis()` → `PosixMillis` — current POSIX time in milliseconds
  - `formatTime(ms: PosixMillis, timezone: String, fmt: String)` → `String`
  - `durationMs(pastMs: PosixMillis)` → `Int` — milliseconds elapsed since pastMs (requires `time`)
  - `addMs(ts: PosixMillis, delta: Int)` → `PosixMillis` — add delta ms to a timestamp
  - `subtractMs(ts: PosixMillis, delta: Int)` → `PosixMillis`
  - `TimeZone` — a FIXED ADT of time zones: `Utc`, `FixedOffset offsetMinutes`, and one constructor per IANA zone baked from the system tzdata (`EuropeStockholm`, `AmericaNewYork`, … — 489 zones incl. the familiar link names; generated by `scripts/gen-tz-zones.py` into `compiler/lib/tz_zones.ml`). A typo'd zone is an unknown-constructor compile error and completion lists every zone. Zone constructors resolve their UTC offset **per instant** (DST-correct — no summer/winter bookkeeping); the runtime reads the system tzdata directly (`dsl/private/tzif.rkt`, RFC 8536 + POSIX footer rules)
  - `Time.truncHour/truncDay/truncWeek/truncMonth/truncYear(zone: TimeZone, ts: PosixMillis)` → `PosixMillis` — bucket-start instant for the wall clock in that zone (week = ISO Monday start); pure, and the only PosixMillis operations usable as a `groupBy` bucket key (GitHub #29)
  - `Time.offsetAt(zone: TimeZone, ts: PosixMillis)` → `Int` — the zone's UTC offset in minutes at that instant
  - `diffMs(a: PosixMillis, b: PosixMillis)` → `Int` — b − a in milliseconds
  - `Time.posixToSeconds(ms: PosixMillis)` → `Int`
  - `Time.secondsToPosix(s: Int)` → `PosixMillis`

**Time convention.** All timestamps use `PosixMillis`; all deltas/durations use `Int`. A plain `Int` does **not** satisfy a `PosixMillis` expectation — use `Time.secondsToPosix(s)` or `addMs(base, delta)` to construct typed timestamps. `PosixMillis` does **not** auto-unwrap for arithmetic — use `diffMs`, `addMs`, or `subtractMs` explicitly. Use `nowMillis()` on insert; format with `formatTime` at API boundaries only — never store pre-formatted strings.

```tesl
import Tesl.Time exposing [nowMillis, PosixMillis, time]

entity Post table "posts" primaryKey id {
  id:          String
  publishedAt: PosixMillis    # BIGINT — no @db annotation needed
}

handler post createPost(...) requires [dbWrite Post, time] =
  insert Post { id: newId, publishedAt: nowMillis() }
```

**Why `BIGINT` not `TIMESTAMPTZ`?** Both use 8 bytes. `BIGINT`/epoch is portable, free of timezone surprises, and trivial to sort/compare with integer arithmetic. Convert when you need PostgreSQL date functions: `to_timestamp(ts / 1000.0)` and `extract(epoch from ts) * 1000`.

**Money and units**

- `Tesl.Money` — exact money: `Money` (integer MINOR units + intrinsic ISO 4217 `Currency`, a fixed baked ADT — `Usd`, `Eur`, … 155 codes), per-currency constructors (`Money.usd`, …), `Money.display`, `Money.scale`/`Money.scaleBy`, proof-gated arithmetic (`Money.add`/`Money.subtract`/`Money.compare` require `SameCurrency a b`, minted by `Money.requireSameCurrency`), explicit runtime-supplied `ExchangeRate` conversion (`Money.convert` / `Money.convertChecked`), money RATES per quantity (`Money / Duration : MoneyPerDuration`, `rate * Duration : Money` — hourly billing, price per kg), and proof predicates `SameCurrency`, `NonNegativeMoney`, `RateFor`. Pure — no capability. See §21.4.
- `Tesl.Units` — compile-time SI dimensional analysis, erased to `Float` at runtime: quantity alias types (`Length`, `Mass`, `Duration`, `Speed`, `Area`, …), unit constructors/accessors (`Length.meters`, `Speed.inKilometersPerHour`, …), operator dimension algebra (`Acceleration * Duration : Speed`), and per-call-site polymorphic ops (`Units.mul/div/square/sqrt/abs/negate/min/max/sum/requireNonZero`). The alias type names are import-gated. Pure — no capability. See §21.5.

That is currently useful for bootstrapping, but the important public point is explicit importing and qualification, not the exact bootstrap mechanism.

### 10.6 Standard library GDP proofs
**Accepted design, Implemented.**

Several standard library functions return proof-bearing values. These proofs can be propagated through function signatures using the `?` return annotation.

**Proof-returning transformation functions:**

| Function | Proof attached to result | Usage |
|---|---|---|
| `String.trim`, `String.trimLeft`, `String.trimRight` | `IsTrimmed result` | Ensures caller has trimmed whitespace |
| `String.toUpper` | `IsUpperCase result` | Ensures string is uppercase |
| `String.toLower` | `IsLowerCase result` | Ensures string is lowercase |
| `List.sort`, `List.sortBy` | `IsSorted result` | Ensures list is sorted |

**Check functions (use with `let x = check f(n)`):**

| Function | Proof on success | On failure |
|---|---|---|
| `Int.nonZero(n)` | `IsNonZero n` | `fail 400` |
| `Int.nonNegative(n)` | `IsNonNegative n` | `fail 400` |
| `Float.requireNonZero(f)` | `FloatNonZero f` | `fail 400` |
| `String.requireNonEmpty(s)` | `IsNonEmpty s` | `fail 400` |
| `Dict.requireKey(key, dict)` | `HasKey key dict` on the dict | `fail 400` |

**Proof-total arithmetic and collection access:**

All of the following functions require a proof at the call site — the compiler rejects calls that lack the required proof:

| Function | Required proof | How to obtain |
|---|---|---|
| `Int.divide(a, b)` | `b ::: IsNonZero b` | `check Int.nonZero(b)` |
| `Float.div(a, b)` | `b ::: FloatNonZero b` | `check Float.requireNonZero(b)` |
| `List.take(n, xs)` | `n ::: IsNonNegative n` | `check Int.nonNegative(n)` |
| `List.drop(n, xs)` | `n ::: IsNonNegative n` | `check Int.nonNegative(n)` |
| `List.repeat(x, n)` | `n ::: IsNonNegative n` | `check Int.nonNegative(n)` |
| `Dict.get(key, dict)` | `dict ::: HasKey key dict` | `check Dict.requireKey(key, dict)` |

```tesl
fn safeDivideInt(a: Int, b: Int) -> Int =
  let divisor = check Int.nonZero(b)
  Int.divide(a, divisor)

fn safeDivideFloat(a: Float, b: Float) -> Float =
  let divisor = check Float.requireNonZero(b)
  Float.div(a, divisor)

fn safeTake(xs: List Int, n: Int) -> List Int =
  let count = check Int.nonNegative(n)
  List.take(count, xs)

fn requireUser(userId: String, users: Dict String String) -> String =
  let checkedUsers = check Dict.requireKey(userId, users)
  Dict.get(userId, checkedUsers)
```

**Return type annotation for proof-propagating functions:**

Use the `?` named-pack form to declare that a `fn` function propagates a stdlib proof:

```tesl
fn normalizeTitle(raw: String) -> String ? IsTrimmed =
  String.trim(raw)                    # proof automatically propagated

fn sortedItems(xs: List String) -> List String ? IsSorted =
  List.sort(xs)                       # proof automatically propagated
```

The entity-append rule expands `IsTrimmed` to `(IsTrimmed _entity)` where `_entity` is the returned value's hidden GDP subject.

**Important syntax note:**

```tesl
# WRONG — `result` is unbound in this position
fn f(s: String) -> String ::: IsTrimmed result = String.trim(s)

# RIGHT — ? form inserts _entity automatically
fn f(s: String) -> String ? IsTrimmed = String.trim(s)

# ALSO VALID — no proof annotation; proof is still attached at runtime
fn f(s: String) -> String = String.trim(s)
```

## 11. Surface grammar for top-level declarations
### 11.1 Overview
**Accepted design.**

```text
<module-file> ::= <module-header> { <import-line> } { <top-level-form> }

<top-level-form> ::= <capability-decl>
                   | <fact-decl>
                   | <type-decl>
                   | <record-decl>
                   | <entity-decl>
                   | <database-decl>
                   | <binding-decl>
                   | <function-decl>
                   | <capture-decl>
                   | <api-decl>
                   | <server-decl>
                   | <main-decl>
                   | <test-block>
                   | <queue-decl>
                   | <sseChannel-decl>
                   | <cache-decl>
                   | <email-decl>
                   | <agent-decl>
```

`main` is an ordinary `<function-decl>` returning an `App` (§11.13); `<main-decl>` is called out separately only because it is the application entry point. There is no `workers`/`deadWorkers` declaration — workers are folded into the queue's `jobs` list (§11.15, §11.17).

`const` is not part of the intended public language. Top-level immutability is already the default.

### 11.14 Test blocks
**Accepted design, Implemented.**

```text
<test-block> ::= "test" <string> [ "requires" "[" <capability-list> "]" ]
                 [ "with" <integer> "runs" ] [ "with" "database" <identifier> ]
                 "{" { <test-statement> } "}"

<test-statement> ::= "expect" <expr> <comparison-op> <expr>
                   | "expect" <expr>
                   | "expectFail" <expr>
                   | "property" <string> "(" <prop-params> ")" "{" <expr> "}"
                   | "let" <identifier> "=" <expr>
                   | <expr>

<prop-params> ::= <prop-param> { "," <prop-param> }
<prop-param> ::= <identifier> ":" <type> [ "where" <expr> ]
```

Test blocks are first-class top-level declarations. They compile to Go test functions and run with `go test`.

**`expect`** checks equality, comparison, or truthiness. **`expectFail`** asserts that an expression returns a check-fail or raises an exception.

**`let` with proof annotation.** Test block `let` bindings support an optional type annotation with proof declaration:

```tesl
let result: Int ::: IsPositive result && IsSmall result = makeValue p
```

The compiler validates that the function on the right-hand side actually returns the declared proof predicates. If `makeValue` does not return `IsSmall`, it is a compile-time error — the annotation documents the expected proof shape and is statically verified:

```tesl
# ERROR — makeWithAdminCargo returns IsPositive and IsAdmin, not IsSmall
test "type-checked binding" {
  let result: Int ::: IsPositive result && IsSmall = makeWithAdminCargo p admin
}
```

This prevents accidentally documenting the wrong proof shape in a test binding. Use `:::` (not `?`) in test let annotations — `?` is a return-type operator, not a binding-type operator.

**`property`** runs randomized property-based tests. Parameters are typed and random values are generated from the type. An optional `where` clause filters generated values. The run count defaults to 100 and can be overridden with `with N runs` on the test header.

```tesl
test "add is commutative" with 50 runs {
  expect add 3 7 == 10
  expectFail positive(-5)
  property "commutative" (x: Int, y: Int) { add x y == add y x }
  property "positive > 0" (n: Int where n > 0 && n < 10000) { n > 0 }
}
```

**Test databases.** Tests run against an automatic in-memory store by default — the case the vast majority of tests use, and which needs no configuration. To run a test body against a specific configured backend, add an optional `with database X` header clause; it binds the named database `X` so that queries inside the block run against `X`'s configured backend:

```tesl
test "rejects duplicate emails" with database AppDb {
  # queries here run against AppDb's configured backend
}
```

Run tests with `tesl test file.tesl`.

#### API tests

`api-test` blocks run end-to-end requests against a compiled server value from within Tesl itself.

```text
<api-test-block> ::= "api-test" <string> "for" <identifier> [ "requires" <capability-list> ] "{" [ <seed-block> ] { <api-test-statement> } "}"
<seed-block>     ::= "seed" "{" { <seed-statement> } "}"
<seed-statement> ::= "insert" <identifier> "{" { <field-init> } "}"
                   | "let" <identifier> "=" <expr>
                   | <expr>
<api-test-statement> ::= "expect" <expr> <comparison-op> <expr>
                       | "expect" <expr>
                       | "let" <identifier> "=" <expr>
                       | <expr>
<api-request-expr> ::= "get" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ]
                     | "post" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ] [ "body" <json-literal> ]
                     | "put" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ] [ "body" <json-literal> ]
                     | "delete" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ]
<api-stream-expr> ::= "subscribe" <string> [ "cookie" <string> ] [ "headers" <json-object-literal> ]
                    | "collect" <identifier> [ "count" <integer> ] [ "until" <json-literal> ] [ "timeout" <duration-literal> ]
```

Files using `api-test` must import `Tesl.ApiTest`. The compiler emits a targeted error if an `api-test` block is present without that import.

Each `api-test` block runs with a fresh in-memory database by default. Optional `seed {}` setup runs before the HTTP boundary and uses the ordinary `insert` syntax, so entity field names and types are still compile-time checked.

Request expressions return the compiler-known type `HttpResponse` with fields `status`, `body`, and `headers`. `body` is a `JsonValue`, and `Tesl.ApiTest` exposes helper functions such as `statusOk`, `jsonString`, `hasLength`, `fieldAt`, `subscribe`, `processNextJob`, and `processNextDeadJob` for asserting on raw JSON, SSE streams, and queue workers.

Queue processing helpers return `JobResult a`. `JobOk job` carries the processed job payload and
`JobFailed job message` carries that same payload plus a `String` failure message. Use
`expectJobOk` and `expectJobFailed` when the test needs a typed success or failure assertion; the
constructors are ordinary exhaustiveness-checked ADT cases with one type parameter, not a
polymorphic error parameter.

When `collect` uses `count` or `until`, a `timeout` clause is required. Queue helpers (`processNextJob`, `processNextDeadJob`, `drainQueue`, `pendingJobCount`) run workers synchronously during the test, making HTTP → queue → SSE flows deterministic.

#### Stubbing outbound HTTP

Code under test that calls OUT (`Tesl.HttpClient`, and therefore every `Tesl.Agent` provider call) is stubbed from inside the test rather than reaching the network. `Tesl.ApiTest` exposes six ordinary functions, usable as statements in a `test`, `api-test`, or `load-test` body:

| Function | Signature | Meaning |
|---|---|---|
| `stubHttp` | `(method: String) (url: String) (status: Int) (body: String) -> Unit` | Answer a matching call with this canned response. |
| `stubHttpFailure` | `(method: String) (url: String) (message: String) -> Unit` | Make a matching call fail like a refused connection. |
| `stubHttpTimeout` | `(method: String) (url: String) -> Unit` | Make a matching call raise exactly the timeout error a hung upstream produces (§21.3). |
| `httpCalled` | `(method: String) (url: String) -> Bool` | Was a matching call made? |
| `httpCallCount` | `(method: String) (url: String) -> Int` | How many matching calls were made? |
| `httpLastBody` | `(method: String) (url: String) -> String` | The request body of the last matching call. |

`"*"` matches any method or URL; a trailing `*` matches a URL prefix. Rules are consulted in declaration order (first match wins), and re-declaring the same method+URL pair replaces the earlier rule.

```tesl
test "the upstream-500 branch is reachable" requires [webClient] {
  stubHttp "GET" "https://api.example.com/rates" 500 "upstream exploded"
  let resp = fetchRates "https://api.example.com/rates"
  expect classifyStatusCode resp.status == "server-error"
  expect httpCallCount "GET" "https://api.example.com/rates" == 1
}
```

The stub table is created **fresh for every test block** and unwinds with it, so no rule and no recorded call can leak into the next test. Until a block declares its first stub, outbound calls behave exactly as before (they reach the network); from the first stub onward an *unmatched* call is a loud failure rather than a silent live request. The double exists only under the test framework — a production build has no stub registry at all.

#### Load Tests

`load-test` blocks run performance/throughput tests against a compiled server using an open
workload model (fixed arrival rate). They reuse the same `seed` and request syntax as
`api-test` blocks.

```text
<load-test-block>     ::= "load-test" <string> "for" <identifier>
                           "rate" <integer> "rps"
                           "duration" <integer> "s"
                           [ "baseline" <string> ]
                           [ "requires" <capability-list> ]
                           "{" [ <seed-block> ] <api-request-expr> { <load-test-assert> } "}"
<load-test-assert>    ::= "assert" <load-metric> <comparison-op> <number> [ <unit> ]
                        | "assert" "regressionVsBaseline" <load-metric> "<" <number>
<load-metric>         ::= "p50" | "p95" | "p99" | "p99.9" | "errorRate" | "throughput"
<unit>                ::= "ms" | "rps"
```

Load tests use coordinated-omission-aware latency measurement: requests are scheduled on a
fixed wall-clock interval and latency is measured from scheduled send time. A warm-up phase
runs until p99 stabilises, then the measurement phase runs for the specified `duration`.

Assertions check histogram percentiles, error rate, and throughput after the run.
`regressionVsBaseline` compares against stored baselines in `.tesl-baselines/`.

```tesl
load-test "list books throughput" for BookServer
  rate 100rps
  duration 10s
  requires [dbRead Book] {
  get "/books"

  assert p99 < 200ms
  assert p95 < 80ms
  assert errorRate < 0.01
  assert throughput > 80rps
}
```

#### Doctests

Doctests are test examples embedded in comments directly above a function declaration:

```tesl
#> double 5
#= 10
#> double 0
#= 0
#> property "always even" (n: Int) { double n % 2 == 0 }
fn double(n: Int) -> Int =
  n + n
```

`#>` introduces a test expression (or a property declaration) and `#=` specifies the expected result. Doctests are automatically extracted and compiled as test cases when running `--test`. Property-based doctests use the same `property` syntax as test blocks.

#### Custom generators with `via`

Property parameters can specify a custom generator function with `via`:

```tesl
import Tesl.Random exposing [random, randomInt]
capability testCap implies random

fn genSmallPositive() -> Int
  requires [random] =
  1 + randomInt(100)

test "custom gen" with 50 runs {
  property "small values" (n: Int via genSmallPositive) { n > 0 && n <= 100 }
}
```

The `via` function is called once per property run to produce a value. This allows domain-specific generators tailored to the test scenario. Custom generators that use `randomInt` must declare the `random` capability.

#### Record generators

Property tests automatically generate random values for record types by constructing the record with random field values. For proof-bearing record fields, the generator fabricates the required proof so the record constructor succeeds.

### 11.15 Queue declarations
**Accepted design, Implemented.**

A `queue` is a **folded record** assigned with `=`. It pairs each job type with its worker (and an optional dead-letter worker) in a single `jobs` list, names the backing database, and configures retry behaviour and worker concurrency. The capabilities the workers need are listed in the queue's `requires`.

```text
<queue-decl> ::= "queue" <identifier> "requires" "[" <capability-list> "]" "=" "Queue" "{"
                   "database" ":" <identifier>
                   "jobs" ":" "[" <job-entry> { <job-entry> } "]"
                   [ "retry" ":" "QueueRetryStrategy" "{" <retry-options> "}" ]
                   [ "numberOfWorkers" ":" <integer> ]
                 "}"

<job-entry> ::= "Job" <JobType> <workerFn> "(" <dead-slot> ")"
<dead-slot> ::= "Something" <deadFn> | "Nothing"

<retry-options> ::= { <retry-option> }
<retry-option>  ::= "maxAttempts"  ":" <integer>
                  | "backoff"      ":" ( "Exponential" | "Fixed" | "Linear" )
                  | "initialDelay" ":" <integer>
```

A `queue` declaration creates a background job queue backed by the named `database`. Each `Job <JobType> <workerFn> (<dead-slot>)` entry folds a `record` type together with its normal worker function and an optional dead-letter worker (`(Something deadFn)` or `(Nothing)`).

> **Durability (2026-09-02).** On a Postgres-backed database a `queue` is durable and shared: jobs are rows in `<schema>.tesl_jobs`, claimed with `FOR UPDATE SKIP LOCKED`, so any number of server instances work one queue; `enqueue` runs on the surrounding transaction; a failed job's `next_attempt_at` follows the declared `backoff`; a job whose instance died mid-run is reclaimed after its stored lease expires (`TESL_QUEUE_VISIBILITY_TIMEOUT_MS` sets the lease length, default 10 min). A stale normal claim returns to `pending`; a stale dead-letter claim returns to `dead`. The same holds for the `email` outbox (`tesl_email_outbox`), the `cache` (`tesl_cache`, `UNLOGGED`) and SSE pub/sub (`tesl_pubsub_outbox` + `LISTEN`/`NOTIFY` fan-out to every instance). The serial email worker claims one message immediately before each SMTP delivery, so queued messages do not consume their claim window waiting behind earlier deliveries. On a Memory-backed database all four stay in the process's memory: that is the development and test store. Workers are woken by `NOTIFY tesl_queue` from any instance over one shared LISTEN connection per process, with a 5 s fallback poll; the stale-claim sweep runs once a minute per process.

Queue claims carry a monotone per-row `claim_seq`, an opaque attempt token, and a
database-clock `lease_until`. Pending and dead-letter handlers renew their claim
every third of its lease length. Renewal, completion and retry compare the current
attempt and require an unexpired lease outside the transaction that created the
claim; an expired attempt cannot revive itself,
delete another attempt's row or change its retry state. Renewal stops on ownership
loss or a database error, and is cancelled and joined when the handler returns or
traps. Claims processed inside their original explicit transaction already hold
the row lock and may finish there after their timestamp expires; they do not start
renewal on another connection. A later transaction cannot use this exception.
External handler effects remain
at-least-once: fencing queue state does not undo an HTTP call from an expired attempt.

`retry` configures how failed worker jobs are retried. `maxAttempts: 1` (the default) means no retries. With `backoff: Exponential` and `initialDelay: N` the delay between retries doubles: N, 2N, 4N, … seconds. With `backoff: Fixed` the delay is always `initialDelay`.

`numberOfWorkers: N` (default 1) sets how many parallel normal-worker threads run when the queue is activated. Listing the queue in `App.queues` activates these N workers plus, if any job has a dead slot, the single dead-letter worker — there is no explicit start call.

```tesl
queue EmailQueue requires [emailWrite] = Queue {
  database: MainDatabase
  jobs: [
    Job SendEmail   sendEmailWorker  (Something handleDeadEmail)
    Job GeneratePDF generatePdfWorker (Nothing)
  ]
  retry: QueueRetryStrategy {
    maxAttempts: 3
    backoff: Exponential
    initialDelay: 60
  }
  numberOfWorkers: 4
}
capability emailWrite implies queueWrite EmailQueue
capability emailRead  implies queueRead EmailQueue
```

Built-in `queueRead` and `queueWrite` capabilities come from `Tesl.Queue` (analogous to `dbRead`/`dbWrite` from `Tesl.DB`).

**The job store is internal; an external consumer is not supported.** Jobs live in a `tesl_jobs` table inside the app's own database. That table is an implementation detail — unversioned, and with no `result` column — and when no PostgreSQL runtime is configured the queue is in-memory instead, so nothing external can attach in dev or tests. The decisive reason is not practical, though: consuming `tesl_jobs` from a non-Tesl process means handing that process the app's database credentials, and a process with database **write** access can plant rows that violate declared record invariants. The checker enforces those invariants at the *write* site, and the read path does not re-check them, so Tesl would read such rows back and treat the facts as established. It is the one grant that defeats the proof system. Foreign work belongs behind an outbound call made from a `worker` — see [Interop and Foreign Work](manual/best-practices.md#interop-and-foreign-work) in the manual.

### 11.16 SSE channel declarations
**Accepted design, Implemented.**

An `sseChannel` is a **folded record** assigned with `=`:

```text
<channel-decl> ::= "sseChannel" <identifier> "(" <binding> { "," <binding> } ")" "=" "SseChannel" "{"
                     "database" ":" <identifier>
                     "payload"  ":" <identifier>
                   "}"
```

An `sseChannel` declaration creates a typed pub/sub channel backed by the named database (via the outbox pattern). The key parameters follow the same binding syntax as function parameters, including proof annotations. The `payload` type must be an ADT — all event variants must be declared before the channel.

```tesl
type UserEvent
  = ProfileUpdated bio: String
  | AvatarChanged  url: String
  | AccountDeleted

sseChannel UserEvents(userId: String ::: UserId userId) = SseChannel {
  database: MainDatabase
  payload: UserEvent
}
```

The `tesl_pubsub_outbox` table is created automatically alongside entity tables. Events published inside `transaction` are written to the outbox atomically, and in-memory listeners are called after commit. Events published outside a transaction call listeners directly (at-most-once; a linter warning is planned).

The SSE fan-out is driven by in-memory listener callbacks. A PostgreSQL LISTEN connection for multi-process fan-out runs automatically when the runtime detects SSE endpoints and a PostgreSQL database is active. Listing the channel in `App.sseChannels` activates its outbox delivery.

Built-in `pubsub` capability comes from `Tesl.Queue`.

### 11.17 Worker declarations
**Accepted design, Implemented.**

`worker` (and `deadWorker`) is a function kind (alongside `fn`, `check`, `establish`, `auth`, `handler`) for background job processors:

```text
<function-kind> ::= "check" | "establish" | "fn" | "auth" | "handler" | "worker" | "deadWorker"
```

Worker functions receive a proof-bearing job value (`FromQueue` proof, analogous to `FromDb`), perform their work, and either complete normally (job marked done) or `fail` (job marked failed, eligible for retry):

```tesl
worker sendEmailWorker(job: SendEmail ::: FromQueue (Id == jobId) job)
  requires [smtpSend] =
  let _ = sendMail(job.to, job.subject, job.body)
  job   # a worker body must return the job value
```

A worker (and `deadWorker`) body **must return the job value** — its declared return type *is* the job type (`SendEmail` here). End the body with `job` (which marks the job done) or with `fail …` (which marks it failed and eligible for retry). Returning any other value — for example the `HttpResponse` from an HTTP call made inside the worker — is a `T001` type error; bind such intermediate results with `let _ = …` and end the body with `job`.

`FromQueue (Id == jobId) job` follows the same 2-arg pattern as `FromDb (Id == pk) entity` — both the job's primary key subject and the job entity subject are in the proof.

**`FromQueue` is provenance, not validity.** It states exactly one thing: *this value came off the queue*. It does **not** state that the value is valid, that it satisfies any domain predicate, or — should external producers ever exist — that our own code enqueued it. A worker that needs a domain fact about the payload must establish it the ordinary way (`check`, `establish`, a `FromDb` lookup); `FromQueue` never substitutes for one. This mirrors `FromDb`, which likewise says "this row came from the database", not "this row is correct".

What makes the boundary trustworthy is not the proof but the **decode**. A job payload is reconstructed with `jsexpr->typed-value` (`tesl/queue.rkt:293`), the same validating decoder that HTTP request bodies cross, so newtype identity, ADT tags and field types are all re-established from JSON. It is additionally **fail-closed on proofs**: a record field carrying a `:::` annotation cannot decode at all unless the record registered an explicit `#:check` for it (`dsl/types.rkt:1394`; the field checker itself is `coerce-record-field-value`, `dsl/types.rkt:974`). A payload therefore cannot smuggle in a proof-annotated field that was never checked — decoding raises instead. Queue payloads are validated exactly as strictly as HTTP request bodies. Contrast a database row, which is *not* re-validated on read (§11.15) — data arriving through the decoder is checked; rows written behind the runtime's back are not.

There is no separate `workers` declaration. Worker functions are wired to job types directly inside the folded queue's `jobs` list (§11.15). A dead-letter worker is declared with `deadWorker` (it receives a `FromDeadQueue` proof) and is wired via the job's dead slot, `(Something handleDeadEmail)`:

```tesl
deadWorker handleDeadEmail(job: SendEmail ::: FromDeadQueue (Id == jobId) job)
  requires [alertCap] =
  telemetry "email.dead" { to = job.to }
  job   # returning the job acknowledges it (deletes the dead row)

# Wired in the queue's jobs list — normal worker + dead-letter worker:
queue EmailQueue requires [smtpSend, alertCap] = Queue {
  database: MainDatabase
  jobs: [Job SendEmail sendEmailWorker (Something handleDeadEmail)]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
```

### 11.18 AI agents
**Accepted design, Implemented.**

An agent is built with a single typed-record constructor, `Agent { … }`. It can be
declared at the top level as an `agent` binding **or** written as a plain expression
(e.g. to build a per-request, bring-your-own-key agent inside a function):

```text
<agent-decl> ::= "agent" <identifier> [ "requires" "[" <capability> { "," <capability> } "]" ] "=" <agent-ctor>
<agent-ctor> ::= "Agent" "{"
                   "provider"     ":" <expr>        -- an LlmProvider value
                   "systemPrompt" ":" <expr>        -- String
                   "maxTokens"    ":" <expr>        -- Int
                   "tools"        ":" <expr>        -- List Tool
                 "}"
```

`provider` is a full `LlmProvider` value built by one of the provider constructors —
`anthropic key model`, `openai key model`, `mistral key model`, `local endpoint model`,
or the deterministic `mockProvider [replies]` / `mockToolProvider [steps]` used in
tests. The model and key are arguments to the provider, so the type checker enforces
them (`anthropic : String -> String -> LlmProvider`). Read a server-side key with
`requireEnv "VAR"` (`String`; fails fast if unset), the String counterpart to
`env : String -> Maybe String`.

`tools` is a `List Tool`. Wrap a typed Tesl function as a tool with `asTool`: the
JSON Schema is derived from the function's parameter types and the model's tool-call
arguments are decoded into those parameters under the hood — no hand-written schema or
validator. (For full manual control the lower-level `tool name desc schema validate
dispatch` constructor is still available.) Tool functions take only `String`, `Int`,
`Float`, `Bool`, or `PosixMillis` parameters. A `PosixMillis` parameter's derived
schema carries an epoch-milliseconds description so the model never mistakes the
integer for seconds or a formatted date.

**Tool capability delegation.** A tool function's `requires` is charged statically to
the site that wires it into an agent (the enclosing function, or the declarative
`agent` block's own `requires`) — but the tool *executes* later, inside the agent
loop, whose ambient capability set is the caller's, not the construction site's. The
emitted tool dispatch therefore **delegates the function's own declared
capabilities** around the call (and a `define`-d function passed to the manual `tool`
constructor delegates its registered `requires` the same way), so a tool that
type-checks cannot trap on a missing capability on a live turn. Delegation grants
exactly the declared `requires` of the wrapped function, nothing more, and only at
the tool boundary — ordinary calls still assert against the ambient grant.

**Tool failure containment.** Any exception raised by a tool body — including a
capability trap in a hand-built `tool` dispatch — is contained as an `is_error`
tool_result (`tool failed: …`), the agent-loop analogue of an HTTP 500: the model
sees the failure and the loop continues, matching the containment `serverTools`
endpoint tools have always had.

```tesl
fn lookupOrderStatus(orderId: String) -> String requires [dbRead Order] =
  case selectOne o from Order where o.id == orderId of
    Something o -> o.status
    Nothing -> "no such order"

# server-keyed agent (top-level block)
agent SupportAgent requires [supportAi] = Agent {
  provider: anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
  systemPrompt: "You are a concise support assistant."
  tools: [asTool lookupOrderStatus]
  maxTokens: 512
}

# bring-your-own-key agent (the SAME constructor, built per request)
fn agentForConsumer(c: Consumer) -> Agent requires [supportAi] =
  Agent {
    provider: anthropic c.apiKey "claude-opus-4-8"
    systemPrompt: "You are a concise support assistant."
    tools: [asTool lookupOrderStatus]
    maxTokens: 512
  }
```

**Server endpoints as tools (`serverTools`).** `serverTools MyServer user : List Tool`
derives one tool per non-SSE endpoint of the server's api, **preauthenticated** with the
proof-carrying authenticated user value — the tools are the same handler functions the
HTTP API dispatches to, partially applied with that value, so the agent acts strictly on
the user's behalf and every authorization check in the handler bodies runs unchanged.
No session forwarding or token minting is involved; the proof system makes "on behalf of
the user" a static requirement.

```tesl
handler post assistant(user: User ::: Authenticated user, q: Question) -> String
  requires [todoWebService, supportAi] =
  let agent = Agent {
    provider: anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
    systemPrompt: "You act on the user's todos via the provided tools."
    maxTokens: 512
    tools: serverTools TodoServer user   # every endpoint, for free
  }
  ask agent q.text
```

Statics (all compile errors when violated):

- Both arguments are structural: a **bare reference** to a `server` declared in the
  module, and a **bare variable** holding the user.
- **Per-endpoint inclusion is decided at each call site** from the user variable's
  declared proof annotation: an endpoint becomes a tool iff the annotation covers the
  endpoint's `auth` predicates. A `u ::: Authenticated u` user exposes the plainly
  authenticated endpoints; a `u ::: Authenticated u && Admin u` user (a handler
  parameter, or a `let admin = check requireAdmin u` upgrade) additionally exposes the
  admin-gated ones. A user value matching **no** authed endpoint is rejected. Endpoints
  without an `auth` line are always included; SSE endpoints never are.
- Every authed endpoint of the api must bind the same user type (one value is applied
  to all of them), and every `capture` parameter must be an agent-prim (same whitelist
  as `asTool` parameters).
- The enclosing function is charged the union of the bound handlers' declared
  capabilities — exposing a server to an agent means the agent may do anything those
  handlers can.

At runtime each endpoint tool also **delegates its bound handler's declared
capabilities** around the dispatch (the same delegation `asTool` tools get), so the
server does not have to be mounted for its handlers' capabilities to be granted on a
live agent turn.

**Curated agent api (the two-api pattern).** Because `serverTools` derives tools from
the *server's* endpoint list, a second `api`/`server` pair that binds the **same
handler functions** but lists only a subset of endpoints acts as a compile-time tool
allowlist: the user-facing server keeps the full HTTP surface, the agent-facing server
(typically never mounted) decides exactly which of those handlers the model may call.
Tool derivation is per server — two `serverTools` call sites in one module do not
interact.

Each tool's name is the bound handler's own name, its description is that handler's
doc-comment (falling back to `"METHOD /path"`), and its input schema has one required
property per capture plus one for the `body` binder (an object derived from the body
record's `fromJson` codec). At runtime the tool reuses the endpoint's own boundary
pipeline — capture parser + `via` check + proof attach, body codec decode — so a tool
argument can never be validated more weakly than the HTTP boundary; a handler
`fail status "msg"` (or a runtime error) comes back to the model as an `is_error`
tool_result, the agent-loop analogue of the HTTP error response, and results are
JSON-encoded through the same path as HTTP responses — with one agent-only
difference: every `PosixMillis` value in a tool result is rendered as a
self-describing `{"epochMillis": <int>, "iso": "<UTC ISO-8601>"}` object instead of a
bare integer, so the model never has to (mis)guess a calendar date from epoch digits.
The HTTP wire format is unchanged, and a response type with a user-written `codec`
block keeps its authored shape. Generated Elm and TypeScript clients decode
`PosixMillis` tolerantly (bare integer or the enriched object), so both shapes are
always parseable client-side.

**Held-back endpoints as human actions (`humanActions`).** `humanActions MyServer user
: List Tool` is the exact **complement** of `serverTools` at the same call site: one
tool per endpoint whose auth predicates the user variable's declared proof does **not**
cover. Together `serverTools` (the agent may run) and `humanActions` (only the human
may) **partition** the server's endpoints — disjoint and complete. Because both are
decided from the *declared* proof, you make an action "human-only" by giving the agent a
`user` value scoped narrower than the human's real authority (e.g. the agent holds
`Authenticated`, the human is also `Admin`): the admin-gated endpoints then fall into
`humanActions`.

```tesl
handler post assistant(user: User ::: Authenticated user, q: Ask) -> String requires [notesAi] =
  let agent = Agent {
    provider:     anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
    systemPrompt: "Manage the user's notes. Admin-only actions must be asked of the human."
    maxTokens:    512
    tools:        List.append (serverTools NotesServer user) (humanActions NotesServer user)
  }
  ask agent q.text
```

A `humanActions` tool is **inert** — this is a language-level guarantee, not a prompting
convention. Calling it does **not** execute the endpoint: the runtime builder is handed
only the server *name* and the endpoints' metadata, never the server value or a handler
closure, so there is no in-process path from the tool to a call. Dispatching one returns
a `human-action-request` descriptor — `{ kind, server, action, args, handle }` — as the
tool_result. `action` is the endpoint's tool name; `args` is the model's *advisory*
prefill; `handle` is a fresh correlation id. The agent thus can only *choose which
held-back action to request and prefill its arguments* — it can never perform it. Statics
match `serverTools` (bare server reference, bare proof-annotated user variable, full
application only), and `humanActions` charges **no** capability (the opposite of
`serverTools`: the agent never runs these endpoints, so their `requires` is not charged).

The frontend renders the request as a typed button. `tesl generate elm|ts` emits, per
server, a `<Server>HumanAction` tag union with one constructor per endpoint and a
`<Server>HumanActionRequest` decoder that **rejects any `action` the server did not
declare** — a compile-time allowlist. The real endpoint URL is resolved by the generated
endpoint client the app calls in its `case` arm (never taken from the wire), so a
prompt-injected agent can neither fabricate an action, relabel it, nor redirect it. When
the human clicks, their browser calls the real endpoint under their own session (which
re-checks auth server-side); to let the agent continue, append the completed
`{ action, handle, result }` to the persisted conversation and run another `converse`
turn ("resume-after" — the runtime does not suspend the turn).

**Long-running work over a queue (resume-after, no new surface).** The same resume-after
shape covers *machine* work an agent starts but should not block on. A tool the agent
calls (a `serverTools` handler, or a `tool` whose dispatch captures the conversation id)
only `enqueue`s a job and returns "queued"; the turn ends at once. A `worker` does the
slow work later and, at completion, `publish`es to the conversation's SSE channel (and/or
`Email.send`s) **and resumes the conversation** — load its transcript with
`conversationFrom`, run one more `converse` with the result as the message, persist with
`conversationJson`. The conversation id carried on the job is the "this conversation is
awaiting that result" record; completion re-enters exactly that conversation. Nothing is
suspended (a resumed turn is just another `converse`, run on the worker), so a
never-completed job never pins a request. This is pure composition of `enqueue` /
`worker` / `publish` / the conversation primitives — no agent-specific machinery. See
`example/learn/lesson70-agent-async-work.tesl`.

Running inference requires the `aiProvider` capability (from `Tesl.Agent`; it implies
`httpClient` because real providers perform outbound HTTP). The agent API:

- `ask agent prompt -> String` — one-shot; runs the tool-calling loop, returns the text.
- `askReply agent prompt -> AgentReply` — like `ask`, plus token usage + tool-call count
  (`replyText` / `replyTokens` / `replyToolCalls`).
- `askWith agent prompt provider -> AgentReply` — a per-call provider override (BYOK).
- `askFor agent prompt decoder maxRetries -> a` — ask for a typed value; the developer's
  `String -> a` decoder is retried up to `maxRetries` on a decode failure.
- Multi-turn conversation (the developer owns persistence): `newConversation` /
  `conversationFrom` build a `Conversation`; `converse` / `converseStreaming` advance it,
  returning a turn (`turnReply` / `turnConversation`); `conversationJson` /
  `conversationLength` inspect it. `converseStreaming conv prompt publish` calls `publish`
  with each tool-use / thought / reply step as it streams.

`Agent`, `LlmProvider`, `Tool`, `AgentReply`, `Conversation` are opaque types. There is
no separate `defineAgent`/`withTools` — the `Agent { … }` constructor is the only way to
build an agent.

### 11.2 Top-level immutable bindings
**Accepted design.**

```text
<binding-decl> ::= <identifier> "=" <expr>
```

### 11.3 Capabilities
**Accepted design, Implemented.**

```text
<capability-decl> ::= "capability" <identifier> [ "implies" <capability> { "," <capability> } ]
<capability>      ::= <identifier> [ <identifier> ]
```

The optional second identifier scopes a built-in resource capability. Database capabilities are
always entity-scoped: `dbRead Order` grants reads of `Order` but not `Customer`, and a bare
`dbRead` or `dbWrite` in any grant, `requires` list, or `implies` target is a compile error.
`dbWrite Order` covers `dbRead Order` as well as writes to `Order`; it never covers either access
to another entity. An imported constructor stays bare: `import Tesl.DB exposing [dbRead, dbWrite]`.

Queue and pub/sub scoping is implemented separately. `queueRead Jobs`, `queueWrite Jobs`, and
`pubsub UserEvents` constrain access to that queue or channel; `queueWrite Jobs` covers
`queueRead Jobs`. Bare queue/pubsub grants currently remain migration wildcards. No DB wildcard
is implied by that compatibility behavior.

### 11.4 Bindings and return specs
**Accepted design, Implemented.**

```text
<binding> ::= <identifier> ":" <gdp-expr> [ ":::" <gdp-expr> ]
<exists-binding> ::= <identifier> ":" <gdp-expr>

<return-spec> ::= "exists" <exists-binding> "=>" <plain-return-spec>
                | <plain-return-spec>

<plain-return-spec> ::= <binding>
                      | <gdp-expr> " ? " <gdp-expr> ":::" <gdp-expr>   -- new canonical form
                      | <gdp-expr> " ? " <gdp-expr>                    -- new canonical form, no other proofs
                      | "?" <gdp-expr> ":::" <gdp-expr>                -- legacy form (still accepted)
                      | "?" <gdp-expr>                                  -- legacy form (still accepted)
                      | <gdp-expr> ":::" <gdp-expr>
                      | <gdp-expr>
```

Interpretation:

- a plain return spec such as `Int` means an unannotated return type;
- an attached return spec such as `Int ::: Positive x` means an anonymous returned value with proof;
- a binding return spec such as `x: Int ::: Positive x` means the return is conceptually a named value whose proof may refer to that binder;
- a **named-pack** return spec such as `Todo ? FromDb (Id == id)` means the returned entity is automatically named by the caller's `let` binder (see section 7.13); the entity-append rule appends `_entity` to every leaf predicate in the `?` group;
- a **ForAll** return spec such as `List Note ::: ForAll (FromDb (AuthorId == user))` means every element of the returned list satisfies the given proof predicate (see section 16.9); compile-time only with zero runtime overhead;
- an existential return spec packages one unannotated witness and then a non-existential body return spec. Nested/multi-witness returns and `:::` annotations on the witness binder are rejected until their runtime contract is implemented.

Note: the current `.tesl` surface uses lowercase `exists ... => ...`. The elaborated Racket core currently uses `Exists`.

### 11.4b Fact (predicate) declarations
**Accepted design, Implemented.**

```text
<fact-decl> ::= "fact" <UpperIdentifier> { "(" <binding-list> ")" }

<binding-list> ::= <binding> { "," <binding> }
<binding>      ::= <identifier> ":" <type-expr>
```

A `fact` declaration introduces a named GDP predicate with zero or more typed parameters. Fact declarations are **phantom** — they have no runtime representation, only compile-time significance for the proof system.

**Single-parameter fact** (most common):
```tesl
fact IsPositive (n: Int)
fact IsTrimmed  (s: String)
```

**Multi-parameter facts** relate several values:
```tesl
fact InRange (lo: Int) (hi: Int) (n: Int)
fact Ordered (lo: Int) (hi: Int)
fact HasPrefix (prefix: String) (s: String)
```

Each parameter group may be written as a separate `(name: Type)` pair, or comma-separated inside a single group:
```tesl
fact InRange (lo: Int, hi: Int, n: Int)   # equivalent to three separate groups
```

The predicate name uses PascalCase by convention. Lowercase fact names are not enforced as errors but are unusual.

**Using a multi-param fact in a `check` function.** The return binding name identifies which parameter is the validated value; the other parameters are constraints from the calling context:

```tesl
fact InRange (lo: Int) (hi: Int) (n: Int)

check isInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"
```

**Consuming multi-param proofs.** A function that requires a multi-param proof must list all parameters in the `:::` annotation. The compiler tracks proof subjects across `let` bindings so that proof evidence flows correctly from check calls to proof-requiring functions:

```tesl
fn processInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> String = "ok"

fn validate(lo: Int, hi: Int, raw: Int) -> String =
  let validated = isInRange lo hi raw   # validated carries InRange lo hi raw
  processInRange lo hi validated        # proof passes: InRange lo hi raw matches InRange lo hi n
```

Passing `raw` (without the proof) directly to `processInRange` is a compile-time error.

### 11.5 Function-like declarations
**Accepted design, Implemented with some current syntax limits.**

```text
<function-decl> ::= <function-kind> [ <http-method> { <http-method> } ]
                    <identifier> "(" [ <binding> { "," <binding> } ] ")"
                    "->" <return-spec>
                    [ "requires" <capability-list> ]
                    "="
                    <body>

<function-kind> ::= "check" | "establish" | "fn" | "auth" | "handler"
<http-method>  ::= "get" | "post" | "put" | "delete" | "patch"
<capability-list> ::= "[" [ <capability> { "," <capability> } ] "]"
```

The `<http-method>` prefix applies to **`handler` only**, where it is required, and states the HTTP
method(s) that handler serves:

```tesl
handler get getTodo(requestUser: User ::: Authenticated requestUser, todoId: String ::: TodoId todoId)
  -> Todo ? FromDb (Id == todoId)
  requires [appDbRead] = …

handler get post search(q: String) -> List Result requires [appDbRead] = …   # one handler, two slots
```

It is load-bearing rather than documentation, for two reasons:

- **It is what SEC005 keys on.** A `get` handler may not reach `dbWrite`, `queueWrite`, `pubsub` or
  `emailCap` anywhere in its capability closure (a GET must be safe and idempotent, and it is the one
  method a `SameSite=Lax` session cookie is still sent on for a cross-site top-level navigation).
  Declaring the method on the handler means that rule reads the handler's own text, so it applies
  whether or not the handler is bound to a server, and cannot be switched off by a malformed server
  block.
- **It makes the server block's positional pairing verifiable** (§11.12), turning a misordered
  binding into a compile error.

For a handler serving several slots, the check is satisfied if the slot's method appears in the
declared set, and the *most restrictive* method governs — a `get post` handler is still held to the
GET no-mutation rule.

The verbs are **contextual keywords**, not reserved words: a handler may still be named `get` or
`post` (`handler get post(…)` declares method `get` on a handler named `post`). SSE endpoints take no
method — they are not paired with handlers.

The same five verbs, and only those five, are accepted here as on an endpoint (§11.11): `sse` is not a
handler method, and there is no `head`, `options`, `trace` or `connect`. Omitting the prefix on a
handler bound to a non-SSE endpoint is a `V001` error — *handler 'x' does not declare an HTTP method,
but serves endpoint 'GET /path'* — carrying the method the slot expects, so the fix is the hint. An
unbound handler with no prefix still compiles; it is the binding that makes the method verifiable.

Current lowering:

- `check` lowers to `define-checker`;
- `auth` lowers to `define-auther`;
- `fn` lowers to `define/pow`;
- `establish` lowers to `define-trusted`. It is the explicit fact-producing boundary for unconditional proofs. The body returns proof constructors directly (e.g. `IsPositive n`), not `ok` expressions. `ok` and `fail` are compile-time errors inside `establish`.
- `handler` lowers to `define-handler`.

The `establish`, `check`, and `auth` kinds establish **proof predicate ownership** for every predicate named in their return type. Each owned predicate is added to the module's local namespace and may be included in `exposing [...]` to make it importable by other modules:

```tesl
module Ports exposing [isValidPort, ValidPort]

check isValidPort(p: Int) -> p: Int ::: ValidPort p =
  if 1 <= p && p <= 65535 then
    ok p ::: ValidPort p
  else
    fail 400 "port out of range"
```

A consuming module names the predicate explicitly in its imports before using it in its own annotations:

```tesl
import Ports exposing [isValidPort, ValidPort]

fn connectTo(host: String, port: Int ::: ValidPort port) -> Int = ...
```

Predicates that are only used within their declaring module do not need to be exported.

**`fn` proof passthrough.** A `fn` may declare a proof-carrying return type (`name: T ::: P`) if and only if `name` also appears as a parameter with that proof annotation — the function is merely passing through a proof it received. A `fn` may not declare a proof-carrying return type for a binding that was not proof-annotated on input; that would fabricate a proof without going through a validation boundary.

```tesl
# VALID — proof passthrough: n carries IsPositive n on input
fn passthrough(n: Int ::: IsPositive n) -> n: Int ::: IsPositive n = n

# REJECTED — n has no proof on input; fn cannot mint IsPositive n
fn forgery(n: Int) -> n: Int ::: IsPositive n =
  let pf = proveAny n
  n ::: pf
```

For returning proof-carrying values where the proof was produced inside the function body, use `check`, `establish`, or `auth` — the three validated proof-introduction boundaries.

**Named-pack return (`?` operator).** When a function or handler returns a value with a GDP proof, the `?` return spec automatically assigns the value's GDP subject from the caller's `let` binder (see section 7.13). This is the idiomatic return form for SQL-layer functions and proof-annotated value returns:

```tesl
handler get getTodo(requestUser: User ::: Authenticated requestUser, todoId: String ::: TodoId todoId)
  -> Todo ? FromDb (Id == todoId)
  requires [dbRead Todo] =
  ...

# Compound entity proof: both Positive and Small get _entity appended
fn makeValue(n: Int ::: Positive n && Small n) -> Int ? Positive && Small =
  n

# Entity proof + independent proof
fn make(n: Int ::: Positive n, user: String ::: Admin user) -> Int ? Positive ::: Admin user =
  n ::: detachFact(user)
```

The elaborated Racket uses `(? Todo _entity ::: (FromDb (Id == todoId) _entity))`. Both a 1-argument `FromDb` fact (for backward compat) and a 2-argument fact (with the entity subject) are attached to the returned value by the SQL layer.

### 11.6 Type declarations
**Accepted design, Implemented.**

```text
<type-decl> ::= <type-alias-decl> | <adt-decl>

<type-alias-decl> ::= "type" <identifier> "=" <gdp-expr>

<adt-decl> ::= "type" <identifier>
               <adt-variant-line>+

<adt-variant-line> ::= ("=" | "|") <identifier> { <adt-field> }
<adt-field> ::= <binding>
              | <gdp-expr> [ ":::" <gdp-expr> ]
```

**Important**: The distinction between type alias and ADT is determined by whether the `=` appears on the same line as the type name or on the next line.

- **Type alias** (newtype): `=` on the same line — `type UserId = String`
- **ADT**: `=` on the next line with the first variant — `type Color` then `  = Red | Green | Blue`

Single-line `type Color = Red | Green | Blue` is parsed as a type alias where the type text is `Red | Green | Blue`, **not** an ADT. Always declare ADTs multi-line:

```tesl
# CORRECT — multi-line ADT
type Color
  = Red
  | Green
  | Blue

# WRONG — parsed as type alias "Color = Red | Green | Blue"
type Color = Red | Green | Blue
```

> **Design note — constructor names must differ from the type name.** A constructor cannot share its name with the type it belongs to. `type Status = Status | Other` is invalid: the constructor `Status` is ambiguous with the type `Status`. Use a distinct name — for example, `type Status = Active | Other`. This is an explicit design choice to prevent collisions between the type namespace and the value constructor namespace and to make it clearer for a human reader what is referenced.

**Parameterized ADTs.** An ADT may declare type parameters by listing lowercase identifiers between the type name and `=`. Parameters may then be used as field types in variants:

```text
<adt-decl> ::= "type" <identifier> { <type-param> }
               <adt-variant-line>+

<type-param> ::= lowercase-identifier
```

```tesl
# Either with two type parameters
type Either a b
  = Left  value:a
  | Right value:b

# A simple container with one parameter
type Box a
  = Box value:a

# Optional value (standard library pattern)
type Option a
  = Some value:a
  | None

# Tree structure
type Tree a
  = Leaf
  | Node left:(Tree a) value:a right:(Tree a)
```

Type parameters are resolved structurally at compile time using Hindley-Milner inference. No explicit type arguments are required at call sites — the compiler infers them from usage:

```tesl
fn wrapInt(n: Int) -> Box Int =
  Box(n)

fn unwrap(b: Box Int) -> Int =
  case b of
    Box value -> value

fn mapEither(e: Either Int String, f: Int -> Int) -> Either Int String =
  case e of
    Left  value -> Left(f(value))
    Right value -> Right(value)
```

The standard library uses `Either`, `Maybe`, and `Result` as parameterized ADTs. User code may define its own parameterized ADTs with any number of parameters.

Type aliases are **nominal newtypes**, not transparent aliases. `type UserId = String` creates a distinct runtime type. A value of type `String` cannot be passed where `UserId` is expected; the two types are incompatible even though both wrap `String`.

**Database auto-mapping**: newtypes that wrap a built-in DB type inherit that base type's column mapping automatically, so no `@db` annotation is needed. For example, `type UserId = String` maps to `TEXT`, and a newtype over `Int` maps to `NUMERIC` (the same as a bare `Int` — a plain integer column is one consistent type; see §11.8). The one built-in exception is `PosixMillis` (`type PosixMillis = Int`), which is a distinct 64-bit millis-timestamp type and maps to compact `BIGINT` rather than `NUMERIC`, so `createdAt: PosixMillis` gets a `BIGINT` column with no annotation.

To construct a newtype value, call the type name as a constructor:
```tesl
let id = UserId("user_abc")      # constructs a UserId
```

To access the wrapped value, use the `.value` field accessor:
```tesl
fn formatId(id: UserId) -> String =
  String.length(id.value)        # extracts the inner String
```
The structural checker treats `.value` as the explicit unwrap for nominal newtypes. Other dotted field access is checked against declared record, entity, or ADT-variant fields; an unknown field or a field access on a non-record/non-entity/non-variant value is a compile-time error.

At JSON/HTTP boundaries, newtypes are decoded and encoded transparently: the JSON representation is the same as the base type. Decoding an incoming request constructs the newtype from its primitive representation, and reading a row from the database lifts the stored primitive back into the newtype.

At SQL boundaries, by contrast, newtypes are **not** coerced. An entity column declared as a newtype requires a value of that exact newtype at *every* SQL site — `insert`, `update … set`, and `where` — so supplying the bare underlying primitive is a compile-time error. Construct the newtype explicitly (e.g. `where owner == UserId(raw)`, `insert Row { owner: UserId(raw) }`). This keeps writes and queries honest: the column's declared type is enforced rather than silently accepting the wrong-typed value.

For ADT fields, explicit labels are allowed via ordinary binding syntax. If a field is written only as a type expression, the current implementation generates labels such as `value`, `value2`, and so on.

### 11.7 Records
**Accepted design, Implemented.**

```text
<record-decl> ::= "record" <identifier> "{" { <record-field> } "}"
                   [ ":::" <gdp-expr> [ "via" <dotted-identifier> ] ]
<record-field> ::= <identifier> ":" <gdp-expr>
                   [ ":::" <gdp-expr> ]
```

Record fields may carry proof annotations documenting what proof a field value must carry. `via checker` on individual record fields is **not** supported — field validation at HTTP boundaries is handled by codec blocks (see §11.12).

**Field proof propagation on read.** When a record field carries a proof annotation (e.g. `title: String ::: TitleSafe title`), the compiler enforces two guarantees:

1. **Construction** — building the record requires the field value to carry the declared proof. A `SafeItem { title: s }` is rejected unless `s` carries `TitleSafe`.
2. **Consumption** — reading the field back (e.g. `item.title`) automatically propagates the declared proof. A function requiring `String ::: TitleSafe t` accepts `item.title` directly, without re-checking:

```tesl
record SafeItem { title: String ::: TitleSafe title }
fn requiresSafe(t: String ::: TitleSafe t) -> String = t
fn readField(item: SafeItem) -> String = requiresSafe item.title  # proof flows through
```

This implements the "validate once, trust everywhere" thesis for record-heavy code: once a value is stored in a proof-annotated field, the proof is permanently associated with the field and available to all consumers.

Records may also carry a **record-level proof** — a compile-time annotation of a cross-field invariant:

```tesl
record OrderLine {
  price:    Int ::: IsPositive price
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQuantity price quantity
```

Without a `via` clause, the `:::` after the closing `}` is a **zero-cost, compile-time-only annotation**. No runtime check is inserted. Instead, the compiler enforces the **ghost witness pattern**: any site that constructs the record must supply a proof variable as an explicit ghost witness:

```tesl
fn makeOrderLine(price: Int ::: IsPositive price,
                 quantity: Int ::: IsPositive quantity,
                 recordProof: Fact (PriceExceedsQuantity price quantity)) -> OrderLine =
  { price: price, quantity: quantity } ::: recordProof
```

The `{ ... } ::: witnessVar` syntax on a record literal is the ghost witness. It compiles to the plain record constructor — no `attach-proof` call, no allocation. Without it, the compiler rejects the construction with:

```
constructing `OrderLine` requires a ghost witness for its cross-field invariant
`PriceExceedsQuantity price quantity`; use `{ ... } ::: proofVar`
```

**Compile-time validation of the ghost witness.** The compiler does not merely require that *some* proof is supplied — it validates that the witness carries the *correct* proof for the *exact* values in the record literal:

1. **Predicate check** — the witness proof must carry the same predicate declared on the record. Passing `(detachFact p)` (which carries `IsPositive p`) where `PriceExceedsQuantity price quantity` is required is a compile error:

   ```
   ghost witness for `OrderLine` carries the wrong proof predicate
     expected a proof of `PriceExceedsQuantity`
     got: `(IsPositive n)`
   ```

2. **Subject check** — the proof subjects in the witness must be the same identity as the values used in the record literal. A proof obtained for `(p_intruder, q)` cannot be used for `{ price: p, quantity: q }` even though both use the `PriceExceedsQuantity` predicate:

   ```
   ghost witness for `OrderLine` carries the wrong proof
     required: `(PriceExceedsQuantity p q)`
     got:      `(PriceExceedsQuantity p_intruder q)`
     the ghost witness must be the cross-field proof obtained for the EXACT
     values that appear in the record literal
   ```

This ensures that the GDP guarantee holds end-to-end: a proof `PriceExceedsQuantity p q` is valid only for the specific binding of `p` and `q` that produced it, and cannot be reused for any other pair of values — even values that happen to satisfy the same predicate independently.

The optional `via checker` suffix on a record declaration (not a field) registers a **runtime invariant** checked at construction time. This is useful for property-based test generators, which call the checker to fabricate valid records. For application code construction, the ghost witness pattern is still required regardless of whether `via` is present.

For HTTP input, the cross-field check belongs in the codec block:

```tesl
codec OrderLine {
  toJson_forbidden
  fromJson [
    {
      price    <- "price"    with_codec intCodec via checkPositiveInt
      quantity <- "quantity" with_codec intCodec via checkPositiveInt
    } via checkPriceExceedsQuantity
  ]
}
```

The `} via checker` suffix on a codec block runs the cross-field checker after all individual fields pass, using the decoded raw values in field declaration order. This is the **only** place where untrusted external input crosses the validation boundary.

For a single field that must satisfy multiple proofs, use the parenthesized `&&` form:

```tesl
fromJson [
  {
    title <- "title" with_codec stringCodec via (isSafeTitle && isShort && containsA)
  }
]
```

The `&&` expression applies checkers sequentially — the second runs only if the first succeeds, and so on. Chaining with multiple separate `via` keywords (e.g., `via isSafeTitle via isShort`) is not supported; use the parenthesized form instead.

This design is theoretically sound because:
- Field-level proofs are about individual field subjects (single-field GDP evidence).
- Record-level proofs are about the *relationship* between field subjects (cross-field GDP evidence).
- The ghost witness pattern (GDP) shifts all fallibility to proof *acquisition* — the construction function itself is total.
- HTTP boundaries are validated by the codec; application-internal construction is validated by requiring a pre-acquired proof as a ghost witness.

**Explicit HTTP wire adapters.** An endpoint may name a different wire type with `body req: Domain from Wire via decodeWire` and `response Wire via encodeWire`. These adapters are part of the static boundary contract, not an escape hatch. The compiler requires:
- `decodeWire` to be a declared Tesl function with exactly one raw `Wire` argument and a `Domain` return; if the endpoint body declares a proof, `decodeWire` must establish that proof itself unless the endpoint uses `body ... via (...)` to establish it at the boundary.
- `encodeWire` to be a declared Tesl function with exactly one raw handler-result argument and a `Wire` return.
- `Wire` to have the appropriate visible codec (`fromJson` for request bodies, `toJson` for responses), because `Wire` is still the type that crosses the HTTP boundary.

**`adtJson` shorthand for ADT types.** When a codec is needed solely to declare the standard `{"tag": "ConstructorName"}` JSON encoding for an ADT, use the `adtJson` shorthand:

```tesl
type OrgRole = RoleAdmin | RoleMember | RoleViewer

codec OrgRole {
  adtJson     # expands to: toJson {"tag": constructorName}
              #              fromJson {"tag": constructorName}
}
```

`adtJson` is equivalent to declaring both `toJson` and `fromJson` blocks that encode/decode the ADT using the standard runtime format. It cannot be combined with separate `toJson` or `fromJson` blocks in the same codec declaration.

Once `codec OrgRole { adtJson }` is declared, other codecs can reference it with `with_codec OrgRole`. The same `with_codec TypeName` form also works for non-ADT types when a visible `codec TypeName { ... }` exists:

```tesl
codec InviteMemberRequest {
  toJson_forbidden
  fromJson [
    {
      email <- "email" with_codec stringCodec
      role  <- "role"  with_codec OrgRole    # valid because OrgRole has a visible codec
    }
  ]
}
```

The compiler enforces that:
1. `with_codec OrgRole` is only used on fields declared as type `OrgRole` (type mismatch is a compile error).
2. `OrgRole` has a visible codec in the current module/import closure (for `fromJson`, the referenced codec must provide a decoder).
3. Builtin codecs (`stringCodec`, `intCodec`, etc.) must match the field's declared type (e.g., `with_codec stringCodec` on an `OrgRole` field is a compile error).

### 11.8 Entities
**Accepted design, Implemented but still evolving.**

Table names must be nonempty, contain no NUL, and fit PostgreSQL's 63-byte
identifier limit. Field names map to snake-case column names, preserving acronym
groups (`userID` becomes `user_id`). The compiler rejects two fields that map to
one column, or a mapped column name longer than 63 bytes. PostgreSQL's silent
identifier truncation must never merge distinct declared storage identities.

```text
<entity-decl> ::= "entity" <identifier>
                  "table" <string>
                  "primaryKey" <identifier>
                  "{" { <entity-body-entry> } "}"

<entity-body-entry> ::= <entity-field>
                      | <entity-index>

<entity-field> ::= <identifier> ":" <gdp-expr>
                   [ ":::" <simple-field-fact> ]
                   [ "@db(" <identifier> ")" ]

<entity-index> ::= [ "unique" ] "index"
                   "[" <identifier> { "," <identifier> } "]"
                   [ "as" <string> ]
```

Entity field proof annotations are intentionally restricted. They must be simple single-field facts of the form `ProofName field`. Entity fields do not currently support `via` checkers.

**Indexes.** An `index` entry declares a secondary index over one or more fields, in the order written; `unique index` additionally declares that the combination is unique. `index` and `unique` are **not** keywords — like every other SQL clause word in Tesl (`where`, `order`, `onConflict`, …) they are ordinary identifiers recognised by position, so a field or variable named `index` keeps working.

```tesl
entity Issue table "kanel_issues" primaryKey id {
  id:        String
  orgId:     String
  slug:      String
  createdAt: PosixMillis

  index [orgId, createdAt]
  unique index [orgId, slug]
  index [createdAt] as "kanel_issues_recent"
}
```

The index name defaults to `<table>_<column>…_idx` over the real column names, truncated to PostgreSQL's 63-byte identifier limit with a deterministic suffix when necessary. The optional `as "..."` override exists mainly to adopt an index a database already has, so `create index if not exists` matches the existing object; explicit names must be plain SQL identifiers of at most 63 bytes and must be unique across **every** entity in the program, because a PostgreSQL index name lives in the schema namespace rather than the table's.

Rejected at compile time: a field the entity does not declare, the same field twice in one index, two identical index declarations, an index over a `Money`/`MoneyRate` field (those store into several derived columns, so a single index over "the field" is not a meaningful object — the same reason they cannot be primary keys), and an index that merely repeats the single-column primary key, which PostgreSQL already indexes.

**How indexes are created.** Declared indexes are created by the ordinary startup migration (§11.9 `auto-migrate?`), with one distinction that matters in production. On a new or empty table every declared index is built inline — instant and lock-free. On a table that already has rows, nothing is built, because a plain `CREATE INDEX` holds a lock that blocks writes for the whole build, and the safe `CONCURRENTLY` form cannot run inside the transaction the migration uses. Instead:

- a missing **plain** index prints a warning containing the exact `CREATE INDEX CONCURRENTLY` statement and the program starts normally — a missing perf index is not a reason for a deploy to take the service down;
- a missing **unique** index is a startup **error** with the same statement — the program declares an invariant the database is not enforcing, and `upsert … onConflict` (§13) depends on the index existing.

An index already present in the database satisfies the declaration when its **column list and uniqueness** match, regardless of the name it was created under. A unique index satisfies a plain declaration; a plain index does not satisfy a unique one.

On the **Memory** backend a plain index is a no-op (every query is a scan), but a **unique** index is enforced on insert, update and upsert, with PostgreSQL's NULL semantics: a row with a `Nothing` in any indexed column is unconstrained, because two NULLs are not equal. Without that, a program could pass `tesl test` on data PostgreSQL rejects.

**`Maybe T` fields.** An entity field declared as `Maybe T` maps to a **nullable** SQL column whose type is the same column type `T` maps to on its own (so `Maybe <ADT>` is a nullable `JSONB`, exactly like a bare `<ADT>` is a `NOT NULL` `JSONB` — the two differ only in nullability, never in column type). At runtime `Nothing` ↔ SQL `NULL` and `Something v` ↔ the column value. The `@db(...)` annotation applies to the inner type `T` as usual.

```tesl
entity Issue table "kanel_issues" primaryKey id {
  id:         String
  assigneeId: Maybe String   # nullable TEXT — NULL means unassigned
  dueAt:      Maybe PosixMillis  # nullable BIGINT
}
```

In queries, `Maybe` fields require a `case` expression or the `isAssignedTo` / helper-function pattern; they cannot be compared directly with `==` to a non-Maybe value.

**Column type mapping summary:**

| Tesl field type | SQL column type | Nullable? |
|---|---|---|
| `String` | `TEXT` | NOT NULL |
| `Int` | `NUMERIC` | NOT NULL |
| `Int32` | `INTEGER` (int4) | NOT NULL |
| `Bool` | `BOOLEAN` | NOT NULL |
| `Float` / `Real` | `DOUBLE PRECISION` | NOT NULL |
| `Bytes` | `BYTEA` | NOT NULL |
| `PosixMillis` | `BIGINT` | NOT NULL |
| newtype over `Int` (e.g. `newtype Counter = Int`) | `NUMERIC` (same as bare `Int`) | NOT NULL |
| newtype over another built-in (e.g. `newtype UserId = String`) | column type of the base | NOT NULL |
| Any ADT | `JSONB` | NOT NULL |
| Record with an explicit bidirectional codec | `JSONB` | NOT NULL |
| `Maybe T` | column type of `T` (e.g. `Maybe Int` → `NUMERIC`, `Maybe <ADT>` → `JSONB`) | NULL |

**Record JSONB columns.** A stored record requires an explicit codec with both
`toJson` and `fromJson`, including when an explicit `@db(jsonb)` annotation is
present. Its encoder determines stored keys and its checked decoder runs ordered
alternatives and proof checks on every read. Records nested inside ADT columns
use the same record codec. Codec resolution follows the record's declaring module,
including private and transitively imported field types; an unrelated same-named
record cannot supply its codec. SQL `NULL` in a `Maybe Record` column is `Nothing`;
JSON `null` reaches the decoder and is rejected for a record. No read rewrites the
stored JSON. Migration history, coordinated rewrites and evidence-backed removal
of old decoders remain under development.

> **Maybe columns compare as values (2026-09-02).** `p.field == x` and `p.field != x` on a `Maybe` column are emitted as `IS NOT DISTINCT FROM` / `IS DISTINCT FROM`, so `Nothing == Nothing` is true and `Nothing == Something v` is false on PostgreSQL exactly as on the Memory store. A query's row binder may not shadow a name already in scope (a parameter, a local or a function); the compiler refuses it, because the two backends would otherwise read the two names differently. Two module names that fold to one Go package name (`FooBar`, `Foobar`, `Foo_bar`) are refused for the same reason: one module's code would silently replace the other's.
>
> **Memory store limits.** `transaction { }` on the Memory store rolls back by restoring touched tables to their state before the block. Outside table readers and writers wait until commit or rollback, while the transaction reads its own writes, so uncommitted and partially rolled-back rows are not observable from another request. Memory transactions are process-wide serialized rather than PostgreSQL's concurrent MVCC transactions. Also, `selectOne` without `order` returns the first row in insertion order on Memory and in heap order on PostgreSQL. The Memory store is a development and test store; a served program with concurrent access should be Postgres-backed.

`Int` maps to `NUMERIC`, **not** `BIGINT`: `Int` is arbitrary-precision (unbounded), and `NUMERIC` stores any magnitude losslessly, so an `Int` of any size round-trips through the database with no truncation (NT-07). A newtype *over* `Int` maps to the same `NUMERIC` — a plain integer column is one consistent type regardless of whether it is a bare `Int` or a nominal newtype. `PosixMillis` is the one deliberate exception: it is a distinct 64-bit millis-timestamp type and maps to compact `BIGINT`. For a bounded integer column that must fit a JavaScript number (< 2^53) or a compact `int4`, use `Int32` (`INTEGER`); a linter warning steers wire/storage `Int` fields toward `Int32`. To store any of these under a different SQL type, use an explicit `@db(...)` annotation.

**NULL comparison semantics.** Comparisons follow PostgreSQL three-valued logic on both the Postgres backend and the in-memory (test) backend, so tests are faithful to production. A comparison involving `NULL` (a `Nothing` / absent `Maybe` value) is `UNKNOWN`, and a `where` row is kept only when its predicate is `TRUE` — an `UNKNOWN` result excludes the row. In particular `field == x`, `field != x`, ordered comparisons (`<`, `<=`, `>`, `>=`), `in`, `not in`, and `like`/`ilike` all **exclude** a row whose `field` is `NULL` (even `NULL == NULL` is not a match). Use the explicit null tests to inspect `NULL`-ness: only `field` being null (`IS NULL`) / not-null (`IS NOT NULL`) yield `TRUE`/`FALSE` on a `NULL` value.

### 11.9 Databases
**Accepted design, Implemented.**

A `database` declaration is a folded record assigned with `=`:

```text
<database-decl> ::= "database" <identifier> "=" "Database" "{"
                      [ "schema" ":" <string> ]
                      "entities" ":" "[" [ <identifier> { "," <identifier> } ] "]"
                      "backend" ":" <database-backend>
                    "}"

<database-backend> ::= "Postgres" "(" "PostgresConfig" "{"
                         "dbName"     ":" <expr>
                         "user"       ":" <expr>
                         "password"   ":" <expr>
                         [ "poolSize"  ":" <expr> ]
                         "connection" ":" <connection>
                       "}" ")"
                     | "Memory"

<connection> ::= "TcpConnection" "{" "host" ":" <expr> "port" ":" <expr> "}"
               | "SocketConnection" "{" ... "}"
```

```tesl
database MyDatabase = Database {
  schema: "my_app"
  entities: [User]
  backend: Postgres (PostgresConfig {
    dbName: env "POSTGRES_DB"
    user: env "POSTGRES_USER"
    password: env "POSTGRES_PASSWORD"
    connection: TcpConnection {
      host: env "POSTGRES_HOST"
      port: envInt "POSTGRES_PORT" 5432
    }
  })
}
```

The `backend` is either `Postgres (PostgresConfig { ... })` or `Memory`. The `port` in a `TcpConnection` carries a port-validity obligation: a literal must be in `1..65535` (or use `envInt "VAR" default`), otherwise it is a compile-time error.

The optional `poolSize` is the connection-pool size: the maximum number of simultaneously open PostgreSQL connections (default 10). It is an `Int` field, so a literal or `envInt "VAR" default` both work — e.g. `poolSize: envInt "PG_POOL_SIZE" 20`. When every pooled connection is busy, a request waits (bounded, 10s by default, `TESL_PG_POOL_LEASE_TIMEOUT_MS` overrides) for a freed connection instead of failing immediately; if the wait times out the HTTP layer answers `503 Service Unavailable`.

#### Schema module references
**Ownership elaboration implemented; migration lifecycle in progress.**

The versioned form selects ownership through a schema module:

```tesl
import NotesSchema.VCurrent exposing [Note]

database NoteDatabase = Database {
  schema: NotesSchema.VCurrent
  migrations: NotesSchema.Migrate
  backend: Postgres (PostgresConfig {
    namespace: "notes_app"
    dbName: env "POSTGRES_DB"
    user: env "POSTGRES_USER"
    password: env "POSTGRES_PASSWORD"
    connection: TcpConnection { host: "localhost", port: 5432 }
  })
}
```

`ModuleRef` is a contextual elaboration category, not a value type or constructor.
In `Database.schema`, a nullary qualified name is a module reference exactly when
it names a directly imported `FamilySchema.VCurrent` root. The import may expose
no declarations. A frozen `V<n>`, child module, string, function result, local
constructor or local variable cannot stand in for that root in the versioned form.
In `Database.migrations`, the name must be that same family's `FamilySchema.Migrate`
prefix. It denotes the conventional migration directory, not an ordinary module
import; an empty history need not already have a directory. Neither reference
introduces a runtime expression or makes a private declaration visible to application
code. Ordinary expression and type positions retain their existing name-resolution
rules and cannot use a module as a value.

Let `closure(S)` be the finite local import graph reachable from schema root `S`,
including `S`. Its non-stdlib members must belong to `S` or its children and satisfy
the schema-content boundary. Then `members(S)` is every entity declared in that
closure, keyed by its declaring module and entity name, independently of exports.
Cycles and repeated imports contribute an entity once. Two distinct members cannot
name the same physical table. `Database { schema: S, migrations: M, backend: B }`
owns exactly `members(S)`; supplying `entities:` as well is an error. A module root
with no entities is valid. Ownership is checked over the whole application graph,
so another database cannot own any part of the same family.

Connection configuration remains in the application. `PostgresConfig.namespace`
is the physical PostgreSQL schema name, required as a nonempty static string for
the module-reference form. It is independent of the Tesl module and database
declaration names; the compiler does not guess a physical namespace from either.
Memory has no physical namespace. During source transition the existing string
`Database.schema` plus explicit `entities:` form retains its meaning and cannot
also specify `migrations:` or `PostgresConfig.namespace`.

Elaboration produces an ownership binding and connection description separately
from ordinary source visibility. Generated table metadata may name private schema
entities, but that does not import their constructors or helpers into application
scope. Version history, migration execution and readiness are additional phase-1
checks; accepting an ownership binding alone does not establish them.

### 11.10 Capture declarations
**Accepted design, Implemented.**

```text
<capture-decl> ::= "capture" <identifier> ":" <binding>
                   "using" <codec-name>
                   [ "via" <checker-expr> ]

<codec-name>   ::= <identifier>

<checker-expr> ::= <identifier>
                 | "(" <identifier> { "&&" <identifier> } ")"
```

The `using` clause names the JSON codec used to parse the URL segment — e.g., `stringCodec` for
string segments, `intCodec` for integer segments. The optional `via` clause applies a `check`
function (or a parenthesized `&&`-list of one check function) to validate and attach a proof to
the captured value.

Only one checker is supported per capture. For complex validation, compose checks into a single
`check` function.

This creates a reusable capture kind that can later be referenced from API declarations.

### 11.11 API declarations
**Accepted design, Implemented**

```text
<api-decl> ::= "api" <identifier> "{" { <api-endpoint> } "}"

<api-endpoint> ::= <http-method> <string>
                   { <api-endpoint-line> }

<http-method> ::= "get" | "post" | "put" | "delete" | "patch"

<api-endpoint-line> ::= <auth-line>
                      | <body-line>
                      | <response-line>
                      | <capture-line>
                      | <return-line>

<auth-line> ::= "auth" <binding> "via" <identifier>
<capture-line> ::= "capture" <binding> "via" <identifier>
<body-line> ::= "body" <binding> [ "from" <gdp-expr> "via" <identifier> ]
<response-line> ::= "response" <gdp-expr> [ "via" <identifier> ]
<return-line> ::= "->" <return-spec>
```

Endpoint headers use path strings. Capture segments are written in the path with a leading `:` and then described by `capture ... via ...` lines in declaration order.

**The verb set is closed.** `get`, `post`, `put`, `delete` and `patch` are the only HTTP methods an endpoint may declare, plus `sse` for a stream (below); all are lowercase. There is no `head`, `options`, `trace` or `connect`, and the uppercase spellings are not accepted either. Anything else at the start of an endpoint is an `E000` parse error naming the supported set — it is never skipped, because a silently dropped endpoint is a route that does not exist and whose only symptom is an unrelated "server is missing N binding(s)". The handler bound to the endpoint must declare the same verb (§11.5); the `server` block pairs the two by position (§11.12).

SSE (Server-Sent Events) endpoints are declared with `sse` instead of an HTTP method:
**Accepted design, Implemented.**

```text
<api-endpoint> ::= ...existing...
                 | "sse" <string>
                     { <api-endpoint-line> }
                     { <subscribe-line> }

<subscribe-line> ::= "subscribe" <identifier> "(" [ <expr> { "," <expr> } ] ")"
```

An SSE endpoint authenticates the client, captures URL parameters, then subscribes the long-lived HTTP connection to one or more typed channels. Subscriptions are declarative — no handler function is needed in the `server` declaration; routing is automatic.

```tesl
sse "/events/user/:userId"
  auth    session: Session ::: Authenticated session && ChannelOwner session userId
          via sessionOwnerAuth
  capture userId: String ::: UserId userId via userIdCapture
  subscribe UserEvents(userId)
```

Multiple `subscribe` lines subscribe the connection to multiple channels simultaneously. The client receives a discriminated JSON SSE `data:` line: `data: {"channel":"ChannelName","payload":{"tag":"VariantName",...}}`.

SSE runs on the **same TCP port** as the HTTP API server. No separate server or reverse proxy configuration is needed. The browser uses the native `EventSource` API, which auto-reconnects on disconnection.

**Client-side usage:**

```javascript
const evts = new EventSource('/events/user/usr_123');
evts.onmessage = (e) => {
  const { channel, payload } = JSON.parse(e.data);
  // dispatch on channel and payload.tag
};
// Reconnects automatically — no manual reconnect code needed
```

### 11.12 Servers
**Accepted design, Implemented.**

```text
<server-decl> ::= "server" <identifier> "for" <identifier> "{" { <identifier> } "}"
```

Handlers are listed **by position**, not by name: handler *i* implements the `api`'s *i*-th non-SSE
endpoint (declaration order), matching how routes are declared in the `api` block. There is no
`<endpointName> = <handlerFn>` binding syntax — an earlier version of the grammar had one, but it
was always matched by position underneath, so the `=` only looked name-keyed while silently ignoring
whatever name you gave it. Listing bare handlers removes that gap: what you write is what runs.

**Positional binding is verified, not trusted.** Because the pairing is positional, a `handler`
declares the HTTP method(s) it serves (§11.16) and the compiler checks that declaration against the
slot the handler actually landed in. Together with the parameter, proof and return-type checks that
already ran, a misordered server block is a compile error rather than a silent misroute:

```text
error[V001]: handler 'hb' declares `post` but is bound to endpoint 'GET /a'
Hint: either change the handler to `handler get hb(…)`, or move it to the slot matching
      the endpoint it should serve — handlers are paired to endpoints by POSITION in the
      server block, in api declaration order
```

Four properties of a slot are cross-checked: the **method**, the positional **parameter types**
(auth value, then captures, then body), each parameter's **proof obligation**, and the response's
**type and proof**. Two endpoints identical in all four are genuinely indistinguishable — reordering
their handlers cannot be detected — and that residue is reported as `W095` (`tesl explain W095`), whose fix
is to give a parameter its own type so the pairing becomes checkable.

### 11.13 Main / the `App` entry point
**Accepted design, Implemented.**

`main` is an **ordinary function** that returns an `App` description. There is no `main { ... }` block, no `with capabilities [...]` block, and no `serve`/`startWorkers`/`startDeadWorkers`/`startEmailWorker` statements — those constructs have been removed from the language. The runtime starts everything (HTTP server, queue workers, SSE LISTEN, email delivery) from the returned `App`.

```text
<main-decl> ::= "main" "(" ")" "->" "App" "requires" "[" <capability-list> "]" "=" <body>
```

The body is an ordinary function body that may run startup `let` bindings (port resolution and seeding)
and must end by returning an `App { ... }` record. Telemetry normally belongs in the optional
`telemetry` field; `initTelemetry` remains a checked compatibility form for older programs. The `let`
bindings are fully type-checked like any function body (unknown names and wrong-typed calls are compile
errors); only the final `App { ... }` record is validated structurally, because its
`database`/`api`/`queues`/`email`/`sseChannels` fields reference declarations by name rather than as values:

```text
<app-record> ::= "App" "{"
                   "database"    ":" <identifier>
                   "api"         ":" <identifier>
                   "port"        ":" <expr>
                   [ "queues"      ":" "[" [ <identifier> { "," <identifier> } ] "]" ]
                   [ "email"       ":" "[" [ <identifier> { "," <identifier> } ] "]" ]
                   [ "sseChannels" ":" "[" [ <identifier> { "," <identifier> } ] "]" ]
                   [ "static"      ":" <string> ]
                   [ "mountPath"   ":" <string> ]
                   [ "telemetry"   ":" <telemetry-config> ]
                 "}"
```

```text
<telemetry-config> ::= "TelemetryConfig" "{"
                       "service"  ":" <string>
                       "endpoint" ":" <string>
                       "console"  ":" <bool>
                       [ "metrics" ":" <bool> ]
                       [ "metricsInterval" ":" <int> ]
                     "}"
```

```tesl
main() -> App requires [appService, smtpSend] =
  let port = envInt "PORT" 8080
  App {
    database: MainDatabase
    api: MyServer
    port: port
    queues: [EmailQueue]          # activates each queue's workers (normal + dead-letter)
    email: [AppEmail]             # activates each email block's delivery worker
    sseChannels: [UserEvents]     # activates each SSE channel's outbox delivery
    telemetry: TelemetryConfig {
      service: "orders"
      endpoint: "in-memory"
      console: True
    }
    mountPath: "/api"             # every route answers under this prefix — see below
  }
```

**Capabilities are granted at the App root**, derived from `main`'s `requires` list. There is no runtime cap-granting block; every capability referenced anywhere in the activated declarations flows from each declaration's own `requires`, and `main.requires` must cover them. A missing capability is a compile error.

Every `dbRead Entity` or `dbWrite Entity` in `main`'s expanded grant must name an entity listed by
the database selected in `App.database`. Otherwise compilation fails: the entity would not be
connected to that App database. This check also applies to entity-scoped DB capabilities reached
through `capability ... implies ...`.

#### OpenAPI export

The checked API surface can be exported for documentation and security tooling without changing
the runtime surface:

```text
tesl generate-openapi <file> <Server> [--output <file>]
```

The command selects the API named by `<Server>` and emits an OpenAPI 3.1 JSON document. It includes
typed captures, request and response schemas, session-cookie security, 401/404 responses, and proof
annotations as both descriptions and `x-tesl-proof`. Proof annotations in OpenAPI are informational;
Tesl's compiler and server remain authoritative. Generation is opt-in and file-based, so production
servers do not gain a documentation route by default. See `manual/openapi-dast.md` for DAST usage.

#### `mountPath` — serving the API under a path prefix

`mountPath` serves every route the `api` block declares under a shared prefix, so a backend can share one origin with a single-page app (or another API surface) and be told apart by path alone. The prefix is a **deployment** concern, so it is declared once at the App root and never written into a route:

```tesl
api MyApi {
  get "/widgets" -> List Widget          # note: NOT "/api/widgets"
}

main() -> App requires [appService] =
  App {
    database: MainDatabase
    api: MyServer
    port: 8080
    mountPath: "/api"                    # GET /api/widgets reaches the route
  }
```

Two properties this buys, both of which the manual alternative (writing `/api/…` into every route string) fails to give you:

- **A new route cannot forget the prefix**, because the prefix appears nowhere in any route string.
- **Generated client names stay clean.** The Elm/TS generators derive function and type names from the route's own path, and inject the prefix only when building the request URL — so `get "/widgets"` still emits `getWidgets`, and that function calls `/api/widgets`.

**What is mounted, and what is not.** This distinction matters when configuring a proxy or a load balancer, so it is worth stating exactly:

| Surface | Mounted? | Why |
| --- | --- | --- |
| `api` block routes | **yes** | this is the surface `mountPath` names |
| SSE routes (`sse "/…"`) | **yes** | declared in the `api` block like any other route |
| static files + the SPA fallback (`static:`) | no | the SPA is the *other* thing sharing this origin that the prefix exists to separate the API from; mounting it would make `mountPath` and `static` mutually exclusive |
| SSO endpoints (`/auth/<seg>/login`, `/auth/<seg>/callback`) | no | keeps the IdP-registered `redirect_uri` (`publicOrigin ++ "/auth/<seg>/callback"`) decoupled from a deployment knob — otherwise changing `mountPath` would silently invalidate your OAuth client registration and break login in production. `publicOrigin` cannot carry a path, so a prefixed callback is not expressible anyway |

So a reverse proxy fronting a mounted app must forward **`/auth/*` as well as the mount prefix**, and if the app serves its own SPA via `static:`, `/` too.

**`healthProbePath` is api-relative.** It names one of the `api` block's own routes, so it moves under the mount with everything else: `mountPath: "/api"` plus `healthProbePath "/healthz"` means the probe lives at `/api/healthz` — point liveness/readiness checks there. Its Host-validation exemption (load balancers probe host-blind) continues to apply, while ordinary routes still refuse a mismatched `Host` with 421.

**A route only answers under the mount.** With `mountPath: "/api"`, `GET /api/widgets` dispatches and `GET /widgets` does not — a route answering at both paths would defeat the point of declaring a mount. A request outside the mount is simply "not an API call": it falls through to static files and the SPA fallback, and 404s only if those miss too.

`tesl run` goes through the same dispatch code as a production deploy, so local and deployed routing agree. `api-test` and `load-test` blocks address the route table directly and therefore use **unprefixed** paths — they exercise routes, not the mount.

**Validation.** Must be a string literal starting with `/` and not ending with `/` (the bare root `"/"` is accepted and is a no-op). `tesl check` rejects any other shape with the corrected string in the message, so there is never a question of which end the slash belongs on. Writing the prefix into a route string *as well* is reported as `W096` (`tesl explain W096`) — that combination serves the route at `/api/api/widgets`.

**Activation by listing, not by start calls.** Listing a queue in `App.queues` activates its `numberOfWorkers` normal workers plus, if any job has a dead slot, the single dead-letter worker. Listing an email block in `App.email` activates its delivery worker. Listing an SSE channel in `App.sseChannels` activates its outbox delivery. The SSE pub/sub LISTEN connection starts automatically when SSE endpoints are present — there is no `startWebSocket` call.

Worker concurrency is configured on the queue itself via `numberOfWorkers: N` (see §11.15), not at the App root:
- I/O-bound jobs (HTTP calls, external APIs): N = 4–8
- CPU-bound jobs: N ≈ number of CPU cores
- Conservative default: 2–4; increase based on queue depth monitoring

Dead-letter workers are always single-threaded — there is no concurrency knob for them. Dead-letter handlers compensate for failures and should run serially to avoid duplicate compensating actions.

Activating a queue launches N+2 threads per queue with PostgreSQL, where N is the queue's `numberOfWorkers` (N+1 with the in-memory fallback):

- **Fallback Poller** — wakes every 5 s to ensure no job is ever stranded indefinitely.
- **LISTEN Connection** *(PostgreSQL only)* — holds a dedicated connection with `LISTEN tesl_queue_<name>`. Wakes immediately when any process enqueues a job and its transaction commits. Reconnects automatically on failure.
- **SKIP LOCKED Worker** — waits on a semaphore (posted by the LISTEN thread or the poller), drains burst signals, then issues `FOR UPDATE SKIP LOCKED` until the queue is empty.

`enqueue!` also issues `SELECT pg_notify(...)` inside the enclosing transaction so the NOTIFY fires exactly on commit — workers in other processes receive the same sub-millisecond wakeup. The runtime starts worker threads before the HTTP server, so ordering is handled automatically by the App root.

The runtime automatically starts (with PostgreSQL) a pub/sub LISTEN thread when SSE endpoints are registered:

- Holds a dedicated connection with `LISTEN tesl_pubsub`. When a NOTIFY arrives carrying an outbox row ID, the thread fetches the row, fans the event to in-memory SSE listeners, and delivers it.
- A fallback poller sweeps `tesl_pubsub_outbox` every 5 s for rows that survived a dropped NOTIFY.
- An initial sweep on startup delivers events published before LISTEN was established.

## 12. Function bodies and expressions
### 12.1 Statements
**Accepted design, mostly Implemented.**

```text
<body> ::= { <statement> }

<statement> ::= <let-statement>
              | <if-statement>
              | <case-statement>
              | <exists-pack-statement>
              | <update-statement>
              | <telemetry-statement>
              | <init-telemetry-statement>
              | <ok-statement>
              | <fail-statement>
              | <enqueue-statement>
              | <publish-statement>
              | <with-transaction-statement>
              | <expr>
```

#### `let`

```text
<let-statement> ::= "let" <identifier> "=" <expr>
                  | "let" <identifier> "=" "check" <expr>
                  | "let" "(" <identifier> ":::" <identifier> ")" "=" <expr>
```

`let name = check expr` is the monadic success-binding form. If the check succeeds, the implementation binds a fresh named value for `name` using the raw payload of the successful check result plus the detached proof extracted from that result.

**No `let ... in` expression form.** `let` is a *statement*, not an expression. Tesl deliberately does not support `let x = expr in body` inline expressions. The single-statement form keeps function bodies linear and greppable — every binding is visible at a consistent indentation level — and avoids the "wall of parentheses" style that `let … in … let … in …` chains drift into. Use sequential `let` statements at the function body level instead. This is a settled design decision and will not change.

**Why `check` calls must be `let`-bound.** The GDP proof system tracks proofs by
*subject identity* — a stable compiler-assigned name for each bound value. A `check`
call produces a named proof that the subject `x` satisfies predicate `P`. For this
to work, the result must be bound to a name with `let x = check f(n)`, so the compiler
can associate the proof with the subject `x`. Writing `needsProof (check f(n))` without
a `let` binding is rejected because there is no stable subject name to attach the proof
to. The proof only exists in the scope of the `let`-bound name.

A bare `check` call used as a statement (result not bound) is also a compile-time error:

```tesl
fn demo(raw: Int) -> Int =
  check isPositive raw   # ERROR: bare `check` — result not bound, proof discarded
  42
```

The compiler rejects this with: `"bare \`check\` call: the result must be bound with \`let x = check f(n)\`"`. A bare `check` does not gate subsequent statements — it discards both the validated value and the proof.

**And the converse: a check function may not be called WITHOUT `check`.** A check-shaped callee (a `check`-kind function, or a stdlib name that returns a check result — `JWT.verify`, `Crypto.checkPassword`, `Float.requireNonZero`, `Units.requireNonZero`, `Dict.requireKey`, `Int.nonZero`, …) returns *either* the payload *or* a check-fail value carrying the status. Only `check` unwraps that and propagates the failure, so an unwrapped check result must not escape into ordinary value position. All three positions it could escape through are rejected:

```tesl
let claims = check JWT.verify token key      # the only accepted form
JWT.verify token key                         # ERROR: bare call, result discarded
Dict.lookup "sub" (JWT.verify token key)     # ERROR: argument position
let claims = JWT.verify token key            # ERROR: plain `let`, no `check`
```

The last one is refused with ``"check function `JWT.verify` must be bound with `check`"`` and ships the `check` insertion as a machine-applicable fix. Without it, `claims` would be bound to the check-fail value on the failure path and then read as if the check had succeeded — a defect visible only on the error path. The rule fires on **saturating** calls only: a partial application (`Dict.requireKey "sub"`, `List.filterCheck (checkInBounds 0 100) xs`) hands over a check *function*, not a check *result*, and stays legal.

The symmetric rule holds for the keyword itself: `check` produces a check *result*, so it must be **fully applied**. `List.filterCheck (check checkInBounds 0 100) xs` is refused with ``"`check checkInBounds` is applied to 2 of its 3 arguments"`` — drop the keyword to hand the function over. A partially applied check used as a callback may also close over the fact's non-element subjects, and those must match what the return type declares: filtering with `checkAtMost other` while returning `List Int ::: ForAll (AtMost hi)` is refused.

`let (x ::: p) = y` is proof decomposition. It elaborates to `x = forgetFact(y)` and `p = detachAllProof(y)`. The value `x` preserves the hidden subject identity of `y` but has no attached proofs. The proof `p` is a first-class detached proof carrying all facts that were attached to `y`. This form is only valid when `y` has at least one attached proof.

The proof side supports `&&`-separated patterns with `_` as discard:

```tesl
let (x ::: _ && q) = y           # discard left proof, bind right as q
let (x ::: p && _) = y           # bind left as p, discard right
let (x ::: p && q) = y           # bind both
let (_ ::: p) = y                # discard value, bind proof only
let (x ::: _ && q && r) = y      # three-way: discard first, bind second and third
```

Pattern matching is positional over the flat conjunction structure. For a value carrying `A && B && C`, the first pattern item corresponds to `A`, the second to `B`, the third to `C`. The elaboration uses `andLeft`/`andRight` to project each part. `_` means the projected proof is discarded.

**`let (_ ::: p) = check f(x)` — validate and keep original name.** A particularly useful combination: decompose a `check` result immediately, discarding the value binding but keeping the proof. The compiler tracks that `p` is the proof *about* `x`, so the proof can be re-attached to `x` with `x ::: p` or `attachFact x p`:

```tesl
fn insertValidated(t: Tree, raw: Int) -> Tree =
  let (_ ::: p) = check checkPositive raw
  let proven = raw ::: p       # raw now carries IsPositive raw
  insertTree t proven          # insertTree requires IsPositive on its second arg
```

This is the idiomatic pattern when downstream code refers to the original binding name (`raw`) rather than the check-result name, or when you need to store the proof separately before re-attaching it. The compiler is smart enough to know that `p` is the proof of `raw`'s subject, so re-attachment is sound.

#### `if`

```text
<if-statement> ::= "if" <expr> "then"
                   <body>
                   "else"
                   <body>
```

**`if/then/else` must be multi-line in function bodies.** Inline single-line `if cond then a else b` is not accepted. Both the `then` and `else` branches must be on separate indented lines:

> **Design note — single-line `if` is forbidden by design.** The parser intentionally rejects `if cond then a else b` on one line. This is not an incidental parser limitation; it is an explicit formatting constraint to ensure that branch structure is always visually clear and consistent across all Tesl code.

```tesl
# Correct
if n > 0 then
  "positive"
else
  "non-positive"

# Rejected — single-line form not supported
if n > 0 then "positive" else "non-positive"
```

#### `case`

```text
<case-statement> ::= "case" <expr> "of" <case-branch>+
<case-branch>    ::= <case-pattern> [ "where" <expr> ] "->" ( <expr> | <body> )
<case-pattern>   ::= <constructor-pattern>
                   | <lit-pattern>
                   | <identifier>
                   | "_"
<constructor-pattern> ::= <UIDENT> { <field-pattern> | "_" }
                        | <UIDENT> "{" <label-pattern> { "," <label-pattern> } "}"
<field-pattern>  ::= <identifier>                          (* variable binding *)
                   | "_"                                   (* wildcard *)
                   | "(" <constructor-pattern> ")"         (* nested constructor *)
                   | "Nothing"                             (* bare nullary Maybe variant *)
                   | <UIDENT>                              (* bare nullary constructor *)
<label-pattern>  ::= <IDENT> "=" <case-pattern>
<lit-pattern>    ::= <STRING>                              (* string literal match *)
                   | <INT>                                 (* integer literal match *)
```

Duplicate binders in a case pattern are illegal. The underscore `_` is not a binder.

**Literal patterns.** String and integer literals match exact values:

```tesl
case code of
  200 -> "OK"
  404 -> "Not Found"
  _   -> "other"

case cmd of
  "help"  -> showHelp()
  "quit"  -> quit()
  other   -> unknown other
```

Literal patterns do NOT count toward exhaustiveness for general types (`Int`, `String`) — a variable or wildcard catch-all arm is always required.

**Nested constructor patterns.** A field position can contain a sub-pattern to match the nested constructor:

```tesl
# Positional syntax (wraps the sub-pattern in parens):
case m of
  Wrap (Something n) -> n
  Wrap Nothing       -> 0

# Labeled syntax (uses braces with field = sub-pattern):
case v of
  Wrap { inner = Something { value = n } } -> n
  Wrap { inner = Nothing }                 -> 0
```

**Case expressions must be exhaustive.** Every constructor of the matched ADT must appear in some branch. Non-exhaustive `case` is a compile-time error listing the missing constructors.

**`where` guards.** A `where` clause adds a runtime condition to a case arm. The guard is evaluated *after* the pattern matches. If the guard is false the arm is skipped and the next arm is tried:

```tesl
case existing of
  Nothing ->
    fail 404 "not found"
  Something todo where todo.ownerId != requestUser.id ->
    fail 403 "not your todo"
  Something todo ->
    todo
```

The `where` guard is emitted as part of the `cond` condition in the compiled Racket — it does **not** execute the arm body before checking the guard. This means bound pattern variables (like `todo` above) are available to the guard expression.

**Explicit binders required.** Every field of a constructor must be explicitly bound or wildcarded. `Circle _ ->` for a one-field constructor, `AlternativeA _ s ->` for a two-field constructor. Omitting binders is an arity error.

**Fall-through arms.** A branch with an empty body (no expression after `->`) is a fall-through arm. It shares the body of the next non-empty arm. This provides the "or-pattern" idiom without wildcard syntax:

```tesl
case status of
  Backlog    ->
  Todo       ->
  Cancelled  ->
    "inactive"     # Backlog, Todo, and Cancelled all use this body
  InProgress ->
  InReview   ->
    "active"       # InProgress and InReview use this body
  Done       ->
    "complete"
```

Fall-through arms may carry binders (`AlternativeA _ s ->`), but those binders are **ignored at runtime** — only the body arm's binders are accessed. This lets you document the constructor's fields for readability without affecting behaviour.

Safety check for the body arm closing a fall-through group: every field label that the body arm binds must exist in **all** preceding fall-through constructors. If a pending constructor lacks the field, the compiler rejects it:

```tesl
type Bepa
  = AlternativeA x:Int s:String
  | AlternativeB s:String
  | AlternativeC t:Int          # does NOT have field 's'

# VALID — AlternativeA and AlternativeB both have field 's'
fn f(b: Bepa) -> String =
  case b of
    AlternativeA _ s ->         # fall-through; 's' documented but ignored
    AlternativeB s ->           # body: accesses field 's' (exists in both)
      *s
    AlternativeC _ ->
      "no-string"

# COMPILE ERROR — AlternativeC lacks field 's'
fn g(b: Bepa) -> String =
  case b of
    AlternativeC _ ->
    AlternativeB s ->           # error: AlternativeC has no 's' field
      *s
```

Additional fall-through constraints:
- The final arm in the entire `case` must have a body — a trailing empty arm is a compile error.
- Wildcard patterns (`_`) are not supported as standalone constructor names by design; fall-through is the intended mechanism for grouping constructors.

#### Existential packing

```text
<exists-pack-statement> ::= "exists" <identifier> "=>" <body>
```

This statement does not bind a fresh variable. It packages an existing named value as an existential witness.

#### Resource blocks

There are none. A database is connected by the `App { database: X }` field `main` returns
(§11.13), which binds it for the whole program, and a test binds one with the
`test "..." with database X { ... }` header (see **Test databases**). The free-floating
`with database X { ... }` block was removed (2026-08-17): wherever the named database was
Memory-backed it did nothing at all, which was every use of it, and in a test body it silently
DISCARDED the name — the block read the in-memory store while the author had asked for the
server. There is no `with capabilities { ... }` block either; capabilities flow from each
declaration's `requires` and are granted at the App root (§11.13).

#### Success and failure

```text
<ok-statement> ::= "ok" <expr> ":::" <gdp-expr>
<fail-statement> ::= "fail" <integer> <expr>
```

**`fail` shape is intentionally minimal.** `fail STATUS "message"` takes exactly an HTTP status code and a plain message. Tesl deliberately does **not** accept a structured JSON payload here. The rationale:

1. Tesl pushes validation to the edge (codecs + `check`), so once a handler body runs, the rest of the request is structurally correct. The remaining failure modes are small and enumerable.
2. A single consistent error shape (status + message) is easier for clients to consume than a union of ad-hoc per-endpoint error bodies.
3. Complex error payloads encourage treating `fail` as a side channel for computed values. That is exactly the ambiguity Tesl's proof system is built to eliminate.

If a handler genuinely needs to return a machine-readable error envelope (for example to surface which of several field-level checks failed in a single response), the right shape is an ordinary success branch returning a domain record that carries the failure data, and a consistent client-side contract about how to interpret it. `fail` remains the short, minimal, "stop and return this status" escape hatch.

This is a settled design decision.

#### The two `ok` forms are not interchangeable

There are two distinct `ok` forms, and they serve different purposes:

- **`ok val ::: proof`** — canonical for `check` and `auth` functions. Produces a `check-ok` carrying the value, plus the proof fact(s) from `proof`. The `let x = check f(n)` form binds `x` as a named-value with the proof attached and the raw value preserved as the subject.

- **Direct proof constructor** — an `establish` returning `Fact (P args)` or `Maybe (Fact (P args))` constructs the detached proof directly, e.g. `IsPositive n` or `PriceExceedsQuantity price quantity`:

```tesl
establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n

establish validatePort(p: Int) -> Maybe (Fact (ValidPort p)) =
  if 1 <= p && p <= 65535 then
    Something (ValidPort p)
  else
    Nothing
```

An `establish` may instead return `Maybe (value: T ::: P value)`. Its success
payload retains the ordinary value while its evidence erases. Every returning
`Something` must carry all declared predicates on that payload; `Nothing` carries
no obligation. A bare attachment (`n ::: P n`) may mint at this trusted boundary;
HTTP-shaped `ok` syntax remains forbidden. Returning an unproven payload, evidence
about another subject, or only one part of a conjunction is a compile error.

```tesl
establish tryPositive(n: Int) -> Maybe (value: Int ::: IsPositive value) =
  if n > 0 then
    Something (n ::: IsPositive n)
  else
    Nothing
```

**`establish` is total.** Unlike `check` functions, `establish` functions cannot use `fail` — they must always return a value. If the proof cannot be established, return `Nothing` for either optional return form. An `establish` body that uses `fail` is a compile-time error.

Both `ok val ::: proof` and direct proof constructors work naturally with the proof system. However, they are **not interchangeable in general**:

- Using `ok val ::: proof` (the `check` form) in an `establish` function is a compile-time error.
- Using direct proof constructors in a `check` function is a compile-time error.
- Calling `detachFact` on an `ok <| proof` result (`detached-proof`) produces a **doubly-wrapped detachment** — a `detached-proof` wrapping another `detached-proof` — which is not a valid proof carrier.

**`ok` binding name requirement in `check` functions.** The expression after `ok` must be the declared binding name. `ok 42 ::: IsPositive n` is rejected — the literal `42` is not the binding `n`. The proof must also match the declared return spec exactly:

```tesl
# WRONG — literal is not the binding name
check bad(n: Int) -> n: Int ::: Positive n =
  if n > 0 then ok 42 ::: Positive n   # error: must return n, not 42
  else fail 400 "..."

# WRONG — proof args in wrong order
check bad2(lo: Int, hi: Int) -> lo: Int ::: InRange lo hi =
  ok lo ::: InRange hi lo              # error: proof does not match

# RIGHT
check validatePositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then ok n ::: Positive n
  else fail 400 "not positive"
```

#### Miscellaneous body statements

```text
<telemetry-statement> ::= "telemetry" <string> "{" [ <telemetry-attr> { "," <telemetry-attr> } ] "}"
<telemetry-attr> ::= <identifier-or-dotted> "=" <expr>

<init-telemetry-statement> ::= "initTelemetry" "service" <string> "endpoint" <string> "console" ("true" | "false")
                               [ "metrics" ("true" | "false") ] [ "metricsInterval" <int> ]
                               [ "traces" ("true" | "false") ] [ "traceRatio" <float> ]
```

There is no `serve` statement. The HTTP server is started by the runtime from the `api` field of the `App` record returned by `main` (§11.13).

#### `enqueue`
**Accepted design, Implemented.**

```text
<enqueue-statement> ::= "enqueue" <identifier> <record-literal>
```

Inserts a job of the named record type into the associated queue. The job type determines the queue unambiguously — each job type belongs to exactly one queue (compiler enforces). Requires the relevant `queueWrite`-derived capability.

```tesl
enqueue SendEmail { to: req.email, subject: "Welcome!", body: "..." }
```

Inside a `transaction` block, the job is inserted atomically — it only becomes visible to workers if the transaction commits. Outside a transaction, delivery is at-most-once (lint warning emitted).

#### `publish`
**Accepted design, Implemented.**

```text
<publish-statement> ::= "publish" <identifier> "(" [ <expr> { "," <expr> } ] ")" <adt-constructor-expr>
```

Publishes an event to the named channel, parameterised by the channel key. The second argument must be a constructor of the channel's `payload` ADT. Requires `pubsub` capability.

```tesl
publish UserEvents(userId) ProfileUpdated { bio: newBio }
```

Inside `transaction` with a PostgreSQL database active: writes the event to `tesl_pubsub_outbox` as part of the same transaction; in-memory listeners are called after commit. If the transaction rolls back, neither the outbox row nor the listener call happens. Outside a transaction: calls in-memory listeners directly (at-most-once semantics).

#### `transaction`
**Accepted design, Implemented.**

```text
<with-transaction-statement> ::= "with" "transaction" "{" <body> "}"
```

Wraps all enclosed database operations (`insert`, `update`, `delete`, `enqueue`, `publish`) in a single Postgres transaction. The block returns its last expression. On any exception, the transaction rolls back and no jobs or notifications escape. Nesting `transaction` inside another `transaction` is a compile error.

```tesl
transaction {
  let user = insert User { id: userId, email: req.email }
  enqueue SendEmail { to: req.email, subject: "Welcome!" }
  user   # returned value
}
```

#### Dead-letter workers: `deadWorker` and the job dead slot
**Accepted design, Implemented.**

When a job fails `maxAttempts` times it moves to `dead` status and is skipped by the normal worker loop. A separate **dead-letter worker** handles these jobs — typically to send an alert, log the failure, or publish a compensating event.

**`deadWorker`** is declared exactly like `worker`, except with the `deadWorker` keyword and the `FromDeadQueue` proof (instead of `FromQueue`):

```text
<dead-worker-fn>  ::= "deadWorker" <identifier> "(" <param-list> ")"
                      [ "->" <type-expr> ]
                      "requires" "[" <capability-list> "]"
                      "=" <body>
```

```tesl
deadWorker handleDeadEmail(job: SendEmail ::: FromDeadQueue (Id == jobId) job)
  requires [alertCap] =
  telemetry "email.dead" { to = job.to, subject = job.subject }
  publish AdminAlerts() EmailDeliveryFailed { to: job.to }
  job
```

Returning the job value marks it **acknowledged** (deleted from the dead-letter queue). Calling `fail` restores it to `dead` status for the next dead-worker pass.

**Wiring.** There is no `deadWorkers` mapping declaration and no `startDeadWorkers` call. A dead-letter worker is folded into the queue via the job's **dead slot** — `(Something handleDeadEmail)` in the `jobs` list (§11.15); use `(Nothing)` when a job has no dead-letter worker:

```tesl
queue EmailQueue requires [smtpSend, alertCap] = Queue {
  database: MainDatabase
  jobs: [Job SendEmail sendEmailWorker (Something handleDeadEmail)]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
```

Listing `EmailQueue` in `App.queues` (§11.13) activates the dead-letter poll loop alongside the normal workers — no explicit start call. The dead-letter loop is always single-threaded and polls every 10 seconds (no NOTIFY wakeup — dead jobs are infrequent). On success the job row is deleted; on failure it stays `dead` and will be retried on the next poll.

### 12.2 Expressions
**Accepted design, partly Implemented.**

```text
<expr> ::= <raw-expr>
         | <attach-sugar>
         | <paren-call-expr>
         | <qualified-name>
         | <select-expr>
         | <insert-expr>
         | <record-literal>
         | <record-update>
         | <list-literal>
         | <string-literal>
         | <integer>
         | "true"
         | "false"
         | "Nothing"
         | <identifier>
         | "(" <expr> ")"
         | <expr> <value-op> <expr>
         | <expr> "|>" <expr>
         | <expr> "<|" <expr>
```

#### List literals
**Accepted design, Implemented.**

```text
<list-literal> ::= "[" [ <expr> { "," <expr> } ] "]"
```

List literals construct a Racket list. The empty list is `[]`; a list with elements is `[a, b, c]`. All elements are compiled with `raw_default=True` (their GDP subject wrappers are stripped to plain values).

```tesl
let empty  = []                # Racket: (list)
let ns     = [1, 2, 3]        # Racket: (list 1 2 3)
let nested = [[1, 2], [3, 4]] # Racket: (list (list 1 2) (list 3 4))
```

**Important:** the `[...]` bracket depth is tracked by all internal splitting functions, so nested list literals parse correctly. `[["a","b"],["c","d"]]` is two elements, not four.

#### Implicit value unwrapping

Tesl parameters and locally bound proof-carrying values are automatically unwrapped by the compiler where a raw (non-GDP) value is needed — for example, in arithmetic, comparisons, string interpolation, and function arguments. There is no surface syntax for manual unwrapping; the compiler infers the correct representation at each use site.

#### Proof attachment sugar

```text
<attach-sugar> ::= <expr> ":::" <proofish-expr>
<proofish-expr> ::= <expr> { "&&" <expr> }
```

This lowers to `attachFact(value, proofish)`.

The preferred pattern for passing a proof-bearing value to a function is `f <| value ::: proof`, which combines `<|` (low-precedence application) with `:::` (proof attachment). This avoids explicit `attachFact` calls in most cases:

```tesl
listen <| port ::: portProof          # preferred
listen (attachFact port portProof)   # equivalent but verbose
```

Important distinction:

- in a proof fact, `&&` and `||` are logical operators over facts;
- in a proofish expression position, `&&` is currently used as proof-value composition, building a collection of detached proofs to attach.

**`:::` requires a proof value, not a predicate expression.** The right-hand side of `:::` in expression context must be an existing proof value — typically the return value of an `establish` or `check` function, a variable holding a detached proof, or a composition built with `introAnd`/`detachFact`. Writing a raw predicate expression such as `value ::: IsPositive x` is only valid inside `establish`, `check`, and `auth` functions (where `ok val ::: Pred val` is the proof-introduction form). In `fn` and `handler` bodies it is rejected at compile time with a clear error. This rule exists because a raw predicate expression in `:::` position would otherwise fabricate a proof fact without going through any validation boundary.

#### Function application
**Accepted design, Implemented.**

Tesl uses ML-style space-separated application:

```text
<application> ::= <callee> <atom> { <atom> }

<callee> ::= <identifier> | <dotted-identifier> | "(" <expr> ")"
<atom> ::= <identifier> | <integer> | <string-literal> | "(" <expr> ")"
```

```tesl
detachFact y
attachFact x proof
add (double x) (double y)
String.length title
(checkActive && checkPinned) note
```

Parentheses are only for grouping or for forming a grouped callee. They do not introduce legacy `f(x)` call syntax. Use `String.startsWith title "todo-"`, not `String.startsWith(title, "todo-")`.

Bare function names are first-class values. Use `f` when passing or storing a function, and use `f()` only for an explicit zero-argument call. This keeps zero-arg invocation distinct from function values while still rejecting legacy `f(x)` / `f(x, y)` syntax.

Application has the highest precedence among expression forms. Parentheses serve as grouping when a subexpression needs to be passed as a single argument: `double (add x y)`.

Function *declarations* retain parenthesized parameter syntax with type annotations, as this is required for the GDP name/subject/type binding machinery.

#### Receiver-style method syntax is not part of the language
**Accepted design, Implemented.**

Receiver-style dotted function syntax is not part of the language and is rejected by the compiler. The canonical style is namespaced function calls:

- `String.length(title)` instead of `title.length`
- `String.startsWith(title, "prefix")` instead of `title.startsWith("prefix")`
- `List.isEmpty(xs)` instead of `(xs).isEmpty`

#### Low-precedence application and pipeline operators
**Accepted design, Implemented.**

```text
<pipe-expr> ::= <expr> "|>" <expr>
<apply-expr> ::= <expr> "<|" <expr>
```

`|>` is the left-to-right pipeline operator. `x |> f` is equivalent to `f x`. Chains are left-associative: `x |> f |> g` is `g (f x)`.

`<|` is the right-to-left low-precedence application operator (analogous to Haskell's `$`). `f <| x` is equivalent to `f x`. Chains are right-associative: `f <| g <| x` is `f (g x)`.

Both operators have the lowest precedence of all expression operators — lower than `:::`. This means `f <| x ::: proof` parses as `f <| (x ::: proof)`, which is the idiomatic way to pass a proof-bearing value to a function:

```tesl
listen <| port ::: portProof       # f <| (value ::: proof)
port ::: portProof |> listen       # (value ::: proof) |> f
```

The existing `ok <| ProofFact` in proof-producing functions is a special case of `<|` applied to the `ok` form.

#### Query/update forms

The current `.tesl` frontend includes a small SQL-like sublanguage:

```text
<select-expr> ::= "selectOne" <identifier> "from" <entity>
                              [ <select-clause>* ]
               | "select" <identifier> "from" <entity>
                          [ <select-clause>* ]
               | "selectCount" <identifier> "from" <entity>
                               [ <select-clause>* ]
               | "selectSum" <identifier> "." <field> "from" <entity>
                             [ <select-clause>* ]
               | "selectMax" <identifier> "." <field> "from" <entity>
                             [ <select-clause>* ]
               | "selectMin" <identifier> "." <field> "from" <entity>
                             [ <select-clause>* ]
               | "selectCountBy" <identifier> "from" <entity>
                                 [ <select-clause>* ] <group-by-clause>
               | "selectSumBy" <identifier> "." <field> "from" <entity>
                               [ <select-clause>* ] <group-by-clause>

<select-clause> ::= "where" <sql-predicate>
                  | "where" "isNull"    <field-ref>
                  | "where" "isNotNull" <field-ref>
                  | "where" "inList"    <field-ref> "[" <expr>* "]"
                  | "where" "notInList" <field-ref> "[" <expr>* "]"
                  | "where" "like"      <field-ref> <string-expr>
                  | "where" "ilike"     <field-ref> <string-expr>
                  | "order"   <field-ref> ( "asc" | "desc" )
                  | "limit"   <int>
                  | "offset"  <int>
                  | "innerJoin" <entity> "on" <binder-field-ref> <entity-field-ref>

<group-by-clause> ::= "groupBy" <field-ref>
                    | "groupBy" "(" <time-trunc> <expr> <field-ref> ")"
<time-trunc> ::= "Time.truncHour" | "Time.truncDay" | "Time.truncWeek"
               | "Time.truncMonth" | "Time.truncYear"

<insert-expr> ::= "insert" <identifier> <record-literal>

<upsert-expr> ::= "upsert" <entity> "{" { <field-init> } "}"
                  "onConflict" "[" <field>+ "]"
                  "doUpdate"   "[" <field>+ "]"

<delete-expr> ::= "delete" <identifier> "from" <entity>
                            [ <select-clause>* ]
               | "deleteAndReturnResult" <identifier> "from" <entity>
                                        [ <select-clause>* ]

<update-statement> ::= "update" <identifier> "in" <identifier>
                       <update-line>+
<update-line> ::= "where" <sql-predicate>
                | "set" <identifier> "." <identifier> "=" <expr>
                | "returning" "one"

<sql-predicate> ::= <identifier> "." <identifier> <comparison-op> <expr>
<comparison-op> ::= "==" | "!=" | "<=" | ">=" | "<" | ">"
```

The parser produces a dedicated `ESqlQuery` AST node for each recognized select, insert, upsert,
update, delete, or `deleteAndReturnResult` expression. SQL clause keywords and their source spans
are consumed before the node is built, including multiline and parenthesized continuations. The
checker, capability validator, index linter, and Go backend read the same `sql_query` payload; they
do not independently reinterpret the application tree. A malformed SQL-shaped expression is left
unrecognized and receives the normal fail-closed structural diagnostic rather than being emitted as
an ordinary function call.

**`innerJoin` — inner join by FK.** Returns only rows from the main entity for which a matching row exists in the joined entity. The two field refs after `on` are the main entity's FK field and the join entity's matching field (no `==` operator — `==` sits above function application in Tesl's grammar). A query requires `dbRead` for every entity it touches: the examples below require both `dbRead User` and `dbRead Profile`, and multiple joins add one requirement per joined entity.

```tesl
select u from User innerJoin Profile on u.profileId Profile.id

select u from User
  where u.active == True
  innerJoin Profile on u.profileId Profile.id
```

**Aggregate queries.** All aggregate forms require `dbRead Entity` for their source entity. `selectCount` always returns `Int`. `selectSum` returns the same type as the target field (e.g. `Int` for an integer field, `Float` for a float field) — zero is its identity, so no matching row is `0`, not an absence. `selectMax` and `selectMin` return **`Maybe <field type>`**: over no matching row there is no value of the column's type to return, and inventing one (or handing back a SQL `NULL` typed as the column) would be unsound. Callers `case` on the result.

**Grouped aggregates (GitHub #29).** `selectCountBy` / `selectSumBy` return **one row per
group** as a `List (Tuple2 key aggregate)`, ordered by key ascending, and require exactly
one `groupBy` clause. The key is a declared column (`groupBy e.category` — key type = the
column's type) or a **calendar bucket** of a `PosixMillis` column:
`groupBy (Time.truncDay zone e.startedAt)` — key type = `PosixMillis`, the bucket-start
instant for the wall clock in that `TimeZone` (`Time.truncHour/Day/Week/Month/Year`;
week = ISO week, Monday start). On PostgreSQL the bucket is computed server-side —
exact integer floor arithmetic for `Utc`/`FixedOffset` keys, and PostgreSQL's own
tzdata (`date_trunc(… AT TIME ZONE 'Europe/Stockholm')`) for zone-constructor keys, so
DST is handled per row inside the query. The "datetime under the hood" is confined to
the generated SQL; the column stays BIGINT millis and the key stays `PosixMillis`. The
Memory backend calls the same reference engine the PostgreSQL expressions are
parity-tested against. Worked examples: lesson 21 (§16b, time and timezone queries).

```tesl
# minutes per local day for one org — one (dayStart, sum) row per day
selectSumBy e.minutes from Entry
  where e.orgId == orgId
  groupBy (Time.truncDay EuropeStockholm e.startedAt)   # List (Tuple2 PosixMillis Int)

selectCountBy e from Entry groupBy e.orgId              # List (Tuple2 String Int)
```

The `Time.trunc*` functions are ordinary pure functions (`Int -> PosixMillis ->
PosixMillis`), so calendar **filtering** needs no SQL bucketing at all — compute the
zone-aware boundary client-side and use a sargable range `where`:

```tesl
let dayStart = Time.truncDay EuropeStockholm (nowMillis())
let dayEnd = addMs dayStart 86400000
selectSum s.soldItemPrice from Sale
  where s.soldAt >= dayStart && s.soldAt < dayEnd     # "revenue today", index-friendly
```

(On DST-transition days a local day is 23h or 25h, so compute `dayEnd` with a second
`truncDay` on a later instant rather than trusting `+86400000` when exactness at the
transition matters.) Note: zone rules for FUTURE instants depend on the tzdata version
of each component (the runtime reads the system tzdata; PostgreSQL bundles its own —
pin both, e.g. via nix). `groupBy` on the scalar aggregate forms or on plain
`select`/`selectOne` is a **compile error** (before #29 it was silently dropped);
`order`/`limit`/`offset`/`innerJoin` are rejected on the grouped forms. Grouped results
are plain proof-free values (no `FromDb` — no entity row flows out).

```tesl
let total  = selectCount u from User where u.active == True     # Int
let total  = selectSum   u.score from User                      # Int (or Float)
let top    = selectMax   u.score from User where u.active == True   # Maybe Int
let bottom = selectMin   u.score from User                          # Maybe Int
```

`selectMax`/`selectMin` are optional, so a caller decides what "no rows" means:

```tesl
fn highestScore() -> Int requires [dbRead User] =
  case selectMax u.score from User of
    Nothing -> 0
    Something score -> score
```

**`upsert` — INSERT … ON CONFLICT DO UPDATE.**  Inserts a record; if the conflict column(s) already exist, updates only the listed fields.  `onConflict` takes the column(s) to conflict on (usually the unique/PK columns); `doUpdate` lists the columns to overwrite on conflict.

```tesl
upsert Session { userId: uid, token: tok, expiresAt: exp }
  onConflict [userId]
  doUpdate   [token, expiresAt]
```

The conflict columns must be **either the primary key or a declared `unique index`** (§11.8) on that entity, and this is a compile-time error otherwise. PostgreSQL can only infer a conflict target from a unique index on exactly those columns; without one it fails at runtime with *"there is no unique or exclusion constraint matching the ON CONFLICT specification"*. So the example above requires `unique index [userId]` on `Session` unless `userId` is its primary key.

**`delete` and `deleteAndReturnResult`.** `delete` removes matching rows and returns `Unit`. `deleteAndReturnResult` removes matching rows and returns the non-negative `Int` count of deleted rows, including `0` when no rows match. Both operations require `dbWrite Entity`; the capability constructor is imported bare from `Tesl.DB`:

```tesl
import Tesl.DB exposing [dbWrite]

# Simple delete (returns Unit)
delete u from User where u.id == userId

# Delete with count inspection
let result = deleteAndReturnResult u from User where u.id == userId
```

## 13. Static semantics
### 13.1 Names, duplication, and imports
**Accepted design, Implemented.**

- A module header is mandatory.
- The module header may appear only once.
- Export lists must be explicit. Wildcard exports are rejected.
- Imports may use either an explicit `exposing [...]` list or the module-import form (`import Module`) for qualified-only access.
- Duplicate top-level definitions are rejected.
- Imported names may not conflict with local definitions.
- The same imported name may not arrive from two different imports.
- Same-spelled type aliases, records, entities, and ADTs defined in different modules are distinct declarations; identity is tied to the defining module, not just the bare name.
- If multiple imported declarations would make an unqualified type-like reference ambiguous, the program must use module qualification/prefixing instead of relying on bare-name resolution.
- `Type(..)` import/export syntax is only valid for locally defined or exported ADTs.
- Proof predicates (upper-case names used in `:::` annotations, such as `ValidPort` or `IsPositive`) are part of the module namespace. They must be explicitly exported by their home module and explicitly imported by any module that names them in function or record annotations. Using a predicate in a signature without having imported it is a compile error. This rule applies to parameter annotations, return spec proof annotations, and `Fact(...)` return types.

### 13.2 No-shadowing rule
**Accepted design, Implemented.**

The following are compile-time errors when they shadow an already-visible name:

- function parameters;
- `let` bindings;
- `case` binders.

This rule exists because the language treats visible binders as proof-relevant carriers of hidden GDP names.

### 13.3 Scope of `exists` in function bodies
**Accepted design, Implemented.**

`exists witness => ...` requires that `witness` already be a visible bound name. It is a packaging form, not a fresh binder form.

### 13.4 Scope of implicit unwrapping
**Accepted design, Implemented.**

Implicit value unwrapping applies to function parameters and locally bound proof-carrying values. The compiler automatically unwraps named values at use sites that require raw Racket values (arithmetic operators, comparisons, string interpolation, constructor arguments, stdlib calls). No surface syntax is required or accepted for manual unwrapping.

### 13.5 Scope of GDP names in proof templates
**Accepted design, Implemented.**

Proof templates are validated for scope. Unbound names inside proof-related syntax are rejected.

This includes, among other places:

- binding annotations;
- return annotations;
- proof-accepting success forms.

### 13.6 Static proof checking at call sites
**Accepted design, Implemented.**

For function calls, the frontend performs proof-aware static checking roughly as follows:

1. each visible value binder in scope carries a static subject identity;
2. when calling a function, the callee's formal parameter names are mapped to the actual argument subjects;
3. the callee's proof obligation is instantiated with that subject mapping;
4. if the obligation for the checked argument's own binder is still unresolved, the call is rejected;
5. if the obligation is fully known and the argument's known facts do not satisfy it, the call is rejected;
6. otherwise the call may be allowed and runtime validation remains authoritative.

This is how cross-parameter proof references such as `ValidPort x` on another parameter can be checked without confusing surface spelling with subject identity.

### 13.7 Static proof satisfaction
**Accepted design, Implemented.**

Static proof satisfaction is currently structural and uses these rules:

- an expected fact is satisfied if that fact is present exactly;
- `P && Q` is satisfied if both `P` and `Q` are satisfied.

### 13.8 Record and entity field restrictions
**Accepted design, Implemented.**

- Record fields may carry proof annotations and optional `via` checkers.
- Entity fields may carry only simple field proof names and do not support `via` checkers.

### 13.9 Proof predicate scope and explicit import
**Accepted design, Implemented.**

A proof predicate name is in scope in a module if and only if:

1. the module declares it — i.e. it is produced in the return type of a local `establish`, `check`, or `auth` function; or
2. the module explicitly imports it — i.e. the predicate name appears in an `import … exposing [...]` list and the exporting module lists it in `exposing [...]`.

This is the same rule that governs functions, record types, and ADT constructors. There is no implicit "transitive visibility" — a module that imports `isValidPort` from `Ports` does not automatically gain the ability to name `ValidPort` in its own annotations; it must import `ValidPort` explicitly too.

**Module-only imports do not expose proof predicates.** A bare `import Tesl.String` (no `exposing` clause) brings the module's functions into qualified scope (`String.length`, etc.) but does NOT make its proof predicates (`IsTrimmed`, `IsNonEmpty`, etc.) available in `:::` annotations. Proof predicates always require an explicit `exposing` clause:

```tesl
# WRONG — IsTrimmed is not in scope without explicit import
import Tesl.String
fn needTrimmed(s: String ::: IsTrimmed s) -> String = s   # compile error

# RIGHT
import Tesl.String exposing [String.trim, IsTrimmed]
fn needTrimmed(s: String ::: IsTrimmed s) -> String = s   # ok
```

The compiler error is: `"proof predicate \`IsTrimmed\` is not in scope; a plain module import does not expose proof predicates. To use it, add it to an explicit import: \`import Tesl.String exposing [IsTrimmed]\`"`.

**Why this rule exists:** In a large codebase there should be exactly one greppable canonical declaration of `ValidPort`. That declaration is the `exposing [ValidPort]` line in the home module. The import statement in every consuming module is an explicit acknowledgement of the dependency. Without this rule, a predicate name could proliferate invisibly across the codebase with no traceable origin.

**Partial application restriction:** Partial application of a function is rejected at compile time if any remaining parameter's proof annotation references a captured parameter. The resulting closure would require a proof about a hidden captured subject, which cannot be expressed or satisfied in Tesl.

## 14. Dynamic semantics
### 14.1 Runtime argument validation
**Accepted design, Implemented.**

Direct calls to executable/check-like definitions validate declared argument types and proofs at runtime.

This includes current `.tesl` functions lowered to:

- `define/pow`
- `define-handler`
- `define-trusted`
- `define-checker`
- `define-auther`

### 14.2 Runtime proof satisfaction
**Accepted design, Implemented.**

Runtime proof checking interprets the expected proof against:

- the facts attached to the evidence-bearing value;
- the runtime subject environment carried by that value.

As at compile time:

- exact facts satisfy themselves;
- `&&` requires all parts.

### 14.3 `detachFact`
**Accepted design, Implemented.**

- `detachFact(value)` extracts the attached proof from `value`.
- If no proof is attached, it fails.
- If exactly one proof is attached, it returns that proof as a `Fact`.
- If multiple separate proofs are attached, `detachFact(value)` **succeeds** by combining
  all attached facts into a single `&&` conjunction and returning the combined proof.
  This is equivalent to calling `detachAllFact`.
- To extract individual proofs from a conjunction, use `andLeft` and `andRight`, or
  use proof decomposition: `let (x ::: p1 && p2) = value` (see §15.2).

### 14.4 Proof decomposition
**Accepted design.**

Use `let (x ::: p) = value` (proof decomposition) to detach a proof from a value, or `let (x ::: p1 && p2) = value` to split a conjunction.

### 14.5 `attachFact`
**Accepted design, Implemented.**

`attachFact(value, proofish)` accepts:

- one detached proof; or
- a list/collection of detached proofs built by proofish conjunction.

It does not accept plain proof-fact data with no detached-proof carrier.

### 14.6 `forgetFact`
**Accepted design, Implemented.**

`forgetFact(value)` removes attached facts while preserving the subject identity and runtime bindings associated with the value.

### 14.7 Existentials
**Accepted design, Implemented for return specs and packing; elimination surface still evolving.**

The runtime supports existential packages plus witness-escape checks.

The current `.tesl` surface includes:

- existential return specs;
- existential packing with `exists witness => ...`.

Dedicated `.tesl` elimination syntax is not yet part of the stable surface.

**Structurally binding the witness to a record id field.** When a handler creates a resource and returns it with an existential proof, the proof fact should encode the primary-key equality explicitly — mirroring the SQL layer's `FromDb (Id == todoId)` pattern. For non-database resources, use a check function that validates `resource.id == witnessId` and constructs a proof of the form `IsCreated (Id == witnessId) ...`:

```tesl
check checkSessionCreated(session: Session, sessionId: String, user: String ::: Authenticated user)
  -> session: Session ::: IsCreatedSession (Id == sessionId) user =
  if session.id == sessionId then
    ok session ::: IsCreatedSession (Id == sessionId) user
  else
    fail 500 "session id does not match the witness"
```

The `(Id == sessionId)` sub-expression inside the proof fact is the structural binding — it closes the gap between the existential witness and the returned record's identity field. Without it, the proof claims "some session was created" but does not bind the returned session's id to the witness.

**Using `?` with existential returns.** For database entities, the `?` pack operator can be used inside an existential return to avoid naming the inner binder explicitly:

```tesl
handler post createTodo(requestUser: User ::: Authenticated requestUser, newTodo: NewTodo)
  -> exists todoId: String =>
       ?Todo ::: FromDb (Id == todoId)
  requires [dbWrite Todo, time] =
  let todoId = generateTodoId()
  exists todoId =>
    insert Todo { id: todoId, title: newTodo.title, ... }
```

The `?` here means the inner `Todo` entity is named by whoever unpacks the existential. This is the idiomatic form for create-resource handlers that return database entities.

### 14.8 Route/API boundaries
**Accepted design, Implemented**

At HTTP/API boundaries the runtime validates:

- captures;
- request bodies;
- proof-annotated record fields when a checker is available;
- successful handler returns that cross the HTTP boundary.

These runtime checks are boundary validation, not the primary mechanism for ordinary pure-language typing. Record-literal shape errors, wrong dotted field access, malformed existential returns, and mixed-type arithmetic/boolean/comparison expressions are intended to be rejected by the compiler before code generation or execution.

Current API declarations are intended to remain type-level, with the value-level wiring handled by `server` and `serve`.

## 14b. Structural type system
**Accepted design, Implemented.**

Tesl has two orthogonal type-checking layers:

1. **GDP proof annotations** — described throughout this spec. Check/establish
   function kinds stamp values with proof predicates. The compiler verifies
   that every proof obligation is satisfied.

2. **Structural HM types** — catches wrong-type arguments to stdlib functions
   at compile time, using Hindley–Milner type inference with Robinson unification.

### 14b.1 Type language

```
τ ::= Int | String | Bool | Float | PosixMillis    -- base types

Use `Bool` in Tesl source code. SQL storage types such as `BOOLEAN` are backend representations, not additional Tesl type names, and `Boolean` is not a source-language alias.
    | List τ                                        -- homogeneous list
    | Tuple2 τ₁ τ₂ | Tuple3 τ₁ τ₂ τ₃               -- tuple/product types
    | Maybe τ | Result τ e | Either l r             -- standard ADTs
    | Dict k v | Set τ                              -- collections
    | τ₁ → τ₂                                      -- function type
    | α                                             -- type variable
```

List literals `[e₁, e₂, ...]` are always `List τ` — homogeneous sequences.
A two-element literal `[a, b]` is `List τ`, not `Tuple2`; the elements must
share the same type.

**`Tuple2` and `Tuple3` are separate, distinct types from `List`.**
Use the `Tuple2 a b` and `Tuple3 a b c` constructors explicitly when you want
a product type. A `Tuple2 τ₁ τ₂` cannot be used where `List τ` is expected,
and a `List` literal cannot be used where `Tuple2` is expected — the compiler
rejects both with a type error.

```tesl
let pair = Tuple2 1 "hello"   # Tuple2 Int String
let xs   = [1, 2, 3]          # List Int

# ERROR — Tuple2 ≠ List
# let xs2 = Tuple2 1 2   (cannot pass to fn expecting List Int)
```

Use `Tesl.Tuple` to construct and deconstruct tuples:
- `Tuple2 a b` — constructor
- `Tuple2.first t`, `Tuple2.second t` — accessors
- `Tuple3 a b c`, `Tuple3.first/second/third` — analogous

Modules importing `Tesl.Units` additionally get dimensioned quantity types (`Length`, `Speed`, `Area`, …; §21.5): each is a canonical type over its SI exponent vector, arithmetic operators compute the result dimension per expression, a dimensionless result collapses to plain `Float`, and every quantity erases to `Float` at runtime.

### 14b.2 PosixMillis is not Int

`PosixMillis` is a nominal newtype. A plain `Int` does NOT satisfy a `PosixMillis`
expectation. Use `Time.secondsToPosix(s)` or `addMs(base, delta)` to construct
typed timestamps from integer literals. `PosixMillis` does **not** auto-unwrap to
`Int` in arithmetic or comparison expressions — use `diffMs(a, b)`, `addMs(ts, n)`,
or `subtractMs(ts, n)` explicitly.

### 14b.3 T_ANY — the escape hatch (stdlib only)

`T_ANY` is an internal sentinel that unifies with any type. It may only appear
in stdlib type signatures (e.g. the check-function argument of `List.filterCheck`)
and never in user code. Users cannot write `Any` in type annotations to bypass
type checking — the word `Any` in a Tesl type annotation is an opaque nominal
type, not the wildcard.

### 14b.4 Error format

Structural type errors use the same location format as GDP errors:

```
error: argument 1 to `Dict.fromList`: expected `List (k, v)` but got `Int`
  --> api.tesl:42
  expression: `Dict.fromList(1)`
  hint: Dict.fromList expects a list of Tuple2 key-value pairs, e.g.
    Dict.fromList [Tuple2 "key1" val1, Tuple2 "key2" val2]
```

Structural type checking is always on; there is no supported env-var bypass for accepted Tesl programs anymore.

### 14b.5 Expression forms covered by structural checking

The structural checker is responsible for the ordinary expression forms that should never fall through to backend/runtime failure for type reasons. In particular:

- record literals and record updates are checked against visible record, entity, or ADT-variant field declarations;
- dotted field access is checked against declared record/entity/variant fields, with `.value` as the explicit newtype unwrap;
- arithmetic, boolean, and comparison operators enforce operand constraints instead of accepting mixed-type expressions;
- when a function declares an existential return type, its terminal expression must be an existential pack (except for `fail ...` paths).

These checks are intentionally frontend responsibilities so that accepted ordinary Tesl programs do not depend on backend/runtime validation for basic type correctness.

---

## 15. Proof composition and decomposition
### 15.1 Implemented proof composition
The following are currently part of the implemented story:

- attaching a detached proof to a value with `attachFact(value, proof)`;
- the surface sugar `value ::: proofValue` where `proofValue` is an existing detached proof (from an `establish`/`check` function, a proof variable, or a composition);
- attaching multiple detached proofs via proofish conjunction `p1 && p2`;
- logical proof conjunction inside proof annotations and obligations using `&&`;
- selecting one proof from a multi-proof value using proof decomposition: `let (x ::: p1 && p2) = value` extracts the conjunction into individual named proofs `p1` and `p2`; `_` discards a slot.

The current proofish `&&` used for attachment is a composition device over detached proofs. It is not yet the final first-class recursive proof-term surface.

### 15.2 Proof decomposition
**Accepted design, Implemented.**

The first proof-decomposition syntax to pursue is:

- `let (x ::: p) = y`

This choice is deliberate:

- it keeps composition and decomposition visually related through `:::`;
- it avoids introducing a separate `split ...` statement before the proof-aware semantics are settled;
- it leaves room to extend the proof side later with `_` and recursive proof patterns.

The intended elaboration is:

- `x` means `forgetFact(y)`;
- `x` therefore preserves the hidden subject identity of `y`;
- `p` means the first-class proof value extracted from `y`;
- the form is only valid when that extraction is unambiguous under the core proof-selection rules.

This form must not be understood as ordinary pair destructuring. It is proof-aware sugar over the existing core operations.

The proof side also supports `&&`-separated patterns with `_` as discard, enabling selective proof extraction:

```tesl
let (x ::: _ && q) = y           # discard left, bind right
let (x ::: p && _) = y           # bind left, discard right
let (_ ::: p) = y                # discard value, bind proof only
let (x ::: _ && q && r) = y      # three-way decomposition
```

Possible later extensions include:

- template-directed proof selection for ambiguous multi-proof values;
- surface sugar for existential elimination.

Parameter syntax that directly splits a function input into value and proof binders is deferred until after local `let`-decomposition has proved sound and ergonomic.

Any future design here should preserve the invariants in sections 6 and 7.

## 16. Open design areas
### 16.1 Currying and partial application
**Accepted design, Implemented.**

Partial application is supported. When a function with known arity `n` is called with fewer than `n` arguments, the call returns a closure that captures the provided arguments and waits for the rest:

```tesl
fn add(x: Int, y: Int) -> Int = x + y

let add3 = add 3        # partial application — returns a closure
add3 4                  # 7
```

ML-style space-separated application works for both known functions and bound variables (including partially-applied closures):

```tesl
let f = add 3
f 4                      # 7
```

### 16.2 Low-precedence application and pipelines
**Implemented.** See Section 12.2 "Low-precedence application and pipeline operators".

### 16.3 Final public existential surface
**Accepted design, Implemented.**

Existential packaging uses `exists witness => body` in function bodies. The witness variable is scoped to the body block and cannot escape. Return types use `exists name: T => InnerType` syntax with exactly one unannotated witness; nested existential returns and proof annotations on the witness binder are rejected. The compiler enforces that ordinary functions with existential return types actually return a pack, while the runtime/core still enforces witness escape prevention at evaluation time. This surface is settled.

A function may also **forward** an existential instead of introducing one: if every tail of the body is a call to a function whose own return type has the same single binder name, the same ground non-function witness type, and a proof that entails the declared one once the callee's parameters are read at the call site, the package the caller receives is the callee's, unchanged. Generic/function-typed witnesses and alpha-renamed binder forwarding fail closed until package renaming and scoped type instantiation are implemented. This is what lets several thin handlers share one proof-carrying core:

```tesl
fn createThing(name: String) -> exists id: String => Thing ? FromDb (Id == id) ... =
  let id = generatePrefixedId "thing"
  exists id =>
    insert Thing { id: id, name: name, createdAt: nowMillis() }

fn viaSession(name: String) -> exists id: String => Thing ? FromDb (Id == id) ... =
  createThing name          # forwarded, not re-derived
```

Forwarding mints nothing, so it cannot forge: a callee carrying a different fact, a callee whose return type is not existential, an argument passed into the wrong proof-subject slot, and a fork where any one branch fabricates its value are all rejected.

### 16.4 The exact public role of `establish`
**Accepted design, Implemented.**

`establish` is the surface keyword for trusted fact introduction. It lowers to `define-trusted`, which is the only function kind where `trusted-proof` (and `ok <| proof`) are permitted. The boundary is enforced via a Racket syntax parameter that rejects those forms in all other function kinds.

The canonical usage pattern is:
- `establish` for functions that return a `Fact (ProofPredicate ...)` value — i.e. a first-class detached proof. The body returns the proof constructor directly (e.g. `IsPositive n`), which produces a `detached-proof`.
- `check` for functions that validate a value and return it with proof attached; uses `ok val ::: proof` in the body, which produces a `check-ok` with both value and facts.

See §12 (`ok` forms) for the precise syntax.

The name `establish` is settled. Renaming it is not planned.

**`establish`, `check`, and `auth` are the three proof-minting boundaries of
Tesl's GDP layer.** All three can attach a proof predicate to a value; all three
are equally capable of producing an incorrect proof if the programmer states the
wrong invariant. None of them is "more unsafe" than the others — the honest
framing is that every proof in the system is traceable back to exactly one of
these three kinds of function, and every one of them is a trust boundary that
deserves care.

The three kinds differ in *when* the proof can fail, not in the authority they
grant:

- `check` validates at runtime and can `fail STATUS "..."`. It is the right
  choice at external boundaries (HTTP request bodies, URL query parameters,
  environment variables, decoded data) where the input might legitimately be
  invalid.
- `auth` validates at runtime and can `fail STATUS "..."`. It is a specialised
  `check` whose proof is about *identity* rather than *shape*.
- `establish` is total: it cannot `fail`. It is the right choice when the
  proof follows from values that are already known to be good, or when you are
  writing an internal lemma that needs to succeed unconditionally. A conditional
  `establish` returns `Maybe (Fact (P ...))` and the caller handles the
  `Nothing` case — there is no silent failure path.

Because `establish` cannot `fail`, reviewers sometimes think of it as "the
unsafe version". That framing is misleading: an `establish` that returns the
wrong predicate is exactly as unsound as a `check` that returns the wrong
predicate. The right mental model is that all three function kinds are trust
boundaries, the entire file author is responsible for each one, and a single
convention — clear name, clear docstring, obviously-matching return
predicate — applies to all of them.

The design goal is that every proof in the system is traceable: either it
came through a runtime-validated `check`/`auth` boundary, or through a total
`establish` declaration. All three are equally inspectable by tools and
reviewers.

### 16.5 First-class recursive proof(fact) terms and proof(fact) combinators
**Accepted design, Implemented.**

Proof values should eventually support recursive conjunction/disjunction structure, not only atomic detached facts plus ad hoc proofish lists used for the current attachment surface.

This means the proof binder in a future decomposition such as `let (x ::: p) = y` should be able to denote structured proof values, including shapes like `P && Q && R`, provided the subject bindings remain well-scoped and well-founded.

To make explicit proof manipulation possible when it is actually needed, the language should grow a small principled family of proof introduction/elimination helpers.

These helpers must elaborate to the same subject-preserving core as `attachFact`, `detachFact`, and `forgetFact`. They must not retarget proofs, weaken the no-shadowing rule, or allow existential witnesses to escape.

### 16.6 A smaller formal core
This draft is intentionally operational and implementation-aware. A later revision should define a smaller elaboration core for:

- named values;
- raw projection;
- detached proofs;
- existential packaging;
- proof satisfaction.

That smaller core would make theoretical review easier.

### 16.9 List query proofs (`ForAll`)
**Implemented.**

`List T ::: ForAll P` is a compile-time annotation on list-returning functions that records "every element of this list satisfies proof predicate P". It is a type-level contract only — at runtime, the list is a plain Racket list with no per-element proof structs and zero overhead.

**Syntax:**
```tesl
fn listNotes(user: String ::: Authenticated user)
  -> List Note ? ForAll (FromDb (AuthorId == user))
  requires [noteDbRead] =
  select note from Note where note.authorId == user
```

**Rules:**
- `ForAll P` is valid on `List T` and `Set T` return types (and their `Maybe (...)` wrappers). Applying it to any other type is a compile error.
- `select ... from Entity where ...` automatically produces `List Entity ::: ForAll (FromDb ...)`.
- `List.filterCheck checkFn xs` produces a `ForAll` list of the check function's proof predicate.
- `List.allCheck checkFn xs` validates every element: returns `Nothing` if any fail, `Something list` if all pass — return type is `Maybe (List T ::: ForAll P)`.
- `Set.filterCheck checkFn s` — same as `List.filterCheck` but for sets: keeps elements that pass, returns `Set T ::: ForAll P`.
- `Set.allCheck checkFn s` — same as `List.allCheck` but for sets: returns `Nothing` if any element fails, `Something (Set T ::: ForAll P)` if all pass.
- `List.filter pred xs` does NOT produce a `ForAll` list — the predicate is opaque to the compiler. Likewise `Set.filter`.
- Inline `value ::: ForAll P` in a function body is rejected with a clear error.
- An empty list literal `[]` does **not** vacuously satisfy any `ForAll P` at **call sites** — passing `[]` to a function that requires `List T ::: ForAll P` is rejected. To construct an empty list that satisfies `ForAll P`, use `List.emptyForAll checkP` where `checkP` is the `check` function that establishes `P`. This makes the intent explicit rather than implicit. Note: returning `[]` directly from a `ForAll`-typed function body is currently accepted (the static checker does not enforce the requirement at return sites), but `List.emptyForAll` is still the recommended and explicit idiom.

Return type: use the ? operator — -> List T ? ForAll P. The explicit subject form -> T ::: ForAll P xs is not supported in return position. The ? operator automatically inserts the entity subject.

Parameter type: use ::: with explicit subject — xs: List T ::: ForAll P xs.

**ForAll proof expansion** — proofs combine, never replace:
```tesl
fn narrowToSmall(xs: List Int ::: ForAll (IsPositive) xs)
  -> List Int ? ForAll (IsPositive && IsSmall)  # P1 AND P2
  requires [] =
  List.filterCheck checkIsSmall xs
```
When `filterCheck` or `allCheck` is called on a list already annotated with `ForAll P1`, the programmer declares the expanded combined proof `ForAll (P1 && P2)` in the return type. The compiler accepts this; the programmer is responsible for the logical soundness of the combined claim.

**Check combination with `&&`:**
```tesl
fn filterBoth(xs: List Int) -> List Int ? ForAll (IsPositive && IsSmall)
  requires [] =
  List.filterCheck (checkIsPositive && checkIsSmall) xs
```
`checkA && checkB` composes two check/establish/auth functions: runs `checkA` first; if it passes, runs `checkB` on the result; if either fails the element is rejected. Right-associative: `checkA && checkB && checkC` = `checkA → checkB → checkC`. Works for `check`, `establish`, and `auth` functions, and mixed combinations.

**General-case `&&` — applying a combined check to a single value:**

The `&&` operator can be used beyond list operations. You can apply a combined check directly to a single value with ML-style application:

```tesl
let r = (checkActive && checkPinned) note
```

Or pass the combined checker itself as a first-class value to collection helpers:

```tesl
List.filterCheck (checkActive && checkPinned) notes
```

The combined checker itself still compiles to `(check-and checkActive checkPinned)` in Racket, but to run it as a check you must use the `check` keyword at the call site: `check (checkActive && checkPinned) note`. This is fail-fast validation: it behaves like nested checks, returning the validated value with the combined proof attached and failing on the first failing check. Use `establish` when you want a recoverable proof attempt instead.

**`List.allCheck`:**
```tesl
fn verifyBatch(notes: List Note)
  -> Maybe (List Note ::: ForAll (IsActive && IsPinned))
  requires [] =
  List.allCheck(checkActive && checkPinned, notes)
```
Unlike `filterCheck` (which drops failures), `allCheck` is all-or-nothing: if any element fails the check, the entire result is `Nothing`. Use when you want to accept a batch only if it is fully valid.

**`Maybe (List T ::: ForAll P)` return type:** valid as a first-class return spec. Emits `(Maybe (List T))` in Racket — the `ForAll` annotation is stripped.

**ForAll in parameter types:**
```tesl
fn countActive(notes: List Note ::: ForAll (IsActive)) -> Int requires [] =
  List.length(notes)
```
The `ForAll` annotation is stripped from the Racket binding; it is a static type-level annotation only.

**Not dependent types.** `ForAll`, check combination, and `allCheck` are a finite set of structural rules in the compiler — not term-level quantifiers. No dependent types infrastructure is required.

See also: `example/learn/lesson29-forall-list-proofs.tesl` (List ForAll), `example/learn/lesson30-forall-set-proofs.tesl` (Set ForAll).

### 16.9a Dict proof quantifiers (`ForAllValues`, `ForAllKeys`)
**Implemented.**

`Dict K V ::: ForAllValues P` and `Dict K V ::: ForAllKeys P` are compile-time annotations on dict-returning functions that record "every value (or key) of this dict satisfies proof predicate P". Like `ForAll`, these are type-level contracts only — at runtime the dict is a plain Racket hash with zero overhead.

**Syntax:**
```tesl
fn getVerifiedCache(raw: Dict String String)
  -> Dict String String ::: ForAllValues IsAuthenticated
  requires [] =
  let checked = Dict.filterCheckValues checkIsAuthenticated raw in
  ok checked ::: ForAllValues (IsAuthenticated)

fn getByValidKeys(raw: Dict String User)
  -> Dict String User ::: ForAllKeys IsValidEmail
  requires [] =
  let checked = Dict.filterCheckKeys checkIsValidEmail raw in
  ok checked ::: ForAllKeys (IsValidEmail)
```

**Filter functions:**
- `Dict.filterCheckValues : (V -> V) -> Dict K V -> Dict K V` — applies a `check` function to each value; keeps entries that pass, drops entries where the check fails. The `ForAllValues P` annotation is established at the call site.
- `Dict.filterCheckKeys : (K -> K) -> Dict K K -> Dict K V` — applies a `check` function to each key; keeps entries with valid keys (using the checked key), drops entries where the check fails. The `ForAllKeys P` annotation is established at the call site.

**Rules:**
- `ForAllValues P` is valid only on `Dict K V` return types. Applying it to `List`, `Set`, or any other type is a compile error.
- `ForAllKeys P` is valid only on `Dict K V` return types. Applying it to any other type is a compile error.
- `Dict.filterCheckValues checkFn d` produces a `ForAllValues P` dict where P is the check function's proof predicate.
- `Dict.filterCheckKeys checkFn d` produces a `ForAllKeys P` dict where P is the check function's proof predicate.
- The `ok dict ::: ForAllValues (P)` proof must match the declared return predicate exactly.
- `Dict.filter pred d` does NOT produce a `ForAllValues` dict — the predicate is opaque to the compiler.

**Not dependent types.** `ForAllValues` and `ForAllKeys` follow the same finite structural rules as `ForAll` — they are not term-level quantifiers.


**Implemented — including horizontal scaling via LISTEN/NOTIFY.**

All constructs are fully implemented with the PostgreSQL backend. The chat example (`example/chat/`) demonstrates the complete feature set.

**Queue** (`tesl_jobs` table): `enqueue!` inserts within the current transaction and issues `NOTIFY tesl_queue_<name>` (deferred to commit); the three-thread worker model (fallback poller + LISTEN connection + SKIP LOCKED worker) handles both single-process and multi-process deployments. Failed jobs are retried with exponential or fixed backoff; exhausted jobs become `dead`. Dead jobs are handled by a `deadWorker` folded into the queue's job dead slot (`(Something deadFn)`) — a separate poll loop that runs dead-letter handlers which can publish compensating events, send alerts, or acknowledge the failure.

**Pub/sub** (`tesl_pubsub_outbox` table): `publish` inside `transaction` writes to the outbox atomically and issues `NOTIFY tesl_pubsub` with the row ID (deferred to commit); the runtime automatically starts a LISTEN thread (when SSE endpoints and PostgreSQL are active) that fetches and delivers outbox rows to connected SSE clients, with a 5-second fallback poller for missed notifications.

**In-memory fallback**: when no PostgreSQL context is active (unit tests), all operations use the in-memory store — no database required. Design archived in `future-roadmap/completed/well_designed_reactivity_design.md`.

### 16.10 Previously open areas now resolved
**Implemented.**

The following design areas were open in earlier drafts and are now resolved:

- **Native Cache** — resolved and implemented. See §19.
- **Email Support** — resolved and implemented. See §20.
- **Outgoing HTTP client** — resolved and implemented via `Tesl.HttpClient`. See §21.3.
- **UUID generation and validation** — resolved and implemented via `Tesl.UUID`. See §21.1.
- **JWT signing and verification** — resolved and implemented via `Tesl.JWT`. See §21.2.
- **Step debugger (Phase 0+1)** — resolved and implemented. See §22. Phases 2–4 remain open.

## 17. Worked examples
### 17.1 Valid proof transport
```tesl
module Example exposing [listen, bootstrap]
import Tesl.Prelude exposing [attachFact, Int, Fact]

establish validPort(port: Int) -> Maybe(Fact (ValidPort port)) =
  if 1 <= port && port <= 65535 then
    ValidPort port
  else
    Nothing

fn listen(port: Int ::: ValidPort port) -> Int =
  port

fn bootstrap(port: Int) -> Int =
  let mPortProof = validPort port
  case mPortProof of
    Something portProof -> listen <| port ::: portProof
    Nothing -> ....
```

### 17.2 Invalid cross-subject proof reuse
```tesl
module BadExample exposing [bad]
import Tesl.Prelude exposing [attachFact, Int, Fact]

establish validPort(port: Int) -> Maybe(Fact (ValidPort port)) =
  if 1 <= port && port <= 65535 then
    ValidPort port
  else
    Nothing

fn listen(port: Int ::: ValidPort port) -> Int =
  port

fn bad(x: Int, y: Int) -> Int =
  let mxProof = validPort x
  case mxProof of
    Something mProof -> listen <| y ::: xProof
    Nothing -> ...
```

This is invalid because `xProof` is about the subject of `x`, not the subject of `y`.

### 17.3 `forgetFact` preserves identity but not evidence
```tesl
module ForgetExample exposing [roundTrip]
import Tesl.Prelude exposing [attachFact, forgetFact, Int, Fact]

establish validPort(port: Int) -> Maybe(Fact (ValidPort port)) =
  if 1 <= port && port <= 65535 then
    Something <| ValidPort port
  else
    Nothing

fn listen(port: Int ::: ValidPort port) -> Int =
  port

fn roundTrip(port: Int) -> Int =
  let mValidProof = validPort port
  case mValidProof of
    Something validProof ->
      let checked = port ::: validProof
      let forgotten = forgetFact checked
      listen <| forgotten ::: validPort port
    Nothing -> ...
```

`forgetFact` does not produce a raw `Int`; it produces the same named subject with no attached proof facts.

### 17.4 Illegal shadowing
```tesl
module Shadowing exposing []
import Tesl.Prelude exposing [Int]

fn bad(x: Int) -> Int =
  let x = 1
  x
```

This is invalid because the inner `x` would shadow a proof-relevant outer binder.

## 18. Canonical guidance for future language changes
Any new Tesl feature that touches proofs, names, existentials, or effects should be justified in terms of this core model.

In particular, new syntax should not be accepted unless it can answer all of the following clearly:

- What hidden subject does the value denote?
- What facts are attached, detached, forgotten, or transported?
- Does the feature preserve the no-shadowing rule?
- Can it accidentally retarget a proof to a different subject?
- Can it cause an existential witness to escape?
- Does it fit the effect model, especially the capability rule and the telemetry exception?
- How does the feature elaborate to the existing core machinery?

If a proposed feature cannot be explained cleanly in those terms, it should not yet be part of the language.

## 19. Native Cache
**Implemented.**

A `cache` declaration creates a typed, name-scoped cache backed by a PostgreSQL `UNLOGGED` table. The unlogged storage provides write performance comparable to Redis while retaining the transactional guarantees of PostgreSQL. An in-memory hash is used as a fallback when no PostgreSQL context is active (unit tests, development).

### 19.1 Declaration syntax

A `cache` is a **folded record** assigned with `=`:

```text
<cache-decl> ::= "cache" <identifier> "=" "Cache" "{"
                   "database" ":" <identifier>
                   "defaultTtl" ":" <integer>
                   "valueType" ":" <type-expr>
                 "}"
```

```tesl
cache UserProfileCache = Cache {
  database: MainDB
  defaultTtl: 3600
  valueType: UserProfile
}

cache ProductListCache = Cache {
  database: MainDB
  defaultTtl: 300
  valueType: List Product
}
```

Each `cache` block declares:
- `database` — the `database` declaration that backs this cache. The compiler emits the `tesl_cache` unlogged table into that database schema automatically.
- `defaultTtl` — default time-to-live in seconds. Individual `Cache.set` calls may override this.
- `valueType` — the Tesl type of stored values. The compiler derives the codec automatically; no user annotation is needed.

### 19.2 Capability

Each named cache declares its own capability token: `cacheCap CacheName` (where `CacheName` is the declared identifier). The capability name uses a space, which the compiler normalises to an underscore in the generated Racket identifier (`cache_CacheName`).

```tesl
capability appService implies cacheCap UserProfileCache
```

A handler that reads or writes `UserProfileCache` must declare `cacheCap UserProfileCache` in its `requires` list (directly or transitively via `implies`):

```tesl
handler get getProfile(id: String) -> UserProfile
  requires [dbRead UserProfile, cacheCap UserProfileCache] =
  ...
```

### 19.3 Operations

```text
Cache.get      CacheName key               # -> Maybe ValueType
Cache.set      CacheName key value         # -> Unit (uses defaultTtl)
Cache.set      CacheName key value ttl     # -> Unit (overrides defaultTtl; ttl in seconds)
Cache.delete   CacheName key               # -> Unit
Cache.invalidate CacheName prefix          # -> Unit (deletes all keys with this prefix)
```

`Cache.get` returns `Maybe ValueType` where `ValueType` is the type declared in the `cache` block. The return type is statically known — no runtime cast is needed. If no entry exists for `key`, `Nothing` is returned.

`Cache.invalidate` is a prefix scan: it deletes every entry whose key starts with `prefix`. This is useful for cache tag patterns such as invalidating all `"user_<id>_*"` entries when a user record changes.

### 19.4 Stale-entry handling

If a stored value cannot be deserialized (for example because the application was redeployed with new required fields on `ValueType`), the runtime silently deletes the entry and returns `Nothing`. The cache degrades gracefully across schema evolution. There is no error propagation.

### 19.5 Transactional cache writes

`Cache.set`, `Cache.delete`, and `Cache.invalidate` inside a `transaction` block participate in the surrounding PostgreSQL transaction atomically. This eliminates the dual-write problem that arises when a separate Redis cache is used alongside PostgreSQL: if the transaction rolls back, no cache mutation is committed.

```tesl
handler put updateProfile(userId: String, req: UpdateProfileRequest)
  -> UserProfile
  requires [dbWrite User, cacheCap UserProfileCache] =
  transaction {
    let updated = update ... in User ...
    Cache.delete UserProfileCache ("profile_" ++ userId)
    updated
  }
```

### 19.6 Background sweeper

A sweeper thread runs every 60 seconds and deletes expired rows (`expires_at < NOW()`). No application code is needed to trigger expiry cleanup.

### 19.7 Worked example

```tesl
import Tesl.Maybe exposing [Maybe, Something, Nothing]

cache UserProfileCache = Cache {
  database: MainDB
  defaultTtl: 3600
  valueType: UserProfile
}

handler get getUserProfile(id: String) -> UserProfile
  requires [dbRead UserProfile, cacheCap UserProfileCache] =
  let cached = Cache.get UserProfileCache ("profile_" ++ id)
  case cached of
    Something profile ->
      profile
    Nothing ->
      let profile = selectOne p from UserProfile where p.id == id
      Cache.set UserProfileCache ("profile_" ++ id) profile
      profile
```

---

## 20. Email Support
**Implemented.**

Tesl provides native transactional email via the outbox pattern: `Email.send` writes a row to a `tesl_email_outbox` table inside the current database transaction. A background worker thread polls for pending rows and delivers via SMTP with exponential-backoff retry. If the surrounding transaction rolls back, the email row is never inserted and no email is ever sent.

### 20.1 Declaration syntax

An `email` is a **folded record** assigned with `=`:

```text
<email-decl> ::= "email" <identifier> "=" "Email" "{"
                   "database" ":" <identifier>
                   "smtp" ":" "SmtpConfig" "{"
                     "host"     ":" <expr>
                     "port"     ":" <expr>
                     "username" ":" <expr>
                     "password" ":" <expr>
                     "tls"      ":" ( "true" | "false" )
                   "}"
                 "}"
```

```tesl
email AppEmail = Email {
  database: MainDB
  smtp: SmtpConfig {
    host: env "SMTP_HOST"
    port: 587
    username: env "SMTP_USER"
    password: env "SMTP_PASS"
    tls: true
  }
}
```

Multiple `email` blocks can coexist, each backed by the same or a different database. The `port` carries a port-validity obligation: a literal must be in `1..65535` (or use `envInt "VAR" default`), otherwise it is a compile-time error.

### 20.2 Capability

The capability is `emailCap` — a single shared token, not name-specific. It is **import-gated**, exactly like `time` from `Tesl.Time`: the only way to make it available is `import Tesl.Email exposing [emailCap]`. Declaring an `email` block does **not** grant it. Any function that calls `Email.send` must declare `requires [emailCap]`:

```tesl
import Tesl.Email exposing [Email, SmtpConfig, emailCap]

capability appService implies emailCap

fn sendWelcomeEmail(to: String) -> Unit requires [emailCap] =
  Email.send AppEmail {
    to: to
    subject: "Welcome!"
    body: RichBody "Welcome to the service." "<h1>Welcome!</h1>"
  }
```

### 20.3 Operations

**`Email.send`** — fire-and-queue, non-blocking:

```text
Email.send EmailName {
  to:      String
  subject: String
  body:    EmailBody    # one of TextBody, HtmlBody, or RichBody
}
```

The `body` field is an `EmailBody` ADT value:

- `TextBody "plain text"` — plain text only
- `HtmlBody "<h1>html</h1>"` — HTML only
- `RichBody "plain text" "<h1>…</h1>"` — both (recommended)

The ADT makes a no-body email impossible to construct. `Email.send` inserts a row into `tesl_email_outbox` and returns immediately; it does not open a TCP connection.

**Activation.** The background delivery thread is started by listing the email block in the `App.email` field of the `App` record returned by `main` (§11.13) — there is no `startEmailWorker` statement. Without listing it, rows accumulate in the outbox but are never delivered.

```tesl
main() -> App requires [appService, emailCap] =
  App {
    database: MainDB
    api: MyServer
    port: 8080
    email: [AppEmail]
  }
```

### 20.4 Delivery model

The worker uses two threads:

- **Poller thread** — every 5 seconds, issues `SELECT ... FOR UPDATE SKIP LOCKED` on `tesl_email_outbox` for `pending` rows. On success, marks the row `sent`. On SMTP failure, increments `attempts` and sets `next_attempt_at` with exponential backoff: `5 minutes × 2^attempts`.
- **Cleanup thread** — every hour, deletes `sent` rows older than 24 hours.

After 5 failed attempts a row is marked `dead` and is no longer retried. Dead rows remain in the table for inspection.

### 20.5 Transactional atomicity

`Email.send` inside a `transaction` block is part of the same database transaction. If the transaction rolls back, the row is never inserted and the email is never sent. This prevents sending notifications for events that did not actually persist.

```tesl
handler post registerUser(req: RegistrationRequest) -> User requires [dbWrite User, emailCap] =
  transaction {
    let user = insert User { id: newId, email: req.email }
    Email.send AppEmail {
      to: req.email
      subject: "Welcome!"
      body: TextBody "Your account has been created."
    }
    user
  }
```

If the `insert` or any subsequent step raises an exception, the transaction rolls back and no email row is committed.

---

## 21. Standard Library Extensions

This section documents newer modules added to the Tesl standard library.

### 21.1 `Tesl.UUID`
**Implemented.**

Provides UUID generation and validation. Import:

```tesl
import Tesl.UUID exposing [uuid, UUID.v4, UUID.v7, UUID.validate, IsUuid,
                           uuidV4Codec, uuidV7Codec]
```

**Capability:** `uuid` — required by `UUID.v4` and `UUID.v7`. `UUID.validate` is a pure `check` function and requires no capability.

**Functions:**

| Function | Signature | Notes |
|---|---|---|
| `UUID.v4` | `() -> String` | Random UUID (RFC 4122 v4). Requires `uuid`. |
| `UUID.v7` | `() -> String` | Time-ordered UUID (RFC 9562 v7). Requires `uuid`. Better for database primary keys — monotonically increasing within a millisecond. |
| `UUID.validate` | `check (s: String) -> s: String ::: IsUuid s` | Validates UUID format (8-4-4-4-12 hex). No capability required. |

**Proof predicate:** `IsUuid s` — attached to the result of `UUID.validate` on success.

**JSON codecs:**

- `uuidV4Codec` — encodes/decodes UUID v4 strings. Decoder validates the UUID format.
- `uuidV7Codec` — encodes/decodes UUID v7 strings. Decoder validates the UUID format.

Use in codec blocks:

```tesl
codec CreateRequest {
  fromJson [
    { id <- "id" with_codec uuidV7Codec }
  ]
}
```

**Example:**

```tesl
import Tesl.UUID exposing [uuid, UUID.v4, UUID.v7, UUID.validate, IsUuid]

capability appService implies uuid

fn makeEntityId() -> String requires [uuid] =
  UUID.v7()

check validateId(s: String) -> s: String ::: IsUuid s =
  UUID.validate s

fn requiresValidId(id: String ::: IsUuid id) -> String = id
```

**`UUID.v7` for primary keys.** UUID v7 encodes a 48-bit millisecond timestamp in the most-significant bits, making newly-generated IDs sort later than older ones. This is preferable to v4 for database primary keys: index pages fill sequentially instead of randomly, which substantially reduces B-tree fragmentation at high insert rates.

### 21.2 `Tesl.JWT`
**Implemented.**

Provides JSON Web Token signing, verification, and decoding using HMAC-SHA256 (HS256). Import:

```tesl
import Tesl.JWT    exposing [jwt, JwtToken,
                             JWT.sign, JWT.verify, JWT.decode, Authentic]
import Tesl.Crypto exposing [Secret]          # the signing-key type
import Tesl.Env    exposing [envRead, requireSecret]   # where the key comes from
```

**Capabilities:** `jwt` — required by all three operations. `JWT.sign` additionally requires `time`, because it stamps the token's expiry from the wall clock, and a capability marks an effect.

**Nominal newtypes:**

- `JwtToken` — wraps `String`. Represents a signed JWT (`header.payload.signature`). Not interchangeable with `String` — the type system prevents passing a raw string where a `JwtToken` is expected, and vice versa. It is the non-secret **wire** value, so it keeps a readable `.value`: handing a token to a client is the point of having one.
- The **signing key** is `Secret` (§21.7), `Tesl.Crypto`'s key-material type. `Tesl.JWT` has no key type of its own: there is exactly one key type in the language, and it is the type `Env.requireSecret` returns, so `Env.requireSecret "SESSION_JWT_SECRET"` feeds `JWT.sign`/`JWT.verify` directly and **no `String` ever holds key material**. `Secret` is a **secret newtype**: it has no readable `.value`, because handing the key back as a `String` would defeat the redaction every rendering sink applies to it.

> **Changed 2026-07-30 (breaking).** `Tesl.JWT` used to export a second key newtype of its own, distinct from `Secret` and with no conversion between them. That was not a cosmetic duplication: `Env.requireSecret` returns `Secret`, so a JWT-only key type forced every program to rewrap the key — putting the plaintext key in a `String` on the way through, which is exactly what a secret type exists to prevent. The JWT-only type was **deleted, not aliased** (the same policy as the `exp` unit fix the day before): a program that named it now gets an unknown-export error, and the fix is to take `Secret` from `Tesl.Crypto` or, better, to read the key with `Env.requireSecret`.

**Functions:**

| Function | Signature | Notes |
|---|---|---|
| `JWT.sign` | `(claims: Dict String String) (secret: Secret) -> JwtToken` | Signs a claims dict into a **session** token, stamping `exp` one hour ahead and `kid` in the header. There is no expiry parameter. Requires `jwt` and `time`. |
| `JWT.verify` | `(token: JwtToken) (secret: Secret) -> Dict String String ::: Authentic claims` | Verifies signature and expiry; returns the claims carrying an `Authentic` fact. Fails 401 on a bad signature or an expired token. Check-shaped: bind with `check`. Requires `jwt`. |
| `JWT.decode` | `(token: JwtToken) -> Dict String String` | Decodes the payload **without** verifying the signature, and mints no fact. Use only for non-security-critical inspection. Requires `jwt`. |

Claims are a `Dict String String`, not a record: the payload is a JSON object, `JWT.verify`/`JWT.decode` return it string-keyed, and every consumer reads it with `Dict.lookup`. The result type is deliberately **concrete** rather than a free type variable — a free variable could be typed as anything at the call site, which let a verified payload be laundered into whatever shape the caller claimed.

**Algorithm:** HS256 (HMAC-SHA256). The JOSE header is `{"alg":"HS256","typ":"JWT","kid":"<key id>"}`, in that field order.

#### The `kid` header is derived, not chosen

`JWT.sign` stamps `kid` = `Crypto.keyFingerprint key` (§21.7) in the header, its RFC 7515 §4.1.4 home. There is no parameter: the value is a domain-separated SHA-256 truncated to 16 hex characters, so it is safe to log and is **not** proof of key possession. It answers the operational question a multi-replica or multi-tenant deployment asks from its logs — *which key signed this, and which key is this replica loaded with* — and it makes key rotation expressible later without a flag day. There is no accessor for it; stamping is the part that is expensive to retrofit.

`JWT.verify` never **parses** the header. It recomputes the HMAC over `header.payload` verbatim, so `kid` is a diagnostic and never an authorization input: a token minted before this existed, and a foreign token with any header at all, verify exactly as their signature says they should. Because the header is inside the signed input, editing it — including swapping in a different `kid` — invalidates the signature and is a 401.

> **Added 2026-07-30.** Tokens minted before this date carry no `kid` and keep verifying; there is nothing to migrate.

#### The expiry is fixed at one hour, and is not yours to set

`JWT.sign` sets `exp` itself — **3600 seconds** ahead — and there is no parameter for it, no way to lengthen it, and no way to opt out. This follows the same rule as the rest of the cryptographic surface (§21.7): no mechanism reaches the application author, because every knob is a place where a non-expert makes a wrong call and gets a plausible-looking result. A caller who can pass an expiry can pass ten years.

One hour is the *session-token* number, and a JWT in Tesl is a session token. Renewing a session means signing a new token, which is one call. If you need a credential that outlives a session — an API key, a machine token — a JWT is the wrong tool: mint a `Crypto.randomToken`, store only its `Crypto.fingerprint`, and you can revoke it. An unexpiring bearer token cannot be revoked without rotating the signing key for everybody.

Putting an `exp` in the claims dict yourself is an **error**, not an override. Silently overwriting it would mean the code says one expiry while the token carries another; rejecting it says so at the mint site. (In practice the type also stops you: claims are `Dict String String`, so the only `exp` a Tesl program can write there is a string.)

#### The `exp` claim is epoch SECONDS

`exp` is a *NumericDate* exactly as RFC 7519 §4.1.4 defines it: **seconds** since the Unix epoch. Both `JWT.sign` and `JWT.verify` use that unit, and so does every other JWT library, so a Tesl-minted token interoperates and a foreign token verifies.

Two details worth knowing:

- **An unreadable `exp` counts as expired.** If `exp` is present but not a number, `JWT.verify` rejects the token with 401 rather than skipping the check. Skipping would be fail-open: a token whose expiry cannot be read would be accepted forever. A missing `exp` is a different case and *is* accepted — the RFC makes `exp` optional, and Tesl itself never mints a token without one, so this only admits foreign tokens.
- **Tesl's own clock type is milliseconds.** `PosixMillis`, `nowMillis()` and `addMs` are all milliseconds (§14b.2). The seconds conversion happens once, inside `Tesl.JWT`, rather than introducing a second time unit into `Tesl.Time`.

> **Changed 2026-07-29 (breaking).** `exp` was epoch *milliseconds* until this date — 1000× too large. A foreign verifier read a Tesl token as valid for roughly fifty thousand years (fail-open), and every foreign token looked long expired to Tesl (fail-closed). The unit was hard-fixed on both sides with **no dual-unit tolerance and no migration window**: a heuristic that guesses which unit a number is in is exactly the kind of hedge that outlives its reason. Tokens minted before the change carry a far-future `exp` and keep verifying until they are re-signed; there is nothing to migrate.

#### Demanding that verification happened

`JWT.verify` returns the claims carrying the `Authentic` fact, so a consumer can require verification rather than trust that it was done:

```tesl
fn subjectOf(claims: Dict String String ::: Authentic claims) -> String = ...
```

Only `check JWT.verify` can satisfy that parameter. `JWT.decode` reads the payload without checking the signature and mints nothing, so it cannot reach such a function, and neither can a claims dict the program simply built. This is the difference between "we verify tokens" as a habit and as a compile-time guarantee.

`Authentic` is `Tesl.Crypto`'s fact (§21.7) and is minted in two places: by `Crypto.checkSignature`, about a payload `String`, and by `JWT.verify`, about a claims `Dict String String`. It means the same thing in both — *this value's message authentication tag verified* — and the two cannot launder into each other, because a parameter demanding one subject type cannot be passed the other. It is re-exposed from `Tesl.JWT` so a program that only uses JWTs does not have to import `Tesl.Crypto` to name it.

**Example:**

```tesl
import Tesl.Dict exposing [Dict, Dict.singleton, Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Time exposing [time]
import Tesl.JWT exposing [jwt, JwtToken, JWT.sign, JWT.verify, Authentic]
import Tesl.Crypto exposing [Secret]

capability authService implies jwt, time

fn issueToken(userId: String, secret: Secret) -> JwtToken requires [authService] =
  JWT.sign (Dict.singleton "sub" userId) secret

fn authenticate(token: JwtToken, secret: Secret) -> String requires [authService] =
  let claims = check JWT.verify token secret
  subjectOf claims

# Only verified claims can reach here.
fn subjectOf(claims: Dict String String ::: Authentic claims) -> String =
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something userId -> userId
```

#### Sliding sessions: `JWT.renew`

`JWT.renew : JwtToken -> Secret -> JwtToken`, check-shaped, `requires [jwt, time]`.

The fixed one-hour TTL means an idle session expires, which is the point — but on its own it also logs out a user who is *actively working*, one hour after they signed in. `JWT.renew` slides the window: it verifies the token, then re-issues it with a fresh `exp` and the **original `iat` preserved**, carrying every other claim across untouched. Pair it with `Http.setSessionCookie` (§21.8) inside an `auth` block and an active user is never logged out mid-task, while an idle one still expires an hour after their last request.

```tesl
auth sessionOwner(request: HttpRequest) -> user: String ::: Authenticated user
  requires [sessions] =
  case Http.sessionToken request of
    Nothing -> fail 401 "no session"
    Something token ->
      let claims = check JWT.verify token (requireSecret "SESSION_KEY")
      let fresh  = check JWT.renew  token (requireSecret "SESSION_KEY")
      let _ = Http.setSessionCookie fresh
      ok (subjectOf claims) ::: Authenticated user
```

**Why this is a function rather than two lines of user code.** Re-signing by hand is not merely tedious, it is a trap: `JWT.verify`'s claims contain `exp` and `iat`, `JWT.sign` rejects both (see below), so the author must strip them — and an author who rebuilds the claims dict to do that silently drops any claim they forget. A dropped `role` or tenant id downgrades the session on *every* renewal, on the success path, where no test looks. Carrying every claim across is the only safe shape, so it is the shipped one.

**`iat` is stamped and reserved.** `JWT.sign` now also stamps `iat` (issued-at, epoch seconds, RFC 7519 §4.1.6) and **rejects a caller-supplied `iat`** exactly as it rejects `exp`. That guard is load-bearing rather than tidy: `iat` is what bounds a renewed session's total lifetime, so a caller who could set it could reset it on every renewal and make the session immortal.

**The absolute maximum lifetime is 12 hours, and it is not a knob.** `JWT.renew` refuses once `now - iat` exceeds twelve times the TTL. This is the security core of the feature, not a policy preference: renewal is presented *with* the token, so an attacker holding a captured token can renew it exactly as its owner can. Without the cap a stolen token would be renewable forever — and since Tesl deliberately has no server-side revocation (§21.8), nothing else would stop it. With the cap, the guarantee the no-revocation decision rests on survives: **a captured token is useful for at most twelve hours after the original login, however often it is renewed.** Twelve hours covers any single working day; a credential that must outlive one is not a session, and the answer for it is `Crypto.randomToken` plus a stored `Crypto.fingerprint` (§21.7), which is revocable.

`JWT.renew` returns a 401 in four cases, all through the same constant-time path as `JWT.verify`: the token does not verify; it has already expired (renewal is not resurrection); it carries no **usable** `iat`, so its age cannot be bounded — **fail closed**, which also covers foreign tokens, since `iat` is OPTIONAL per the RFC, and tokens minted before `iat` was stamped, which simply run out at their own `exp` within the hour; or the session has passed its absolute maximum.

**Usable** means an exact non-negative integer dated no more than a minute ahead of this machine's clock, and both halves of that guard the cap rather than the format. A huge float (`1e300`) makes `now - iat` hugely negative, so the cap check passes forever; an `iat` dated in the future widens the cap by exactly its distance ahead. Either survives every renewal, because `iat` is preserved — one malformed claim would buy an effectively immortal session. Tesl's own tokens cannot carry one (`JWT.sign` stamps `iat` from the clock and the mint guard is total), so this matters when a Tesl verifier shares its HS256 secret with a foreign minter, and under nothing worse than clock skew between replicas. The minute of tolerance is for that skew and is not otherwise a knob.

It mints **no** fact. The `Authentic` fact belongs on `JWT.verify`'s claims, where "this was verified" is the useful thing to prove downstream; a renewed token is a fresh credential on its way *out* to the browser.

### 21.3 `Tesl.HttpClient`
**Implemented.**

Provides outgoing HTTP requests. Import:

```tesl
import Tesl.HttpClient exposing [httpClient, HttpResponse,
                                 HttpClient.get, HttpClient.post,
                                 HttpClient.put, HttpClient.delete]
```

**Capability:** `httpClient` — required by all four functions. The identifier is camelCase to match Tesl identifier rules.

**`HttpResponse` record:**

```tesl
record HttpResponse {
  status:  Int
  body:    String
  headers: List (Tuple2 String String)
}
```

**Functions:**

| Function | Signature | Notes |
|---|---|---|
| `HttpClient.get` | `(url: String) (headers: List (Tuple2 String String)) -> HttpResponse` | Issues a GET request. |
| `HttpClient.post` | `(url: String) (headers: List (Tuple2 String String)) (body: String) -> HttpResponse` | Issues a POST request with a string body. |
| `HttpClient.put` | `(url: String) (headers: List (Tuple2 String String)) (body: String) -> HttpResponse` | Issues a PUT request with a string body. |
| `HttpClient.delete` | `(url: String) (headers: List (Tuple2 String String)) -> HttpResponse` | Issues a DELETE request. |

All functions are synchronous and block until the response is received. Both `http://` and `https://` schemes are supported.

**Example:**

```tesl
import Tesl.HttpClient exposing [httpClient, HttpResponse,
                                 HttpClient.get, HttpClient.post]
import Tesl.Tuple exposing [Tuple2]

capability appService implies httpClient

handler get fetchExternalUser(id: String) -> HttpResponse requires [httpClient] =
  let url     = "https://api.example.com/users/" ++ id
  let headers = [Tuple2 "Accept" "application/json",
                 Tuple2 "Authorization" "Bearer token"]
  HttpClient.get url headers
```

**Header lists.** Headers are `List (Tuple2 String String)` — a list of name/value pairs. Pass `[]` for requests with no custom headers.

**Response inspection.** Inspect `response.status` (HTTP status code) and `response.body` (raw response body string). Parse JSON bodies with the standard codec layer or with `Dict`/`String` operations.

**Timeouts.** Every outbound call has a deadline, so a hung upstream can never pin a request thread (and its DB pool slot) or a queue worker indefinitely. A blown deadline raises the same clean `HttpClient` error as any other outbound failure — inside a worker that fails the *job*, so retry / backoff / dead-letter run normally. The deadlines are deployment tuning, configured by environment variable exactly like the response-body cap `TESL_HTTP_MAX_RESPONSE_BYTES`:

| Variable | Default | Bounds |
|---|---|---|
| `TESL_HTTP_CONNECT_TIMEOUT_MS` | `10000` | Reaching the host (TCP + TLS). |
| `TESL_HTTP_TIMEOUT_MS` | `30000` | The whole response: send, status line, headers, body. |
| *(SSE streams)* | `30s` per write | Streaming (SSE) responses are not bounded by a total deadline — a healthy event stream is long-lived by design. Each write (event or heartbeat) has a 30 s deadline so a client that stops reading is disconnected. Not configurable. |

**Testing outbound calls.** `Tesl.ApiTest` provides a test-scoped double so handlers and workers that call out are testable without a network — including the failure branches (upstream 500, malformed body, refused connection, timeout). See §11.14.

### 21.4 `Tesl.Money`
**Implemented.**

Provides exact monetary amounts: an integer count of MINOR units (cents / öre / yen) carrying an intrinsic ISO 4217 currency. Money NEVER touches `Float`, and there is no Money × Money. Import:

```tesl
import Tesl.Money exposing [Money, Currency, ExchangeRate,
                            SameCurrency, RateFor,
                            Usd, Eur, Money.usd, Money.display, Money.scale,
                            Money.add, Money.requireSameCurrency,
                            Money.convert, Money.requireRateFor,
                            Money.convertChecked, ExchangeRate.make]
```

**Capability:** none — `Tesl.Money` is a pure module.

**Types:**

- `Money` — an exact-integer amount in minor units plus its `Currency`. `Money.usd 1050` is $10.50 (1050 cents).
- `Currency` — a FIXED baked ADT with one constructor per active ISO 4217 code (`Usd`, `Eur`, `Jpy`, `Sek`, … — 155 codes, generated into `compiler/lib/currencies.ml`). A typo'd currency is an unknown-constructor compile error and completion lists every code. Each currency carries its minor-digit convention (USD 2, JPY 0, BHD 3), which drives rounding, display, and the digit-shift in conversion.
- `ExchangeRate` — a runtime-supplied rate with provenance: `ExchangeRate.make from to rate asOf`. The rate is exactified decimal-faithfully at construction (0.9155 becomes the exact rational 1831/2000, not the raw binary-float noise), so conversion math is exact end to end.

**Functions:**

| Function | Signature | Notes |
|---|---|---|
| `Money.usd`, `Money.eur`, … | `(minorUnits: Int) -> Money` | One per ISO code. There is deliberately no `Money.of` — `of` is the case-expression keyword and cannot follow a dot. |
| `Money.fromMinorUnits` | `(c: Currency) (minorUnits: Int) -> Money` | For a currency picked at runtime. |
| `Money.minorUnits` | `(m: Money) -> Int` | |
| `Money.currency` | `(m: Money) -> Currency` | |
| `Money.display` | `(m: Money) -> String` | Canonical, culture-INVARIANT rendering: `"$10.50"`, `"¥1000"`, `"10.50 SEK"` — digits and a single `.` decimal, no thousand separators, never a `,` decimal. Locale rendering (sv-SE `100 000,23 kr`) is a client-side presentation concern (`Intl.NumberFormat` over the wire's `{minorUnits, currency}`); the server bakes no locale tables. |
| `Money.scale` | `(m: Money) (k: Int) -> Money` | Exact integer scaling (quantity × unit price). |
| `Money.scaleBy` | `(m: Money) (factor: Float) -> Money` | FRACTIONAL scaling (interest, VAT, discount): the factor is exactified decimal-faithfully (`1.055` → `211/200`), multiplied exact, and rounded HALF-EVEN back to minor units. Named — not `*` — because it rounds. `Money.scaleBy m 1.055` applies 5.5% interest. |
| `Money.negate`, `Money.abs` | `(m: Money) -> Money` | |
| `Money.isZero`, `Money.isNegative` | `(m: Money) -> Bool` | |
| `Money.add`, `Money.subtract` | `(a: Money) (b: Money ::: SameCurrency a b) -> Money` | Proof-gated: the second argument must carry `SameCurrency a b`. |
| `Money.compare` | `(a: Money) (b: Money ::: SameCurrency a b) -> Int` | −1 / 0 / 1 on minor units. |
| `Money.requireSameCurrency` | `check (a: Money) (b: Money) -> b ::: SameCurrency a b` | Mints the same-currency proof (or fails 400). |
| `Money.requireNonNegative` | `check (m: Money) -> m ::: NonNegativeMoney m` | |
| `Money.convert` | `(r: ExchangeRate) (m: Money) -> Result Money String` | `Err` when the rate's FROM currency does not match the amount. |
| `Money.requireRateFor` | `check (r: ExchangeRate) (m: Money) -> m ::: RateFor r m` | Mints the rate-matches-amount proof. |
| `Money.convertChecked` | `(r: ExchangeRate) (m: Money ::: RateFor r m) -> Money` | Total behind the proof — no `Result` to unwrap. |
| `Currency.code` | `(c: Currency) -> String` | ISO alpha code, `"USD"`. |
| `Currency.minorDigits` | `(c: Currency) -> Int` | |
| `Currency.fromCode` | `(s: String) -> Maybe Currency` | Runtime code resolution. |
| `ExchangeRate.make` | `(from: Currency) (to: Currency) (rate: Float) (asOf: PosixMillis) -> ExchangeRate` | Rate data always carries provenance. |
| `ExchangeRate.fromCurrency` / `.toCurrency` / `.rate` / `.asOf` | accessors | |

**Raw operators are compile errors with hints.** `price + tax` reports ``operator `+` is not defined for `Money`; use `Money.add a b` (requires a `SameCurrency a b` proof — mint it with `Money.requireSameCurrency a b`)``. `*`, `/`, `%` report that money times money is meaningless and point at `Money.scale m k`; `<`/`<=`/`>`/`>=` report that ordering across currencies is undefined and point at `Money.compare`. Unary `-` points at `Money.negate`.

**Proof predicates:** `SameCurrency a b` (two-subject, the `Dict.requireKey`/`HasKey` shape), `NonNegativeMoney m`, `RateFor r m`. A runtime currency mismatch inside `Money.add`/`Money.convertChecked` means the proof layer was bypassed and fails loudly — defense in depth, not the safety story.

**JSON codecs / wire shape:** `moneyCodec` (exported by `Tesl.Json`) encodes/decodes the unconditional wire shape:

```json
{"minorUnits": 1000, "currency": "USD"}
```

At the AGENT boundary only, a Money value additionally carries `"display"` (`"$10.00"`) so the model never re-derives major units from minor units; HTTP responses keep the two-field shape. Agent tool-parameter schemas for `Money` parameters carry a description spelling out the minor-units convention (`$10.00 USD is {"minorUnits":1000,"currency":"USD"}` — never major units, never a float).

**Database storage.** A `price: Money` entity field maps to TWO columns: `price_minor BIGINT` + `price_currency TEXT`. Equality (`==`) works in `where` clauses; ordered comparisons (`<`, `>=`, …) and `ORDER BY` on a Money column are rejected (ordering across stored currencies is undefined). `selectSum` over a Money column returns `Money` and only sums a single currency: mixed currencies raise (`filter by currency first`), and an empty row set raises (a zero total has no currency to carry). `Maybe Money` columns are not supported (NULL semantics would span both columns — fail-closed).

**Example:**

```tesl
import Tesl.Money exposing [Money, ExchangeRate, SameCurrency, RateFor,
                            Usd, Eur, Money.usd, Money.display,
                            Money.add, Money.requireSameCurrency,
                            Money.convert, ExchangeRate.make]
import Tesl.Result exposing [Result(..)]
import Tesl.Time exposing [PosixMillis, Time.secondsToPosix]

fn addSameCurrency(a: Money, b: Money) -> Money =
  let proven = check Money.requireSameCurrency a b
  Money.add a proven

fn convertToDisplay(rate: ExchangeRate, amount: Money) -> String =
  case Money.convert rate amount of
    Ok converted -> Money.display converted
    Err message -> message

test "convert applies a runtime rate with banker's rounding" {
  # 1000 minor USD × 0.9155 = 915.5 → round-half-even → 916 minor EUR
  let rate = ExchangeRate.make Usd Eur 0.9155 (Time.secondsToPosix 1751900000)
  expect convertToDisplay rate (Money.usd 1000) == "€9.16"
}
```

**Why integer minor units, and why isn't the currency in the static type?** Binary floats cannot represent 0.10, so float money drifts by construction; exact-integer minor units make every amount, sum, and scale exact, with a single round-half-even (banker's rounding) only at currency conversion. The currency is an intrinsic runtime qualifier rather than a type parameter — exactly the `PosixMillis` design, where the timezone is data, not 489 timestamp types. A `Money<Usd>`-style type family would multiply every signature, entity, and codec by 155 currencies while still needing runtime handling for currencies chosen at runtime. Instead the same-currency obligation is proof-layer: `Money.add`/`Money.subtract`/`Money.compare` statically require `SameCurrency a b`, which only `check Money.requireSameCurrency a b` can mint — so öre never silently add to yen, and the failure path is the developer's explicit 400, not a corrupted total.

**Why are exchange rates runtime data?** A rate baked into source is stale the moment it is written, and an ambient "current rate" service invisibly couples money math to hidden state. `ExchangeRate.make` forces the rate to arrive as an explicit value with provenance (`asOf`), so every conversion names the rate it used — auditable, testable, and never a compiler default.

**Money rates — money PER quantity (`MoneyPerDuration`, `MoneyPerMass`, …).** Hourly consultant cost and price-per-kilogram compose Money with the §21.5 dimension algebra: the currency stays inside the value, the DENOMINATOR dimension joins the type.

| Function / form | Signature | Notes |
|---|---|---|
| `money / quantity` | e.g. `Money -> Duration -> MoneyPerDuration` | Builds a rate by division (the divisor needs the usual non-zero proof, `Units.requireNonZero`). |
| `MoneyRate.perHour`, `MoneyRate.perDay` | `(m: Money) -> MoneyPerDuration` | The Money IS the per-hour / per-day price. |
| `MoneyRate.perKilogram` | `(m: Money) -> MoneyPerMass` | |
| `MoneyRate.perLiter` | `(m: Money) -> MoneyPerVolume` | |
| `MoneyRate.perSquareMeter` | `(m: Money) -> MoneyPerArea` | |
| `rate * quantity` | e.g. `MoneyPerDuration -> Duration -> Money` | Dimensions cancel; the currency rides through; ONE round-half-even at materialization. Wrong denominator (`rate * Mass` on an hourly rate) is a compile error naming both dimensions. |
| `rate * factor` | `MoneyPerDuration -> Float -> MoneyPerDuration` | Exact decimal-faithful rescale (10% surcharge: `rate * 1.1`); no rounding until Money materializes. |
| `MoneyRate.currency` | `rate -> Currency` | Denominator-polymorphic (typed per application site, like `Units.*`). |
| `MoneyRate.display` | `rate -> String` | `"950.00 SEK/h"`, `"$2.50/kg"` — canonical, culture-invariant, denominator label from the constructor. |

Inside, a rate is an EXACT rational (minor units per SI-canonical denominator unit), so `MoneyRate.perHour (Money.sek 95000) * Duration.minutes 30.0` is exactly `475.00 SEK`. `+`/`-`/`/` on rates are compile errors — materialize `Money` first. The alias type names are import-gated with `Tesl.Money`.

**Rates persist and serialize (GitHub #38).** At a BOUNDARY — the JSON wire or a database column — a rate is quantized to INTEGER minor units per one `per`-labelled unit, half-even, exactly the Money stance (exact integers at rest, exact rationals only mid-computation):

- **Wire**: `{"minorUnits": 95000, "currency": "SEK", "per": "h"}` (agent boundary adds `"display"`). Legal `per` labels: `s`, `h`, `day`, `kg`, `m`, `m^2`, `m^3`, `L`. Decode verifies the label's dimension against the declared alias — `per: "kg"` into a `MoneyPerDuration` field is a decode error, and unknown labels/currencies fail closed.
- **Database**: an entity field `hourly: MoneyPerDuration` maps to THREE columns — `hourly_minor BIGINT NOT NULL`, `hourly_currency TEXT NOT NULL`, `hourly_per TEXT NOT NULL`. Writes quantize (both backends store the identical quantized value); reads reconstruct the exact rational and verify the dimension. `==`/`!=` compare all three columns — equality is REPRESENTATIONAL (950 SEK stored per `"h"` is a different row value than the same price stored per `"day"`). Ordered comparison, aggregates, and `groupBy` on rate columns are rejected — materialize `Money` and aggregate that.
- **Division-built rates** (`total / worked`) carry the denominator's DEFAULT label — per `h` for Duration, per `kg`/`m`/`m^2`/`m^3` otherwise — chosen for sane quantization magnitude (a 950 SEK/h rate stored per second would quantize to 0).
- **Elm/TS clients** get one shared `MoneyRate` alias (`{ minorUnits, currency, per }`) with tolerant decoders, like `Money`.

```tesl
fn invoice(rate: MoneyPerDuration, worked: Duration) -> Money =
  rate * worked          # 950 SEK/h × 1.5 h = 1425.00 SEK, half-even once
```

**Deliberately NOT money rates.** *Money per item* (e-shop unit price × count) is `Money.scale price qty` — an exact-integer count with zero rounding beats a rate (and a dimensionless denominator would make "×3 items" and "×3.0 rescale" indistinguishable in the algebra — a fail-open we refuse). *Money per nominal type* (`MoneyPer<Product>`) does not fit dimensional analysis — nominal types have no exponents and nothing cancels; use `Money.scale` with newtype-keyed prices, and revisit as a phantom-tag feature only if per-entity price mix-ups prove to be a real bug class.

### 21.5 `Tesl.Units`
**Implemented.**

Provides compile-time SI dimensional analysis over `Float` quantities. Dimensions exist ONLY in the type layer and are fully ERASED at runtime — a `Speed` is a plain Racket float in the compiled program, zero cost. Import:

```tesl
import Tesl.Units exposing [Length, Duration, Speed, Area,
                            Length.meters, Length.kilometers, Duration.seconds,
                            Speed.inKilometersPerHour, Units.sqrt,
                            Units.requireNonZero]
```

**Capability:** none — `Tesl.Units` is a pure module.

**Quantity types.** A dimension is a vector of signed exponents over the 7 SI base dimensions (m, kg, s, A, K, mol, cd). The importable alias type names are:

`Length`, `Mass`, `Duration`, `ElectricCurrent`, `Temperature`, `AmountOfSubstance`, `LuminousIntensity`, `Speed` (m/s), `Acceleration` (m/s²), `Area` (m²), `Volume` (m³), `Force` (N), `Energy` (J), `Power` (W), `Pressure` (Pa), `Frequency` (1/s)

These are structural over the dimension, not nominal: `Speed` in an annotation and the result of `Length.meters 1.0 / Duration.seconds 1.0` are the SAME type. A computed dimension with no alias still works and prints in unit form (`m/s^3`).

**Constructors and accessors.** Every unit constructor is `Float -> Quantity` and converts INTO the SI canonical magnitude; every accessor is `Quantity -> Float` and converts back OUT. Conversion factors live only in the runtime (`tesl/units.rkt`); the types are factor-independent.

| Module | Constructors | Accessors |
|---|---|---|
| `Length` | `meters`, `kilometers`, `centimeters`, `millimeters`, `miles`, `feet`, `inches`, `yards`, `nauticalMiles` | `inMeters`, `inKilometers`, … `inNauticalMiles` |
| `Mass` | `kilograms`, `grams`, `milligrams`, `tonnes`, `pounds`, `ounces` | `inKilograms`, … |
| `Duration` | `seconds`, `milliseconds`, `minutes`, `hours`, `days` | `inSeconds`, … |
| `Speed` | `metersPerSecond`, `kilometersPerHour`, `milesPerHour`, `knots` | `inMetersPerSecond`, … |
| `Acceleration` | `metersPerSecondSquared` | `inMetersPerSecondSquared` |
| `Area` | `squareMeters`, `squareKilometers`, `hectares`, `squareFeet`, `acres` | `inSquareMeters`, … |
| `Volume` | `cubicMeters`, `liters`, `milliliters`, `gallons` | `inCubicMeters`, … |
| `Temperature` | `kelvin`, `celsius`, `fahrenheit` (affine — see caveat) | `inKelvin`, `inCelsius`, `inFahrenheit` |
| `Force` | `newtons` | `inNewtons` |
| `Energy` | `joules`, `kilojoules`, `kilowattHours`, `calories` | `inJoules`, … |
| `Power` | `watts`, `kilowatts`, `horsepower` | `inWatts`, … |
| `Frequency` | `hertz`, `kilohertz` | `inHertz`, `inKilohertz` |
| `Pressure` | `pascals`, `kilopascals`, `bar` | `inPascals`, … |

**Operator dimension algebra.** The ordinary arithmetic operators compute dimensions per expression:

- `*` ADDS exponent vectors: `Length * Length : Area`; `Acceleration * Duration : Speed` — m/s² × 4 s is m/s.
- `/` SUBTRACTS them: `Length / Duration : Speed`; `1.0 / Duration : Frequency` (a scalar numerator inverts the dimension).
- `+` / `-` and comparisons require the SAME dimension; a mismatch is a compile error naming both dimensions: ``cannot add quantities of different dimension: `Length` and `Mass` (dimensions must match exactly; convert first)``.
- A dimensionless result collapses to plain `Float` (`Length / Length : Float`).
- A scalar operand must be a `Float` literal: `2.0 * len` is fine; `2 * len` reports ``a quantity is scaled by a `Float`, not an `Int` — write a Float literal (`2.0`, not `2`)``.
- `%` is not defined for quantities.
- Division follows the same non-zero rule as every Tesl `/`: a variable divisor must carry a non-zero proof. `Units.requireNonZero q` mints `FloatNonZero q` — the SAME predicate that guards `Float` division, because quantities ARE floats at runtime. It is a check function, so it is bound with `check`, which both propagates the zero-divisor rejection and preserves the dimension (the checked binding is still a `Duration`):

```tesl
fn pace(d: Length, t: Duration) -> Speed =
  let safe = check Units.requireNonZero t
  d / safe
```

**Polymorphic dimension operations.** `Units.mul`, `Units.div`, `Units.square`, `Units.sqrt`, `Units.abs`, `Units.negate`, `Units.min`, `Units.max`, `Units.sum`, `Units.requireNonZero`. A dimension variable does not fit HM unification, so these are dimension-COMPUTED at each application site: `Units.sqrt` halves the exponents and is only defined when every exponent is even (`Units.sqrt area : Length`; the square root of a bare `Length` is not a physical quantity and is a compile error); `Units.min`/`Units.max` require both arguments in the same dimension; `Units.sum` takes a `List` of one known dimension.

**Duration bridge (`Tesl.Time` interop).** Timestamps stay `PosixMillis` with exact-Int ms deltas (`addMs`/`diffMs` remain canonical — the same exactness stance as Money's minor units). Alongside them, typed spans: `Time.add : PosixMillis -> Duration -> PosixMillis`, `Time.subtract`, and `Time.diff : PosixMillis -> PosixMillis -> Duration` (exported by `Tesl.Time`), plus `Duration.toMillis : Duration -> Int` (rounds half-even) and `Duration.fromMillis : Int -> Duration` here. `Time.add ts (Duration.hours 2.0)` reads as intended and is unambiguous to a model in a way `addMs ts 7200000` is not.

**Import gating.** The alias type names (`Length`, `Speed`, …) are common words, so they resolve to quantity types ONLY in a module that imports them from `Tesl.Units`. A module that does not import them keeps its own `type Speed = Slow | Fast` working unchanged. Declaring such a type while ALSO importing the colliding alias is a compile error (``type `Speed` collides with the `Speed` quantity type exported by Tesl.Units (imported by this module); rename the type``) — never a silent hijack. Internally each dimension is a canonical type name built from characters that cannot appear in a Tesl identifier, so user types can never collide with (or forge) a quantity type.

**Temperature is affine.** `Temperature.celsius` and `Temperature.fahrenheit` apply an OFFSET (°C → K adds 273.15), so the stored quantity is absolute kelvin. Caveat: adding two absolute temperatures type-checks (same dimension) but is rarely physically meaningful — dimensional analysis catches unit mistakes, not every physics mistake.

**Agent boundary.** Agent tool-parameter schemas for quantity parameters carry the unit in the description (`"a Speed expressed in SI units: m/s — ALWAYS supply the value in m/s, never in km/h, mph, feet, pounds or any other non-SI unit; convert first"`) — the km/h-vs-m/s guessing class is exactly what this kills.

**Example:**

```tesl
import Tesl.Units exposing [Length, Duration, Speed, Acceleration, Area,
                            Length.meters, Duration.seconds,
                            Acceleration.metersPerSecondSquared,
                            Speed.inMetersPerSecond]

# m/s² × s = m/s — the compiler works the dimension out per expression
fn finalSpeed(a: Acceleration, t: Duration) -> Speed =
  a * t

fn rectangleArea(w: Length, h: Length) -> Area =
  w * h

test "dimension algebra" {
  let accel = Acceleration.metersPerSecondSquared 2.5
  expect Speed.inMetersPerSecond (finalSpeed accel (Duration.seconds 4.0)) == 10.0
}
```

**Why compile-time dimensions with runtime erasure?** The alternative designs both lose: runtime unit objects tax every arithmetic operation and turn unit bugs into production exceptions; no units at all is the Mars Climate Orbiter. Encoding each dimension as a distinct canonical type makes dimension checking ordinary type equality — `m/s/s × 4s : m/s` falls out of exponent arithmetic in the checker, wrong-unit code does not compile, and the compiled program pays nothing because every quantity erases to a plain float. Conversions happen exactly twice: at construction (into SI canonical) and at an accessor (out of it), so there is no unit ambiguity in between — and the import gating keeps this entire vocabulary out of modules that never asked for it.

---

### 21.6 `Tesl.Regex`
**Implemented.**

Regular expressions over `String`. Six functions, pure — no capability:

```tesl
import Tesl.Regex exposing [Regex.matches, Regex.find, Regex.findAll,
                            Regex.captures, Regex.replace, Regex.split]
```

| Function | Signature | Meaning |
|---|---|---|
| `Regex.matches` | `(pattern: String, input: String) -> Bool` | the pattern matches somewhere in `input` (anchor with `^`/`$` for a whole-string match) |
| `Regex.find` | `(pattern: String, input: String) -> Maybe String` | the text of the first match |
| `Regex.findAll` | `(pattern: String, input: String) -> List String` | the text of every non-overlapping match, left to right |
| `Regex.captures` | `(pattern: String, input: String) -> Maybe (List String)` | the capture groups of the first match, in source order, whole match EXCLUDED; `Something []` when the pattern has no groups |
| `Regex.replace` | `(pattern: String, input: String, replacement: String) -> String` | replaces EVERY match; the replacement is inserted literally (`$1`, `\1` and `&` are ordinary characters — never group references) |
| `Regex.split` | `(pattern: String, input: String) -> List String` | splits on every match, like `String.split` with a pattern separator |

**The pattern is argument 1 of every function and MUST be a string literal
written at the call site.** There is no dynamic-pattern form. That is what makes
the following four compile-time rules enforceable, and it closes the
resource-exhaustion hole a `Regex.matches userPattern input` would open.
To reuse a pattern, name the *predicate* — wrap the call in a `fn` or a `check`.

**The accepted subset of `pregexp`.** Literal characters, `.`, character classes
`[a-z]` / `[^0-9]` with ranges, the class escapes `\d \D \w \W \s \S`, the
word boundaries `\b \B`, the anchors `^ $`, capturing `( … )` and non-capturing
`(?: … )` groups, alternation `|`, and the quantifiers `? * + {n} {n,} {n,m}`.
A backslash may also precede any of `. * + ? ( ) [ ] { } | ^ $ - /`.

Deliberately outside the subset: backreferences (`\1`), lookaround
(`(?=`, `(?!`, `(?<=`, `(?<!`), inline flags (`(?i:`), lazy/possessive
quantifiers (`*?`, `*+`), POSIX bracket classes (`[:alpha:]`), and the escapes
`\n \t \r \\` (a Tesl string literal already processes those — see §8.5 — so
spelling them inside a pattern would be ambiguous). A regex backslash is written
DOUBLED in Tesl source: `"\\d+"` is the pattern `\d+`.

**Compile-time rules.** Each has its own stable diagnostic code:

| Code | Rule |
|---|---|
| `VREGEX001` | the pattern must parse in the subset above |
| `VREGEX002` | the pattern must be a string literal at the call site |
| `VREGEX003` | the pattern must not be able to backtrack catastrophically |
| `VREGEX004` | every capture group must participate in every successful match |

`VREGEX003` rejects a group repeated two or more times when its body can match
the empty string, contains a top-level `|`, or contains its own quantifier —
*unless* the body begins with a fixed single-character atom whose character set
is disjoint from every other character atom in the body. That exception is a
sufficient condition for a unique decomposition of the input, and it keeps the
everyday separator idiom legal: `(?:-[a-z0-9]+)*` and `(?:\.[a-z]+)+` are
accepted, while `(a+)+`, `(?:aa+)+`, `(?:a|a)*` and `(?:[a-z]+\.)+` are not.
Two neighbouring unbounded repetitions over overlapping character sets
(`[0-9]+[0-9]*`) are rejected for the same reason.

`VREGEX004` rejects a capture group under a quantifier and a capture group
inside an alternation branch — the only two shapes where a group can fail to
capture on a successful match. Because they cannot occur, `Regex.captures`
returns `Maybe (List String)` rather than `Maybe (List (Maybe String))`: the
outer `Maybe` is "did the pattern match", and the list length is exactly the
number of groups written in the pattern.

**Runtime bounds.** The compile-time rules eliminate exponential backtracking;
the remaining (polynomial) ambiguity, and any pattern that reached the runtime
without passing them, is bounded operationally. Every match runs in its own
Racket thread under a wall-clock deadline — `TESL_REGEX_TIMEOUT_MS`, default
1000 — over an input bounded by `TESL_REGEX_MAX_INPUT_BYTES`, default 1 MiB.
Exceeding either raises a clean `Regex` error rather than pinning the thread.
Compiled patterns are memoised, so the steady-state cost of a call is a hash
lookup.

```tesl
fact ValidSlug (s: String)

check requireSlug(raw: String) -> raw: String ::: ValidSlug raw =
  if Regex.matches "^[a-z0-9]+(?:-[a-z0-9]+)*$" raw then
    ok raw ::: ValidSlug raw
  else
    fail 400 "a slug is lowercase words joined by single hyphens"
```

See `example/learn/lesson75-regex-validation.tesl`.

### 21.7 `Tesl.Crypto`
**Implemented.**

Password storage, message authentication, content digests, and secrets. Import:

```tesl
import Tesl.Crypto exposing [
  PasswordHash, Signature, Secret,
  HashFor, PasswordVerified, Authentic,
  Crypto.hashPassword, Crypto.checkPassword, Crypto.needsRehash,
  Crypto.signWith, Crypto.checkSignature,
  Crypto.fingerprint, Crypto.keyFingerprint, Crypto.randomToken,
]
```

**Every primitive is libsodium, unmodified.** Tesl's contribution is the type system around the primitives, never the primitives. The implementation (`tesl/crypto.rkt`) marshals values across the FFI and chooses libsodium's own recommended parameters; it implements no cryptography. `tesl doc Crypto.<name>` states the primitive underneath every function — friendly names hide the *choice*, never the *fact*.

**No mechanism reaches the application author.** No algorithm choice, no work factor, no nonce, no salt, no encoding, no length. Every knob is a place where a non-expert makes a wrong call and gets a plausible-looking result. Experts get transparency through documentation and the algorithm tag inside every stored artifact — not through parameters.

**Capabilities.** A capability marks an *effect*; sensitivity is carried by the types and the facts, which track the value rather than the function. So only the two operations that draw randomness are gated, and they reuse the existing `random`:

| Gated by `random` | Ungated (pure) |
|---|---|
| `Crypto.hashPassword` (draws a salt), `Crypto.randomToken` | everything else — `checkPassword`, `signWith`, `checkSignature`, `needsRehash`, `fingerprint`, `keyFingerprint` |

`Tesl.JWT`'s `jwt` capability is inconsistent with that rule — `JWT.sign` is a pure HMAC and is gated — and is retained as known debt rather than propagated: removing a capability would break every `requires [jwt]` in the wild.

**Types.**

| Type | Secret? | `==` | `Ord` | `.value` | Constructor |
|---|---|---|---|---|---|
| `PasswordHash` | yes | **no** | no | **no** | **none** |
| `Secret` | yes | yes, **constant-time** | no | **no** | `Secret "…"` |
| `Signature` | no | **no** | no | **no** | via `Crypto.signatureFromHex` / `Crypto.signatureFromBase64` |

- `PasswordHash` has **no caller-callable constructor**, so `PasswordHash "hunter2"` is a `T001` unknown-constructor error: a plaintext cannot be blessed as a hash.
- `PasswordHash` and `Signature` have **no `Eq` at all** — not for timing, but because a hand comparison would route around `Crypto.checkPassword` / `Crypto.checkSignature` and quietly defeat the design. Their only legitimate comparison *is* a verification.
- `Secret` keeps `==`, lowered to libsodium's `sodium_memcmp`, so the familiar operator stays and the timing leak does not. `Ord` is denied on all three: an ordered comparison against a secret is a binary-search oracle for its value.
- `Signature` is **not** secret. A message authentication tag is public data — publishing it is the entire point — and redacting it would make webhook debugging impossible.
- **Storage is not rendering.** A `PasswordHash` column stores and reads its real value, exactly like any other newtype column; otherwise it could never be verified against. Redaction applies where a value is *displayed*.

**Facts.**

| Fact | Minted by | Meaning |
|---|---|---|
| `HashFor plaintext` | `Crypto.hashPassword` | This hash is the hash of *that* plaintext |
| `PasswordVerified stored` | `Crypto.checkPassword` | A submitted password was checked against this stored hash |
| `Authentic payload` | `Crypto.checkSignature` | This payload's tag verified |

All three are minted **only** by those functions. A hand-written `fn f(p) -> PasswordHash ::: HashFor p = …` is rejected: they are absent from `proof_discharge.ml`'s `stdlib_auto_preds`, so there is no fail-open path that grants them by name.

**Functions.**

| Function | Signature | Notes |
|---|---|---|
| `Crypto.hashPassword` | `(plaintext: String) -> PasswordHash ::: HashFor plaintext` | Argon2id, PHC string format, libsodium's INTERACTIVE parameters read at call time. Requires `random`. Rejects input over **1024 bytes** with a 400 — libsodium imposes no bound of its own, so an unbounded memory-hard hash on an unauthenticated endpoint is a denial-of-service amplifier. Rejection, never truncation. |
| `Crypto.checkPassword` | `(stored: Maybe PasswordHash) (candidate: String) -> ok stored ::: PasswordVerified stored \| fail 401` | Constant-time. Takes `Maybe` **deliberately**: with `Nothing` it hashes against a dummy, so a missing user and a wrong password cost the same and return the same message. Without that, a login endpoint enumerates registered addresses. |
| `Crypto.needsRehash` | `(stored: PasswordHash) -> Bool` | True when the stored hash was minted with weaker parameters than the current ones, or in an unparseable format. Tesl does **not** perform the rehash: a crypto function writing to the database would be a hidden effect. |
| `Crypto.signWith` | `(key: Secret) (payload: String) -> Signature` | HMAC-SHA256. Expert alias `Crypto.hmacSha256`. Deliberately not named `sign`: this is *symmetric* authentication, and the bare name is reserved for asymmetric signing so that "I signed it, so anyone can verify it" cannot be inferred. |
| `Crypto.checkSignature` | `(key: Secret) (sig: Signature) (payload: String) -> ok payload ::: Authentic payload \| fail 401` | Constant-time. This is why there is no `constantTimeEquals` on the surface — the compare lives where it cannot be got wrong. |
| `Crypto.signatureHex` | `(sig: Signature) -> String` | Transport out, for a header or body. |
| `Crypto.signatureFromHex` | `(hex: String) -> Signature` | Transport in — a webhook's signature header (Stripe, GitHub). Malformed input fails the verification cleanly; it never raises. |
| `Crypto.signatureBase64` | `(sig: Signature) -> String` | Transport out, base64 — the encoding Standard Webhooks uses (`webhook-signature: v1,<base64>`). |
| `Crypto.signatureFromBase64` | `(b64: String) -> Signature` | Transport in — a Standard Webhooks `webhook-signature` header. Malformed input fails the verification cleanly; it never raises. |
| `Crypto.fingerprint` | `(content: String) -> String` | SHA-256, hex. For ETags, cache keys, dedup, idempotency keys. Expert alias `Crypto.sha256`; `Crypto.sha512` also exists. **Not for passwords.** |
| `Crypto.keyFingerprint` | `(key: Secret) -> String` | "Did I load the right key?" — a domain-separated SHA-256 truncated to 16 hex characters, safe to log. Not proof of key possession. |
| `Crypto.randomToken` | `() -> String` | 256 bits from the OS CSPRNG, base64url (43 URL-safe characters). No length parameter, on purpose. Requires `random`. |

**Argument order.** Configuration first, subject last, so `payload |> Crypto.signWith key` reads correctly (`x |> f` is `f x`, so the piped value is the last argument) and `Crypto.signWith key` partially applies into a reusable signer.

**Upgrades and rolling deploys.** Cost parameters are read from libsodium at call time, never hardcoded, so a libsodium upgrade silently strengthens every *new* hash while `needsRehash` starts answering `True` for old ones — application code that was correct stays correct. Stored data is never rewritten: a hash is one-way, so the plaintext exists for exactly one moment, the next successful login, and upgrade-on-login is therefore not the weaker option but the only mechanism. Verification accepts every scheme ever shipped because the algorithm and its parameters live inside each stored PHC string, so old and new instances read the same rows during a rolling deploy — no flag day, no dual-write window, and **never** a bulk rewrite at startup.

**Foreign-hash migration, and its limit.** libsodium verifies foreign **Argon2i / Argon2id** PHC strings, including ones with parameters libsodium would not itself choose. It **cannot** verify bcrypt (`$2a$`/`$2b$`) or scrypt (`$7$`), and has no PBKDF2 at all. Both limits are pinned by tests so behaviour and documentation cannot drift apart.

**What `PasswordVerified` does and does not deliver.** It proves a password was checked against a stored hash. Reaching `Authenticated` still requires an `establish`. What the fact buys is that the unverified step becomes *small, explicit and reviewable* — one `establish` beside a real verification — instead of an `auth` body that never verified anything. That is a genuine improvement; it is not a proof of correct authentication.

**Not provided, deliberately:** general `encrypt`/`decrypt`, raw AES/ChaCha, cipher modes, MD5, SHA-1, any parameter knob, and key custody (envelope encryption, KMS integration, rotation infrastructure — that is platform infrastructure, not language surface; Tesl's job is to accept a key as a value).

**Dependency.** `Tesl.Crypto` is implemented on Go's standard library (`crypto/*`) plus `golang.org/x/crypto/argon2` for password hashing; the emitted module pins and checksums that one dependency in its `go.mod`/`go.sum`. There is no native library and no `TESL_LIBSODIUM`.

See `example/learn/lesson64-password-storage.tesl` and `runtime/go/teslrt/password_test.go`.

### 21.8 `Tesl.Http` — the session cookie
**Implemented.**

`Tesl.JWT` (§21.2) is the session *credential*. `Tesl.Http` is its *transport*: one cookie, with no options. Import:

```tesl
import Tesl.Http exposing [HttpRequest, cookieCap,
                           Http.setSessionCookie, Http.clearSessionCookie,
                           Http.sessionToken]
```

| Function | Type | Capability |
|---|---|---|
| `Http.setSessionCookie` | `JwtToken -> Unit` | `cookieCap` |
| `Http.clearSessionCookie` | `() -> Unit` (written `Http.clearSessionCookie()`) | `cookieCap` |
| `Http.sessionToken` | `HttpRequest -> Maybe JwtToken` | none |

These are ordinary imported functions, not syntax and not ambient forms — the precedent is `Email.send`. The *names* arrive only through `import Tesl.Http exposing [...]`, and the *right to write* arrives only through `cookieCap` in a `requires` list. A handler's return type is unaffected, so setting a session cookie leaves every generated TypeScript and Elm client byte-identical.

**Capability.** `cookieCap` is provided by `Tesl.Http` and is import-gated exactly like `emailCap`: declaring an `api` or a `server` does not grant it. Reading `request.cookies`, and calling `Http.sessionToken`, need **no** capability — reading request data is not an effect.

**Every attribute is fixed, and so is the name.** `Http.setSessionCookie` emits exactly:

```
Set-Cookie: __Host-session=<token>; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=3600
```

There are no options, on the same rule as `Tesl.Crypto`: a caller who can pass `SameSite=None` eventually will. The `__Host-` prefix is load-bearing — it makes the *browser* enforce `Secure`, `Path=/` and no `Domain`, so a plain-HTTP deployment on a non-localhost origin visibly fails to store the session rather than transmitting one in the clear. Browsers exempt `http://localhost`, so local development is unaffected, and api-tests ignore cookie attributes entirely. `Max-Age` is taken from the same TTL constant `JWT.sign` stamps `exp` from, so the cookie can never outlive the token inside it.

**The writer takes a `JwtToken`, not a `String`.** That is the type system, not documentation, guaranteeing a session cookie always carries a signed value. There is no way to express an unsigned session cookie and no second cookie-writing function.

**Cookies attach to 2xx responses only.** A handler that sets a cookie and then `fail`s sends no `Set-Cookie` — no session is minted on an error path. The rule is enforced at the single point where every response is built, not by each handler remembering to undo the effect. Within one request the last call wins, per cookie name, so `setSessionCookie` followed by `clearSessionCookie` emits one header rather than two contradictory ones.

**Sliding sessions.** By default a session ends one hour after login, whether or not the user is active. To slide the window instead, call `JWT.renew` (§21.2) in the `auth` block and set the result — an `auth` block may write the cookie, which is why the effect is scoped to the whole request rather than to the handler alone. Renewal preserves the original `iat` and refuses past a fixed 12-hour absolute maximum, so a captured token still cannot be renewed indefinitely.

**On an `sse` endpoint too.** An `sse` subscribe runs its `auth` block under the same capability grant and the same per-request cookie scope as an HTTP route, so a sliding session renews on a long-lived stream exactly as it does on a JSON route. An SSE response that carries a `Set-Cookie` omits the `Access-Control-Allow-Origin: *` header the uncredentialed stream still gets: a credentialed subscribe is same-origin by construction, and "here is your session" beside "any origin may read this" is a contradiction worth not sending, even though a browser rejects a wildcard grant for a credentialed request anyway.

**`Http.clearSessionCookie()`** is the logout half: the same cookie with `Max-Age=0`. It removes the *browser's* copy; it does not invalidate the token, which stays verifiable until `exp` — bounded at one hour by the fixed TTL, or at 12 hours from login if the session was being renewed. That is the trade a stateless, horizontally scalable session makes: any replica holding the key verifies any token, with no session store, no sticky sessions and no cross-replica invalidation. Server-side revocation is stateful by nature and is deliberately not provided; for long-lived revocable credentials the answer is `Crypto.randomToken` plus a stored `Crypto.fingerprint` (§21.7).

**CSRF.** `SameSite=Lax`, plus Tesl's existing 415 on non-`application/json` request bodies, plus the absence of CORS headers on JSON routes, means a cross-site form or `fetch` cannot reach a state-changing handler. The one remaining obligation is the rule Tesl already teaches: GET handlers do not mutate.

**Testing.** `Tesl.ApiTest` exposes `responseCookie : HttpResponse -> Maybe String`, which returns the session cookie a response set as a Cookie-header-ready `name=value` pair — feed it straight to a request's `cookie` clause. It is `Nothing` when no cookie was set, including on every error response. For the attributes, read the raw `"set-cookie"` entry of `response.headers`.

**Not provided, deliberately:** general response-header setting, success statuses other than 200, cookie options of any kind, a second cookie, general cookie handling for UI state or preferences (a permanent non-goal — client-only state belongs in the generated client's own storage, and anything the server must trust belongs in a row keyed by the session subject), a cookie-read capability, and server-side session revocation.

See `example/learn/lesson76-sessions.tesl` and `tests/session-cookie-tests.tesl`.

---

### 21.9 `Tesl.Url` and `Tesl.Net`
**Implemented.**

Parsing a URL into its components, and classifying a host. Both pure — no
capability, no I/O, no name resolution.

```tesl
import Tesl.Url exposing [Url, Url.parse, Url.host, Url.port]
import Tesl.Net exposing [HostClass(..), Net.classifyHost, Net.isForbiddenHost]
```

**Why these exist.** An application that validates a user-supplied outbound URL
before fetching it has to answer *what is the host*, and before these modules
that was `String.indexOf` and `String.slice` at every call site. Every
hand-rolled version wrote the same recipe — cut the authority at the first `/`,
fall back to `:` — and shipped the same four bugs, none of which needs DNS or
attacker infrastructure, because the forbidden address is spelled out verbatim
in the URL and the comparison simply does not recognize the spelling:

| URL | Why a hand-written check passes it |
|---|---|
| `https://localhost:6379/hook` | the "host" is `localhost:6379`, which equals no entry in a forbidden-host list |
| `https://LOCALHOST/hook` | hostnames are case-insensitive; `==` is not |
| `https://localhost./hook` | a root-anchored FQDN resolves identically and compares differently |
| `https://2130706433/hook` | decimal-encoded `127.0.0.1` |
| `https://[::ffff:127.0.0.1]/hook` | IPv4-mapped IPv6 spelling of the same address |

#### `Tesl.Url`

`Url` is **opaque**: `Url.parse` is the only way to build one, so everything an
accessor returns is already canonical. Parsing covers authority-based URLs —
`scheme://[userinfo@]host[:port][/path][?query][#fragment]`.

| Function | Signature | Meaning |
|---|---|---|
| `Url.parse` | `(text: String) -> Maybe Url` | parses, or `Nothing` |
| `Url.scheme` | `(url: Url) -> String` | lowercased, no colon |
| `Url.host` | `(url: Url) -> String` | **canonical**: lowercased, trailing dot stripped, IPv6 unbracketed, every IP-literal spelling folded. Never carries the port |
| `Url.port` | `(url: Url) -> Maybe Int` | the port only when written |
| `Url.effectivePort` | `(url: Url) -> Maybe Int` | the written port, or the scheme default (`http` 80, `https` 443, `ws` 80, `wss` 443, `ftp` 21) |
| `Url.path` | `(url: Url) -> String` | `"/"` when the URL had none |
| `Url.query` | `(url: Url) -> Maybe String` | text after `?`; `Something ""` when written empty |
| `Url.fragment` | `(url: Url) -> Maybe String` | text after the first `#` |
| `Url.userInfo` | `(url: Url) -> Maybe String` | everything before the **last** `@` of the authority |
| `Url.toString` | `(url: Url) -> String` | re-serializes from the canonical parts |

**`Url.parse` fails closed.** Anything two parsers might read differently is
refused rather than guessed at: an ASCII control character, space or tab
anywhere; a backslash (browsers read `\` as `/` in an authority, so
`https://example.com\@localhost/` is a host swap); a URL with no `//` authority
(`mailto:`); an unbracketed IPv6 literal; an empty, zero or out-of-range port; a
host with a character outside `[a-z0-9._-]`; and an all-numeric final label that
is not a valid address literal.

**Userinfo is exposed, not dropped.** `https://trusted.example.com@127.0.0.1/`
puts a trusted-looking name in the credentials slot, and a check that reads the
URL as text sees it as the host. Refusing URLs that carry userinfo is one line.

#### `Tesl.Net`

`Net.classifyHost` canonicalizes the host first and then classifies it, so every
spelling of an address lands in the same class:

```tesl
type HostClass =
  | Loopback | PrivateIp | LinkLocal | Cgnat | Multicast
  | Unspecified | PublicIp | DomainName | InvalidHost
```

| Constructor | Range |
|---|---|
| `Loopback` | `127.0.0.0/8`, `::1`, and the RFC 6761 `localhost` names |
| `PrivateIp` | `10/8`, `172.16/12`, `192.168/16`, IPv6 ULA `fc00::/7` |
| `LinkLocal` | `169.254.0.0/16` (cloud instance metadata), `fe80::/10` |
| `Cgnat` | `100.64.0.0/10` |
| `Multicast` | `224.0.0.0/4` and above, `ff00::/8` |
| `Unspecified` | `0.0.0.0/8`, `::` |
| `PublicIp` | an address literal in none of the above |
| `DomainName` | a valid DNS name — **not** a safety verdict |
| `InvalidHost` | not a host the runtime will vouch for. Refuse it |

Classification is an ADT rather than a bag of predicates because a `case` over
it is exhaustiveness-checked: the bug this closes *is* a forgotten spelling, so
a forgotten range has to be a compile error rather than one missing `||`.
The predicates exist for one-line checks: `Net.isLoopback`, `Net.isPrivate`,
`Net.isLinkLocal`, `Net.isCgnat`, `Net.isMulticast`, `Net.isIpLiteral`,
`Net.isIpv4Mapped`, and the aggregate `Net.isForbiddenHost` (true for every
non-public address literal, the `localhost` names, and anything unparseable).
`Net.normalizeHost : String -> Maybe String` is the canonical spelling to
compare and store.

Host canonicalization decodes every IPv4 spelling `inet_aton` accepts — the
32-bit decimal/octal/hex forms, the `a.b` / `a.b.c` short forms, and per-part
octal and hex — plus the IPv4-mapped and IPv4-compatible IPv6 forms, so all of
them fold to one dotted quad before any range test runs.

**Scope: this is the shallow half, and deliberately so.** `DomainName` does not
mean safe — a name still resolves, and it can resolve to `127.0.0.1` or to the
metadata address. Only *resolve → judge every returned address → connect to the
address that was judged* closes that, it is not expressible in `.tesl`, and it
is already always-on for `Tesl.HttpClient`. The two share one range table
(`dsl/private/host-classify.rkt`), so an application's check and the runtime's
refusal cannot disagree about what "private" means.

See `tests/url-net-tests.tesl` and `tests/url-net-runtime-tests.rkt`.

---

## 22. Step Debugger
**Phase 0+1 Implemented. Phases 2–4 Open.**

Tesl provides a source-level step debugger using the Debug Adapter Protocol (DAP), integrated with the VSCode extension.

### 22.1 Architecture

```
VSCode
  │  DAP JSON-RPC over stdio
  ▼
runtime/go/cmd/tesl-dap     — DAP protocol handler
  │  launches or attaches to a Go program with debug instrumentation
  ▼
runtime/go/teslrt/debug.go  — source checkpoints and value snapshots
  │  signals stopped events through the Go control channel
  ▼
tesl-dap                    — serves variables, stackTrace, and stepping
```

### 22.2 Compiling with debug instrumentation

Pass `--debug` to the Go compiler:

```bash
tesl --debug file.tesl --out .tesl-stuff/go-debug
```

When `--debug` is active:
1. Debug checkpoints retain Tesl source locations and local-value accessors using the AST node locations.
2. Debug metadata is emitted into the Go module under `.tesl-stuff/go-debug/` and maps Tesl source lines to generated Go lines:

```json
{
  "tesl_file": "foo.tesl",
  "entries": [
    { "tesl_line": 12, "go_line": 47 },
    ...
  ]
}
```

The metadata allows the DAP server to translate VSCode breakpoint line numbers into generated Go positions.

### 22.3 VSCode integration

The `editor/vscode-tesl` extension contributes a `debuggers` entry in `package.json`. Launching `Debug Tesl Program` via VSCode:

1. Starts the Go DAP server from `runtime/go/cmd/tesl-dap`.
2. The DAP server compiles the `.tesl` file with Go debug instrumentation and launches the generated program.
3. Breakpoints set in VSCode are sent via `setBreakpoints` DAP messages. Go checkpoints match source locations, send stopped events, and wait for resume commands.
4. The variables panel calls `variables` and receives proof-unwrapped Go runtime values.

**GDP value unwrapping in the debugger.** The Go value renderer unwraps the runtime evidence layer before display. The user sees the application-level value, not the proof-carrying runtime wrapper.

### 22.4 Phase 1 capabilities (implemented)

- Breakpoints at statement and function level.
- `continue` resumes execution.
- Local variable inspection (proof-unwrapped values).
- Stack trace showing the currently paused function and source location.

### 22.5 Deferred phases

| Phase | Feature | Status |
|---|---|---|
| 2 | Step-over (`next`) and step-into (`stepIn`) | **Open** — requires a `step-depth` parameter to track call depth. |
| 3 | GDP proof tags as variable annotations | **Open** — show `"Alice" [IsTrimmed, IsNonEmpty]` in the variables panel. |
| 4 | Conditional breakpoints | **Open** — pause only when a user expression is truthy. |
| 4 | Watch expressions | **Open** — user-defined expressions evaluated at each pause. |

### 22.6 Attach to a running process

`tesl run --debug <file.tesl>` starts the app with live checkpoints (the same
emitted code — the `thsl-src!` gate is read at Racket expansion time) and a
loopback-only control channel under `<project>/.tesl-stuff/` (`debug.sock`, or
`debug.port` plus an owner-only `debug.token` for the TCP fallback). When a
project path cannot fit in a Unix socket address, the runtime selects the
authenticated TCP form; inspector-launched targets instead use an isolated,
owner-only short runtime directory. Loopback is shared by every local user, so
a TCP client's first message must be a `handshake` carrying that per-launch
token. Silent handshakes have a five-second deadline and at most 16 may be
pending; excess or unauthenticated connections are closed. Both Unix and TCP
endpoints also admit at most 16 authenticated clients at once; further
connections are closed before joining the session.
Debuggers then attach to the RUNNING process — the app keeps serving across
attach/detach, several clients may share one session (the debugger detaches
only when the last one leaves), and breakpoints can be re-armed without a
relaunch:

Before a stopped event and snapshot are published, active instrumented Tesl
executions have one second from the triggering stop to rendezvous at their next
function-entry/checkpoint boundary or exit. If that bound expires, publication
continues with `rendezvous: "timed-out"` rather than hanging; `"complete"` means
the finite participant set did rendezvous. The triggering execution remains
paused, and executions that later reach a boundary wait behind the stop, but an
execution still blocked in external Go work may be running, so a timed-out
snapshot is not a complete stop-the-world view. Stacks and SQL captures are
keyed by execution, and a query completion consumes and updates only the capture
identity created for that query. A failed query or exec consumes that identity
while unwinding too, so reusable plans retain no failed-operation mapping.
Arbitrary Go runtime goroutines and external systems are not suspended. A
lifecycle scope blocked inside `Serve` is explicitly
quiescent: it is excluded from the finite stop participant set, but must wait
behind the stop before returning to Tesl. Control writes are frame-atomic and
bounded to one second per client; a client that stops reading is removed without
delaying stopped-event delivery to other clients. The 16-client admission cap
also bounds the per-client stopped-event delivery work.

- **VSCode/VSCodium**: the `Attach to running app (tesl run --debug)` launch
  configuration (`request: "attach"`, `project: "${workspaceFolder}"`).
  Disconnect detaches; the app keeps running.
- **CLI / agents**: `tesl debug-attach` — `--break-at FILE:LINE … --once`
  (arm, wait for the first stop, print it, resume, detach), `--snapshot`,
  `--ping`, `--detach`, or a bare NDJSON stdin/stdout bridge for interactive
  stepping. MCP: the `tesl.debug_attach` tool.

A plain `tesl run` build erases every checkpoint at expansion time (zero
release residue) and exposes no endpoint — attach is a property of `--debug`
runs only. An abandoned pause can be bounded with
`TESL_DEBUG_PAUSE_TIMEOUT_MS` (auto-resume). The wrapper keeps debug and
release bytecode separate (a mode marker under `.tesl-stuff/build/` drops
stale `compiled/` dirs when the mode flips).

---

## 23. Single sign-on (SSO) and third-party auth
**Implemented (Phase 3).**

Tesl adds "Log in with GitHub / Google / your customer's Entra ID" as a **server
clause**, not a library the application drives. The design principle is the same
one that governs the session cookie (§20-adjacent, and lesson 76): *the dangerous
state must be unrepresentable*. Here that means the application never writes the
OAuth2 redirect, the `state` nonce, the PKCE challenge, the authorization-code
exchange, the ID-token signature check, or the `Set-Cookie` line. It declares a
**connection** (an ordinary value) and an **`onIdentity`** function that maps a
*verified* third-party identity to the app's own session subject. Everything
between the login button and the session cookie is runtime code the application
cannot get wrong because it does not write it.

```tesl
server AppServer for AppApi {
  sso "github" connection githubConn onIdentity linkUser
  publicOrigin "https://app.example.com"
  sessionKey "SESSION_KEY"
  loginMethods [Sso]
}
```

A worked, compiling example is `example/learn/lesson78-sso.tesl`; the flagship
end-to-end program is `example/sso-demo.tesl`.

The provider passed to `Sso.defaults` is the closed **`SsoProvider`** ADT
(`Github` | `Google`), not a string, so a mistyped provider is a compile error;
any other OpenID Connect issuer (a self-hosted Keycloak/dex, Okta, Auth0, or
single-tenant Entra) is reached with **`Sso.oidc "<issuer-url>" clientId secret`**,
which discovers the endpoints from the issuer and applies the same
signature+claims trust argument. And because the `connection`, `onIdentity`, and `sessionRevoked`
functions run under the server's granted capabilities, their `requires` must be
covered by `main`'s grant — the compiler rejects a program whose `main` does not
grant them (and an `sso` server additionally forces `main` to grant `httpClient`
for the flow's network calls) rather than failing at runtime. This is the same
capability-flows-to-`main` rule handlers and queue workers already obey.

### 23.1 Two trust arguments, written separately

An SSO login ends by minting a session for a subject the app did not choose. The
argument that this subject is *the right one* is **different for OIDC and for
plain OAuth2**, and Tesl keeps them separate because conflating them is how one
of the two stops being checked.

**OpenID Connect — the identity is a signed token, and the runtime verifies it.**
For an OIDC connection the provider returns an **ID token** (a JWS). The runtime
verifies the token's signature against the provider's published JWKS with the
algorithm **pinned** to the discovery document's advertised set (RS256/ES256
only; `alg: none`, symmetric `alg`, and an attacker-supplied `jwk`/`jku`/`x5u`/
`x5c`/`crit` header are all refused), then validates every claim it will rely
on: `iss` exactly equals the discovered issuer, `aud` contains this client, `exp`
is in the future and `iat` is not, and — when a `nonce` was sent — it matches.
Only after all of that runs is `onIdentity` called. Reading a claim off an
unverified token is not expressible: `SsoIdentity` is opaque.

**Plain OAuth2 — there is no identity token, so the argument is procedural.**
A bare OAuth2 provider (GitHub is the canonical case) returns only an access
token, which is a bearer credential, not a statement about *who* logged in. There
is nothing to verify a signature on. The trust argument is instead the shape of
the flow: a per-login **PKCE** challenge binds the authorization code to the
process that started the flow; a single-use, cookie-bound **`state`** value ties
the callback to that same browser; the authorization **code is redeemed exactly
once**, server-to-server, with the client secret sent only in the HTTP Basic
header (never in a URL or body); and the user's identity is then read by a
**server-side call to the provider's userinfo endpoint** using that access token
— never from anything the browser could have touched. These are two different
arguments and are documented, tested, and reasoned about as two different
arguments.

### 23.2 The account-linking rule

The identity the app stores must be **stable and injective**, or two different
people can collide onto one account (or one person can silently acquire two).
Tesl's identity key is the pair **`(issuer, subject)`**, exposed through
`Sso.subject`:

- For OIDC the `issuer` is the verified `iss` claim and the `subject` is the
  verified `sub`.
- For plain OAuth2 there is no issuer claim, so the runtime **synthesises a
  stable issuer** from the provider configuration; the `subject` is the
  provider's immutable user id from userinfo (never the email, which is
  reassignable).
- The **route segment is not identity.** `sso "github"` names a route
  (`/auth/github/login`), not a trust domain; renaming the segment must not
  re-key existing users, and it does not.

Email is deliberately **not** an identity key. An email address is reassignable
and, at some providers, not even verified — see §23.4.

### 23.3 Why TLS alone was not accepted (the §3.1.3.7 history)

An early and recurring objection is that TLS to the provider already
authenticates the token, so signature verification is redundant. OpenID Connect
Core §3.1.3.7 requires ID-token signature validation anyway, and Tesl follows it
for a concrete reason: **the transport and the token have different trust
boundaries.** A corporate TLS-terminating middlebox, a mis-issued certificate, a
compromised CDN edge, or any proxy the deployment cannot see all sit *inside* the
TLS boundary but *outside* the signing boundary. The signature is verified with a
key the provider published and rotates; a party that can observe or rewrite the
TLS stream still cannot forge it. TLS protects the *fetch*; the signature
protects the *claim*. Tesl still requires TLS for every discovery/JWKS/token
fetch (a plain-`http://` issuer or an SSRF-reachable JWKS host is refused), but it
is the floor, not the argument.

### 23.4 Multi-tenant issuers and the Entra reference path

Microsoft Entra ID is the tested enterprise reference, and it is where the
identity rules earn their keep.

- **Entra is configured via `Sso.oidc`** with the single-tenant issuer
  `https://login.microsoftonline.com/<tenant>/v2.0` — a concrete issuer, never
  the multi-tenant `common` authority.
- **The issuer is checked exactly, per tenant.** Entra's multi-tenant issuer is
  templated (`…/{tenantid}/v2.0`), so the runtime checks the concrete issuer
  against the connection's declared tenant(s); an empty tenant list, a `tid`
  outside the allowed set, or an `iss`↔`tid` disagreement is refused. A wildcard
  "any Microsoft tenant" configuration cannot be expressed by accident.
- **No email linking with Entra — this is the nOAuth defense.** Entra does not
  emit `email_verified`, so an email claim there is an *unverified* attacker-
  controllable string. Linking an account by email against Entra is the published
  **nOAuth** account-takeover: the attacker sets their unverified email to the
  victim's and is linked to the victim's account. The account-linking rule
  (§23.2) already forbids email as an identity key; the Entra path is where that
  rule is not optional. `allowedEmailDomains` is therefore **unusable with
  Entra**; the correct Entra mechanism is tenant restriction (`allowedTenants`).
- **Domain restriction is a *claim* check, not an authorize-param hint.**
  Provider authorize parameters such as Google's `hd` are hints to the login UI
  and are not trustworthy on their own. The enforced restriction is a check on
  the *verified* claim (a hosted-domain / verified-email claim), applied before
  `onIdentity`, and satisfiable only by a verified value.

`claims` are **not** an authorization input — they describe who the user is, not
what they may do; the app's own proofs decide authorization. The `tenant`, by
contrast, **is** an authorization-relevant input and is checked as one.

### 23.5 Session control, key rotation, and revocation

The session that SSO mints is an ordinary Tesl session (a signed JWT in a
`__Host-session` cookie), so it inherits the whole session-control surface:

- **`sessionPolicy StandardSession | ShortSession`** sets the renewable TTL and
  the absolute maximum lifetime (1h/12h vs 15min/8h). The absolute cap is
  decoupled from the TTL, so a short renewal window does not imply a short
  maximum session.
- **`sessionPreviousKey` is the rotation overlap and the only kill switch.** With a
  previous key configured, `JWT.verify` accepts a token signed by *either* the
  current or the previous key, so the signing key can be rotated without logging
  every user out; signing always uses the current key, so the previous slot
  drains on its own within one absolute cap. Emptying the slot while rotating the
  current key is a **global** logout — blunt by design, and the only revocation
  primitive that needs no per-session state.
- **`sessionRevoked` is a per-user check at the renewal boundary**, consulted
  *only* when a session renews and never on the stateless verify path. It is
  fail-closed (a raise or a failing read denies the renewal). Its two honest
  overclaims: it bounds revocation latency to the *renewal* interval (a live
  session is not killed mid-window), and it trusts the app's store to answer.

### 23.6 `loginMethods` — proving that only SSO can log in

The question an enterprise reviewer actually asks is "can you prove that a
password path cannot be used on an SSO-mandated account?" `loginMethods` is the
checked answer.

```tesl
server AppServer for AppApi {
  loginMethods [Sso]                            # SSO only
  # ── or ──
  loginMethods [Sso, Password via ssoRequired]  # mixed, one policy function
}
```

Under a `loginMethods` declaration **without `Password`**, the compiler refuses
any application call to the unique session-minting chokepoint
(`Http.setSessionCookie`) and any `Crypto.checkPassword` / `Crypto.hashPassword`
call, because the only sanctioned minting site is the runtime-owned SSO callback,
which is not application code. This is an **allowlist over the minting site**, not
a search for password-shaped code: a magic-link handler, a signup auto-login, or a
hand-rolled hash compare are all refused for the same reason, because each would
reach `Http.setSessionCookie`. The guarantee `loginMethods [Sso]` delivers is the
sentence the reviewer wants: *no code path in this program can produce a session
cookie except the SSO callback.*

Mixed mode (`[Sso, Password via <fn>]`) names one policy function that the
runtime consults on the password path; the per-site witness that lets a password
handler mint a session under this declaration is a design area (§16) and is not
yet enforced — a mixed-mode server currently requires only that the policy
function exists.

### 23.7 Server-clause grammar

```text
<sso-clause>        ::= "sso" <string> "connection" <ident> "onIdentity" <ident>
<public-origin>     ::= "publicOrigin" ( <string> | "fromEnv" <string> )  # absolute https (or http loopback), no path/query/fragment; fromEnv reads an env var at boot
<session-key>       ::= "sessionKey" <string>         # env var → Secret
<previous-key>      ::= "sessionPreviousKey" <string>        # env var → Secret (rotation)
<after-login>       ::= "afterLogin" <string>            # relative path
<session-policy>    ::= "sessionPolicy" ( "StandardSession" | "ShortSession" )
<session-revoked>   ::= "sessionRevoked" <ident>         # (String, PosixMillis) -> Bool
<listen-address>    ::= "listenAddress" ( "Loopback" | "AllInterfaces" )
<trusted-proxies>   ::= "trustedProxies" "[" <string> ("," <string>)* "]"  # edge declaration → request.clientAddress
<health-probe-path> ::= "healthProbePath" <string>       # the one path exempt from Host validation
<content-security-policy> ::= "contentSecurityPolicy" <string>  # server default CSP for HTML; per-response override wins
<login-methods>     ::= "loginMethods" "[" <method> ("," <method>)* "]"
<method>            ::= "Sso" | ( "Password" "via" <ident> ) | "Proxy" | "Machine"
```

All of these are validated at compile time, fail-closed: a server with an `sso`
clause must declare `publicOrigin` and `sessionKey`; `afterLogin` must be
relative; unknown connection/`onIdentity`/policy functions, duplicate route
segments, an `sessionPreviousKey` without an `sessionKey`, and unknown
`loginMethods` keywords are each a compile error.

---

## Appendix A. Current implementation divergences
This appendix is descriptive rather than normative.

### A.1 `const`
Resolved: the frontend rejects `const name = expr` at top level. Use `name = expr`; top-level bindings are immutable by default.

### A.2 Prelude / standard-library bootstrapping
The current frontend bootstraps some Prelude and ADT names specially. The intended language story is still that explicit imports and ordinary library definitions should carry as much of this surface as possible, including `Maybe` and `Result`.

### A.3 Application style
The primary application form is ML-style space-separated syntax (`f x y`). Parentheses are reserved for grouping (`f (g x)`) and grouped callees (`(checkA && checkB) x`). `<|` and `|>` provide low-precedence alternatives.

### A.4 Verbose ambient logging

**Implemented.** Activate at runtime with `TESL_VERBOSE=1`.

Tesl applications emit structured log lines to stderr for:
- HTTP requests and responses (method, path, status, elapsed ms)
- SQL queries emitted by the ORM (condensed single-line form + bound parameters)
- Queue `enqueue` and `dequeue` / `done` / `fail` events
- Pub/sub `publish` and `deliver` events

**Zero overhead when disabled.** `tesl-verbose?` is evaluated once at module load time from the `TESL_VERBOSE` environment variable. When it is `#f`, the only per-call cost is a single boolean read.

```bash
TESL_VERBOSE=1 racket .tesl-stuff/build/your-app.rkt   # or: TESL_VERBOSE=1 tesl run your-app.tesl
```

Example output:
```
[TESL][HTTP] → POST /rooms/room-1/messages
[TESL][SQL] insert into "chat"."messages" ("id", ...) values ($1, ...) [msg-abc, ...]
[TESL][QUEUE] enqueue NotifyJob id=job-xyz
[TESL][PUBSUB] publish RoomMessages(room-1)
[TESL][PUBSUB] deliver outbox#42 RoomMessages(room-1) → 2 listener(s)
[TESL][HTTP] ← 200 POST /rooms/room-1/messages (18ms)
```

Implementation: `tesl/logging.rkt` + instrumented in `dsl/web.rkt`, `dsl/sql.rkt`, `tesl/queue.rkt`.
