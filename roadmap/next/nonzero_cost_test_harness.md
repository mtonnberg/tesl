# Internal regression suite must run in non-zero-cost mode

Status: PARTIAL FIX LANDED (check/exists/sql/web) — remaining audit roadmapped.

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
