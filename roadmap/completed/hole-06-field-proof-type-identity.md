# Hole #6 — field-proof registry keyed by bare field NAME, not (type, field)

**Status:** deferred from the 2026-07-03 fix pass (needs a proof-pass refactor). CONFIRMED live.
**Severity:** critical (cross-type proof forgery / auth bypass via a shared field name).

## The hole
`build_field_proof_map` (validation_common.ml:1768) keys proof-carrying record/entity
fields by the **bare field name** (`f.name`), discarding the declaring type. The
consumer, the `EField` arm of `carried_proofs_of_expr` (validation_structural.ml:154),
does `List.assoc_opt field !field_proof_registry` with **no type resolution of the
receiver object**. So a proof declared on `TypeA.token` is credited when reading
`someB.token` for an unrelated `TypeB` that has a plain `token` field.

Repro (compiles clean today, 0 error diags):
```tesl
record Privileged { token: String ::: Admin token }
record Public     { token: String }              # no proof
fn needAdmin(s: String ::: Admin s) -> String = "admin: ${s}"
fn forge(evil: String) -> String =
  let p = Public { token: evil }                  # never validated
  needAdmin p.token                               # accepted — Admin forged
```
Control: rename `Public.token` → `publicToken` and it is correctly rejected (V001),
isolating the shared field spelling as the sole cause.

## Why it was deferred
The sound fix keys the registry by `(declaring-type, field)` and, at the `EField`
lookup, resolves the receiver's **type** to select the right entry. But
`carried_proofs_of_expr` runs in the proof pass with **no `type_env`** — it cannot
currently resolve `p`'s type. A fail-closed shortcut ("refuse to credit any field
name shared across types") is NOT viable: the corpus reuses field names heavily
(`title` on 22 types, `body`/`content` on 8, `user` on 15), several proof-carrying,
so it would reject legitimate reads en masse.

## Fix (class-level, per close_fail_open_without_runtime_layer.md)
Thread the receiver's resolved type into the field-proof lookup:
1. Give `carried_proofs_of_expr`/`subject_of_expr` access to the same `type_env`
   the checker already computes (or run this specific check inside `checker.ml`'s
   EField handling, which HAS the receiver type).
2. Re-key `field_proof_registry` as `((type_name, field_name) -> proof)`.
3. At `EField { obj; field }`: resolve `obj`'s type `T`; credit the proof only for
   the `(T, field)` entry. If `obj`'s type is unresolved → **fail closed** (do not
   credit — Option A) with a platinum message ("cannot infer the type of `obj`, so
   the field proof cannot be established here; bind via a `check`").
4. `subject_of_expr`'s `EField` subject should likewise incorporate the type, not
   just the syntactic `obj.field` string.

## Verification
- forge.tesl above → V001 (rejected).
- Rename control still passes.
- Full corpus (92 files) + `dune test` stay green; the `title`/`body`/`user`
  proof-carrying reads in the lesson corpus must still type-check.
