# `env`/`envInt`/`envString` compile without import but fail at runtime (soundness)

## Updates

### DECISIONS

- Using env, requireEnv, envInt etc should require a stated capability, when used in a declarative bloc (such as database) then the main function referring to that database needs the correct capabilities
- no functions should be able to be used without importing it (option A below)
- Fix the other functions that compile without import 


## Why (the bug — "incorrect code through the compiler")
Found 2026-06-30 on `core_polish` (taken_decision.md B5 fallout). Using an env
builtin in **function-body / expression position** without `import Tesl.Env`
**compiles cleanly** but emits Racket that is **unbound at runtime**:

```tesl
#lang tesl
module TEnv exposing [getPort]
import Tesl.Prelude exposing [Int, String]
fn getPort() -> Int requires [] = envInt "PORT" 3000   -- NO `import Tesl.Env`
```
→ compiles ✓, emits `(envInt "PORT" 3000)` with **no** `(require tesl/tesl/env)`
→ `raco`: `envInt: unbound identifier`. This is exactly the "incorrect code
through the compiler" failure class. It was masked for `example/chat/chat-backend.tesl`
(which uses `envInt` at a function body, line 541) by a stale committed `.rkt`;
fixing the snapshot exposed it.

## Root cause
- `env`/`envInt`/`envString` are registered in the **global type env**
  (`compiler/lib/type_system.ml:480-482`), so the checker accepts them with no
  import.
- The emitter only adds `(require tesl/tesl/env)` when `Tesl.Env` is **imported**
  (`emit_racket.ml` require table, `add "Tesl.Env" "tesl/env.rkt"`).
- **Config-block** usage (`database X = Database { port: envInt "P" 5432 }`) is
  rendered self-contained by `emit_racket.ml:~4913` (NOT a runtime `envInt` call),
  so it correctly needs no require/import (verified: `lesson18`/`lesson26`/… use
  config-block `env*` with no `Tesl.Env` import and no `tesl/tesl/env` require).
- The gap is specifically **function-body / expression-position** `env*` usage.

## Fix (recommended: A — reject at compile time)
**A. Checker/validation rule:** when `env`/`envInt`/`envString` is referenced in
expression position (a function/const body, not a config block) and `Tesl.Env` is
not imported, emit a clear error (e.g. "use of `envInt` requires `import Tesl.Env
exposing [envInt]`"). Config-block usage is validated separately
(`validation_structural.ml`) and is unaffected. This matches the project stance —
turn a runtime "unbound identifier" into a compile-time rejection — and is the
class the repo has a history of letting slip.

**B. Emitter alternative (consistency):** always emit `(require tesl/tesl/env)`
when the emitted module contains a function-body `env*` call (AST walk), making
`env*` an always-available builtin (consistent with the global type env). Lower
user friction but doesn't *reject* anything.

A is preferred. Whichever is chosen, **negative tests are mandatory** (this is the
"must NOT compile" class): function-body `env*` without import → rejected; with
import → accepted; config-block `env*` without import → still accepted.

## Blast radius (small for env*) + the gap is GENERAL
Only `chat-backend.tesl` used function-body `env*` without the import (now fixed by
restoring `import Tesl.Env exposing [envInt]`). Every other `env*` user either
imports `Tesl.Env` (todo-api, user-service-api, KanelBackend, ai-*, ai-live-check)
or uses it only in config blocks (lessons 18/26/29/31/59/60, email-tests).

**But the gap is not specific to `env*`.** The global stdlib type-env
(`type_system.ml`) makes MANY functions typecheck without import (`generatePrefixedId`,
`UUID.v4`, `randomInt`, `statusOk`, …), while the emitter's require list is
**import-driven** (`emit_racket.ml` `add "Tesl.Env" "tesl/env.rkt"`,
`add "Tesl.Id" "tesl/id.rkt"`, …). Any such function that lives in an import-only
`.rkt` module (NOT a base/always-emitted require) and is used in expression
position without its import has the SAME compile-clean / runtime-unbound behaviour.
A correct fix therefore must reconcile the global type-env against the import-driven
require set across the whole stdlib — a design decision (checker-rejects vs
emitter-emits-by-usage) plus a full corpus audit of which modules are base vs
import-only.

## Status: DEFERRED to `roadmap/later` (rationale)
The concrete instance (chat-backend) is FIXED, and the gate's **Tesl-test sweep**
catches this class for any committed example at runtime (it is exactly how
chat-backend was caught). The general compile-time hardening is **architectural**
(touches the type-env / import-resolution / emitter require model and many stdlib
functions); rushing it risks destabilising the type & import system — the opposite
of the "smaller, more stable core" goal. It should be done deliberately with the
design decision above and a corpus audit, not folded into an unrelated polish pass.
Residual risk after deferral: user code (not in the example sweep) using an
import-only stdlib function in expression position without its import compiles but
fails at runtime — a clear error (`unbound identifier`), not silent unsoundness.

## Verification
- New negative tests (above) in `test_frontend`/`test_library_negative`.
- `dune test` + `./compile-examples.sh` green.
- Manual: the TEnv snippet above is rejected with a clear import hint.

## Status: Fix A + Fix B DONE (2026-06-30, core_polish); Fix C deferred
- **Fix A (Option A — import required):** bare import-only stdlib fns
  (env/envInt/envString/requireEnv + Id/Random/Time/ApiTest/Cli) used in
  expression position now require their module import (scope-aware; the Agent
  function set excluded — `__tart_` path). 0 corpus breakage. Tests: R65_SB*.
- **Fix B (env capability):** env*/requireEnv in a function body require the new
  `envRead` capability (named envRead, not env, to avoid the function clash),
  flowing transitively. Capability walk made shadow-aware. Only lesson11 affected
  (it teaches capabilities). Tests: R65_SBC*. (Found+patched a duplicated
  capability-provider map across validation_common + proof_checker — a live
  instance of soundness_increase Tier-0 #1.)
- **Fix C (config-block env → mounting function) — DEFERRED to
  `roadmap/later/env_config_block_capability.md`.** Rationale: config-block `env*`
  (`database X = Database { … env "P" … }`) is desugared to `tesl-env-raw` and is
  **runtime-safe** without import/capability (verified: lesson18 compiles). So this
  is a *consistency* feature, not a soundness fix. The real pattern is App-mounted
  databases (`main() -> App = App { database: X }`), so gating it needs **novel
  App-wiring linkage** (config-env-per-database → which function mounts it → require
  envRead there) plus a ~10-file ripple. Better as a focused, well-designed
  follow-up than rushed into this pass; the meaningful effect-gating (env-reading
  functions) is already done by Fix B.
