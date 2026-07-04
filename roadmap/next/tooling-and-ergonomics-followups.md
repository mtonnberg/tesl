# Tooling & ergonomics follow-ups (2026-07-03 review §7)

Non-soundness items from the fresh review. Two were fixed in the same pass; the rest
are captured here. Prioritised by impact.

## FIXED in the 2026-07-03 pass
- **`--check-json` exit code** — now exits non-zero IFF an error-severity diagnostic
  is present (main.ml, `--check-json` handler), matching the AGENTS.md contract and
  `agent-context`. Previously any warning made it exit 1, so a CI/editor keyed on the
  exit code saw ~40/92 shipped examples "fail" on lint warnings.
- **SQL type-mapping fidelity** — `Maybe <ADT>` → nullable JSONB; bare `Int` and
  newtype-over-Int both → NUMERIC (consistent); LANGUAGE-SPEC §11.8 table corrected;
  in-memory backend NULL comparisons aligned to Postgres 3-valued logic. (dsl/sql.rkt,
  regression-guarded in tests/sql-test.rkt.)

## TODO — Tooling

### T1. `--occurrences-json` mislocates doctest occurrences to line 0 (LSP rename corruption)
Doctest bodies are parsed by `parse_expr_snippet` (parser.ml:4961) as standalone
snippets, so their expression locs are LOCAL to the snippet (line 0), not the real
comment position. These synthetic `DTest { description = "doctest: …" }` decls
(parser.ml:4967) are appended to `m.decls`, so the occurrence collector walks them and
emits occurrences at line 0. `references`/`documentHighlight`/`rename` consume this
list unfiltered → an LSP rename of a doctested symbol writes a corrupting edit at
line 0.
**Fix (safe):** exclude synthetic doctest decls (description prefix `"doctest: "`) from
occurrence collection — occurrences are editable source positions and a comment-embedded
doctest snippet has no reliable one. (Better, later: offset the snippet locs by the
doctest line's real source position so occurrences point into the comment correctly.)
Guard with a test that renames a symbol that also appears in a `#>` doctest and asserts
no line-0 edit.

### T2. `--fmt` does not normalize indentation
Formatted output is not lint-clean (re-running `--lint` after `--fmt` can still flag
layout), weakening the "one canonical style" thesis. `--fmt` should own indentation so
`fmt` then `lint` is a fixpoint. Scope: the formatter's layout pass.

### T3. `--check-json` vs `agent-context` JSON shape divergence
The two emit different diagnostic JSON shapes despite AGENTS.md implying "the same data
agent-context summarises". Reconcile to one schema (or document the difference
explicitly).

## TODO — Ergonomics

### E1. Import ceremony is heavy and self-defeating
Even `Int`/`String` must be hand-imported from `Tesl.Prelude`, and unused imports are
then flagged (W050) — so import lists must be hand-pruned constantly, and every
flagship example ships with W050 warnings. Options: (a) an implicit always-in-scope
Prelude for the ubiquitous primitives; (b) a `--fmt`/`--lint --fix` that auto-prunes
and auto-adds imports; (c) both. Reduces first-run friction for the target TS/C#/Java
developer.

### E2. Codec double-declaration tax
Request/response record + `toJson`/`fromJson` each list every field (each field named
~3×). The docs over-teach this: a plain response record needs no codec, yet the
canonical "pattern to copy" writes ~20 lines of redundant `toJson`. Fix: derive a
default codec from the record shape (opt out / override only where needed), and correct
the tutorial to stop teaching the boilerplate.

### E3. Non-compiling tutorial snippets
Several pitch/tutorial snippets don't compile (e.g. tour.md's `check isValidPort` uses
the single-line `if cond then a else b`, which E000 rejects). Add a docs test that
extracts fenced ```tesl blocks marked as runnable and compiles them in CI, so the
manual can't drift from the language. (Ungated prose blocks that are intentionally
illustrative should be marked so the extractor skips them.)

## Progress — 2026-07-04

- **T1 (LSP rename corruption) — DONE** (commit e082c45). Synthetic `#>` doctest decls
  are excluded from occurrence collection, so a rename no longer writes a line-0 edit.
  Regression: `test_cli_occurrences_json_doctest_no_line0` (test_diagnostics.ml).
- **T3 (check-json vs agent-context JSON shape) — DONE** (commit 3a41a18, document).
  The two carry the same diagnostics in two intentional shapes (compact-flat vs IR-2/LSP
  nested-span); AGENTS.md now states this explicitly (reconciling would break two
  established API contracts — the item allows documenting).
- **E2 (codec double-declaration tax) — DONE for the actionable half** (commit 44b7d1e).
  Verified a plain response record already auto-derives its JSON encoder (compiles AND
  emits with no `codec` block), so E2's "derive default codec from shape" is already
  supported for the common case; the over-teaching was purely documentation, now
  corrected in best-practices ("write a codec only for the decode side / to override").

- **T2 (fmt owns indentation → fmt/lint fixpoint) — REMAINING.** Formatter-internals
  work (a layout/indentation pass) that must not regress the 68 exact-match `.rkt`/fmt
  snapshots (ci.sh phase 6) — a focused formatter task.
- **E1 (implicit Prelude / auto-prune imports) — REMAINING.** A user-facing language
  change (implicit always-in-scope primitives changes name resolution across
  parser/checker/every example; and/or a new `--lint --fix`/fmt auto-prune action). No
  `--fix` exists today. A deliberate feature with design choices (which primitives are
  implicit; opt-out), best decided with the maintainer.
- **E3 (docs compile-test) — REMAINING.** The manual-coherence test
  (`manual/tests/test_embedded_docs.ml`) already SYNTAX-lints every `tesl` fence ("no
  D1-class syntax rot"); E3 wants FULL compilation of *runnable* blocks. That needs a
  runnable/illustrative marker convention + a compiler-backed (shell-out) extractor, plus
  marking the existing illustrative blocks — a bounded but non-trivial test-infra add.

Non-soundness item; the tree is green (`ci.sh` 11/11 under 9.2) with the above done.
