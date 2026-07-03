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
