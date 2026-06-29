## Background

We have run/debug codelenses for plain `test "..."` blocks (and a "run" lens for doctests),
but Tesl has several test kinds:
  - `test` (plain) — has Run + Debug today
  - `doctest` (`#>` / `#=`) — has Run today, no Debug
  - `api-test` — has nothing
  - `load-test` — has nothing

Run/Debug should be as easy for every kind as it is for plain test-blocks.

### Current state (audited 2026-06-29)

- The VSCode/VSCodium extension (`editor/vscode-tesl/extension.js`, plain JS) regex-detects
  only `test "..."` (`TEST_RE`, ~L270) and `#>` doctests (`DOCTEST_RE`). `api-test`/`load-test`
  lines are not matched, so they get no CodeLens and no Test Explorer entry.
- The single-test path is: codelens → `tesl.runSingleTest` / `tesl.debugSingleTest` →
  `tesl test --test-name "NAME" file.tesl` (CLI wrapper `nix/tesl-cli-body.sh`) →
  `--test-name` flag in `compiler/bin/main.ml` → `Emit_racket.set_test_name_filter`.
- **The blocker:** the test-name filter (`emit_racket.ml:~6203`) is applied **only to
  `DTest`**. `DApiTest`/`DLoadTest` are emitted **unconditionally** (`emit_racket.ml:6172-6173`),
  so there is no CLI path to run a single api-test/load-test — and `--test-name "X"` does not
  even suppress them (they all still run). All three kinds emit as `(test-case <description>)`.
- DAP (`dsl/debug/dap-server.rkt`) already supports `mode:test` + `testName`; the Test
  Explorer (TestController, extension.js ~L533) already exists for plain tests + doctests.

## Goal

It is easy and convenient to run/debug all parts of Tesl.

## Decisions

- **Run** for all three new kinds (api-test, load-test, doctest).
- **Debug** for **api-test and doctest only**. A `load-test` is a throughput/latency
  benchmark over N requests, not a steppable scenario — Run-only (see O3 for a possible
  "run vs baseline" affordance).

## Plan — two layers

### Layer 1 — Compiler prerequisite (the real work)

- Extend the test-name filter (`emit_racket.ml:~6203`, `set_test_name_filter`) to also match
  and — crucially — **suppress** non-matching `DApiTest`/`DLoadTest` (today they emit
  unconditionally at `emit_racket.ml:6172-6173`). Without this there is no single-test run
  for api/load.
- Add a `--test-kind {test|api-test|load-test|doctest}` disambiguator in `compiler/bin/main.ml`
  and the `tesl test` wrapper (`nix/tesl-cli-body.sh`). api-test and plain-test descriptions
  can collide (both emit as `(test-case <description>)`), so kind + name pins exactly one block.
- Target: `tesl test --test-kind api-test --test-name "..."` emits exactly that one test.

### Layer 2 — Editor affordances (`editor/vscode-tesl/extension.js`)

- Add detection regexes next to `TEST_RE`/`DOCTEST_RE` (~L270): `api-test "([^"]+)"` and
  `load-test "([^"]+)"`.
- CodeLens + Test Explorer (TestController, ~L533):
  - **api-test:** Run + Debug (DAP `mode:test`, pass `testName` + the new kind).
  - **load-test:** **Run only.**
  - **doctest:** add a **Debug** lens (currently Run-only) for parity.
- Wire all through the existing `tesl.runSingleTest` / `tesl.debugSingleTest` commands,
  passing the new `--test-kind`.
- Confirm a single emitted api-test runs cleanly under the DAP server.

### Overlap

`roadmap/later/integrate_vscodium_test_explorer.md` wants the Test Explorer to show all tests
project-wide with status. The Test Explorer is the natural home for "all kinds." Sequence the
two together: this item delivers the per-kind run/debug primitives; that item surfaces them
across the project.

## Open question

- **O3:** load-tests support `baseline "label"`. Add a "Run vs baseline" / compare affordance
  for load-tests, or defer? (Defer unless cheap.)

## Verification

- `dune build && dune test` (new filter/kind tests).
- `./compile-examples.sh` → "All good!".
- Manual: in VSCodium, click Run/Debug on an `api-test` and Run on a `load-test`; confirm
  exactly the selected test runs and DAP attaches for the api-test.

## Notes

- The debug/run tests must be possible through the mcp/tesl command so agents can work with tests.