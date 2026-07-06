# Stdlib surface drift: importable names with no runtime binding (+ cap-charge gaps)

> **DONE 2026-07-06.** Every concrete Class-A / A′ instance is resolved
> (implemented or removed — see the ✅ rows). Regression:
> `tests/stdlib-delete-tests.tesl`; registry oracle
> `test_capability_registry.ml` updated for the `generateId` charge. Gate green.
> The **durable binding-existence seam test** (the guard that closes this class
> by construction) is carved out into its own item —
> [[stdlib_binding_existence_seam_test]] in roadmap/next — because it is a
> separate, non-trivial cross-language deliverable, not part of the remediation.
> Class-B (ApiTest queue-cap consistency) stays recorded here as NOT exploitable.

Found 2026-07-06 by a fail-open audit spun off the email-capability fix
([[email_capability_not_composable]] in roadmap/completed). Same generator as
that bug and as `env-builtins-import-soundness`: **one fact ("stdlib name X
exists / is an effect") is hand-restated across several tables — the
`Type_system` per-module import allowlist, the `stdlib_env` type table, the
`stdlib_capabilities` cap-charge table, and the runtime `.rkt` `provide` lists —
and the tables have drifted.** All findings below were verified against the
current tree (post `6524407`).

## Class A — importable + typechecks but NO runtime binding (runtime crash)

A program that imports one of these names passes `tesl --check` (the name is in
the `Type_system` import allowlist and, for most, has a `stdlib_env` type), then
crashes at Racket module load / call with "unbound identifier" — the mapped
`.rkt` provides no such name. None are exercised by any shipped example, which is
why the gate is green. This is the exact `env-builtins-import-soundness` class,
now with a concrete verified inventory:

| Name | Declared (type / export / home) | Runtime gap | Suggested disposition |
|---|---|---|---|
| `randomFloat` | type + Tesl.Random export + home + charges `random` | ~~no runtime `randomFloat`~~ | **✅ DONE 2026-07-06** — `(define (randomFloat) …(racket-random))` `[0,1)` + provide in `tesl/random.rkt`; registered in `stdlib_zero_arg_names`, called as `randomFloat()` (fresh per call, like `UUID.v4()`) |
| `Time.millisToSeconds` | type + Tesl.Time export | no runtime binding | **✅ DONE 2026-07-06 — REMOVED** (type + Tesl.Time allowlist entry deleted; redundant with `posixToSeconds`). Import/use now rejects. |
| `Dict.delete` | type (alias-of-remove) + export | ~~no runtime binding~~ | **✅ DONE 2026-07-06** — `(define Dict.delete Dict.remove)` + provide in `tesl/dict.rkt` |
| `Set.delete` | type + export | ~~no runtime binding~~ | **✅ DONE 2026-07-06** — `(define Set.delete Set.remove)` + provide in `tesl/set.rkt` |
| `generateId` | type + home Tesl.Id; **taught in `manual/overview.md:41,51,103`** | ~~no runtime `generateId`~~ | **✅ DONE 2026-07-06** — `(define (generateId) …(tesl-generate-prefixed-id ""))` + provide in `tesl/id.rkt`; charges `random`; registered in `stdlib_zero_arg_names`, called as `generateId()` |
| `newId` | type + home Tesl.Id | no runtime binding | **✅ DONE 2026-07-06 — REMOVED** (type + home entry deleted; redundant with Tesl.UUID). Use now rejects (`unknown name`). |

**`Dict.delete` / `Set.delete` were the two zero-risk inline fixes** (pure
synonyms of the existing `remove`) and are **DONE** — landed with the runtime
aliases + a checked-in regression `tests/stdlib-delete-tests.tesl` (emits + runs,
2 tests pass; would have been "unbound identifier" before). The rest still need a
one-line runtime def whose *semantics* an owner should confirm (range of
`randomFloat`, exact conversion of `millisToSeconds`, what `generateId`/`newId`
should produce) before guessing.

### Also Class A but compile-caught (milder): phantom exports — **REMOVED 2026-07-06**
- `List.mapCheck` / `Set.mapCheck` were phantom exports (export lists + emitter
  GDP-classification only; no type, no runtime). Initial decision was IMPLEMENT,
  but on review **`mapCheck` has no meaning distinct from `allCheck`**: both
  check every element and yield a `ForAll P` collection on the happy path; the
  only difference a `mapCheck` could add is *raising* on failure instead of
  returning `Nothing` — an unhandled-throw-behind-erased-proofs anti-pattern
  that Tesl's Maybe-returning `allCheck` exists to avoid. (A genuinely distinct
  `mapCheck` would be a type-CHANGING map-with-proof `(a→b) → List a → List b`,
  a separate larger design, not what the `a→a` phantom signature implied.)
  **DECISION FLIPPED → REMOVE.** Deleted from the two module export allowlists
  (`type_system.ml:769`, `:810`) and both emitter GDP-classification lists
  (`emit_racket.ml`); `import Tesl.List exposing [List.mapCheck]` now rejects.
  No type or runtime was added.

### Class A′ — type/runtime arity drift: `randomInt` — **DONE 2026-07-06**
- Was: type `(Int, Int) -> Int` vs runtime single-arg `(randomInt n)` → arity
  crash. **Fixed:** runtime is now 2-arg `[lo, hi)`
  (`(+ lo (racket-random (- hi lo)))`) to match the type. Callers constrain
  `lo < hi` via a proof on the inputs (the Tesl way).

## Class B — capability-charge consistency gap (NOT currently exploitable)

The four `Tesl.ApiTest` queue helpers `pendingJobCount` / `drainQueue` /
`processNextJob` / `processNextDeadJob` (`type_system.ml:629-632`, homed to
`Tesl.ApiTest` `:934-935`) perform queue read/write at runtime
(`tesl/api-test.rkt:258-296`, via `process-next-job/result!` +
`pending-job-count`), yet are **absent from `stdlib_capabilities`** — while their
siblings `deadJobs` / `requeue` ARE charged (`type_system.ml:1021`
queueRead/queueWrite). Clear drift.

**Verified NOT exploitable today** (2026-07-06): the agent's sketch
`handler h() requires [] { drainQueue Q }` does **not** compile — a queue name
does not resolve as a value outside test/api-test scope (`pendingJobCount
Lesson33Queue` inside an `api-test` block compiles; the identical call in a plain
`fn` gives `error[T001]: unknown constructor: Lesson33Queue`). Handlers reference
queues only via `enqueue JobType {…}`, never by queue name. So the helpers are
de-facto test-scoped through their argument, and the missing cap-charge is
latent defense-in-depth, not a live confinement break.

Risk if we "fix" it naively: charging these `queueRead`/`queueWrite` would
require the shipped api-test blocks that call them (chat-backend, KanelBackend,
agent-run-tests, lesson33) to declare those caps — they currently declare
**app-specific** queue caps (`chatQueue`, `kanelQueue`, `runQueue`) that may not
imply `queueRead`/`queueWrite`. So the charge could over-reject. Decision
deferred to the durable fix below (charge + reconcile the example blocks, OR
formally restrict `Tesl.ApiTest` to test context).

## Durable fix (the real deliverable)

A **binding-existence + cap-coverage seam test**, the missing analog of
`compiler/test/test_capability_registry.ml` (which already pins the cap table).
It pins, at build/test time:
1. every name in `stdlib_env` ∪ the dotted `tesl_module_exports` resolves to a
   real runtime `provide` (or an emitter alias / checker builtin) — kills Class A
   and the phantom exports by construction;
2. every runtime `require-capabilities!` site has a matching `stdlib_capabilities`
   charge (and vice versa) — kills Class B drift and would have caught the
   historical `durationMs` gap.

**Status 2026-07-06: every Class-A / A′ instance is resolved** (implemented or
removed — see the ✅ rows above), so the drift surface is clean. The durable
guard (the seam test) is tracked separately as
[[stdlib_binding_existence_seam_test]].

## Not findings (audited, clean)
- `durationMs` cap-charge (review §6) is already fixed (`type_system.ml:1013`
  charges `time`; `tesl/time.rkt:42` self-checks). Stale claim.
- `initTelemetry` / `decodeAs` (memory `env-builtins-import-soundness`) ARE bound
  (`tesl/telemetry.rkt:10` no-op stub; `tesl/agent.rkt:539` real) — no crash,
  though `initTelemetry`/`telemetry` are no-op stubs.
- `check_auth_call_restriction` (`validation_advanced.ml:1176`) has a
  non-recursing arm that could skip a `check authFn` nested in an `EField.obj` /
  bare `EConstructor` arg — but it is a semantic-hygiene DIAGNOSTIC, not a
  proof/capability gate (no proof forged, the auth fn still runs), and the
  bypass shape is contrived. Logged, low priority; not scheduled.
