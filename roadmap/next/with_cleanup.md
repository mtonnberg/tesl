## Background

Before the App migration the entrypoint used `with database X { … }` / `with …` blocks.
We have since moved to an `App` type, which is an improvement. That left the `with` keyword
spread across several unrelated constructs, and left a question mark over how tests should
declare their setup.

A code audit (2026-06-29) corrected a few assumptions that were baked into the original note:

- **Tests do NOT actually use `with database`.** The ~1,724 plain `test` blocks and 87
  `api-test` blocks declare capabilities with `requires [...]` and get an **automatic
  in-memory** database/cache/queue. The runtime falls back to in-memory hashes whenever no
  real PostgreSQL connection is parameterized (`dsl/sql.rkt`, `tesl/cache.rkt`,
  `dsl/test-support.rkt`). There is currently **no declarative real-PG-vs-in-memory switch**.
- The only real `with database` usage (10 occurrences / 2 files: `lesson48-sql-inner-join`,
  `lesson60-email`) and `with transaction` usage (16 occurrences / 6 files) are
  **function-body** query-scoping blocks — not test setup.
- The inline capture form `capture id: T with <codec>` is used **0 times** in any real
  `.tesl` file — only in the fixture `compiler/test/test_review66_api_validation.ml`. Every
  real capture uses the reference form `capture id: T via <capturer>` + `capturer cap: T using <codec>`.
  That unused inline `with` is the **sole** reason the type-application parser carries a
  special-case for `with` (`parser.ml:~492`).

## Goal

- The use of `with` is streamlined and easy to learn/extrapolate.
- It is easy to understand which capabilities a test runs with.
- It is easy to understand whether a test runs against a real DB or in-memory.

## Plan — three independent, separately-shippable changes (do A first)

The strict ordering matters: do **A** before deleting the `parser.ml:~492` special-case, or
inline captures silently break (the regression caught last session by
`test_review66_api_validation` R66_CA13/CA14 — see the Implementation caution below).

### A. Capture syntax: `with` → `using` (do first — unblocks the parser cleanup)

- Surface becomes `capture id: T using <codec> [via <check>]` for the inline form. The
  reference form (`capture id: T via <capturer>` + `capturer cap: T using <codec>`) is
  unchanged. This makes inline and reference captures use the same `using`/`via` keywords.
- Parser: in `parse_api_form` (`parser.ml:~3832`) accept the `USING` token instead of
  `IDENT "with"` for the inline codec. Because `using`/`via` are real keyword tokens,
  type-application terminates on them naturally.
- **Payoff:** delete the `with` arm of the type-app terminator at `parser.ml:~492`, leaving
  only `where`. Update the surrounding comment.
- Migration: rewrite the 3 inline-`with` fixtures in `test_review66_api_validation.ml`
  (≈ L617/633/647) to `using`; add a negative test asserting inline `with` is now rejected.
  No example `.tesl` changes are needed (0 real usages). Update docs that show inline `with`
  codecs (LANGUAGE-SPEC, manual, the captures lesson).

### B. `with transaction` → `transaction`

- Recognize a bare `transaction { }` (`IDENT "transaction"` at statement start, no leading
  `with`) in `parse_with_stmt` (`parser.ml:~2441`) and the test-stmt path (`parser.ml:~4226`).
- **Keep `with database X { }` unchanged** — dropping `with` there would re-overload the
  `database` declaration keyword (`database X = Database { … }`), exactly the kind of keyword
  overloading the `cacheCap` rename removed.
- Migration: 16 occurrences across `lesson21-sql-reference`, `chat-backend`, and
  `KanelBilling/Org/Issues/Backend`. Update docs.

### C. Test infra: optional header clause, in-memory by default

- Keep zero-config in-memory as the **default** for plain tests (covers ~1,700 tests; no
  change, no mandatory `TestConfig` record).
- Add an **optional** test-header clause for the rare test that needs a specific/real
  backend: `test "..." requires [...] with database X { }` (and continue to support the
  existing `with N runs`). `with database X` on a test header binds that database for the
  test body; its absence ⇒ in-memory.
- This makes the previously-implicit backend choice explicit *only where it matters*, and
  reuses the kept `with database` keyword for one consistent story (block form + header form).
- The real-PG path still keys off the parameterized connection/env; document that a
  `with database X` header opts the test into the configured backend for `X`.
- Net effect on the goals: explicit `with database X` ⇒ configured backend; otherwise
  in-memory. That answers "is this test against a real DB or in-memory?" by reading the header.

## Open questions (decide at execution time)

- **O1:** For A and B — hard-migrate in one commit, or accept the old spelling during a
  deprecation window? (Pre-1.0 / trunk-based, so hard-migrate is likely fine.)
- **O2:** For C — should the optional header clause also accept `with queue X` / `with cache X`,
  or is `with database X` + `requires [...]` sufficient? (Queues/caches are reachable via
  `requires` + in-memory today.)

## Implementation caution (learned during the Phase F / capture review, 2026-06-29)

Precise inventory of where `with` is parsed today (the token is always a bare
`IDENT "with"`, not a keyword):
1. **Inline capture codec** — `capture id: T with <codecFn> [via <checkFn>]`
   (parser.ml:~3832 + the endpoint/api capture path). This is the ONLY `with` that
   directly follows a *type*, and it is exactly why the type-application parser
   special-cases `with` as a terminator (parser.ml:~492, the `IDENT ("where" | "with")`
   arm). NOTE: this form has 0 real usages — only the `test_review66_api_validation.ml`
   fixtures exercise it. (Change A renames it to `using` and removes the special-case.)
2. `with database X { … }` (parse_with_stmt, parser.ml:~2427). KEEP `with` (change B).
3. `with transaction { … }` (parse_with_stmt, parser.ml:~2441). DROP `with` → `transaction` (change B).
4. `test "…" with N runs { … }` (parser.ml:~2780/4270). KEEP (change C also reuses `with database` on headers).
(`with capabilities` was removed in the App / Phase-F work. There is no `with cache` form;
the four above are all of them.)

⚠️ The capture step (change A: captures use `using`/`via`, drop inline `with`) MUST land
BEFORE removing `with` from the type-application terminator (parser.ml:~492).
`capture id: T with codec` puts `with` right after a type; if that arm is deleted while the
inline-`with` capture syntax still exists, the type parser consumes `with` as a type
argument and inline captures silently break (regression caught by
`compiler/test/test_review66_api_validation` R66_CA13/CA14). Sequence: migrate the capture
syntax → migrate `with transaction`→`transaction` → only THEN prune the parser arm.

## Verification

- `dune build && dune test` (parser + `test_review66_api_validation` for A).
- `./compile-examples.sh` → "All good!" (authoritative; covers the example sweep, the
  migrated `with transaction` files, and the Racket suite).
- Grep guards: 0 inline `capture … with`, 0 `with transaction` remaining after migration.
