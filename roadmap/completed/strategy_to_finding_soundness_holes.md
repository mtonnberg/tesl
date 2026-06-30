## Background

We have a lot of tests and have done some reviews of the compiler. However, bugs are still being found.

## Goal

- A report written (as roadmap/later/soundness_increase.md) that in detail give actionable items that in a *systemic* way finds, closes soundness holes or even better make it formally impossible for them to appear/exist.
## Status: DONE (2026-06-30, core_polish)
Report written to `roadmap/later/soundness_increase.md` — a tiered, actionable
program: Tier 0 make whole classes structurally impossible (single source of truth
for the stdlib surface so the checker/emitter/capability models can't diverge;
derive declaration contracts; "compile ⇒ emit+load"; totality of partial forms),
Tier 1 systematically find the residue (differential well-typed generation, boundary
fuzz), Tier 2 close-and-keep-closed (negative corpus, differential parity, emitter
mutation). Root diagnosis: holes are checker-model vs emitter/runtime-model drift
wherever a fact is hand-maintained in two places.
