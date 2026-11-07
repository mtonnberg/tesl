# Migration compilation and model CI performance

> Audience: contributors reviewing migration performance and regression coverage.

Base: `ad3dd99`, after PR #117 merged. Branch: `perf/migration-ci-wave3`.

## Model job setup

The PR's model job exhausted its ten-minute budget while Nix built unrelated Go
linters, MailHog and Nuclei. It had not reached TLC. The job now uses
`nix develop .#migration-models`, a `mkShellNoCC` shell containing TLC (including
its Java runtime), Bash, coreutils, grep and sed. It has no development-shell
compiler build or PostgreSQL startup hook.

The workflow triggers, model script, exhaustive state spaces, required mutation
counterexamples, job timeout and individual model deadlines are unchanged.
Local setup plus all model checks completed in 16.2 seconds. This machine already
had most dependencies; comparing that with the hosted timeout is not a controlled
cold-run speedup measurement. Hosted cold-run timing remains required.

## Repeated schema checking

Profiling V20 emission found 13,876 semantic inventory loads. One instrumented run
spent 204 CPU seconds inside inventory loading out of roughly 311 CPU seconds
overall. Hashing accounted for only 13.7 CPU seconds; replacing the hash function
would not address the main repeated work. Profiling instrumentation was removed.

`Migration_inventory.with_cache` now scopes immutable successful inventories to
one source-history capture, including nested work. The cache is discarded on
normal return and exception. It retains at most 128 entries, with a 32 MiB
serialized key/value weight budget; this is not an exact OCaml heap-size limit.

Every lookup still resolves and parses the schema import closure and checks
module ownership and physical member storage. Keys contain the compiler ABI,
stored-value compatibility label, root path, exact schema source paths/bytes,
and actual resolved lifted-stdlib paths/bytes. Neither mtimes nor an ABI label
alone authorizes reuse. Before returning a hit, source bytes are checked again.
Stdlib inputs are rechecked on hits and before storing a computed result. Errors
are not cached. Existing whole-compilation source/ABI guards still run.

## Measurements

Component command (from `compiler/`, with `TESL_REPO_ROOT` set):

```sh
dune exec test/bench_migration_inventory.exe -- /path/to/v20/schema/tracker/v-current.tesl 500
```

It alternates uncached/cached/cached/uncached loads and checks inventory equality.
Local results were 5.960s, 0.306s, 0.300s and 5.918s: approximately **19–20×** for
repeated inventory loading, including the initial cache miss.

Independent baseline/candidate compilers emitted the same frozen V20 application
in alternating order:

| Run | Baseline seconds | Candidate seconds | Ratio |
|---|---:|---:|---:|
| First pair | 260.03 | 119.69 | 2.17× |
| Second pair | 317.84 | 113.24 | 2.81× |

These are local whole-emission observations, not a 10× whole-CI or database
throughput claim. All emitted files matched after substituting the compiler build
ABI and its explicitly verified transform-contract bytes/hashes. Contract SHA-256
values were recomputed, and decoded contracts differed only in the ABI string;
arbitrary hashes were not masked. Other emitted code and contracts matched.

Local raw data: `/tmp/nix-shell.E25jrS/opencode/wave3-emission-results.json` and
`wave3-emission-{before,after}-{1,2}/`. These temporary files are local evidence,
not durable hosted artifacts.

## Test value and real workloads

No existing CI phase, test assertion, model mutation, release, workload size or
latency threshold was removed or weakened. Added regressions warm the cache before
editing source, retain the same ABI for changed-interface checks, and cover
malformed source, invalid proof/type declarations, private dependencies, overlays,
actual stdlib-byte changes, eviction, and cleanup after exceptions.

The full V1–V20 scenario rebuilt the hash-verified original frozen source releases
with the candidate and passed on PostgreSQL with 1,000 additional tasks created
through HTTP. It retained pure conversion fixtures, API tests, old/new application
overlap, retained cohorts, finality and restart checks. Logs and build records are
under `/tmp/nix-shell.E25jrS/opencode/wave3-twenty/`.

This is compilation-work reuse, not cached test results: application tests still
execute against real PostgreSQL. Full hosted CI and cold model-job timing remain
separate verification requirements.
