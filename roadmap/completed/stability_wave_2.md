# Stability and robustness — Wave 2

> **STATUS: CLOSED (2026-07-01).** This is the wave-2 program record. The
> completable, low-risk slices were executed this pass; the remaining
> (TCB / runtime / HM-core / large-mechanical) items are carried over verbatim
> into **`roadmap/later/stability_backlog.md`** with the maintainer decisions
> baked in — nothing actionable remains in `roadmap/next/`. The design
> guardrails and root diagnosis still live in
> `roadmap/completed/stability_and_robustness.md`.
>
> **Shipped this pass (verified: `dune test` green + `./compile-examples.sh` green):**
> - **S4b** — `body_has_db_site` + `is_forgery_restricted_kind` collapsed to one
>   shared, shadow-aware decision site in `validation_common.ml`; `checker.ml` is
>   now shadow-aware (it previously wasn't — a shadowed `fn insert` looked like a
>   real DB site; the hole was masked by the shadow-aware `validation_advanced`
>   gate also running).
> - **S2b (OCaml half)** — `test_suite_registration.ml` now fails the build if a
>   `test_*.ml` runs in no gate (named only in an `(executable)` stanza) unless
>   explicitly allowlisted. (Superset-gate + filesystem-derived Racket run-set:
>   still open, in the backlog.)
> - **TSS-3 (new soundness gap, found & fixed)** — `==`/`!=`/`<` on a bare
>   top-level function reference is now rejected (it escaped `is_equatable`/
>   `is_orderable` and emitted `(equal? proc proc)` — an HM-2-class bypass).
> - **`test_wave2_soundness.ml`** — a 50-case antagonistic corpus (forgery /
>   shadowing / provenance / capability-laundering / decidable-comparison).
> - **Found & fixed a pre-existing gate blind spot**: `test_review66` R66_CA15
>   (a should-pass SSE test) had been failing under `dune test` unnoticed because
>   the authoritative gate does not run `dune test` — exactly S2b's point.
>
> **Carried over →** `roadmap/later/stability_backlog.md`: S1b, S2b-remainder,
> S3b, S5, S6, S8, S9, S13, S14b, S15, S16, CAP-A2, G7, HM-1, S7/S10–S12.

## Context

Wave 1 was the third formal review (`EVALUATION-EXECUTIVE.md`, `EVALUATION-TECHNICAL.md`,
`FIXES-APPLIED.md`). It closed the most dangerous **live** soundness holes and landed the first slices of
the systematic program in `stability_and_robustness.md`. It also **added two generators the original
taxonomy missed** — **G7** (the trusted Racket runtime's *behaviour* is a soundness surface) and **G8**
(OCaml↔Racket restatement drift) — and produced one *honest non-result*: the S13 fail-closed change was
implemented, proven unsound by the authoritative gate, and reverted.

**This document is the single "what is left" list** — every non-fixed item and every open question from
`stability_and_robustness.md` + the review, so nothing is lost between waves. IDs are carried over
verbatim (`S1`–`S16`, `G1`–`G8`, `CAP-A2`, `HM-1`, `TSS-1`) and traceable to the reports. The design
guardrails and root-generator diagnosis in `stability_and_robustness.md` still hold and are **not**
repeated here — read that first; this is its backlog.

> Format (unchanged): **ID — action** · *closes* · **enforced by** · effort · **why still open**.

---

## What Wave 1 closed (baseline — do NOT redo)

Recorded so Wave 2 does not re-litigate settled work; details in `FIXES-APPLIED.md`.

- **GDP-FORGE-1** (critical) — return-proof admission now decides by proof **content**
  (`body_carries_required`), not by the `attachFact`/`ok` keyword-presence heuristic. Pinned PN08/PC04.
- **S3 (core)** — one closed `sql_op` variant + a **total** classifier (`sql_op_effect`, no `_` arm) in
  `validation_common.ml`; name-keyed predicates derived from it.
- **S4 (membership only)** — the capability write-set and **both** `body_has_db_site` copies now consult
  that registry, so the `insertMany`/`updateAndReturnOne`/`deleteAndReturnResult` **membership drift**
  (CAP-A1) can no longer recur. *(Structural collapse still owed — see S4 below.)*
- **S14 (function case)** — `==`/`!=` on function-typed operands rejected (`is_equatable`).
- **G1/S2 (core)** — the orphaned `test_review18_antagonistic` is registered, and
  `test_suite_registration` makes any unregistered `test_*.ml` **build-red** (verified to catch one).
- **G3 (instance)** — an SSE endpoint that declares >1 `subscribe`, a `body`, or a `-> ReturnType` is now
  a **hard error** instead of a silent code-gen drop.

---

## P0 — finish making trust verifiable, and single-source the last drift

The live holes are closed; the P0 priority is now the *meta* work Wave 1 only started — a gate that can be
**trusted**, and the single-source law completed **across the language seam** (G8). Everything in P1/P2 is
a TCB or runtime edit that, per the design guardrails, must land *behind* a trustworthy gate.

- **S1b — one exit-code-driven authoritative gate; machine-readable verdicts.** `compile-examples.sh`
  currently force-sets `test_exit=0` (`:769`) and its exit code does **not** reflect failures — the Wave-1
  run proved this by returning **0 with 15 real `✗`** failures. Aggregate verdicts from
  Alcotest-JSON / a RackUnit structured reporter keyed by **stable test IDs**; delete the force-to-zero and
  the `ci.sh` substring allow-list (`ci.sh:62-66`, which over-matches new tests on bare tokens like
  `httpclient`). · *G1: verdict-from-prose + did-not-run-reads-green.* · **enforced by** an aggregator over
  artifacts + a fixture test that prints `[FAIL]` in a passing test's name and asserts the gate still reads
  green only via the artifact. · **M** · *why open: needs the "known pre-existing failures"
  (mutation false-positives / httpclient `-j4` flake / cache-email-jwt) resolved or moved onto a typed,
  dated, self-expiring waiver list first — otherwise deleting the allow-list turns the gate red on
  known-benign noise.*

- **S2b — one gate that is a superset; assert `{discovered} == {ran}` beyond the orphan check.** Unify the
  two disjoint gates so `compile-examples.sh` *also* runs `dune test` + the raco suites (or `ci.sh` becomes
  a thin caller). Extend `test_suite_registration` from "every `test_*.ml` is named somewhere" to "every
  discovered suite actually **runs** in the authoritative gate" (distinguish `(test)`/`(tests)` from
  `(executable)`; flag `test_mutate_differential`/`test_mutate_classify`, which no gate runs). Derive the
  Racket run-set from the filesystem, not the hardcoded 8 in `tests/internal-all.rkt`. · *G1: "a test
  exists but no gate runs it," generalised.* · **enforced by** a `(test)` parsing `dune describe` + globbing
  the test dirs; non-empty symmetric difference = build-red. · **M**

- **S3b — finish S3: the static==dynamic law + the G8 cross-seam binding.** The registry exists but the
  **law is not asserted**, and the runtime authority (`sql.rkt`'s per-builtin `require-capabilities!`,
  `tesl/db.rkt`, the `types.rkt` predicate keys) is a **third, ungoverned restatement in Racket** (G8).
  (a) assert `{op | effect=Write}` == `{op | emitter issues a write}`, *derived from the emit side*
  (`emit_racket.ml`), not a hand mirror; (b) bind the Racket guard set to the OCaml registry — emit it as a
  build artifact, or add a cross-language conformance test that loads both and asserts set-equality. ·
  *G2 + G8.* · **enforced by** the emit-derived set-equality test + a cross-seam conformance test. · **L**
  · *why open: G8 was only named in Wave 1; the seam is where the `insertMany` bug was masked "by luck."*

- **S4b — collapse the duplicated soundness predicates to ONE decision site.** Wave 1 unified their SQL
  *membership* but left the duplication: `body_has_db_site` is two functions (`validation_advanced.ml:20`
  shadow-aware; `checker.ml:2819` **not** shadow-aware); `is_forgery_restricted_kind` is defined twice
  (`validation_advanced.ml:919`, `checker.ml:2786`); the `body_returns_named` spelling carve-out
  (`checker.ml:2833`) is now moot after GDP-FORGE-1 but still present as unremoved dead defense. Collapse
  each to a single shared, shadow-aware function consumed by all callers, and delete the carve-out. ·
  *G2 + root "weakest-of-N-sites bounds the guarantee."* · **enforced by** a §7.12 antagonistic test over
  an **emit-derived** write-op oracle + a shadowed-name rejection case (`fn insert(...)` must not forge
  FromDb). · **M**

- **S8 — independent, non-tautological emitter oracle.** A small Tesl IR interpreter (semantics anchored to
  a committed table of the primitive's documented behaviour, not re-derived from the emitter) + a
  grammar-driven generator of well-typed programs; assert interpreter ≡ emitted-Racket observable results;
  demote byte snapshots to a refactor aid. · *G1: consistent-emitter-wrongness (the snapshot oracle is the
  compiler's own output).* · **enforced by** a `(test)` differential suite with a generated-case floor + a
  seed corpus. · **L**

---

## P1 — the class fixes now safe behind the stronger gate

TCB edits deferred from Wave 1 precisely because the guardrails require them to land behind G1. Sequence
after P0.

- **S5 — hyphenate every generated temp; delete the reserved-name machinery (G4).** The emitter still
  mints `tesl_ignored_%d` and `tesl_proof_bind_%d` (a near-miss of the reserved `tesl_proof_binding_`) that
  the 5-prefix denylist (`validation_names.ml:53`) does not cover, and the reservation walk only descends
  `DFunc` (skips `DTest`/`DApiTest`/`DLoadTest`, exactly where those temps are minted). Mint every temp with
  a hyphen (lexer-illegal in identifiers, `lexer.mll:140`; `tesl-lambda-%d` already does this), then delete
  `is_reserved_generated_name` / `check_reserved_generated_names` / the prefix list. · *G4: gensym capture,
  for all declaration kinds at once.* · **enforced by** one property test: every gensym helper's output
  contains a lexer-illegal character. · **M** · *why open: touches many `emit_racket.ml` templates and will
  churn committed `.rkt` snapshots (needs a regen sweep) + requires updating the EMIT-1 tests in
  `test_eval_review_fixes.ml`; low reachable severity so it was deferred — see open decision #5.*

- **S6 — lower routes via an exhaustive clause sum-type; reject (never drop) unsupported clauses.** Wave 1
  made the SSE drops loud at the *validation* layer; the *class* is still open — model the clause set
  (`Auth | Body | Response | Capture | Subscribe …`) and consume it in every emitter via a `match` with **no
  `_` arm**, so a route that cannot honour a clause hits an explicit `reject_unsupported_clause` at compile
  time. Ideally split HTTP and SSE into distinct endpoint types so an SSE endpoint *cannot hold* a
  body/response, and replace positional list-zips (subscribes head, first `:param`, endpoint/handler index)
  with arity-checked/key-based matching. · *G3.* · **enforced by** non-`_` `match` (warning-8) + a property
  test that each (clause, method) is either emitted or a validation error, never both. · **L**

- **S9 — make the remaining hand-rolled soundness walks total.** `proof_checker.ml:359,392` (and
  `validation_proof.ml`'s `check_forall_consistency`, `check_exists_witness_shadowing`,
  `body_uses_attach_or_ok`-style residues) still use `let rec walk … | _ -> fold_children`, so a new expr
  variant silently escapes. Replace with a `fold_children_except` whose policy returns `Descend |
  Skip(reason)` for **every** variant (exhaustive, no `_`). · *G2/root: comment-asserted non-descent
  diverging from the fold default.* · **enforced by** type-level exhaustiveness + a per-pass property test
  that visited-child set == declared policy. · **M**

- **S14b — constrain `==`/ordering to decidable types via an Eq/Ord qualified-type layer (TSS-1).** Wave 1
  closed the function case; the generic-type-**variable** residual is open: `a < b` and `a == b` for `a: a`
  still type-check (`is_orderable`/`is_equatable` return `true` for `TVar`, deliberately, because the corpus
  uses generic comparison helpers and Tesl has no Ord/Eq constraint — verified: tightening `TVar` broke 6
  files). The principled fix is a small **qualified-type** layer (Ord/Eq dictionaries discharged at
  instantiation) in the HM core, so a generic helper is `∀a. Ord a => …`, not `∀a. …`. · *root:
  unconstrained polymorphism.* · **enforced by** the resolver being total over the type universe + negative
  tests for `a < b` on an unconstrained var. · **M** · *why open: this is an HM-core (TCB) change, and it
  interacts with generalization/instantiation — must land behind the gate.*

---

## P2 — deepen coverage; close the remaining classes

- **S7 — generative negative corpus with attributed kills (G5 centrepiece).** For each accepted
  proof-bearing program, apply a **table** of soundness-breaking transforms (drop a `:::`, retarget a fact
  subject, swap a conjunction operand, widen a capability row, forge a provenance predicate, weaken an auth
  `via`) and assert the checker rejects **every** mutant — *for the specific soundness diagnostic code*
  (a mutant rejected for an incidental parse/type error counts as **survived**). Converts the ~2500 instance
  pins into the class property "no soundness-breaking mutation of an accepted program is itself accepted." ·
  *G5: the (n+1)th attack; "apart from more tests."* · **enforced by** a `(test)` generative suite over all
  proof-bearing files. · **L**

- **S10 — broaden mutation to the soundness machinery, corpus-wide, with an enforced threshold.** Extend
  `mutate.ml` beyond binops (`* / % ++`) and beyond `lesson42` to the proof/capability/provenance code;
  run across **all** proof-bearing files with a per-category kill threshold; a timeout is a gate failure. ·
  *G5: adequacy unmeasured.* · **enforced by** a `--mutate-all` step reading a committed threshold;
  attribution required. · **L**

- **S11 — §7 invariant registry with disable-and-expect-failure (G6).** `LANGUAGE-SPEC §7.1–§7.13` tags 13
  invariants "Implemented" but links them to code only by prose; **5 of 13** (§7.2/7.5/7.6/7.10/7.13) have
  no referencing test. Add an `invariants.ml` registry `{ id; guard_symbol; antagonistic_test }`,
  cross-checked against the spec headings (as `test_error_codes.ml` checks manual anchors), **plus** a
  disable-and-expect-failure check per row (the named test must fail when the named guard is disabled). ·
  *G6: prose-cannot-fail.* · **enforced by** the registry test + per-row guard-disable hook. · **L**

- **S12 — pin the erase/retain boundary as an enumerable manifest (G6/G7).** The erasure pass emits, per
  program, the retained-guard set and stripped-carrier set; assert `retained == the §7.10 closed set` over a
  corpus, so erasing a retained guard — or failing to erase a proof carrier — changes the manifest and fails
  the build. **Extend beyond S12 as written (G7):** the manifest must also assert each retained guard is
  **fail-closed by construction** — S13 proved a retained guard can silently default to *permit*. ·
  *G6 + G7.* · **enforced by** manifest-equality over a corpus. · **L**

- **S13 — fail-closed retained runtime checks (has a PREREQUISITE — do not retry the one-liner).** The
  Wave-1 attempt to fail-close `runtime-type-satisfied?` was **reverted**: the gate proved the fail-open
  default is **load-bearing** — `Unit`, `DeleteResult`, `Fact`, `Int`, and many user `type-ref`s reach the
  no-predicate branch with no registered runtime predicate, and a type variable can appear as a
  lowercase-named `type-ref` (e.g. `List.map`'s element type). **Prerequisite:** register a runtime
  predicate for *every* type that can appear in a retained §7.10 position (param/return/payload), **then**
  invert the default; or maintain a curated allowlist of genuinely-unconstrained `type-ref`s. Also audit the
  `emit_racket.ml _ -> "Any"` fallback (G6-1) so an unrecognised type does not lower to the permissive
  `Any`. Move the env fail-closed decision to the raw `tesl-env-*` helpers, not just `env.rkt`. · *root:
  undecided-case-defaults-to-ALLOW (G7).* · **enforced by** a property test: an arbitrary unregistered type
  key is rejected — *after* the prerequisite lands. · **M→L**

- **S15 — single float choke point, split by purpose.** `Float_fmt.to_faithful_literal` (emission) vs an
  `identity_key` (hex of `Int64.bits_of_float`, for proof-subject identity / proof-arg capture). Ban raw
  `string_of_float`/`%g` on floats elsewhere (the current `%.12g` proof-subject identity can collide). ·
  *root: ad-hoc serialization; proof-subject collision.* · **enforced by** two property tests (round-trip;
  identity-key distinguishes signed-zero/NaN, no collisions). · **S**

- **S16 — derive the handler↔endpoint contract (Tier-0 #2).** Derive the positional count/type/proof
  contract from the endpoint rather than re-stating it (the prior name-based attempt false-positived on
  valid positional handlers; POST/PUT carry an implicit body param; auth-value position matters). · *root:
  declaration↔implementation contract restated, not derived.* · **enforced by** a derived check + an
  antagonistic suite of mismatched handlers. · **M**

- **G7 — a behavioural runtime oracle.** Beyond making retained guards fail-closed (S12/S13), add at least
  one oracle that observes **runtime semantics** rather than re-reading the OCaml checker: pub/sub
  at-most-once delivery, transactional rollback atomicity, connection-pool capability isolation. Under
  single-mode erasure these are the entire post-checker TCB and no discipline makes a defect in them
  build-red. · *G7 (new).* · **enforced by** a `(test)` behavioural suite (may need PG + concurrency
  harness). · **L**

---

## Decisions by the maintainer

Genuine trade-offs, not clear bugs. #1–#3 carry over from `stability_and_robustness.md`; #4–#7 were
surfaced or sharpened by the review.

1. **CAP-A2 — per-handler capability narrowing at runtime.** `call-with-declared-capabilities`
   (`capability.rkt:58`) asserts `declared ⊆ ambient` but never `parameterize`s the ambient to the declared
   set, so an HTTP handler runs under the whole-app union — any static capability hole becomes a live
   cross-capability reach. **The worker path already narrows** (`queue.rkt:510`), so the idiom exists and is
   applied inconsistently. **Question:** is per-handler least-privilege a *runtime* guarantee (Option A:
   intersect `declared ∩ ambient` per call, revise §7.10 — recommended) or *compile-time-only* (Option B:
   certify the static checker complete)?
   **Decision**: Option a, if the runtime cost does not become too large. Option b would the the best way forward if we *knew* the compiler was perfect.

2. **HM-1 — the `Int` contract.** The compiler rejects out-of-range *literals* but computed expressions
   overflow silently into bignums — a falsifiable spec promise the erased runtime breaks. Pick one: (A)
   bounded checked arithmetic (emit/snapshot churn + perf), or (B) document `Int` as arbitrary-precision and
   **drop** the literal-range error. Make the compile-time message match runtime reality.
   **DECISION**: Go with b. If we need to supply memory effecient data structures in the future we can do that then.

3. **Env reads at module-load / bootstrap.** Top-level config/agent-provider `envRead`s run unguarded by
   design. **QUESTION:** record this as an explicit, tested boundary (a positive `bootstrap` capability the
   emitter grants only around top-level config reads) or accept it — either way make it machine-checkable,
   not implicit.
   **DECISION**: envRead should only be useable by the functions/entities that state that capability in its requires-list.

4. **SSE multi-channel subscribe (new).** `lesson24-pubsub-sse.md` documents multi-channel subscribe as a
   *feature*, but `emit_sse_route` emits only the head channel — Wave 1 made the extra channels a hard error
   rather than a silent drop. **QUESTION:** implement multi-channel SSE emission (make the doc true) or
   correct the doc and keep the rejection (the doc currently promises a feature the implementation lacks).
   **DECISION**: Multi-channel must be supported to easily send different type of data (some channels is for all users, some is per user, some is only for admins etc). I cannot see how that would be solved with only one channel?
   **DECISION REVERSED (2026-07-01)**: the premise was a misunderstanding. Several *independent* channels
   are expressed as several `sse` blocks in the api — each its own endpoint, path, and auth/key scoping —
   which already works (verified: two `sse` endpoints in one api each deliver their own channel). A client
   opens one `EventSource` per endpoint (HTTP/2 multiplexes them over the shared port). So one channel per
   `sse` endpoint stays; the guard now points users to separate `sse` blocks, and the over-promising doc
   (`lesson24-pubsub-sse.md`) was corrected. (Multi-channel-per-endpoint was implemented, then reverted as
   redundant.)

5. **G4 hyphenation vs snapshot churn (new).** S5 is the correct class fix but churns committed `.rkt`
   snapshots and needs an `test_eval_review_fixes` EMIT-1 update. **QUESTION:** schedule the full
   hyphenation-plus-snapshot-regen (removes the class), or accept the low reachable severity and only add the
   missing prefixes to the denylist + extend the walk to test decls (fixes the instance, keeps the class)?
   **DECISION**: Do a full regen

6. **ID-2 — framework-as-language boundary (new, identity).** 11 framework-effect forms (`EEnqueue`,
   `EPublish`, `ECacheGet/Set/…`, `ESendEmail`, `EServe`, `ETelemetry`, …) are first-class *core* AST nodes.
   **QUESTION:** which are LANGUAGE (proof/capability-load-bearing, e.g. `transaction`, `publish`) vs LIBRARY
   (cache/email could be capability-governed stdlib calls)? Finishing the stalled surface-form-lowering to
   `ERuntimeCall` shrinks the checker/emitter surface and defends the "small, opinionated" identity.
   **DECISION**: As little as possible should be in the language itself - while allowing the wanted automagic infrastructure and other guarantees.

7. **ID-3 — state the "why a language, not a library" thesis (new, docs).** The defensible right-to-exist
   (erasure-as-sole-mode + host-wide no-shadowing + trusted-only `:::` fabrication) lives in the code but is
   never stated. Add a doc section anchored on §7.4 / §7.12 / single-mode erasure. *(Belongs with
   `documentation_improvements.md`.)*
   **DECISION**: Yes add it to documentation_improvements.md if not already covered by that roadmap item.

---

## Exit criteria for Wave 2

1. **G1 fully closed:** one authoritative **exit-code** gate with machine-readable verdicts, a derived
   run-set (`{discovered} == {ran}`), skip-is-failure-unless-waived, no force-to-green, and an independent
   emitter oracle — demonstrably turning **red** on an injected soundness/emitter regression.
2. **G2 + G8 closed:** the static==dynamic law holds *and* is bound across the OCaml↔Racket seam; each
   soundness invariant has exactly one decision site (S4b).
3. **G5 standing:** the generative negative corpus + attributed proof-layer mutation run in the gate over
   all proof-bearing files, with an enforced kill threshold.
4. **G6 + G7 closed:** every §7.N invariant maps to a guard + a disable-and-expect-failure test; the
   erase/retain manifest holds *and* asserts each retained guard is fail-closed; at least one behavioural
   runtime oracle exists.
5. Every remaining class (G3/S6, G4/S5, TSS-1/S14b) has a **generative** guard, and open decisions #1–#7 are
   recorded with their enforcing test or an explicit accepted-as-is note.

When G1-fully + G2/G8 + G5 land with the project's demonstrated class-level discipline, "promising alpha"
graduates to "credible beta for its niche" — the bar the review set for continued investment.
