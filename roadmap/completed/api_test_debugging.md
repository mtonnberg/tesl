# API-Test Debugging — Breakpoints Inside api-test Bodies

**Status:** IMPLEMENTED (2026-07-29)

`emit_api_test_stmt` now mirrors `emit_test`'s `thsl-src!` checkpoint wrapping
(TsLet value, TsExpect subject, TsExpr, TsExpectFail, TsExpectHasProof, TsIf/TsCase
branches with locals threading via `api_test_cp_locals_after`); load-test request
bodies stay uninstrumented. 15 committed snapshots regenerated (pure wrapping
diffs), new dune group `g8_api_test_instrumentation` in
`compiler/test/test_debug.ml` (8 cases), full dune test + raco sweep green, docs
note in `manual/best-practices.md` (single-test debug: other blocks' breakpoints
are dead under `--test-name`). Remaining manual step: VSCodium end-to-end
breakpoint check inside an api-test body.

**Why:** Debugging a single api-test from VSCode (Test Explorer "Debug" profile or
the "🐛 Debug api-test" CodeLens) launches, registers breakpoints, then runs to
completion without ever stopping. Root cause (diagnosed 2026-07-29): the Tesl
emitter instruments plain `test` bodies with `thsl-src!` checkpoints on every
`let`/`expect` statement, but `emit_api_test_stmt` (compiler/lib/emit_racket.ml:7043
in the tesl repo) emits api-test statements raw — no checkpoint, so no breakpoint
inside an api-test body can ever fire. Since api-tests are our primary backend test
form (they exercise handlers, auth, and — via `serverTools` — the agent tool path),
this is the main debugging gap left after the multi-module DAP fix.

**Workaround (works today):** set the breakpoint inside the HANDLER the api-test
drives, not in the test body. Handlers are fully instrumented; the in-memory
request pauses there with live locals (the verified "request → backend breakpoint"
loop in AGENTS.md).

**Scope (fix lands in tesl, tracked here because it blocks our workflow):**
- Mirror `emit_test`'s checkpoint wrapping in `emit_api_test_stmt`: wrap the
  `TsLet` value and the `TsExpect` subject in `(thsl-src! file line locals thunk)`
  using each statement's `loc`, accumulating bound names as `locals` so the
  debugger shows seed data, responses, and decoded bodies while stepping.
- Cover the remaining statement arms (`TsExpr`, `TsExpectFail`, `TsIf` branches)
  so F10 stepping walks the whole scenario.
- Leave `load-test` request bodies uninstrumented (throughput benchmark —
  intentionally has no Debug lens).
- Verify end-to-end from VSCodium: breakpoint on a `let r = get …` line in an
  app.tesl api-test stops with `r` inspectable; then continue into a handler
  breakpoint in the same session.
- Note for docs/LEARNINGS.md: under `--test-name` only the selected block is
  emitted, so breakpoints in OTHER test blocks are silently dead during a
  single-test debug session — expected, but surprising.
