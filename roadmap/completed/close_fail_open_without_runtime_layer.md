# Systematically close "fail-open / silent-fail" — WITHOUT a large runtime layer

**Status:** proposed (2026-07-03 review follow-up)
**Motivation:** The 2026-07 fresh review found 16 soundness holes, all one class: a
verifier recognizes one syntactic shape / spelling / kind-set and *fails open*
(accepts) for everything else, and because proofs are erased there is no
backstop. The obvious fix — an opt-in runtime verification build that re-checks
proofs/caps/provenance — was **rejected by the maintainer**, for good reasons:

> A runtime verifier is itself a large, unverified, bug-prone body of code. "Who
> watches the watchman?" It duplicates the checker's logic (a second place to
> drift), adds per-request cost, and its own bugs are new silent-unsoundness
> vectors. The goal is to close the *fail-open* holes at the root, not to bolt a
> second fallible checker behind the first.

This item collects **static, TCB-shrinking** alternatives. The through-line: make
fail-open *unrepresentable* and make the *trusted core small enough to audit*,
rather than adding a second large thing to trust.

---

## The root property we want

> Every place that decides "is this proof / capability / provenance / type
> admitted here?" is a **total function that defaults to REJECT**. An
> unrecognized shape is a rejection (or an *explicitly enumerated, reviewed*
> keep-open), never a silent accept. And the code that can *introduce* a proven
> fact is small enough to read in one sitting.

Everything below serves that. They compose; the recommendation combines A + B + E.

---

## Cross-cutting constraint: fail-closed must stay PLATINUM, not go Haskell-terse

A core Tesl goal is **platinum-grade diagnostics** — clear, constructive, helpful,
not merely *correct*. This is a first-class design constraint on every option here,
because the naive way to "fail closed" is to reject unrecognised input with a
generic message ("provenance not verifiable"), which is exactly the failure mode
that makes minimal, elegant systems unpleasant to use.

The Haskell-GDP model (Option B's inspiration) buys a ~5-LOC TCB precisely by
reducing proofs to phantom types — but that minimalism is *also* its error ceiling:
a failed proof surfaces as a raw GHC unification error about phantom type
variables, stripped of domain meaning. That ceiling is structural: there is no
place in the elegant encoding to attach "you fetched by `Title` but declared
`FromDb (Id == todoId)` — filter on `Id` instead." Tesl deliberately pays for a
larger bespoke checker to escape that ceiling; **no fix in this item may quietly
re-impose it.**

Two rules make this concrete and enforceable:

1. **Rejections are structured diagnostics, not booleans/strings.** The `verdict`
   type in Option A must carry a *rich* reason:
   ```ocaml
   type verdict = Admit of evidence | Reject of Diagnostic.t
   (* Diagnostic.t: stable code + one-line WHAT + WHY + the EXPECTED canonical
      form + a machine-applicable FIX when derivable + a precise source span. *)
   ```
   Making the reason a `Diagnostic.t` (never a bare `bool`/`string`) means the
   *type system of the compiler itself* forces every fail-closed path to be as
   helpful as an accepting path is silent. "Fail closed" and "fail helpfully"
   become the same act.

2. **Every new rejection ships with a golden-diagnostic test.** The exact error
   text (code, message, hint, fix) is part of the contract, snapshot-tested, so a
   refactor cannot silently degrade a platinum message into a terse one. A
   fail-closed rejection with a poor message is a *bug*, not a lesser success.

The bar to hold every rejection to — already met by the 2026-07-03 fix for the
FromDb fail-open (`validation_capabilities.ml check_provenance_spelling`):

> `provenance predicate in the return of 'getTodo' must be written as
> 'FromDb (Column == subject)'; the form 'FromDb todoId' is not a checkable
> provenance spelling, so its DB origin cannot be verified`
> *Hint: write the provenance as 'FromDb (Column == subject)' (e.g. 'FromDb (Id == todoId)')…*

That names the exact form seen, shows the canonical form, and points at the fix —
correct **and** constructive. Every fail-closed site in this program must clear
that bar.

---

## Option A — Fail-closed by construction (PRIMARY; adds zero runtime code)

Make the soundness verifiers *total* and *default-deny* in their own types, so
"return nothing / fall through" cannot mean "accept."

1. **A `verdict` type that has no silent-accept.** Replace the ad-hoc
   `bool` / `_ option` / `_ list` results of soundness recognizers (e.g.
   `extract_col_eq_var`, the codec-coverage scan, the agent-tool recognizer, the
   `Fact`-typed-field obligation collector) with:
   ```ocaml
   type verdict = Admit of evidence | Reject of reason
   ```
   There is no third constructor, so a function *must* say Admit or Reject — the
   compiler will not let you "forget" a shape and have it read as Admit. The
   current failure mode (`| _ -> []` / `| _ -> true` / `| None -> (* skip *)`)
   becomes impossible to express as an accept.

2. **Exhaustive matches everywhere soundness is decided.** The codebase already
   uses `[@@@ocaml.warning "@8"]` in some modules to turn a non-exhaustive match
   into a *build error* (great — see `validation_common.ml` func_kind gate).
   Extend that discipline to **every** proof / capability / provenance / SQL-codec
   / field-obligation function. Then adding a new AST node, return-spec form,
   proof shape, or `func_kind` forces an explicit soundness decision at compile
   time instead of silently defaulting to accept.

3. **Total traversal over the proof grammar.** Where a verifier only understands
   `(Col == subj)` (FromDb) or the `:::` surface form (field obligations),
   rewrite it as a total function over the *whole* `proof_expr` / return-spec /
   type grammar whose default arm is `Reject`. Unrecognized-but-valid shapes then
   reject (fail-closed), which is the sound polarity — worst case is
   over-rejection, which is loud and fixable, never a forge.

**Cost:** a focused refactor of existing checker code. **New runtime code: none.**
This alone retires most of the 16 holes and prevents the *next* one of the same
shape. It is the single highest-leverage move and should ship first.

---

## Option B — Shrink the trusted kernel (LCF / de Bruijn); the real answer to "who watches the watchman"

The review measured the effective TCB at ~39–55k LOC (checker + emitter +
runtime), versus ~5 LOC + the host type-checker in the Haskell-GDP model Tesl
cites. The principled way to make the watchman trustworthy is to make it **tiny**,
not to add a second one.

**Idea (LCF architecture):** introduce a small *private* "proof kernel" module
inside the compiler that is the **only** code able to construct a
`proven_fact` value. Everything else in the 40k-line checker consumes
`proven_fact`s but cannot fabricate one. The kernel exposes a minimal, auditable
interface — roughly:

- `mint_at_boundary : func_kind -> …  -> proven_fact`  (only accepts Check/Auth/Establish)
- `pass_through : input_proof -> subject_subst -> proven_fact`
- `conj_intro : proven_fact -> proven_fact -> proven_fact`
- `framework_provenance : db_site_witness -> proven_fact`  (FromDb/FromQueue, gated on a real site)

A `proven_fact` is an abstract type with a hidden constructor (like OCaml's
private/abstract types, or GDP's hidden `Named` constructor). Because the type is
abstract, *no* amount of buggy logic elsewhere can mint one — a bug in the 40k
lines can only cause **over-rejection** (annoying, loud), never a forge. The
trusted surface collapses from ~40k LOC to a few hundred you can read and unit-test
exhaustively.

This mirrors exactly how Haskell-GDP gets a ~5-LOC TCB, and how LCF/Isabelle/Coq
keep a small trusted kernel behind a large untrusted elaborator. It is a refactor
of the checker's *internals*, not new runtime code.

**Why this does NOT inherit Haskell's cryptic-error ceiling (important).** The
worry with "shrink the TCB toward the Haskell-GDP model" is that you also inherit
its terse errors. You do not — *if* the split is done right — because an LCF
architecture **decouples soundness from helpfulness**:

- the tiny **kernel** is the only thing that must be *correct* (it guarantees no
  forge);
- all the **domain-aware, heuristic, friendly diagnostics** live in the large
  **untrusted elaborator**, which has full context (source spans, the user's
  spelling, the entity/field names, "did you mean").

Because the elaborator rejects bad programs with a platinum message *before* the
kernel would ever refuse them, the kernel's own failure path is essentially
unreachable in practice and never needs to be user-facing. So you can make the
elaborator arbitrarily clever and friendly **without widening the trusted core** —
the exact freedom Haskell-GDP lacks, where the "elaborator" is GHC's unifier and
the only error it can give is a phantom-type mismatch. This is Tesl's structural
advantage: small trusted kernel *and* platinum errors, at the same time. The
elaborator's diagnostics are not trusted for soundness, so investing heavily in
them costs nothing in TCB size.

**Cost:** medium/large one-time internal refactor. **New runtime code: none.**
Pairs naturally with A (the kernel's entry points are the total, fail-closed
functions, and A's `Diagnostic.t`-carrying `verdict` is produced by the
elaborator, keeping messages platinum).

---

## Option C — Proof certificates / a justification ledger (strongest static guarantee)

Have the (large, untrusted) checker EMIT, per accepted program, a machine-checkable
**justification** for each discharged obligation: "proof `P x` here is admitted
because it was minted by `check foo` at L:C" or "passed through param `p`, subject
`x→y`." A **small, independent** certificate-checker then validates the ledger is
well-formed and every admitted proof traces to a trusted mint or a pass-through
chain.

This is proof-carrying-code applied internally (the de Bruijn criterion): the
certificate-checker only *validates a derivation*, it does not *re-derive*, so it
is tiny and auditable — the watchman is small by construction. It can run in CI on
the example corpus, not per-request, so there is no runtime cost.

**Cost:** design a certificate format + a small validator. **New runtime code:
none** (CI-time only). Heavier than A/B; consider after them if a stronger,
inspectable guarantee is wanted. Complements B (the kernel can emit the certificate).

---

## Option D — Conservative "shadow" oracle for differential testing (finds NEW holes cheaply)

Not a backstop that ships — a **test-only** second checker that is deliberately
*simple and over-conservative*: it only needs to be **sound** (may reject valid
programs), never complete. Run it in CI against generated/mutated programs: **if
the real checker ACCEPTS something the conservative shadow REJECTS, flag it for
human review.** The shadow is small (it can be crude — e.g. "reject any program
where a proof-consuming call's argument isn't syntactically traceable to a
check/auth/establish or an input proof") precisely because it may over-reject.

This answers "who watches the watchman" with a *smaller, auditable* watchman that
runs only in CI and only needs the easy half of the spec (soundness lower bound).

**Cost:** a small conservative checker + a differential harness. **Ships: no**
(CI-only).

---

## Option E — Fix the self-fulfilling gate (mandatory regardless of A–D)

The review's key process finding: `mutate.ml` records a mutant as a regression
test **only when the checker already rejects it** (`is_attributed_kill`), and
silently drops (`else None`) any mutant the checker *accepts* — i.e. a live hole
is invisible to the gate. So the corpus can only guard *closed* holes; it can
never surface a *new* one. This is why 60+ review rounds keep finding fresh holes.

Changes:
- In `mutate.ml`: a forgery-transform mutant that the checker **accepts** is a
  **candidate hole → surface it / fail the build for triage**, not a silent drop.
  (Pair with a small allowlist for known-benign accepts.)
- Broaden the transform vocabulary beyond the 6 declaration-level shapes to the
  classes the review exploited: value-level mint, provenance-by-spelling,
  cross-module trust, field/kind gaps, positional binding.
- Add property/metamorphic tests asserting the **meta-invariant**: "every proof a
  compiled program admits traces to a trusted mint or a pass-through" — over
  randomly generated programs.
- CI hygiene: **SKIP ≠ PASS** (today a host lacking racket/initdb skips whole
  phases and the gate still prints "All good"); byte-check `.rkt` snapshots beyond
  `example/learn`.

**Cost:** moderate; mostly test-infra. **New runtime code: none.** This is what
makes A/B/C durable — without it, a future fail-open regression is invisible again.

---

## Recommendation

**A, B, and E are NOT alternatives — they are complementary layers, and the target
is to do all three (A + B + E).** A earlier draft read as "A instead of B"; that
was a sequencing statement, not a preference. They operate at different levels:

| Layer | What it guarantees | What it does NOT do alone |
|---|---|---|
| **A** fail-closed by construction | Each verifier is *total* and default-deny, so no site silently accepts an unrecognised shape. Great localized platinum errors. | Doesn't shrink the TCB — all ~40k LOC are still trusted; a *bug* in a verifier (not just a missing shape) can still be unsound. |
| **B** LCF proof kernel | Only a tiny kernel can mint a `proven_fact`, so a bug *anywhere else* can only over-reject, never forge. Shrinks the trusted core to a few hundred auditable LOC. | Doesn't by itself make the elaborator's decisions total/helpful — that's A's job; B just makes them *unable to be unsound*. |
| **E** fix the gate | Makes any regression of A or B *detectable* (accepted-but-should-reject mutants surface; SKIP≠PASS). | Doesn't fix anything itself — it's the safety net that keeps A and B honest over time. |

So they compose exactly as you read it: **A** makes every decision site
correct-and-helpful by construction; **B** makes the whole architecture unable to
forge even where A has a bug; **E** ensures neither silently regresses. B's kernel
entry points *are* A's total fail-closed functions, and A's rich `Diagnostic.t`
lives in B's untrusted elaborator — they interlock.

**Why sequence A before B (in time, not priority):**

1. **A + E first.** A is the smaller, faster refactor that *directly* closes the
   16 holes and their class, with platinum errors, and E makes it stick. Highest
   immediate ROI, and it produces the total fail-closed functions that become B's
   interface — so doing A first means B is a re-housing of already-correct code,
   not a rewrite.
2. **B next.** With A's entry points in place, factor them behind the abstract
   `proven_fact` kernel to collapse the TCB from ~40k to a few hundred trusted
   LOC — the principled, durable answer to "who watches the watchman." (B *can*
   be started in parallel by whoever owns the checker internals; it just lands
   more cleanly once A exists.)
3. **C (certificates) / D (shadow oracle)** — genuinely optional add-ons, only if
   an externally-inspectable guarantee (C) or a stronger novel-hole finder (D) is
   wanted after A + B + E. Not required for soundness.

No runtime verification layer is required at any step. The trust does not move to
a new large body of code — under A it becomes total and loud, under B it *shrinks*
into a small auditable core, and under E the gate can actually detect regressions.

## Progress — 2026-07-04 (A + B + E + discovery ALL DONE)

> **Update:** Option B's atomic `proof_env` flip landed 2026-07-04 — see
> "Option B — step 2 LANDED" below. All four layers (A fail-closed, B LCF kernel,
> E gate, discovery fixpoint) are now complete and gate-green. The text below is the
> pre-flip status kept for history.

**The soundness mission of this item is complete and verified.** The 16 fail-open
holes (and the roadmap `hole-*` + `eq_ord` instances) are ALL closed by Option-A-style
fail-closed fixes, Option E's gate is fixed, and the discovery loop is at a fixpoint.

- **Option A (fail-closed by construction) — effectively DONE for the known class.**
  Every one of the 16 holes was closed with a total, default-deny decision + a platinum
  diagnostic (field-proof type identity, Fact-typed-param, establish delegation,
  relational auth/capture subject, cross-module effect re-verification, imported generic
  Eq/Ord, …). Exhaustive-match discipline (`-warn-error +8`) is already library-wide, so
  a new AST/return-spec/proof shape forces an explicit decision at compile time. The
  dedicated `type verdict = Admit | Reject of Diagnostic.t` wrapper (a uniform refactor of
  the remaining ad-hoc `bool`/`option`/`list` recognizers) is NOT yet introduced — the
  fixes were applied at each site directly; folding them behind one `verdict` type is a
  cosmetic/uniformity refactor that closes no additional hole.
- **Option E (fix the self-fulfilling gate) — DONE** (committed earlier: SKIP≠PASS,
  accepted-load-bearing-mutant = candidate hole, `TESL_S7_EXHAUSTIVE=1` default).
- **Discovery loop — DONE, at fixpoint.** Exhaustive S7 = **2314 attributed kills, ZERO
  load-bearing candidate holes**. The 4 census transform classes are all non-load-bearing
  (verified, incl. a fresh triage of retarget-return-subject: an out-of-scope forged
  subject is rejected `T001`, and even when accepted is INERT — matches no downstream
  requirement).
- **Full `ci.sh` GREEN under Racket 9.2** — all 11 phases, no skips (454s).

**Remaining: Option B (LCF `proven_fact` kernel).** This is the TCB-shrink capstone —
a private kernel that is the ONLY code able to construct a `proven_fact`, collapsing the
trusted surface from ~40k LOC to a few hundred. It is an **all-or-substantial** refactor
(the abstract type gives its guarantee only when NO site outside the kernel can mint —
the minting/`proof_expr`-construction surface is ~229 sites across
checker/validation/proof_checker), so a partial migration provides no guarantee and is
best done as one focused, gate-green campaign by whoever owns the checker internals (as
this item itself notes). It closes **no currently-open hole** (discovery is at a
fixpoint); it hardens against FUTURE bugs. Recommended next step: add
`proof_kernel.ml`/`.mli` and migrate minting innermost-first
(`validation_common → structural → proof → capabilities/advanced → proof_checker`), each
site gate-green, `fact_of` keeping all `proof_matches` consumers unchanged.

### Option B — step 1 landed (2026-07-04, commit 9cd7588); atomic flip remains

`compiler/lib/proof_kernel.ml`/`.mli` added: the abstract `proven_fact` + admission
rules (`mint_at_boundary` check/auth/establish-only, `framework_provenance`,
`assume_param`, `pass_through`, `conj_intro`, `fact_of`). Inert so far — the design
+ interface (the crux) is locked, gate-green.

**Remaining (the atomic flip — one focused gate-green campaign):**
1. Change `Validation_common.proof_env` element type from `proof_expr` to
   `Proof_kernel.proven_fact` (`type proof_env = (string * proven_fact list) list`).
   This is ATOMIC: `proof_env` has ~324 references across
   validation_{common,structural,proof,advanced}.ml, so the build only goes green
   once every one is migrated — it lands as a single campaign, not incrementally.
2. Route every PRODUCER through a kernel rule (the `-warn-error`/type errors pinpoint
   each): check/auth/establish return admission → `mint_at_boundary fd.kind`;
   FromDb/FromQueue grants → `framework_provenance`; a proof-carrying param's proof →
   `assume_param`; `carried_proofs_of_expr` subject-subst → `pass_through`; `introAnd`
   → `conj_intro`. A catch-all/unrecognized shape now yields "no `proven_fact` → no
   admission" (fail-closed) by construction.
3. Route every CONSUMER through `fact_of` (proof_matches / pp_proof / proof_key all
   keep taking `proof_expr`, so they read `fact_of pf`).
4. `andLeft`/`andRight` need a `conj_elim_left`/`conj_elim_right` kernel rule — add to
   the kernel when that site is migrated.
5. Verify: `dune test` + exhaustive S7 (kills must stay ≥ 2314) + `ci.sh` under 9.2;
   the migration must be behaviour-preserving (proven_fact = proof_expr under the
   hood), so no diagnostic changes — only the trusted surface shrinks.

Because `proven_fact` is a transparent alias for `proof_expr` inside the kernel, the
flip is purely a compile-time discipline (zero runtime/behaviour change); its payoff
is that after it, no code outside proof_kernel.ml can mint a fact.

### Option B — step 2 LANDED (2026-07-04): the atomic flip is DONE

`Validation_common.proof_env` is now `(string * Proof_kernel.proven_fact list) list`.
The whole `proof_env` producer/consumer surface across
validation_{common,structural,proof,advanced}.ml was migrated in one gate-green
campaign. **After this flip, no code outside `proof_kernel.ml` can construct a
`proven_fact` — the abstract type makes it a compile error, so a bug anywhere in the
~40k-line checker can only OVER-reject, never forge.** The fact-introduction surface
is now a small, greppable set of named kernel-rule calls (audit:
`grep -E 'Proof_kernel\.(mint_at_boundary|framework_provenance|assume_param|pass_through|conj_intro|conj_elim_left|conj_elim_right|conj_split|elaborated)'`).

**Kernel rules as landed** (a few added beyond step-1's set, each a distinct trust
axiom, all identity-on-`proof_expr` except `mint_at_boundary`'s fail-closed `None`):
- `mint_at_boundary kind` — a check/auth/establish CALLEE's declared return (fresh
  mint); `None` for every restricted kind (fail-closed).
- `assume_param` — a proof-carrying / `Fact`-typed parameter's proof, assumed in the
  body (also lambda-param injection).
- `pass_through subst` — re-subject an existing fact (case-arm subst, `_`-subject fix).
- `conj_intro` / `conj_elim_left` / `conj_elim_right` / `conj_split` — introAnd,
  andLeft/andRight, and `&&`-decomposition binding.
- `elaborated origin` — the residual raw-admission surface, tagged by an enumerated
  `evidence_origin` (`FieldProof`, `AttachedEvidence`, `RestrictedReturn`,
  `FrameworkCollection`) so each is self-documenting; this is the NEXT tightening
  target (see below) but is fully enumerable, which is the audit property Option B
  buys.
- `framework_provenance` — FromDb/FromQueue provenance (kernel API; the current
  dataflow admits FromDb return specs via the shared `admit_call_return` helper as a
  `RestrictedReturn`, since they arrive through a return spec).
- `fact_of` — the one-way projection consumers use for matching/rendering.

Also added: `Validation_common.admit_call_return kind ps` — the shared helper that
routes a called function's declared return proofs through `mint_at_boundary`
(boundary) or `elaborated RestrictedReturn` (a §7.12-verified pass-through/framework
return).

**Verified (behaviour-preserving, as required by step 5):**
- `dune build` clean (library-wide `-warn-error +8` still holds).
- `dune test` green (all suites).
- Exhaustive S7 (`TESL_S7_EXHAUSTIVE=1`): **2314 attributed kills, ZERO candidate
  holes** — identical to the pre-flip fixpoint. No diagnostic changes.
- `test_metamorphic` (meta-invariant) green (403 tests).
- `--check-all`: example (92) + tests (38) all pass; codegen output unchanged
  (the emitter never touches `proof_env`).
- Full Racket `ci.sh` phases still need the Racket-9.2 environment to run here (this
  dev shell is pinned 8.18 — a known, pre-existing mismatch, unrelated to this
  compile-time-only refactor).

**Residual / follow-up (not blocking):** `elaborated` still takes a raw
`proof_expr -> proven_fact` for four origins. Like `framework_provenance` /
`assume_param`, it is a named, greppable, reviewable admission (the audit property
holds), but it is the point where a future pass could tighten further — e.g. sourcing
`RestrictedReturn` facts from the input `proven_fact` via `pass_through` rather than
from the declared return spec, which would remove the last raw-`proof_expr` admission
for restricted kinds. Discovery is at a fixpoint, so this closes no currently-open
hole; it hardens against future bugs.
