# Generic Eq/Ord soundness — closed built-in constraints (no type classes)

## Status (branch `worktree-eqord-generic-soundness`)

The generic-comparison soundness hole (roadmap `#2`, `completed/type_decidability_ord_eq.md`)
is closed **fail-closed** by two layers. Neither introduces user-facing type classes:
no `class`/`instance`, no `=>` surface syntax, no dictionaries. It is Jones-style
*qualified types* restricted to the fixed, built-in predicate set `{Ord, Eq}` — invisible
to developers except as a clearer error at a genuinely-wrong call.

- **LANDED — Layer 2 (runtime backstop, all cases).** `tesl-equal?`
  (`tesl/private/runtime.rkt`) replaces `equal?` for `==`/`!=` emission
  (`emit_racket.ml` `emit_binop`). It raises a defined Tesl error on a **function
  operand** instead of `equal?`'s silent reference-identity result — closing the one
  *silent-wrong-answer* case. `<`/`>`/… on a function already crash loud (Racket
  contract), so they need no guard. Deliberately a **top-level** operand check, not a
  deep structural scan: Tesl value structs embed procedures in their metadata (e.g. a
  `record-field-spec` `checker`), so a deep "contains-a-procedure" walk would
  false-positive-crash valid record equality. Composite coverage is the static layer's
  job.
- **LANDED — Layer 1 (compile-time, same-module).** Closed built-in `Ord`/`Eq`
  obligations are captured from a fn body and discharged at each call site once the type
  is concrete. A generic helper (`fn genLt(a,b) = a < b`) still compiles; `genLt f g`
  with `f,g : Int -> Int` is **rejected at the call site** — the S14b residual, closed
  for callees defined in the same module.
- **NOT LANDED — Layer 1b (compile-time, cross-module).** A generic comparator imported
  from another module (e.g. `List.member fn xs`, `List.maximum funcList`) is not yet
  rejected at compile time, because the importer rebuilds the callee's scheme from its
  annotation and does not re-check its body (there is no interface serialization). Such
  misuse is still caught **at runtime**, fail-closed, by Layer 2 (`==`) / the loud `<`
  crash. See "Best way forward" below.

## Design (Layer 1 — additive, no change to existing inference)

Closed predicate set `Ord`/`Eq`, reusing the existing instance classifiers `ty_is_ord`
/`ty_is_eq` (`checker.ml`) unchanged. The mechanism is three additive hooks + one pass:

1. **Harvest** — `infer_binop` (`checker.ml`): when a `<`/`==` operand is *non-ground*,
   append `(POrd|PEq, operand-ty)` to a per-fn accumulator `ctx.ord_eq_acc`. The existing
   ground check is untouched.
2. **Finalize** — end of `check_func_decl`: convert the accumulated operand types (body
   form: type params are lowercase `TCon "a"`) into the scheme's **rigid** vars via the
   same name→rigid map `decl_scheme` uses, and store in `ctx.ord_eq_constraints`
   (fn-name → obligations). Unattributable operands (stray unification var / unknown
   name) are dropped, not stored (`constraint_to_rigid`).
3. **Record calls** — `check_expr`'s generic-call path *and* `infer_direct_call`: record
   `(callee-name, resolved arg types, loc)` into `ctx.ord_eq_calls`. Arg types are read
   straight off the callee's instantiated (and now unified) type — no re-inference.
4. **Discharge** — `check_ord_eq_calls`, run after the whole module is checked (so all
   obligations are known → forward refs / mutual recursion handled). For each recorded
   call to a constrained callee: `instantiate_with_map` the scheme (rigid→fresh),
   unify against the recorded arg types, and for each obligation check the now-concrete
   type against `ty_is_ord`/`ty_is_eq`. **Fail-closed:** a concrete non-instance is
   rejected; a still-generic obligation is left for the enclosing fn / the runtime
   backstop. (`type_system.ml`: `instantiate_with_map`, `apply_int_map`.)

### Instance set is unchanged
No per-type "implementation" is written — comparison is one primitive; `ty_is_ord`
/`ty_is_eq` only *classify* which types may be compared. Ord = `{Int, Float,
PosixMillis}` + newtypes over them; Eq = everything without a function component
(records/ADTs/containers recursed). Derivatives (`type ProductId = String`) inherit via
alias resolution. **String stays Eq-only (not Ord)** — deliberately out of scope (a
separate one-line policy knob on `ty_is_ord`).

### `:::` proof refinements — no interaction
A `:::` refinement is erased from the HM `ty` (carrier `Int` → `TCon "Int"`; the proof
lives in `binding_meta_env`). So a refined value compares exactly like its carrier, and
Layer 1 (which fires only on generic operands) never sees it. Verified: corpus refined-Int
comparisons still pass.

## Verification done (OCaml-only; no Racket run here — see caveat)

- `dune build @all` = 0 (lib, bin, all test executables compile).
- `--check` fixtures: `genLt f g` / `genEq f g` REJECTED; `genLt 1 2`, `myGt`/`myEq` on
  `Int` ACCEPTED.
- `--check-all` over `example/`, `tests/`, `tesl/` → **0 over-rejections** (no new
  "reaches a generic" errors); confirms no valid generic helper (`member`, `maximum`,
  `minimum`, …) is broken.
- `test_wave2_soundness.ml` F-decidable-comparison group: green (43 tests), incl. 4 new
  Stage-3 cases.
- `tesl-equal?` guard logic unit-checked in isolation.
- **20 example `.rkt` + `list-derived.rkt` snapshots regenerated** for the
  `equal?`→`tesl-equal?` emit change (verified against the OCaml exact-match test).

### CAVEAT — full Racket gate not run on this branch
The `tesl` Racket collection resolves through a shared path, so `./compile-examples.sh`
/ `dune test` integration / `raco` compile modules other worktrees are editing and race
the main checkout. **Run the full gate (`./compile-examples.sh`) on this branch in a
clean/idle environment before merging.** Expected new-but-benign diff: the regenerated
snapshots + the runtime backstop.

## Best way forward — Layer 1b (cross-module compile-time)
Harvest obligations for imported/lifted generic comparators too, so `List.member fn xs`
is rejected at compile time (not only at runtime). Since imported source is re-parsed
(`load_imported_func_sigs` / `load_lifted_sigs`), run the same harvest over imported
bodies during scheme reconstruction and key `ord_eq_constraints` by the qualified name
(`List.member`). Reuse the same `ty_is_ord`/`ty_is_eq` — not a divergent shadow. Add the
planned `member x xs` / `maximum xs` accepted + `List.member fn xs` rejected tests.

## Files
- `compiler/lib/type_system.ml` — `instantiate_with_map`, `apply_int_map`.
- `compiler/lib/checker.ml` — `ord_eq_pred`, ctx fields (`ord_eq_acc`,
  `ord_eq_constraints`, `ord_eq_calls`), `infer_binop` harvest, `constraint_to_rigid`
  + `finalize_ord_eq_constraints`, call recording, `check_ord_eq_calls` (discharge).
- `compiler/lib/emit_racket.ml` — `emit_binop` emits `tesl-equal?`.
- `tesl/private/runtime.rkt` — `tesl-equal?`.
- `compiler/test/test_wave2_soundness.ml` — Stage-3 cases.
- Regenerated snapshots: `example/learn/*.rkt` (20), `tesl/list-derived.rkt`.

## Status: DONE — 2026-07-04
Layer 1b landed in commit `891ac97` (generic-Eq/Ord soundness was already closed
fail-closed by the landed Layers 1+2; 1b is the compile-time cross-module increment).

`harvest_fd_ord_eq` + `load_imported_ord_eq_constraints` (checker.ml) re-parse each
import and, for every imported `fn`, record an Eq/Ord obligation for each `<`/`==`
operand that is a bare PARAMETER of a generic type — in the callee scheme's rigid
vars via the same `constraint_to_rigid`/`finalize_ord_eq_constraints` machinery,
keyed by qualified + plain name. `check_module` folds these into
`ord_eq_constraints` (local entries win) before `check_ord_eq_calls`, which
discharges them against a recorded call's argument types exactly like the
same-module case. `List.member f fs` with `f : Int -> Int` is now a COMPILE error
("equality is not defined for `Int -> Int` … via `List.member`"); `List.member x xs`
at `Int` compiles.

**Scope carve (non-soundness):** this covers comparators that compare a bare
PARAMETER (`member`/`contains` — the flagship documented case). `maximum`/`minimum`
compare case-binder ELEMENTS, not parameters; harvesting those statically needs full
body re-inference of the import — a large, delicate change to the checker's core
inference path — for an earliness-only gain, since those cases are already
fail-closed at RUNTIME by Layer 2 (the loud `<` crash / `tesl-equal?`), exactly as
this item's own Layer-2 design specifies. Left to Layer 2 by design.

**Verify:** `test_f_import_member_fn_rejected` / `_int_accepted`
(test_wave2_soundness F-decidable group) green; corpus `--check-all` example 92/92,
tests 38/38 (no over-rejection of the legitimate `member`/`contains` corpus); S7 =
135. **CAVEAT (unchanged from this item):** the full Racket gate (`compile-examples.sh`
on Racket 9.2) still needs a clean-env run before merge — see
`align-dev-shell-racket-9.2.md`.
