# Capability-gate config-block env (the mounting function needs envRead)

Deferred from `env_builtins_import_soundness` (Fix A + Fix B shipped). Per the
decision "when env* is used in a declarative block (database), the main function
referring to that database needs the capability."

## Why deferred (not a soundness hole)
Config-block `env*` (`database X = Database { port: envInt "P" 5432 }`) is desugared
to `tesl-env-raw` (NOT the `env` runtime function) and runs at startup from a base
require — it is runtime-safe without import or capability (verified: lesson18 et al.
compile). So this is a CONSISTENCY feature (make env access require `envRead` even
via config), not a correctness fix. Fix B already gates the meaningful case
(env-reading *functions*).

## What it needs (the hard part)
Novel App-wiring linkage:
1. Detect which `DDatabase`/`DEmail` config_exprs use `env*` (a `database → usesEnv?`
   map from the config blocks).
2. Trace which function MOUNTS such a database: `main() -> App = App { database: X }`
   (the App-record field) and/or `with database X { }` (EWithDatabase).
3. Require `envRead` on that function (extend collect_needed_capabilities to, on
   seeing `App { database: X }` / `EWithDatabase X` where X uses env, add envRead).

## Ripple
~10 config-env files would need their App-mounting `main` to declare `requires
[envRead]` (and import envRead): lesson18/26/29/31/59/60, ai-conversation-service,
todo-api, user-service-api, KanelBackend, tests/email-tests. Mechanical but broad.

## Tests
- main mounting an env-configured database without `requires [envRead]` → rejected.
- with it → accepted. Config-block env in a module with no mounting main → no
  requirement (nothing mounts it).

---

## STATUS: COMPLETED (core_polish) — implemented UNIFORM across all config blocks

The "hard part" (per-block App-record mount-tracing) was prototyped database-only and then
**discarded** in favour of a simpler, more correct model. User clarification: *"the database
was just an example, it should work the same for all declarative blocks."*

**Final model (validation_capabilities.ml):**
- `module_config_reads_env` — true if ANY declarative config block (database / queue / email /
  cache / agent) has a `= … { }` config that reads env (env/envInt/envString/requireEnv). Every
  such block initializes at **app startup**, i.e. when `main` runs, so the env read is uniformly
  `main`'s responsibility — no fragile per-block reference graph needed.
- `check_handler_capabilities` now also covers `MainKind`, but `main` is checked for **envRead
  only** (it reads env directly, or a config block it starts up does). main is deliberately NOT
  subject to the full transitive check — its body is lowered into
  `with capabilities main_caps { with database … }`, so the scope already grants its db/queue
  caps; env is the one effect the scope does not grant.
- The four near-identical handler/worker/fn/deadWorker arms were collapsed into one kind-driven
  arm (`cap_check_kind_info`), preserving the existing error text verbatim.

**Ripple:** 7 mains gained `requires [envRead]` + an `envRead` import (lesson18, lesson31,
todo-api, chat-backend, KanelBackend, ai-conversation-service, ai-live-check); `.rkt` regenerated.

**Tests:** `compiler/test/test_review67_block_validation.ml` group `env-honesty` (R67_ENV01-09):
C1 direct env in main, C2 database config, agent uniformity (non-database block), a no-env
control (guards against a false positive), and a non-main Fix-B regression guard.

**Known limitation:** per-module (like every other capability check) — a library that declares
env-reading config but has no `main` relies on the importing app's `main`; cross-file apps are
not linked.
