# 2026-07 review — OPEN items only

Closed work has moved to `roadmap/completed/review_2026_07_closed_items.md` (and the
per-topic files in `roadmap/completed/`). This file lists only what remains. Each is
unblocked but touches soundness-critical or broad-impact code, so it needs its own
verified pass — a rushed change would risk false-positives/regressions and worsen DX.

### Larger engineering (multi-step)
1. **PFC-2 — container-wrapped proof minting** (`RetMaybeAttached`:
   `Maybe (v: T ::: P v)` / `Maybe (T ? P)` / `Either L (T ? P)` / custom eithers).
   A plain `fn` can mint through the container; the direct `-> T ? P` / `-> T ::: P`
   forms are already gated. **Concrete prerequisite discovered 2026-07-02
   (3rd pass), NOT yet fixed — do NOT ship a producer-only check:** a sound producer
   check ("the container's success-payload must carry the inner proof") would REJECT
   the shipped reference example `lesson52` (`findMin`/`findMax`/`findMinAlt`),
   because **ADT field proofs do not propagate to pattern binders today**. Verified:
   with `Node (value: Int ::: IsPositive value)`, `case t of Node l cur r ->
   needPositive cur` FAILS ("`cur` does not statically satisfy `IsPositive cur`").
   So findMin's `Right cur` is accepted only because `RetMaybeAttached` producers are
   currently UNCHECKED — findMin relies on this very hole. The correct fix is TWO
   parts, in order:
     (a) **field-proof propagation through pattern matching** — destructuring an ADT
         constructor whose field carries `::: P` must give the bound variable that
         proof (in `pattern_bindings`/`extend_case_envs` / the checker's
         `bind_pattern_vars` + `binding_meta_env`). This is a broad engine change
         (affects all pattern matching) and makes field proofs actually load-bearing
         instead of decorative;
     (b) THEN the **container-aware producer check** (resolve which constructor arg
         the `? P` annotates — `Something`/`Right`/`CustomRight`, e.g. via the fact's
         declared subject type — and require that payload to carry the proof via the
         engine), which now ACCEPTS findMin (cur genuinely carries the proof via (a))
         and REJECTS `Something (0-999)`.
   A producer-only check without (a) either false-positives findMin (a DX
   regression) or, if it "allows all variable payloads", is trivially unsound
   (`let bad = 0 - 999; Something bad`). Highest-value remaining; needs the engine
   pass below.

   **PFC-2b — ADT field proofs were entirely DECORATIVE (the root under PFC-2).**
   A constructor field declared `value: Int ::: IsPositive value` was (i) NOT
   enforced at construction and (ii) NOT propagated at destructuring. The sound fix
   is THREE interconnected parts, in order:
     (a0) **enforce field proofs at ADT construction — DONE (4th pass, 2026-07-02).**
          `Node Leaf 5 Leaf` / `Node Leaf (0-5) Leaf` are now REJECTED (the value
          must carry `IsPositive`); a proven value is accepted.
          `build_adt_ctor_field_bindings` + `check_ctor_field_proofs` in
          `check_record_field_proof_construction` (mirrors the record path via
          `check_call_proofs`, positional alignment). Zero corpus regressions
          (99+38 green; lesson52 already constructs with proven values). Message is
          clear and strictly better than the prior silent accept. Regression
          R75_ADTFIELD.  **This closes the "fabricate an ADT with an unproven
          proof-field" forgery class.**
     (a)  **propagate field proofs on destructuring — STILL OPEN.** `Node l cur r`
          must give `cur` the field's `::: P` proof (only sound now that a0 holds).
          Mapped path: extend `build_field_proof_map` (validation_common.ml) to ADT
          variant fields, then teach the multi-field `PCon` case in
          `check_expr_call_proofs` (validation_proof.ml:1024) — and the sibling
          `ECase` handlers in `validation_advanced.ml` walk_expr (~517) and
          `checker.ml` (~2027 `binding_meta_env`) — to add each pattern-bound var's
          field proof (renamed to the binder subject). Monotonic (adds proofs → only
          accepts more), so low regression risk, but multi-site.
     (b)  **container-aware producer check** for `RetMaybeAttached` — STILL OPEN.
          Resolve which constructor arg the `? P` annotates (`Something`/`Right`/
          `CustomRight`, e.g. via the fact's declared subject type), then require
          that success-payload to carry the proof via the engine. With (a) in place
          this ACCEPTS findMin (`Right cur`, cur carries the proof) and REJECTS
          `Something (0-999)`.
   (a)+(b) remain a dedicated engine pass; (a0) — the foundational soundness gap —
   is landed.
2. **TS-ORD/EQ — principled decidability** (`type_decidability_ord_eq.md`). `<`/`==`
   on `Maybe`/functions/records typecheck → runtime crash; the shadow inferencer
   fails open. Fix: `Eq`/`Ord` as qualified types in HM generalization/instantiation
   (a blunt fail-closed guard over-rejects valid generic code).
3. **VER-METAMORPHIC** — grammar-based program fuzzer over `--check`, a metamorphic
   property (wrap any accepted `ok`/return in `transaction{}`/`Maybe`/ctor, assert
   verdict unchanged), and a runtime proof-witness differential oracle (backstop for
   erased proofs). Durable fixtures for the fixed class already exist (`test_review75`).
4. **Architecture** — the lowering-IR seam itself (ARCH-SEAM engineering; the false
   *claim* is corrected); **ARCH-CAP-NARROW** per-handler runtime capability narrowing
   (was attempted + reverted; needs the supplied-capability design first);
   **ARCH-ADOPTION** package manager / playground / non-Nix distribution (owner's call).

### Moderate — additive checks needing careful false-positive verification
5. **CAP-01** — qualified-name effectful calls escape the transitive capability
   charge (symmetry with unqualified calls in the effect walk). See
   `capability_completeness.md`.
6. **CAP-UUID** — `uuid` uncharged statically; **currently masked** by a separate
   `unit -> T` parse/type bug that makes `UUID.v4/v7` uncallable (fix together).
7. **DRIFT-1** — `cli.args` typechecks unimported but is unbound at runtime; the
   import-scope guard skips lowercase module prefixes (`cli`). Must not disturb other
   lowercase-prefixed stdlib names.
8. **LB-01** — under bare `import Mod`, `exposing` is not enforced for fact names.
   **Encapsulation leak, NOT a forgery** (fact ownership still blocks minting a
   non-exported predicate; a consumer can at most NAME one it can never satisfy).
   Fix in the import/predicate-availability resolution. See `library_exposing_facts.md`.
9. **NT-07** — `Int` (bignum) silently narrows at Postgres/JS-codec boundaries; add a
   boundary range-check (loud error, not truncation) + tighten the runtime oracle so
   `Int` rejects flonums. See `int_boundary_narrowing.md`.
10. **VER-PROP** — a `where`-guarded `property` passes vacuously; add a
    min-effective-iterations floor in the `property` emit (touches every property
    test's emitted loop — needs a runtime test pass).
11. **SEC-TELEMETRY** — opt-out/allowlist for the ambient OTLP network egress.
    **SEC-SSE-CORS** — make the SSE `Access-Control-Allow-Origin` configurable rather
    than hardcoded `*` on a credentialed stream (both `dsl/*.rkt` runtime changes).
