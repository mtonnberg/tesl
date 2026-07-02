# Stability and robustness

## Background

We have, more or less, the feature set we know we need. Before adding more, we should:

- Collect more user feedback.
- Make the core more robust and more stable.
- **Remove whole classes of bug**, not individual bugs.

The instance-level findings from the formal reviews are being handled separately. **This item is not a
bug list.** It is the *systematic* program: the
structural disciplines that stop the classes from recurring, framed so that "the next instance"
becomes unrepresentable or auto-caught — not patched after the fact.

## Goal

Decide *how* to systematically remove classes of bugs, improve robustness, and ensure correctness
**without relying on "just more tests."** Concretely: for each generator of bugs, land a change that
makes the bad state either impossible to express or impossible to ship green — enforced by the type
system, by a single source of truth, by an independent oracle, or by an exit-code gate — rather than
by a human remembering a convention.

---

## Root diagnosis — one generator behind the classes

This is the project's own Tier-0 diagnosis (`roadmap/completed/soundness_increase.md`), and a fresh
code-level audit of the post-fix tree confirms it is still the dominant generator:

> **A soundness fact is restated by hand in many places instead of derived from one source, and is
> decided by a *syntactic proxy* — an identifier's spelling, an argument's position, a list's head,
> a literal's rendered text — instead of the resolved semantic object the checker already knows
> about.**

Two properties turn ordinary drift into *silent* unsoundness:

1. **No runtime backstop.** Proofs and capability rows are erased in release *and* `--debug`
   (single-mode erasure, `LANGUAGE-SPEC.md §7.10`). The OCaml checker is the sole contract for almost
   everything. A disagreement between two restatements is not a crash — it is a value carrying a
   guarantee it never earned, flowing to JSON/DB/clients silently.
2. **An invariant checked at N sites is only as strong as its *weakest* site.** Soundness is the
   *intersection* of what every site admits; fixes land per-site. We already have a live example:
   `body_has_db_site` exists in two copies — `validation_advanced.ml:20` got the shadowing fix,
   `checker.ml:2819` did not — so the FromDb-forgery gate holds today only by the accident that both
   passes run and the strict one fires first.

Everything below is an instance of this generator. The disciplines are ordered so that the ones that
make trust *itself* verifiable (the gate) and remove the most dangerous live drift come first.

### What is genuinely solid (build on it, don't reinvent)

- The **single generic AST fold** (`ast_visitor.ml`) is real, total over all 30 expr variants, and
  loc/order-preserving. The CAP-1 fix (deleting the `EConstructor` arm so the capability walk routes
  through `fold_children_env`) is a true **class-level** fix — a new expr variant can no longer escape
  the capability walk.
- **`tesl_stdlib_cap_map`** (`validation_common.ml:714`) is a genuine single source of truth for
  module→capability, *referenced* (not copied) by `proof_checker.ml:97`. This is the pattern to
  generalize to the other tables.
- The **property-test pattern already exists** and is the right shape: `test_ast_visitor.ml` (fold is
  identity/total), `test_desugar.ml` (lowering is a structural identity), `test_stdlib_consistency.ml`
  (cross-table registry agreement), `test_error_codes.ml` (registry ↔ manual anchor resolution). Much
  of the work below is *generalizing these to the soundness-critical tables and passes* they don't yet
  cover.

---

## The bug-class generators and the discipline that removes each

Each generator names the mechanism, its current status, and the discipline that closes the *class*
(not the instance). "Enforced by" is load-bearing: it must make the bad state unrepresentable or
build-red, never "a convention to remember."

### G1 — "Green" cannot see the classes that keep breaking *(meta-generator; highest priority)*

The definition of green is built from non-authoritative signals, so every "this is fixed" claim —
including the fixes just applied — rests on a gate blind to the very classes that recur.

- **Two non-superset gates.** `compile-examples.sh` (called "authoritative") never runs `dune test`
  (only `dune build test/…exe || true`, which swallows failure); `ci.sh` runs `dune test` but not the
  `tests/all.rkt` PG-backed aggregate. Running either alone is a structural false-green — the
  mechanism by which 78 failing tests once hid.
- **Verdicts parsed from stdout prose.** `ci.sh:62-66` greps `[FAIL]` then drops failures via a broad
  substring allow-list (`mutation|…|test_jwt|httpclient|exact-match`) that over-matches *new* tests
  whose names contain those tokens — fail-open. `compile-examples.sh:766-769` force-sets `test_exit=0`
  when a Postgres-start message co-occurs. Text is not a contract.
- **Tautological emitter oracle.** Snapshots are byte-matched against output from the *same compiler*;
  `.tesl` test oracles' expected values are mostly compiler-emitted too. A *consistently wrong*
  emitter is green. (Hand-written `expect` values in lessons are a genuine independent oracle, but
  only for the construct paths they happen to reach.)
- **Near-zero generative coverage.** Mutation runs on **1** proof-bearing file (`lesson42`), binop-only
  operators, never touching the proof/capability/provenance machinery. `test_mutate_differential` /
  `_classify` are `(executable)` stanzas no gate runs. The ~2500 antagonistic assertions are instance
  pins (reject *this* known-bad program), not generative.
- **Suite membership is a hand-edited list** (`test/dune (names …)`, `ci.sh` `RKT_SUITES`/`AI_TESL`).
  A suite a contributor forgets to append silently leaves every gate with zero signal.

**Discipline (close the class):**
- One **exit-code-driven** authoritative gate; the second becomes a thin caller. Aggregate verdicts
  from **machine-readable** per-test artifacts (Alcotest JSON / a RackUnit structured reporter) keyed
  by **stable test IDs** — never from stdout greps.
- **Skip is failure unless waived.** A PG-absent or WSL2 path emits `skip(reason)`, and the gate fails
  unless that exact test ID is on a typed, dated, **self-expiring** waiver list. Delete the
  force-to-green override and the substring allow-list.
- **Derive the run-set from the filesystem / `dune describe`**, then assert
  `{discovered suites} == {ran suites}`; a non-empty symmetric difference is build-red. Closes "a test
  exists but no gate runs it" generally.
- An **independent, non-tautological emitter oracle**: a small Tesl IR interpreter (semantics anchored
  to a committed table of the underlying primitive's documented behaviour, *not* re-derived from the
  same intuition that wrote the emitter) + a grammar-driven generator of well-typed programs; assert
  interpreter ≡ emitted-Racket observable results, shrink counterexamples. Demote byte snapshots to a
  refactor-regression aid. *(Compatible with single-mode erasure: this checks emitted-value
  correctness, not proof re-verification.)*

> **Why first:** until green is trustworthy, every other item's "done" is unverifiable — and the gate
> *as it stands today could not have caught* PROOF-1, CAP-1, CONC-1, or either EMIT bug.

### G2 — A soundness fact is restated in N places and decided by spelling

The same fact (which names are SQL ops, which are env reads, which predicates are framework-minted) is
re-typed inline at many sites with divergent membership, and privilege is keyed on the surface string
rather than the resolved binding.

- The SQL-builtin name set is inlined at **~8 sites / 24 places**; membership already disagrees —
  `selectMany` is in `validation_proof.ml:1653`/`validation_common.ml:880` but absent from
  `checker.ml:2822`, `validation_advanced.ml:22`, `validation_capabilities.ml:88`, `parser.ml:2485`.
- **Most severe live instance:** `validation_capabilities.ml:88-89` `sql_write_names` omits
  `insertMany`/`updateAndReturnOne`/`deleteAndReturnResult` — these *are* real DB-write emitters
  (`emit_racket.ml:895,906,922`). A handler whose only write is `insertMany` may be statically inferred
  to need no `dbWrite`. (The retained runtime ambient-grant check *may* still catch the grant at the
  boundary — **maintainer to confirm** whether `insertMany` emits a `dbWrite`-guarded call; either way
  the *static* inference is unsound.)
- `body_has_db_site` and `is_forgery_restricted_kind` are each defined twice and have **drifted** (only
  one copy got the shadowing fix). `body_returns_named` (`checker.ml:2833`) still admits a
  proof-carrying return whenever the body tail's *name* equals the return binder, with no `proof_env`
  consultation — an independent spelling-keyed admission path that re-opens PROOF-1's shape.

**Discipline (close the class):**
- **One sum-typed builtin registry** in `validation_common.ml`: a closed variant `sql_op` (and the
  env/time/jwt/http families) mapped to a *rich record* — `{ effect: Read|Write|None; role: Head|Modifier;
  attaches_fromdb: bool; reserved: bool; runtime_net: … }`. The distinct questions stay distinct fields
  (a flat "is-SQL" set would wrongly collapse them — a SQL keyword like `where`/`returning` is reserved
  and a fallback head but has no effect). Every site consumes a projection and **pattern-matches the
  variant** — adding a constructor without classifying it is a non-exhaustive-match **compile error**,
  not a silent blind spot. Kills the duplication *and* the `insertMany` capability omission at once.
  (A grep-gate is explicitly rejected as enforcement: the capability copy `["insert";"update";…]`
  contains neither `select` nor `selectOne`, so any sentinel grep passes it.)
- **Decide by resolution, not spelling.** EVar carries only a `string` today (`ast.ml:103`); the
  checker resolves names transiently and discards it. Elaborate references **once** into a
  `ref_kind = Builtin of … | UserFn | Local | Unresolved` (computed from the registry) and have every
  soundness predicate match on `ref_kind`. Shadowing, imports, and aliased re-exports then fall out for
  free, and `body_returns_named` admits only when the returned binding's kind actually carries the
  proof. *(This is an `L` elaboration pass; the registry above delivers most of the value first as an
  `M`.)*
- **Collapse each duplicated predicate to one definition** consumed by all passes; if redundancy is
  kept for defense-in-depth, both call the *same* function so they cannot drift.

### G3 — A surface clause is silently dropped when codegen projects into a non-total target

Lowering projects a structurally-total surface record into a positional, untyped Racket list whose
arity the OCaml compiler cannot relate to the clause set — so a forgotten/excess clause is a silent
semantic drop, not a type error. CONC-1 (dropped SSE per-key auth) was the instance; the *class* is
open: `emit_sse_route` (`emit_racket.ml:5039`) still truncates `ep.subscribes` to its **head** (a 2nd
subscribe channel is dropped today) and drops `body`/`response` clauses on SSE endpoints with no
diagnostic. The SSE-vs-HTTP partition (`validation_structural.ml:524`) short-circuits "harmless"
checks — the exact reasoning that produced CONC-1.

**Discipline (close the class):** model the clause set as a **sum type** (`Auth | Body | Response |
Capture | Subscribe …`) and have every emitter consume it via a `match` with **no `_` arm**
(exhaustiveness is already warning-8-as-error). A clause a route cannot honour must hit an explicit
`reject_unsupported_clause` (a hard validation error) — never an implicit drop. Adding a clause then
forces a per-route honour-or-reject decision at *compile time*. Replace the SSE skip with positive
per-method clause-legality rules. *(`[@@warning +9]` on records does **not** suffice — dot-access reads
bypass it.)*

### G4 — Generated names protected by a denylist that drifts

The emitter mints temps via scattered `Printf.sprintf "tesl_*"` templates; the reservation that stops
user code from capturing them (`validation_names.ml:53`) is a *separately hand-copied* 5-prefix list,
applied only to `DFunc` bodies. Audit found **4 reachable underscore families minted but not reserved**
(`tesl_match`, `tesl_gen_<field>`, `tesl_ignored_`, `tesl_proof_bind_` — the last a near-miss of the
reserved `tesl_proof_binding_`), and the walk skips `DTest/DApiTest/DLoadTest` where several temps are
minted into user-shared scope.

**Discipline (close the class):** make capture **unrepresentable**, not policed. Mint *every* temp with
a hyphen (`tesl-case-`, `tesl-checked-`, …); the lexer forbids `-` in identifiers (`lexer.mll:140`), so
a hyphenated temp is provably uncollidable. Then **delete** `is_reserved_generated_name`,
`check_reserved_generated_names`, and the prefix list — they become dead code. One property test asserts
every gensym helper's output contains a lexer-illegal character. (This obsoletes the denylist, the
grep-gate, and the per-declaration-kind walk simultaneously.)

### G5 — The instance-pin corpus cannot find the (n+1)th attack; the proof layer is untested generatively

The ~2500 antagonistic assertions prove rejection of *known* bad programs. Nothing *generates* new
attacks, and because proofs are erased and never re-verified at runtime (`check-runtime.rkt:832`), the
strongest independent oracle (runtime `expect` values) is **structurally blind** to a forged proof — a
wrongly-accepted forgery produces byte-identical runtime values. So soundness coverage scales with
reviewer imagination, not the program space.

**Discipline (close the class) — this is the "apart from just more tests" centerpiece:**
- **Generative negative corpus:** for each *accepted* proof-bearing program, apply a **table** of
  soundness-breaking transforms (drop a `:::`, retarget a fact subject, swap a conjunction operand,
  widen a capability row, forge a provenance predicate, weaken an auth `via`) and assert the checker
  **rejects** every mutant. Convert ~2500 pins into the class property "no soundness-breaking mutation
  of an accepted program is itself accepted."
- **Attributed kills.** A mutant rejected for the *wrong* reason (an incidental parse/type error)
  counts as **survived** — assert the rejection maps to the specific soundness diagnostic code, or a
  weakened rule hides under green coverage.
- **Test proof-soundness as a property of the checker, not of runtime behaviour** (because it is
  unobservable post-erasure). Optionally keep a tiny opt-in build that retains a proof witness so at
  least one end-to-end forgery attempt is observable in CI.
- **Broaden mutation** (`mutate.ml`) to `* / % ++` and to the proof/capability/provenance machinery,
  run it across **all** proof-bearing files with an enforced per-category kill threshold; a timeout is
  a gate failure, not a silent skip.

### G6 — Spec invariants and the erase/retain boundary are prose with no enforcing link

`LANGUAGE-SPEC §7.1–§7.13` states 13 soundness invariants tagged "Implemented," linked to code only by
free-text comments; **5 of 13** (§7.2, 7.5, 7.6, 7.10, 7.13) have no referencing test. Prose cannot
fail — a guard can be weakened to a no-op with the spec still reading "Implemented" and a green suite.
The erase-vs-retain boundary (§7.10's closed set of retained runtime checks — ambient cap-grant, param
type, return shape, existential escape, newtype tag) is the *entire* trust argument and is asserted
nowhere machine-checkable.

**Discipline (close the class):** an `invariants.ml` registry `{ id; guard_symbol; antagonistic_test }`,
cross-checked against the spec headings exactly as `test_error_codes.ml` checks manual anchors — fail if
a §7.N has no row, or a row names a symbol/test that doesn't exist. **Then go beyond name-resolution:**
a *disable-and-expect-failure* check per row (the named antagonistic test must fail when the named guard
is disabled), so a silently-weakened guard is build-red. Make the retained-check set an **enumerable
output** of the erasure pass (a manifest over a corpus), so erasing a retained guard — or failing to
erase a proof carrier — changes the manifest and fails the build.

### G7 — The trusted Racket runtime's *behaviour* is a soundness surface, with no generator and no gate *(added by the third formal review)*

G1–G6 are, with one exception (G3's positional drop), a theory of the **OCaml checker**. But single-mode
erasure makes the ~18k-line **Racket runtime** the *entire post-checker TCB* for everything the spec does
**not** erase: handler dispatch, SQL emission, the SSE `LISTEN/NOTIFY` thread and pub/sub outbox,
transactional atomicity, connection handling, and the **retained `§7.10` guards**. The roadmap models the
runtime in only two roles — "the eraser with no backstop" and "a blind oracle" — neither of which makes
the runtime's *own* behaviour a correctness generator. A race in the pub/sub poller, a dropped `NOTIFY`,
a connection-pool capability leak, or a transaction that commits a side effect on rollback is a live,
uncrashable, checker-invisible data-integrity defect that no discipline makes build-red. The fail-open
`runtime-type-satisfied?` (now fixed, S13) and CAP-A2 are early *instances* of this class.

**Discipline (close the class):** treat the retained-runtime set as a TCB with its own coverage. Every
retained guard must be **fail-closed by construction** (asserted, not assumed — S13 did this for the type
guard; audit the rest). Add at least one **behavioural** oracle that observes runtime semantics
(pub/sub at-most-once delivery, transactional rollback atomicity, connection-pool capability isolation)
rather than re-reading the OCaml checker — the manifest of S12 enumerates the guards but never asserts
each is fail-closed *or* that its runtime behaviour is correct.

### G8 — Cross-language (OCaml emit ↔ Racket runtime) restatement drift *(added by the third formal review)*

G2's single-source law (`S3`) asserts `{op | static-effect=Write} == {op | emitter issues a write}` — but
**both** sides are OCaml-internal (the classifier and `emit_racket.ml`). The *actual runtime authority*
for "this op needs `dbWrite`" is a **third, independent hand-restatement living in Racket**: `sql.rkt`'s
per-builtin `(require-capabilities! (list db-write))` calls, plus the capability identities in
`tesl/db.rkt` and the type-predicate registry in `types.rkt`. Nothing binds the OCaml registry to the
Racket guard set; they can drift exactly as the OCaml-internal lists did. The `insertMany` omission was
masked at runtime **only by luck** — the Racket guard happened to be complete where the OCaml inference
was not. OCaml exhaustiveness structurally cannot reach a Racket literal, so G2's discipline, as written,
stops at the language seam.

**Discipline (close the class):** make the seam a *generated* boundary, not a restated one — emit the
Racket capability-guard table (and the runtime-type registry keys) **from** the OCaml registry (S3) as a
build artifact, or add a cross-language conformance test that loads both and asserts set-equality. The
single-source principle must span the seam, not stop at it.

---

## Status — third formal review (2026-06-30)

Landed this cycle (instance track + the safe class slices):

- **GDP-FORGE-1 (critical)** — proof forgery via the `attach_or_ok` syntactic escape: closed by
  proof-content admission; pinned (PN08/PC04). *(root generator: decide-by-spelling)*
- **S3 (partial) + CAP-A1** — single sum-typed SQL-op registry with a total classifier; capability
  write-set + both `body_has_db_site` copies (**S4**) now consume it; the `insertMany`/`updateAndReturnOne`/
  `deleteAndReturnResult` capability omission is closed; pinned (CN03).
- **S14 (partial)** — `==`/`!=` on **functions** rejected (`is_equatable`); generic-type-variable residual
  deferred to an Eq/Ord qualified-type layer (R3).
- **G1/S2 (partial)** — orphaned `test_review18_antagonistic` registered; `test_suite_registration`
  meta-test makes any unregistered `test_*.ml` build-red (verified to catch an injected orphan).
- **G3 (partial)** — SSE endpoints now **reject** (no longer silently drop) >1 `subscribe` channel, a
  `body`, or a `-> ReturnType`.
- **S13** — *attempted and reverted (finding).* The fail-closed flip was implemented and run through the
  gate, which proved the **fail-open default is load-bearing**: `Unit`/`DeleteResult`/`Fact`/`Int`/many
  user `type-ref`s reach the no-predicate branch with no registered runtime predicate. S13 is therefore
  **not** a one-line default-flip; it needs a prerequisite (register a predicate for every type that can
  appear in a retained §7.10 position, or a curated allowlist) before the default can be inverted.
- **CAP-A2** — *attempted and reverted (correction, 2026-07-01).* Runtime narrowing (`parameterize`-ing
  the dynamic capability set to the handler's declared row) was implemented and reverted: a handler's
  emitted `requires` row is NOT its complete runtime set — its `auth` via-fn (e.g. a session lookup that
  reads the DB) and server-scoped grants (e.g. `pubsub` for `publish`) run under the same context but are
  not in `requires`, so the naive narrow denied them (kanel `listMyOrgsHandler` lost `db-read`; the
  ai-conversation SSE handler lost `pubsub`). `call-with-declared-capabilities` (`dsl/capability.rkt`)
  therefore remains a subset-assertion (`declared ⊆ ambient`) with NO narrowing. Decision #1 (Option A) has
  a prerequisite: complete static inference + a full emitted per-call row. Tracked in
  `roadmap/later/stability_backlog.md` (CAP-A2).

The maintainer has since settled every open design question, and **everything still open** — the rest of
S1/S2, S3 finish + G8, S4 structural collapse, S5–S16, TSS-1 Eq/Ord, HM-1, env-cap, SSE multi-channel, the
ID-2 surface-shrink, and the G7 runtime oracle — is consolidated (with those decisions baked in) in
`roadmap/later/stability_backlog.md` (and the wave-2 program record in
`roadmap/completed/stability_wave_2.md`). This section is only the Wave-1/2 delta.

---

## Design guardrails (decisions this program must respect)

- **Smaller, more stable core.** Do not grow the language to add stability machinery. Prefer removing a
  footgun over adding surface.
- **Negative tests are first-class.** No soundness fix is "done" until a `should_fail` test pins it; no
  item here should lack a negative-test (or generative) home.
- **No host FFI / no unsafe escape hatch** (explicitly declined — it adds a trust boundary). If a real
  primitive gap appears (e.g. password hashing), add *that* primitive, never a general FFI.
- **Single-mode erasure is permanent.** Proofs/cap rows are erased in release and `--debug`; the checker
  is the sole root of trust. **Do not** design a runtime proof re-verification layer or an
  erased-vs-non-erased differential gate as if a non-erased mode existed — it does not, and the old
  Racket safety net is being removed, not built upon. (Hardening the *already-retained* §7.10 checks is
  in scope; adding a *new* proof-verification layer is not.)
- **Don't touch the TCB (checker/emitter) casually.** TCB edits carry stability risk; G2's elaboration
  pass and G3's clause sum-type are TCB changes and must land behind the strengthened gate (G1) with
  generative coverage (G5), not before it.
- **Single source of truth is *the* design principle for drift.** The cap-map is unified; **finish** the
  remaining unification (G2) rather than adding a 4th parallel table guarded only by a consistency test.
- **`compile-examples.sh` is sacred until G1 replaces it.** New standing gates go through the
  `test_integration` / `ci.sh` dune-test path; unifying the two gates is itself a G1 task done
  deliberately, not a casual edit.

---

## Actionable program (prioritized)

Format: **ID — action** · *closes* · **enforced by** · effort.

### P0 — make trust verifiable, and single-source the most dangerous drift

- **S1 — One exit-code gate, machine-readable verdicts, skip-is-failure-unless-waived.** Make one script
  authoritative (invokes `dune test` + the Racket aggregate + raco suites); aggregate from JSON/JUnit +
  exit codes keyed by stable IDs; delete the substring allow-list and the WSL2 force-to-zero; waivers are
  typed, dated, self-expiring, exact-ID. · *G1: verdict-from-prose + did-not-run-reads-green.* ·
  **enforced by** aggregator over artifacts; a fixture test that prints `[FAIL]` in a passing test's name
  and asserts the gate still reads green only via the artifact. · **M**
- **S2 — Derive the gate run-set from the filesystem/dune; ban hand-maintained suite lists.** Assert
  `{discovered} == {ran}`; any `test_*.ml` that is `(executable)` or unlisted without a dated waiver is
  build-red. · *G1: "a test exists but no gate runs it."* · **enforced by** a `(test)` meta-test parsing
  `dune describe` + globbing the test dir. · **M**
- **S3 — One sum-typed builtin registry (SQL/env/time/jwt/http), consumed by exhaustive match.** Delete
  the ~24 inline SQL sites and the env/time copies; fixes the live `insertMany` **capability** omission
  and the FromDb-gate drift as a side effect. · *G2: N-restatements-that-drift.* · **enforced by** OCaml
  exhaustiveness (unclassified op = compile error) + a **static-effect == dynamic-emission** set-equality
  test (`{op | effect=Write}` == `{op | emitter issues a write}`, derived from the emit side, not a hand
  mirror). · **L**
- **S4 — Collapse duplicated soundness predicates to one decision site.** Delete `checker.ml:2819`'s
  `body_has_db_site`; both callers use the shadow-aware, registry-backed version; same for
  `is_forgery_restricted_kind`; remove the `body_returns_named` spelling carve-out (admit only via
  `proof_env`). · *G2 + root "weakest-of-N-sites bounds the guarantee."* · **enforced by** a §7.12
  antagonistic test parameterised over an **emit-derived** write-op oracle (not the predicate's own
  source) + a shadowed-name rejection case. · **M**

### P1 — close the live structural generators

- **S5 — Hyphenate every generated temp; delete the reserved-name machinery.** · *G4: gensym capture, for
  all declaration kinds at once.* · **enforced by** one property test: every gensym output contains a
  lexer-illegal character. · **M**
- **S6 — Lower routes via an exhaustive clause sum-type; reject (never drop) unsupported clauses.** Fixes
  the open SSE multi-subscribe/body/response drops; replace the SSE skip with positive per-method rules. ·
  *G3: surface-clause drop on projection.* · **enforced by** non-`_` `match` (warning-8) + a property test
  that for each (clause, method) the clause is either emitted or yields a validation error — never both
  type-checks and vanishes. · **L**
- **S7 — Generative negative corpus with attributed kills.** Mutate accepted proof-bearing programs at the
  proof/capability/auth layer; assert rejection attributed to the specific soundness code. · *G5: the
  (n+1)th attack; "apart from more tests."* · **enforced by** a `(test)` generative suite over all
  proof-bearing files; surviving or wrong-reason mutant = red. · **L**
- **S8 — Independent emitter oracle.** Tesl IR interpreter (externally-anchored semantics) + grammar-driven
  generator; interpreter ≡ emitted Racket on observable results; byte snapshots demoted to refactor aid. ·
  *G1: consistent-emitter-wrongness.* · **enforced by** a `(test)` differential suite with a generated-case
  floor + a committed seed corpus. · **L**

### P2 — deepen coverage and remove the remaining classes

- **S9 — Make remaining hand-rolled soundness walks total.** Replace `let rec walk … | _ -> fold_children`
  in `check_forall_consistency` (`validation_proof.ml:1560`), the `proof_checker.ml:327-392` hybrid walks,
  `check_exists_witness_shadowing`, and `body_uses_attach_or_ok` with a `fold_children_except` whose policy
  returns `Descend | Skip(reason)` for **every** variant (exhaustive, no `_`). · *G2/root: comment-asserted
  non-descent diverging from the fold default.* · **enforced by** type-level exhaustiveness + a property
  test per pass that its visited-child set equals its declared policy. · **M**
- **S10 — Broaden mutation to the soundness machinery, corpus-wide, with an enforced threshold.** Extend
  `mutate.ml` beyond binops and beyond `lesson42`; timeouts are failures. · *G5: adequacy unmeasured.* ·
  **enforced by** a `--mutate-all` step reading a committed per-category threshold; attribution required. ·
  **L**
- **S11 — §7 invariant registry with disable-and-expect-failure.** Map every §7.N to a guard + test; the
  test must fail when the guard is disabled; fill the 5 unreferenced invariants. · *G6: prose-cannot-fail.* ·
  **enforced by** a registry test modeled on `test_error_codes.ml` + per-row guard-disable hook. · **L**
- **S12 — Pin the erase/retain boundary as an enumerable manifest.** The erasure pass emits, per program,
  the retained-guard set and stripped-carrier set; assert retained == the §7.10 closed set over a corpus. ·
  *G6: the trust boundary is asserted nowhere.* · **enforced by** manifest-equality over a corpus, not an
  absence-grep over one sample. · **L**
- **S13 — Fail-closed boundary defaults at the lowest shared primitive.** `runtime-type-satisfied?`
  (`types.rkt:1085`) must reject unregistered type keys (with an explicit allowlist); move the env
  fail-closed decision to the raw `tesl-env-*` helpers, not just `env.rkt`. · *root: undecided-case defaults
  to ALLOW.* · **enforced by** a property test: an arbitrary unregistered type key is rejected. · **M**
- **S14 — Constrain `==`/`!=`/ordering to decidable types.** They are `∀a. a→a→Bool` today
  (`type_system.ml:305`), so `==` on functions/opaque TCons compiles to meaningless `equal?`; the HM-2 fix
  only covered ordering on record *literals* syntactically. Reject non-equatable/non-orderable operands at
  the type level over Tesl's closed type universe. · *root: decision-by-syntactic-proxy (the record-literal
  special-case) + unconstrained polymorphism.* · **enforced by** an `is_equatable`/`is_orderable` resolver
  in `infer_binop`, total over the type (not a syntactic operand match). · **M**
- **S15 — Single float choke point, split by purpose.** `Float_fmt.to_faithful_literal` (emission) and
  `Float_fmt.identity_key` (= hex of `Int64.bits_of_float`, for proof-subject identity at
  `validation_common.ml:1177` and proof-arg capture at `parser.ml:401`). Ban raw `string_of_float`/`%g` on
  floats elsewhere. · *root: ad-hoc serialization; proof-subject collision from `%.12g`.* · **enforced by**
  two property tests (round-trip; identity-key distinguishes signed-zero/NaN, no collisions). · **S**
- **S16 — Finish Tier-0 #2: derive the handler↔endpoint contract.** Positional count/type/proof contract
  derived from the endpoint, not re-stated (the prior name-based attempt false-positived on valid positional
  handlers; POST/PUT carry an implicit body param, auth-value position matters). · *root:
  declaration↔implementation contract restated, not derived.* · **enforced by** a derived check + an
  antagonistic suite of mismatched handlers. · **M**

---

## Open design decisions for the maintainer

Genuine choices with trade-offs, not clear bugs — framed for a decision (two are *documented* decisions
worth re-examining now that the cost is concrete):

1. **Per-function capability narrowing at runtime (CAP-3).** `§7.10` deliberately makes the
   declared-context capability check **compile-time only**; the runtime ambient is the whole-app union
   (`desugar.ml:652`), so `call-with-declared-capabilities` never narrows (`capability.rkt:58`). The cost:
   **any** static capability hole becomes a live *cross-capability* exploit (a `[dbRead]` handler that
   statically-unsoundly reaches `dbWrite` runs under the union grant). Option A (recommended): intersect
   `declared ∩ ambient` at each call so least-privilege is physically real and a static hole degrades to a
   contained denial — at a small per-call cost, and revise §7.10. Option B: keep the no-op but certify the
   static capability checker complete (it largely is, via the visitor). **Decision needed:** is per-handler
   least-privilege a runtime guarantee or a compile-time-only one?
2. **`Int` contract (HM-1).** The compiler rejects out-of-range *literals* but computed expressions overflow
   silently into bignums. Either (A) bounded checked arithmetic (broad emit/snapshot churn + a perf cost) or
   (B) document `Int` as arbitrary-precision and **drop** the literal-range error. Pick one and make the
   compile-time message match runtime reality.
3. **Env reads at module-load / bootstrap.** The `envRead` runtime guard is scoped to non-empty capability
   contexts; top-level config/agent-provider reads run unguarded by design (consistent with per-module cap
   validation and "main checked for `envRead` only"). **Decision:** record this as an explicit, tested
   boundary (a positive `bootstrap` capability the emitter grants only around top-level config reads), or
   accept and document it as-is. Either way it should be machine-checkable, not implicit.

---

## Exit criteria

The cycle is done when:

1. **G1 is closed first:** one authoritative exit-code gate with machine-readable verdicts, a derived
   run-set, skip-is-failure-unless-waived, and an independent emitter oracle — demonstrably turning **red**
   on an injected soundness or emitter regression (the test we never had).
2. **G2 is closed:** one builtin registry consumed by exhaustive match; the static-effect == dynamic-emission
   law holds; each soundness invariant has exactly one decision site.
3. **G5 is standing:** the generative negative corpus + attributed proof-layer mutation run in the gate over
   all proof-bearing files, with an enforced kill threshold.
4. Every closed class has a **generative** (not merely instance-pinned) guard, and the three open decisions
   above are recorded with their enforcing test.

Re-evaluate after G1+G2+G5: if these land with the project's demonstrated class-level discipline, the
trustworthiness of every future "fixed" claim is itself verifiable — the precondition for graduating from
"promising alpha" to "credible beta for its niche."
