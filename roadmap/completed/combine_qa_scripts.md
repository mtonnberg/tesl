# Combine QA scripts — DONE

Today we have both "compile-examples.sh" and "compiler/ci.sh". Combine them in a third script in the project root called ci.sh

## Status: DONE

The two QA scripts were merged into a single authoritative gate at the repo root:
`./ci.sh`. Running it is now THE one way to know the state of the codebase — it
runs the union / strict superset of both originals, with every overlapping phase
deduped so each logical phase runs exactly once.

### What `./ci.sh` runs (11 deduped phases, in order)
1. **Build** — `dune build` (from `compiler/`)
2. **Dune test** — OCaml alcotest suite, with the explicit, dated, ID-keyed
   failure-waiver list from the old `compiler/ci.sh` (currently EMPTY; no
   substring/`grep -viE` swallowing). Ran in BOTH originals → runs once here.
3. **Lifted-stdlib snapshots** — `scripts/gen-stdlib-rkt.sh --check`
4. **Format** — `tesl fmt` in place, bounded `xargs -P` pool (`TESL_CI_JOBS`)
5. **Validate** — `tesl validate` (check+lint+fmt-check) parallel pool; this is
   the strict superset of the old bare per-file "compile-all", so it subsumes it.
6. **Exact-match .rkt snapshots** — byte-exact re-emit vs every committed
   `example/learn/*.rkt`
7. **Tesl test files** — generated Racket test submodules (batch runner)
8. **Mutation** — `tesl --mutate` lesson42
9. **Integration** — httpclient + email alcotest integration exes
10. **Racket suites** — debugger / headless-inspect / MCP / lifted-stdlib + AI
    (Tesl.Agent) mock feature & runtime suites
11. **Racket aggregate suite** — `tests/all.rkt` with the async shared PostgreSQL
    cluster when available

### Properties preserved
- Explicit dated ID-keyed dune-test failure waivers (no substring swallowing).
- Async shared-PostgreSQL warm-up (overlaps the build; joined before the tests
  that need it); honest SKIP that PROPAGATES the real exit code (never forces
  green) when `pg_ctl` cannot start.
- Parallel `xargs -P` fmt/validate pools (`TESL_CI_JOBS`).
- Exact-match `.rkt` snapshot verification.
- Final collated per-phase summary with timings and an overall exit code.
- All env knobs: `TESL_CI_JOBS`, `RKT_SUITES_SKIP`, `TESL_RACKET_SUITE_TIMEOUT`,
  `TESL_MUTATION_TIMEOUT`, `TESL_TEST_FORCE_NIX_SHELL`, `TESL_TEST_USE_TEMP_PG`,
  `TESL_TEST_BUFFERED_OUTPUT`, `TESL_TEST_DISABLE_PRECOMP`,
  `TESL_POSTGRES_HOST/PORT/USER`.

### Progress indicator
Each phase prints a `[N/11] <phase>` start header and a `[N/11] <phase> …
OK/FAIL/SKIP (Xs)` completion line; a final collated summary lists every phase
with its status + timing and the overall verdict. Colour is emitted only on a
TTY (plain output in CI logs; `TESL_CI_NO_COLOR=1` forces plain).

### Shims + CI
- `compile-examples.sh` and `compiler/ci.sh` are now thin shims that `exec` the
  new root `ci.sh` (exit code, env knobs, and args all pass straight through), so
  existing hooks and muscle-memory keep working.
- `.github/workflows/ci.yml` now invokes `./ci.sh` inside `nix develop`,
  exit-code driven (no `|| true`).
