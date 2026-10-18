# Migration delivery status

> Audience: contributors reviewing the migration PR and its release evidence.

The [scoped traceability register](migration-pr-scope.md) links the 18 agreed PR
clauses to live production declarations, named witnesses and execution routes.
Full staged uniqueness remains required and pending. Bounded empty-queue removal
is integrated and technically accepted with merged execution evidence below.
Static consistency is not executed acceptance: a successful complete CI run is
still required. Historical-roadmap reconciliation is reported separately.

Last passing full-gate baseline: `1ddc8a6` (2026-10-14). Earlier baseline: `84ef00d`.
Requirements were committed in `b5cddb9`;
additive catch-up was committed in `137ddd1`, row-transforming catch-up in
`4f6e86e`, queue catch-up in `085bf00`, and ordered composition in `99b869f`.
Automatic deployment wiring and its targeted verification are recorded below.

## Latest PR scope and verification (2026-10-18)

The full-gate attempt on `943a73d` stopped at phase 4 in 3,093 seconds: the first
three phases passed, Dune failed, and phases 5–24 were not reached. The failures
were an obsolete cache-constructor emission assertion and one Go indentation
error in the embedded stage runtime. Both are corrected. The two durable-store
emission cases and all five affected PostgreSQL emission cases passed in a
targeted private-cluster rerun. Evidence: `.tesl-stuff/pr-increment-ci.log` and
`.tesl-stuff/pr-increment-ci-fix-tests.log`. This targeted rerun is not a full-gate
pass; a complete rerun remains required.

These maintainer decisions supersede narrower scope statements in the historical
sections below:

- Required: three-release staged uniqueness with a preparatory nonunique index,
  indexed per-key promotion guards and reviewed promotion; fenced empty-queue
  removal; safe unrelated-table Drop beside unchanged queues; Worker-topology
  cache, email and SSE support; and complete scoped requirement/code/test links.
- Required performance gate: measured base-versus-candidate latency regression,
  with noise calibration. Absolute 1% read / 5% write p99 overhead acceptance is
  not the chosen merge criterion; report absolute overhead separately.
- The 10M/100M data sweep is deferred until after merge. The reservation-table
  uniqueness subsystem is also deferred; it is distinct from required staged
  promotion. Queue identity rename and simultaneous row/payload transformations
  remain unsupported; the ordered row-first/payload-second route is accepted.

The latest complete CI invocation on `9852f26` **failed**, with 23/24 phases
passing in 6,536 seconds. Its migration kernel reached the final Worker lesson
after 1,792 seconds, then hit the 1,800-second package timeout eight seconds into
that test. The focused Worker-lesson retry passed in 45.81 seconds. The shared
package budget is now 2,400 seconds; individual scenario deadlines are unchanged.
This correction still needs a complete rerun. The remaining migration-runner
phases were not reached after the kernel failure, so this is not a migration-gate
pass. Evidence: `.tesl-stuff/pr-scope-baseline-ci.log` and
`.tesl-stuff/pr-scope-worker-recheck.log`.

Commit `61c0732` connects the three durable facilities through a single Installer
transaction and exact catalog/privilege checks. Its 16 new PostgreSQL tests passed
with the race detector (80.573 seconds); existing facility/cache/outbox/pubsub
regressions passed (8.957 seconds). Compiler build, targeted emission tests,
emitted PostgreSQL runtime compilation, `go vet`, and documentation integrity
also passed. See [combined facility verification](../runtime/go/teslrt/MIGRATION_FACILITIES.md).
These results do not establish a full CI pass or interoperability with archived
pre-extension binaries.

Safe unrelated-table Drop now permits unchanged queues, comparing full historical
membership and payload/proof/codec contracts. Current application imports cannot
retain access to dropped entities through historical schemas or transitive helpers.
After integration with the durable facilities, all 16 compiler planning cases passed
and the PostgreSQL application suite passed in 111 seconds. These scenarios
cover old-claim refusal, surviving claims, restamped retained jobs, delayed-job
consumption and source-contract tampering. The embedded-runtime seam passed six
tests; generated snapshots were refreshed. Logs:
`/tmp/opencode/safe-drop-integrated-{compiler,postgres,embedded}.log`.

The full migration runner now includes a pinned baseline/candidate latency gate.
Its standalone run at `.tesl-stuff/latency-cli-only-20261018` passed A/A noise
calibration, all correctness checks and all four p50/p95 comparisons. Baseline
read/write p50 was 0.936/1.656ms; candidate was 0.925/1.636ms. The comparator
rejected a deliberate +3ms change to recorded candidate samples. Two earlier
calibration failures are retained and documented; sample size and compiler-build
scope were corrected without widening thresholds. See
[latency policy and evidence](../scripts/MIGRATION-LATENCY.md). This establishes
neither absolute migration overhead nor hosted-runner reliability.

On top of compiler groundwork `4f03e6f`, **bounded V8 Stage/Carry preparation is
connected to the real original-V1 PostgreSQL execution path**. It builds NONUNIQUE
indexes and records immutable pending obligations. It does not implement the full
three-release uniqueness protocol: no V9 writer guard, unique-index promotion or
V10 reliance is enabled. Reviewed promotion and cancellation remain refused;
deleting the source declaration cannot silently cancel an installed obligation.

The supported slice is an additive history, introducing a new preparatory index
on an existing table/key after V1, then carrying its exact descriptor forward.
Bool and Int32 with integer/bigint storage, optionally nullable, are supported.
Stage-on-birth/V1, reuse of an existing index name, changing a carried preparatory
descriptor, histories containing row transformations/queue conversion/Drop, String
C/POSIX collation and UUID/bytes mappings remain explicitly unsupported. Existing
stage-free facilities and safe Drop retain their previous checks and behavior.
Source carry-age checking still defaults to three revisions; runtime configuration
of that limit is not implemented.

`postgres-storage-v2` and `tesl-retained-physical-version-v8` carry the complete
typed semantic descriptor and stage ID, not only an index name or digest. The
runtime compares source and physical descriptors and reconstructs field dependency
reachability, including private check/establish producers and codec reverse edges.
Ordinary stage-free source/physical encodings retain their existing formats.

**Catalog compatibility is explicit.** Every fresh original-V1 installation built
by this toolchain installs the required `tesl_schema_stage_protocol` format-1 row
and `tesl_schema_stages` table alongside row format5, even before a stage is
declared. This lets predecessor and staging binaries built by this toolchain
coexist. Tables, constraints, function bodies, owners and ACLs are checked exactly.
Pre-extension development catalogs missing that extension are refused, not adopted
or upgraded implicitly. Compatibility with archived pre-extension binaries is not
claimed.

Stage registration shares the nonunique index job/receipt transaction. Each
pending row retains the full descriptor, its checksum, introduction version,
physical-plan hash, actual creator ABI, source snapshot, table/index and job ID.
Observation derives that complete expected tuple from protected physical manifests
and committed jobs; carry/restart/reinstall do not rewrite it to the latest version
or ABI. Existing concurrent-index jobs and lease tokens own building/recovery.
The stage stays `pending` even after its linked index job becomes `valid`: neither
state grants uniqueness, `onConflict` eligibility or Memory enforcement.

The registration SQL itself now authorizes the descriptor before inserting it:
an owner-only bounded canonical parser extracts the actual migration document,
its v8 physical body and that body's ninth-child stage inventory. Only an exact
immediate child of that inventory is eligible. The full descriptor bytes and its
ID/table/index/key column are bound to the protected plan and nonunique job;
the job receipt, object hash, expansion hash and creator ABI must also agree.
Physical/job rows are held with share locks through registration. Atom contents,
nested lists and other physical fields cannot supply descriptor authority.
Parsing is bounded to 64 MiB, 1,000,000 nodes and 512 edges of nesting, with exact
framing and no trailing bytes. The independent Go source/physical/record checks
remain in place; later observation is not the mutation-boundary authorization.

Worker-direct regression calls start with an empty stage table so uniqueness or
replay constraints cannot mask authorization failures. Fake IDs, mutated and
coherently rehashed descriptors, cross-stage/index/job bindings, and wrong job
columns fail without inserting a row. Synthetic protected plans with coherent
hash/job linkage exercise embedded-atom, nested-list and wrong-position attacks.
Legitimate registration and exact replay reconstruct the original records. These
checks run in the mandatory native preparation suite; evidence for this boundary
review is in `/tmp/opencode/stage-boundary/`.

Mandatory routes: `test_staged_indexes` includes actual Go Memory execution;
`test_migration_row_indexes` now also compiles predecessor/staging/carry programs
and executes the PostgreSQL/race stage-preparation suite. The full migration runner
already invokes both executables without selecting out either native scenario.
The preparation implementation is embedded only for PostgreSQL artifacts; the
isolated experimental V9 guard is still not integrated.

Targeted evidence is in `/tmp/opencode/stage-preparation/`: the native stage
scenarios verify duplicate writes, valid NONUNIQUE indexes, predecessor read/write
compatibility, immutable carry/restart/reinstall, finite catch-up, interrupted-build
lease recovery, and rejection of validly framed descriptor drift, source/ABI drift,
catalog/ACL drift, missing extension and attempted unreviewed Contract. Compiler
checks also reject promotion and source deletion after generating fresh seals.
Staged compiler/Memory (9), inventory (14), storage (11), safe-Drop planning (16),
embedded seam (6), the original index application scenario, and 20 top-level
baseline/facility/dependency runtime tests passed; the latter ran with `-race` and
required private PostgreSQL. `go vet` and `staticcheck` passed (an existing
capitalized facility-error message was lowercased without changing its ACL check).
These are targeted results, not a
full CI or latency-gate pass.

**Remaining V9/V10 work:** indexed per-key guards on every relevant write path,
reviewed `PromoteStage`, predecessor writer fencing before concurrent UNIQUE build,
protected cancellation, duplicate reporting/repair/retry and promotion recovery,
and V10 readiness tied to durable enforcement plus a valid/ready/live unique index.
The pending-only stage-control extension must be evolved explicitly for those
transitions. Full-roadmap traceability reconciliation also remains open; the
bounded empty-queue removal increment is documented separately below.

## Bounded empty-queue removal integration (2026-10-18)

The reviewed `RemoveEmpty` source decision is integrated with compiler history,
physical format v9, Installer staging, Worker/Contract/deploy/catch-up execution,
protected SQL mutation and immutable receipt verification. See
[empty queue removal](../manual/queue-removal.md) for the exact source surface and
protocol. This supports one whole-queue removal edge in an additive history,
including additive prefixes and later additive successors. It does not enable
row-transforming or queue-converting prefixes/suffixes, staged-index histories,
Drop/reset composition, mixed removal edges, rename/move, partial job removal,
multiple removals or retired-identity reuse.

The receipt binds the real database UUID/fence, selected removal version,
predecessor/target physical hashes, closed endpoint inventories, complete earlier
physical/source-inventory prefix and actual compiler ABI. Every admitted older
writer and representation fence is required before checking retained jobs.
Pending, delayed, dead, quarantined, claimed and expired-claimed removed jobs
block publication. Surviving jobs retain payloads and scheduling; their audit
records retain actual old versions. Receipt, membership, restamps and floors
publish atomically. Later replay does not lower newer floors or rewrite newer
claims. An original-V1 protocol marker is required; older development catalogs
are refused rather than adopted.

`compiler/test/test_migration_queue_removal.ml#reviewed_source_scope`, `#native`
and `#native_chain` are real registered source/native witnesses selected by the
mandatory compiler loop. They compile V1/V2 and V1→additive V2→RemoveEmpty V3→
additive V4 applications, remove the source projects, and run PostgreSQL/race
scenarios for nonempty refusal, both fence domains, producer/claim races,
survivors, source/version/ABI tampering, crashes, later replay and deployment.
The isolated fixtures and relevant Contract/queue/history/Stage/facility/Drop
regressions passed. On merged root, four source checks and both real compiled
PostgreSQL/race fixture suites passed in **465.176 seconds**, including the
original-marker refusal, all nonempty categories, independently missing writer
and representation fences, old-producer post-wait rejection, missing claim
authority, unchanged survivors and V4 claim/floor-preserving replay. The dependency
shell was pinned to root `66c22b2`; generated runtime/docs and ABI snapshots are
regenerated normally rather than copied from the isolated worktree. Evidence:
`/tmp/opencode/queue-removal-merged-verification/merged-removal.log` and its
`fixtures/adjacent/postgres.log` and `fixtures/chain/postgres.log`.

This code/test review and merged execution establish technical acceptance for the
documented bounded support: `PR-EMPTY-QUEUE` is evidenced, with no additional
human approval flag. The static validator requires concrete source, staging,
execution and protected-mutation links plus registered source and both compiled
native witnesses; a status flip backed by the old emptiness helper cannot pass.
`PR-UNIQUE` remains pending because Stage/Carry does not provide the full three-release
uniqueness protocol. No full CI pass or universal history support is claimed.

## Delivery contract

The implemented surface supports **original-V1, fresh-install PostgreSQL histories**
with checked row transformations and restricted Worker-topology queue histories.
**Baseline `1ddc8a6` passed the complete local authoritative gate: 24/24 phases,
no skips, exit 0, including all 49 migration phases in that same invocation.**
This covers additive, transforming, queue and ordered catch-up, the finite
deployment job, and gated rollout wiring. Hosted supported-major results and
the separate pinned performance requirements remain open. This document does not waive the
[normative roadmap's requirements](../roadmap/next/database-migrations.md#target-mechanisms-after-phase-4-authoritative-summary).

The maintainer explicitly accepted fresh-catalog-first development. Missing or
incompatible installed objects must refuse, rather than be adopted or supplied
with invented history. In-place upgrades of older development catalogs are outside
this delivery contract. Other missing roadmap requirements remain open work.

## Clarified release requirements (maintainer, 2026-10-12)

| Requirement | Release decision and present state |
|---|---|
| CI preview | Required workflow, already available through compiler-owned non-mutating `tesl migrate generate app.tesl --manifest-json`. Editor preview is sufficient; applying edits inside the editor is not a merge blocker. |
| Automatic production migration | Required and included in the passing local full gate. `app --schema deploy` installs/stages as Installer, closes that connection, catches up as Worker and completes reviewed target finality. A Compose rollout stops old services and gates new service startup on the finite job's successful exit. No manual per-version commands or intermediate images are needed. |
| Catch-up from any earlier supported schema version | Required. A deployment targeting Vn must advance a valid database at Vk through every missing checked step without intermediate application deployments. Additive, row-transforming, queue-only and the tested ordered row-first / queue-second history now execute with the latest artifact. |
| Ordered row/queue changes | Two ordered migrations are acceptable. The row-first / queue-payload-second sequence is now implemented and tested with retained jobs, repair and restart. `MIG028` names the conflicting entities/payloads and prescribes the tested split/order and commands. Simultaneous row and payload changes remain refused and are not required for this release. |
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

## Additive catch-up continuation

The configured schema Worker now walks a wholly additive missing suffix in
version order. It preflights that suffix before advancing its first missing step,
selects each exact compiler-linked plan, and preserves the actual application's
owner, declared version, ABI and complete source history. It never fabricates an
older application identity. Each edge has its own bounded execution budget under
the Worker's cancelable service lifetime.

Known additive physical history is compared with retained compiled source, so a
genuine alternative V2 with a different default cannot be silently adopted by V4.
An unfinished historical edge also retains its creator-ABI restriction. Historical
queue descriptors contain creator-linked callback identities, so they continue to
use their existing source/retirement verification rather than byte equality with
a newer compiler's recompiled descriptor. The actual A/B/C compiler witnesses
verify that compatible new-edge queue and row upgrades still work.

Verified public-application scenarios:

- V1/V2/V3 databases advanced by the V4 Worker; old V1 reads/writes remain valid,
  intermediate defaults and database UUID survive, and replay preserves receipts.
- Fresh setup using only the latest additive artifact still records/executes V1
  through V4, rather than inventing a V4 installation origin.
- Process death after an intermediate receipt or publication resumes correctly.
- Conflicting retained source and a consistent foreign-ABI unfinished step refuse
  before later publication; a transforming gap does not partially advance V2.
- Concurrent V3/V4 Workers serialize through the existing boot fence and record
  each revision once.
- V3 catches up V1 while building both intermediate/final index jobs; readiness
  remains blocked until required indexes are valid.

Evidence: `.tesl-stuff/catchup-additive-red.log` reproduces the old predecessor
refusal. `catchup-row-regressions.log` passes the extended additive application
suite (198.856s), additive-tail, new-table and index suites. The stronger index
catch-up/readiness witness passes in `catchup-index-readiness.log` (72.096s).
`catchup-compiler-compat-verified.log` passes both real cross-compiler witnesses
(435.468s). The final additive rerun, retaining both actual-current and historical
execution ABI checks, passes in `catchup-additive-final.log` (200.037s).
Runtime/model race tests and vet/staticcheck/lint/gosec/Nilaway pass in
`catchup-runtime-analysis-final.log`.

## Row-transforming catch-up continuation

The newest application's `--schema catch-up [--database Module.Database] [--json]`
is a finite Worker-topology deployment command. It reconstructs each historical
execution window from the sealed owner, preserving the real binary's declared
version, ABI and complete history. One boot-locked coordinator runs retained
expansion, finite index completion, required additive epoch closure and reviewed
intermediate Contracts. Typed historical backfill uses the original checked
codecs/callbacks and normal lease ownership, budgets, receipts and fences.

Recent incompatible instances refuse before advancement, with stop/wait/rerun
instructions; retirement rechecks under its actual fences. Catch-up never forces
retirement. Finite index actors use the historical execution admission but do not
register as historical application instances. All retained indexes must be valid
before proceeding, even if some do not gate request readiness.

The final version is expanded and index-ready; its own Contract is not required
to report `schema-caught-up`. Installation remains an Installer command, and the
latest ordinary Worker owns ongoing backfill. Queue-conversion gaps were still
refused by this row-only increment; the continuation below supplies that path.
Ordered composition and production deployment wiring were still outstanding at
that increment; their continuations are recorded below.

Verified evidence (logs under `.tesl-stuff/`):

- `catchup-transforming-scenarios.log`: ordinary adjacent V1–V4 rollout plus V4-only
  catch-up from V1/V2/V3, Retype/WriteBack, Legacy removal, proof Revalidate, live
  instance refusal, rejected-data repair and immutable-receipt replay.
- `catchup-transforming-native.log`: concurrent-index suite (128.167s), including
  finite historical index execution; full Retype/WriteBack suite (296.311s), with
  crashes after expansion receipt, retirement, Contract receipt and publication.
- `catchup-transforming-concurrent.log`: repeated-Retype/restart rerun (163.417s),
  including competing latest coordinators serialized through the boot fence.
- `catchup-transforming-analysis.log`: additive suite (246.221s), including latest
  bootstrap and historical unforced epoch closure; runtime race tests (35.667s).
  A subsequent command used an incorrect model package path; the corrected run is
  `catchup-transforming-static.log`: migrationtest race tests (12.576s), vet,
  staticcheck, golangci-lint and Nilaway pass.
- `catchup-transforming-compiler-compat.log`: real cross-compiler row and queue
  upgrade witnesses pass (462.736s).
- `catchup-transforming-cancellation.log`: final index suite (106.719s) also
  proves cancellation cannot report `schema-caught-up` with unfinished jobs;
  runtime race tests (35.896s), vet and gosec pass.
- `catchup-transforming-doc-sync.log`: snapshots, traceability, document integrity
  and manual coherence pass.

These are targeted results, not a new full authoritative CI pass.

## Queue catch-up continuation

The newest application's Installer stages all retained queue-only edges and
explicitly linked repair lineages. Future proposals bind the real database UUID,
fence namespace, exact predecessor hash, payload contracts and checked source
identity. They do not create a published predecessor, grant dispatch or advance
admission. Activation retains the existing adjacent-predecessor and retirement
checks. Staging remains bounded to 32 source lineages per transaction, and retry
can only reuse the same immutable records. Completed older edges remain read-only
observations, including when a compatible compiler creates new successor edges.

`--schema catch-up` preflights all required staged targets and executable repair
code, executes each queue edge using transaction-bound attempts, and completes
its protected queue Contract. Unlike the final row window, the final queue edge
is retired before success: merely finding no selectable jobs cannot establish
finality. Live claims, recent retiring instances and unresolved rejected/invalid
payloads block progress with repair/drain instructions. There is no Worker direct
access to the private job table and no implicit discard or forced retirement.

The queue example now covers latest-only installation/catch-up from fresh and
V1/V2/V3 databases, historical repair, missing executable repair refusal, exact
receipt replay, real claim/heartbeat expiry, and process death after staging,
conversion and retirement. Existing adjacent rollout and incompatible-compiler
refusals remain covered. The embedded runtime dependency list now explicitly
includes `migration_row_catchup.go`, so editing that file invalidates the compiler
snapshot; all six seam tests pass.

Evidence under `.tesl-stuff/`:

- `queue-catchup-restart.log`: complete ordinary adjacent rollout and all latest-
  binary bootstrap, gap, repair, replay and three process-death scenarios pass.
- `queue-catchup-compiler-compat.log`: actual A/B/C compiler witness (472.498s),
  including latest catch-up after A's completed V2 and real claim/heartbeat guards.
  `queue-catchup-compiler-final.log` reruns it with the missing-repair preflight
  witness and adjacent-source staging verifier (471.019s).
- `queue-catchup-regressions.log` / `queue-catchup-regressions-final.log`: 58 queue
  source/fixture cases; the obsolete fresh-V2 refusal assertion was replaced with
  retained-origin and no-unpublished-admission checks, then the PostgreSQL case
  passed (112.796s). Repeated row catch-up/restart (143.648s) and index/cancellation
  suite (70.389s) also pass.
- `queue-catchup-static.log` / `queue-catchup-static-final.log`: runtime and
  migrationtest race tests (34.533s / 11.588s), vet, staticcheck, golangci-lint,
  gosec and Nilaway pass after retaining the adjacent staging verifier.
- `queue-catchup-final.log`: final ordinary rollout, all gap/repair/claim/heartbeat
  and process-death scenarios, and six embedded-runtime seam checks pass after
  giving each staging group its own bounded budget under the cancelable Installer
  lifetime.
- `queue-catchup-final-analysis.log`: final runtime/migrationtest race tests
  (34.350s / 11.569s), vet, staticcheck, golangci-lint, gosec and Nilaway pass.

Ordered composition was still missing from the queue-only increment; the
continuations below supply that path and production deployment wiring. Their
complete local acceptance is recorded below.

## Ordered row/queue continuation

The compiler now accepts retained row transformations alongside queues when each
row-transforming edge preserves exact queue membership and payload contracts.
Payload-changing edges still require unchanged entities. A queue edge immediately
after a row transform carries an explicit checked row-Contract prerequisite in
the retained physical descriptor; Installer staging and Worker activation bind
the settled predecessor, while the queue inventory retains its actual original
expansion hash. Neither source identity nor database version is fabricated.

Row Contract retirement now verifies unchanged payload contracts, fences old
writers, checks live claims/quarantine/conversion attempts, and atomically
restamps retained jobs with the row retirement receipt and admission floor.
The audit records original payload hashes and claim sequences. An expired old
claim is released; a surviving current-version claim retains its identity.
Queue-only retirement does not select a nonexistent row-cleanup Contract for
ordinary entity reads. Additive epoch closure after completed row/queue edges
uses their exact retirement receipts and compares only the admitted payload tail.

`scripts/test-ordered-row-queue.py` is a new phase in the shared migration gate.
It builds public V1–V4 artifacts from guarded compiler previews and exercises:

- V1 → row Retype/WriteBack V2 → queue payload V3 with only the latest binary.
- Catch-up from already settled V2; an additive V4 tail and epoch closure.
- Rejected row repair without advancing queue stamps or the admission floor.
- Live old queue claims, late V1 row inserts and queue enqueue during overlap.
- Process death after expansion, before the retirement transaction commits, and
  after it commits; exact receipt replay and retained values survive.
- Altered restamp audit refusal and actual latest typed row reads/queue handling.
- A combined-change preview reporting `MIG028`, both conflicting names, the
  required split/order and actionable source/deployment commands.

Targeted evidence under `.tesl-stuff/`: `ordered-overlap-final.log` passes the
ordered scenarios and diagnostic; `ordered-regressions.log` passes the full
Retype/WriteBack suite (272.955s) and additive suite (202.215s);
`ordered-queue-table-index.log` passes 58 queue source cases (346.811s), table Drop
(61.807s) and index/cancellation (71.691s). `ordered-compiler-compat.log` passes the
actual row and queue A/B/C compiler witnesses (697.379s).
`ordered-analysis-final.log` passes runtime/migrationtest race tests
(34.769s / 11.623s), vet, staticcheck, golangci-lint, gosec and Nilaway.

This remains the original-V1 owned protocol: changed protected definitions do not
adopt older development catalogs. Queue membership removal/rename, queue-bearing
table Drop and simultaneous row/payload transformations remain outside this
supported sequence. These targeted results are not a fresh full CI pass.

## Automatic deployment continuation

`app --schema deploy [--database Module.Database] [--json]` is a finite,
Worker-topology deployment operation. It takes a separate Installer connection
from `TESL_SCHEMA_INSTALLER_DSN` and the configured Worker `ddlConnection`.
Before installation, the Worker verifies a live Installer backend tag/PID in its
own database; equal database names alone do not establish identity. Existing
role-isolation checks remain mandatory. The Installer closes after installation
and bounded staging, before any data conversion executes. Worker execution pins
the installed UUID, fence, format and origin across phase boundaries.

The job executes retained catch-up and the reviewed final row Contract for a
transforming target. Missing final Contract source refuses before database
mutation. Queue targets likewise complete retirement. Known recent-instance and
live-claim blockers wait within `TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS` (default 600);
data rejection, invalid payloads, execution failures and source/catalog problems
fail the job. Cancellation and timeout cannot produce `schema-deployed` success.
Ordinary application startup remains inert with respect to the Installer variable.

`templates/docker/compose.worker.yml.example` scopes credentials separately for
the migration job, schema Worker and Request service. `deploy-worker.sh` validates
configuration, pulls the immutable image, stops old services, runs the job, and
starts the new services only after a successful exit. The same image executes all
retained versions. The shared migration gate includes real Compose configuration
validation and executable rollout exit-status tests; this phase requires the
Docker Compose client, not a running Docker daemon.

Evidence under `.tesl-stuff/`:

- `deploy-verified.log`: public compiled fresh/adjacent/gap deployment, final row
  cleanup, rejection/repair, claim/heartbeat waiting, deadline refusal, separate
  database refusal, missing Contract refusal, Installer closure and restart pass;
  real Compose configuration and rollout failure gating pass.
- `deploy-complete-scenarios.log`: all ordered catch-up regressions plus deployment
  scenarios pass, including queue-Contract waiting for a V2 claim.
- `deploy-analysis-final.log`: runtime/migrationtest race tests (34.623s / 11.583s),
  vet, staticcheck, golangci-lint, gosec and Nilaway pass. The parser now makes its
  empty-argument guard explicit for the ordinary-startup credential-inertness test.

These targeted results are now supplemented by the complete authoritative run
recorded in the acceptance section below.

## Implemented behavior and its evidence

### Combined installation and rolling Worker startup

`app --schema worker --install` accepts the existing two connection inputs:
`TESL_SCHEMA_INSTALLER_DSN` and the configured Worker `ddlConnection`. It checks
both connections reach the same database, installs/stages with the Installer,
closes that connection, and passes only the Worker connection/configuration and
verified database identity into the long-running Worker. The consumed Installer
variable is removed from the current Go environment; this is not secure erasure
of startup credentials or a separate-process security boundary.

The current schema window stays open for rolling application overlap. The
Kubernetes example uses this command instead of a pre-upgrade Installer Job;
its post-upgrade cleanup Job remains. `AGENTS.md` now uses this discussion as an
example of concrete language about tables, permissions, commands and processes.

Targeted verification: `.tesl-stuff/worker-install-native.log` verifies separate
connections, closed Installer sessions before Worker readiness, restricted
Worker table privileges, restart and unchanged deployment behavior.
`worker-install-analysis.log` passes runtime/migrationtest race tests, vet,
staticcheck, lint, gosec and Nilaway. The actual kind/Helm/OpenTofu run in
`worker-install-kube.log` records 731 successful samples, zero failed samples,
at least two Ready application pods, both version overlaps, 81 queue conversions
and 121 correct job results. These new changes have targeted evidence; the full
gate baseline recorded above predates this combined-command increment.

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
| Broader composition | The tested ordered row-first / payload-second sequence is implemented. Simultaneous row/payload changes and queue-bearing table Drop remain refused. Queue membership removal/rename and general `IgnoreOld` remain unsupported. |
| Other durable facilities | Worker migration topology refuses durable caches, email outboxes and SSE facilities; Embedded topology refuses versioned queues. |
| Operator workflow | Public application verbs are `status`, `install`, `deploy`, `worker`, `catch-up`, `contract`, `close-epoch`. Automatic deployment and ordered catch-up pass the full local gate. Other operator conveniences above remain roadmap work without blocking this release. `close-epoch --dry-run` is not the general data dry-run. |
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

### Complete deployment/catch-up gate (`1ddc8a6`)

One uninterrupted `./ci.sh` invocation completed in **15,716s (4h 21m 56s)**:
**24/24 phases OK, no skips, `READINESS_CI_EXIT_CODE=0`**. The working tree was
clean at completion. Evidence: `.tesl-stuff/deploy-ci-release.log` and
`.tesl-stuff/deploy-ci-release-migrations/phases.tsv`.

| Gate | Result from this invocation |
|---|---|
| Compiler and agent surface | Full Dune/OCaml suite passed (2,350s); protocol contracts, diagnostics/tooling, embedded-source checks and snapshots passed. |
| Complete migration runner | **49/49 phases passed**: kernel 1,669s; ordered row/queue and deployment scenarios 464s; deployment wiring 1s; review 05 361s; review 11 592s; V1–V20 2,625s. |
| Adversarial and retained-data evidence | 127 review-05 and 117 review-11 cases; 58 compiler queue-source cases; V1–V20/95 PostgreSQL API cases; fresh/adjacent/gap deployments, finality, repair, drain, interruption and typed Request handling. |
| Runtime and analysis | Normal/race tests, fuzz targets, vet, staticcheck, golangci-lint, gosec, govulncheck and Nilaway all passed. |
| Distribution and integration | Recursive corpus, CLI smoke/portability, clean installation, browser parity, OpenAPI DAST and SSO browser E2E all passed. |

The earlier attempts remain failures, not acceptance evidence. They found stale
assertions for newly supported row/queue emission, unchanged-payload retirement,
and future staging, plus brittle embedded-document checks. The corrected tests
retain refusal/unchanged-state assertions for malformed targets, premature
publication, admission and retirement. Queue-bearing row Contract guards now
reject invalid targets explicitly, and the V1 inventory query uses a guarded
`CASE` instead of evaluating an absent predecessor. Fixes are committed in
`2e1ab64`, `4881f71` and `1ddc8a6`.

Only this evidence document and related status wording are updated after the
passing run; build/documentation integrity checks are rerun for those updates.
Hosted PostgreSQL-major matrix results and pinned release-scale performance
evidence remain separate requirements.

### Earlier readiness baseline (`84ef00d`)

The following rows and readiness-fix history describe the earlier baseline.

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
5. Preserve the deployment, catch-up and ordered row/queue witnesses as the release
   regression contract. Keep other operator/editor items as nonblocking follow-up;
   completing this release still does not close every original roadmap item.
