# Internal regression suite must run in non-zero-cost mode

Status: ✅ COMPLETE. See "## Resolution" at the bottom.
(Historical: PARTIAL FIX LANDED for check/exists/sql/web/record; a later pass finished
the audit + fixed the mode-fragile tesl-test; the FINAL pass routed body-proof-test —
the one NZC-dependent test the audit missed because the suite aborted at tesl-test
before reaching it — through a suite-aware in-memory NZC driver. Racket suite all-pass.)

## Problem

`TESL_ZERO_COST_PROOFS` is **default-ON** (zero-cost erasure is the production
default; read at macro-expansion time, see `dsl/web.rkt` / `dsl/private/check-runtime.rkt`).

Several `tests/*.rkt` internal regression tests validate the **evidence-bearing**
(non-zero-cost) proof/validation machinery — `detach-proof`, `detached-proof-*`,
`attach-proof`, `facts-of`, and `check-exn` assertions on validation errors that are
**erased** in zero-cost mode. Under a clean zero-cost compile they FAIL:

- `tests/check-test.rkt`, `tests/exists-test.rkt`: `detach-proof: expected
  proof-bearing evidence, got 5` (because `(positive 5)` returns raw `5`).
- `tests/sql-test.rkt:185`, `tests/web-test.rkt:516..546`: `check-exn` expecting an
  exception that no longer fires under erasure.

They only passed historically because the bytecode cache happened to be compiled in
non-zero-cost mode. A fresh `raco make` (or a `compiled/` purge) in the default
(zero-cost) mode makes them fail. So since the zero-cost-default flip (`675be2a`),
`compile-examples`'s `racket tests/all.rkt` step has effectively been relying on stale
bytecode for these.

## Fix landed

`tests/internal-all.rkt`: added `run-non-zero-cost-test` — runs a test in a fresh
subprocess with `TESL_ZERO_COST_PROOFS=0` and `use-compiled-file-paths = null`
(in-memory compile, so it neither reads nor clobbers the default zero-cost bytecode
cache shared with the zero-cost example-batch). Routed `check-test`, `exists-test`,
`sql-test`, `web-test` through it.

## `tesl-test.rkt` — needs non-zero-cost AND has install-linked complications

`tests/tesl-test.rkt` is also evidence-bearing but can't simply join the run-nzc
batch:

- `tesl-test.rkt:532` — `(check-equal? left-token right-token)` on a decomposed
  combined proof `((ValidPort port) && (IsPositive n))`. Under zero-cost the tokens
  are the raw declared names (`'port` vs `'n`, unequal); under non-zero-cost the
  evidence unifies them. So it needs `TESL_ZERO_COST_PROOFS=0`.
- BUT `tesl-test` calls `install-linked-tesl!` (`raco pkg install --auto --link
  <repo root>`), whose `raco` subprocess INHERITS the env var. Running tesl-test at
  `TESL_ZERO_COST_PROOFS=0` would compile the linked package non-zero-cost and write
  those `.zo` into the shared `compiled/`, clobbering the zero-cost cache the rest of
  the run depends on. So it needs the dedicated non-zero-cost compiled root (below),
  not the in-memory `use-compiled-file-paths null` driver.
- `tesl-test.rkt:604` — separately, `(regexp-match? #rx"expected module" …)` is a
  STALE assertion: the compiler now reports `expected `module` or `library` keyword`
  (library feature), and `compile-tesl-error` on the no-`#lang` source returns a
  file error rather than the parser message. Update the assertion (and/or the
  compile-tesl-error path for module-less sources) as part of this pass.

## Remaining (roadmap)

1. **Audit the other internal tests** for non-zero-cost dependence: `record-test`,
   `postgres-test`, `example-api-test`, `body-proof-test`, `surface-regression-test`,
   `existential-regression-test`, `tesl-test`, `port-test`, `codec-specialization-test`.
   Any that assert on evidence/validation-exception behavior need the same routing.
2. **Performance:** `use-compiled-file-paths null` recompiles deps in-memory per test
   (~30–60s each). For the full set, switch to a shared dedicated non-zero-cost
   bytecode root (`PLTCOMPILEDROOTS`/`current-compiled-file-roots`, e.g.
   `compiled-nzc/`, gitignored) so the non-zero-cost build is cached and reused across
   these tests while staying isolated from the zero-cost `compiled/`.
3. **Decide the architecture explicitly:** the internal regression suite is the
   non-zero-cost "safety-net" oracle; the zero-cost production path is covered by the
   example-test-batch (snapshots). Document this split so the two modes are tested
   deliberately rather than by bytecode accident. Consider a single
   `racket tests/all.rkt` invocation under a dedicated non-zero-cost compiled root
   instead of per-test subprocesses.

## Resolution

Audited every remaining internal test by running it in a *fresh in-memory* compile
(`racket tests/run-nzc.rkt <test>`, `use-compiled-file-paths` cleared so no stale
`.zo` can mask the result) in the default (zero-cost) mode:

- `body-proof-test`, `port-test`, `codec-specialization-test`,
  `surface-regression-test`, `existential-regression-test`, `postgres-test`,
  `example-api-test` — **all pass in zero-cost mode**. They assert on compile-time
  validation and on the runtime helpers that exist in *both* modes, so they are NOT
  non-zero-cost-dependent. No routing change needed; they stay in the default bucket.
- `check-test`, `exists-test`, `sql-test`, `web-test`, `record-test` — genuinely
  non-zero-cost (detach-proof / check-exn on erased evidence). Already routed through
  the in-memory `run-nzc.rkt` driver. Unchanged.
- `tesl-test` — had ONE mode-fragile assertion (`tesl-test.rkt:532`): a decomposed
  combined proof `((ValidPort port) && (IsPositive n))` whose tokens unify to the
  runtime witness under non-zero-cost but are the `establish` parameter names
  (`'port` / `'n`) under zero-cost erasure. Rather than route tesl-test through a
  dedicated non-zero-cost compiled root — which is pathological here, because
  `install-linked-tesl!` (`raco pkg install --link`) runs 9× and each triggers a full
  `raco setup` into a cold root — the assertion was made **mode-aware**: it asserts
  the unified runtime witness under non-zero-cost and the symbolic `'port`/`'n` shape
  under the zero-cost default. This is strictly *more* coverage (both modes are now
  pinned) and removes the bytecode-accident fragility.
- Also fixed in tesl-test as part of this: `:604` stale regex
  (`expected module` → `expected .module. or .library.`, the library-keyword
  rewording); a *second* mode-fragile evidence site (`~:1627`, record-field proof
  extraction — `named-value?`/`facts-of`) made mode-aware the same way; and FIVE
  cross-module-require path bugs (`~:1025`, `:1451`, `:1486`, `:1524`, `:1956`) where
  the consumer/App module was compiled with `compile-tesl-module` to a random
  `/var/tmp` file so its relative `(require (file "shared.rkt"|"lib.rkt"))` could not
  resolve — now all use `compile-tesl-to-dir!` to place the output beside its sibling.

  IMPORTANT — tesl-test is NOT fully green after this, and the remaining blocker is
  NOT non-zero-cost: it is **task-#9 config-migration debt**. Once the evidence sites
  pass (under NZC, or via the mode-aware fixes in zero-cost), the run reaches old-style
  config/queue fixtures such as `Q01` (`tesl-test.rkt:~3370`,
  `queue MyQueue { database FakeDb ... }`) that expect the OLD space-delimited
  `queue { database X }` syntax to compile with an *undeclared* database — which the
  current validator (correctly) rejects with `V001 queue references unknown database`.
  These predate the undeclared-database check and need rewriting/migration, exactly the
  fragile `.ml`/`.tesl` old-config fixtures that app_simplification.md says to migrate
  in the App pass. So tesl-test's full greening is deferred to that
  config-migration/App pass; the NZC-specific work for it (532, 1627) is done here.

Note on NZC-routing tesl-test (rejected, with evidence): the dedicated-compiled-root
approach HANGS — tesl-test calls `install-linked-tesl!` (`raco pkg install --link`) 9×,
each of which triggers a full `raco setup` into the cold root. The in-memory
`run-nzc.rkt` driver does NOT hang and does NOT clobber the zero-cost cache (verified:
default `*.zo` mtimes unchanged), but its blanket exn handler turns tesl-test's
intentional negative-compile fixtures (the Q01 `FakeDb` errors above) into fatal
`NZC-ERROR`s. Hence the mode-aware approach for tesl-test's own evidence assertions,
and deferral of the rest to the config-migration pass.

Net architecture (as point 3 asked to document explicitly): the **zero-cost
production path** is covered by the example-test-batch (snapshots, run in default
mode); the **non-zero-cost evidence machinery** is covered by the five `run-nzc.rkt`
tests; `tesl-test` pins BOTH modes for the proof-decomposition behavior. The dedicated
non-zero-cost compiled root was prototyped and verified to isolate correctly
(`PLTCOMPILEDROOTS=<abs>` populates a separate `compiled-nzc/` and leaves the
zero-cost `tesl/dsl/compiled/` untouched) but is NOT needed given the audit — kept as
a documented option should a future evidence-bearing-AND-install-linked test appear.

## Final pass: body-proof-test was the audit's blind spot

The audit above ran each test in a fresh in-memory compile and concluded body-proof
"passes in zero-cost" — that was WRONG. body-proof is packaged as a `body-proof-suite`
value run via `run-tests` (not top-level checks), and the internal-all suite ran it in
the DEFAULT mode AFTER tesl-test. Because tesl-test's Q01 failure aborted
`run-internal-tests` first, body-proof was NEVER REACHED — so its zero-cost failures
(detach-proof / attached-proof / Skolem-witness scoping erased) were hidden. Once
tesl-test was fixed (and the cache work recompiled `dsl/*` in default, clearing the
stale-NZC bytecode accident it had been passing on), body-proof surfaced 6 failures.

Fix: `tests/run-nzc-bodyproof.rkt` — a suite-aware driver that, under
`use-compiled-file-paths null` (in-memory, no clobber) + `TESL_ZERO_COST_PROOFS=0`,
`dynamic-require`s `body-proof-suite` and `run-tests` it. `internal-all.rkt` runs it
via a new `run-non-zero-cost-driver`; body-proof no longer runs in the default suite.
Verified 21/21 pass under NZC; the racket internal suite is all-pass.
