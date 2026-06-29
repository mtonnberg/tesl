# `.rkt` snapshot regeneration sweep (committed artifacts are stale)

Status: ✅ COMPLETE. The blocking emit regression (below) was fixed — the EOk
`check`-strip bug in emit_racket.ml (a surface `check …` in an `ok`/`attach-proof`
tail emitted an unbound `(check …)` head) now strips to `(attach-proof ((check-and …) n) p)`,
verified by 2 new emit tests (test_emit.ml "eok-proof"). With that fixed, the drifted
snapshots were regenerated (24 genuinely-changed `.rkt`, all raco-expand clean) and the
full example batch is green (113/113 Format/Compile/Lint/Tesl-tests). Snapshot
regeneration is now part of the normal workflow after any emit change.

## Context

The committed `example/**/*.rkt` and `tests/**/*.rkt` are byte-exact compiler-output
**snapshots** that `tests/example-test-batch.rkt` `dynamic-require`s (it does NOT
recompile the `.tesl`). They have **drifted** from the current compiler's emit:

- codec emit: `tesl-codec-decode-field` / `tesl-json-string-codec` →
  `tesl-decode-prim-field` / `tesl-decode-prim-string` (new fns live in
  `dsl/types.rkt`).
- proof representation / checkpoint emit (`thsl-src!` → `thsl-src-control!`, more
  checkpoints).

They currently pass only because the runtime still provides the old entry points
(backward-compat). **When the old safety net / old runtime entry points are removed
(near-horizon), every un-regenerated snapshot breaks.** So a full regen is needed
before that removal.

## Why the naive sweep was backed out

Regenerating all 98 snapshot `.rkt` (via `main.exe <file>.tesl > <file>.rkt`) hit two
problems:

1. **Stdlib shims are NOT plain snapshots.** `tesl/list.rkt`, `tesl/either.rkt`,
   `tesl/list-prim.rkt` are hand-written shims that re-export the `*-derived.rkt`
   snapshots, yet they have a sibling `.tesl`. Regenerating them as compiler output
   clobbers the shim (e.g. `tesl/list.rkt: only-in: ListPrim.head not included`).
   → The sweep must EXCLUDE `tesl/` (stdlib infra is regenerated only via
   `scripts/gen-stdlib-rkt.sh`, which knows the shim/derived split).

2. **A real current-compiler emit regression.** Regenerating
   `tests/adversarial-review-tests.rkt` produces `(check (check-and checkPositive
   checkSmall) n)` with **`check` unbound** — the current compiler drops the require
   that binds `check` (the committed snapshot has `(require … tesl/dsl/check …)`).
   This is an emit bug in the committed compiler (HEAD), exposed by regen. It must be
   fixed in the compiler before the sweep can complete, or those constructs will
   emit broken code once snapshots are refreshed.

## Plan

1. Fix the `check`/`check-and` require-emission bug in the compiler (investigate why
   the `tesl/dsl/check` require is dropped for `ForAll (P && Q)` / `check (check-and
   …)` constructs).
2. Sweep regen scope = `example/**` + `tests/**` snapshots ONLY (exclude `tesl/`).
3. `tesl/` stdlib: regenerate `*-derived.rkt` only via `scripts/gen-stdlib-rkt.sh`
   (already current as of this work); never regenerate the shims.
4. Re-run compile-examples; every snapshot test must pass under the current emit.

## Orphaned stale hand-written tests block `raco setup` / `install-linked-tesl!`

`tests/tesl-test.rkt:install-linked-tesl!` runs `raco pkg install --auto --link <repo
root>`, so `raco setup` compiles **every** `.rkt` in the repo, including stale,
**orphaned** hand-written tests that are not run by any suite (`tests/internal-all.rkt`
does not load them) and reference runtime identifiers that were renamed long ago:

- `tests/cache-test.rkt`  → `cache_FreshCache: unbound identifier`
- `tests/email-test.rkt`  → `email-spec?: unbound identifier`
- `tests/debug-test.rkt`  → (stale)
- `tests/email-tests.rkt` (generated snapshot) → stale (skipped by the batch; no test
  submodule), but still recompiled by `raco setup`.

These only "passed" because their **cached `.zo`** (compiled when their source still
matched the runtime) was never invalidated — `raco` doesn't recompile when source mtime
is unchanged. A `compiled/` purge (or a fresh CI checkout) forces a recompile and they
fail, which makes `raco setup` exit non-zero → `install-linked-tesl!` raises →
`tesl-test` errors → `compile-examples`'s aggregate suite fails. So this is latent
pre-existing breakage, masked in any warm-cache environment.

Options: (a) update the three orphaned tests to the current runtime API, (b) delete them
if superseded, or (c) add a `compile-omit-paths` info.rkt so `raco setup` skips dead
test scripts. (a)/(b) are the real cleanup and pair with the snapshot regen above.

## Done so far (kept, verified)

- `tests/critical-review-28-tests.rkt` — regenerated (its stale snapshot carried old
  proof code; `checkShort28` now passes).
- `example/learn/lesson33-sse-and-queue-tests.rkt` — regenerated (carries the
  `_queue_for_<Job>` desugar fix; passes).
- `tesl/list-derived.rkt`, `tesl/either-derived.rkt` — regenerated via the gen script
  (committed copies were stale; `--check` now passes).
- The `_queue_for` desugar fix itself (`desugar.ml:queue_job_types`) is committed-safe
  and on the new typed-config path.
