# Optimization sweep

> **Status:** Next · **Effort:** mixed (S/M/L per workstream)
>
> **Progress — 6 of 7 shipped (WS1–WS6); WS7 → `later/` (the only deferred item):**
> - ✅ **WS1 Measurement harness** — phase timing landed (`compile.ml` + `compile-examples.sh`).
> - ✅ **WS2 Parallelize CI loops** — `xargs -P` over `fmt`/`validate` in `compile-examples.sh` (~2.4x validate, ~1.7x fmt; deterministic output + exit status preserved).
> - ✅ **WS3 Parallel compiler build** — done; `compiler/ci.sh` builds `-j $(nproc)` (B-FAST).
> - ✅ **WS4 Batch / whole-project mode** — `--check-batch` / `--check-all` + an import-parse
>   cache; ~3.4x on the 67-file corpus. *Finding: the stdlib was never re-parsed per run (it
>   is a static OCaml env); the real redundancy was process-spawn + local-import parsing.*
> - ✅ **WS5 Mutation speed** — parallel mutant pool (~4x; score byte-identical to serial) + DB-test stubbing. *Note: the
>   separate mutation **correctness** bug (false survivors) was fixed — see
>   `roadmap/completed/fix_mutation_bug.md`.*
> - ✅ **WS6 Startup / distribution** — measured (warm bytecode ~8-10x; `raco exe` ~0.63s
>   standalone; `raco demod` **fails at runtime** — `define-runtime-path` breaks demod, avoid
>   for now). Added a `tesl --exe` path. Recommendation: ship precompiled bytecode + `--exe`.
> - ➡️ **WS7 Incremental validation cache** — moved to `roadmap/later/incremental-validation-cache.md`.

## Why now

Tesl is alpha, and the thing that compounds in alpha is iteration speed. Two loops
matter:

- **The user's inner loop** — edit a `.tesl` file, run `tesl validate`/`tesl test`,
  read the result. Today every invocation pays a fresh OCaml process start *and* a
  Racket cold start.
- **The language's CI loop** — `compile-examples.sh` is the gate that keeps the whole
  example/test corpus honest, and it currently runs almost everything serially.

Neither is broken; both are slower than they need to be. This item is a deliberate
sweep: measure first, take the cheap wins, then decide whether the larger bets (startup
distribution, incremental caching) are worth it. The goal is a faster, more delightful
loop without trading away any correctness guarantees.

## Goals & success criteria

- **Faster inner loop** — `tesl validate <file>` / `tesl test <file>` feel snappy on a
  warm machine.
- **Faster CI** — `compile-examples.sh` wall-clock drops materially on a multi-core box,
  driven by parallelism rather than doing less work.
- **Faster startup** — a decision (and ideally first step) on shipping compiled programs
  that start faster than a Racket source cold start.
- **Faster mutation runs** — mutation testing scales to more targets than just
  `lesson42` without blowing the timeout budget.
- **No correctness regression** — the full test suite and mutation score are unchanged
  after every optimization. Speed must never come from skipping checks.

## Current state

Grounded in the current pipeline (line numbers approximate, treat as anchors):

- **CI pipeline — `compile-examples.sh`.** Four largely-serial phases: `tesl fmt` over
  all files (≈445-451) → `tesl validate` per file (≈469-475) → tesl test blocks via
  `tests/example-test-batch.rkt` (≈522) → `raco test tests/all.rkt` aggregate (≈579).
  The per-file `fmt` and `validate` loops spawn one `tesl` process per file. The shared
  PostgreSQL cluster is started asynchronously while phases 1-2 run, but is guarded by a
  60s `timeout` that can stall on WSL2 (≈187, 555). `raco make` precompiles test `.rkt`
  to bytecode first (≈316-332).
- **Compilation — OCaml frontend.** `compiler/ci.sh` builds with `dune build -j 1`
  (serial, ≈26). Per file, `compile.ml::compile_source` (≈2039) runs parse
  (`parser.ml`) → type check (`checker.ml`) → proof check (`proof_checker.ml`) → ~30
  validation passes (`validation.ml` + `validation_*.ml`) → emit (`emit_racket.ml`).
  Each file is compiled by a fresh `tesl` process; there is no cross-file or incremental
  caching, so the stdlib is re-parsed for every file.
- **Startup.** The compiler emits a `.rkt` file that runs via `racket`; `raco make`
  produces `.zo` bytecode. There is **no `raco exe` standalone executable** path today,
  so every run pays Racket cold-start plus DSL module loading.
- **Mutation testing.** `compile.ml::mutate_file` (≈2375-2443) drives `mutate.ml`. It
  generates mutants of `check`/`auth`/`establish` functions and, for **each mutant**,
  shells out to a new `raco test` process (≈2414-2435) with a 15s per-mutant timeout
  (`TESL_MUTATE_TIMEOUT`). Mutants run one at a time. In `compile-examples.sh` this is
  wired only for `example/learn/lesson42-mutation-testing.tesl`, capped at 120s
  (`TESL_MUTATION_TIMEOUT`, ≈531-576).

Prior art: `roadmap/completed/00-reduce-test-time.md` already took a first pass at test
time; this item continues that work across more axes.

## Workstreams

### 1. Measurement harness — S (do first)
- **Problem:** we are guessing at bottlenecks. Optimizing without numbers risks effort
  on the wrong phase.
- **Approach:** add opt-in phase timing to the compiler (parse / typecheck / proof /
  validation / emit) behind an env flag, and a per-phase wall-clock summary at the end
  of `compile-examples.sh`.
- **Anchors:** `compile.ml::compile_source` (≈2039), `compile-examples.sh`.
- **Payoff:** every later workstream becomes data-driven; we keep a before/after number.

### 2. Parallelize CI loops — S
- **Problem:** the per-file `fmt` and `validate` loops are serial, but each file is
  independent.
- **Approach:** drive them with bounded parallelism (e.g. `xargs -P "$(nproc)"`), keeping
  deterministic, collated output so failures are still readable.
- **Anchors:** `compile-examples.sh` ≈445-475.
- **Payoff:** near-linear speedup of the two longest CI phases on multi-core machines.

### 3. Parallel compiler build — S
- **Problem:** `compiler/ci.sh` forces `dune build -j 1`.
- **Approach:** let dune use all cores (drop `-j 1` or set `-j "$(nproc)"`), confirming
  the serial constraint isn't hiding a real ordering dependency.
- **Anchors:** `compiler/ci.sh` ≈26.
- **Payoff:** faster cold builds for contributors and CI.

### 4. Cut per-file process-spawn overhead — M
- **Problem:** validating N files spawns N `tesl` processes, each re-parsing the stdlib.
- **Approach:** a batch / whole-project mode that validates many files in a single
  invocation, parsing and type-checking the stdlib once and reusing it across files.
- **Anchors:** `compile.ml` (entry/CLI), `checker.ml` (stdlib env construction).
- **Payoff:** removes redundant startup and stdlib work; compounds with workstream 2.

### 5. Mutation speed — M
- **Problem:** mutants run serially, one `raco test` process each, and DB-touching tests
  inflate per-mutant cost. This keeps mutation testing pinned to a single lesson file.
- **Approach:** run mutants in parallel with a bounded pool; reuse a warm Racket process
  / precompiled deps instead of a cold `raco test` per mutant; skip or stub DB-touching
  tests inside mutant runs.
- **Anchors:** `compile.ml` ≈2414-2435, `mutate.ml`.
- **Payoff:** mutation testing becomes cheap enough to run across more than one target.

### 6. Startup / distribution — M–L
- **Problem:** programs start via Racket source/bytecode with full cold-start cost; no
  standalone artifact.
- **Approach:** evaluate `raco exe` / demodularized bytecode (`raco demod`) for shipping
  faster-starting programs; decide what the distributable artifact should be.
- **Anchors:** `emit_racket.ml` (module requires), `roadmap/later/language_distribution.md`.
- **Payoff:** faster program startup and a real distribution story; feeds the
  distribution roadmap item.

### 7. Incremental validation cache — L (candidate for `later/`)
- **Problem:** unchanged modules are fully re-validated on every run.
- **Approach:** content-hash modules and skip parse/typecheck/validation for inputs whose
  hash (and dependency hashes) are unchanged.
- **Anchors:** `compile.ml`, `validation.ml`.
- **Payoff:** large speedup on warm repeated runs — but needs a sound invalidation story
  first, so it is the last and most cautious bet.

## Sequencing

1 (measure) → then the quick wins 2 and 3 → then the medium structural wins 4 and 5 →
then the larger bets 6 and 7, gated on what the measurements from step 1 justify.

## Open questions

- Standalone binary (`raco exe`) vs distributing precompiled bytecode — which is the
  artifact we want to support? (See `roadmap/later/language_distribution.md`.)
- How aggressively can PG-backed tests be parallelized given the shared-cluster /
  per-test-database model before contention erases the win?
- For workstream 7, what is the minimal sound cache-invalidation key (file hash +
  transitive import hashes + compiler version)?

## Out of scope (for this item)

- **Runtime proof-struct allocation cost** — owned by
  `roadmap/next/actually-zero-cost-runtime-proofs.md`. This item is about toolchain and
  test/build speed, not the per-call cost of proof-carrying values. Cross-link, don't
  duplicate.
