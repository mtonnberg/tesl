> **STATUS: PARTIAL — shipped + remainder carved to later/ (2026-06-26).** Phase 0
> scaffold (desugar seam, provenance, capability data-table, diagnostic-snapshot
> corpus, byte-exact + differential gates) shipped in W0-W2. Phase 3: lowered the
> three fixed-shape effect forms EEnqueue / EStartWorkers / EServe to one
> data-driven `Ast.ERuntimeCall` core node (3 emit arms → 1 walker). Phase 4:
> extracted the one provably-identical helper (proof-infix-operands) into
> dsl/private/proof-utils.rkt. DEFERRED → roadmap/later/surface-form-lowering.md:
> EUnop (P1), LInterp (P2), and the telemetry/publish/with-block/cache/email effect
> forms — blocked by the emitter's emit-time context-dependent `*name` raw-param
> unwrapping (the prerequisite "*name → core primitive" refactor is documented
> there), plus position-dependent emit (with-blocks) and missing byte-gated
> coverage (cache/email). Everything shipped is byte-identical (58-lesson 0-differ).

---

# Smaller Core — Reduce compiler size by composing surface features

> Part of the **Smaller Core** theme — see `smaller_core.md` for how this fits with the
> sibling initiatives.

## Context

Tesl is a hybrid: an OCaml frontend compiler (~36k lines in `compiler/lib/`) emitting to
three targets (Racket runtime, TypeScript, Elm), over a trusted Racket substrate
(~8.8k lines in `dsl/`). Now that the surface feature set is rich and stable, the
question is whether we can **re-express that feature set as compositions of a smaller core**
— shrinking the compiler and the runtime, improving maintainability and performance,
**without changing anything a user sees**.

This is the sibling of `roadmap/later/lifting_implementation.md`. That item moves the
*pure standard library* (`tesl/*.rkt`) into Tesl source. **This item is about the code
that cannot move to Tesl**: the OCaml frontend and the irreducible Racket runtime. The
two share the "smaller core" goal and do not overlap.

### The key architectural realization

**The compiler has no desugaring / lowering / elaboration pass.** The surface AST
(`compiler/lib/ast.ml`) flows *directly* into the type checker, each of the **three**
emitters (`emit_racket.ml` 6113, `emit_elm.ml` 1344, `emit_ts.ml` 601), the tooling IR
(`ir.ml` 925), and ~6 `validation_*.ml` files. Every surface construct is therefore
implemented independently in *each pass × each target*.

The expression AST has 30 variants (`ast.ml:97-134`). About 17 are domain-specific
effect/sugar forms — `ETelemetry`, `EEnqueue`, `EPublish`, `EStartWorkers`,
`ECacheGet/Set/Delete/Invalidate`, `ESendEmail`, `EStartEmailWorker`, `EWithDatabase`,
`EWithCapabilities`, `EWithTransaction`, `EServe` — and several more are pure syntactic
sugar (`EIf`, `EUnop`, `LInterp` string interpolation). Each carries its own arm in the
checker, in all three emitters, in `ir.ml`, and in the validators.

**Therefore: a single lowering pass that reduces surface sugar and effect forms to a small
"core AST" cuts the per-feature maintenance cost sharply.** The 17 forms are enumerated
across **15 files**, and within `emit_racket.ml` alone there are ~12 separate
match-traversals (`emit_expr`, free-variable walk, tail-expression analysis, named-return
analysis, establish-kind handling…) that each must list every variant. Lowering them to a
small core means a new or changed surface feature touches ~2–3 sites (a parser rule, a
lowering rule, and — if it enforces anything — one capability/proof table entry) instead of
an arm in ~15 files where forgetting traversal N is a silent bug. This directly answers the
seed: *compose features from a smaller core, lower the cost of maintenance, keep the
surface identical.*

**Sizing expectation (measured, not assumed).** The raw line shrink is **modest** —
roughly 700–1,400 lines, single-digit-percent of the ~45k-line codebase. Two corrections
to an earlier, optimistic reading: (1) the **Elm and TS emitters emit only *types*, not
expression bodies** (zero references to any effect/sugar form), so there is *no* 3× emit
fan-out to collapse — expression handling is essentially `emit_racket.ml` + `checker.ml`
(+ small arms in `ir.ml`/validators); and (2) the effect arms are already thin delegations
(`emit_racket.ml:2155-2262` ≈ 107 lines for 14 forms, mostly one-line calls into the
runtime). **The win is maintainability — cost-per-feature, not LOC.** If raw size is the
goal, `lifting_implementation.md` (stdlib → Tesl) shrinks more.

### The other non-negotiable invariant: error messages must not regress

Gold-tier diagnostics matter more than an elegant compiler — and naive early desugaring is
exactly how compilers regress them (an error on `if c then … else …` surfacing as "no arm
for `False`", or spans drifting to synthesized nodes). We get **both** by constraining
*where* lowering sits:

- **Lower late.** Type-check, proof-check, capability-check — and therefore every
  user-facing diagnostic — run on the **surface AST**. Lowering is repositioned as a
  **back-end transform feeding the emitters + IR**, *not* a front-of-pipeline pass the
  checker consumes. The checker keeps its surface-aware arms, so error messages are
  untouched by construction. This is why the size win concentrates on the emit×3 + IR
  fan-out rather than the checker.
- **Provenance for any unavoidable early lowering.** Tesl already threads `loc` on every
  AST node; a lowered node copies the original `loc` plus a `desugared_from` origin tag
  (cf. Rust's HIR `DesugaringKind`), and diagnostics are written against the origin. This
  preserves the `improve_error_messages` / bidirectional-checking investment rather than
  competing with it.
- **Proven by a hard gate:** diagnostic-snapshot tests. Capture today's error messages over
  a corpus (extending the existing `test_diagnostics` suite) and assert they are
  byte-identical after each lowering step. A diagnostics regression becomes a failing test,
  not a judgment call.

### The non-negotiable invariant: enforcement must not weaken

Effect forms are not free sugar — they carry **capability**, **proof**, and **type**
semantics that the validators enforce (e.g. `EServe`/`EWith*`/`ECache*` interact with
`validation_capabilities.ml`; `EOk`/`EFail`/`ELetProof` carry proof obligations). Lowering
them to plain function application must **not** bypass those checks.

The design rule that guarantees this: **run all enforcement passes before lowering loses
structure** — i.e. type-check, capability-check, and proof-check operate on the surface
AST (or on a core form that still carries the needed metadata), and the lowering to
function-application is what the *emitters* consume. Equivalently, where an effect lowers
to a runtime primitive, that primitive is registered in the same capability/proof tables
the checker already consults, so enforcement moves from per-variant *code* to per-entry
*data* — it is relocated, never removed.

The guardrail that proves we held the invariant is the existing safety net (differential
parity, mutation testing, capability tests) — **with the prerequisite that the net
actually exercises the denial paths** (see Phase 0).

## Feasibility — verified, not assumed

Confirmed by reading the source during planning:

- **No lowering layer exists.** `ir.ml` is primarily a JSON export for editor tooling. Its
  type IR (`Ir.ir_type`) *is* consumed by `emit_elm.ml` and `emit_ts.ml`, but its
  expression/structural export is *not* consumed by any emitter for **expression lowering** —
  the three emitters each re-derive expression structure from the surface AST. So introducing
  a core-lowering pass is *new* shared infrastructure, but it sits in a gap that today is
  filled by per-pass hand-rolled expression recursion.
- **The fan-out is real, but in *traversals*, not *targets*.** The ~17 effect/sugar
  variants in `ast.ml:117-134` are enumerated across 15 files; `emit_racket.ml` alone has
  ~12 match-traversals that each list every variant, and `checker.ml` has ~6. (The Elm/TS
  emitters do *not* handle expressions, so they are unaffected.) Collapsing a variant
  removes its arm from every one of those traversals at once.
- **A safety net guards the trusted boundary — but it is narrower than it looks.** The
  differential parity script (`scripts/differential-proofs.sh`), the **3-lesson** golden
  `.rkt` byte-comparison in `compiler/ci.sh` (`ci.sh:108` checks exactly `lesson00`,
  `lesson04`, `lesson05`), and mutation testing in `compile-examples.sh` are the gates that
  protected the zero-cost-proofs erasure work. Byte-identical emission before/after lowering
  is a checkable success criterion — but the byte-exact set must be **widened** beyond 3
  lessons (there are 79 committed `.rkt` under `example/`, 58 under `example/learn/`) before
  it can credibly gate this work (see Phase 0).
- **Precedent exists for surface simplification.** `drop-star-operator`,
  `remove_const_keyword`, and `remove dot access to functions` all simplified the language.
  This item differs: it keeps the surface **identical** and reduces only internal code.

> Note: the line-savings figures below are exploration estimates, not verified deletions.
> Each phase's real reduction is measured after the pilot lands.

### What can be lowered vs. what must stay core

**Default: lower late** — after type/proof/capability checking and diagnostics, feeding
the emitters + IR. Early (pre-check) lowering is reserved for forms whose checker arm
carries no distinctive error message, and even then only with provenance tags.

| Class | Forms | Disposition |
|---|---|---|
| **Sugar with no proof/capability semantics — but *not* context-free at emit time** | `EUnop` (`-x`, `!x`), `LInterp` string interpolation | Lower for **emission** to existing core, but **late**: both forms thread `func_kind`-dependent `*name`/raw-value unwrapping. `emit_interp` (`emit_racket.ml:2483`) emits Racket **`(format … ~a …)` with `tesl-display-val`**, *not* `BConcat`/`string-append` — so lowering `LInterp` must target the `format` primitive (or move the unwrapping into the core form), never `BConcat`, or byte-identity breaks. The pilot candidates, with this caveat. Only lower pre-check if diagnostics are non-distinctive *and* a `desugared_from` tag is carried. |
| **Sugar that is *not* clean** | `EIf` | **Stays core for now.** It carries `establish`-kind special-casing in `checker.ml` and `emit_racket.ml:3886/3900` plus tail-expression handling — not a trivial `→ ECase`. Only revisit after that special-casing is untangled. |
| **Effect forms** (carry capability/proof/target semantics) | `ECache*`, `ESendEmail`, `EStartEmailWorker`, `ETelemetry`, `EEnqueue`, `EPublish`, `EStartWorkers`, `EServe`, `EWith*` | Enforce + diagnose on the surface form; lower to function application **for emission only**. Biggest win (collapses emit×3 + IR); highest care. |
| **Irreducible core** | `ELit`, `EVar`, `EField`, `EApp`, `EBinop`, `ERecord`, `EList`, `EConstructor`, `ELambda`, `ECase`, `ELet`, `ELetProof`, `EOk`, `EFail` | Stay as the target core. `ELetProof`/`EOk`/`EFail` are proof carriers — do not touch. |
| **Racket runtime dedup** (independent) | duplicated proof helpers across `dsl/private/check-runtime.rkt` and `dsl/web.rkt` | Extract a shared `dsl/private/proof-utils.rkt`; unify proof decomposition/detach/wrapping. |

## Plan

### Phase 0 — Safety gate + lowering scaffold (prerequisite)

Before deleting any code path, make the test net trustworthy and add the seam.

1. **Harden the net to cover enforcement, not just emission.** Audit the corpus and
   confirm there are tests that *fail* when a capability is missing, a proof is unmet, or
   a type is wrong (negative/denial tests). Add the missing ones. This is what makes "the
   tests will catch regressions" actually true for the effect-form work.
2. **Add diagnostic-snapshot tests.** Extend the existing `test_diagnostics` suite to
   snapshot the *exact* error-message text for a corpus of broken programs (one per
   form/error class). These must stay byte-identical through every later phase — the gate
   that proves gold-tier error messages did not regress.
3. **Add the lowering module, positioned after enforcement.** Create
   `compiler/lib/desugar.ml` (a pure `Ast.expr -> Ast.expr` / `module_form -> module_form`
   pass) wired into `compile.ml` **between type/proof/capability checking and emit** — so
   diagnostics always fire on the surface AST. Initially it is the identity — proves the
   seam compiles and ships with byte-identical output across the whole corpus.

### Phase 1 — Pilot: one pure-sugar form, end to end

Use `EUnop` → function/`EBinop` (`!x`→`not x`, `-x` has a direct core form) — a pure-sugar
form, but **not context-free at emit time**: `EUnop` (`emit_racket.ml:1719`) special-cases
negative-int literals and threads `*name`/raw-value unwrapping keyed on `ctx.func_kind`, so
a naive pre-emission `Ast.expr → Ast.expr` desugar runs *before* that context exists and is
**not** byte-identical. Lower it **late** (or move the `*name` unwrapping into the core
form) so the emitted Racket stays byte-for-byte the same. (`EIf` is *not* the pilot: see the
disposition table.) Lower it in `desugar.ml` (post-enforcement), then **delete its arms from
`emit_racket.ml`'s ~4 `EUnop` sites** (`:1719`, `:2428`, `:3056`, `:3253`) — keeping the
`checker.ml` arm so its diagnostics are unchanged. Note `ir.ml` has **no `EUnop` arm**, so
this pilot gains nothing there. Gate: `compiler/ci.sh` green, the byte-exact `.rkt` set
unchanged, the diagnostic snapshots byte-identical, and `scripts/differential-proofs.sh`
parity holds. This validates the whole mechanism (and calibrates the real savings) on a
low-risk form.

### Phase 2 — Remaining pure sugar

Repeat for `LInterp`, but lower it to the **`format` primitive** the current emitter
already uses (`emit_interp` at `emit_racket.ml:2483` emits `(format … ~a …)` with
`tesl-display-val`) — **not** `BConcat`/`string-append`, which would change the emitted
Racket and break byte-identity. `ir.ml` has **no `LInterp` arm**, so only the
`emit_racket.ml` sites collapse. Each: add lowering rule (late), delete the emit arms,
re-confirm the byte-exact `.rkt` set. (`EIf` remains core — see the disposition table.)

### Phase 3 — Effect forms → function application (the big reduction, highest care)

For each effect family (`ECache*`, email, `ETelemetry`/`EEnqueue`/`EPublish`,
`EStartWorkers`, `EServe`, `EWith*`):

1. **Keep enforcement and diagnostics on the surface form.** Capability, proof, and type
   checks (and their error messages) run *before* lowering, on the surface AST. Where a
   form lowers to a runtime primitive, register that primitive in the capability/proof
   tables (`validation_capabilities.ml`, the proof tables in `emit_racket.ml`) so
   enforcement is relocated, not dropped.
2. **Lower to function application for emission**, deleting the per-target arms in all
   three emitters and `ir.ml`.
3. **Gate hard after *each* family:** differential parity, mutation tests (proofs still
   kill mutants), the capability denial tests, **and the diagnostic snapshots** from
   Phase 0 must stay green. Land one family per change so a regression is bisectable.

### Phase 4 — Racket runtime dedup (independent, can run in parallel)

Extract the proof helpers duplicated across `dsl/private/check-runtime.rkt` and
`dsl/web.rkt` (`proof-infix-operands`, `proof-satisfied?`, `normalize-typecheck-value`,
and a reconciled `proof-fact-matches?` / `flatten-proof-conjunction-facts`) into a new
`dsl/private/proof-utils.rkt`; optionally unify the proof decomposition
(`intro-and`/`and-left`/`and-right`), `detach-proof` variants, and struct-wrapping
(`ensure-named`/`attach`/`ensure-detached-proof`). ~120–300 lines, gated by the Racket
suites (`tests/all.rkt`) and the differential net. Note: the
`check-runtime.rkt`↔`web.rkt` `begin-for-syntax` duplication is *intentional* (the authors
documented why) — touch only the genuinely identical helpers.

## Weighted pros and cons

**Pros**
- **High — cost-per-feature drops from ~15 sites to ~2–3.** The 17 forms are enumerated
  across 15 files and ~12 traversals in `emit_racket.ml` alone; lowering collapses that to
  one parser rule + one lowering rule + an optional table entry. This is the seed's
  "cost of maintenance" target and the real payoff.
- **Medium — eliminates a bug class.** "Forgot to handle variant X in traversal Y" simply
  cannot happen once the traversals see only the small core.
- **Medium — smaller trusted boundary.** `emit_racket.ml` shrinks toward the core; fewer
  hand-written paths to audit.
- **Low/Medium — performance.** A normalized core can enable shared optimizations. It builds
  on `actually-zero-cost-runtime-proofs` and `optimizations.md`, both of which have **already
  shipped** (now in `roadmap/completed/`) — so this is composition with done work, not a
  pending dependency.
- **Low — raw size.** Realistically ~700–1,400 lines (single-digit-percent). A genuine but
  secondary benefit; `lifting_implementation.md` shrinks more by LOC.

**Cons / risks**
- **High — error-message regression** is the chief risk of any desugaring. Mitigated by
  lowering *late* (checker sees surface), provenance tags for any early lowering, and the
  byte-identical diagnostic-snapshot gate from Phase 0.
- **High — the emit boundary is trusted; effect-form lowering touches it heavily.**
  Mitigated by enforce-and-diagnose-before-lower, per-family landings, and the differential
  + mutation + capability gates.
- **Medium — capability/proof enforcement could silently weaken** if a form's metadata is
  lost in lowering. This is the invariant's whole point; Phase 0's denial tests are the
  proof it held.
- **Medium — the checker shrinks less than the back end.** Keeping surface-aware checker
  arms to protect diagnostics is a deliberate trade: we accept a smaller front-end win in
  exchange for unchanged error quality.
- **Low/Medium — modest LOC.** Anyone expecting a dramatic shrink will be disappointed;
  the value is structural (cost-per-feature), not line count. State this up front.
- **Low — `toString` precondition.** `LInterp`→concat needs a generic stringifier for all
  interpolated types. If absent, keep `LInterp` core.
- **Low — does not shrink the surface or remove user features** (by design). Elm/TS
  emitters are untouched (they emit types only).

## Critical files

- `compiler/lib/ast.ml` — `:97-134` expression variants; the ~17 effect/sugar forms to lower.
- `compiler/lib/compile.ml` — pipeline orchestration; wire in the new lowering pass.
- `compiler/lib/desugar.ml` — **new** lowering pass (`Ast.expr -> Ast.expr`).
- `compiler/lib/checker.ml` — `infer_expr` (`:1215+`) and its ~6 expression traversals;
  keep enforcement + diagnostics on the surface form.
- `compiler/lib/emit_racket.ml` (6113) — the ~12 expression traversals (effect arms at
  `:2155-2262`, plus free-var/tail-expr/establish-kind walks) collapse to the core. This
  is where most of the OCaml shrink is.
- `compiler/lib/ir.ml` (925) — per-form arms collapse; confirm tooling JSON unchanged.
- Note: `emit_elm.ml`/`emit_ts.ml` emit **types only** — they do not handle expressions
  and are *not* affected by this work.
- `compiler/lib/validation_capabilities.ml` and the proof tables — relocate effect-form
  enforcement to data entries; ensure no denial path is lost.
- `dsl/private/check-runtime.rkt`, `dsl/web.rkt`, **new** `dsl/private/proof-utils.rkt` —
  Phase 4 runtime dedup.
- `compiler/ci.sh`, `compile-examples.sh` — the gates; add capability denial + diagnostic
  snapshot tests here.

## Verification

Per "compiling is not testing":

1. **Byte-identical emission.** After each lowering, `compiler/ci.sh` must show the
   byte-exact `.rkt` set unchanged (today only 3 lessons at `ci.sh:108`; widen it toward the
   58 under `example/learn/` per Phase 0) — or re-baselined with reviewed, behavior-identical
   diffs — across all three targets.
2. **Diagnostic snapshots byte-identical.** The `test_diagnostics` snapshot corpus (Phase
   0) must show no change in error-message text or source spans — the gate that gold-tier
   error messages survived the lowering.
3. **Differential parity.** Run `scripts/differential-proofs.sh` over the corpus and confirm
   behavior-identical output — the same gate that guarded erasure. (Note: proof erasure is now
   unconditional/default-on, so toggling `TESL_ZERO_COST_PROOFS=0`/`=1` no longer changes
   compiler behaviour; the meaningful gate is the differential script, which lives in
   `scripts/` and is not yet wired into `compiler/ci.sh` — wire it in, per Phase 0.)
4. **Proof integrity.** Mutation testing (`compile-examples.sh`, e.g.
   `lesson42-mutation-testing.tesl`) must still kill mutants — proves proof enforcement
   survived lowering.
5. **Capability denial.** The Phase 0 negative tests (missing capability / unmet proof /
   wrong type) must still *fail to compile* — proves effect-form enforcement was relocated,
   not removed.
6. **Per-phase reduction measured.** Record actual `compiler/lib` and `dsl` line deltas
   after each phase; the pilot calibrates the rest.
7. **Standalone smoke test.** `nix build` + run/validate an example outside the repo tree.

## Out of scope

- Moving pure stdlib (`tesl/*.rkt`) into Tesl — that is `lifting_implementation.md`.
- Removing or changing any user-visible surface feature.
- Touching the intentionally-duplicated `begin-for-syntax` blocks in
  `check-runtime.rkt`/`web.rkt` beyond the genuinely identical helper functions.
