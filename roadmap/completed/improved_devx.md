# Improved developer experience

> **Status:** Next · **Effort:** mixed (S/M/L per workstream)
>
> **Progress — ALL workstreams shipped except `tesl init`** (deferred to
> `roadmap/later/tesl_init.md`). Debugging (DAP + Track-A rendering), help, error codes,
> lint, LSP, and delight are all done:
> - **WS1 Debugging:** ✅ A1 source positions · ✅ A2 Tesl-level failure rendering · ✅ A3
>   error codes · ✅ B1 transport hardening · ✅ B2 breakpoints at Tesl altitude · ✅ B3
>   variables panel (proof/type overlaid from compile-time) · ✅ B4 VSCode `launch.json` ·
>   ✅ B5 emitter fork retired (one emission path; `thsl-src!` expansion-gated on
>   `TESL_DEBUG`; release erases to bare; the DAP server sets `TESL_DEBUG=1`).
> - ⬜ **WS2 `tesl init`** — ⚠Deferred! not done. Deffered to roadmap/later/tesl_init.md should not be done now.
> - ✅ **WS3 Help overhaul** — coherent nav + machine-readable anchor scheme (`manual/anchors.md`).
> - ✅ **WS4 Error → manual deep-links** — stable error codes (`error_codes.ml` registry) +
>   `read more:` / `explain:` pointers on diagnostics + `tesl help <code>` /
>   `tesl help manual <section>#<anchor>` (anchor-resolving); dev-docs path bug fixed.
> - ✅ **WS5 Linting** — false positives cut + proof footgun rules (W063 redundant re-check,
>   W064 discarded validation).
> - ✅ **WS6 Autocomplete / LSP** — completion (was missing) + compiler-backed hover/go-to-def.
> - ✅ **WS7 Delight** — formatter idempotence locked + polish.
>
> **⚠ SUPERSEDED CONTRACT (affects B3, B5, and the "Debug builds keep proof structs" design
> decision below).** The original plan kept `named-value` proof structs under `--debug` so the
> debugger could read `facts` off them. That was **removed**: proofs are now erased
> **unconditionally** (release *and* `--debug`). The debugger instead shows the **raw runtime
> value** and **overlays proof/type from compile-time** (`tesl --local-bindings-json`), which is
> the runtime-agnostic principle this doc already argues for. **B5 is now done** — the emitter
> fork is retired: one emission path, `thsl-src!` expansion-gated on `TESL_DEBUG` (release
> erases to bare with zero residue; the DAP server sets `TESL_DEBUG=1`). See
> `roadmap/completed/actually-zero-cost-runtime-proofs.md` (shipped).

## Why now

Tesl's bet is that APIs can feel close to a solved problem — but a language only
delivers that feeling if the *experience around it* is delightful. In alpha, adoption
and the willingness to keep using Tesl hinge less on raw feature count and more on how
it feels to get started, read an error, debug a failing handler, and have the editor
help you along.

Today the foundations exist (a working LSP, three-tier error messages, a formatter, a
Nix install) but the experience is uneven. Debugging is the weakest link, onboarding is
nix-only with no project scaffold, and the help system wasn't designed for the reality
that both humans *and* AI agents read it. This item collects the experience work into
one place so it can be sequenced deliberately rather than picked at ad hoc.

## Goals & success criteria

- **Debugging improves dramatically** — when something fails at runtime, the developer is
  pointed at the `.tesl` line/construct responsible, not just a Racket trace.
- **Getting started is easy** — Nix + the VSCodium extension + a `tesl init` command give
  a new user a runnable project in minutes.
- **Help is designed for AI + human** — `tesl help` / `tesl help manual` are coherent,
  navigable, and consumable by an agent without scraping.
- **Errors teach** — error messages link to the relevant manual section for deeper
  reading.
- **Linting and autocomplete are better** — fewer false positives, more useful
  suggestions, more of the language surface covered.
- **It feels delightful** — the small stuff (formatter, test output, prompts) is polished.

## Current state

Grounded in what exists today:

- **Onboarding.** Install is the Nix flake (`nix profile install github:mtonnberg/tesl`)
  plus the `editor/vscode-tesl` extension backed by the `editor/tesl-lsp` language server
  (diagnostics, hover types, completions, go-to-definition, occurrence highlighting).
  There is **no `tesl init`** — nothing scaffolds a runnable starting project.
- **Help.** `tesl help` and `tesl help manual` exist but predate the goal of serving both
  humans and AI agents; they aren't structured for either audience deliberately.
- **Errors.** Three-tier error messages already shipped
  (`roadmap/completed/improve_error_messages.md`), but they don't deep-link into the
  manual for "read more."
- **Debugging.** Programs compile to Racket; `TESL_VERBOSE=1` gives structured logs.
  Runtime failures still surface largely in terms of the generated Racket, not the
  original Tesl. There is, however, a **partially-built source-mapped debugger** already
  in the tree: a `--debug` compile mode (`emit_racket.ml::set_debug_mode`) wraps each
  statement in `(thsl-src! file line locals thunk)`; the AST carries a `Location.loc` on
  every node; `dsl/debug/checkpoint.rkt` is a step runtime (breakpoints, step-into/over,
  GDP-wrapper unwrapping via `thsl-display-value`); and `dsl/debug/dap-server.rkt` is a
  ~460-line Debug Adapter Protocol server that proxies to VSCode. This works but shows
  signs of still being stabilized (a `~/tesl-dap.log` crutch, `PLTCOLLECTS`/WSL
  special-casing).

## Workstreams

### 1. Debugging — L (two tracks: A = error legibility, B = interactive DAP)

The single biggest lift to day-to-day experience. We commit to **both** tracks, because
they stay valuable independently even once both ship — they answer different questions:

- **Track A — error legibility (post-hoc, headless).** "What broke?" Makes *every*
  failure readable in Tesl terms, everywhere a human isn't sitting at a live session: CI
  output, production stack traces, a failing `tesl test`, an AI agent reading a trace.
- **Track B — interactive DAP (live, in-editor).** "Why, exactly, as it runs?"
  Breakpoints, stepping, and inspecting proof-carrying locals inside `editor/vscode-tesl`.

They are not redundant: A is the floor (broad, headless, always-on), B is the ceiling
(deep, interactive, present-human-only). And they share one substrate — the AST's
`Location.loc` and the `thsl-src!` source-position emission — so the mapping work in A
directly raises the quality of B's breakpoints and variable panel. Track B is mostly
*finish and harden* (the server and step runtime already exist), not *build from scratch*.

**Track A — make failures legible**
- **A1. Source-position mapping in runtime errors (shared prerequisite).** Thread
  `Location.loc` through emission so Racket exceptions/traces resolve back to `.tesl`
  `file:line`. Anchors: `emit_racket.ml`, `ast.ml` (`loc`), the runtime error path.
- **A2. Tesl-level failure rendering.** Render proof / `check` / capability failures at
  the originating Tesl construct ("expected `ValidTitle`, got …"), not as expanded
  macros. Build on `TESL_VERBOSE` rather than replacing it.
- **A3. Stable error codes + manual links.** Same effort as workstream 4 — do it once,
  shared.

**Track B — finish the interactive debugger**
- **B1. Stabilize launch/transport.** `PLTCOLLECTS` resolution, DAP framing,
  cross-platform (WSL) reliability; retire or gate the `~/tesl-dap.log` crutch. Anchor:
  `dsl/debug/dap-server.rkt`.
- **B2. Breakpoint + stepping correctness.** Map breakpoints to `.tesl` lines (depends on
  A1) and keep stepping "at Tesl altitude" — skip forms that exist only from macro
  expansion. Anchor: `dsl/debug/checkpoint.rkt`.
- **B3. Variables panel quality.** Extend GDP-wrapper unwrapping and proof display
  (`thsl-display-value`, `format-proof-list`) to cover records, newtypes, and ADTs.
  **Contract with `actually-zero-cost-runtime-proofs.md`:** proof display reads the
  `facts` off the runtime `named-value` struct, which that item's elision would erase.
  The agreed contract is that **`--debug` builds never elide proof structs** (release
  builds may). This keeps the debugger at full proof fidelity and lets both efforts
  proceed in any order — see that item's Phase 2 note.
- **B4. VSCode integration.** Debug configuration / `launch.json` contribution in
  `editor/vscode-tesl`.
- **B5. Two-emission-path guardrail → unify after A1.** `--debug` is a second emission
  mode; in the short term, add a regression test that compiles the example corpus in both
  modes so they cannot drift. The longer-term plan is to retire the fork (see *Design
  decisions* below): once A1 makes the emitter carry positions unconditionally, move the
  debug-vs-release choice into an expansion-time switch in `checkpoint.rkt` so there is
  one emission path with zero release overhead.

- **Payoff:** A = every failure legible everywhere (also unblocks the AI+human and
  error-deep-link goals); B = live deep-dive in the editor.

### 2. Onboarding & `tesl init` — M
- **Goal:** zero-to-running project in one command.
- **Approach:** a `tesl init` that scaffolds a minimal but real project — an entity, a
  handler with a codec, a test block, and a server definition — that validates and runs
  immediately, paired with the VSCodium extension for a complete starting point.
- **Anchors:** CLI entry in `compile.ml`, `example/` for canonical shapes to template
  from.
- **Payoff:** removes the blank-page problem for new users.

### 3. Help system overhaul (AI + human) — M
- **Goal:** `tesl help` / `tesl help manual` redesigned from the ground up for both
  audiences.
- **Approach:** coherent navigation for humans; a machine-readable manual surface (stable
  structure / IDs) so an AI agent can consume it without scraping prose. The manual stays
  **shipped inside the `tesl` CLI** (`tesl help manual`, as today) — no separate hosting,
  and it versions for free with the binary the user already has installed.
- **Anchors:** existing `tesl help` implementation, `LANGUAGE-SPEC.md` / `TESL.md` as
  source material.
- **Payoff:** better self-service for humans and far better assistance from agents.

### 4. Error messages → manual deep-links — S–M
- **Goal:** every meaningful error can say "read more here."
- **Approach:** assign stable error codes and attach manual links/anchors to errors,
  extending the completed three-tier work rather than rewriting it.
- **Anchors:** `roadmap/completed/improve_error_messages.md`, the error-rendering path in
  the compiler.
- **Payoff:** errors become a teaching surface; depends on workstream 3 for link targets.

### 5. Linting improvements — M
- **Goal:** more useful, less noisy `tesl validate` linting.
- **Approach:** survey current lint rules, cut false positives, add high-value rules that
  catch real Tesl footguns (e.g. the documented proof/unwrapping gotchas).
- **Anchors:** the lint/validation passes (`validation_*.ml`).
- **Payoff:** higher signal in the inner loop.

### 6. Autocomplete / LSP improvements — M
- **Goal:** completions and editor intelligence cover more of the language.
- **Approach:** extend the LSP's completion/hover coverage; improve quality of go-to-def
  and diagnostics where gaps exist.
- **Anchors:** `editor/tesl-lsp`, the compiler's JSON output flags it consumes.
- **Payoff:** the editor does more of the work.

### 7. Delight — S, ongoing
- **Goal:** the small stuff feels good.
- **Approach:** formatter polish, prettier `tesl test` output, friendlier CLI prompts and
  summaries — picked up opportunistically alongside the other workstreams.
- **Payoff:** cumulative "this is nice to use."

## Sequencing

Across the item: quick wins first (4 and 7) → structural experience work (2, 3, 6, and 5
in parallel as capacity allows) → debugging (1) carried alongside as the largest,
highest-value bet. Note 4 depends on 3 for somewhere to link to.

### Debugging (workstream 1) — work plan

Strategy: **land A1 first** (it is the shared substrate), then run Track A and Track B
**in parallel** — they touch different surfaces (compiler error rendering vs. the Racket
DAP server + VSCode extension) and can be owned by different people. Track A is shippable
and useful on its own and lands earlier; Track B is a fast-follow since the server
already exists.

- **Sequential / on the critical path:** `A1 → A2`, and `A1 → B2`. A1 gates Tesl-level
  rendering *and* correct breakpoints, so it is the one thing to do first.
- **Parallel once A1 lands:** Track A (A2, A3) ∥ Track B (B1, B3, B4). B3 (variable
  display logic) can even be built and unit-tested against `checkpoint.rkt` before B1's
  transport is fully stable.
- **Shared / coordinate:** A3 is the same work as workstream 4 — do it once.
- **Continuous guardrail:** stand up B5 (dual-mode corpus compile) as soon as any B work
  starts, so the `--debug` path can't silently drift from normal emission.
- **Vertical-slice tactic for B:** get one end-to-end demo working on Linux/WSL first —
  "set a breakpoint in `example/.../todo-api.tesl`, hit it, inspect a proof-carrying
  local in VSCode" — then broaden coverage, rather than hardening every DAP request up
  front.

## Design decisions

- **Stepping "at Tesl altitude" (B2).** Steppability is decided by **source-location
  provenance**, not a hand-maintained list of constructs. A form gets a `thsl-src!`
  wrapper (becomes a stop) iff it carries a genuine parser-assigned `Location.loc` *and*
  is a "user statement" category node (let-binding, statement, terminal expression,
  function-body entry, reachable `case`/`if` branch). Granularity is statement-level, not
  sub-expression. Synthetic forms introduced during lowering (codec field extraction, SQL
  assembly, capability plumbing, `named-value` wrapping, exists/forall witnesses) lack a
  real loc and are therefore never wrapped → automatically skipped. New lowerings are
  non-steppable by default; a wrapper is added only when a new user-visible stop is
  deliberately wanted. (Step-into of stdlib/builtins naturally degrades to step-over,
  since those are compiled without `--debug` wrappers.)
- **One emission path, eventually (B5).** We do not keep two divergent emitters
  long-term. Short term: keep the existing `--debug` fork, guarded by the dual-mode corpus
  test. Once **A1** makes the emitter carry source positions unconditionally (it needs
  them for error mapping anyway), move the debug-vs-release decision into an
  **expansion-time** switch in `checkpoint.rkt`: `thsl-src` expands to a checkpoint when
  debug is enabled at `raco`-compile time, and to the bare expression (zero residue)
  otherwise. One OCaml emission path, zero release overhead. (Requires making
  `debug-enabled?` an expansion-time constant rather than a runtime parameter.)
- **Manual hosting.** Resolved: the manual ships in the `tesl` CLI (`tesl help manual`).
  No external hosting; versioning is free with the installed binary.
- **~~Debug builds keep proof structs~~ — SUPERSEDED.** Erasure is now unconditional
  (release *and* `--debug`); the debugger overlays proof/type from compile-time
  (`tesl --local-bindings-json`) rather than reading runtime structs. See the
  superseded-contract note at the top and
  `roadmap/completed/actually-zero-cost-runtime-proofs.md` (shipped).
- **Keep the debugger runtime-agnostic (OCaml decides, runtime executes a thin agent).**
  To avoid tying the debugger to Racket, the design splits along "knowledge vs. live
  execution":
  - **Track A is mostly OCaml.** A1 produces a real **source-map artifact** (emitted
    `file:line` → `.tesl` `file:line`) as a compile output, and trace translation is a
    *separate OCaml tool* that maps a raw backend stack trace back to Tesl. The only
    backend requirement is line numbers in traces — portable across targets.
  - **Track B keeps only a thin runtime "debug agent."** The current `thsl-src!` design
    is already instrumentation-based (the OCaml emitter injects checkpoints), which is the
    portable choice — not relying on a host VM's debugger API. The per-runtime port is
    just "block / report `(position, raw locals)` / resume" against that runtime's
    concurrency primitives. **Value display formatting belongs in OCaml** (it knows the
    static types/proofs); the runtime reports raw values in a neutral serialization.
  - **Don't rewrite the working Racket DAP server now** for portability alone — do it when
    the debugger needs a rewrite anyway or a runtime swap becomes concrete. The cheap,
    low-regret move now is to write the agent contract down as an OCaml-owned spec.
  - The larger lever for runtime-swappability is the emitter ABI itself, tracked
    separately in `roadmap/later/swappable-runtime-backend.md`.

## Out of scope (for this item)

- **General toolchain/test/build performance** — owned by
  `roadmap/next/optimizations.md`. Experience here is about clarity and ergonomics, not
  raw speed.
