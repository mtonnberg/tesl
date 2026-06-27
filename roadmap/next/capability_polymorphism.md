# Capability polymorphism (capability-row variables on function types)

Status: SPEC — to be implemented as a dedicated pass *after* the config/App pass,
the `.rkt` regeneration sweep, and the proof-test refresh.

## Problem

Tesl's capability system gives a strong, valuable guarantee:

> A function declared `requires []` (or with no `requires`) promises that **nothing
> in its entire call tree touches a capability**.

This breaks down for **higher-order functions**. Consider `listMyOrgsHandler`
(KanelOrg.tesl), which `requires [kanelDbRead]` and does:

```
let memberships = ...           # select-many, needs dbRead (via kanelDbRead implies dbRead)
List.foldl fetchOrgByMembership [] memberships
```

`fetchOrgByMembership requires [kanelDbRead]` (it reads the DB). But `List.foldl`
is capability-free. At runtime, every function body is wrapped in
`call-with-declared-capabilities (list <its caps>)` (see
`dsl/web.rkt:build-executable-expansion` and `dsl/capability.rkt`). `foldl`'s caps
are empty, so it **narrows the declared context to `[]`**, and when it invokes the
callback, the callback's `[dbRead, kanelDbRead]` is checked against `[]` →

```
GET /orgs: capability violation in handler listMyOrgsHandler —
  Capabilities not declared by the current DSL context: (db-read kanelDbRead)
```

This currently blocks `example/kanel/KanelBackend.tesl` and
`example/chat/chat-backend.tesl` api-tests (surfaced once the unrelated
`_queue_for_<Job>` desugar regression was fixed — see the queue-config fix in
`desugar.ml:queue_job_types`).

## Rejected fix: "empty ⇒ transparent"

Making capability-free functions transparent to the declared context (inherit the
caller's instead of narrowing to `[]`) **voids the core guarantee**: a `requires []`
function could then perform DB reads through a callback, invisibly. Strictly worse
than the bug. Do not do this.

## Design: capability-row polymorphism

A higher-order function **opts into** propagating its callback's capabilities by
naming a **capability(-row) variable** on the parameter's function type and
including it in its own `requires`:

```
fn customMap(xs: List Int, f: (Int -> Int requires c)) -> List Int requires [time, c] =
  let now = nowMillis()
  List.map f xs

fn customMap2(xs: List Int,
              f1: (Int -> Int requires c),
              f2: (Int -> Int requires c2)) -> List Int requires [time, c, c2] =
  ...
```

Reading: `customMap` uses `time` directly, **plus whatever `f` needs**. The opt-in
is explicit and visible in the signature. `List.map`/`foldl`/`filter`/… become
honestly polymorphic instead of special-cased.

The `requires []` promise is preserved: a function with no capability variables and
no concrete caps still guarantees a capability-free call tree.

### Key design decisions

1. **Variable vs concrete disambiguation.** An identifier in `requires` is a
   capability *variable* iff it is bound by a parameter's function-type `requires`;
   otherwise it must resolve to a declared `capability`, else error
   ("unbound capability variable `c`"). Binding occurrence (the param type)
   disambiguates — no new sigil. `time`/`random`/`dbRead` remain concrete.

2. **`c` is a row variable (a set), not a single capability.** If `f` needs
   `[dbRead, random]`, `c` instantiates to that whole set, and `requires [time, c]`
   expands to `time ∪ {dbRead, random}`.

3. **Arrow-type syntax.** `(Int -> Int requires c)`. A pure callback instantiates
   `c = {}`, so the HOF requires only its concrete caps. Allow the bracketless
   single-variable form (`requires c`) and brackets for multiples
   (`requires [c, time]`) on arrow types.

4. **Instantiation at the call site.** When `customMap` is applied to a concrete
   `f` whose type carries `requires [dbRead, random]`, unify `c := {dbRead, random}`
   and check the caller holds `time ∪ c`. Distinct variables (`c`, `c2`) instantiate
   independently. Two params *may* share a variable to require identical caps
   (advanced; can defer).

5. **Explicit, not inferred.** Consistent with Tesl's "declare your capabilities"
   philosophy. The HOF must list the variable in its own `requires` (forgetting it
   while the body calls `f` is a compile error, exactly as today).

## Runtime: lean on the static guarantee (option b), with a gated net

Decision: capabilities move toward a **compile-time-only** check, mirroring
zero-cost proofs. The static checker (with polymorphism) becomes the source of
truth; the runtime declared-context check for the higher-order case is relaxed.

**Risk-driven constraints (do not skip):**

- Capabilities are a **security** boundary — a static false-negative = an
  unauthorized privileged op actually runs. Higher completeness bar than proofs.
- **Atomicity:** the runtime net may only be relaxed *together with* the static
  polymorphism checker, never ahead of it (else the HOF case has neither static nor
  runtime enforcement).
- **Dual-mode like proofs:** reuse the `zero-cost-proofs?`-style switch.
  - Production: erased (zero cost).
  - CI/tests: net retained as an oracle that keeps catching checker regressions,
    including polymorphic-instantiation, transitive, and nested-arrow cases.
  - Fully erase only after the checker has comprehensive +/- coverage and has been
    green for a while.

The runtime closure-tagging alternative (closures carry their declared cap set so a
HOF computes `own ∪ caps-of(callback)`) is the strongest net and matches the row
model exactly, but changes closure representation; kept as a fallback if (b)'s
static coverage proves insufficient.

## Implementation surface

- **Parser:** `requires` on arrow types; capability variables in `requires` lists.
- **Type system:** capability-row variables; function types carry a cap row;
  unification/instantiation of cap rows.
- **Checker:** bind variables from param function-types; propagate to the enclosing
  `requires`; instantiate at call sites; report unbound variables; keep the
  "uses-but-didn't-declare" error.
- **Emit:** how the (now polymorphic) declared context is emitted given (b).
- **Runtime:** gate `call-with-declared-capabilities` enforcement behind the
  zero-cost switch; relax the HOF nesting check in erased mode.
- **Stdlib:** annotate `map`, `foldl`, `foldr`, `filter`, `concatMap`, `any`, `all`,
  `find`, `Dict.foldl`, `Set.foldl`, … with `requires c` capability rows.

## Tests (must include negatives)

- Positive: HOF with capability-bearing callback compiles + runs (the kanel/chat
  `List.foldl` case; `customMap`/`customMap2`).
- Positive: pure callback ⇒ `c = {}` ⇒ HOF requires only concrete caps.
- Negative: HOF body calls `f` but omits `c` from `requires` → compile error.
- Negative: `requires [c]` with no binding param → "unbound capability variable".
- Negative: caller lacks `time ∪ c` at instantiation → capability error.
- Negative (regression oracle): a genuine `requires []` function that performs a
  capability op directly is still rejected.

## Decisions captured

- Sequencing: **spec now, implement as the next pass.**
- Runtime: **(b) lean on static**, with the gated-net / dual-mode discipline above.
- `chat-backend` + `kanel` api-tests remain red until this pass lands (documented).
