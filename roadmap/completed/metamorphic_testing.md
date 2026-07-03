# VER-METAMORPHIC — systematic soundness hunting (fuzz + metamorphic invariance + runtime oracle)

**Status:** COMPLETED. Sub-parts 1 + 2 DELIVERED (gate-green); **sub-part 3 DECLINED by the
maintainer (2026-07-03)** — see the banner on that section below. · **Effort:** L (three sub-parts: fuzzer M, metamorphic
property M, runtime oracle L) · **Refs:** 2026-07 review (VER-METAMORPHIC); `test_review75`
(durable fixtures for the already-fixed forgery classes); reuse `compiler/lib/mutate.ml`,
`Compile.check_module`, and the in-process harness in `compiler/test/test_s7_generative.ml`.

## Delivered — sub-parts 1 + 2 (`compiler/test/test_metamorphic.ml`, in the `dune test` gate)

- **Sub-part 1 — grammar-valid fuzz.** Every parseable `.tesl` under `example/` + `tests/`, plus
  each structural mutant from `Mutate.generate_mutants` (the proof/capability TCB), is run through
  `Compile.check_module` in-process; the property is that the checker never raises (totality). ~380
  programs fuzzed, 0 crashes.
- **Sub-part 2 — metamorphic invariance.** Two rewrites that are semantics-preserving *by
  construction* — insert an inert `let _ = 0` at a body head, and reorder two top-level functions —
  must not change the accept/reject verdict, asserted over the accepted corpus AND rejected
  fixtures (inverse direction). ~40+ invariance checks, all invariant.
- **Load-bearing verified:** a temporary `check_module` crash canary (env-gated) made every fuzz
  case fail as expected; reverted. The invariance property likewise fired during development,
  correctly flagging an unsound α-rename attempt.
- **α-rename NOT used (by design):** Tesl proofs carry variable names by string in
  return-spec/`:::`/FromDb positions outside the ordinary expression tree, so a partial rename is
  not meaning-preserving and manufactures false flips. A proof-aware rename (rename in body AND all
  proof positions) is a future enhancement — the harness is structured to add transforms easily.
- **Coverage logged + floored** (`fuzzed >= 50`, `invariance >= 40`, `crashes == 0`) so a green run
  cannot silently mean "explored nothing".

## Remaining — sub-part 3 only (needs go-ahead)

## Why

Tesl's guarantees rest on ~4.3k lines of checker + ~6.6k lines of emitter, and **proofs are erased
with no runtime backstop** — a checker/emitter slip is silent and shippable. Hand-written tests
(and the generative negative corpus, below) pin the bug *classes we already know about*; they don't
systematically hunt for the *next* one. This item adds three complementary, oracle-free (or
self-oracle) techniques that find new soundness defects automatically. `test_review75` already holds
regression fixtures for the fixed classes — VER-METAMORPHIC is the machinery that surfaces new ones.

## Relationship to existing work (do not duplicate)

- **Generative negative corpus** (`test_s7_generative.ml`, `Mutate.apply_soundness_transform_to_module`)
  is the *breaking* direction: apply a soundness-**breaking** AST rewrite to an accepted program and
  assert the checker now **rejects** it (attributed kill). VER-METAMORPHIC's metamorphic property is
  the **dual**: apply a semantics-**preserving** rewrite and assert the verdict is **unchanged**.
  Both are property-based and should share `mutate.ml`'s `Ast_visitor` rewrite plumbing and the
  in-process `Compile.check_module` harness — build the metamorphic runner beside the s7 runner.
- The **runtime proof-witness oracle** (sub-part 3) is the same class as the discarded/out-of-scope
  `roadmap/discarded/independent_emitter_oracle.md` (S8) and the behavioral runtime oracle (G7).
  Pursuing it here **re-opens that decision** — call it out explicitly before starting (it is the
  largest, most architectural sub-part; parts 1–2 are independent of it and worth doing first).

## Sub-part 1 — grammar-based program fuzzer over `--check`

Generate grammar-valid Tesl programs and run each through the frontend; the property is **the
checker must never CRASH or hang** — it may accept or reject, but an uncaught OCaml exception,
`failwith`, non-termination, or an internal-invariant assertion is always a bug.

- **Generator:** a grammar-driven generator producing well-formed modules (valid `module`
  header/imports, then declarations/expressions). Bias toward the proof/capability/SQL surface where
  the soundness TCB lives (`check`/`auth`/`establish`, `:::`, `FromDb`/`ForAll`, `requires`, `case …
  where`). Two feasible builds: (a) a hand-written recursive generator over the `Ast` types, or (b)
  seed from the accepted corpus (`example/` + `tests/`) and apply random *structure-preserving*
  edits via `mutate.ml`. Prefer (b) first — it reuses infra and stays closer to real programs.
- **In-process, not subprocess:** call `Compile.check_module` directly (as `test_s7_generative`
  does) so a crash is an OCaml exception you can catch and attribute, not a lost exit code.
- **Shrinking:** on a crash, delta-debug the AST to a minimal reproducer before reporting.
- **Gotcha:** any generated program written to disk must have a filename matching its `module`
  header (kebab/Pascal) or a `V001` file-name check masks the real behaviour — the in-process path
  sidesteps this; keep it in-process.

## Sub-part 2 — metamorphic invariance property

Pick transformations that a correct checker's verdict must be **invariant** under, and assert the
accept/reject verdict is unchanged before/after. No known-good oracle needed — any verdict *change*
is a defect. Relations to implement (each a property test over the accepted + rejected corpora):

- **Wrap an accepted `ok`/return value in a semantics-preserving context** and assert still accepted:
  `Something <v>` (Maybe), a single-field constructor, an identity operation, an
  identity passthrough call. (`transaction {}` also preserve meaning but need a
  DB context/capabilities — include them only for programs that already have one, to avoid
  introducing new obligations that would legitimately change the verdict.)
- **α-rename** a bound variable to a fresh non-colliding name → verdict invariant (respect host-wide
  no-shadowing: rename to a genuinely-unused name).
- **Reorder independent `let` bindings** / **insert an unused `let`** → verdict invariant.
- **Inverse direction:** apply the same preserving wraps to a **rejected** program and assert it is
  **still rejected** (a wrap must not launder an unsound program into acceptance).

A verdict flip in EITHER direction is a checker inconsistency (exactly the class where a proof is
accepted bare but not under a wrapper, or vice versa). Reuse `mutate.ml` for the rewrites and
`Compile.check_module` for the verdict.

## Sub-part 3 — runtime proof-witness differential oracle (the erasure backstop)

> **DECLINED (2026-07-03, maintainer).** Do NOT build this and do NOT reintroduce proof
> information at runtime. Proof erasure is intentional and load-bearing (§4.3, zero-cost); a
> retain-mode lowering that re-checks `P(v)` at run time reverses that decision. Metamorphic
> testing's purpose here is only to confirm that **behaviour is unchanged** under
> semantics-preserving rewrites (the checker's verdict is invariant; the runtime still works /
> tests still pass) — NOT to re-derive erased proofs. Sub-parts 1 + 2 deliver that. The text below
> is retained only as the record of the rejected option.

Because proofs are erased on the standard (zero-cost) path, nothing at runtime re-checks a
predicate the checker assumed. Add a **test-only** retain-mode lowering: at each site where an erased
proof `P(v)` would be assumed, evaluate `P` against the *actual runtime value* `v` and assert it
holds — a differential between "the checker asserted `P(v)`" and "`P(v)` is true at run time". Run it
as a gated test target (like the existing integration suites), never on the default zero-cost path.

- This is a **second lowering path** (retain vs erase) — a real architectural lift, and the reason
  this sub-part is L and re-opens the S8/G7 decision. Scope it after 1–2, and confirm the
  keep-a-runtime-net direction is wanted before building it (the project deliberately erases; §4.3).
- Lower-cost stepping stone: an in-memory-shim **HTTP behavioural** oracle (assert observable
  status/body on capability-denied and proof-boundary paths) — the one check class erasure cannot
  hide — before a full per-predicate retain-mode.

## Verification (prove the harness is load-bearing)

- Fuzzer + metamorphic suites run in the gate (`./ci.sh`), in-process, fast, deterministic seeds
  (no `Date.now`/random in fixtures; seed by index).
- **Load-bearing check:** temporarily reintroduce one already-fixed forgery (e.g. drop the A3
  `check_fact_name_distinctness` guard, or the A2 OR fail-closed) and confirm the metamorphic
  property and/or fuzzer *catches* it (a verdict flip / crash) — then revert. A harness that stays
  green with a known bug reintroduced is not load-bearing.
- Any coverage bound (generator depth, N iterations, shrink budget) must be `log()`-ed, not silently
  capped, so "green" cannot read as "explored everything".
