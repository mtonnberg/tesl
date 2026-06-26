> **STATUS: COMPLETE (2026-06-26).** Phase 0 (Ast_visitor framework — map/fold/iter
> + recursive variants over all 30 expr variants, loc-preserving) and Phase 1
> (mutate.ml / linter.ml / emit_racket.ml proof-collector migration + the
> EFail.message recursion-bug fix) shipped in the W1 wave. Phase 2 (2026-06-26):
> added `fold_children_env` and migrated the mechanical expr sub-walks
> (validation_capabilities.collect_needed_capabilities, the structural arms of
> validation_proof.check_expr_call_proofs, proof_checker walks); semantically
> load-bearing walks (alias/shadow tracking; checker.ml infer_expr) are
> deliberately KEPT EXPLICIT per Phase 3 (checker.ml has zero Ast_visitor refs).
> Gates green (test_ast_visitor incl. env-fold property tests; 58-lesson byte-exact
> 0-differ; diagnostics held). No deferred items.

---

# Smaller Core — A shared AST traversal framework

> Part of the **Smaller Core** theme — see `smaller_core.md`. This is the *enabler*: it
> makes the desugaring (`reduce_language_size.md`) and validation-consolidation
> (`validation_consolidation.md`) items dramatically cheaper, and removes a standing bug
> class. Highest-leverage single move in the theme.

## Context

The Tesl compiler (~36k lines, `compiler/lib/`) manipulates one central type — the
expression AST, `Ast.expr`, with 30 variants (`ast.ml:97-134`). Almost every pass needs
to walk that tree: type-check it, emit it, validate proofs/capabilities over it, collect
names, mutate it, lint it, export it.

**There is no shared way to walk it.** Each pass hand-writes a `match … with` that
enumerates every variant — including the boring "just recurse into my children" cases.

## The key architectural realization

**No traversal abstraction exists anywhere in the compiler.** Searching `compiler/lib/`
for `map_expr` / `fold_expr` / `iter_expr` / `visit_expr` / open-recursion helpers returns
nothing defined. Instead, ~15 files each re-enumerate the full variant set:

- `emit_racket.ml` — ~12 distinct traversals (`emit_expr`, free-variable walk,
  tail-expression analysis, named-return analysis, establish-kind handling, …)
- `checker.ml` — ~6 (incl. `infer_expr:1246`)
- `validation_proof.ml` (`check_expr_call_proofs:259`), `proof_checker.ml`,
  `validation_advanced.ml`, `validation_capabilities.ml`, `validation_names.ml`,
  `validation_common.ml`, `validation_structural.ml`
- `mutate.ml`, `linter.ml`, `compile.ml` (`visit_expr:1830`), `ir.ml`

The consequences:
- **Every new variant is an N-site edit.** Adding one expression form means finding and
  updating every traversal that should recurse through it.
- **A whole bug class is uncheckable.** OCaml exhaustiveness is *on* (dune only sets
  `-w -50`), so you can't "forget a variant" in a no-catch-all match — the compiler forces
  an arm. The silent bug is **wrong or incomplete recursion on a *handled* variant**: a pass
  writes an arm but fails to descend into all of that variant's sub-expressions, and nothing
  complains because the match still type-checks. This is live today: `compile.ml`'s
  `visit_expr:1830` matches `EFail _ -> ()` and never recurses into `EFail`'s message
  expression, while `mutate.ml` and `linter.ml` *do* recurse into it. The bug is silent.

A single `map` / `fold` / `iter` over `expr`, with a default that structurally recurses
into children, lets each pass override **only the cases it cares about** and inherit
correct recursion everywhere else.

## The critical nuance: do not throw away exhaustiveness

OCaml's exhaustiveness warning is, today, a *safety feature* for the **semantic** passes:
when you add a variant, the compiler forces you to decide how `checker.ml` and
`emit_racket.ml` handle it. A naive visitor with a catch-all `| _ -> …` default would
**hide** a genuinely missing semantic handler — trading a silent boring-recursion bug for a
silent semantic bug. That is not an improvement.

The design rule that keeps both benefits:
- The visitor's default is **structural recursion** (`map_children` — descend into every
  sub-expression and rebuild), which is *correct by default* for the boring passes.
- **Semantic passes stay explicit.** `checker.ml` and `emit_racket.ml` keep their exhaustive
  matches where each variant needs distinct handling; they may use `map_children` only for
  the genuinely-recursive boilerplate, not to replace meaningful cases.
- The visitor is therefore aimed at the **many mechanical walks** (free-var collection,
  mutation enumeration, validation sub-walks, linting) — where today's hand-rolled matches
  are pure boilerplate and the silent-recursion bug actually bites.

## Feasibility — verified, not assumed

- **No `map`/`fold`/`iter`/visitor is defined** in `ast.ml` or anywhere in `compiler/lib/`
  (grep confirmed). The gap is real.
- **The boilerplate is real.** The ~12 traversals in `emit_racket.ml` and the validation
  sub-walks repeat the same "recurse into `EApp`'s fn+arg, `EIf`'s three children,
  `EWith*`'s body, `ECache*`'s key/value, …" structure verbatim.
- **OCaml supports the pattern cleanly.** A record-of-functions visitor or an open-recursion
  `map_children : (expr -> expr) -> expr -> expr` is idiomatic and adds no dependency.

## Plan

### Phase 0 — Define the framework + prove it is behaviour-neutral
Add `compiler/lib/ast_visitor.ml` exposing, at minimum:
- `map_children : (expr -> expr) -> expr -> expr` — apply f to each immediate
  sub-expression, rebuild the node, preserving `loc` exactly.
- `fold_children : ('a -> expr -> 'a) -> 'a -> expr -> 'a`
- `iter_children : (expr -> unit) -> expr -> unit`
- convenience `map` / `fold` / `iter` that recurse to a fixpoint via the above.

Property test (in `compiler/test/`): over the whole `.tesl` corpus, `map (fun e -> e)` and
a recursive identity `map` must reproduce the AST **structurally unchanged** (including
locs). This is the guarantee the migrations rely on.

### Phase 1 — Migrate one mechanical pass, end to end
Pick a self-contained boring walk — e.g. a free-variable collector or `mutate.ml`'s
enumeration — and reimplement it on the visitor. Gate: `compiler/ci.sh` green, its
byte-identical `.rkt` snapshots (currently `lesson00`/`lesson04`/`lesson05` only — narrower
than ideal; widen the set as part of the safety net) unchanged, differential parity via
`scripts/differential-proofs.sh` unchanged. (Note: proof erasure is now unconditional, so
the old `TESL_ZERO_COST_PROOFS` 0/1 toggle no longer changes compiler behaviour; the
parity that matters is the differential script, and it is not yet invoked by `ci.sh`.)
This validates the framework on real code before any breadth.

### Phase 2 — Migrate the validation sub-walks
Move the mechanical recursion in the `validation_*.ml` passes onto the visitor (this is the
shared groundwork for `validation_consolidation.md`). Keep each pass's *decisions* explicit;
only the recursion becomes shared. Re-baseline diagnostics (reuse the diagnostic-snapshot
gate proposed in `reduce_language_size.md`).

### Phase 3 — Leave semantic passes explicit
`checker.ml` and `emit_racket.ml` keep exhaustive matches for cases that matter; they may
adopt `map_children` only for pure boilerplate recursion. Do **not** introduce a catch-all
that suppresses exhaustiveness warnings in these files.

## Weighted pros and cons

**Pros**
- **High — eliminates a silent bug class.** Boring passes recurse correctly by default;
  "wrote an arm for variant X but forgot to recurse into its sub-expressions" (the
  `EFail.message` bug at `compile.ml:1830`) can't happen for them.
- **High — amplifies the rest of the theme.** Desugaring and validation consolidation both
  become far smaller once a shared traversal exists. This is why it sequences first.
- **Medium — cost-per-variant drops.** A new expression form updates the visitor's child
  recursion once, plus only the semantic passes that genuinely care.

**Cons / risks**
- **Medium — must not weaken exhaustiveness on semantic passes.** The whole "critical
  nuance" section exists to prevent this; enforced by keeping `checker`/`emit` explicit.
- **Low/Medium — modest direct LOC.** The win is structural; raw deletions are moderate
  until desugaring/validation build on it.
- **Low — visitor design churn.** Getting the `map`/`fold` signatures right may take a
  revision; contained to one new file.

## Critical files

- `compiler/lib/ast.ml` — `:97-134` the `expr` variants the visitor must cover (plus
  patterns and declaration forms if extended).
- `compiler/lib/ast_visitor.ml` — **new** framework.
- `compiler/lib/mutate.ml`, the `validation_*.ml` sub-walks, free-var/lint walks in
  `compile.ml` (`:1830`) and `linter.ml` — first migration targets.
- `compiler/lib/checker.ml`, `compiler/lib/emit_racket.ml` — stay explicit; adopt
  `map_children` only for boilerplate recursion.
- `compiler/test/` — the identity-`map` property test.

## Verification

1. **Identity property.** `map (identity)` over the corpus reproduces the AST unchanged.
2. **Byte-identical emission.** Each migrated pass leaves `compiler/ci.sh` green and its
   byte-identical `.rkt` snapshots unchanged. (Today `ci.sh:108` byte-checks only three
   lessons — `lesson00`, `lesson04`, `lesson05`; there is no 33-file gate. Widen this set
   as part of the safety net before relying on it.)
3. **Differential parity.** Run `scripts/differential-proofs.sh` across the corpus after each
   migration and require it unchanged. (It is the only place the `TESL_ZERO_COST_PROOFS`
   switch lives, and it is not yet wired into `ci.sh`. Note that proof erasure is now
   unconditional, so the 0/1 toggle no longer changes compiler output; the script's value is
   the source→Racket differential it performs, not the env-var flip.)
4. **Diagnostics unchanged.** For validation-pass migrations, the diagnostic snapshots
   (`reduce_language_size.md` Phase 0) stay byte-identical.
