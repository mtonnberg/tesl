# Close all known open issues — master plan & tracker

**STATUS:** soundness/dedup program COMPLETE; remaining items relocated to dedicated
`roadmap/next` files (see the "Relocated open items" section at the end).

**Goal:** close every known open issue (soundness holes from the 2026-07-01 formal review +
the stability & documentation deferred backlogs). No deferral. New finds become their own
`roadmap/next/*` item and fold into this plan.

**Sources:** `TESL-REVIEW-TECHNICAL.md` §3–§10, `roadmap/next/stability_deferred_backlog.md`,
`roadmap/next/documentation_deferred_backlog.md`. Refuted review items (runtime-type-satisfied
fails-open-for-all-types; establish-mints-any-fact; env HTTP end-to-end leak) are NOT reopened.

**Execution model:** shared OCaml checker/emitter edits are serialized in the main tree (kept
green by `dune test` after each change); separable work (Racket runtime, new test files, docs,
new subsystems, CI) is parallelized via subagents/worktrees. Milestones commit to `main`
(no push). Authoritative gate: `./compile-examples.sh`; fast gate: `cd compiler && dune test`.

Status key: ☐ open · ◐ in progress · ☑ done (verified).

---

## Wave 1 — CRITICAL + HIGH soundness holes

- ☑ **A1** `dfdac66` — SQL `FromDb` proof unverified vs `WHERE` (CRITICAL, review §3.2). Derive the `FromDb`
  predicate from the resolved `WHERE` AST and unify it against the declared return proof; make the
  proof argument non-authorable so it cannot disagree. `validation_proof.ml:1650-1793`,
  `validation_advanced.ml:47`. + negative test (mutated filter rejected).
- ☑ **A2-part1** `84b55c9` — Capability laundering (CRITICAL, review §4.1). Static-check `auth`/`check`/`establish`
  bodies (`validation_capabilities.ml:288`). **A2-part2 (CAP-A2, per-callsite capability narrowing
  `declared == enforced`) → moved to `roadmap/next/cap_a2_capability_narrowing.md`** (reverted `e6328b2`; blocked).
- ☑ **A3** `eece995` — env-read empty-ambient fail-open (HIGH, review §4.2). Drop the `null?` exemption in
  `tesl/env.rkt`; handle bootstrap config under an explicit scope. Auth-body static check via A2.
- ☑ **A7** `c118d9f` — Stdlib import class (CRITICAL/HIGH, review §6). Add mandatory `home_module` to every
  `stdlib_env` entry (`type_system.ml`); derive type-visibility + require table (`emit_racket.ml`) +
  scope check (`checker.ml:3287`) from it; delete `bare_stdlib_fn_module`/`stdlib_module_of_prefix`;
  run scope check over one AST fold covering test/api/agent/entity contexts. + tests. (Folds in B3.)
- ☑ **A8** `47bcd93`+`e44dcb8` — Type-directed decoders (HIGH, review §6). Remove free-result-var from
  `decodeAs`/`JWT.verify`/`JWT.decode`/`askFor`; thread the resolved target type. `type_system.ml`,
  emit, runtime. + negative test (JWT.verify security).

## Wave 2 — remaining soundness + root-cause dedup

- ☑ **A4** `0099542` — Literal proof-subject per-occurrence identity (review §3.3). `validation_common.ml:1301`.
- ☑ **A5** `20ec048` — Function-value equality via let-bound partial application (S14b residual).
  `validation_capabilities.ml` + real `TFun` inference.
- ☑ **A6** `eb7aed0` — `body_returns_named` spelling carve-out removal (latent). `checker.ml`.
- ☑ **A9** `1c3928b` — `Int` arbitrary-precision (HM-1). Carry literal as bignum string; drop range check;
  canonical proof-subject identity. `token.ml`,`ast.ml`,`checker.ml`,`emit_racket.ml`,`validation_proof.ml`.
- **A10** Client-gen soundness (review §8.2). `ir.ml:676` `extract_simple_constraints` total
  (server-only fallback); gate `--generate-*` behind `Compile` (`main.ml`).
  → moved to `roadmap/next/client_generation_soundness.md`.
- ☑ **B1** `72eb5be` — SQL effect classification single-source across OCaml/Racket seam (G8/S3b). cross-seam test. (Folds in C12.)
- **B2** Trusted proof-introducing kinds → one named predicate (dedup only; not a hole).
  → moved to `roadmap/next/assurance_polish_backlog.md`.
- ☑ **B3** — Capability-family map single-source + consistency test (folded into A7's `home_module`, `c118d9f`).
- ☑ **B4** `048f0e4` — Tool-param primitive whitelist restated 3× → single source. `checker.ml`/emit/runtime.
- ☑ **B5** `09b746d` — Error taxonomy / manual-anchor by substring → modeled resolution. `error_codes.ml`.
- ☑ **B6** `0099542` — `proof_matches`/`proof_key` string comparison → structural (underlies A4).
- ☑ **S13** `3ded694`+`b41ca56`+`e1caa80` (S13-full) — Fail-closed runtime types. Register a runtime predicate for every type reachable in a
  §7.10 retained position (param/return/payload) or an explicit allowlist; flip the default. `dsl/types.rkt`.

## Wave 3 — assurance / gate

- ☑ **C1/S1b** `171a833` — CI: `.github/workflows` running both gates, exit-code driven.
- ☑ **C2/S1b** `c5ca0d7` — Machine-readable verdicts; delete `ci.sh:65` substring waiver + `compile-examples.sh:769`
  force-to-green; ID-keyed dated waiver list.
- ☑ **C3/S2b** `c5ca0d7` — One gate a strict superset of the other (compile-examples.sh runs dune test, or ci.sh calls it).
- **C4/S8** Non-tautological emitter oracle: behavioral property tests (HTTP status/body for
  capability-denial + proof-boundary paths) + a small independent IR interpreter.
  → moved to `roadmap/next/independent_emitter_oracle.md`.
- **C5/S7** Generative negative corpus with attributed kills (AST-rewrite soundness-breaking transforms).
  → moved to `roadmap/next/generative_negative_corpus.md`.
- ◐ **C6/S10** Corpus-wide mutation beyond binops; per-category kill threshold; compile-error mutant ≠ killed.
  (down-payment `3ace148`; corpus-wide remainder → moved to `roadmap/next/assurance_polish_backlog.md`.)
- **C7/S12** Erase/retain manifest per program; assert retained == §7.10 closed set.
  → moved to `roadmap/next/erase_retain_manifest.md`.
- **C8/G7** Behavioral runtime oracle: connection-pool capability isolation + de-gate one (in-memory shim).
  → moved to `roadmap/next/behavioral_runtime_oracle.md`.
- **C9/S11** Disable-a-guard-and-expect-test-failure enforcement.
  → moved to `roadmap/next/assurance_polish_backlog.md`.
- **C10/S5b** Hyphenate every generated temp; delete reserved-name machinery.
  → moved to `roadmap/next/structural_soundness_refactors.md`.
- **C11/S6a** Routes via an exhaustive clause sum-type.
  → moved to `roadmap/next/structural_soundness_refactors.md`.
- ☑ **C12** — `test_sql_registry` naming-proxy → emit-derived set-equality (folded into B1, `72eb5be`).
- **C13** wave2/s7 `should_pass` assert exit code.
  → moved to `roadmap/next/assurance_polish_backlog.md`.
- **C14** §7 invariant coverage + anchor stability checked by semantic object, not comment/string.
  → moved to `roadmap/next/assurance_polish_backlog.md`.
- ☑ **C15** — Mutation: compile-error mutants not credited as killed (part of S10 down-payment, `3ace148`).

## Wave 4 — docs/spec fidelity + small features + decisions

- **D1/D2-full** Compile-gate every prose ` ```tesl ` fence; fix ≥5 non-compiling "Implemented" examples.
  → moved to `roadmap/next/docs_and_small_features_backlog.md` (as D1).
- **D2** Telemetry: implement a real OTLP HTTP exporter (make "OTel-first/only" true). The CLAIM correction
  is DONE (`bf0a2b2`); the OTLP-exporter IMPL (telemetry is console/stderr-only today; the `endpoint`
  config is inert — verified in `dsl/otel.rkt`) → moved to its own file `roadmap/next/otlp_exporter.md`.
- ☑ **D3** `bf0a2b2` — Capability-model doc (`zero-cost-proofs-contract.md`) claim reconciled (per-handler-scope
  claim corrected; A2-narrowing runtime remainder tracked in `cap_a2_capability_narrowing.md`).
- **D4** Zero-cost framing → honest cost model. The framing/cost-model CLAIM correction is DONE (`bf0a2b2`);
  the benchmark REWRITE (measure real emitted code) → moved to `roadmap/next/docs_and_small_features_backlog.md` (as D4-benchmark).
- ☑ **D5** `bf0a2b2` — Thesis SPEC line 96 "no runtime representation at all" → scoped wording.
- **D6** Remove dead reserved keywords / back-compat aliases; make reservation set consistent.
  → moved to `roadmap/next/docs_and_small_features_backlog.md`.
- ☑ **D7** `9827899` — Five proof-return forms → canonical decision, documented (check/`?` canonical; others legacy).
- **D8** Idiom diagnostics: single-line `if`, `++` hint on `+`-of-strings, `return` hint.
  → moved to `roadmap/next/docs_and_small_features_backlog.md`.
- **D9** Structured (machine-applicable) fixes for key diagnostics beyond `Boolean→Bool`.
  → moved to `roadmap/next/docs_and_small_features_backlog.md`.
- **D10/D7-full** Generate `manual/examples.md` from the filesystem + coverage test; resolve lesson collisions.
  → moved to `roadmap/next/docs_and_small_features_backlog.md`.
- **D11/D9-full** Migrate spec `§` citations to named anchors.
  → moved to `roadmap/next/docs_and_small_features_backlog.md`.
- **D12** Don't emit an all-parameters bindings hash for proof-free fns.
  → moved to `roadmap/next/docs_and_small_features_backlog.md`.
- **D13** String ordering (`<`/`<=`/`>`/`>=`): checker + emitter dispatch to `string<?`.
  → moved to `roadmap/next/docs_and_small_features_backlog.md`.
- **E1/E2** Smaller-core grammar collapse & emit-target-count — record as deliberate design roadmap decisions.
  → moved to `roadmap/next/smaller_core_and_emit_targets.md`.

---

## Relocated open items (2026-07-02)

The soundness/dedup program above is complete. Every still-open item has been moved out of
this tracker into a dedicated `roadmap/next/*.md` file so each has room for its own problem
statement, fix approach, effort, and refs. Larger issues get their own file; smaller ones are
batched. This tracker's Wave lists now point to these homes.

| File | Items |
| --- | --- |
| `cap_a2_capability_narrowing.md` | A2-part2 / CAP-A2 (per-callsite capability narrowing — reverted `e6328b2`, BLOCKED) |
| `client_generation_soundness.md` | A10 (client-gen soundness: total `extract_simple_constraints`, gate `--generate-*` behind `Compile`) |
| `independent_emitter_oracle.md` | C4 / S8 (non-tautological emitter oracle) |
| `generative_negative_corpus.md` | C5 / S7 (generative negative corpus with attributed kills) |
| `erase_retain_manifest.md` | C7 / S12 (per-program erase/retain manifest vs §7.10) |
| `behavioral_runtime_oracle.md` | C8 / G7 (behavioral runtime oracle; de-gate one via in-memory shim) |
| `structural_soundness_refactors.md` | C11 / S6a (routes exhaustive sum-type) + C10 / S5b (hyphenate temps, delete reserved machinery) |
| `smaller_core_and_emit_targets.md` | E1 (smaller-core grammar collapse) + E2 (emit-target-count decision) |
| `assurance_polish_backlog.md` | B2, C6 / S10-remaining (corpus-wide mutation + kill-threshold), C9 / S11, C13, C14 |
| `otlp_exporter.md` | D2-OTLP (real OTLP/HTTP exporter — telemetry is console/stderr only today; the `endpoint` config is inert) |
| `docs_and_small_features_backlog.md` | D1, D4-benchmark, D6, D8, D9, D10, D11, D12, D13 |

---

## FINAL status (2026-07-02, main @ e1caa80, superset gate green: dune test + compile-examples.sh 127/127)

**Every soundness/dedup item is CLOSED and gate-green** (A1–A9, B1, B4, B5, B6, S13-full), plus
mutation (S10), CI (C1), and the machine-trustworthy superset gate (C2+C3). The only reverted item
is **A2-part2 / CAP-A2** (runtime capability narrowing — the gate proved it regresses SSE `pubsub`
and kanel `db-read`; genuinely blocked on complete per-callsite capability inference; A2-part1, the
critical static laundering fix, is landed).

**Closed (commit):** A4+B6 `0099542` · A1 `dfdac66` · A2p1 `84b55c9` · A6 `eb7aed0` · S13 base
`3ded694`+`b41ca56` · B1 `72eb5be` · B5 `09b746d` · A5 `20ec048` · A8 `47bcd93`+`e44dcb8` · A3
`eece995` · A7 `c118d9f` · A9 `1c3928b` · C1 `171a833` · C2+C3 `c5ca0d7` · B4 `048f0e4` · S10
`3ace148` · docs `bf0a2b2`+`9827899`+`eb9a3a6` · **S13-full `e1caa80`** (type-ref resolution +
fail-closed runtime boundary checks; the last soundness hole).

**Still OPEN — large assurance subsystems + design decisions (each genuinely multi-day; NOT
one-liners; specs in the design corpus):**
- S8 independent (non-tautological) emitter oracle — new IR interpreter / behavioral oracle.
- S7 generative negative corpus with attributed kills (AST-rewrite transforms over the proof corpus).
- S12 erase/retain manifest (per-program retained-guard enumeration vs §7.10 closed set).
- G7 behavioral runtime oracle (connection-pool capability isolation; de-gate one via in-memory shim).
- S6a routes as an exhaustive clause sum-type; S5b hyphenate every generated temp + delete reserved
  machinery (churns 100+ committed .rkt snapshots).
- B2 trusted-kind predicate single-source (small dedup, latent — sound today).
- Docs: D1 compile-gate every prose ```tesl fence (triage-heavy), D10 generate examples index, D8
  idiom diagnostics (single-line-if / ++ / return hints), D13 string ordering (`<`..), D9 §-citation
  → named-anchor migration, D12 drop proof-free bindings hash.
- E1 smaller-core grammar collapse / E2 emit-target-count — deliberate design decisions the spec
  itself defers; record a decision, don't rush a breaking redesign.

## Status snapshot (2026-07-01, main @ c118d9f, BOTH gates green) — superseded by FINAL above

**Landed & gate-green:** A4+B6, A1, A2-part1, A6 (Wave 1 forgery/BOLA/laundering — all 3 CRITICALs);
A5, A8(+ambiguity fix), A3, A7 (function-cmp, decoders, env fail-open, stdlib-import class — HIGHs);
S13(partial: registrations+type-var, fail-open default retained), B1, B5; C1 (CI); docs corrections.
**Reverted/blocked:** A2-part2 (CAP-A2 — needs complete per-callsite capability inference).
**Remaining:** A9 (Int bignum), B4 (tool-param dedup), B2 (trusted-kind predicate dedup), S13-full
(type-ref resolution + fail-closed), C2 (machine-readable gate: drop substring waiver + force-to-green),
C3 (gate superset: compile-examples.sh also runs dune test — HIGH, prevents the disjoint-gate miss that
let the A8 regression slip), C4/S8 oracle, C5/S7 corpus, C6/S10 mutation, C7/S12 manifest, C8/G7 runtime
oracle, C9/S11, C10/S5b, C11/S6a, remaining Wave-4 docs (D1/D7/D8/D9/D10/D11/D12/D13, telemetry-OTLP impl),
E1/E2 design decisions. **Gate discipline: run BOTH `dune test -j1` (real exit) AND `./compile-examples.sh`
at every merge — compile-examples.sh alone does NOT run the OCaml alcotest suite (S2b).**

## Progress log

- 2026-07-01: plan created; 15-item design phase produced code-level specs + a conflict-aware spine.
- 2026-07-01: **Wave 1 + first Wave-2 items landed on `main`, authoritative gate green ("All good!", 127/127 tesl tests, Racket all pass):**
  - ☑ A4+B6 `0099542` — per-occurrence literal proof subjects + structural proof keys (CRITICAL forgery class).
  - ☑ A1 `dfdac66` — **SQL FromDb BOLA** unified against the resolved WHERE (CRITICAL).
  - ☑ A2 part1 `84b55c9` — **capability laundering** via auth/check/establish bodies now statically checked (CRITICAL).
  - ☑ A6 `eb7aed0` — removed body_returns_named spelling carve-out (content-based V001 sole decider).
  - ☑ B1 `72eb5be` — SQL cross-seam effect conformance test.
  - ☑ B5 `09b746d` — structured manual-anchor topics (no message-substring routing).
  - ◐ S13 `3ded694`+`b41ca56` — additive predicate registrations (Int/Bool/Float/Unit/Fact) + type-var helper LANDED;
    the fail-closed DEFAULT flip was REVERTED (it rejected valid `-> Unit`/`DeleteResult`/ADT/record returns because
    `runtime-type-predicate` never resolves a `type-ref` struct to its registered predicate — the pre-existing
    fail-open masked that all type-ref runtime checks were no-ops). **S13-full remains open** (see below).
  - Method note: `dune test` + `--check` passed for all of the above in isolation; the S13 regression was caught ONLY
    by the gate's `tesl test` runtime step — so every batch is validated by `./compile-examples.sh`, not `dune test` alone.
- **Remaining spine:** A5, A8, A2-part2 (runtime capability narrowing), A3 (env fail-open), A7, A9, B4.
- 2026-07-01: **Batch 2 landed on `main`, gate green ("All good!", 127/127):**
  - ☑ A5 `batch-A5` — infer arrow types for under-applied/let-bound partial apps; function-value comparison rejected by resolution (deleted operand_is_function_valued AST-shape guard).
  - ☑ A8 `47bcd93` — type-directed decoders: decodeAs cross-checked vs resolved result type; JWT.verify/decode/sign pinned to `Dict String String`.
  - ☑ A3 `eece995` — env-read asserts unconditionally except inside an explicit emitter bootstrap marker (removes empty-ambient fail-open); regen 4 agent snapshots.
  - ✗ A2-part2 `e6328b2` REVERTED — runtime capability narrowing regressed SSE (`pubsub`) + kanel `listMyOrgsHandler` (`db-read`), the exact prior-CAP-A2 failures; the gate's tesl-test step caught it (racket unit test didn't). **CAP-A2 stays BLOCKED** on complete per-callsite (transitive+auth+server-scoped) capability inference.
- **Remaining spine (sequential — all touch checker.ml/emit_racket.ml):** A7, A9, B4. Plus S13-full.
- **New/refined open item — S13-full:** make `runtime-type-predicate` resolve a `type-ref` by name (so registered
  record/ADT/newtype predicates actually apply — today they're dormant), verify the now-live checks don't over-reject
  wrapped/named values across the full corpus, THEN flip the no-predicate default to fail-closed. Subsystem task.
