# 01-05 Item Plan

## Purpose of this document

This document should act as the execution view over the active `01-05` range.

The important update is that Item 05 is no longer an early-stage tooling item. A large part of it is already done. The plan therefore needs to separate:

- work that is already complete
- work that is still active
- work that should explicitly wait for Item 04 and Item 03

There is still no active `02` item under `roadmap/next/`, so the gap should remain explicit rather than filled with invented scope.

## Current status by item

### Item 01 — Bool canonicalization

Status: **complete**.

`compile.ml` has `legacy_bool_diagnostics` that turns any use of the `Boolean` type name into
a compile error (code `VBOOL001`) and missing `Bool` import into `VBOOL002`.
The emitter no longer accepts `"Boolean"` as a type name.
All examples, lessons, and language docs use only `Bool`, `True`, `False`.

### Item 02 — no active item

Status: intentionally absent.

- [ ] keep the numbering gap explicit unless a real Item 02 is added

### Item 03 — IR-1 semantic layer

Status: not done yet; still the foundation for the next major tooling tier.

Note: one-shot compiler queries (`--definition-json`, `--occurrences-json`, `--type-at-json`) now
exist and are used by the editor, but these are per-request compilations with no retained semantic
state. The `--ir` flag emits an AST-level JSON schema (code-generation IR), not a semantic query
layer. The retained semantic layer — module cache, stable node identity, queryable program knowledge
— has not been started.

Remaining high-level slices:

- [ ] finalize/query-review the retained semantic schema
- [ ] define the compiler query surface needed by the editor
- [ ] implement retained semantic infrastructure after Item 04 metadata stabilizes
- [ ] use IR-1 as the basis for richer references/rename/completion/field tooling

### Item 04 — bidirectional type checking

Status: **largely complete** — full `infer_expr`/`check_expr` dual entry points are live with
structured `expectation_frame` values carrying type, role, reason, and origin through the tree.
The implementation covers `if`-conditions (checked against `Bool`), top-level fn/handler/worker/
check/auth return types, record and entity literal field values, list and tuple elements,
constructor arguments, function call arguments, and case arm bodies. Expectation messages name
the structural role and give a human-readable reason for the expected type.
Tests added in `compiler/test/test_types.ml`.
Remaining: thread expectation metadata into IR-1 design (blocked on Item 03).

### Item 05 — improved tooling

Status: partially complete, with the single-file semantic tooling core mostly landed.

Completed slices:

- [x] compiler-backed diagnostics contract
- [x] formatter/linter command surface
- [x] `TESL_REPO_ROOT` contract alignment
- [x] initial compiler-emitted fixes + LSP code actions
- [x] compiler-backed local binding metadata for hover
- [x] compiler-backed definition
- [x] compiler-backed occurrences
- [x] compiler-backed references
- [x] compiler-backed `type_at`
- [x] compiler-backed single-file rename
- [x] rename correctness fixes for declaration spans / let-RHS selection
- [x] codec `via` rename correctness fix
- [x] compiler traversal through codec internals and capture parser/checker references
- [x] codec unknown target-type validation

Remaining Item 05 slices:

- [ ] expand compiler fix payload coverage beyond the first safe set
- [ ] add compiler-backed `field_at` / field semantic queries
- [ ] add type-driven field/member completions after `.`
- [ ] remove remaining editor-side semantic heuristics where compiler answers are available
- [ ] design and implement multi-file/workspace references and rename
- [ ] finish the advanced tooling work on top of IR-1 rather than on ad-hoc LSP logic

## Recommended execution order from here

The practical order is now:

1. [ ] finish Item 01 so the language surface is coherent for newcomers
2. [ ] continue only the low-risk Item 05 slices that do not depend on final checker metadata
3. [ ] land Item 04 so the checker structure and retained metadata stabilize
4. [ ] execute Item 03 IR-1 design and implementation on top of that stabilized checker shape
5. [ ] finish the remaining advanced Item 05 tooling on top of IR-1

## What should not be treated as active Item 05 work anymore

These are no longer open roadmap buckets and should not keep reappearing as if they were still pending:

- [x] rewrite-era OCaml migration work
- [x] repo-root wiring cleanup
- [x] initial code-action plumbing
- [x] basic compiler-backed definition/occurrences/references/type-at support
- [x] basic single-file rename

## Practical next-slice checklist

If work resumes immediately, the clean remaining slices are:

- [ ] Item 01: finish Bool canonicalization and docs/examples
- [ ] Item 05: extend fix/code-action coverage
- [ ] Item 05: add `field_at`
- [ ] Item 05: add field/member completions from compiler query data
- [ ] Item 04: continue bidirectional checker refactor
- [ ] Item 03: keep IR-1 design aligned with the checker changes, then implement after stabilization

## Success shape

This plan is accurate when:

- Item 05 is shown as mostly past the basics and focused on the remaining semantic slices
- Item 04 is treated as a real dependency for advanced tooling
- Item 03 is treated as the retained semantic foundation, not optional polish
- the remaining roadmap is readable as a checklist instead of a rewrite-era narrative
