# S12 / C7 — erase/retain boundary as an enumerable manifest

> Relocated 2026-07-02 from `close_all_open_issues.md` (Wave 3, item C7/S12).
> Backlog ID: **S12** (`stability_deferred_backlog.md`). Review §8.4 (erase/retain
> boundary), §7.10 of the spec.

## The problem

The erase/retain boundary is stated in three places (spec §4.3, §7.10,
`zero-cost-proofs-contract.md`) and they agree item-for-item (6 carriers, 4 always-on
checks). But nothing *mechanically* asserts, per compiled program, that the set of
retained guards equals the §7.10 closed set. The agreement is verified by inspection of
the prose, not by construction from the emitter.

## Why it matters

The erase/retain boundary is the heart of the zero-cost-proofs thesis: proofs are erased,
a fixed closed set of runtime guards is retained, and each retained guard must be
fail-closed. A per-program manifest turns "the three docs agree" into "the emitter
provably retains exactly the §7.10 set on every program in the corpus." Closes generator
classes G6 + G7.

## Fix approach

Emit, per program, the **retained-guard / stripped-carrier manifest** — the concrete set
of runtime guards the emitter kept and the proof carriers it stripped. Then, over a
corpus, assert `retained == the §7.10 closed set`, and assert each retained guard is
fail-closed by construction.

Critically, the manifest must **enumerate guard sites explicitly** (from emission), not
via a grep heuristic — a heuristic over/under-counts and would give false confidence.

## Effort

**L** — a new manifest-emission subsystem plus a corpus aggregator. The explicit
guard-site enumeration is the hard part (it must be driven by the emitter's own structure,
not pattern-matched text).

## Refs

- Review: §8.4 (the three erase/retain statements agree item-for-item — verify by
  construction).
- Backlog: `stability_deferred_backlog.md` → **S12**.
- Spec: §7.10 closed set (6 carriers, 4 always-on checks); `zero-cost-proofs-contract.md`.
