# Tesl — Executive Review

**For:** CTO / decision-maker
**Date:** 2026-07-02
**By:** external language-design review (production type-system perspective)
**Scope:** Is Tesl a sound idea, is the implementation credible, has it earned its right to exist, and is it going in a good direction? Companion evidence: `TECHNICAL-REVIEW-2026-07.md`.

---

## Bottom line up front

**Tesl is a genuinely good idea with a genuinely capable core, undermined by one recurring implementation defect and one strategic drift. It is worth continuing — but only if the *class* of defect is closed before any more language surface is added.**

- **The idea holds water.** Proof-carrying values, capabilities-as-effects, and auth-in-signatures, aimed narrowly at web APIs, is a coherent and defensible thesis. It is *not* a research toy: it compiles real full-stack APIs end-to-end, the developer experience (error messages, agent tooling, debugger) is excellent, and the hard part of the type theory is implemented correctly.
- **It has earned its right to exist as an alpha language.** It has *not* earned "bet-a-company-on-it" status — and its own README says so honestly.
- **But the safety guarantee has holes today.** I independently confirmed, by running the compiler, **five distinct ways to forge a compile-time proof** — including a *total authentication bypass* — that the compiler accepts silently. Because proofs are erased before runtime, there is no safety net: a forged proof is a live production defect with no detection.
- **These holes are not random.** They are all the same mistake repeated in different places, and the project has already been through **60+ review rounds** patching instances of it one at a time. That approach cannot converge. The fix is structural and is described below.
- **Direction is partly misaligned:** the stated goal is mainstream adoption, but the adoption enablers (installer beyond Nix, package manager, playground, libraries) have been shelved, while effort flows into a new AI-agent feature surface that is itself outrunning the soundness model.

**Recommendation: continue investing, but institute a "close the class, then grow" freeze.** Spend the next cycle on four structural fixes (below). They are well-scoped, high-leverage, and would retroactively kill every hole I found. Then reassess adoption-vs-research positioning.

---

## Remediation status (updated 2026-07-02)

A first remediation pass has already **closed the critical soundness cluster** and
several supporting issues. Landed and verified (each forgery now rejected, its
legitimate control still compiles, the 99+38 example/test corpus stays green, and a
new regression module `compiler/test/test_review75_reviewfixes.ml` guards them):

- **The trust-boundary proof/auth forgery via `transaction`/`with` wrappers** (the
  headline critical finding) — the proof validator was made *total and
  fail-closed* so no wrapper form can hide a minting site, and the same fix was
  applied to the `establish` and shadowing validators.
- **Shadowing forgery**, **auth `via` never validated**, **agent-context dropping
  lint warnings**, **the misleading mutation "100%" score**, and the **docs/first-
  touch drift** (the `tesl init` templates now compile; the FAQ and cost claims are
  corrected).

Since then, the **compare-functions-or-optionals** finding (row 5 of the table
below) has also been closed: the second, divergent type-checker that guarded
`<`/`==` was removed, and the check now uses the compiler's own type information.
Comparing optionals (e.g. `Maybe Int`), functions, or a record that hides a
function is now rejected at compile time. One narrow residual remains — comparing
functions *indirectly* through a generic helper — which needs a small,
well-understood type-system addition and is scheduled, not dropped.

The other remaining deeper items (a container-wrapped minting case, the
DB-provenance edge, capability whole-program checks, and the runtime proof-witness
backstop) are **tracked, not dropped** — each carved to `roadmap/later/` (open
items) with the maximum done now and a precise reason it needs its own pass; landed
work is recorded under `roadmap/completed/` (`review_2026_07_closed_items.md` and
the program tracker `review_2026_07_master.md`).

## What Tesl is trying to achieve

Most web-API bugs come from the boundary: validation forgotten after decoding, auth wired by convention, effects hidden, domain guarantees lost a few calls in. Tesl's bet is to push these into the language so the compiler enforces them:

- **Validate once, then carry the proof.** A value checked at the boundary is stamped with a fact; downstream code that needs the fact simply demands it in its type, and the compiler refuses unvalidated data.
- **Effects are explicit capabilities**; auth requirements show up in signatures; SQL, queues, real-time, and AI-agent tools are language features.
- The pitch: make the *correct* path the *obvious* path, so a normal developer picks Tesl for their next API because it's the easiest way to something that works and stays working.

This is the right problem and a principled attack on it.

---

## Does it hold water?

**The ideas: yes.** **The implementation: the core yes, the boundary enforcement no.**

The most important thing I found is encouraging *and* damning at once: **Tesl built the hard part correctly and then bypassed it.** It has a principled, sound engine for deciding when one proof satisfies another (based on hidden value identity, not on variable names — the genuinely difficult part, and it works: renaming variables, reusing names, aliasing, and cross-function flow are all handled correctly). None of the security holes are in that engine.

Instead, every hole is in the *separate, simpler* checks that guard where a proof is first *minted* at a boundary. Those checks are hand-written code walks that **"fail open"**: if the programmer wraps the code in a form the check's author didn't anticipate (a database transaction block, an optional-value wrapper, a constructor), the check simply doesn't run, and an unproven or false claim is accepted. Concretely, I confirmed by running the compiler:

| # | What I did | What should happen | What happens |
|---|---|---|---|
| 1 | Wrap a validated result in a `transaction { … }` block and claim a proof the code never established | Rejected | **Accepted** — arbitrary proof forged |
| 2 | Same trick on an **authentication** function — vouch "authenticated" for `"attacker"` | Rejected | **Accepted** — every request authenticates as anyone |
| 3 | A plain function claims a value is "positive" and returns `-999` in an optional wrapper | Rejected | **Accepted** — downstream code trusts `-999` |
| 4 | A database handler claims "this row came from the DB with id X" but inserts a different id | Rejected | **Accepted** — forged data-provenance / cross-tenant ownership |
| 5 | Compare two functions or optional values for order/equality | Rejected (undecidable) | **Accepted** — crashes or silently wrong at runtime |

Each has a control: the *un-wrapped* version is correctly rejected. So the language knows the answer — it just skips the check when the code is shaped in a way the check didn't foresee.

**In fairness, what Tesl gets right is substantial:** SQL is injection-safe by construction and its provenance checks are real for the common query paths; integers don't overflow; partial functions (empty-list head, divide-by-zero) are designed out and re-checked at runtime; exhaustiveness checking is thorough; capabilities have a genuine runtime backstop; the auth *runtime* path is fail-closed; the error messages and agent tooling are best-in-class. 45 of 71 adversarial probes were correctly defended. This is a capable system with a specific, fixable structural weakness — not a facade.

---

## Has it earned its right to exist?

**As an alpha / research-grade language: yes, clearly.** It demonstrates that proof-carrying web APIs are buildable with mainstream-feeling ergonomics, and it does things (auth and effects visible in signatures, proofs that survive refactoring, an agent-first debugging surface) that the TypeScript-plus-libraries status quo does not.

**As a production language you would build a business on: not yet** — and this is the honest reading of its own "alpha" labeling. The gap between those two states is almost entirely the defect class above, plus the fact that the guarantee has no runtime safety net, so any compiler bug in that class is directly exploitable and invisible.

---

## Why this keeps happening (the part that matters strategically)

The repository contains **60+ prior "critical review" rounds**, each preserved as a regression test. That is admirable diligence — but it is also the warning sign. Each round finds one more code shape the boundary checks forgot, patches *that shape*, and moves on. The underlying pattern — "hand-written checks that fail open, with no runtime backstop, and no automated way to discover the next forgotten shape" — is never removed. So every time the language grows a new feature (transaction blocks, the new return syntax, AI-agent blocks), the same hole reopens in a new place. **The current holes are, quite literally, the newest features' turn.**

You cannot reach production stability by continuing to patch instances. This is the central strategic point: **the review process has been fighting symptoms, and the disease regenerates faster than features are added carefully.**

---

## Recommendations

**Do these four before adding any new language features. They are structural, well-scoped, and would retroactively kill every hole in the table above.**

1. **Make the boundary checks impossible to "fail open."** Change them so that any unfamiliar code shape is *rejected by default* rather than silently accepted, and wire them into the compiler's own exhaustiveness checking so that adding a new language feature *forces* the author to say how proofs flow through it — the compiler won't build otherwise. (One of Tesl's own subsystems already works this way; generalize it.)
2. **Eliminate the duplicate checkers.** Several safety properties are decided by two divergent pieces of code that must agree but don't; every divergence is a hole. Collapse each to one.
3. **Add a runtime safety net for proofs in the test/CI build.** Because proofs are erased, a compiler bug is invisible. Keep the proof information in a special test build and assert that what the code does at runtime matches what the compiler claimed. This turns "silent production forgery" into "a failing test the moment a hole exists" — and would have caught all five holes automatically.
4. **Test the compiler generatively, not just with frozen examples.** Add a fuzzer and a mechanical check that *wrapping any accepted code in a transaction/optional/constructor doesn't change the verdict.* That single automated property finds the entire defect class with no human guessing — replacing the 60-round manual game of whack-a-mole.

**Then address direction:**

5. **Pause the AI-agent surface expansion until its capability model is complete** (the project's own notes say it isn't). Growing the surface faster than the guarantees cover it is exactly what created today's holes.
6. **Decide, explicitly, adoption vs. research.** The stated goal is mainstream adoption, but the adoption enablers (a non-Nix installer, a package manager, an online playground, libraries) are all shelved. Either re-fund the adoption path or reposition Tesl as a research vehicle — the current mismatch quietly guarantees neither outcome.
7. **Fix the first impression.** The `tesl init` starter templates and the FAQ **do not compile** against the current compiler. For a language whose pitch is "the correct path is the obvious path," the generated starting point failing to typecheck is the worst possible opening. Put all first-touch artifacts under the same automated compile gate as the internal examples.

---

## Scorecard

| Dimension | Grade | Note |
|---|---|---|
| Vision & problem selection | **A** | Right problem, principled, defensible niche |
| Core type/proof engine | **A−** | The hard part is done correctly and is sound |
| Boundary proof enforcement | **D** | Fails open; 5 confirmed forgeries incl. auth bypass |
| Runtime safety net for proofs | **F (by design)** | Erased; no backstop → checker bugs are live exploits |
| Capabilities & effects | **B** | Sound core + runtime backstop; whole-program & some primitives uncovered |
| Developer experience | **A−** | Excellent diagnostics, agent tooling, debugger |
| Verification methodology | **C+** | Honest gate, but fixture-accretion; no fuzzing/differential/backstop |
| Documentation honesty | **B−** | Spec/alpha framing honest; templates/FAQ/cost-claims drifted |
| Architecture strategy | **C** | Clean frontend; "swappable runtime" claim is false; no lowering IR |
| Trajectory / focus | **C** | Adoption goal vs. research investment; surface outrunning soundness |
| **Overall** | **Promising, not yet trustworthy** | Fund the structural fixes; re-review after |

**One sentence for the board:** *Tesl is a well-conceived, capably-built alpha language whose safety guarantee currently has confirmed holes of a single, fixable structural kind; it is worth continued investment specifically to remove that class of defect and to realign effort with its stated goal — but it should not yet be trusted for production, and no new language features should ship until the boundary checks are made fail-closed and independently backstopped.*
