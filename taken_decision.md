# Decisions log — `core_polish` branch

Overarching goal: a **smaller, more stable core** — shrink surface area, find bugs, raise
quality. We have a history of letting **incorrect code through the compiler**, so negative
tests (code that must NOT compile) are first-class. Adding surface is suspect unless it closes
a genuine gap or removes a footgun.

Branch: `core_polish` (off `main` @ 8a4b3f0). Commits squashed to one at the end.
Each decision below was taken autonomously per the task brief; rationale recorded here.

---

## Per-item decisions (the original 7 in roadmap/next)

### 1. test_fixes → **DO**
Migrate `compiler/test/test_aisuite_entitlement.ml` off the removed `defineAgent`/`withTools`
to the unified `Agent { provider, systemPrompt, maxTokens, tools }` constructor. Pure
test-suite repair; keeps the entitlement proof-suite (263 negative cases) compiling against the
current API and re-verifies no proof regression. → `roadmap/completed`.

### 2. incorrect_lint_warnings → **DO** (soundness fix)
Two bugs: (a) a **soundness hole** — importing a type `T` without `T(..)` still brings `T`'s
*constructor* into scope (so `chat-backend.tesl` compiles though it shouldn't); (b) spurious
W050 unused-import warnings for Queue. Directly serves "don't let incorrect code through".
Fix import-ctor scoping in `checker.ml`; add positive+negative tests. → `roadmap/completed`.

### 3. incremental-validation-cache → **DEFER TO LATER** ⛔
Moved back to `roadmap/later`. Rationale: it **conflicts with the overarching goal**. It adds a
stateful cache (cache dir, LRU eviction, transitive-import hashing) and an **invalidation-key
soundness risk** — a wrong key silently validates stale inputs, which is *worse* than slow. That
is more surface + more state + a new soundness footgun, i.e. the opposite of a smaller, more
stable core. It is also a *performance* item; performance is not this cycle's objective
(stability + smaller surface is). The item itself is marked "deliberately the last and most
cautious bet" and "needs a sound design before any code". The "why" (warm-run speed) is
understood and legitimate — but not aligned now. Left in `later` with this note + the existing
shadow-mode-first design guidance.

### 4. lift-remaining-stdlib-and-foreign-fn → **SCOPE-THEN-DO**
- **DO**: lift the trivially-liftable, **non-proof-bearing** combinators (shrinks the trusted
  hand-written Racket core = the TCB, which serves the goal). Start with the safe subset and
  parity-gate every combinator.
- **DECLINE `foreign fn`** (split to `roadmap/later` as declined-with-reasons): adding a host-FFI
  form **adds surface and a new trust boundary**, and the security audit explicitly lists "no
  user-facing FFI" as a *strength*. It closes no real gap. If a genuine primitive gap appears
  (e.g. password hashing), add that primitive directly, not a general FFI.
- Risk flagged by analysis: flipping Dict/Set fully onto the source path means threading the
  `is_tesl_module` exception through ~47 short-circuit sites with proof/cap soundness on the
  line. Sequence carefully; if a module's lift can't be made provably parity-safe, leave it.

### 5. security_hardening → **SCOPE-THEN-DO** (split)
The item is explicitly unbounded ("security scope is unbounded … or it sprawls"). Split:
- **DO now** (→ `roadmap/completed/security_hardening_runtime_fixes.md`): the concrete,
  high-severity, secure-by-default **runtime** fixes, each with a standing `tests/security/`
  regression test — static path traversal (#5), request body-size + JSON-depth limits (#1/#2),
  error info-leak (#4), email CRLF + address validation (D1), HttpClient SSRF allowlist + CRLF +
  timeout + response cap (H1/H3/H4/H5), SSE auth-raise bug (S2), CSPRNG for prefixed IDs (#6),
  cache `LIKE`-escape + bound TTL (D3/D4).
- **SPLIT to `roadmap/later/security_hardening_program.md`**: the unbounded/architectural program
  — differential-parity standing gate, fuzz harness, emitter-mutation, adversarial proof corpus,
  lints-as-policy, SBOM/supply-chain, and the language-surface design audits (L1–L7), plus
  policy items needing design (default-deny auth #3, SSE per-key authz S1, TLS-verify defaults
  that can break self-signed setups). These need design + are not "land a fix" bounded.

### 6. surface-form-lowering → **SCOPE-THEN-DO** (split)
- **DO now**: lower `ECacheGet/Set/Delete/Invalidate` + `ESendEmail/EStartEmailWorker` to the
  data-driven `ERuntimeCall` core node and delete their bespoke `emit_racket.ml` arms (shrinks
  the emitter). These are context-free/position-independent (unlike the blocked forms). Byte-gate
  with committed `lesson59`/`lesson60` `.rkt` references.
- **SPLIT to `roadmap/later/surface-form-lowering-rawparam.md`**: EUnop / LInterp / telemetry /
  publish / with-blocks — all blocked on the same hard prerequisite (context-dependent
  `*name` raw-param unwrapping; verified-blocked 3×). High-risk byte-identity work; defer with
  the design note intact.

### 7. expose_request_query_parameters → **DO**
Closes a real gap (handlers can read `.cookies`/`.headers` but not query params). Per the
recorded decisions: repeated keys **last-wins**, **URL-decode** values, query is **inline in the
path** (`?...`), names **case-sensitive**. `Dict String String`, mirroring the existing shape.
→ `roadmap/completed`.

---

## Bugs found along the way
(Appended as discovered; each either fixed here or written as a new roadmap/next item and folded in.)

### B1 — Soundness: type-only import leaked an ADT's constructors (FIXED)
`import M exposing [Color]` (the bare TYPE) brought `Color`'s constructors (`Red`…) into
scope, so unimported constructors were usable — incorrect code compiled. Root cause:
`checker.ml load_imported_ctors` stripped `(..)` *before* the membership test, so it could
not tell `[Color]` from `[Color(..)]`. Fixed: a ctor enters scope only via the explicit ctor
name or the exact `Color(..)` form. 0 regressions across the example/test corpus (verified by
full compile-sweep). Covered by 7 new CTORSCOPE tests (positive + negative) in
`test_library_negative.ml`.

### B2 — Lint: config-block usage not credited → spurious W050 (FIXED)
`DQueue`/`DChannel`/`DCache`/`DEmail`/`DConst`/`DWorkers`/`DDatabase` were lumped into a
catch-all in `linter.ml collect_decl_names` that ignored their `config_expr`, so names used
only inside `queue X = Queue { … }` / `database X = Database { … }` were flagged unused.
Fixed: descend into `config_expr` (+ capabilities/database/types), mirroring `DAgent`. Verified
on `chat-backend.tesl` (5 spurious W050 → 0). Covered by 2 new W050 tests in `test_linter.ml`.
Also removed chat-backend's genuinely-unused imports (`env`, `Fixed`, `Memory`,
`SocketConnection`, `DatabaseBackend`) — those W050s were *correct*.

### Assessment of the item's "chat-backend should not compile" claim
DISPUTED / partly a misunderstanding. `queue X = Queue { … }` is **config-block syntax** handled
by the dedicated config checker; it does NOT reference the imported `Queue` as a generic
constructor (verified: removing the `Queue` import still compiles). So there is no
`Queue`/`Queue(..)` soundness hole there — the real constructor-scoping soundness bug was the
*local-module* case (B1), now fixed. Noted observation (not fixed, arguably by design): the
stdlib config ADTs (`Exponential`/`Fixed`/`DatabaseBackend`/…) are seeded by
`config_stdlib_seed` whenever the owning `Tesl.*` module is imported, regardless of the
`exposing` list — so explicitly importing them is redundant. Left as-is (the config-block
prelude-seeding is intentional, like Maybe/Either).

### B3 — More test files use the removed agent API (FIXING — folded into test_fixes)
`test_aisuite_capability.ml` (23×) and `test_aisuite_structured.ml` still call the removed
`defineAgent`/`withTools` → `dune test` has 78 failures there. Same class as test_fixes (which
only named entitlement). Migrating them to `Agent { }` too. (The full `dune test` is NOT run by
`compile-examples.sh`, which is why these stayed hidden — see the verification-gate memory.)

### B4 — Stale test asserted the OLD lenient codec behaviour (FIXED)
`test_frontend.ml test_codec_missing_toJson_errors` asserted (via `compile_ok`) that a codec
with only `fromJson` and no `toJson` **compiles** — the pre-rule "lenient" behaviour. The
codec-completeness rule added earlier (per user: "a codec with only toJson … should not
compile") now correctly REJECTS it, so `dune test` was red. The test's own NAME ("missing
toJson errors") already describes the correct behaviour; rewrote the body to expect the
rejection (a missing-`toJson` completeness error). Uncovered only because the gate doesn't run
`dune test`.

### B5 — Committed `.rkt` snapshot drift + a coverage gap in the drift gate (FIXED + new item)
While byte-verifying surface-form-lowering, a full regen sweep found several committed `.rkt`
**stale** vs current compiler output: `lesson32-api-tests.rkt` was **missing its entire
`(module+ test …)` api-test block** — so the gate's Tesl-test sweep silently SKIPPED it (no
`(module+ test` ⇒ not run); `chat-backend.rkt` carried a removed `import Tesl.Env` (stale after
this branch's W050 cleanup); `KanelNotify.rkt` had shifted source maps; `lesson03`/`lesson41`/
`lesson32` had machine-absolute `/home/<user>/…` paths baked in. Root cause: `compile-examples.sh`
RUNS committed `.rkt` but never regenerates+compares them, and the only regen-compare gate
(`test_integration` exact-match + `ci.sh`'s bash loop) covered ONLY `example/learn/`. **Fixed:**
regenerated every drifted `.rkt` (repo-relative paths) and **extended `test_integration`
exact-match to all of `example/` + `tests/`** (`test_all_examples_exact_match` /
`test_all_tests_exact_match`), proven to bite (injected drift → RED). Wired into CI because
`ci.sh` runs `dune test`. Did NOT add a check to `compile-examples.sh` itself: it is the
authoritative gate and editing it risks the very stability we're protecting; the
`test_integration`/`ci.sh` path is the standard, lower-risk home. → new item
`snapshot_drift_gate.md`, completed this session.

---

## Item progress (this session)
- **test_fixes** ✓ completed · **incorrect_lint_warnings** ✓ completed ·
  **incremental-validation-cache** → later (rationale above) ·
  **expose_request_query_parameters** ✓ completed (commit 27beaef) ·
  **surface-form-lowering** ✓ completed (commit 3be5b99; cache/email lowered, remainder→later) ·
  **snapshot_drift_gate** (discovered, B5) ✓ completed ·
  **security_hardening** ✓ completed (9 bounded runtime fixes F1–F9 +
  `tests/security-test.rkt` suite; unbounded program → `later`) ·
  **lift-remaining-stdlib-and-foreign-fn** — pending decision (see item 4 above).
- Discovered items (folded in): `env_builtins_import_soundness` → later (B5),
  `snapshot_drift_gate` ✓ completed (B5). Codec test fallout fixed (B4).

### Security_hardening — scope decision (final)
DONE: the 9 concrete secure-by-default runtime fixes (path traversal, info-leak,
body/JSON limits, CSPRNG ids, email/HTTP CRLF, cache LIKE/TTL, SSE auth-raise bug),
each load-checked + gate-verified (no regression) + (for the unit-testable 5: F1,
F4, F5, F6, F9) a standing `tests/security-test.rkt` rackunit suite wired into
`internal-all.rkt` (~28 assertions). Extracted pure exported helpers
(`static-path-segments-safe?`, `email-header-field-safe?`, `http-header-field-safe?`)
to make the guards unit-testable. F2/F3/F7/F8 are runtime-path/DB/SSE fixes verified
by code review + the no-regression gate (+ tests/cache-tests for F7). The unbounded
program (TCB differential/mutation gates, default-deny, SSRF allowlist, TLS verify,
SSE per-key authz, lints-as-policy, SBOM, L1–L7) → `later/security_hardening_program.md`.

---

## Continuation — final 5 next-items + the 4 parallel workflow commits

### Integration of the 4 parallel workflow commits → **CHERRY-PICK + manual merge**
The four background-agent commits were cherry-picked into `core_polish`:
`lsp-temp-files` (0a7cbab), `optimization_coach` typed-Racket evidence.rkt pilot (8738c11),
`soundness_increase` cap-unification (3192589), `surface-form-lowering` ETelemetry (0d588d3).
- **proof_checker.ml conflict** (cap-unification vs surface-form): resolved to the
  single-source-of-truth form — `stdlib_capabilities = Validation_common.tesl_stdlib_cap_map`
  — after verifying the canonical map is a superset of the literal (no capability dropped) and
  there is no dependency cycle (proof_checker already depends on Validation_common).
- **surface-form vs the 9-form world**: surface-form was based on a 3-lowered-form base; HEAD
  already lowered 9 (enqueue/workers/serve + cache×4 + email×2). Resolved as a UNION → ETelemetry
  is the **10th** lowered form. desugar.ml/emit_racket.ml/test_desugar.ml conflicts merged to keep
  all 9 + add ETelemetry (count assertion 9→10; `sample_expr_no_lowered` strips it too).
- **checker.ml RRawVar exhaustiveness** (commit 27d6c68): a HEAD-side segment walk
  (`ERuntimeCall { segments }`) that surface-form's base lacked needed `RRawVar _ -> ()`
  (a pre-rendered emitted name, like RLit — no scope walk). Found by the build.

### env_config_block_capability (Fix C) → **DO, UNIFORM across all config blocks**
Supersedes the earlier "Fix C deferred" note. The user clarified: *"the database was just an
example, it should work the same for all declarative blocks."*
- **Model:** every declarative config block (database / queue / email / cache / agent) whose
  `= … { }` config reads env initializes at **app startup**, i.e. when `main` runs. So the env
  read is uniformly **main's** responsibility. `module_config_reads_env` checks all five block
  kinds with one or-pattern; `main` requires `envRead` iff it reads env directly OR any config
  block in the module reads env. This is *simpler and more correct* than per-block App-record
  mount-tracing (which I prototyped first, database-only, then discarded): tracing queue/cache/
  agent references is incomplete and fragile, whereas "startup reads env ⇒ main carries envRead"
  is uniform and matches runtime semantics.
- **main is the capability boundary, NOT fully checked.** `check_handler_capabilities` never
  checked `MainKind` — by design: main's body is lowered into
  `with capabilities main_caps { with database … }`, so the scope grants its db/queue caps.
  The ONE effect the scope does not grant is reading the environment, so main is checked for
  `envRead` ONLY (extending the full transitive check to main would wrongly demand it re-declare
  every startup cap — a large, semantically-wrong ripple). The other four kinds keep the full
  check unchanged.
- **Refactor:** the four near-identical capability arms collapsed into one kind-driven arm
  (`cap_check_kind_info`), preserving the existing error-message text verbatim (snapshot tests
  pin it) and adding the `main` arm — net smaller surface.
- **Ripple (accepted, mechanical):** 7 mains gained `requires [envRead]` + an `envRead` import
  (lesson18, lesson31, todo-api, chat-backend, KanelBackend, ai-conversation-service,
  ai-live-check); their `.rkt` regenerated; `R67_APP01` fixture updated.
- **Known limitation (consistent with the rest of the per-module cap system):** validation is
  per-module, so a *library* module that declares env-reading config but has no `main` relies on
  the importing app's `main` to carry `envRead`; cross-file apps (e.g. Kanel split across files)
  are not linked. Documented in the roadmap note.
- **Tests:** `R67_ENV01-09` — C1 (direct env in main), C2 (database config), agent uniformity
  (non-database block), the no-env control (no false positive), and a non-main Fix-B regression
  guard. Positive + negative.

### The other four continuation items
- **lsp-temp-files-pollute-repo** ✓ done (0a7cbab): LSP writes validation copies to the system
  temp dir; `TESL_LOGICAL_PATH` bridges the temp content path to the logical import path so local
  imports still resolve. → completed.
- **surface-form-lowering-rawparam** ✓ done (0d588d3): ETelemetry lowered to `ERuntimeCall` via
  the new `RRawVar` segment (10th lowered form). `EUnop`/`EPublish`/`LInterp` remain BLOCKED
  (raw-param / position-dependent — documented in desugar.ml). → completed.
- **soundness_increase** ✓ strategy delivered + cap-unification shipped (3192589): the two
  capability-provider maps unified into one source of truth (`Validation_common.tesl_stdlib_cap_map`)
  so the proof checker and capability validator cannot drift. The strategy report stands as the
  ongoing plan. → completed.
- **optimization_coach_and_optional_typing_pilot** ✓ pilot done (8738c11): `evidence.rkt`
  converted to `#lang typed/racket/optional` (typechecks cleanly, runtime-erased) as the
  leaf-module static-doc pilot; Optimization Coach noted as the profiling complement. → completed.
