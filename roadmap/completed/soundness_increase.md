# Systemically finding, closing, and preventing soundness holes

Report requested by `strategy_to_finding_soundness_holes`. Tesl's promise is that
an accepted program upholds its guarantees. A *soundness hole* is a program the
compiler ACCEPTS that then violates a guarantee — usually by failing at runtime in
a way the type/proof system claimed impossible. We have many tests and have done
reviews, yet holes keep appearing. This report explains **why they appear**, then
gives a tiered, actionable program: **(0) make whole classes structurally
impossible, (1) systematically find the rest, (2) close-and-keep-closed.**

## Root diagnosis: the checker's model ≠ the emitter/runtime's model

Almost every hole found is the SAME shape — the **checker accepts** a construct
the **emitter or runtime** does not faithfully support. Two models that should
agree are maintained SEPARATELY and have drifted:

| Hole | Checker believes | Emitter/runtime reality | Drift between |
|---|---|---|---|
| bare stdlib import (env*) | name is in the global type-env → in scope | `(require tesl/X.rkt)` only emitted if imported → `unbound identifier` | global type-env ↔ import-driven require table |
| handler param arity | the handler sig type-checks alone | `define-server` passes only the endpoint's values → arity crash | no endpoint↔handler contract check |
| ctor-import scoping | `exposing [T]` ⇒ type only | constructors were usable | scope model over-approximated |
| one-direction codec | `toJson` alone is fine | decode path absent at runtime | partial form accepted |
| stale `.rkt` snapshot | source is fine | committed `.rkt` ran OLD code, masking the break | source ↔ committed artifact |

**The lesson:** every place two representations of the same fact are maintained by
hand, they will drift, and the drift is a hole. The systemic fix is to **remove the
duplication**, not to test harder around it.

## Tier 0 — Make whole classes IMPOSSIBLE (highest leverage)

The goal isn't more tests; it's removing the conditions under which a hole can
exist. Concrete structural moves:

1. **Single source of truth for the stdlib surface.** Today a stdlib function's
   existence, its module, its required capability, and its runtime `require` live in
   ≥3 hand-maintained places (`type_system.ml` global env, `emit_racket.ml` require
   table, `validation_capabilities.ml` `var_caps`, the bare/qualified import tables).
   Replace with ONE table — `(name, module, capability, runtime-require, gated?)` —
   that the checker, the import-scope pass, the capability pass, and the emitter all
   *derive* from. Then "type-checks but unbound at runtime" / "callable without its
   capability" become unrepresentable. (This pass's env Fix A/B patched two symptoms
   of the missing single source; the structural fix is to unify the tables.)
2. **Contracts between declarations are derived, not re-stated.** Generate the
   handler's expected parameter contract FROM the endpoint (path captures + auth
   proven values) and check the handler against it — a mismatch then cannot compile.
   Same for `server … for API`, `auth … via fn` return ↔ handler input, capture↔codec.
3. **"Compiles" must entail "emits and loads".** Make it a language invariant (not
   just a test) that every accepted construct round-trips: parse → check → emit →
   `raco`-load → run. Wire a compile-and-run check per construct so a construct is
   not "in the language" until it executes. (The pass-1 `test_integration`
   exact-match extension over `example/`+`tests/`, plus the gate's Tesl-test sweep,
   are the seed; make the regen+compare a standing CI gate so artifact drift can't
   hide a break — see `snapshot_drift_gate`.)
4. **Totality of partial surface forms.** Any form the parser accepts with an
   optional/missing half (codec directions, captures, config blocks) gets a parser/
   checker completeness rule so "half a construct" cannot compile (the codec
   both-directions rule is the model).
5. **Shrink the trusted, hand-written surface.** Fewer bespoke emitter arms = fewer
   places to diverge (the surface-form lowering work; lifting stdlib bodies). A
   smaller emitter is a smaller attack surface for miscompiles.

## Tier 1 — Systematically FIND the residue

For what can't yet be made impossible:

1. **Differential generation (checker-accepts vs runtime-runs).** Generate small
   well-typed programs targeting the audit areas (unimported names; endpoint/handler
   shapes; partial forms; erasure boundary); compile AND run each; any crash is a
   hole. Prioritise the Tier-0 audit list.
2. **Fuzz the untyped boundary.** Fuzz `jsexpr->typed-value` and the parser with
   malformed/huge/deeply-nested input; assert invariants (no crash, bounded
   resources, no internal leak), not outputs.
3. **`--check` leniency inventory.** Enumerate every "deferred to runtime" path
   (e.g. HttpRequest field access) and ask "what if the runtime can't honour it?" —
   each is a candidate hole.
4. **Completeness critic each cycle.** Which constructs have NO compile-and-run
   example? which checker leniencies have no negative test? Convert each gap to a
   corpus/property entry. Silence is not coverage.

## Tier 2 — CLOSE and keep closed

1. **Negative-test corpus (must-NOT-compile), first-class.** Every found hole
   becomes a permanent `should_fail` test (see `test_review65_antagonistic`'s
   import-scope / ctor-scope / bare-stdlib groups). A fix isn't done until a negative
   test pins it.
2. **Differential parity gate.** `TESL_ZERO_COST_PROOFS=0` vs `=1` behaviour-
   identical across the corpus — the guard that erasure never silently drops a check
   (proofs are erased by default, so the static checker is the sole guarantor).
3. **Mutation testing, extended to the emitter.** `tesl --mutate` already kills
   check/auth/establish mutants; add emitter mutation (mutate `emit_racket.ml`,
   require a test to fail) so the trusted codegen is covered.

## Toward "formally impossible" (longer horizon)
- Tier 0 #1–#2 are the pragmatic form of "impossible by construction" (single
  source of truth ⇒ the divergence class cannot be expressed).
- Beyond that: a machine-checked statement of the proof-checker core's soundness;
  a typed IR whose well-formedness the emitter consumes so a miscompile is a type
  error in OCaml. Aspirational; the Tier-0 deduplication captures most of the value
  far cheaper.

## Prioritized actionable items
1. Unify the stdlib surface into one derived table (Tier 0 #1) — kills the
   env*/import/capability class structurally. **Highest ROI.**
2. Endpoint↔handler (and auth↔handler) contract derivation (Tier 0 #2) — kills the
   arity class; also see `handler_param_arity_soundness`.
3. Make snapshot regen+compare a standing gate (Tier 0 #3 / `snapshot_drift_gate`).
4. A differential well-typed-program generator (Tier 1 #1) + boundary fuzzer (#2).
5. Emitter mutation testing (Tier 2 #3).

Fold every newly-found hole into the diagnosis table; the duplication it exposes
points at the next Tier-0 unification.
