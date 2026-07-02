# Tesl — Technical Review & Soundness Verification

**Audience:** evaluation engineers, compiler/type-system contributors
**Date:** 2026-07-02
**Reviewer stance:** external language-design review (the perspective of someone who has shipped a production type system). Critical, formal, adversarial — nothing taken at face value; every claim checked against the live compiler.
**Subject:** Tesl @ `main` (`adb5af1`), OCaml frontend + Racket runtime.

> **Methodology & independence.** I read the specification and the load-bearing compiler source (`proof_checker.ml`, `validation_common.ml`, `emit_racket.ml`, `validation_capabilities.ml`, `dsl/*.rkt`) directly, then ran the compiler (`compiler/_build/default/bin/main.exe`, `TESL_REPO_ROOT` set; Racket 8.18) against ~70 purpose-written adversarial `.tesl` programs. Every "confirmed hole" below was reproduced first-hand with a control (a legitimate baseline that compiles, so the delta isolates the security property). I deliberately did **not** read the repository's own prior review artifacts (`compiler/test/test_review*_antagonistic.ml`, `tests/critical-review-*`) to avoid anchoring on previously-found instances — those files' *existence and count* is treated only as a signal (see §7). A background multi-agent sweep (94 agents) produced 71 adversarial findings across 12 categories; 23 were independently confirmed as holes by a second agent, and I personally re-verified the critical ones.

---

> **Remediation status (2026-07-02).** A first pass has landed fixes for the
> critical cluster and several other findings; every item is tracked in
> `roadmap/next/review_2026_07_master.md`, with deferred remainder in
> `roadmap/later/review_2026_07_deferred.md`. Closed + verified: §5.1 (PF-3/4/5/6,
> AUTH-1, PFC-1 — `validate_ok_expr` and the `establish` walks are now total /
> fail-closed and descend into `EWith{Database,Capabilities,Transaction}`), §5.4
> (SHADOW-1/2/3 — the no-shadowing walk descends into constructor args / `fail`
> messages), §5.7 (AUTH-VIA — new `check_auth_proof_via`), SC-01 (order-insensitive
> ForAll comparison), the agent-context/debug-inspect/mutation-score tooling fixes,
> and the docs/template drift (§6). Carried forward (with partial work done): §5.2
> (PFC-2 container minting — direct forms gated, container needs engine-level
> proof-lifting), §5.3 (F1/F2 FromDb named-pack), §5.5 (Eq/Ord type-classes), §5.6
> (capability whole-program/registry), §5.8 (EE-1/LB-01/NT-07), and the
> generative-fuzz/runtime-witness backstop. Regression guard:
> `compiler/test/test_review75_reviewfixes.ml`.

## 1. What Tesl is

Tesl is a domain-specific language for building **web APIs** whose central bet is that most API defects are not "business logic is hard" defects but *boundary* defects: validation that is forgotten after decoding, auth wired by convention, effects that are ambient and invisible, and domain guarantees that evaporate a few calls past the boundary. Tesl attacks this by moving four concerns into the language:

1. **Proof-carrying values (GDP — "Ghosts of Departed Proofs").** A `check`/`auth`/`establish` function validates a value at the boundary and stamps it with a *fact* (e.g. `IsPositive n`, `OwnedBy user task`, `FromDb (Id == id)`) via the `:::` operator. Downstream functions demand facts in their parameter types (`fn f(n: Int ::: IsPositive n)`), so the compiler mechanically forbids passing unvalidated data. Facts are attached to a *hidden subject identity*, not to the surface variable name (spec §6.2, §7.3).
2. **Capabilities as an effect system.** Side effects (`dbRead`, `dbWrite`, `time`, `random`, `httpClient`, `email`, `queue`, …) must be declared in `requires [...]`; the lattice is compile-checked. Telemetry is a deliberate ambient exception (§5.2).
3. **Auth in signatures.** `auth` functions produce identity facts; endpoints wire them via `auth <binding> via <authFn>`; handlers demanding an auth fact cannot run without it.
4. **Domain features as first-class constructs.** Typed SQL/entities/databases, queues/workers, SSE channels, caches, email, telemetry, and AI agents (`Agent { … } asTool fn`) are language forms, not libraries.

The safety story is **compile-time only**: proofs are *erased* before the program runs (§4.3, §7.10). "Zero-cost" refers to this erasure. The runtime keeps a small, enumerable set of checks (capability grant, handler param/return shape, existential-witness escape).

**Architecture.** An OCaml frontend (~29 modules in `compiler/lib`, ≈10k LOC of analysis) does parsing, HM type inference, proof checking, capability/structural validation, then lowers to Racket via `emit_racket.ml`. A Racket runtime/substrate (`dsl/*.rkt`, `tesl/*.rkt`, ≈18k LOC) executes. There is no shared IR between backends: `emit_racket`, `emit_elm`, `emit_ts` each re-walk the surface AST.

---

## 2. Verdict summary

| Question | Verdict |
|---|---|
| Do the *ideas* hold water? | **Yes, strongly.** Proof-carrying boundaries + capability effects + auth-in-signatures for the web-API niche is a coherent, defensible thesis, and much of it is genuinely enforced (§4). |
| Does the *implementation* hold water? | **Core: yes. Boundary validators: no.** The cross-function proof engine is principled and sound. The boundary-*minting* validators are ad-hoc partial walks that fail open (§3). |
| Has it earned its right to exist? | **As an alpha/research language: yes.** As a "bet-a-company" production language: **not yet**, and the README says so. |
| Worth continued investment? | **Yes — conditional** on closing the *class* of defect in §3 before adding more surface. |
| Is the direction good? | **Partially misaligned** (§8): surface growth (AI agents) is outpacing the soundness model, and the adoption path is foreclosed. |

The single most important finding: **Tesl built the hard part correctly and then bypassed it.** There is a principled, subject-identity-based structural decision procedure for proofs (`proof_key`, `validation_common.ml:259`). The confirmed soundness holes do **not** live there — they live in the *separate, hand-rolled, non-total* validators that guard fact *minting* at boundaries, which either compare strings, fail to descend into some AST forms, or are applied to one return form but not its sibling. Because proofs are erased, each such gap is a live production forgery with no runtime backstop.

---

## 3. Root-cause analysis: one generator, many instances

Every confirmed critical/high soundness hole is an instance of **one class**:

> **Soundness-critical checks are implemented as multiple independent, hand-written AST traversals that FAIL OPEN, decide by surface spelling, or cover one surface form but not its sibling — and because proofs are erased, an escaped check is a silent production forgery with no runtime detection.**

Three mutually-reinforcing sub-factors:

**(A) Non-total traversal that fails open.** The load-bearing example is in `compiler/lib/proof_checker.ml`. The function that validates a `check`/`auth` body's `ok … ::: proof` against the declared return spec — `validate_ok_expr` (line 552) — is a hand-rolled recursion over `EIf/ECase/ELet/…` that bottoms out on a catch-all leaf and **never descends into `EWithTransaction`/`EWithDatabase`/`EWithCapabilities` bodies.** The tell is damning and local: *the same file* has sibling walkers (the `EOk`-search walks at lines 359 and 392, and the witness walk at 512–513) that **do** descend into exactly those wrapper nodes, via the shared visitor `Ast_visitor.fold_children` or explicit cases. Two walkers over the same AST disagree; the soundness-critical one was left behind in the "Wave-2" migration. Any expression form the walker forgot = an unchecked minting site.

**(B) Decide-by-spelling instead of the structural key.** The *within-body* comparisons in `proof_checker.ml` (`normalize_conj`, lines 56–59, used at 594/625; and the ForAll return check) compare `pp_proof`-rendered **strings**, not the structural `proof_key`. For plain conjunctions this has been hardened (sorting makes `A && B` = `B && A`, parens are normalized by the parser), so today it produces *false negatives* (over-strict) rather than false positives — but it means two comparison regimes coexist and disagree (the ForAll path is order-*sensitive* while the plain path is order-*insensitive*; SC-01). A refactor that flips which side is authoritative turns this into unsoundness. The *right* engine already exists next door: `proof_key`/`KAnd` over resolved subject identities (`validation_common.ml:259–273`) is what the cross-function call path uses, and it is sound (§4).

**(C) Erasure ⇒ no runtime backstop for proofs.** Proofs are erased (`emit_racket.ml`; `proof-satisfied?` only structurally matches an *already-attached* fact, never re-derives it). So the OCaml checker is the *sole* contract for proof truth. This is by design and is even a stated strength (small trusted runtime surface) — but it converts every (A)/(B) gap from "a bug the runtime would catch" into "a silent forged proof in production." Contrast capabilities, which *do* have a runtime backstop (`dsl/capability.rkt`) — that asymmetry is why capability gaps degrade to loud 500s while proof gaps degrade to silent exploits.

The same generator also explains **SHADOW-1/2/3** (the no-shadowing validator is another partial walk — it doesn't descend into bare `EConstructor` arguments, `fail`-message expressions, or lambda-in-constructor-arg), the **FromDb named-pack forgery** (the `body_has_db_site` provenance gate is applied to the `-> x: T ::: FromDb …` form but *not* the sibling `-> T ? FromDb …` form), and **EE-1** (existential enforcement bypassed by wrapping the value in any non-variable expression).

**This is why there have been 60+ review rounds** (54 of 139 compiler test modules are `review*/antagonistic/attack/critical`; `tests/` holds 23 `critical-review-*`). Each round finds one more AST form a walker forgot, pins it as a frozen fixture, and moves on. The *class* regenerates every time a new surface form is added (transaction blocks, `?` named-pack returns, agent blocks, container returns) — which is exactly where the current holes are. **Instance-by-instance patching cannot converge here.**

---

## 4. What Tesl gets *right* (this is not a house of cards)

Fairness demands emphasis: 45 of 71 adversarial probes were **correctly rejected or are principled by-design trust boundaries.** The sound core is real and, in places, better than its competitors:

- **The cross-function proof engine is subject-identity structural, not spelling-based.** `proof_key` (`validation_common.ml:259`) builds a canonical structural key over *resolved* subjects. Verified live: reusing a binder name `x` across scopes does **not** retarget a proof; a derived value (`let y = x + 1`) loses the proof while a pure alias (`let y = x`) keeps it; literals are per-occurrence subjects so a proof about one `5` can't be reused for another; field selectors are part of subject identity.
- **`attachFact`/`detachFact` retargeting is robustly blocked** (7/8 probes rejected): detach-from-A/attach-to-B/consume-B is rejected; laundering across a function boundary or through a `Maybe` case does not relaunder the subject; cross-subject `&&` combination onto a third value is rejected with both origin subjects named.
- **Direct proof forgery in a plain `fn` is rejected** — `x ::: P x` in a `fn`/`handler` body, and minting hidden in a `let`/`case` arm, are all caught (§7.12 holds for the *direct* form; it is only the *wrapper/container* forms that escape).
- **SQL is injection-safe by construction:** all values are `$N`-parameterized, identifiers pass a strict `^[A-Za-z_][A-Za-z0-9_]*$` allowlist before quoting, LIMIT/OFFSET are integer-guarded. **FromDb provenance for SELECT/UPDATE is genuinely verified** — wrong-column, where-less, OR-broadened, aliased, and *transaction-wrapped* select forgeries are all rejected (note: the SELECT verifier descends into `transaction{}` — the return-spec validator does not; more evidence for §3-A).
- **Type system:** HM core is sound (occurs check rejects `g g`; params are monomorphic); `Int` is arbitrary-precision (no overflow); partial functions are designed out (`List.head` → `Maybe`; division and `Dict.get` are proof-gated *and* runtime-rechecked); exhaustiveness analysis is genuinely thorough (nested patterns, literal-without-catch-all, all-guarded constructors, unreachable arms). Newtype nominal identity is enforced (`UserId` ≠ `ProjectId`).
- **Capabilities have a real runtime backstop** (every effect primitive calls `require-capabilities!`), effect analysis for the covered primitives is one shared `fold_children_env` walk (so a *new expr variant* cannot silently escape capability analysis — the good pattern §3 wants everywhere), and capability-row polymorphism is sound in the tested cases.
- **Auth runtime path is fail-closed:** the router gates before the handler; handlers can't be called directly; `define-server` refuses to build unless the handler's full param proof/shape matches the endpoint bindings (this backstop catches several *frontend* gaps at load time). Cross-predicate privilege escalation (`Authenticated` wired to an `IsAdmin` handler) is rejected at compile time.
- **Tooling:** `agent-context` is genuinely token-economical and useful; the headless step-debugger works and its three safety properties hold; the MCP server is a real working stdio JSON-RPC server; diagnostics are compact (E000/T001/P001/V001 + lint) and the error messages are *excellent* — actionable, with suggested fixes and manual deep-links. This is a real DX strength.
- **Erasure is genuinely implemented** (not a dead branch waiting to be re-enabled), and the runtime *type* oracle was recently hardened from fail-open to fail-**closed** for unknown concrete types (S13) — evidence the team knows the fix pattern.

The design axiom that `check`/`establish`/`auth` bodies are **trusted** (the compiler verifies the predicate is *restated*, not that the code *implies* it) is legitimate and analogous to Rust's `unsafe` — GDP guarantees *provenance*, not semantic truth. That is defensible and documented. It is *not* counted as a hole below.

---

## 5. Confirmed soundness holes (reproduced first-hand)

All repros were run with `--check`/`--check-json`; "accepted" = exit 0, zero error diagnostics. Controls (unwrapped variants) are rejected, isolating the property.

### 5.1 CRITICAL — Trust-boundary proof forgery via wrapper blocks (`validate_ok_expr` non-descent)

A `check`/`auth`/`establish` body wrapped in `transaction {}` / `with database` / `with capabilities` bypasses the return-spec proof check entirely, minting an arbitrary fact.

```tesl
check chk(n: Int) -> n: Int ::: B n =
  transaction {
    ok n ::: A n          # declares B n, proves only A n
  }
fn sink(n: Int ::: B n) -> Int = n   # forged B n flows here
```
**Observed:** accepted (exit 0). **Control** (no wrapper): `error[P001]: ok proof does not match declared return spec: got 'A n', expected 'B n'`. Confirmed for `check` (PF-3/4), `establish` (PF-5), and `auth` (PF-6, AUTH-1, PFC-1). The `auth` case is a **total authentication forgery**: `auth forgeAuth(request) -> user: String ::: Authenticated user = with database WDB { ok "attacker" ::: SomethingElse user }` compiles and emits a live `define-auther` that unconditionally accepts, minting `Authenticated` for every request.
**Root:** `proof_checker.ml` `validate_ok_expr` (552) does not descend into `EWithTransaction/EWithDatabase/EWithCapabilities`; sibling walkers (359/392/512) do.
**Class fix:** §9-1. **Instance fix:** add `| EWithTransaction {body;_} | EWithDatabase {body;_} | EWithCapabilities {body;_} -> validate_ok_expr body` (and route the whole validator through `Ast_visitor.fold_children`).

### 5.2 CRITICAL — Plain `fn` mints proofs via container-return (`Maybe (T ? P)` / `Either L (T ? P)`)

The `?` named-pack proof annotation on a *container* return type is honored on an ordinary `fn` with **no validation and no trusted-kind requirement**, breaking §7.12 wholesale.

```tesl
fn launder() -> Maybe (Int ? IsPositive) =
  Something (0 - 999)                 # -999 stamped IsPositive
fn attack() -> Int =
  case launder () of
    Nothing -> 0
    Something v -> needPositive v     # accepts -999
```
**Observed:** accepted (exit 0). Emitted Racket shows the proof is an erased annotation with no runtime guard, so `-999` flows through. Variants confirmed: `Either String (Int ? IsPositive)` via `Right`, and `Maybe (String ? IsAdmin)` (authorization laundering on an arbitrary string).
**Root:** §3-A applied to container/named-pack returns — the "only check/auth/establish may introduce a fresh proof" gate (`validation_advanced.ml`) is not applied to `RetNamedPack` inside a container.
**Class fix:** §9-1/§9-2. **Instance fix:** require the introducing function to be a trusted kind for any `?`/named-pack proof, on all container return forms.

### 5.3 CRITICAL — `FromDb` provenance forgery on the named-pack return form

```tesl
handler createTodo(claimedId: String)
  -> Todo ? FromDb (Id == claimedId) requires [...] =
  insert Todo { id: "totally-different-literal", ownerId: "x", createdAt: nowMillis() }
```
**Observed:** accepted (exit 0). The handler stamps `FromDb (Id == claimedId)` while inserting an unrelated literal id — unforgeable DB provenance fabricated from a hand-crafted record with no DB read of `claimedId`. Cross-tenant variant (`FromDb (OwnerId == victim)`) also accepted (F2). This **directly falsifies** the spec/lesson claim that "the FromDb proof is unforgeable except by calling the SQL forms."
**Root:** the `body_has_db_site`/`check_pk_match` gate is applied to `RetAttached` (`-> x: T ::: FromDb …`, correctly rejected) but **not** to `RetNamedPack` (`-> T ? FromDb …`). A gate on one surface form but not its semantic sibling (§3).
**Class fix:** §9-1/§9-2. **Instance fix:** apply `body_has_db_site` provenance verification to *both* return forms, and mint `FromDb` from the actual query's WHERE/RETURNING, not from the declared spec.

### 5.4 CRITICAL/HIGH — No-shadowing validator misses AST positions (proof forgery via shadow)

```tesl
fn forge(n: Int ::: InBounds n, raw: Maybe Int) -> Maybe Int =
  Something (case raw of
               Something n -> needsProof n     # 'n' shadows proof-carrying param
               Nothing -> 0)
```
**Observed:** accepted (only a W011 indentation warning). The raw `case` value reaches `needsProof` (which requires `InBounds n`) unproven. **Control** (same shadow *not* inside a constructor arg): `V001 case pattern binder 'n' shadows an existing name`. Also confirmed: lambda-param shadow inside a constructor arg (SHADOW-2), binder shadow inside a `fail` message (SHADOW-3).
**Root:** the no-shadowing walk does not descend into bare `EConstructor` arguments / `EFail` messages — §3-A again, in a *different* validator.
**Class fix:** §9-1.

### 5.5 HIGH — Type-directed decidability enforced by a divergent shadow inferencer (ordering/equality on non-comparable types)

Ordering/equality is a fully-polymorphic stdlib signature (`< : ∀a. a → a → Bool`) guarded by a *second*, hand-written `infer_expr_type` (`validation_common.ml`) that partially re-implements the HM checker. Where the two disagree, the guard fails open:

- `String.toInt a < String.toInt b` (both `Maybe Int`) — accepted; emits a Racket `(< (raw-value (Something…)) …)` **contract violation at runtime**. (Shadow inferencer returns `None` for stdlib-fn results → guard's `None → allow` arm.)
- `fn genLt(a,b) -> Bool = a < b` then `genLt f f` on functions — accepted, emits `(< f f)` crash; `genEq f f` emits `(equal? f f)` → silently `#f`. (The `TVar → true` arm doesn't participate in HM instantiation.)
- A record with a function field compared via `==` — accepted, `equal?` compares closures by identity → silently wrong. (`is_equatable` doesn't recurse through nominal type definitions.)

**Root:** decidability is enforced monomorphically at each syntactic comparison site by a shadow type system rather than as qualified types (`Eq`/`Ord`) in the real checker's generalization/instantiation.
**Class fix:** §9-6.

### 5.6 HIGH — Whole-program capability composition is not checked (compile-time-decidable error escapes to runtime 500)

`main`'s granted capability set is never verified to cover the transitive `requires` of the handlers/workers it serves (`validation_capabilities.ml:349-358` checks `main` only for `envRead`). Remove `random` from `main`'s grant while a handler still `requires [random]` → **compiles clean**, then every request 500s with `Missing capabilities: (random)`. Additionally, `UUID.v4/v7` require `uuid` at runtime but have **no arm** in the static allowlist (`var_caps`), so UUID generation typechecks with no `uuid` declared (dual hand-maintained registries with no cross-check — the same class as the known `env builtins` gap). And `cli.args` typechecks with no import but is **unbound at runtime** (`raco test` → `tesl_import_cli_args: unbound identifier`) — a checker↔runtime name-resolution drift (DRIFT-1).
**Root:** whole-program properties decidable at compile time but enforced only at runtime; dual registries without a conformance check.
**Class fix:** §9-3/§9-6.

### 5.7 HIGH — Auth `via` clause is never validated at the frontend

`auth <binding> via <authFn>` is not checked for (a) existence of `authFn`, (b) its kind, or (c) whether it produces the declared predicate — whereas capture `via` has all three checks (`validation_structural.ml:1010-1063`, `check_capture_proof_via`; no `check_auth_proof_via` exists). A typo'd or wrong-kind `via` target passes `--check-json` and fails only at Racket load or first request. Also: auth-wiring reconciliation is gated behind `if auth_preds <> []` (only runs if the module has ≥1 auth function), and auth-family predicates on a *second* identity-typed handler param can be satisfied from an unproven body at the frontend (caught only by the runtime `define-server` backstop). This is a **multi-identity / IDOR-class** weakness: relational `OwnedBy resource user` proofs are inexpressible at the boundary because auth and capture checkers each see only their own value, pushing developers toward unary `OwnedBy resource` proofs whose names overclaim.
**Class fix:** §9-2 (make auth `via` reuse the capture `via` validator) + a boundary story for two-subject authorization.

### 5.8 Lower-severity confirmed items

- **NT-07 (medium):** `Int` is unbounded bignum in the type system but silently narrowed to 64-bit BIGINT in Postgres storage and to JS `number` in Elm/TS codecs — no range check anywhere. "Well-typed" does not imply "round-trips." Runtime type oracle also conflates `Int`/`Float` (`2.0` satisfies `Int`), weaker than the checker.
- **CAP-01/CAP-06 (high/medium):** capability charging is inconsistent across call forms — a qualified-name call to an imported effectful function can escape the transitive charge; asymmetry with unqualified calls.
- **LB-01 (medium):** under bare `import Mod`, a library's `exposing` list is **not** enforced for facts — non-exposed proof predicates leak.
- **SC-01 (low):** ForAll conjunction comparison is order-*sensitive* (string compare) while plain conjunction is order-*insensitive* — a false-negative today, but two disagreeing comparison regimes are the §3-B smell.
- **EE-1 (medium):** existential-proof enforcement bypassed by wrapping the value in any non-variable expression.

---

## 6. Claims vs. reality (documentation honesty)

Of 84 spec/README/manual claims sampled against the live compiler: **46 verified, 23 partial, 13 false, 1 unsupported.** The *most consequential* soundness claims that verify true are genuinely enforced, and `TESL.md`'s alpha framing is exemplary (it pre-empts the over-claim risk by stating guarantees are compile-time with no runtime re-check). But the human-facing surface has drifted:

| Claim | Status | Reality |
|---|---|---|
| "From nothing to a running, type-checked API in three steps" (README) | **False** | Both `tesl init` scaffolds (`templates/minimal`, `templates/api`) fail `--check` with V001 (`main` reads env but doesn't declare `envRead`) + W050 warnings. **The generated starting point does not typecheck.** |
| FAQ teaches working syntax | **False** | `requires [db]` (real: `dbRead/dbWrite`) → P001; chained `::: A ::: B` → E000; `forall x in xs, p` → E000 (fictional). Beginners copy-paste errors. |
| "Proof annotations are zero-cost / no allocation" (best-practices "Proof Cost Model") | **False (overstated)** | A proof-*annotated parameter* allocates a `named-value` at runtime (`web.rkt:604`, `check-runtime.rkt:664`, confirmed via `raco expand`); `check` builds `check-ok` structs. Spec §4.3 fine-print admits "one allocation retained"; the single-sourced summary rounds it to "Zero." |
| "FromDb is unforgeable except by calling the SQL forms" (lesson18) | **False** | §5.3. |
| "check/auth ok proof is validated against the declared return spec" | **False** (partial) | §5.1 — holds except inside wrapper blocks. |
| "Only check/auth/establish may introduce a fresh proof" | **Partial** | §5.2 — false for scalar/container named-pack returns. |
| "The Racket runtime is an implementation detail; swappable to Rust/Zig" (spec §150) | **False** | No backend seam exists; the swappable-runtime item is in `roadmap/discarded`; `swappable-runtime-backend.md` itself says the claim "is aspirational, not real." |
| "`ir.ml` is the compiler's IR" | **False** | It's a parse-driven JSON *tooling export*; TS/Elm generators consume `Ast.module_form` directly (`dev-docs/11-frontend-ir.md`). |
| "Native OTLP exporter not yet implemented / aspirational" (spec §5.2, §66) | **False (understated)** | `dsl/otel.rkt` implements it and posts OTLP/HTTP+JSON to `<endpoint>/v1/logs`. Stale disclaimer. |
| "type_at: line 1-based, col 0-based" (MCP README) | **False** | CLI treats line as 0-based; off-by-one for every position query following the README. |
| "Remediation: run `tesl fmt <file>`" (fmt-check hint) | **False** | No bare `fmt` subcommand exists (only `--fmt`). |
| `agent-context` gives "the whole compiler/linter picture" (AGENTS.md/MCP) | **Partial/false** | It **drops all linter warnings**; since the checker emits no warnings, its warning count is effectively always 0. The documented "1 warning" example is unreachable via the primary agent loop. |

**Class:** *unverified prose that isn't under the green-check gate silently rots.* The accurate source of truth (`LANGUAGE-SPEC.md`, and the compiled `example/` corpus) is not what beginners read first, and the spec's own `tesl` code blocks are not compiled by CI (spec examples use `--` comments, which Tesl rejects).

---

## 7. Verification methodology critique (are the green checks meaningful?)

The gate (`ci.sh`, `compile-examples.sh`) is **large and honest in its core**: ~3839 Alcotest cases over 139 modules with an *explicitly empty, dated* waiver list (a real `[FAIL]` fails the gate — not swallowed by a substring grep as in a documented predecessor); there is a genuine generative, attributed-kill soundness layer; and a §7-invariant registry test binds each spec invariant to a red→green antagonistic program and asserts the KnownGap set is *exactly* expected. That is above-average rigor.

But the gate has systematic blind spots that let the §3 class survive:

1. **The generative soundness defense is 9 hand-written seeds × 7 hand-annotated transforms** — not a fuzzer over arbitrary accepted programs, not derived from the 80+ example corpus. A forgery expressible only in a program shape none of the 9 seeds instantiate is untested *by design*. The `transaction{}`-wrapper holes (§5.1) are exactly such a shape.
2. **Mutation testing in CI is a single curated file** (`lesson42`, 20 synthetic mutants, 100% killed) — `ci.sh:873`. None of the ~80 examples or 37 test files with real `check/auth/establish` boundaries are mutation-tested. And `if scored = 0 then 100.0` lets an all-invalid file report a perfect score.
3. **Property tests pass vacuously.** A `where`-guarded property with a rarely-true guard runs zero effective iterations and passes green — proven live: a **false** property with guard `n == 999999999` passes over 200 draws in `[-1e6, 1e6]`. No min-success/discard floor (`emit_racket.ml:5607`). Proof-carrying generators exist for only 3 hardcoded predicates.
4. **No program-space fuzzing, no differential oracle.** The only randomness in the tree is fixture IDs. There is no grammar-based program fuzzer and no checker-accept-vs-runtime-behavior differential — the two tools that would mechanically surface §3.
5. **Skip-is-success semantics:** 16 phase sites self-skip (not fail) when a tool is missing; a box lacking Postgres runs *zero* DB-backed coverage yet can still print "All good." Golden `.rkt` snapshots are self-referential (they enshrine a stable-but-wrong emit). The runtime suite is non-hermetic (a stale `.zo` cache from Racket 9.2 vs PATH 8.18 broke every aggregate test until 12 `compiled/` dirs were wiped).

**The 60+ regression rounds are the diagnostic.** 54/139 test modules are frozen past-bug fixtures. This is a *regression-fixture-accretion* posture: every found hole becomes a pinned example, not a generator covering its class. It plateaus at "the bugs we already found" and leaves adjacent instances exposed — which is precisely the observed pattern.

---

## 8. Architecture & trajectory

**Frontend/runtime split (good bones, missing seam).** The OCaml frontend genuinely owns all static guarantees, and coupling to Racket is confined to the emission stage — a clean place to insert a seam *later*. But no seam exists today: `emit_racket.ml` writes ~321 raw Racket forms directly, and three emitters re-derive lowering from the surface AST independently (O(N) hand-synchronized edits, drift caught only by tests). The spec's "swappable to Rust/Zig" claim is false today and the enabling roadmap item was **discarded**. The runtime also carries irreducible trusted semantics (ambient whole-app capability union — per-handler narrowing was attempted and reverted; param/return shape validation; skolem-escape) that any rewrite must reproduce exactly, and these are not written down as a conformance ABI.

**Goal-vs-investment mismatch.** README's stated goal is mainstream adoption ("a normal programmer… can answer *Tesl*"). Yet every adoption enabler — package manager, library support, online playground, homepage, static-binary/Docker distribution — is in `roadmap/discarded`. Install is **Nix-only** (the project's own estimate: ~5% of developers). Meanwhile investment flows to internal soundness polish and an **AI-agent surface expansion** (`Tesl.Agent`, declarative agent blocks, provider transports, ~1045 LOC Racket) — and `capability_map_single_source.md` documents that the agent-block capability model is *incomplete* (a `DAgent` declaring `[aiProvider]` can host a `[dbWrite]` tool without the row being checked). **Surface is growing faster than the soundness model covers it — the exact pattern the stability work is trying to reverse.**

**History opacity.** 97 commits, 89 squashed into June 2026 with messages like "wip"/"Improve correctness," plus several unmerged squashed branches. The "112 completed roadmap items" cannot be independently verified from the log; regression bisection in the churn-heavy checker/emitter is hard.

---

## 9. Recommendations — remove the class first

Ordered by leverage. The first four close the §3 generator; do them **before** any new language surface.

**1. Make every soundness-critical traversal total and fail-closed.**
Ban the `| _ -> ()` / `[else #t]` catch-all in the proof-return, shadowing, existential, and provenance validators. Route them all through the shared `Ast_visitor` and remove wildcard leaves so **OCaml's own exhaustiveness checker forces every new AST variant to declare how proofs/subjects/capabilities flow through it.** This is the Rust/Elm/Zig move — *make illegal states unrepresentable in the compiler's own code*. It directly kills §5.1, §5.2, §5.3, §5.4, §5.8-EE-1 in one structural change, and prevents the next surface form from reopening the hole. (The capability analysis already does this via `fold_children_env` — generalize that pattern.)

**2. One decider per property; delete the duplicates.**
Two proof-return walkers in one file (one migrated, one not); two type inferencers (HM + shadow); two capability registries (compile-time allowlist + runtime primitives); a provenance gate on one return form but not its sibling. Each pair *will* drift, and every drift is a fail-open. Collapse each: have the single HM checker attach resolved types to the AST and have validation *consume* them (never re-infer); make all proof comparisons use the structural `proof_key`, never `pp_proof` strings; enforce provenance on all return forms via one function.

**3. Add a runtime proof witness as a differential backstop (gated build).**
Because proofs are erased, checker bugs are invisible in production and in tests. Under a `--verify`/CI build, retain proof witnesses and run the entire example+test corpus asserting **runtime witnesses match compile-time claims.** Capabilities already have a runtime check; proofs deserve one *at least in CI*. This converts "silent production forgery" into "a failing test the instant a checker gap exists" — and would have caught every §5 hole automatically.

**4. Replace regression-fixture accretion with generative + metamorphic testing.**
Add (a) a grammar-based program fuzzer feeding `--check`; (b) a **differential oracle** (checker-accept vs. runtime-witness from #3); and (c) **metamorphic wrappers** — mechanically take every accepted `ok`/return in the corpus and re-wrap it in `transaction{}`, `with database`, `Maybe`, `Either`, a constructor arg, a `fail` message — and assert the verdict is unchanged. That single metamorphic property would have found §5.1/§5.2/§5.4 with zero human imagination. Keep the frozen fixtures, but stop treating them as the coverage story.

**5. Mint provenance from query semantics, on all forms.** `FromDb` facts should be derived from the actual SELECT WHERE / INSERT RETURNING, not the declared spec; or treat insert-provenance as an explicit `establish` (visibly trusted) rather than silently auto-minted.

**6. Make effect/decidability analysis type-directed, not spelling-directed.** Model `Eq`/`Ord` as qualified types participating in generalization/instantiation (kills §5.5); charge capabilities from *resolved* types, not name tables (kills the UUID/`cli.args`/qualified-call gaps §5.6); check whole-program capability composition (`main` grant ⊇ union of reachable `requires`) at compile time.

**7. Gate the human-facing surface.** Put `tesl init` templates, FAQ/best-practices code, and the spec's `tesl` code blocks under the *same* compile gate as `example/`. First-touch artifacts that don't typecheck are the worst possible first impression for a language whose pitch is "the correct path is the obvious path."

**8. Strategy: freeze surface growth until 1–4 land; then decide adoption vs. research.** Either re-open the adoption path (non-Nix install, a playground, a minimal package story) or explicitly reposition as a research vehicle. The current split — production-adoption *goal* with research-project *investment* and a growing AI surface outrunning the soundness model — is the classic pre-1.0 failure mode.

---

## 10. Appendix — confirmed holes by severity

| Sev | ID | One-line |
|---|---|---|
| Critical | PF-3/4, PFC-1 | `transaction{}`-wrapped `check` mints an unrelated fact; flows to consumers |
| Critical | PF-5 | `establish` wrapped in `transaction{}` returns wrong Fact unchecked |
| Critical | PF-6 / AUTH-1 | `auth` wrapped in wrapper block = total authentication forgery |
| Critical | PFC-2 | Plain `fn` mints proof via `Maybe (T ? P)` / `Either L (T ? P)` |
| Critical | F1/F2 (domain) | `FromDb` provenance forged on `-> T ? FromDb` (incl. cross-tenant `OwnerId`) |
| Critical/High | SHADOW-1 | Shadow inside constructor-arg `case` forges proof onto raw value |
| High | SHADOW-2/3 | Shadow escapes V001 in lambda-in-ctor-arg and `fail`-message positions |
| High | TS-ORD/EQ | Ordering/equality on `Maybe`/functions/records typechecks → runtime crash / silent wrong |
| High | CAP-COMPOSE | `main` grant not checked ⊇ reachable `requires` → runtime 500 |
| High | CAP-UUID / DRIFT-1 | `uuid` uncharged statically; `cli.args` typechecks but unbound at runtime |
| High | CAP-01 | Qualified-name effectful call escapes transitive capability charge |
| High | AUTH-VIA | Auth `via` clause unvalidated at frontend (typo/wrong-kind/wrong-predicate) |
| Medium | LB-01 | `exposing` not enforced for facts under bare `import Mod` |
| Medium | NT-07 | `Int` bignum silently narrowed at DB/JS boundaries; no range check |
| Medium | EE-1 | Existential enforcement bypassed by non-variable wrapper |
| Low | SC-01 | ForAll conjunction comparison order-sensitive (string compare) |

**Not counted as holes (by-design trust boundaries):** `check`/`establish`/`auth` bodies restate rather than prove their predicate (GDP provenance, not truth) — legitimate, analogous to `unsafe`, but it means the *entire* guarantee reduces to the correctness of hand-written boundary bodies **plus** the wiring checks in §5.7. Harden the wiring; the axiom itself is fine.

---

*Prepared from first-hand compiler execution and source reading, cross-checked against a 94-agent adversarial sweep. Repros are in the review scratch area; each is a few lines and re-runnable with `TESL_REPO_ROOT=$(pwd) compiler/_build/default/bin/main.exe --check <file>`.*
