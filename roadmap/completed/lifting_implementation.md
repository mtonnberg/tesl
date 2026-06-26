> **STATUS: PARTIAL — shipped + remainder carved to later/ (2026-06-26).** Built the
> reusable lift mechanism (leaf-primitive split + tesl/<mod>.tesl bodies +
> scripts/gen-stdlib-rkt.sh bootstrap with path-normalized snapshots + a ci.sh
> drift gate). Lifted **List** (16 combinator bodies) and **Either** (10 combinators
> — types AND bodies, removing 10 stdlib_env rows; the doc's "biggest win") from
> hand-written Racket into Tesl. Net: trusted hand-written .rkt core 303→265 code
> lines; stdlib_env 162→152; 26 combinator bodies now auditable Tesl. DEFERRED →
> roadmap/later/lift-remaining-stdlib-and-foreign-fn.md: Dict/Set (proof-machinery
> drift risk), Int (marginal — most lack type rows), and the `foreign fn` form (P2,
> high blast radius, superseded for core-shrink). Maybe/Result have NOTHING to lift
> (ADT re-exports). Gates green (58-lesson 0-differ, parity tests, drift gate).
> dev-docs/05-adding-stdlib-function.md updated.

---

# Smaller Core — Lifting the standard library into Tesl

> Part of the **Smaller Core** theme — see `smaller_core.md` for how this fits with the
> sibling initiatives.

## Context

Tesl is a hybrid: an OCaml frontend compiler (~36k lines) + a trusted Racket
runtime/substrate (9,860 `.rkt` lines in `dsl/`, ~8,315 excluding tests/debug) +
a Racket-written standard library
(~4.4k lines in `tesl/*.rkt`). The goal of this work is a **smaller core**: offer
the same functionality with less code, written in as much Tesl as possible, so the
language is exercised on itself ("expanding the feature-set without increasing the
tech burden"). The Racket *runtime* stays for now — only stdlib source moves.

The concrete pain is real and measurable: *"all the standard libraries that are
racket code need special handling to add types."* Every stdlib function lives in
**two** hand-maintained places that must stay in sync:

1. **Implementation** in `tesl/<mod>.rkt` — e.g. `(define (List.sum xs) (apply + ...))`
2. **Type signature** in `compiler/lib/type_system.ml` `stdlib_env` (202 entries)
   plus an export entry in `tesl_module_exports` — e.g. `"List.sum", mono (t_fun [t_list t_int] t_int)`

The OCaml checker can't see inside the Racket file, so a human transcribes each
signature. Drift between the two is a latent soundness risk.

### The key architectural realization

The compiler already has a **from-source type loader**: `load_imported_func_sigs`
(`compiler/lib/checker.ml:616`, called from `compile.ml:2232/2379`) parses an
imported local `.tesl` module and infers its **types** directly from source.
(`load_imported_func_info` in `compiler/lib/validation_common.ml:611` is a sibling
loader, but it produces only **proof metadata** — `func_info` records for
proof-annotated parameters — not types; types come from `load_imported_func_sigs`
plus `make_stdlib_env()` at `checker.ml:1297`. `load_imported_ctor_info` /
`load_imported_cap_map` likewise carry ctor/capability info, not signatures.) This
is how `import Email exposing [...]` works in `example/library-examples/` today —
**with zero `stdlib_env` involvement**.

Stdlib modules don't use that path because they are flagged *special* at the type
loader itself: `load_imported_func_sigs` has its own `is_tesl_module` short-circuit
(`checker.ml:617`) that returns `[]` for any `Tesl.*` module, so their types fall
back to the hardcoded `stdlib_env`. (Note: `compile.ml:1686 is_tesl_stdlib_module_name`
is a *different* switch — at `compile.ml:1935` it only **excludes** `Tesl.*` from
the local-file dependency graph in `build_local_import_graph`; it has nothing to do
with type loading. Flipping it alone changes nothing about where stdlib types come
from.)

**Therefore: if we promote stdlib modules from "special/hardcoded" to "ordinary
source `.tesl` modules," OCaml needs no hardcoded knowledge of any lifted
function** — no `stdlib_env` entry, no `tesl_module_exports` entry, and no separate
"type-export generator." Shrinking the Racket core and eliminating the type
duplication become the *same* move. This is the recommended approach.

**Scope caveat — it is not one switch.** The `Tesl.`-prefix specialness is not a
single guard: there are **~47 `Tesl.`-prefix / `is_tesl_module` short-circuit sites
across 7 files** (`checker.ml`, `compile.ml`, `emit_racket.ml`, `proof_checker.ml`,
`validation_common.ml`, `validation_names.ml`, `validation_structural.ml`). Putting
even one module on the from-source path means threading the exception through every
relevant one of these (type loading, naming/require paths, proof/structural checks,
the dependency graph), not flipping a single line. Budget for the breadth.

### Intended outcome

- Pure, leaf-free stdlib functions are written in `.tesl` and dogfood the language.
- `stdlib_env` shrinks from 202 entries to ~60 (only irreducible leaves + operators).
- Adding/changing a derived stdlib function means editing one `.tesl` file; the
  compiler infers its type. No OCaml edit, no double-maintenance.

## Feasibility — verified, not assumed

All confirmed against the built `tesl` binary during planning:

- **Self-recursion works.** `factorial` emits a direct recursive Racket call
  (`example/learn/lesson14-test-blocks.rkt:23`); Racket provides TCO for tail calls.
- **Polymorphic user signatures work.** `fn applyToList(f: a -> b, xs: List a) -> List b`
  with free type variables `a`/`b` validates cleanly (`tesl validate`, exit 0).
- **Higher-order params work** (`fn applyTwice(f: Int -> Int, ...)`, lesson36).
- **End-to-end lift works.** A derived `sum` built on the primitive `List.foldl`,
  written in pure Tesl, compiles and `tesl test` passes ("1 test passed"). The
  emitted Racket is clean: `(tesl_import_List_foldl <lambda> 0 *xs)`.

### What can be lifted vs. what must stay a leaf

From a full audit of `tesl/*.rkt` (260 exports total, ~113 derivable):

| Module | Lift candidates (derived) | Keep as Racket leaf (FFI / primitive) |
|---|---|---|
| `list.rkt` | sum, product, max, min, any, all, count, partition, intersperse, intercalate, groupBy, dedupe, range, repeat, flatten, concatMap, member (~24) | head, tail, nth, map, filter, foldl/foldr, sort, zip, isEmpty, length |
| `dict.rkt` | map, mapWithKey, filter*, foldl/r, union*, intersection, difference, update (~8) | empty, insert, lookup, keys, values, fromList, size + proof ops (get/requireKey) |
| `set.rkt` | partition + several map/fold wrappers (~3) | empty, insert, member, union, intersection, difference, fromList + proof ops |
| `either.rkt` | map, mapLeft, andThen, withDefault, toMaybe, fromMaybe, isLeft, isRight (~13) | (constructors, once ADTs are Tesl-defined) |
| `maybe.rkt` / `result.rkt` | all (pure ADT + combinators) | (constructors) |
| `int.rkt` | min, max, clamp, sign, simple predicates (~5) | parse, pow, gcd, lcm, divide/modulo (proof), conversions |
| `string.rkt` | a few predicates (isEmpty, startsWith…) | length, split, join, replace, slice, case, parse, trim (proof) — mostly leaves |
| `float.rkt` | ~none | nearly all (transcendentals, parse) |

**Must remain Racket leaves** (no Tesl body to infer from): low-level string/char
ops, hash/set construction, float math, numeric parsing, and — critically — the
**proof-machinery functions** (`check`/`establish`-backed, and proof-consuming ones
like `Int.divide`/`Dict.get`/`List.take` that call `validate-runtime-argument`).
These are out of scope for lifting; touching them risks the GDP guarantees.

## Plan

### Phase 0 — Enabler: stdlib as ordinary source modules (one pilot module)

Make `Tesl.List` loadable from source while still backed by Racket leaves. Prove
the whole mechanism on one module before any broad sweep.

1. **Split `tesl/list.rkt`** into:
   - `tesl/list.rkt` (or `list-prim.rkt`) — only the PRIMITIVE leaves, exported as
     today with dotted runtime names (`List.foldl`, `List.map`, …).
   - `tesl/List.tesl` — a `library` module exposing the DERIVED functions, written
     in Tesl, importing the primitives via `import Tesl.List` (or a `Tesl.ListPrim`
     split — see naming note below).
2. **Resolve the naming impedance.** A `.tesl` module emits *bare* provides
   (`(define (sum …))`), but qualified calls expect dotted runtime symbols
   (`List.sum` → `tesl_import_List_sum`). Pick the least-invasive bridge:
   - **Option A (shim, recommended for Phase 0):** keep `Tesl.List` as the public
     module; its `.rkt` is a thin re-export that `require`s the build-compiled
     `List.tesl` output and re-provides bare `sum` as `List.sum` via `rename-out`,
     alongside the leaves. Compiler contract (`module_path_table`, dotted symbols)
     is unchanged; only the build gains a step.
   - **Option B (loader change):** teach the from-source path to register the
     module's exports under its qualified prefix. Cleaner long-term, more compiler
     work. Defer to Phase 2 if Option A proves awkward.
3. **Flip the module off the special path.** Thread a from-source exception through
   the **type loader's** short-circuit — `load_imported_func_sigs`'s `is_tesl_module`
   guard at `checker.ml:617` — so it infers the lifted module's types from
   `tesl/List.tesl` instead of returning `[]`. (`compile.ml:1686`/`:1935`
   `is_tesl_stdlib_module_name` is the dependency-graph exclusion, *not* the type
   path; it must be flipped too so the lifted `.tesl` is built, but it does not by
   itself move type loading.) This is not "one switch" — see the scope note below.
   Remove the lifted functions' entries from `stdlib_env` and `tesl_module_exports`
   in `type_system.ml`. Keep leaf entries.
4. **Bootstrap build step.** Add a Dune rule that compiles `tesl/*.tesl` →
   `.rkt` using the current `tesl` binary *before* tests/install, mirroring the
   existing `compiler/gen/` + `embedded_docs.ml` build-time-generation pattern.
   Two-stage: current binary compiles stdlib source; output ships in the package.
5. **Distribution.** Ensure `tesl/*.tesl` (and their compiled `.rkt`) are found by
   the same discovery `tesl run`/`validate` already use (`TESL_REPO_ROOT`, nix
   `share/`). Embed source via the `embedded_docs` mechanism if needed for the
   standalone binary.

### Phase 1 — Lift the pure/leaf-free modules broadly (chosen scope)

Once Phase 0's pattern holds on `List`, repeat for `Dict`, `Set`, `Either`,
`Maybe`, `Result`, and the `Int` derived helpers. Each module: split leaves vs
derived, write `<Mod>.tesl`, drop its `stdlib_env`/`exports` entries, regenerate.
`Maybe`/`Result` are pure ADT + combinators and the cleanest wins; `Either` is the
single biggest reduction (13 derivable functions).

Leave `String` and `Float` mostly as-is (they are almost all leaves) — lift only
the handful of trivial predicates if convenient.

### Phase 2 — Optional: `foreign fn` declaration form (deepest version of the goal)

Today the leaf primitives are the *only* reason `stdlib_env` must exist at all.
Add a Tesl declaration form (none exists today — verified) that gives a primitive's
*type* in `.tesl` source while its body names a Racket builtin, e.g.:

```tesl
foreign fn length(s: String) -> Int = racket "string-length"
```

This pushes even leaf *types* into the language, shrinking `stdlib_env` to just
core operators (`+`, `==`, `::`, literals, `if`). Highest payoff for the "implement
the language in the language itself" vision, but it is new surface syntax (parser +
type checker + emitter + linter/formatter) and should only follow a successful
Phase 1.

## Weighted pros and cons

**Pros**
- **High — removes the duplication at its root.** Lifted functions need zero OCaml
  knowledge; the from-source loader already exists, so this is reuse, not new
  machinery. Directly answers the stated pain.
- **High — dogfooding / agility.** New derived helpers are one `.tesl` edit. The
  language demonstrably expresses its own stdlib.
- **Medium — smaller trusted Racket surface.** ~1.4k lines of core-module Racket
  shrink toward leaves only; fewer hand-written Racket functions to audit.
- **Low/Medium — better errors & tooling for stdlib.** Stdlib source participates
  in the same type/proof checking, hover, and go-to-definition as user code.

**Cons / risks**
- **Medium — the emitter becomes more load-bearing.** `emit_racket.ml` (the trusted
  boundary) now produces more stdlib code paths. Mitigated by the existing
  differential safety net (`scripts/differential-proofs.sh`, 80/80 parity corpus) and
  by keeping leaves + all proof machinery in Racket.
- **Medium — performance.** Lifted functions delegate through `named-value`-wrapped
  calls; hot paths may allocate more than hand-tuned Racket. The proof-elision work
  (`roadmap/completed/actually-zero-cost-runtime-proofs.md`) has **already shipped**
  (tasks #8/#9/#10) and erasure is now unconditional/default-on, so that dependency
  is satisfied — no need to sequence against it. Mitigation: only lift proof-free
  pure functions; benchmark `List`/`Dict` before/after.
- **Low/Medium — build complexity & bootstrap.** A two-stage build (binary compiles
  stdlib source) adds a failure mode and a clean-build ordering constraint.
  Mitigated by following the established `compiler/gen/` generator pattern.
- **Low — naming-shim friction.** The bare-vs-dotted provide mismatch needs the
  Phase 0 shim (Option A) or a loader change (Option B); Option A is contained.
- **Low — does not shrink the OCaml frontend.** The 36k-line compiler is unchanged
  (slightly larger if Phase 2 lands). The "smaller core" win is on the Racket and
  type-table side, not the frontend.

## Critical files

- `compiler/lib/checker.ml` — `load_imported_func_sigs` (:616) with its
  `is_tesl_module` short-circuit (:617); **this is the from-source TYPE path** — flip
  lifted modules onto it here. Also `make_stdlib_env` (:1297, the hardcoded type
  source), `stdlib_module_of_prefix` (:2968), `known_qualifier_modules` (:1159);
  qualified-name resolution for stdlib.
- `compiler/lib/compile.ml` — `is_tesl_stdlib_module_name` (:1686), used at
  `build_local_import_graph` (:1935) as the **dependency-GRAPH exclusion** (not type
  loading); flip it so the lifted `.tesl` is built into the import graph.
  `load_imported_func_sigs` is called from here at :2232/:2379.
- `compiler/lib/type_system.ml` — `stdlib_env` (:287+, 202 entries),
  `tesl_module_exports` (:573+), `tesl_known_module_names` (:696); delete lifted
  entries, keep leaves.
- `compiler/lib/validation_common.ml` — `load_imported_func_info`/`_ctor_info`/
  `_cap_map` (:611/:423/:673); these carry **proof/ctor/capability metadata, not
  types** — adjust alongside the type path, but they are not the type source.
- `compiler/lib/emit_racket.ml` — `module_path_table` (:55+), `import_rename`
  (:95+), proof-consuming/comptime tables; require-path + symbol naming.
- `tesl/list.rkt` (and peers) — split into leaf `.rkt` + new `<Mod>.tesl`.
- `compiler/gen/` + `compiler/lib/dune` + `compiler/lib/embedded_docs.ml` — model
  for the build-time stdlib-compile/embed step.
- `dev-docs/05-adding-stdlib-function.md` — rewrite once the workflow changes.

## Verification

End-to-end, per the README testing doctrine ("compiling is not testing"):

1. **Per-module behavioral parity.** For each lifted module, keep a `.tesl` test
   that exercises every lifted function (`tesl test tesl/list.test.tesl`), plus the
   existing Racket suites (`tests/*.rkt`). Run `bash compiler/ci.sh` (OCaml tests +
   all `.tesl` compile) and `bash compile-examples.sh` (full pipeline + mutation +
   Racket aggregate).
2. **Differential safety net.** Run `scripts/differential-proofs.sh` (the only place
   the `TESL_ZERO_COST_PROOFS` toggle is wired — it does *not* live in `ci.sh` or
   `compile-examples.sh`) and confirm byte-identical / behavior-identical output, the
   same gate that guarded the erasure work. Note that proof erasure is now
   unconditional/default-on (tasks #8/#9), so the 0/1 toggle no longer changes
   compiler behaviour; treat this as a regression check on the differential script
   itself, and consider wiring that script into CI rather than relying on the env var.
3. **Type-source-of-truth check.** Confirm that with the lifted module's
   `stdlib_env` entries removed, `import Tesl.List exposing [...]` still type-checks
   user code (e.g. `example/todo-api.tesl`) — proving types now come from source.
4. **Performance guard.** Micro-benchmark a `List.foldl`/`Dict.union`-heavy handler
   before and after; ensure no allocation/latency regression beyond an agreed
   threshold (tie to the zero-cost-proofs measurement harness in
   `roadmap/next/optimizations.md`).
5. **Standalone-binary smoke test.** `nix build` + `tesl validate`/`run` an example
   outside the repo tree to confirm stdlib source/compiled output is discovered and
   embedded correctly.
