# Runtime constant-factor speed: Optimization Coach + (optional) one Optional-typed leaf

Actionable follow-up from `completed/evaluate_typed_racket.md` (which DISCARDED
sound gradual Typed Racket for the runtime). These are low-risk and pursue the
*actual* goal (constant-factor runtime speed) without the boundary hazards.

## 1. Optimization Coach (do first — zero risk, no TR)
`optimization-coach` is installed and is INDEPENDENT of Typed Racket (it reports
the Racket optimizer's inlining / unboxing / specialization decisions on plain
`#lang racket`). Open these in DrRacket with the plugin and triage:
- `dsl/private/check-runtime.rkt` — failed inlining of `raw-value`, proof-matching.
- `dsl/types.rkt` — codec `for/hash`/`for/list` specialization (45 `for`-forms);
  `runtime-type-satisfied?` inlining.
- `tesl/float.rkt` — float un-boxing.
- `dsl/sql.rkt` — the 54 `for`-form query loops.
Caveat: Coach is a DrRacket plugin (IDE findings, not a CI gate) — an analysis/
triage tool. Realistic payoff: single-digit-% constant-factor wins on specific
loops, achievable now.

## 2. Optional-typing pilot (only if you want static-doc value) — ONE leaf
`#lang typed/racket/optional` (types ERASED at runtime → zero runtime cost) on
exactly `dsl/private/evidence.rkt` (~158 LOC: the seven GDP struct defs + base
helpers). Goal is static documentation/safety of the system's most important data
shapes, NOT speed.
**Measure:** (a) `./compile-examples.sh` stays green; (b) compile-time delta on the
module; (c) did `raw-value`'s recursive `Any`/`Rec` typecheck without gymnastics.

## 3. Kill criteria (abandon immediately if any hit)
- Any `ns/call` or `bytes/call` regression vs the baseline in the report
  (proof-free 8.4 ns / 0 B; Optional must show none — a regression means a
  contract was forced → stop).
- `evidence.rkt` recursion needs more than trivial `Any`/`Rec` annotations.
- `./compile-examples.sh` or the Racket suite goes red.
- **HARD STOP:** never convert `check-runtime.rkt`, `dsl/types.rkt`, or `dsl/web.rkt`
  to Deep or Shallow Typed Racket (prefab `type-ref` + macro phase-1 + the GDP
  struct hub → documented 2–35× boundary slowdowns and multi-minute compiles).
