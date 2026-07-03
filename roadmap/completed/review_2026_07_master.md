# Close the 2026-07-02 external review — master tracker & plan

Source: `EXECUTIVE-REVIEW-2026-07.md` + `TECHNICAL-REVIEW-2026-07.md` (repo root).
Goal: create a roadmap item per issue, then close every one. Anything not fully
closable now is carved down to the maximum and the remainder moved to
`roadmap/later/` with a clear item (never a silent defer).

## The one root class (fix this and most instances die)

> Soundness-critical checks are hand-written, **non-total** AST traversals that
> **fail open**, decide by **surface spelling**, or cover one surface form but not
> its sibling — and because proofs are **erased** there is no runtime backstop, so
> an escaped check is a silent production forgery.

The sound *cross-function* proof engine (`proof_key`, `validation_common.ml:259`)
is fine. The holes are all in the *boundary-minting* validators. The primary fix
is therefore **structural**: make those traversals total + fail-closed (remove
`| _ -> ()` / `[else #t]` leaves so OCaml exhaustiveness forces every future AST
variant to be classified), collapse duplicate deciders, and add a metamorphic
regression net (wrap any accepted `ok`/return in `transaction{}`/`Maybe`/ctor and
assert the verdict is unchanged).

## Issue register (each row = an issue; "Item" = the file that owns the fix)

| ID | Sev | Issue | Item | Status |
|----|-----|-------|------|--------|
| PF-3/4, PFC-1 | Crit | `transaction{}`/`with`-wrapped `check` mints unrelated fact | soundness_fail_open_validators | fix now |
| PF-5 | Crit | `establish` wrapped in `transaction{}` returns wrong Fact unchecked | soundness_fail_open_validators | fix now |
| PF-6 / AUTH-1 | Crit | `auth` wrapped in wrapper block = total auth forgery | soundness_fail_open_validators | fix now |
| PFC-2 | Crit | plain `fn` mints via `Maybe (T ? P)` / `Either L (T ? P)` | soundness_fail_open_validators | fix now |
| F1/F2 | Crit | `FromDb` provenance forged on `-> T ? FromDb` named-pack form | soundness_fail_open_validators | fix now |
| SHADOW-1/2/3 | Crit/High | no-shadowing walker misses ctor-arg / `fail`-msg / lambda-in-ctor | soundness_fail_open_validators | fix now |
| EE-1 | Med | existential enforcement bypassed by non-variable wrapper | soundness_fail_open_validators | fix now |
| SC-01 | Low | ForAll conjunction comparison order-sensitive (string compare) | soundness_fail_open_validators | fix now |
| CAP-COMPOSE | High | `main` grant not checked ⊇ union of reachable `requires` | capability_completeness | fix now |
| CAP-UUID | High | `uuid` uncharged statically (dual-registry drift) | capability_completeness | fix now |
| DRIFT-1 | High | `cli.args` typechecks but unbound at runtime | capability_completeness | fix now |
| CAP-01 | High | qualified-name effectful call escapes transitive charge | capability_completeness | fix now |
| AUTH-VIA | High | auth `via` clause unvalidated at frontend | auth_via_boundary | fix now |
| LB-01 | Med | `exposing` not enforced for facts under bare `import Mod` | library_exposing_facts | fix now |
| TS-ORD/EQ | High | ord/eq on `Maybe`/functions/records typechecks → runtime crash | completed/type_decidability_ord_eq | LANDED 2026-07-03 (closed built-in Ord/Eq, no type classes); cross-module 1b → next/eq_ord_generic_soundness |
| NT-07 | Med | `Int` bignum silently narrowed at DB/JS boundaries | int_boundary_narrowing | boundary guard now; type-level bounded Int → later |
| DOC-TEMPLATES | High | `tesl init` scaffolds don't compile (envRead) | docs_first_touch | fix now |
| DOC-FAQ | High | FAQ teaches non-compiling syntax | docs_first_touch | fix now |
| DOC-COST | Med | "zero-cost / no allocation" overstated | docs_first_touch | fix now |
| DOC-OTLP | Low | stale "OTLP not implemented" text | docs_first_touch | fix now |
| DOC-SPEC-COMMENTS | Low | §7.13 example uses `--` comments (Tesl uses `#`) | docs_first_touch | fix now |
| TOOL-AGENTCTX | High | `agent-context` drops all linter warnings | docs_first_touch | fix now |
| TOOL-FMT-HINT | Med | `tesl fmt <file>` remediation string points at non-existent cmd | docs_first_touch | fix now |
| TOOL-DBG-HELP | Med | `debug-inspect` absent from `--help` | docs_first_touch | fix now |
| TOOL-MCP-COORD | Med | MCP README wrong coord convention (1-based vs 0-based) | docs_first_touch | fix now |
| VER-PROP | High | property tests pass vacuously (no min-success floor) | verification_methodology | fix now |
| VER-MUT | High | mutation CI single-file; `scored=0 → 100%` bug | verification_methodology | scored-bug now; corpus coverage → later |
| VER-METAMORPHIC | High | no generative/metamorphic/differential program testing | verification_methodology | metamorphic net now; fuzzer+witness backstop → later |
| ARCH-SEAM | High | "swappable Rust/Zig runtime" claim false; no lowering IR | architecture_trajectory | correct claims now; IR seam → later |
| ARCH-CAP-NARROW | Med | runtime capability grant is app-wide union, not per-handler | architecture_trajectory | later (attempted+reverted; needs design) |
| ARCH-ADOPTION | High | adoption enablers all discarded vs stated adoption goal | architecture_trajectory | strategy note now; work → later |
| SEC-TELEMETRY | Med | telemetry ambient network egress (no capability) | architecture_trajectory | documented tradeoff; opt-out → later |
| SEC-SSE-CORS | Low | SSE hardcodes `ACAO: *` on credentialed stream | docs_first_touch | fix now |

## Execution plan (ordered by leverage)

1. **Structural class fix** (`soundness_fail_open_validators`): make
   `validate_ok_expr` (proof_checker.ml:552) total + fail-closed — descend into
   `EWith{Database,Capabilities,Transaction}`, explicitly enumerate leaves, delete
   the `| _ -> ()`. Apply the same gate that guards `RetAttached` proof-minting to
   `RetNamedPack` (kills PFC-2, F1/F2). Make the shadow walker total. Normalise
   ForAll comparison through the structural key. Descend existential enforcement.
2. **Metamorphic regression net** (`verification_methodology`): a test that takes
   the accepted-`ok` corpus and re-wraps each in `transaction{}` / `with` / a ctor
   and asserts the verdict is unchanged — the automated guard for the whole class.
3. **Capability completeness** (`capability_completeness`): whole-program grant ⊇
   reachable requires; charge `uuid`; resolve/charge qualified calls; make
   unimported bare names an error (`cli.args`).
4. **Auth `via` validation** (`auth_via_boundary`): add the auth analogue of
   `check_capture_proof_via`.
5. **Library `exposing` for facts** (`library_exposing_facts`).
6. **Ord/Eq fail-closed** + **Int boundary guard** (instance fixes; type-class /
   bounded-Int stories carved to `roadmap/later`).
7. **Docs / first-touch / tooling** (`docs_first_touch`): templates compile, FAQ
   fixed, cost claim corrected, agent-context includes lint, help/hint/coord fixes.
8. **Verification methodology**: property min-success floor, mutation scored-bug.
9. **Architecture/trajectory**: correct the false claims now; move IR seam,
   per-handler capability narrowing, telemetry opt-out, and adoption work to
   `roadmap/later`.

## Final status (2026-07-02)

**Closed + verified this pass** (repro rejected, control accepted, `--check-all
example`=99 & `tests`=38 green, `compiler/test/test_review75_reviewfixes.ml`
green, full `dune test` shows no new failures — only the pre-existing
`elm-proof-surface` 3/5/8 that fail identically on the untouched baseline):

- **PF-3/4/5/6, AUTH-1, PFC-1** — the CRITICAL cluster. `validate_ok_expr`
  (`proof_checker.ml`) and the `establish` fact-constructor walks now descend into
  `EWith{Database,Capabilities,Transaction}`; the `ok`-proof validator is now a
  total, `| _ -> ()`-free match (fail-closed for future AST variants).
- **SHADOW-1/2/3** — the no-shadowing (V001) walk no longer treats `EConstructor`
  args / `EFail` messages as no-ops; they descend like every other form.
- **SC-01** — ForAll conjunction comparison uses an order-insensitive normal form.
- **AUTH-VIA** — new `check_auth_proof_via` mirrors `check_capture_proof_via`
  (existence + kind + predicate-coverage of the endpoint auth `via` target).
- **TOOL-AGENTCTX** — `agent-context` now folds in linter findings.
- **TOOL-DBG-HELP** — `debug-inspect` is in `tesl --help`.
- **VER-MUT** (scored=0 bug) — reports "n/a" instead of a false 100%.
- **DOC-TEMPLATES / DOC-FAQ / DOC-COST / DOC-OTLP / DOC-SPEC-COMMENTS /
  TOOL-MCP-COORD** — templates compile (2/2), FAQ + best-practices fixed, proof
  cost claim corrected to match §4.3, OTLP text de-staled, spec `tesl` blocks use
  `#`, MCP coord convention corrected.

**Carved to `roadmap/completed/review_2026_07_deferred.md`** (maximum done now, precise
reason each needs its own pass — see that file): PFC-2 (container-wrapped minting —
direct forms gated; container needs engine proof-lifting), F1/F2 (FromDb named-pack
provenance), EE-1, CAP-COMPOSE/UUID/DRIFT-1/CAP-01, LB-01, TS-ORD/EQ (type-classes),
NT-07, VER-PROP, the generative-fuzz/witness-backstop harness, ARCH-SEAM /
ARCH-CAP-NARROW / ARCH-ADOPTION, SEC-TELEMETRY, SEC-SSE-CORS, TOOL-FMT-HINT.

## Verification gate for every fix
`cd compiler && dune build` → run the specific repro **and** its passing control →
`dune test` (frontend) → `./compile-examples.sh` (example + Racket sweep, the
authoritative green check). Full `ci.sh` before declaring the batch done.
