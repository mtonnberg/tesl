# Assurance-polish backlog — B2, C6/S10-remaining, C9/S11, C13, C14

> Relocated 2026-07-02 from `close_all_open_issues.md` (Wave 2 item B2; Wave 3 items
> C6/S10, C9/S11, C13, C14). Backlog IDs: **S10**, **S11**
> (`stability_deferred_backlog.md`). Review §7.

Assurance and dedup hardening. None of these is an open soundness hole — they strengthen
the *apparatus that proves* soundness, and dedup a latent (sound-today) restatement.

---

## B2 — trusted proof-introducing kinds → one named predicate

Dedup only; **sound today**. Effort **S/M**. The set of trusted proof-introducing kinds is
restated rather than centralized. Collapse it to one named predicate so the trusted set has
a single source of truth. (Latent — no hole, but the same G1 single-fact-in-N-surfaces
generator.)

## C13 — wave2/s7 `should_pass` assert exit code

Effort **S**. The wave2 / s7 `should_pass` cases should assert the process **exit code**
(0), not merely the absence of a diagnostic, so a should-pass program that regresses to a
nonzero exit is caught.

## C14 — §7 invariant coverage by semantic object, not string

Review §8.4. Effort **M**. The §7 invariant "coverage" registry is report-only and
satisfied by matching a string in a *comment* ("TESTED" ≠ exercised). Re-anchor coverage —
and anchor stability — to the **semantic object** each invariant guards (the actual guard
site / test), not a comment or string match, so renaming or deleting the real guard breaks
the coverage claim.

---

## Refs

- Review: §7 (mutation is narrow; invariant coverage is report-only / comment-matched),
  §8.4.
- Backlog: `stability_deferred_backlog.md` → **S10**, **S11**.
- Source: `mutate.ml` (S10); `validation_*.ml` / `checker.ml` guard-toggle points +
  `test_invariants.ml` (S11, C14); wave2 / s7 test harness (C13).
