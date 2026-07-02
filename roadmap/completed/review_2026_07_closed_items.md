# 2026-07 external review — closed items (consolidated)

All items closed + verified across the three closing passes (2026-07-02). Each was
verified: repro rejected, legitimate control accepted, `--check-all example`=99 &
`tests`=38 & `templates`=2 green, `compiler/test/test_review75_reviewfixes.ml`
(13 cases) green, and full `dune test` showing no new failures (only the
pre-existing `elm-proof-surface` 3/5/8, which fail identically on the untouched
baseline). Companion reports: `EXECUTIVE-REVIEW-2026-07.md`,
`TECHNICAL-REVIEW-2026-07.md`. Open remainder: `roadmap/later/`.

## Critical / high soundness (forgeries)
- **PF-3/4/5/6, AUTH-1, PFC-1** — wrapper-nested proof/auth/establish forgery.
  `validate_ok_expr` (proof_checker.ml) is now a total, `| _ -> ()`-free match and
  the `establish` fact-constructor walks descend into
  `EWith{Database,Capabilities,Transaction}`, so a `transaction{}` / `with …`
  wrapper can no longer hide a minting site.
- **SHADOW-1/2/3** — the no-shadowing (V001) walk descends into bare constructor
  args and `fail` messages (was a fail-open no-op there).
- **F1/F2** — non-existential named-pack `-> T ? FromDb (Col == rhs)` insert
  forgery, generalised over the provenance column (`Id` and `OwnerId`/cross-tenant):
  `check_nonexist_named_pack_insert`.
- **EE-1** — existential insert with a wrapped/computed id now fails closed.
- **PFC-2 — container-wrapped proof minting (the last critical-class forgery) — FULLY
  CLOSED** via a 3-part chain, each verified with zero corpus regressions (99+38+2
  green; lesson52 `findMin`/`findMax`/`findMinAlt` — the Maybe/Either/custom cases —
  all still compile because their payloads carry the proof legitimately):
    - **(a0) field proofs enforced at CONSTRUCTION.** A constructor field declared
      `value: Int ::: IsPositive value` was decorative — `Node Leaf 5 Leaf` compiled
      clean, fabricating a "PositiveTree" with a non-positive value. Now the argument
      must carry the field's proof (`build_adt_ctor_field_bindings` +
      `check_ctor_field_proofs` in `check_record_field_proof_construction`, mirroring
      the record path). Regression R75_ADTFIELD.
    - **(a) field proofs PROPAGATE on destructuring.** `case t of Node l cur r ->`
      now gives `cur` the field's `::: P` proof (subject renamed field→binder), via a
      new `ctor_field_proof_registry` / `build_ctor_field_proof_map` and per-field
      propagation in the `ECase` handler of `check_expr_call_proofs`. Monotonic (only
      accepts more) — `needPositive cur` now compiles. Regression R75_FIELDPROP.
    - **(b) container producer check.** A forgery-restricted `fn`/`handler`/`worker`
      returning `Maybe (T ? P)` / `Either L (T ? P)` / custom eithers must have every
      returning SUCCESS payload (single-arg ctor whose payload TYPE is the proof's
      subject type — `Something x`/`Right x`/`CustomRight x`, NOT the error side nor
      `Nothing`) actually CARRY the proof. `Something (0 - 999)` / `Right (0 - 999)`
      rejected with a clear message; `check`-validated and field-proof-carried
      payloads accepted. Regressions R75_PFC2 (Maybe/Either forgery + checked-payload
      control). New `RetMaybeAttached` branch in the fn-forgery gate
      (`validation_advanced.ml`).
- **CAP-COMPOSE** — whole-program capability composition: `check_handler_capabilities`
  verifies `expand(unit.requires) ⊆ expand(main.requires)` for every handler (App
  `api:` server bindings), worker (`queues:` → `DWorkers`), and queue reachable from
  the App `main` returns. App-based reachability ⇒ zero false positives; a
  handler/worker requiring a capability `main` does not grant is now a compile error
  with a clear hint, instead of a runtime "Missing capabilities" 500.

- **TS-EQ #3 — equality recurses through nominal fields.** `is_equatable`'s
  `TName` arm now descends into a record/ADT's field types (guarded against
  recursive types), so a type that TRANSITIVELY contains a function is
  non-equatable — `record Handler { callback: (Int -> Int) }; a == b` is rejected
  ("`==` is not defined for type `Handler`") instead of emitting a meaningless
  `equal?` on closures. Plain records still compare. Regression R75_EQFIELD. (The
  remaining TS-ORD/EQ sub-holes — #1 stdlib-result types, #2 functions via a
  generic `TVar` helper — need the deferred Eq/Ord qualified-type layer / HM-type
  consumption; tracked in `roadmap/later/`.)

## Robustness / consistency
- **SC-01** — ForAll conjunction comparison made order-insensitive
  (`normalize_conj_str`), matching the plain-conjunction path.
- **AUTH-VIA** — `check_auth_proof_via` mirrors `check_capture_proof_via`:
  endpoint `auth <b> ::: P via <fn>` is validated at the frontend for existence,
  kind, and predicate coverage (was deferred to Racket load / first request).

## Tooling / verification / docs
- **TOOL-AGENTCTX** — `agent-context` now folds in linter findings (was dropping
  all warnings — the documented primary agent loop reported 0 warnings always).
- **TOOL-DBG-HELP** — `debug-inspect` is listed in `tesl --help`.
- **VER-MUT** — mutation `scored = 0` now reports "n/a (0 scorable mutants)"
  instead of a misleading 100%.
- **TOOL-FMT-HINT** — verified NOT a bug: the shipped `tesl` wrapper
  (`nix/tesl-cli-body.sh`) provides a bare `fmt` subcommand; the review had tested
  the raw compiler `main.exe` (only `--fmt`). Hint is correct for end users.
- **DOC-TEMPLATES** — both `tesl init` scaffolds compile (added `envRead` import +
  `requires`). **DOC-FAQ / best-practices** — non-compiling syntax fixed
  (`requires [db]`→`dbRead/dbWrite`, chained `:::`→`&&`, fictional `forall`, obsolete
  `test "x" = …`). **DOC-COST** — proof-cost claim corrected to match §4.3.
  **DOC-OTLP** — stale "not implemented" text removed. **DOC-SPEC-COMMENTS** — spec
  `tesl` blocks use `#`. **TOOL-MCP-COORD** — MCP README coord convention corrected.
- **ARCH-SEAM** (claim) — spec no longer implies a swappable runtime today;
  `ir.ml` described as a JSON tooling export. **ARCH-ADOPTION** (claim) — README
  states the mainstream-adoption goal is a direction, not a current capability
  (Nix-only on-ramp acknowledged).

## Regression guard
`compiler/test/test_review75_reviewfixes.ml` (wired into `compiler/test/dune`) —
13 cases covering the wrapper-forgery, shadow-descent, auth-via, FromDb-provenance,
EE-1, and CAP-COMPOSE fixes (each with its passing control).

## Also completed (own files in this directory)
`soundness_fail_open_validators.md`, `auth_via_boundary.md`, `docs_first_touch.md`,
`verification_methodology.md`, `architecture_trajectory.md`,
`review_2026_07_master.md` (the program tracker), `capability_completeness.md`
(CAP-COMPOSE portion).
