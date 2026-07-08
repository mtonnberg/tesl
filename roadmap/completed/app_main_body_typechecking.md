# App-main bodies skip type-checking — close the `is_app_main` fail-open

**Status: IMPLEMENTED (2026-07-08, same day as drafted)** — shipped as designed (option "check the let-chain; keep the App tail structural"), all phases in one pass:

- `checker.ml` `is_app_main` branch now runs `check_app_main_lets`: each `ELet`/`ELetProof` binding value is inferred exactly like the ordinary inference arms (declared-type unification, let-polymorphism generalization, env threading so later lets see earlier ones), stopping at the `App { … }` tail, which stays structurally validated as before.
- **Phase-0 audit result**: decl-name references from main lets already resolve (`startEmailWorker AppEmail` probe clean); statement forms (`enqueue`, `publish`, `telemetry`, …) chain as `let _ = <stmt-node>` and their checker arms fire — a wrong-typed or unknown field in a main `enqueue` payload is now a compile error. The earlier probe failure `let x = enqueue …` is NOT a gap: `enqueue` is a statement form, and the same let-value spelling errors identically inside fn bodies (parity, pre-existing design).
- **Corpus fallout: ZERO.** Every `.tesl` in `example/` + `tests/` compiles unchanged — no latent main-body errors existed in-tree.
- All three fail-open probes now rejected at compile time: `initTelemetry bogus "x"` → `unknown initTelemetry keyword: bogus`; `greet 42` → `cannot unify String with Int`; `doesNotExist "y"` → `unknown name`.
- Tests: `compiler/test/test_app_main_typecheck.ml` (9 checks: 4 fail-open classes incl. the initTelemetry keyword-shadow value, 5 sound variants incl. let-chain env threading and main-position `enqueue` payload checking), registered in test/dune.
- Docs: LANGUAGE-SPEC `<main-decl>` section now states main lets are fully checked and only the App tail is structural.
- The 2026-07-08 emitter `failwith` for valueless initTelemetry keywords is now defense-in-depth behind the checker (kept).

The original plan follows unchanged.

---

**Status: PLANNED (drafted 2026-07-08, discovered during the OpenTelemetry Metrics review pass)**

## Problem

`main() -> App` bodies are not type-checked at all. `checker.ml:4367-4383`:

```ocaml
(* App-pass entry point: `main() -> App = … App { … }` is declarative
   configuration whose fields reference declarations (databases/queues/servers)
   by name, not as values. It is validated structurally and lowered by the
   desugar pass, so its body is not type-checked here. *)
let is_app_main =
  fd.kind = MainKind &&
  (let rec tail = function
     | ELet { body; _ } | ELetProof { body; _ } -> tail body
     | ERecord { type_hint = Some "App"; _ } -> true
     | EApp { fn = EConstructor { name = "App"; _ }; arg = ERecord _; _ } -> true
     | _ -> false
   in tail fd.body)
in
(if is_app_main then () else check_stmt ctx' fd.body …)
```

The skip exists for a legitimate reason — the tail `App { … }` record references
declarations (`database: MetricsDb`, `api: MetricsServer`) by NAME, not as
value bindings, so ordinary inference on the record would fail — but the skip
covers the WHOLE body, including every `let` above the record. Those lets are
ordinary expressions and get zero checking.

## What is actually true today (probed 2026-07-08, working tree)

All three of these compile clean when placed as `let`s in an App-main
(`scratchpad/main-hole.tesl` probe; same file:line class as
[[env-builtins-import-soundness]]):

1. **`let _ = initTelemetry bogus "x"`** — unknown keyword, silently DROPPED by
   the emitter's catch-all (`emit_racket.ml` `emit_kw_args` `_ :: rest` arm).
   In a fn body the checker rejects it (`unknown initTelemetry keyword: bogus`,
   checker.ml:2546) — main is precisely where every example puts
   `initTelemetry`, so the validation never runs where it matters. The
   2026-07-08 metrics work added an emitter `failwith` for the
   valueless-keyword sub-case only (keyword directly followed by another
   keyword); a wrong keyword WITH a value still vanishes silently → telemetry
   config typos are inert with no diagnostic (exactly bug #19's symptom class).
2. **`let wrong = greet 42`** where `greet : String -> String` — type error,
   emitted verbatim as `(greet 42)`, fails at runtime (or corrupts, depending
   on the callee's dynamics).
3. **`let ghost = doesNotExist "y"`** — completely unbound name, emitted
   verbatim, crashes at Racket compile/load ("typechecks-but-unbound" — the
   stability-root class from [[stability-root-diagnosis]]).

What IS validated in main today: the App record shape (missing
`database`/`api` fields → V001, seen firing), module/decl structure
(`validation_structural.ml` MainKind arms), and capability rows. Only the
let-bound EXPRESSIONS escape.

Blast radius: any expression a user writes in a main `let` — telemetry init,
`startEmailWorker`, seeding/setup calls, helper invocations. Errors land at
Racket load or at runtime instead of compile time, or (for keyword forms)
nowhere at all.

## Design

**Check the let-chain; keep the App tail structural.** The `tail` walk in
`is_app_main` already knows the body's shape. Instead of skipping everything:

- Walk the `ELet`/`ELetProof` chain, running normal `infer_expr`/`check_stmt`
  on each binding's VALUE expression (bindings added to the env as usual so
  later lets see earlier ones).
- Stop at the final `App` record and validate it structurally exactly as today
  (no inference on the record or its decl-name fields).

Hypothesis to verify in Phase 0: decl names (queues, email specs) referenced
from main lets (e.g. `startEmailWorker AppEmail`) already resolve in the
checker env — worker/handler bodies reference the same names and ARE checked,
and the stdlib types them polymorphically (`deadJobs : _a -> List DeadJob`
pattern, type_system.ml:758). If some decl kind is NOT in the checker env,
bind it as an opaque nominal so main lets resolve the same way handler bodies
do — do NOT special-case skip again.

Rejected alternatives:

- **Type the App record itself** (phantom types for decl names in value
  positions): larger change, no user-visible win over structural validation —
  the record's shape checks already exist.
- **Per-form validators for main statements** (validate initTelemetry here,
  startEmailWorker there): whack-a-mole; the class is "main lets unchecked",
  not "initTelemetry unchecked" — fix the class
  ([[stability-root-diagnosis]]).
- **Leave it and rely on emitter guards**: the metrics-work `failwith` covers
  one sub-case of one form; unbound names and wrong-typed calls have no
  emitter guard and never can cleanly (the emitter has no type env).

## Phases

**Phase 0 — characterize + env audit.** Turn the three probes above into a
compiler test (expected-error fixtures). Audit which decl-name kinds resolve
in the checker env from a main-let position (queue, database, server, email,
cache, agent). *Exit:* failing tests demonstrating the hole; a list of any
decl kinds needing env bindings.

**Phase 1 — check the let-chain.** Implement the design; bind missing decl
kinds as opaque nominals if the audit found any. Expect fallout: the example
corpus may contain latent main-body errors that were never checked — fix them
(they are real bugs, not test friction). *Exit:* the Phase-0 fixtures pass
(errors reported at compile time); `./ci.sh` green including the full example
sweep; the emitter `failwith` for valueless initTelemetry keywords becomes
unreachable-but-kept (defense in depth).

**Phase 2 — retire redundant guards + docs.** Note in LANGUAGE-SPEC that main
bodies are fully checked except the declarative App tail; drop any per-form
workarounds made redundant. *Exit:* `dune test` + `./ci.sh` green.

## Non-goals

- Typing the App record's decl-name fields as values (structural validation
  stays).
- Checking `worker`/`deadWorker`/`handler` bodies differently — they are
  already fully checked.
- The emitter keyword-refolding design for `initTelemetry` (bug #19) — a
  separate wart; with the checker running in main, its failure modes become
  compile-time errors first.

## Risks & containment

1. **Latent errors in the existing corpus** turn into compile errors — that is
   the point, but it may break examples/user apps that "worked" by accident.
   Contain: run the full example sweep in Phase 1 and fix findings; note the
   change in the spec.
2. **Decl-name resolution gaps** (a main let referencing a decl kind absent
   from the checker env) would produce false "unbound" errors. Contain: the
   Phase-0 audit enumerates them before the flip; opaque-nominal bindings
   close each one.
3. **`let _ = …` discard semantics**: main lets are usually `_`-bound; ensure
   the checker does not warn/error on intentionally-discarded Unit values
   differently than in fn bodies (same `check_stmt` path = same behavior).

## Open questions

1. Should the App tail's `port:` / literal-valued fields get expression-level
   checking too (they are values, not decl names)? RECOMMENDATION: yes if free
   with the structural pass; not worth a separate mechanism.
