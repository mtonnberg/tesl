> **STATUS: COMPLETE (2026-06-26).** Phase 1 module_facts core shipped (W1/W2) and
> extended on 2026-06-26 to fold endpoints / entities / codecs into the
> module_facts record (built once, threaded into check_api_endpoint_structure /
> check_entity_structure / the codec passes), preserving check order + diagnostic
> byte-identity. Phase 2 mechanical sub-walks migrated onto the new
> `fold_children_env`. Intentionally NOT done (documented, low/negative value):
> cross-walk FUSION (no clear byte-safe win), threading facts into
> check_name_shadowing (local-only names vs imported-inclusive mf_funcs → not
> byte-safe), and the ir.ml endpoint-dedup non-task (would couple validation to the
> optional TS/Elm exporters). Gates green.

---

# Smaller Core — Validation-pass consolidation

> Part of the **Smaller Core** theme — see `smaller_core.md`. This item **splits**: Phase 1
> (the shared `module_facts` record) is **visitor-independent** and high-value and can start
> now; Phase 2 (recursion onto the visitor) is a **follow-on** that depends on
> `ast_visitor_framework.md` and benefits from `reduce_language_size.md`. Phase 1 is the
> standalone win; Phase 2's leverage comes from the visitor it rides on.

## Context

After type-checking, Tesl runs a large semantic-validation suite: ~8.9k lines across seven
`validation_*.ml` files, orchestrated by `validation.ml`'s `check_module` (an 84-line
driver that runs a sequence of per-check calls — a soft ~55-check count, not a hard 60).
`compile.ml` invokes `Validation.check_module` in 4 pipeline branches.

Each pass walks the AST independently and several re-extract the same structural facts
(endpoints, entities, field→proof maps, codecs). There *is* already some sharing — e.g.
`carried_proofs_of_expr` is defined once (`validation_structural.ml:22`) and reused by the
proof and advanced validators — so this is a *consolidation*, not a rescue.

## The key architectural realization

The redundancy is of two kinds, addressed by two different mechanisms:

1. **Repeated traversal boilerplate** — each pass hand-walks the AST. This is the same
   boilerplate the `ast_visitor_framework.md` item removes; once a shared `map`/`fold`/
   `iter` exists, the validation sub-walks collapse onto it.
2. **Repeated structural-fact extraction** — within the validation suite the same facts are
   rebuilt repeatedly: `build_func_info`/`build_fields_map`/`build_ctor_info`/
   `build_field_proof_map` are recomputed **13×** across the passes, and entity/field/proof
   maps are derived by multiple checks. These can be computed **once** into a `module_facts`
   record and passed to the checks that need them. (Endpoint extraction also appears in
   `ir.ml:249`, but note `ir.ml`/`module_to_ir` is consumed **only** by `emit_ts.ml`/
   `emit_elm.ml` — not by the validation pipeline — so deduplicating validation against it is
   a weak target that couples validation to the optional TS/Elm exporters. The real win is
   the shared-fact record, not the `ir.ml` dedup.)

Crucially, the passes are **not** freely reorderable: they carry algorithmic dependencies
(proof-environment construction, name resolution must precede proof checks, etc.). So the
goal is to **share traversal and extraction while preserving the existing check order and
each check's decisions** — not to merge them into one monolithic pass.

## Feasibility — verified, not assumed

- The suite is real and large: `validation_proof.ml` (2419), `validation_advanced.ml`
  (1502), `validation_structural.ml` (1291), `validation_common.ml` (1200),
  `validation_capabilities.ml` (1087), `validation_names.ml` (969),
  `validation_sql_codec.ml` (445); driver `validation.ml` (~84).
- Sharing already works (`carried_proofs_of_expr` reused across files), proving facts can be
  computed once and consumed by several passes without semantic change.
- Duplicated extraction is concrete (endpoint extraction in `validation_structural.ml:453`
  and `ir.ml:249`).
- The suite is **heavily exercised** by the corpus, so consolidation regressions are
  catchable (and the diagnostic-snapshot gate makes them byte-level visible).

> This item should be sized conservatively: because some sharing already exists, the LOC win
> is moderate. The value is a smaller, more uniform validation layer that is cheaper to
> extend.

## Plan

This item **splits cleanly into two phases with different dependencies and different value.**
Phase 1 is **visitor-independent** and high-value; Phase 2 is hard-blocked by the visitor.

### Phase 0 — Gate (visitor dependency applies to Phase 2 only)
Phase 1 (the `module_facts` shared-fact record) needs only the diagnostic-snapshot gate and
can start immediately. **Phase 2** (rewriting recursion onto the visitor) must not start until
`ast_visitor_framework.md` Phase 1 has landed and proven byte-identical — that visitor is the
substrate Phase 2 builds on.

### Phase 1 — Compute structural facts once (visitor-INDEPENDENT, do early)
Introduce a `module_facts` record folding the **13×** recomputation of
`build_func_info`/`build_fields_map`/`build_ctor_info`/`build_field_proof_map` (plus
endpoints, entities, field→proof map, codecs) into a single pass, and feed it to the checks
that currently re-extract. This phase needs **no AST visitor** — only the diagnostic-snapshot
gate — so it can land independently and is where most of the value sits. No change to check
order or outcomes. (Do **not** lead with deduplicating against `ir.ml`: `ir.ml`/`module_to_ir`
feeds only `emit_ts.ml`/`emit_elm.ml`, not validation, so that dedup is the weak target. The
shared-fact record is the real win.)

### Phase 2 — Rewrite sub-walks onto the visitor; fuse co-located walks (visitor-dependent)
**Hard-blocked by `ast_visitor_framework.md`** — there is no shared traversal to rewrite onto
until the visitor lands. Reimplement each pass's mechanical recursion via the shared visitor
(keeping each check's decisions explicit). Where two checks walk the same region with no
ordering dependency between them, fuse their traversals — **without** reordering checks that
depend on each other. Re-baseline diagnostics after each step.

## Weighted pros and cons

**Pros**
- **Medium — a smaller, more uniform validation layer.** Less boilerplate, one place for
  structural facts, cheaper to add the next check.
- **Low/Medium — modest perf.** Fewer full AST walks and fewer re-extractions per compile.
- **Medium — compounding.** Directly leverages the visitor and benefits from the smaller
  core that desugaring produces.

**Cons / risks**
- **Medium — ordering/algorithmic dependencies between passes.** The chief risk; mitigated
  by preserving check order and only sharing traversal/extraction.
- **Low/Medium — modest LOC win.** Some sharing already exists; do not oversell the size
  reduction.
- **Low — diagnostics drift.** Mitigated by the byte-identical diagnostic-snapshot gate.

## Critical files

- `compiler/lib/validation.ml` — the `check_module` driver/order to preserve.
- `compiler/lib/validation_structural.ml` (`carried_proofs_of_expr:22`, endpoint extraction
  `:453`), `validation_proof.ml`, `validation_advanced.ml`, `validation_common.ml`,
  `validation_capabilities.ml`, `validation_names.ml`, `validation_sql_codec.ml` — the
  passes to migrate onto the visitor and the shared `module_facts`.
- `compiler/lib/ir.ml` (`:249`) — has duplicate endpoint extraction, but `ir.ml`/
  `module_to_ir` is consumed only by `emit_ts.ml`/`emit_elm.ml` (not validation), so this is
  a low-priority dedup target, not the flagship. The shared `module_facts` record is the win.
- `compiler/lib/compile.ml` — the 4 `Validation.check_module` call sites.
- `compiler/lib/ast_visitor.ml` — the dependency from `ast_visitor_framework.md`.

## Verification

1. **Diagnostics byte-identical.** Reuse the diagnostic-snapshot corpus from
   `reduce_language_size.md`: every validation error message and span unchanged through each
   phase.
2. **Validation tests green.** The `test_validation` suite in `compiler/ci.sh`, plus the
   full corpus (`compile-examples.sh`), pass unchanged.
3. **Order preserved.** Confirm the `check_module` sequence is unchanged (or provably
   equivalent) — no check observes facts a reordering would have changed.
