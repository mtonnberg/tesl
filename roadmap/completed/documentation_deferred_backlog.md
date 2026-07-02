# Documentation improvements — deferred backlog (later)

> **NOTE (2026-07-02):** the still-open items here are now tracked in dedicated
> `roadmap/next/*.md` files created from `close_all_open_issues.md` — see that file's
> "Relocated open items" section. Per-item status markers below (☑ DONE / → moved)
> reflect the completed program; the descriptive prose is retained verbatim.

## Context

This is what remains of `roadmap/next/documentation_backlog.md` after the
2026-07-01 closure round.  Read `roadmap/completed/documentation_improvements.md`
for the root diagnosis (the single-fact-in-N-surfaces generator), the doc
problem-classes C1–C7, the target information architecture, and the durable
disciplines — they hold and are not repeated here.

> Format: **ID — action** · *closes class* · **enforced by** · effort · **why deferred**.

---

## Closed 2026-07-01 (final round) — do NOT redo

Verified via the doc-guard test (`manual/tests/test_embedded_docs.ml`) + gate.

- ☑ **D2-lite — prose fence syntax-rot lint.** `test_embedded_docs.ml` now scans
  every prose ` ```tesl ` fence across README / TESL / LANGUAGE-SPEC / manual/ /
  dev-docs/ / example/intro/ (43 docs, 274 fences) for the D1 structural rot class
  and fails the build on any hit: a `Tesl.Db` mis-case (the module is `Tesl.DB`),
  a leading `predicate` declaration keyword (Tesl uses `check`/`fact`), or the old
  `server … impl … on PORT` syntax.  Signals chosen to be unambiguous and
  currently zero.  (`--` line comments — another D1 symptom — are deliberately NOT
  linted: the spec/FAQ use `--` as an illustrative-comment convention in ~119
  pseudo-code fences, so it is not a reliable rot signal.)

All prior doc rounds (D0, D1, D3–D6, D8, D10–D17, D9-core, D13, D14, D15) are
recorded in `roadmap/completed/documentation_improvements.md`.

---

## Deferred — large / needs triage

- → **moved to `roadmap/next/docs_and_small_features_backlog.md`** (as D1).
  **D2 (full) — compile-gate every prose ` ```tesl ` fence.** *closes C2.*
  `compile-examples.sh` checks only `.tesl` files; ~274 fenced blocks are not run
  through `tesl check`.  Build a fence-extractor, introduce a `,ignore` tag, and
  run each non-ignored block through `tesl check` (parse + types).  · **enforced
  by** the authoritative gate. · **L** · *why deferred: the TRIAGE is the bulk of
  the work — each of ~274 fences must be classified complete-program vs.
  illustrative fragment (many spec fences are intentionally partial pseudo-code
  using `…`), and mis-tagging either false-fails the gate or silently blesses rot.
  D2-lite (above) closes the specific structural-rot regression class in the
  meantime; scope tip when resumed: start with `manual/` + `example/intro/`
  complete-program fences.*

- → **moved to `roadmap/next/docs_and_small_features_backlog.md`** (as D10).
  **D7 (full) — generate the examples index from the filesystem.** *closes C6.*
  `manual/examples.md` is hand-written; generate it (each lesson's own header is
  the source), compute the count, and add a coverage test.  Also resolve the
  on-disk lessonNN number collisions (07 / 62 / 63) and the stray
  `tesl-lsp-*.tesl` transient in `example/learn/`.  · **enforced by** generation +
  an index-coverage check. · **M** · *why deferred: renaming ~6 collision lessons
  churns their `.rkt` snapshots, `embedded_docs.ml` keys, roadmap/example
  cross-refs, and any external lesson-number citations — a coordinated
  rename-and-regen change; the hand-maintained index is currently correct
  (verified 70 lessons, links resolve).*

- → **moved to `roadmap/next/docs_and_small_features_backlog.md`** (as D11).
  **D9 (full) — migrate the ~72 spec `§`-citations to named anchors.** *closes
  C7.* Decision #6(b) = full migration.  The resolution test
  (`test_spec_anchors.ml`) and the published anchor contract (`manual/anchors.md`)
  landed (D9-core, D15); the ~72 raw `§<n>` citation sites in
  `compiler/lib`+`compiler/test` are not yet rewritten to named-anchor references.
  · **enforced by** the existing resolution test. · **L** · *why deferred (explicit
  round-4 judgment): the resolution test is the higher-value guardrail and every
  citation resolves today, so the mechanical 72-site rewrite is polish; it also
  first requires settling the canonical citation FORMAT (`§7.4` vs. a slug anchor
  vs. a stable ref key), a lock-in decision better made deliberately.*
