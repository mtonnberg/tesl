# Goal
Reduce end-to-end runtime of compile-examples.sh to <20 seconds (preferably lower) without changing compiler output or program/runtime semantics, and stream results to the console as they occur.
## Current state (brief)
- Phases: (1) Validate files with tesl validate, (2) Tesl tests via tesl test, (3) Racket aggregate tests via racket tests/all.rkt.
- Racket suite is launched through nix-shell, adding startup overhead.
- A fresh PostgreSQL cluster is created with initdb and started every run (temporary dirs), then torn down.
- Racket test output is buffered: captured then printed after completion.
- internal-all.rkt compiles each test module by spawning raco make per module, and runs two test files in separate Racket subprocesses.
## Proposed changes
1) Remove nix-shell overhead when already in dev shell
- Detect when running inside Nix dev shell (IN_NIX_SHELL set).
- If set, invoke racket tests/all.rkt directly instead of nix-shell --run.
- Fallback to current nix-shell invocation when not in dev shell.
- File: compile-examples.sh (phase “Test suite”), replace the single command line accordingly.
2) Persist PostgreSQL data across runs (opt-out available)
- Use a stable data dir (e.g., .tesl-postgres/data) instead of mktemp for every run.
- On first run: initdb -A trust -U tesl; subsequent runs: skip initdb.
- Start with pg_ctl -o "-F -k <socket_dir> -p <port>"; stop on exit but keep data dir for reuse.
- Add env flag TESL_TEST_USE_TEMP_PG=1 to force current temp-per-run behavior (CI default).
- Files: compile-examples.sh setup_shared_postgres; optionally reuse scripts/postgres-*.sh logic for portability.
3) Overlap Postgres boot with validation
- Start setup_shared_postgres in background at script start and export intended env values once ready.
- While Postgres boots, run the Validation phase (tesl validate) fully.
- Block on pg_isready (or a small wait loop checking pg_ctl status/socket) before Tesl tests and Racket tests.
- Ensure traps still stop Postgres on exit (success/failure paths).
4) Stream Racket test output live and still compute summary
- Replace capture-to-variable with tee into a temp file:
  - tmp_log=$(mktemp); racket tests/all.rkt 2>&1 | tee "$tmp_log"; test_exit=${PIPESTATUS[0]}
  - test_output=$(cat "$tmp_log") for summary parsing.
- Keep noisy-line filtering only for a post-run condensed echo; let live stream be unfiltered except truly-known spam (optional).
- File: compile-examples.sh “Test suite” section.
5) Warm Racket compiled cache once per run
- Before launching tests/all.rkt, precompile test modules once: raco make tests/internal-all.rkt tests/*.rkt tests/private/*.rkt (expand exact set present in repo).
- Keep internal-all.rkt’s ensure-test-module-compiled as-is; after a warm cache it becomes a no-op and avoids per-module raco startup costs.
- Optionally guard precompile with TESL_TEST_DISABLE_PRECOMP=1 to skip.
6) Avoid extra Racket subprocesses inside internal-all.rkt
- Replace run-external-test for tesl-test.rkt and port-test.rkt with in-process loading:
  - Prefer turning those files into modules that register a rackunit suite; then (load-test-module ...) and run via run-tests.
  - Backward-compatible fast path: when TESL_TEST_INLINE_EXTERNAL=1, dynamic-require those modules directly (letting side effects register tests), otherwise keep current external call.
- File: tests/internal-all.rkt (adjust run-external-test calls and/or add inline fast path).
7) Minor shell efficiency and observability
- Print per-phase elapsed times and final total (date +%s or bash SECONDS).
- Use stdbuf -oL -eL on long-running commands (where available) to improve line-buffered streaming when wrapped.
- Keep current success/failure summaries; do not change exit codes.
8) CI-safe defaults
- In GitHub Actions/CI, set TESL_TEST_USE_TEMP_PG=1 (fresh cluster per run) for isolation.
- Unset IN_NIX_SHELL in CI so the old nix-shell wrapping path remains the default there (or detect non-interactive and keep wrapper).
## Implementation steps (concrete)
A. compile-examples.sh
- A1. Detect dev shell: if [ -n "${IN_NIX_SHELL:-}" ]; then use racket directly; else use nix-shell wrapper.
- A2. Introduce PERSISTENT PG: set TESL_PG_ROOT=${TESL_PG_ROOT:-".tesl-postgres"}; use $TESL_PG_ROOT/data and a tmp socket dir; call initdb only when data dir missing.
- A3. Start Postgres in background early; run validation while waiting; then join when needed for tests.
- A4. Switch Racket test run from $(...) capture to tee-based streaming with PIPESTATUS for exit code and a temp log for parsing counts.
- A5. Precompile: run raco make over test modules prior to running the suite (guarded by TESL_TEST_DISABLE_PRECOMP).
- A6. Add timers per phase and total.
B. tests/internal-all.rkt
- B1. Add support for TESL_TEST_INLINE_EXTERNAL env var; when set, replace run-external-test calls for tesl-test.rkt and port-test.rkt with in-process dynamic-require of those modules (assuming they define/execute tests on require).
- B2. If they do not currently behave as modules, refactor them to provide suites and invoke via run-tests; keep old path as fallback.
## Acceptance criteria
- Running time for ./compile-examples.sh on a warm dev shell with a persisted Postgres data dir: <20s total.
- Output from the Racket tests streams continuously to the console; no long silent periods before results appear.
- Exit codes and final summary counts remain identical to current behavior for passing and failing cases.
- CI remains green with TESL_TEST_USE_TEMP_PG=1 and without relying on a persisted data dir.
## Rollback/flags
- TESL_TEST_USE_TEMP_PG=1 forces fresh per-run cluster (old behavior).
- TESL_TEST_DISABLE_PRECOMP=1 disables raco make warm-up.
- TESL_TEST_INLINE_EXTERNAL=0 keeps current external racket subprocess executions.
- TESL_TEST_BUFFERED_OUTPUT=1 reverts to buffered capture for the suite.
## Measurement plan
- Baseline: time nix-shell --run "./compile-examples.sh" (record total and phase times).
- After A1–A4: re-measure.
- After A5 and B1/B2: re-measure; verify target is met.
- Document timings in commit/PR description.
