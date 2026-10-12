# Migration delivery status

> Audience: contributors reviewing the migration PR and its release evidence.

Assessment: 2026-10-12. Verified implementation: `84ef00d`; release requirements
were clarified subsequently below.

## Delivery contract

The implemented surface supports **original-V1, fresh-install PostgreSQL histories**
with checked row transformations and restricted Worker-topology queue histories.
**Local authoritative acceptance is green: 24/24 phases, no skips, exit 0.**
Those results establish the implemented surface. The maintainer's clarified
release requirements below still require deployment automation, catch-up and
ordered row/queue composition before release acceptance. Hosted supported-major
checks also remain open. This document does not waive the
[normative roadmap's requirements](../roadmap/next/database-migrations.md#target-mechanisms-after-phase-4-authoritative-summary).

The maintainer explicitly accepted fresh-catalog-first development. Missing or
incompatible installed objects must refuse, rather than be adopted or supplied
with invented history. In-place upgrades of older development catalogs are outside
this delivery contract. Other missing roadmap requirements remain open work.

## Clarified release requirements (maintainer, 2026-10-12)

| Requirement | Release decision and present state |
|---|---|
| CI preview | Required workflow, already available through compiler-owned non-mutating `tesl migrate generate app.tesl --manifest-json`. Editor preview is sufficient; applying edits inside the editor is not a merge blocker. |
| Automatic production migration | Required. Deploying checked migration history must drive the necessary installation/staging, expansion, backfill/conversion and reviewed retirement steps without manual per-version schema commands. The configured schema Worker already performs supported next-step expansion and backfill; the complete deployment coordinator is not implemented. |
| Catch-up from any earlier supported schema version | Required. A deployment targeting Vn must advance a valid database at Vk through every missing checked step, whether one or many versions behind, without requiring operators to deploy each intermediate application binary. Current runtime expansion/queue staging is adjacent-edge execution, not general catch-up. |
| Ordered row/queue changes | Two ordered migrations are acceptable. Simultaneous non-additive row and queue-payload changes in one edge are not required. The ordered sequence must actually work, with a friendly diagnostic explaining conflicting changes, the required split/order and the next commands. Today the retained-history guard still refuses transforming row history in a queue-bearing database, even across separate releases; supporting that sequence remains required work. |
| Other operator/editor conveniences | Dedicated offline application, pruning, rebase/repair scaffolding, grant/deployment-recipe generation, extra quarantine/pause tooling and editor apply are not merge blockers for this release. Named automatic Contract modes are an implementation choice; executing necessary reviewed Contracts automatically is part of the deployment/catch-up requirement. |

**What catch-up must prove.** Keep the exact recorded history and run missing
transitions in order, including required intermediate Contracts and epoch closures.
Resume interrupted work from durable state and immutable receipts. A single new
deployment must be able to consume two separately authored row/queue migration
steps; splitting the source must not force an operator to ship intermediate images.
The final catalog, rows, queue payloads and admission state must match the supported
one-version-at-a-time path. This extends upgrades within the owned protocol; it
does not invent absent history or adopt incompatible old development catalogs.

**Automatic execution still observes compatibility.** Installer and Worker
authority remain separate from Request authority. Incompatible old writers and
claimants must be excluded/drained before their representations are retired; a
version gap is not permission to bypass those fences. Readiness waits when needed.
Multi-version catch-up may therefore require a drained interval; uninterrupted
traffic across incompatible skipped versions is not established by this requirement.
Failed proofs or conversion remain explicit, actionable blockers consumed by the
authored repair/discard policy, rather than implicit data loss.

Acceptance witnesses must include a one-step production deployment, V1-to-latest
and intermediate-to-latest catch-up containing both additive and transforming
steps, restart from partial progress, and two ordered row/queue changes with
retained jobs. The combined-change diagnostic must prescribe that tested sequence.
The already passing adjacent-deployment examples alone do not establish these gates.

## Implemented behavior and its evidence

| Area | Delivered surface | Main evidence / review entry point |
|---|---|---|
| Source history | Guarded generation/refresh, frozen nominal schemas/codecs, verified `Same`, typed row/queue functions and fixtures, source-bound Contract previews | [Implementation ledger](migrations-implementation.md), compiler migration suites |
| Row lifecycle | Additive and repeated transforming releases, old/new overlap, reverse writes, rejection/repair, explicit Contract and additive epoch closure | [V1–V20 project tracker](../example/db-twenty-releases/README.md): four tables and 95 PostgreSQL-backed Tesl API tests |
| Queue lifecycle | Consecutive changed-payload edges with retained membership and unchanged stored entities; claims, conversion, repair, unchanged-payload restamping and retirement | [V1–V4 queue application](../example/queue-three-upgrades/README.md), compiler queue application/transform suites |
| Recovery | Business rejection repair; source-bound `on: "execution-failed"` corrected conversion; `on: "unconverted"` explicit audited discard, including malformed original bytes | [Queue remediation](../manual/queue-remediation.md), review 11 cases 97–111 |
| Authority | Installer/Worker/Request separation, exact catalog checks, immutable history, transaction-bound attempts, original-byte comparison and actual retirement fences | Review 05/11 adversarial suites, runtime race tests |
| Queue scale | First conversion for every type in a 257-type, 1,280-job reference workload: 24.535s and 24.549s; enqueue approximately 45s separately | [Performance report](queue-admission-performance.md), measurements tied to binary/compiler hashes |

Recovery and discard are implemented through `QueueRepair`. The separate
[`QueueRecovery` proposal](../roadmap/later/queue-execution-recovery.md) is
superseded design context, not a deferred recovery blocker. A discard revision is
an explicit data-loss policy for the named type and edge; it is not general
`IgnoreOld` membership removal or a decoder for malformed bytes.

The performance result measures progress after Worker readiness, not backlog
drain or end-to-end deployment. Its sub-half-second margin and two ordinary-build
samples are not a production SLA or evidence for the separate p99 admission gate.

## Roadmap requirements still open

| Requirement | Current boundary |
|---|---|
| Ordered row/queue applications | Non-additive row transformations alongside versioned queues refuse, including retained history from separate releases. The required first delivery may use two ordered migrations with actionable diagnostics; unrestricted simultaneous changes are not required. Queue membership removal/rename and general `IgnoreOld` remain unsupported. |
| Other durable facilities | Worker migration topology refuses durable caches, email outboxes and SSE facilities; Embedded topology refuses versioned queues. |
| Operator workflow | Public application verbs are `status`, `install`, `worker`, `contract`, `close-epoch`. Automatic deployment completion and general catch-up remain release blockers. Other operator conveniences above remain roadmap work without blocking this release. `close-epoch --dry-run` is not the general data dry-run. |
| Source/editor workflow | Native CLI has generation, plan, Contract and source-write recovery; non-mutating previews can run in CI. Editor apply and rebase/prune/repair scaffolding remain follow-up work, not merge blockers. |
| Staged uniqueness | The specified staging/promotion declaration and per-key promotion guard remain outstanding. Ordinary index execution does not establish that workflow. |
| Release-scale acceptance | Dedicated pinned read/write p99 measurements and the prescribed large-table/rolling-write workloads remain unfulfilled. The 1,000-extra-row experiment is not the 10M/100M-row gate. |
| Complete traceability | The current checked inventory explicitly lists uncovered normative scopes. Finite model checks and a green partial coverage map do not complete whole-feature correspondence. |

The recorded compiler-ABI/stored-value compatibility design and initial
materialisation policy are documented in the
[implementation decisions](migrations-implementation.md#implementation-decisions).
Retained historical lowerings are not the implemented execution model. Arbitrary
active-edge compiler substitution remains refused.

## Acceptance evidence

| Gate | Recorded state |
|---|---|
| Feature checks | Included in the final run: 117 review 11 + 127 review 05 cases, 58 compiler queue-source/PostgreSQL cases and runtime race/registration checks. |
| Model and documentation checks | Both finite models and all seven required mutation counterexamples pass; traceability, SQL-document classification, documentation and embedded-source sync pass. |
| Complete migration gate | `.tesl-stuff/readiness-ci-final-gate-migrations/phases.tsv`: all 47 phases pass uninterrupted on Go 1.26.9, including the final precondition fixes, 244 adversarial cases and V1–V20/95 PostgreSQL API cases. |
| Authoritative `./ci.sh` | `.tesl-stuff/readiness-ci-final-gate.log`: all 24 phases **OK**, no skips, `READINESS_CI_EXIT_CODE=0`, 12,489s (3h 28m 9s). Includes CLI smoke, 268-source corpus, fuzzing, static/security analysis, clean install, browser parity, DAST and SSO E2E. |
| Hosted supported-major matrix | Updated configuration requires the same complete runner on PostgreSQL 14/18 for PRs and 14–18 nightly. Fresh hosted results and timing evidence remain required. |
| Pinned performance environment | Outstanding; no local functional or queue timing result substitutes for it. |

### Readiness fixes and earlier attempts

The passing invocation above supersedes the failed attempts recorded here. The
only subsequent changes are documentation/comment updates and regenerated embedded
documentation; documentation integrity and build/sync are rechecked afterwards.

The first authoritative readiness run (`.tesl-stuff/readiness-ci.log`) exposed:

- CI's `--locale=C` cluster defaulted to SQL_ASCII, which pgx's simple protocol
  rejects. CI now explicitly initializes UTF-8, matching the migration runner.
- The historical compiled queue candidate fixture fed current row-companion
  history to the legacy format-4 installer. It now uses the current checked
  Installer/Worker/Request path, retains a negative legacy-candidate assertion and
  verifies Request cannot install; no history literal is rewritten to pass.
- The delete-deadline fixture applied its 400ms request budget to startup. It now
  uses the existing test-only post-startup arming hook; the locked DELETE still
  has the same 400ms budget and rollback assertions.

All three focused suites pass on private UTF-8 PostgreSQL (12.024s, 67.317s and
31.766s); `.tesl-stuff/readiness-failed-suites.log`. Those passes are diagnostic
follow-up, not a replacement for the complete authoritative retry.

The subsequent `.tesl-stuff/readiness-ci-retry.log` passed the complete compiler
suite. Native CLI tests now model a terminal without inheriting `CI=true` (the
separate CI-refusal test remains), query current linked row source inventory
without sidecars, and separate table Drop from index changes when exercising
supported plans. A combined Drop/index change still must refuse. The complete CLI
package passes after these corrections. Lesson 12 now obtains its single
cross-field `Fact` explicitly rather than passing a conjunction to that parameter;
its compiler diagnostics and executed tests pass. The lesson index and stale
lesson snapshots were regenerated.

Local debugger failures were overlong Unix socket paths under the disk-backed Go
temporary root; the unchanged tests pass with `GOTMPDIR=/tmp/opencode`.
`TESL_MIGRATION_TEST_DATA_TMPDIR` lets the runner keep database/release data on a
disk filesystem independently of short socket/test temporary paths. The embedded
sync gate compares against the Git index: stage the freshly generated embedded
file before a local acceptance run, so a further build-time change still fails.

The next broad run, `.tesl-stuff/readiness-ci-final.log`, completed the kernel in
1,319s and reached the row-access suite. A JSON-key rejection assertion raced the
parent's stderr-copy goroutine after receiving HTTP 500. It now waits on output
notifications with a bounded context, retaining the exact codec-message and
unchanged-state assertions; the focused PostgreSQL case passes.

The recursive corpus now accounts for all 268 tracked inputs, including the two
release recipes whose transition bodies require generated canonical paths and
frozen predecessors. Both recipes build every release and run their generated
tests rather than compiling raw transition templates out of context. The corpus
passes (`.tesl-stuff/readiness-corpus-assembled.log`), and stale snapshots were
regenerated. Browser checks now have a realpath primitive restricted to their
existing canonical in-memory source names; native filesystem guards are unchanged.
The browser-target build and pinned Terser build-only minifier retain the existing
2 MB ceiling: 1,992,421 bytes, with all search and lesson parity checks passing
(`.tesl-stuff/readiness-playground-final.log`).

The following uninterrupted migration run passed all 47 phases: kernel 1,292s,
review 05 346s, review 11 536s and V1–V20 2,365s. The full authoritative run then
exposed later static-analysis debt. A checked external-entrypoint inventory now
links private generated/test-bridge callbacks to actual producers without disabling
unused-code checks. Generation-to-smallint narrowing uses one checked positive
range conversion, including a regression for 65537 wrapping to 1. Indexed
inventory/projection lookups and tests now state their nonempty/ownership
preconditions locally; canceled cache-waiter ordering remains intact.

The existing Go-only overlay now pins 1.26.9 and its published source checksum;
1.26.6 was rejected by current standard-library advisories. Nilaway needs a 3 GiB
soft heap target on this host and now runs with that target in CI. Nilaway,
staticcheck, golangci-lint, gosec and govulncheck all pass together on Go 1.26.9
(`.tesl-stuff/readiness-analysis-verified.log`). The final combined invocation
includes those checks; preceding failed runs remain recorded as failures.

The final validation pass also separated short request deadlines from Retype
startup, gave the nominal-key lifecycle its own 90-second scenario budget, and
preserved its individual operation/progress bounds. The Go unit/race package
aggregate now has an explicit 1,800-second budget instead of the implicit ten
minutes; compiler tests stream progress under a two-hour aggregate bound. Early
CI cleanup now joins and stops its asynchronously started private PostgreSQL.

CLI smoke now fails immediately on manifest errors. Its example execution shares
the corpus runner's assembled-release and expected-diagnostic/repair handling,
covering all 187 tracked example inputs. Revalidation checks successful fixture
packages in standard Go test output rather than requiring a verbose `PASS` line.
The complete smoke passes (`.tesl-stuff/readiness-cli-smoke-verified.log`).

The worker-lifetime witness now uses a one-second artificial lease instead of
120ms, allowing a real protected PostgreSQL renewal round trip on shared runners.
It still proves renewal beyond the deadline observed at blocked persistence,
within the same three-second progress bound, and checks exact ownership and
shutdown ordering. Three isolated repetitions and the final aggregate run pass.

### Shared CI execution

Both authoritative CI and the supported-major workflow invoke
`scripts/run-migration-tests.sh` without selection arguments. That is the single
suite list, including the previous matrix-only candidate/runtime tests, current
queue/proof suites, both V1–V4 examples, both adversarial reviews and V1–V20.
Every matrix lane installs matching PostgreSQL tools before creating private
clusters. Pooler and scheduled crash/replica settings remain enabled in that lane.

The kernel and normal/race package aggregates use 1,800-second timeouts. The
scenario-specific adjustments above retain operation/progress assertions.
Compiler suite outer limits are 1,800 seconds; example
and adversarial phase limits are 3,600 seconds. A timeout is a failure. Hosted job
limits are 240 minutes for a migration lane and 360 for authoritative CI, which
also runs the compiler/corpus/integration gates. These are execution ceilings,
not measured completion promises; use retained phase timings to revisit them.

The runner prints its retained evidence directory. `TESL_MIGRATION_TEST_OUTPUT`
selects it explicitly. `phases.tsv` records elapsed seconds and exit status per
phase; phase logs and the private PostgreSQL log are retained. GitHub uploads them
even after a failure. Passing arguments selects only kernel tests and is a focused
check, never the complete gate.

## Review order and next acceptance steps

1. Read the [operator contract](../manual/migration-operations.md) and recovery
   policy, then the source/type boundaries in LANGUAGE-SPEC and the ledger.
2. Review authority and publication separately from pure conversion: catalog/ACLs,
   installed identity, claims/attempts, bytes, rollback, then Contract finality.
3. Read the actual rolling-release and antagonistic witnesses; retain their
   refusal/unchanged-state assertions when optimizing.
4. Preserve the passing authoritative gate and obtain hosted supported-major CI
   results. A failed prefix or isolated retry cannot replace a complete invocation.
5. Complete the clarified release requirements: automatic deployment, arbitrary
   version-gap catch-up and the supported ordered row/queue path with constructive
   diagnostics. Keep the other operator/editor items as nonblocking follow-up;
   completing this release still does not close every original roadmap item.
