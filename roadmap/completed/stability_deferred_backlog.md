# Stability & robustness — deferred backlog (later)

> **NOTE (2026-07-02):** the still-open items here are now tracked in dedicated
> `roadmap/next/*.md` files created from `close_all_open_issues.md` — see that file's
> "Relocated open items" section. Per-item status markers below (☑ DONE / ◐ PARTIAL /
> → moved) reflect the completed soundness/dedup program; the descriptive prose is
> retained verbatim.

## Context

This is what remains of `roadmap/next/stability_backlog.md` after the 2026-07-01
closure round.  Everything here is **deferred, not undecided**: each item is a
large new subsystem, a TCB/type-core change that must land behind a
fully-trustworthy gate (G1), a big snapshot regeneration, or is blocked on a real
prerequisite.  Read `roadmap/completed/stability_and_robustness.md` and
`roadmap/completed/stability_wave_2.md` for the root-generator diagnosis (G1–G8)
and the design guardrails — they still hold and are not repeated here.

IDs are carried over verbatim (`S1`–`S16`, `G7`, `CAP-A2`, `HM-1`, `TSS-*`).

> Format: **ID — action** · *closes* · **enforced by** · effort · **why deferred**.

---

## Closed 2026-07-01 (final round) — do NOT redo

Verified green via `dune test` (exit 0) + `./compile-examples.sh`.

- ☑ **S5a — reserved-name capture gap closed (the soundness half of S5).** The
  emitter mints `tesl_ignored_%d` and `tesl_proof_bind_%d` while emitting TEST /
  api-test / load-test bodies, but `is_reserved_generated_name`
  (`validation_names.ml`) did NOT list those two prefixes (`tesl_proof_bind_` is a
  genuine near-miss of the reserved `tesl_proof_binding_`), and
  `check_reserved_generated_names` walked `DFunc` only — so a user binder named
  `tesl_ignored_0` inside a `test { }` block could capture the minted temp
  (silently-wrong Racket that still type-checks — the G4 variable-capture class).
  Both prefixes are now reserved and the walk descends `DTest`/`DApiTest`/
  `DLoadTest` (test-level binders + embedded exprs).  Additive validation, **zero
  snapshot churn**.  Pinned by `test_eval_review_fixes.ml` emit-1 group (4 new
  cases).  *(The remaining hyphenation-of-every-temp + reserved-machinery deletion
  is S5b below — cosmetic hardening, not soundness.)*
- ☑ **S14b — comparison soundness resolved by maintainer decision (NOT a
  qualified-type layer).** Maintainer decision (2026-07-01): the comparison
  requirement is the concrete scalars (`Int` / `Float` / `PosixMillis`, and
  derived newtypes), NOT a general `Ord`/`Eq` qualified-type polymorphism — so the
  HM-core qualified-type layer that had been the L/TCB blocker is **cancelled**.
  A generic `TVar` stays permissive by design (the corpus's generic comparison
  helpers only instantiate to concrete comparable types, and the one
  genuinely-unsound instantiation — a function — is rejected regardless).  The
  residual soundness hole that WAS open — a **partial application**
  (`(add 1) == (add 2)`, which infers a wrong concrete return type so it slipped
  past both the type-based check and the bare-`EVar` TSS-3 guard) — is now closed:
  `operand_is_function_valued` (`validation_capabilities.ml`) positively detects a
  bare top-level fn ref, an under-applied top-level fn, or a lambda, and is checked
  BEFORE inference in both the `==`/`!=` and `<`/`<=`/`>`/`>=` arms.  A
  fully-applied call returning a comparable value is NOT over-rejected.  Pinned by
  `test_wave2_soundness.ml` group F (6 new cases: partial-app/lambda rejected,
  full-app accepted).
- ☑ **S2b (Racket half) — filesystem-derived Racket run-set completeness.**
  `test_racket_discover.ml` fails the build if any `tests/*.rkt` is run by NO gate
  and not excluded-with-reason — the Racket analogue of `test_suite_registration`.
  The gated set is DERIVED, not hand-listed: (1) the compile-examples.sh
  auto-detect rule recomputed (a `tests/X.rkt` with a `tests/X.tesl` sibling and a
  `(module+ test` submodule is run via `example-test-batch.rkt`), (2)
  `internal-all.rkt`'s `define-runtime-path` set, (3) `ci.sh`'s non-comment
  `tests/*.rkt` refs, (4) a support allowlist (aggregators), (5) an
  excluded-with-reason allowlist (the two network-only httpclient suites).  This
  disproved the earlier suspicion that ~21 `critical-review-*.rkt` were un-run:
  they DO run (auto-detect; 36 of 67 files run this way).
- ☑ **S3b-b — the emitter's SQL-op guard is registry-derived.** The free-variable
  SQL-keyword guard in `emit_racket.ml` was a hand-maintained literal that had
  drifted to 7 of 14 ops (omitting `select`/`selectMany`/…); it now calls
  `Validation_common.is_sql_builtin` (all 14), so a free-var occurrence of any SQL
  op yields the clean compile-time error and adding an op to the registry cannot
  leave the guard behind.  Pinned by `test_sql_registry.ml` check (3).
- ☑ **S9 — confirmed fully done** (both hand-rolled soundness walks made total in an
  earlier round; the "remaining per-pass visited-child-set property test" was P1
  polish, not a soundness gap).  No stale work.

---

## Deferred — large / TCB / blocked

- ☑ **DONE (C2/C3, `c5ca0d7`)** — machine-readable gate + ID-keyed waivers landed.
  **S1b — machine-readable verdicts + dated waiver list.** *closes G1.* The core
  "exit code reflects failure" is done.  Remaining: (a) emit JSON verdicts keyed by
  stable suite IDs + an aggregator; (b) replace `ci.sh:62-66`'s substring
  allow-list (over-matches bare tokens like `httpclient`) with an explicit dated,
  ID-keyed waiver list.  · **enforced by** a fixture test that prints `[FAIL]` in a
  passing test's name + an artifact aggregator. · **M** · *why deferred: touches
  the critical gate-parsing path across two runners (Racket + OCaml); a subtle bug
  would re-introduce the over-broad-waiver problem in a new form, so it needs a
  stable-suite-ID scheme designed first, not a rushed edit.*

- ☑ **DONE (C3, `c5ca0d7`)** — superset gate landed (Racket-discovery half already closed).
  **S2b (superset half) — one gate a strict superset of the other.** *closes G1.*
  The Racket-discovery half landed (above).  Remaining: make `compile-examples.sh`
  also run `dune test` (+ the raco suites) OR make `ci.sh` a thin caller of it, so
  the OCaml and Racket gates are not disjoint (the disjointness is how R66_CA15
  hid).  · **enforced by** a single gate whose green implies both suites ran. ·
  **M** · *why deferred: a gate-script restructure that changes gate runtime and
  the WSL2-PostgreSQL waiver interaction; best done as its own focused change.*

- ☑ **DONE (B1, `72eb5be`)** — cross-seam SQL effect-conformance test landed.
  **S3b (cross-seam half) — bind the registry to the Racket guard set.** *closes
  G2 + G8.* The OCaml conformance test + the emitter derivation (S3b-b) are done.
  Remaining: a cross-seam test that, for every op in `all_sql_ops`, emits a minimal
  program and asserts `sql_op_effect op = SqlWrite` iff the emitted call is a
  `db-write`-guarded `sql.rkt` fn (the `require-capabilities!` read/write split is
  still hand-maintained). · **L** · *why deferred: cross-language emit-then-parse
  test infrastructure; belongs with the full G8 conformance work.*

- → **moved to `roadmap/next/structural_soundness_refactors.md`.**
  **S5b — hyphenate every generated temp; delete the reserved-name machinery.**
  *closes G4.* With S5a the capture CLASS is closed by rejection; S5b is the
  stronger structural form — mint every temp with a lexer-illegal hyphen
  (`tesl-lambda-%d` already does) so collision is impossible, then delete
  `is_reserved_generated_name` / `check_reserved_generated_names`.  · **enforced
  by** one property test: every gensym helper's output contains a lexer-illegal
  char. · **M** · *why deferred: churns ~103–174 committed `.rkt` snapshots
  (byte-exact `test_integration` gate) + an EMIT-1 test update; a focused
  snapshot-regen change of its own.*

- → **moved to `roadmap/next/structural_soundness_refactors.md`.**
  **S6a — routes via an exhaustive clause sum-type.** *closes G3.* Split HTTP/SSE
  into distinct endpoint variants (or a `clause` sum type) consumed via non-`_`
  matches, so an SSE endpoint structurally cannot hold a body/response.  (S6b —
  multi-channel SSE — was reversed as redundant; done.)  · **L** · *why deferred: a
  moderate AST refactor touching a public AST layer + all three emission paths,
  with an unsettled shape decision (ternary SSE|GET|POST-etc vs binary SSE|HTTP);
  the current validation already REJECTS the unsound cases, so this is a
  structural-guarantee upgrade, not an open hole.*

- → **moved to `roadmap/next/generative_negative_corpus.md`.**
  **S7 — generative negative corpus with attributed kills.** *closes G5.* For each
  accepted proof-bearing program, apply a table of soundness-breaking transforms
  (drop a `:::`, retarget a fact subject, widen a capability row, forge a
  provenance predicate, weaken an auth `via`) and assert the checker rejects every
  mutant for the SPECIFIC soundness diagnostic.  Down-payment done
  (`test_wave2_soundness.ml` + `test_s7_generative.ml`, ~6 seeds).  · **L** · *why
  deferred: the generative generalisation over the full proof-bearing corpus
  (~855–1200 files) is multi-day; the transform grammar per soundness layer must be
  designed as AST rewrites, not string edits.*

- → **moved to `roadmap/next/independent_emitter_oracle.md`.**
  **S8 — independent, non-tautological emitter oracle.** *closes G1.* The snapshot
  oracle byte-matches committed `.rkt` against the same compiler's emission, so a
  consistently-wrong emitter stays green.  Build a small Tesl IR interpreter (from
  a committed behaviour table) + a grammar-driven generator; assert interpreter ≡
  emitted-Racket observable results.  · **L** · *why deferred: a new multi-component
  subsystem — no expression-level IR exists today (`ir.ml` is endpoint-focused).
  A half-finished interpreter is a false oracle worse than the byte snapshots;
  should land after G1 (S1b/S2b-superset).*

- ◐ **PARTIAL** (down-payment `3ace148`; corpus-wide + kill-threshold remainder
  → **moved to `roadmap/next/assurance_polish_backlog.md`**).
  **S10 — broaden mutation to the soundness machinery, corpus-wide.** *closes G5.*
  Extend `mutate.ml` beyond binops/lesson42 to the proof/capability/provenance
  code across all proof-bearing files, with a per-category kill threshold; a
  timeout is a gate failure. · **L** · *why deferred: blocked on S7's transform
  grammar + a discoverable proof-bearing-file manifest; corpus-wide mutation needs
  timeout budgeting.*

- → **moved to `roadmap/next/assurance_polish_backlog.md`.**
  **S11 (residual) — disable-a-guard-and-expect-test-failure enforcement.** *closes
  G6.* The §7 invariant registry + heading hard-gate + coverage report landed
  (`test_invariants.ml`).  Remaining: the strongest form — toggle each guard off
  and assert a test goes red. · **M** · *why deferred: needs guard-toggle
  (feature-flag) points threaded through `validation_*.ml`/`checker.ml` and a
  multi-variant build harness; must be complete (missing one guard defeats it).*

- → **moved to `roadmap/next/erase_retain_manifest.md`.**
  **S12 — pin the erase/retain boundary as an enumerable manifest.** *closes G6 +
  G7.* Emit per-program the retained-guard / stripped-carrier set; assert
  `retained == the §7.10 closed set` over a corpus, each retained guard fail-closed
  by construction. · **L** · *why deferred: new manifest-emission subsystem + a
  corpus aggregator; must enumerate guard sites explicitly (not grep-heuristic) to
  avoid over/under-counting.*

- ☑ **DONE (S13-full, `e1caa80`)** — type-ref resolution + fail-closed runtime
  boundary checks landed; the last soundness hole. (Base registrations `3ded694`+`b41ca56`.)
  **S13 — fail-closed retained runtime checks.** *closes G7 (undecided-case-
  defaults-to-ALLOW).* `runtime-type-satisfied?` (`dsl/types.rkt`) fails OPEN when
  a type has no registered runtime predicate; the fail-closed flip was tried and
  reverted (the open default is load-bearing — `Unit`/`DeleteResult`/`Fact`/`Int`/
  many user `type-ref`s reach the no-predicate branch). · **L** · **BLOCKED** on
  the prerequisite: register a runtime predicate for every type reachable in a
  retained §7.10 position (param/return/payload), or a curated allowlist of
  genuinely-unconstrained `type-ref`s, THEN invert the default; also audit the
  `emit_racket.ml _ -> "Any"` (allow-all) fallback.

- → **moved to `roadmap/next/cap_a2_capability_narrowing.md`** (BLOCKED; reverted `e6328b2`).
  **CAP-A2 — per-handler runtime capability narrowing.** Decision: Option A
  (narrow `declared ∩ ambient` per handler) *if runtime cost is acceptable*.
  Narrowing was tried and reverted (a handler's emitted `requires` row is NOT its
  complete runtime set — its `auth` via-fn and server-scoped grants run under the
  same context but are not in `requires`, so a naive narrow denied them). · **L** ·
  **BLOCKED** on the prerequisite: complete static capability inference emitting
  the full transitive + auth + server-scoped per-call row, THEN narrow to it.
  `call-with-declared-capabilities` remains a subset-assertion (`declared ⊆
  ambient`).

- ☑ **DONE (A9, `1c3928b`)** — `Int` arbitrary-precision landed (literal carried as
  bignum; range check dropped; canonical proof-subject identity).
  **HM-1 — the `Int` arbitrary-precision contract.** Decision (b): document `Int`
  as arbitrary-precision and drop the literal-range error.  The runtime is already
  bignum; the frontend represents `INT` as a native OCaml `int` (`token.ml`), so
  the range check is a representation limit.  Dropping it requires carrying the
  literal as a source string / bignum to codegen and flipping ~18 antagonistic
  `should_fail "out of range"` tests. · **M** · *why deferred: a TCB carrier change
  (AST literal, checker inference, emitter, proof-subject identity in
  `validation_proof.ml`) that should land behind G1 with a huge-literal round-trip
  property test + a proof-subject-identity audit (arbitrary-precision string
  identity must be canonical).*

- → **moved to `roadmap/next/behavioral_runtime_oracle.md`.**
  **G7 — a behavioural runtime oracle.** Two of three named oracles exist
  (PG-gated: transactional rollback PG-Q7, pub/sub at-most-once PG-Q9).
  Remaining: the connection-pool capability-isolation oracle (none exists), and
  de-gating at least one behavioural oracle so it runs without local PostgreSQL (an
  in-memory shim). · **M** · *why deferred: an in-memory shim must faithfully
  reproduce the transactional / NOTIFY-LISTEN / sweep-race semantics or it is a
  false-green; conflates a new-oracle design with a runtime-shim subsystem.*

---

## Small follow-up noted this round (not a soundness item)

- → **moved to `roadmap/next/docs_and_small_features_backlog.md`** (as D13).
  **String ordering (`<`/`<=`/`>`/`>=`).** String EQUALITY (`==`) works; String
  ORDERING is currently REJECTED by the checker (`is_orderable` covers Int / Float
  / PosixMillis only) — which is SOUND (rejecting is safe).  The maintainer noted
  comparison should "support Strings"; adding lexicographic string ordering is a
  discrete FEATURE (checker: add `String` to `orderable_bases`; emitter: dispatch
  `<` to `string<?` — the emitter currently emits raw numeric Racket `<` with no
  operand-type dispatch, so this touches emission + runtime), not part of the S14b
  soundness resolution.  Track here for a focused follow-up.
