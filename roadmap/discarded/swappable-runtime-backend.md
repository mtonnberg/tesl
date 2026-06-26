# Swappable runtime backend (emitter ABI)

> **Status:** Later · **Effort:** L (architectural)

## Why now / why later

`LANGUAGE-SPEC.md` states that the Racket layer is an implementation detail and the
long-term design is meant to be agnostic to the backend runtime. Today that is
aspirational, not real: the OCaml emitter emits **Racket-specific forms** and the runtime
semantics live in the **Racket DSL**, so "swap the runtime" currently means "rewrite the
emitter *and* re-implement the entire DSL." There is no seam to swap at.

This is filed under `later/` because nothing forces a swap yet and it is a large refactor
— but it is tracked deliberately because several smaller efforts keep bumping into the
same coupling and all point at it: debugger portability
(`roadmap/next/improved_devx.md`), source maps, the value/proof representation in
`roadmap/next/actually-zero-cost-runtime-proofs.md`, and distribution
(`roadmap/later/language_distribution.md`). This item is the architectural work that turns
"the backend is Racket" into "the backend is a replaceable component behind a documented
interface."

## Goals & success criteria

- **A documented, minimal runtime ABI** — the explicit contract every backend must
  implement, owned by the OCaml side.
- **The emitter targets an abstract lowering / IR**, not Racket forms directly; the Racket
  backend becomes *one* implementation behind that interface.
- **A conformance suite** that any backend must pass (the example corpus run end-to-end
  through a backend), proving the seam is real and not Racket-shaped.
- **No regression:** the Racket backend still passes the full corpus and mutation suite
  after the refactor.
- *(Optional, demonstrative)* a second, even partial, backend that proves the ABI holds.

## Current state

- **Emitter:** `compiler/lib/emit_racket.ml` (~5,900 lines) walks the typed AST and emits
  Racket directly — forms like `define/pow`, `define-checker`, `define-auther`,
  `define-handler`, `define-record`, `define-entity`, `define-api`, `define-server`, plus
  a fixed set of `require`s (`tesl/dsl/capability`, `types`, `check`, `otel`, `sql`,
  `web`, …).
- **Runtime semantics** (proofs/GDP, capabilities, SQL, HTTP dispatch, queues, SSE,
  telemetry) live in the Racket `dsl/` + `tesl/` trees.
- The "OCaml is frontend-only" split (per `dev-docs/01-overview.md`) is clean at the
  *analysis* layers (parse → typecheck → proof-check → validate), but the **emission**
  layer hard-codes Racket as the target. That emitter is the coupling point.

## Workstreams

### 1. Define the runtime ABI (spec-first) — S–M
- **Approach:** enumerate exactly what a backend must provide, written as a document the
  current Racket backend already satisfies (so it is descriptive first, prescriptive
  second). Surface area to cover: value representation (and the debug-mode proof carrier),
  capability dispatch, `check`/`establish`/`auth` proof minting, record/entity/ADT
  representation, SQL execution interface, HTTP server + routing, queue/worker, SSE/pubsub,
  telemetry, and the **debug agent** contract (the `thsl-src!` block/report/resume +
  neutral value serialization from the debugger work).
- **Payoff:** turns implicit Racket assumptions into an explicit interface; immediately
  useful as documentation even before any refactor.

### 2. Introduce a lowering IR — L
- **Approach:** insert an explicit, backend-neutral intermediate representation between the
  checked AST and emission — lower-level than the surface AST, expressing ABI operations
  rather than Tesl syntax.
- **Payoff:** the place where backend-independence actually lives.

### 3. Re-home the Racket emitter onto the IR — M (follows 2)
- **Approach:** refactor `emit_racket.ml` into an `IR → Racket` backend so it consumes the
  IR instead of the AST. Behavior-preserving; guarded by the existing corpus + mutation
  suite.
- **Payoff:** proves the IR is expressive enough for the one backend we have.

### 4. Backend conformance suite — M
- **Approach:** a backend-agnostic test battery (the example corpus exercised through a
  backend, with expected behavior) that a new backend must pass to be considered valid.
- **Payoff:** makes "is this backend correct?" a checkable question, not a vibe.

### 5. Second backend as proof of seam — L (optional / demonstrative)
- **Approach:** a partial backend to a non-Racket target, enough to prove the ABI is not
  secretly Racket-shaped. Scope deliberately small.
- **Payoff:** the only real validation that the abstraction holds.

## Sequencing

1 (spec) → 2 (IR) → 3 (Racket onto IR) → 4 (conformance) → 5 (optional second backend).
Workstream 1 has standalone value and can begin immediately; the rest is a staged refactor
gated on the corpus staying green at each step.

## Dependencies / relationships

- **Debugger portability** (`roadmap/next/improved_devx.md`, workstream 1 + Design
  decisions): the debug-agent contract and source-map artifact feed ABI workstream 1.
- **Zero-cost proofs** (`roadmap/next/actually-zero-cost-runtime-proofs.md`): the value /
  proof-carrier representation is part of the ABI, including the "debug builds keep proof
  structs" contract.
- **Distribution** (`roadmap/later/language_distribution.md`): a different backend changes
  the distribution and startup story.

## Open questions

- **IR altitude:** how low? Close to the surface AST (easy, but leaks Tesl semantics into
  every backend) vs. a small core calculus (harder, cleaner seam). This is the central
  design tension.
- Is a second backend a genuine goal, or only a conformance device? That answer sets how
  aggressively to abstract.
- Where do the **trusted / security-critical** guarantees live if the runtime changes? The
  spec notes some integrity checks currently sit in trusted runtime parts — the ABI must
  say which guarantees are the backend's responsibility vs. statically discharged.

## Out of scope (for this item)

- Building a *production* non-Racket backend — this item is the **seam**, not a second
  implementation.
- Performance of the Racket backend itself — owned by `roadmap/next/optimizations.md`.
