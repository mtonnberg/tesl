# Staged uniqueness: PostgreSQL major verification

The connected, bounded staging/guard/Contract/recovery/cancellation/reliance
implementation was exercised on PostgreSQL **14.23, 17.10 and 18.4** using fresh
private clusters and the same actual compiled race-enabled fixtures. This is
technical evidence for the scoped `PR-UNIQUE` requirement, not a full CI pass or
acceptance of arbitrary key types or history compositions.

## Tools and setup

- Checkout base: `53d335d0f799d4ac810fadf9db0703523769329b`, with the uncommitted
  connected lifecycle changes. No compiler or runtime implementation changed
  during this major verification; subsequent edits concern documentation and
  static traceability checks.
- Pinned nixpkgs revision from `flake.lock`:
  `e73de5be04e0eff4190a1432b946d469c794e7b4`.
- Packages: `postgresql_14`, the root development shell's `postgresql_17`, and
  `postgresql_18`. Both client tools and servers used the selected major.
- Go `go1.26.9 linux/amd64`; Dune `3.21.1`; PostgreSQL packages built with clang
  `21.1.8` on x86_64 Linux.
- `CI=1`, `TESL_SKIP_AUTO_BUILD=1`, `GOMAXPROCS=2`, `GOFLAGS=-p=2`, Nix
  `--max-jobs 1 --cores 2`; all heavy phases ran sequentially.
- UTF-8 private clusters initialized with libc C, data under repository
  `.tesl-stuff`, Unix sockets under `/tmp/opencode`, no TCP listener, and
  `max_connections=40`. Each major used a new cluster.
- `TESL_MIGRATION_TEST_REQUIRE_POSTGRES=1` and the matching
  `TESL_MIGRATION_TEST_POSTGRES_MAJOR` were set. JSON test output was checked for
  nonempty execution, package success and **zero skipped Go tests**.

The public compiler harness exported ordinary index, preparation, guarded
V1/V2/V3/reviewed-V3/V4, and cancellation/successor binaries once. These were
reused unchanged across majors. Build metadata confirms `-race=true` and
`-tags=tesl_migration_test`; binary SHA-256 identities are retained with the logs.

## Measured subsets

Elapsed seconds below are Go package test times, excluding fixture compilation
and cluster setup. Every cell passed.

| Selected subset | PG14.23 | PG17.10 | PG18.4 |
|---|---:|---:|---:|
| Writer context, text-domain checks and negative index-probe witnesses | 4.589 | 4.219 | 5.122 |
| Actual compiled original index workers and recovery | 62.991 | 58.894 | 75.213 |
| Stage preparation, text equality/locales and protected registration | 72.053 | 68.377 | 96.315 |
| Guard, reviewed authority, concurrent UNIQUE builds, repair/recovery, V4, catch-up and deployment | 490.952 | 476.691 | 571.618 |
| Failed/unbuilt preparation cancellation, crash recovery and successors | 79.791 | 76.692 | 101.189 |
| **Selected total** | **710.376** | **684.873** | **849.457** |

Each run executed the same selected top-level set and its subtests. In particular,
these are real compiled applications and PostgreSQL/race executions, not merely
metadata fixtures. The preparation suite also creates C, POSIX, C.UTF-8 and
en_US.UTF-8 databases: C/POSIX requests were accepted and the non-C requests were
refused on every tested major. PostgreSQL/libc may canonicalize requested POSIX
to C; an additional PG14 investigation observed exactly that. No artificial
catalog modification was used to claim a distinct POSIX runtime configuration.

## Commands and retained evidence

The toolchain selection follows `.github/workflows/migration-protocol.yml`:

```sh
nixpkgs_rev="$(jq -r '.nodes.nixpkgs.locked.rev' flake.lock)"
nix build --max-jobs 1 --cores 2 --no-link --print-out-paths \
  "github:NixOS/nixpkgs/$nixpkgs_rev#postgresql_14^out"
nix build --max-jobs 1 --cores 2 --no-link --print-out-paths \
  "github:NixOS/nixpkgs/$nixpkgs_rev#postgresql_18^out"
```

Inside the root Nix development shell, the matching package's `bin` was placed
first on PATH. Fixture export used the registered compiler harness and its
`TESL_ROW_INDEX_EXPORT`, `TESL_STAGE_PREPARATION_EXPORT`,
`TESL_STAGE_GUARD_EXPORT` and `TESL_STAGE_CANCELLATION_EXPORT` modes. The normal CI
route clears these export-only variables and executes all registered scenarios.

Each runtime phase used this command shape, with its recorded budget and selector:

```sh
go -C runtime/go test -p 2 -race -count=1 -timeout=BUDGET \
  -tags=tesl_migration_test ./teslrt -run PATTERN -json
```

Selectors were `^(TestPgWriterContext|TestStageText|TestPgStageProbePlan)`,
`^TestPgRowIndex`, `^TestPgStagePreparation`, `^TestPgStageGuard` and
`^TestPgStageCancel`. Budgets were respectively 180s, 240s, 240s, 900s and 300s.
The lifecycle run also fits the registered compiler harness's 600s package budget.

Local evidence root: `/tmp/opencode/stage-major-verification/`.

- PG14: `pg14.tANfzHXi/`
- PG17: `pg17.5BH6oZ42/`
- PG18: `pg18.PwyglMQo/`
- Shared fixtures: `programs/`; export logs: `build-*.log`.
- `toolchain.log`, `binary-sha256.txt`, `binary-build-settings.txt`.
- Each major directory retains `versions.log`, `commands.log`, package JSONL
  events, summaries, init/shutdown logs and the PostgreSQL log.
- Reproduction helper retained at `/tmp/opencode/run-stage-major-matrix.sh`;
  JSON event auditing at `/tmp/opencode/summarize-stage-major.py`.

No runtime/compiler compatibility bug was found and no checks or constructor
typing rules were weakened. The evidence collector initially queried
`lc_collate`/`lc_ctype` as GUCs, which PG18 no longer exposes; it was corrected to
read `pg_database` before the successful PG18 run. That preflight failure is not
counted as a passing test run.

## Acceptance boundary

`PR-UNIQUE` is now `evidenced` for the existing key domain. Its static validator
requires concrete source/context/guard/protected-Contract/index/recovery/
cancellation/reliance implementations, the actual compiled fixture routes, race
execution, mandatory PostgreSQL and matching-major matrix wiring. Negative tests
reject deletion or substitution of those links, reordered handoff, helper-only
evidence, metadata-only replacements and export-only test bypasses.

Static `release_ready` concerns scoped trace links only. The report deliberately
retains `execution_verified=false` and `full_ci_required=true`; historical roadmap
reconciliation remains separate. The complete repository CI gate was not run.

The bounded domain remains Bool, Int32 with int4/int8 storage, and builtin TEXT
under the checked libc C/POSIX equality, optionally nullable. Arbitrary numeric
`Int`, native UUID/bytea mappings, custom equality/collations/opclasses, composite
staged keys and NULLS NOT DISTINCT remain explicitly refused; native UUID/bytea
language/storage mappings are not implemented. Unsafe nonleading/covering
index paths are refused. The history-composition and retirement restrictions in
[the lifecycle scope](stage-lifecycle.md) remain explicit; this evidence does not
claim universal migration-history support.
