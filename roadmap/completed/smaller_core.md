# Smaller Core — umbrella theme

> **Theme.** Several `later/` items share one goal and one title prefix. This doc ties
> them together: the thesis, how they complement each other, and the order that makes each
> one cheaper than if done alone.
>
> **This is the index/umbrella for the five Smaller-Core items — not a work unit itself.**
> It has no Plan/Phases/Verification of its own; the work lives entirely in the five sibling
> docs. Do not schedule or allocate effort to this doc.
>
> **Status (2026-06-26):** all five sibling docs have been executed and moved to
> `completed/`. `ast_visitor_framework`, `validation_consolidation`, and
> `compile_time_specialization` are **done**; `reduce_language_size` and
> `lifting_implementation` shipped their high-value parts and carved the
> architecturally-blocked / lower-value remainder into `later/` (see the Index).
> This umbrella stays in `next/` as a living map — it is never itself "complete."

## Thesis

Express as much of Tesl as possible in terms of a **small, well-factored core** — so that
adding and maintaining features costs less, the trusted surface (the emitter + runtime
substrate) stays small, and the language demonstrably runs on itself. The constraint is
absolute: **the user-visible surface and behaviour do not change.** These are internal
re-expressions, verified by the differential parity net, not feature changes.

## The two anchor items sit on complementary axes

| | `lifting_implementation.md` | `reduce_language_size.md` |
|---|---|---|
| **Axis** | **Vertical** — *what is written in Tesl vs. hand-maintained in the host* | **Horizontal** — *how many primitive forms the compiler carries* |
| **Move** | Move stdlib *implementation + types* out of Racket (`tesl/*.rkt`) and the `stdlib_env` in `type_system.ml` (~202 → **~152** after the List + Either lifts), **into Tesl source** | Collapse the ~17 surface effect/sugar forms onto a **small core AST** via a desugaring/lowering pass |
| **Shrinks** | The Racket stdlib and the hand-transcribed type table (drift risk) | The back-end fan-out and the cost to add/change a surface feature |
| **Main win** | Dogfooding + zero type double-maintenance | Cost-per-feature: ~15 edit sites → ~2–3 |

They are not redundant — one reduces *host-maintained code*, the other reduces *primitive
forms*. They **meet** at two points: the `foreign fn` declaration form (Phase 2 of lifting)
and the desugaring of effect forms to function calls (Phase 3 of reduce), both of which
shrink the hand-maintained tables from opposite directions.

## The new pillars (this theme)

- **`ast_visitor_framework.md`** — **shipped** (`compiler/lib/ast_visitor.ml`): a shared
  `map`/`fold`/`iter` over the AST (plus an env-threading `fold_children_env`), replacing the
  hand-matched all-30-variant recursion in the mechanical passes (`ast.ml:97-134`).
  This was the **keystone**: it turned the other items from "touch 15 files" into "touch a
  handful," and a whole bug class ("forgot variant X in pass Y") disappears. Semantically
  load-bearing passes (e.g. `checker.ml` `infer_expr`) stay explicit by design.
- **`compile_time_specialization.md`** — the **performance** pillar. The runtime does
  per-request work the compiler already knows statically (generic JSON decode + a redundant
  re-validation walk, generic response encoding, per-field codec lookups, repeated SQL
  clause scans). Emit *type-specialized* decoders/encoders/queries instead. Distinct from
  the toolchain-speed work in `next/optimizations.md` and the proof-allocation work in
  `completed/actually-zero-cost-runtime-proofs.md`.
- **`validation_consolidation.md`** — fold the ~8.9k-line validation suite (~55–60 checks, a
  soft count — the per-check calls run as a sequence inside one `check_module`, not a hard 60) onto
  the visitor and a computed-once `module_facts` record. A follow-on beneficiary of the
  visitor framework; lower standalone priority.

## Recommended sequence (dependency DAG)

```
            ┌─────────────────────────────┐
            │ 1. AST visitor framework    │  (enabler / keystone)
            └──────────────┬──────────────┘
            ┌──────────────┴───────────────┐
            ▼                               ▼
┌───────────────────────┐     ┌────────────────────────────┐
│ 2. reduce_language_size│     │  validation_consolidation  │
│    (desugaring)        │     │  (rides on the visitor)    │
└───────────┬───────────┘     └────────────────────────────┘
            ▼
┌───────────────────────────────┐
│ 3. lifting_implementation     │
│    (+ foreign fn, its Phase 2)│
└───────────┬───────────────────┘
            ▼
┌───────────────────────────────┐
│ 4. compile-time specialization│  (performance; uses the clean core/IR)
└───────────────────────────────┘
```

Each step makes the next cheaper:
1. The **visitor** makes desugaring and validation cheap to write and refactor.
2. **Desugaring** leaves fewer core forms for everything downstream to handle.
3. **Lifting** (+ `foreign fn`) expresses the stdlib and leaf types in Tesl, emptying the
   type table.
4. **Specialization** leverages the now-clean core/IR to emit fast, type-specific runtime
   code.

The leverage compounds in this order, and the visitor first is the highest-value single
move. One edge is a genuine **hard** prerequisite, not just leverage: the visitor is required
for the **AST-recursion half** of `reduce_language_size` (rewriting the hand-rolled `Ast.expr`
traversals) and for **Phase 2** of `validation_consolidation` (the recursion migration) — there
is nothing to rewrite those passes onto until it lands. The other edges (lifting's and
specialization's dependence on the visitor, and `validation_consolidation`'s Phase 1
`module_facts` work) are soft/sequencing and can run out of order.

## Expectation-setting

These are **maintainability and performance** initiatives, not a dramatic line-count cut.
The raw OCaml/Racket shrink is single-digit-percent (see each item's sizing section); the
real payoff is *cost-per-feature*, a smaller trusted surface, and hot-path performance. If
raw LOC is the goal, `lifting_implementation.md` removes the most by moving stdlib into
Tesl.

## Out of scope (whole theme)

- LSP/editor integration and error-message quality — explicitly excluded from this theme.
- Toolchain/build/test speed — owned by `next/optimizations.md`.
- Runtime proof-struct allocation — owned by
  `completed/actually-zero-cost-runtime-proofs.md`.
- `foreign fn` as a standalone item — it lives as Phase 2 of `lifting_implementation.md`.

## Index

| Item | Status (2026-06-26) | Axis / role |
|---|---|---|
| `completed/ast_visitor_framework.md` | **done** | enabler — shared AST traversal (+ env-threading fold) |
| `completed/validation_consolidation.md` | **done** | follow-on — `module_facts` + mechanical walks folded onto the visitor |
| `completed/compile_time_specialization.md` | **done** — SQL → `later/sql-compile-time-specialization.md` | performance — specialized codec encoders + decoders |
| `completed/reduce_language_size.md` | **partial** — effect→`ERuntimeCall` + proof dedup; rest → `later/surface-form-lowering.md` | horizontal — desugar surface → core |
| `completed/lifting_implementation.md` | **partial** — List + Either lifted; rest → `later/lift-remaining-stdlib-and-foreign-fn.md` | vertical — stdlib & types into Tesl |
