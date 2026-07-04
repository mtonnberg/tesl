# Hole #12 — an imported function's declared `requires` is trusted UNVERIFIED

**Status:** deferred from the 2026-07-03 fix pass (needs cross-module body re-check; module-ordering constraint). CONFIRMED live.
**Severity:** high (undeclared/ungoverned effect — dbWrite / httpClient — laundered through a module import).

## The hole
When module A `import`s module B, A trusts B's functions' **declared** `requires`
and never re-verifies them against B's bodies. So a B function that lies —
`fn sneakyWrite() -> Int requires [] = insert Todo {…}` (declares no caps, performs
`dbWrite` + `time`) — is caught when B is compiled **alone** (V001), but an importer
that only compiles A sees the honest-looking `requires []` and calls it from a
`requires [dbRead]` handler, performing an ungoverned write.

Repro (both files in one dir):
- `Evil.tesl` alone → V001 "`sneakyWrite` uses privileged operations … [dbWrite, time] … does not declare them".
- `App2.tesl` (`import Evil exposing [sneakyWrite]`; `fn readOnly() requires [dbRead] = sneakyWrite()`) → **0 error diags** (launder).

The runtime cannot compensate: the ambient capability check is against the whole-app
UNION (capability.rkt CAP-A2 documents that per-frame narrowing was reverted), which
never receives the omitted cap.

## Distinction from hole #13 (already fixed)
#13 was capability *aliasing* (`f: (…requires clock)` stripping a declared user
alias from propagation) — fixed by not stripping declared caps in
`build_func_capability_map`. **#12 is different**: the imported declaration is
*honestly propagated but is itself a lie* the importer never checks.

## Why it was deferred
The clean fix — compute each imported function's **actual** needed capabilities from
its body (`collect_needed_capabilities`) instead of trusting its declared `requires`
— is blocked by module ordering: `load_imported_func_caps` lives in
`validation_common.ml`, but `collect_needed_capabilities` lives in
`validation_capabilities.ml`, which `open`s `validation_common` (so common cannot
call it — circular). Resolving this needs either moving the actual-cap computation,
or a whole-program build that compiles every reachable module.

## Fix (choose one)
- **(A) Verified-caps propagation:** relocate the actual-cap computation so the
  imported-func-caps builder returns `collect_needed_capabilities(fd.body)` (with the
  imported module's own func/param cap maps) UNIONed with — or replacing — the
  declared caps. A lying `requires []` then contributes its real `[dbWrite]` to the
  importer, forcing the caller to declare it. Handles transitive imports by building
  the imported module's func-cap map first.
- **(B) Whole-program check:** the build/`ci.sh` gate compiles every module in the
  project (not just the entrypoint), so B fails on its own. Cheaper to implement but
  only closes it at the project boundary, not for a single-file `--check`.

Prefer (A) — it makes `--check <importer>` sound in isolation, matching the "compiler
is the sole contract" posture. See close_fail_open_without_runtime_layer.md for the
broader "cross-module = re-check or confine" principle.

## Verification
- App2.tesl → V001 (caller must declare dbWrite, or Evil rejected).
- httpClient egress variant and 2-hop chain → rejected.
- The legitimate multi-module corpus (example/kanel/*, example/chat/*) stays green.

## Status: DONE — 2026-07-04
Fix (A) — verified-caps propagation — landed in two commits:

- `f8b4b67` (behaviour-preserving): relocated `collect_needed_capabilities`,
  `build_func_capability_map`, `build_param_capability_map` and the effect tables
  from `validation_capabilities.ml` into `validation_common.ml`, resolving the
  circular `open` that blocked the loader from computing an imported body's caps.
- `c47bee2` (the fix): `load_imported_func_caps` now RE-VERIFIES each imported
  function — computes its body's ACTUAL capabilities via
  `collect_needed_capabilities` and UNIONs them with the declared row, iterated to a
  FIXPOINT over the imported module's own call graph (the 2-hop lie) and recursively
  through its transitive imports (cycle-guarded by a `visited` set). A lying
  `requires []` now contributes its real effect to the caller, which must declare it.

**Verify:** direct lie (`App2` importing `Evil.sneakyRead`, `requires []` + `env`) and
the 2-hop chain (`App3`/`EvilChain`) are REJECTED ("uses privileged operations and
callees requiring [envRead] but does not declare them"); the honest passthrough
(`AppOk`) and the declared-capability remediation (`App2Fixed`) COMPILE — the
diagnostic leads to fixable code, not a dead-end (the importer additionally imports
`Tesl.Env exposing [envRead]` to bring the capability into scope, the pre-existing
P001 rule). Committed test `test_hole12_cross_module_caps.ml` (writes imported +
importer to a temp dir; in-process compile). Corpus `--check-all`: example 92/92,
tests 38/38 (no over-rejection of the honest multi-module corpus — kanel/chat).
`dune test` green bar the known Racket 8.18/9.2 app-server `.zo` version-mismatch
integration flakes (see `align-dev-shell-racket-9.2.md`). S7 = 135 kills.
