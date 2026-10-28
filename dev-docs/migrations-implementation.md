# Migration implementation ledger

> Audience: contributors implementing, reviewing, and verifying schema migrations.

This ledger tracks the work in `roadmap/next/database-migrations.md`,
`queue-payload-migrations.md`, and `staged-uniqueness-guard.md`. The history file is
non-normative. An unchecked row is not delivered.

## Current assessment and implementation order

The [delivery status](migration-delivery-status.md) is the current roadmap-to-code
assessment and acceptance checklist. It records the V1–V20 row evidence, implemented
execution recovery/audited discard, 257-type performance result, shared CI runner
and remaining release gates. The readiness pass completed authoritative `./ci.sh`
with all 24 phases OK, no skips and exit 0; its complete migration runner passed
all 47 phases. Historical verification entries below retain their
original scope and do not establish a passing gate on the latest tree.

### Integration review and delivery target

The row migrations and unchanged-payload queue retirement have executable
PostgreSQL lifecycles. Checked queue converters and their pure byte adapters
also execute. The initial queue-only V1/V2 edge now compiles and runs through
ordinary installation/worker commands, including retained conversion, rejection,
separately compiled repair deployment and `--schema contract V2` retirement.
Repeated ordinary queue upgrades now execute through public commands; mixed
entity/queue histories remain incomplete.

The public-command regression now covers one ordinary V1/V2 queue application built from
frozen source, with no test-only metadata patches: enqueue an old-shaped job,
deploy its checked converter, claim/convert/process it with V2, reject another
job without losing its original bytes, repair that job through a separately
checked repair revision, and retire V1 only after finality. A separate runnable
example now exercises three consecutive ordinary queue deployments on one database.

Compatibility direction: prioritize a fresh-install ordinary-application rollout.
The maintainer accepts breaking the old control catalog rather than spending
substantial effort on in-place upgrades. Existing databases lacking required
catalog objects must fail inspection; do not silently adopt them or invent empty
history. A small compatibility fix is acceptable, but an upgrade project is not
on this path.

The required integration boundaries, in order, are:

1. Public checked `jobs:` coverage and generated adapter linkage for the exact
   database/family/queue/job edge; a shape change narrows the admission window.
2. Protected, immutable registration tying the conversion hash to both installed
   schema/payload contracts and the database identity. A pure adapter digest is
   not this authority.
3. An attempt-fenced apply operation that compares the original job identity,
   source version, payload and active conversion before publishing new bytes and
   their version together. Stale attempts, backend death and concurrent updates
   must not publish partial conversion or permit handler effects afterward.
4. Quarantine on checked rejection, preserving original bytes/version; typed
   repair revisions use new immutable identities rather than editing history.
5. Bounded finalization of pending, delayed, dead and processing jobs before the
   retirement floor commits. Then enable the public path and run the complete
   private-PostgreSQL gate.

The adapter review found a concrete gap: a freshly rehashed fixture closure could
omit the old payload definition while retaining its return signature. The new
regression failed on that omission before the fix. The runtime reader now
requires every fixture's complete, exact old-payload dependency set. Direct,
proof-bearing and optional generated fixture cases pass after the correction.
The evidence below records earlier milestones; it does not supersede these
remaining integration requirements.

### Implementation and verification evidence

After review-fix WIP commit `a125d9c`, compatible cross-compiler queue new-edge
rollout is verified by `TestCompiledQueueCompilerUpgradeRetainsPayloads`. Actual
A/B/C compilers are built from isolated source: B changes query implementation
only, C changes the declared stored-value contract. The first test reproduced
new-edge staging incorrectly pinned to the predecessor creator ABI. Staging now
consumes exact prior snapshots/physical identity/compatibility while pinning the
new edge to its compiler-linked executable ABI. All converters in an edge must
agree; immutable root/target registration still refuses active-edge substitution.
The A-frozen V1 → B-built V2–V4 public conversion/repair/retirement/completion run
passes. A separate probe denies B replacement of A's active V2 and permits B V3
after A retires V2; C refuses without changing installed data. The extended witness
passed in 283.350 seconds. Broader same-version substitution and scale/fairness
remain separate scope, not inferred from this result.

R05-01–R05-08 follow-up now has implemented fixes and 119 passing adversarial cases,
with no expected failures. Unchanged queued jobs are privately audited and
restamped during fenced non-additive retirement; old/surviving claims and rollback
have direct coverage. Generated migration callbacks share fuel/depth/cooperative
deadline budgets; actual tail/mutual recursion refuses without publication. Public
status reports bounded queue blocker codes/actions, repair revisions and recent
instances without exposing retained payloads. Relative overlay handling, stale
tests, lint coordination and executor cleanup identity are repaired. The complete
compiler suite passes. All mandatory migration phases passed across a completed
prefix and resumed tail after a user interruption; this is not described as an
uninterrupted full-gate invocation. Logs and exact dispositions are in the root
`db-migration-review-05-evidence.md`; the executive report is decision-oriented.

Review 05 starts from `3081667`; its assessment and execution inventory are
`db-migration-review-05.md` and `db-migration-review-05-exec.md` at the repository
root. It adds 107 adversarial cases: 106 pass, one explicitly expected failure
reproduces an unchanged delayed job blocking queue-only retirement beside a changed
payload. Shared SQL checking now enforces assignment/insertMany types and destination
field proofs, including sibling-proof invalidation and exact joint assignment
subjects. Lesson 96 was rewritten and linked runnable examples are now embedded
for installed help. The earlier full-gate pass below predates these review fixes:
the review's broad compiler run reproduced seven baseline failures plus a concurrent
linter collision, and its migration rerun observed an intermittent embedded-index
cleanup assertion (isolated retry passed). Do not report those runs as all green.

WIP commit `84782f8` records repeated public queue upgrades. The complete default
`scripts/run-migration-tests.sh` gate now passes on private PostgreSQL, including
the compiled V1–V13 Todo history, all 53 queue conversion/repair cases, all 24 queue
source cases, ordinary unchanged-payload queue deployment, row generation and
Contract suites, proof revalidation/Retype/removal, whole-table Drop, and both
ordinary V1–V4 example runners. The kernel/application package completed in
1240.993 seconds; the independently rerun complex Todo history passed in 468.624
seconds. The complete local log is `.tesl-stuff/full-migration-gate-active.log`.

An earlier complete attempt reached the package's existing 30-minute deadline;
the first isolated retry encountered a large overnight clock gap during compiler
emission. Neither attempt established a migration assertion failure. A subsequent
active-host isolated run and the full default gate both passed without changing
test deadlines or implementation. Earlier logs remain separate from the passing
log; a timeout is not counted as passing coverage.

After `e5cc6cb` (the mixed V1–V4 row-data example), the public queue protocol now
consumes consecutive unchanged-entity edges. The source planner and companion
reader bind every adjacent inventory to its physical descriptor. Source/target
staging, publication, conversion and retirement use the actual edge versions;
retirement receipts remain canonical and edge-scoped. Physical registration accepts
a non-additive queue predecessor only with its exact completed retirement, both
floors and retained physical hash. Installed history re-verifies all earlier
receipts and lineages, including after later retirement and job deletion.

`example/queue-three-upgrades/` builds seven standalone binaries through guarded
public source previews: original V1 and normal/repaired V2, V3 and V4. Its private
PostgreSQL runner passes three ordinary conversion → rejection → repair → Contract
cycles, late predecessor arrivals, unretired successor refusal, fresh rehashed
retirement substitution refusal, Contract replay and Worker restart. The retained
payload's numeric meaning advances 7 → 17 → 27, all six descriptors and three
retirement receipts remain, and the UUID/original receipt stay unchanged. The
ordinary V4 HTTP Request process executes its typed handler and acknowledges all
seven jobs; receipts survive completion. No candidate bridge or patched source
history grants execution. The default migration gate now includes this example
alongside the varied non-additive row-data example. Mixed entity/queue changes and
membership changes remain gated. The full default gate verification is recorded
above.

WIP commit `ba79df7` records the runnable ordinary three-release row example.
WIP commit `ef9c032` records the initial public queue V1/V2 conversion, repair
deployment and retirement integration. The ordinary row example has subsequently
been expanded to four releases and three distinct non-additive upgrades on one
database: V2 combines JSONB Retype/WriteBack with an author/owner Rename; V3 combines
another Retype with memo removal and an explicit Legacy default; V4 revalidates a
plain title into an AllowedTitle proof while retaining the exact V3 JSONB column
and a verified Same metadata/codec dependency. Its public-command runner verifies
rejection blocking both floors, admitted predecessor repair and writes, renamed
old inserts, legacy defaults on new inserts, physical cleanup, proof-producing
write refusal, Contract replay and Worker restart after each retirement. All four
source releases and generated race-test suites build; the private PostgreSQL
rollout passes. This expands row-data coverage; repeated public queue edges remain
the next integration milestone. The default migration gate already invokes this
example but has not been rerun in full for these changes.

The first public queued-payload scope now builds an ordinary V2 application for
one queue-only V1/V2 edge, unchanged entities and exact queue/job membership. The
captured graph retains original queue helper bindings; emission links its typed
adapter package into the actual application, and queue companion v2 carries exact
physical transition descriptors. Runtime companion validation checks the changed
inventories against those descriptors instead of accepting arbitrary changed
contracts or weakening the v1 companion's unchanged-payload rule.

The ordinary V2 install command verifies an already-expanded V1 installation and
stages the checked conversion/target using installer authority. It refuses a
missing/unexpanded predecessor before creating a replacement baseline. The normal
Worker command publishes the exact target and runs bounded compiler-bound turns
under Worker authority. A generated test builds real V1 and V2 application
binaries, deletes their sources, invokes their public install/worker commands,
and verifies a retained payload is converted while an old-valid rejected payload
remains at V1. A normal V2 Request application also starts and serves HTTP after
publication. There are no patched source-history literals or Main bypasses.

All 53 conversion/repair cases, 24 queue-source cases, affected queue/source/
baseline/physical runtime race suites, the existing public V1/V2 application
regression, compiler `@check`, embedding and runtime file gates pass. Mixed row/
queue transformations, membership changes on this narrowing edge and later
queue edges remain gated. Explicitly imported repair modules now link complete
typed lineages into ordinary V2 applications. The installer selects an unambiguous
executable lineage rooted in the exact physical decision and stages revisions;
the public Worker applies them. `--schema contract V2` checks the complete installed
history and recent retiring instances before and under the actual writer/compatibility
drain, then invokes atomic queue finality. The extended source-deleted regression
checks fresh V2 refusal, installation replay, staged-authority corruption, a separate
repaired deployment, rejection/recent-instance Contract refusal, retirement replay,
post-retirement restart and old enqueue refusal.
The complete default migration gate has not been rerun for this public hookup.

WIP commit `0a36c5b` records internal application queue retirement. A new runnable
ordinary row-data example now lives in `example/db-three-upgrades/`. It builds
V1/V2/V3 through public compiler APIs, freezes and refreshes sources using guarded
manifests, generates exact Contracts, runs generated Go tests and emits standalone
application binaries. Both upgrades replace a JSONB record's shape/codec through
typed Retype/WriteBack mappings; the application handlers are shared.

The example's private-PostgreSQL runner passed the complete ordinary lifecycle on
one database: V1 install/worker/HTTP seed, V2 expansion with rejection blocking
Contract, admitted predecessor repair, late V1 write, V2 Contract/floor/physical
cleanup, then the same non-additive lifecycle for V2/V3. It verifies exact retained
metadata and generated `metadata__v2`/`metadata__v3` columns. Source checks report no
errors/warnings, and all three generated release test suites pass with race
detection. The default migration gate now includes this runner. This is a working
public-command example of row migrations; queued-payload public rollout remains
the separate integration gap described above.

After WIP commit `1dc82cc`, the initial queue-only application edge now has a
protected retirement operation and independently verified durable receipt. It
drains both real V1 writer and compatibility-plan domains, locks application
state, checks the exact completed target and canonical source/repair lineage,
and refuses while old-stamped jobs, retiring claimants or transient conversion
attempts remain. On success it atomically records queue retirement and terminal
lifecycle slots and advances the real `min_version`/`compat_floor` to V2. No row
generation or destructive entity Contract is fabricated for unchanged entities.

Read-only observation verifies the queue receipt against the full installed
physical/source history and its complete lifecycle. Finality uses a protected
boolean SQL helper instead of reading raw job rows from Request authority. The
new database test reproduced that privacy-boundary error before the fix. The
per-entity finality reader now recognizes exact queue-only retirement while
retaining generation-one entity finality.

The ordinary-app PostgreSQL witness proves that pending jobs, quarantine and a
rejecting repair block retirement; a successful typed repair permits it even
with a live surviving V2 claimant. Replay is idempotent, retired V1 enqueue and
repair registration refuse, the worker turn becomes idle, and V2 lease renewal
and normal completion still succeed. The public V1 status binary can inspect
the retired history. All 53 conversion/repair cases pass with mandatory
PostgreSQL, plus affected runtime baseline/physical/queue/epoch race suites,
the public unchanged-payload application regression and embedding/build gates.

This is internal queue-only V1/V2 finality. Public changed-payload emission,
schema-worker/retirement command integration and operator recent-instance policy
remain pending; it is not a general mixed row/queue Contract or repeated ordinary
application rollout. Older catalogs are still refused rather than upgraded.
The full migration gate has not been rerun after these changes.

WIP commit `39c516b` records application-bound conversion/repair mutation and its
real version fences. A bounded application Worker turn now discovers staged
digests from the published target and resolves them through the compiler-bound
typed executable registry, instead of accepting adapter pointers from a caller.
The binding constructor registers only adapters whose nominal types and named
wrappers match the checked source descriptor. A staged digest without linked
executable code refuses before any job transaction runs.

The turn budget bounds total job transactions across migration and repair stages.
Committed receipts prevent hot-loop retries of the same rejection. PostgreSQL
tests use one-job turns to run the original rejection, a later rejecting repair,
and then the successful repair after reconnect; completed turns become idle.
Request logins and metadata-only callback entries are refused. All 53 compiler/
generated execution cases pass with PostgreSQL required, including the actual
application mutation and three-upgrade candidate tests, plus pipeline race tests,
compiler `@check`, runtime file gates and embedding checks.

This is the scheduling entry point, not its public integration. Ordinary
changed-payload app emission and selection of this turn by the schema-worker
service remain gated until the complete application retirement path is ready.
The full migration gate has not been rerun after these changes.

After WIP commit `cf06bca`, conversions and typed repairs now mutate jobs in the
ordinary application's real control/queue database through an internal Worker
dispatch boundary. It requires the exact completed V2 physical expansion,
registered target inventory, staged compiler source and real database UUID.
Each mutation takes the actual source-version retirement fence and rechecks target
queue admission; the isolated candidate's scope/floor tables are not installed or
used in the application. The tested selection/attempt/receipt code is shared.

Fresh application catalogs include private queue conversion receipt/attempt
tables, with independent read-only descriptors and no direct Worker/Request read
or write grants. Normal completion cleans up abandoned attempts while preserving
outcome receipts, and enqueue refuses reuse of audited job IDs. The immutable
staging and protected apply checks own source identity; the work tables do not
introduce foreign-key triggers into the existing queue/control catalog.

A generated PostgreSQL witness installs the ordinary compiled V1 app, publishes
the checked target, rejects a stored V1 job, registers later repairs, rejects
again, rolls back a successful repair, then commits it. The normal protected
queue protocol claims the repaired V2 payload, checks its generated codec and
completes the job. Repair replay survives reconnect and deletion. Tests also prove
unpublished/unstaged and Request dispatch refusals, database identity checks,
quarantine requeue refusal, the real source fence, abandoned-attempt cleanup and
raw historical payload privacy. All 53 conversion/repair cases pass with mandatory
PostgreSQL, including the three-upgrade candidate witness; affected runtime race
suites and the public V1/V2 unchanged-payload app regression pass too.

Public changed-payload application emission and automatic schema-worker scheduling
are still gated, as is complete application retirement finality. The dispatch
opener currently handles the initial queue-only V1/V2 edge. This delivers actual
application-bound mutation through an internal API, not a completed public rollout
or three ordinary application deployments. The full migration gate has not been
rerun after these changes.

The PostgreSQL execution candidate now has a same-database three-upgrade witness:
V1 → V2 → V3 → V4, with incompatible payload fields and JSON codecs at every edge.
The compiler emits three separate binaries from checked historical/target schemas
and typed migration/repair callbacks; the original sources are gone before the
binaries execute. Each edge migrates retained jobs, rejects old-valid payloads,
registers a rejecting repair and then a successful repair, reconnects/reopens the
Worker, replays its receipt, and retires the old version only after conversion.

This required edge-scoped repair slots: the source table now keys uniqueness by
`(from_version, revision)`, preserving all older descriptors and receipts. An
installer-only adjacent upgrade compares the new frozen decoder contract and
full historical schema/storage snapshots to the previous target, requires its
completed retirement floor, and atomically appends the new target/root while
preserving database identity. A skipped version or an unretired predecessor is
refused without changing the installation. Workers reopen against only the
active edge, while historical records remain available for audit.

The test retains one delayed job through all three computed transformations
(priority 7 → importance 17 → rank 27), plus a dead job with seven prior attempts.
Rejection and repeated rejection preserve original bytes/source stamps at every
edge. The final database retains four payload contracts, nine source/repair
descriptors and twenty outcome receipts; the first V1 conversion receipt remains
byte-identical after later upgrades. Old writers and the old binary's opener are
fenced. All 53 conversion/repair cases pass with PostgreSQL required, plus runtime
file gates, embedding checks and compiler `@check`.

This is a repeated-upgrade test of the real PostgreSQL execution candidate. It is
not three ordinary application deployments: application target planning/publication
currently handles the initial queue-only V1/V2 edge, and ordinary changed-payload
dispatch/retirement remains the integration gap. The full migration gate has not
been rerun after these changes.

WIP commit `d9729e0` records the verified opener, source/target staging and internal
queue-only physical planning. Successor preparation now registers the real
application's V2 physical manifest, complete queue inventory and expansion intent
atomically from the staged target. Protected SQL requires exact staged authority
for changed payloads; the existing unchanged/additive path remains available.
The first narrowing path retains queue/job membership and refuses additions,
removals, unstaged changes and unused staged decisions. Read-only observation
also checks the physical descriptor's exact conversion/payload bindings.

The internal publication operation uses the existing compatibility-plan drain and
`tesl_record_expanded`, rechecking installation identity, manifest, target inventory
and conversion authority under the publication transaction. Its zero-DDL V2
descriptor is explicitly non-epoch-preserving. Preparation alone does not admit
V2; the completed expansion commits that admission. A repeated publication
verifies and returns the same immutable history rather than replacing it.

Repair staging can also append revisions after that exact V2 expansion has been
published, while the historical source remains admitted. This requires the same
immutable conversion root, staged target, physical manifest and completed
expansion receipt; it cannot create a new root against an already-published
target. The application witness stages only the root before publication, then
appends both repair revisions afterward without editing deployed history.

The generated ordinary-V1 application witness now prepares and publishes the
compiler-generated successor inventory. It rejects unauthorized identities and
altered inventories without leaving partial physical/source registration. It
checks V1 status through the public binary before and after publication, V2
admission only after commit, preservation of existing V1 jobs, exact replay and
waiting for an outstanding V1 compatibility plan. All 52 conversion/repair cases
pass with mandatory PostgreSQL (19 parent DB groups), along with affected
baseline/physical/queue-operation race suites and the public unchanged-payload
V1/V2 application regression. This is internal Worker publication: ordinary
compiled changed-payload V2 dispatch and application retirement are still gated.
No old-database upgrade path was added.

Queue target staging now binds a compiler-generated physical descriptor to the
actual application's source installation and staged conversion set. The internal
`Migration_row_history.check_queue_expansion` path is limited to one V1/V2
queue-only edge with unchanged entities; public physical planning remains gated.
Its retained physical v6 descriptor includes exact queue/job identities,
conversion digests and old/new payload contracts. Runtime classification treats
it as narrowing, even though it has no row-generation windows.

Conversion source v2 certificates additionally bind full source/target schema and
storage snapshot hashes. Repairs cannot change those bindings. This prevents a
valid payload converter from authorizing a different complete schema, including
unrelated entity changes. Application source staging now checks the complete
installed source snapshot too. Target staging checks the existing entity layout,
all snapshot hashes, complete conversion coverage, compiler/stored-value identity,
database UUID/fence and staged source bytes before recording an immutable target
binding in `tesl_row_queue_target_staging`.

The source-deleted ordinary V1 application witness generates the target descriptor
from actual checked schema/migration sources. PostgreSQL tests reject freshly
rehashed altered schema/storage hashes, namespace, callback identity, missing or
duplicate decisions and reversed payload contracts. Exact registration and replay
pass without changing jobs or publishing V2. The complete 52-case conversion/repair
suite passes with PostgreSQL required, along with baseline/physical runtime race
tests and the ordinary V1/V2 unchanged-payload application regression.

This records a pre-expansion target binding, not a completed target expansion.
Publishing the target queue inventory and expansion receipt, consuming this binding
in ordinary worker dispatch, and application retirement finality remain necessary
before removing the public changed-payload gate. New installations include the
target staging table; older catalogs are refused rather than silently upgraded.

The normal fresh application installer now creates an independently checked
`tesl_row_queue_conversion_staging` table. An installer-only runtime operation
appends the original compiled conversion and repair lineage while bound to the
application's actual database UUID, fence namespace, admitted source version,
complete queue inventory, expansion receipt and exact old payload contract.
The new payload contract and complete source descriptor are retained for later
target-expansion validation. Replays compare all fields rather than rewriting
deployed source, and Worker/Request roles cannot mutate staging rows.

The generated PostgreSQL fixture now compiles a separate ordinary V1 application,
deletes its original Tesl sources, runs its public `--schema install` and
`--schema worker` commands, and enqueues a real V1 job through its protected queue
API. Staging binds all three source/repair records to that application's catalog
without changing the job. Tests reject unauthorized roles, unexpected catalogs,
foreign staged database identity and a missing staging table. The latter is the
intentional fresh-install compatibility boundary: registration does not create
or upgrade missing application catalog objects. Existing row-baseline and queue
candidate/operation race suites plus the public V1/V2 unchanged-payload application
regression pass with the extended catalog.

This is pre-expansion staging, not active conversion authority. It currently
requires the source version to be the installed current version. The target
application's checked physical expansion still needs to consume this staging
and bind its exact target inventory before dispatch can be enabled. Changed
queued payloads therefore remain gated in ordinary application compilation.

WIP commit `6fd12f0` records the shared queue lifecycle and bounded batch worker.
The next boundary now has a read-only Worker opener that reconstructs its
candidate execution handle without retaining installer state. It authenticates
the Worker login, verifies the complete relation/function set, independently
described columns/constraints/indexes, exact FK targets and RI triggers (including
the attempt-row cascade), sequence semantics and protected grants. Only then does
it call the verified read-only snapshot function and compare the database identity,
exact installed repair head, full source descriptors and payload contracts with
the linked compiler artifacts. An admission floor above remaining old jobs refuses.

All execution fixtures now start through that opener. Three additional PostgreSQL
groups cover opening without TEMP privilege, fifteen catalog/source corruption
cases, and a new worker process that resumes a rejected job using only Worker
connection information. The latter test caught pgx's original-DSN retention after
Config.User/Database changes; the fixture now serializes the actual Worker
endpoint and strips installer connection environment variables. The complete
52-case conversion/repair suite passes with PostgreSQL required (17 parent database
groups plus the process child), as do the existing queue candidate/operation race
tests and public V1/V2 queue application regression. This closes candidate restart
and catalog verification; format-5 application history/expansion integration and
production scheduling remain pending.

The PostgreSQL candidate now has bounded worker dispatch for a checked conversion
or repair revision. It discovers eligible jobs through a protected, indexed
`FOR UPDATE SKIP LOCKED` selection operation; callers no longer supply job IDs.
Each selected job commits independently, up to a requested limit of 1–256 jobs.
Receipts exclude previously processed outcomes, including rejections, so a worker
does not repeatedly retry the same rejected conversion. Repair selection requires
the exact latest predecessor rejection. Delayed/retry-scheduled and dead jobs are
included without changing their handler schedule.

The cursor exists only within a dispatch turn. Restart starts from the beginning
and consults durable receipts, allowing earlier locked jobs and later arrivals to
be found. `NoEligible` reports a scan result, not finality: locked or live-claimed
jobs and quarantines can still block retirement. Errors return confirmed progress
from earlier committed jobs; uncertain commits are resolved from receipts on
retry. Cancellation is checked before each BEGIN; a regression reproduced a
closed worker connection when pgx received an already-canceled context, and the
pre-transaction check fixes that case.

Four additional PostgreSQL groups cover bounded automatic conversion and repair,
restart without a saved cursor, concurrent workers, an earlier skipped row,
per-job failure after a committed prefix, invalid bounds, cancellation and request
role refusal. The expired-claim tests also use automatic batch selection. These
are candidate worker turns, not a production scheduler or format-5 activation.

After WIP commit `201aa9b`, the PostgreSQL candidate now composes conversion and
repair with the existing protected queue operation SQL. Claim, renew, fail,
complete, quarantine and inspection functions are reused; candidate-specific
admission binds a transaction-local installation identity and the exact compiled
source/target contracts. Context does not survive transaction commit.

Database-first regressions exposed three integration gaps before their fixes:
abandoned conversion attempts blocked ordinary completion through a foreign key,
receipt replay stopped working after a handler deleted its job, and expired
processing/dead-processing claims could not be converted. Attempt rows now cascade
on job deletion while immutable receipts remain independent; replay consults
receipts even without a job. Conversion recovers expired claims under the job
lock, preserves their pending/dead disposition, advances the attempt sequence,
and rolls back the release with the conversion if the transaction fails. Live
claims and the claiming transaction's completion right remain protected.

Ten generated PostgreSQL groups now pass, including an actual old claim/fail,
rejection/repair chain, current-codec decode, current claim/renew/complete and
receipt replay after deletion/reconnect. They also cover stale old completion,
expired pending/dead claims, active transactions beyond lease expiry, admission
context leakage and altered/cross-database bindings. The ordinary public V1/V2
queue application regression passes against its own private PostgreSQL cluster.
Application format-5 history/expansion binding and production dispatch are still
not connected to this candidate; its admission implementation remains isolated.

Typed queue repair now has a real PostgreSQL execution candidate, beyond the pure
artifacts. The private candidate installer owns a fresh namespace for one checked
queue transition, reuses the actual `tesl_jobs` definition, and stores the real
compiler-emitted payload contracts and conversion/repair descriptors. Restricted
Worker operations run the compiled callback under a row lock, then atomically
publish payload/version/quarantine changes with immutable per-job receipts.
Installer-only repair registration can follow an existing rejection without
rewriting the original migration. Replays consult durable receipts before
executing callbacks, including after reconnect.

The mandatory private-PostgreSQL run passes all 52 conversion/repair cases,
including six generated Go database groups with original source files removed.
The database witnesses cover preserved delayed/dead scheduling and attempts,
rejection followed by two repair revisions, actual backend death before commit,
post-commit replay, concurrent workers, abandoned/stale transaction attempts,
atomic registration failure, cross-database and rehashed contract substitution,
malformed payload quarantine and a waiting old enqueue across retirement.
Review reproduced a request-role execution leak caused by PostgreSQL default
function grants; explicit revocation plus exact function/grant validation fixes
it, and the adversarial PostgreSQL case passes afterward. Compiler `@check`,
runtime file gates, embedding consistency and pipeline race tests also pass.

This is an isolated execution candidate, not format-5 application activation.
Its installation identity and floor are candidate-owned; full application
source/expansion receipts, catalog integration, production dispatch and live
lease/retirement integration remain the next boundary. Public changed-payload
deployment still refuses. The historical full migration gate below predates this
work; it is not claimed as current whole-tree coverage.

Public `QueueRepair` declarations now connect the checked repair lineage to
ordinary diagnostics, formatting and standalone compilation. The declaration
names an exported, directly imported predecessor, exact job identity, consecutive
repair revision, typed callback and fixtures. Checking follows and captures the
complete predecessor chain, rejects cycles and wrong identities, honors unsaved
source, and omits only checked contextual declarations during callback lowering.
Generated fixture tests run the original conversion and every repair in order;
an accepted predecessor fixture fails instead of bypassing rejection. Public
source-deleted compiled tests cover this path. This completes the public pure
repair artifact link; the subsequent database candidate is recorded above.
Application integration remains incomplete.

Verification passes all 51 queue-conversion/repair cases, 23 declaration cases,
43 transformation cases, 14 fixture cases, 21 refresh cases, runtime pipeline
race tests, compiler `@check`, runtime file gates and embedding consistency.
The documentation catalog gate exposed 13 existing undocumented migration names;
their checked rule/contract descriptions are now included alongside QueueRepair,
and all 13 stdlib documentation/search groups pass. The full private-PostgreSQL
gate recorded below has not been rerun after the repair changes.

After WIP commit `7c02ddb`, typed repairs have an internal checked source and pure
execution path. Repair certificates bind an immutable predecessor digest and
consecutive repair revision to a new callback, preserving exact historical and
target contracts/codecs. Generated artifacts include the complete lineage;
runtime registration checks it atomically, and repair accepts only its exact
predecessor's rejected outcome. Source-deleted generated tests exercise rejection,
another rejection and successful repair, retaining the original bytes/version.
They also cover wrong predecessors, revision gaps, altered contracts, callback
reuse, direct-conversion bypass and freshly rehashed descriptor substitutions.
Runtime tests cover traps and invalid output without usable partial results.
The 42-case queue-conversion suite and runtime pipeline race tests pass. These
repairs were initially internal pure artifacts; the public declaration hookup is
recorded above. The later PostgreSQL candidate adds durable mutations and receipts
in isolation; it does not enable ordinary application deployment.
The full-gate result below predates this repair work.

The full default `scripts/run-migration-tests.sh` gate now passes after the public
`Migration.jobs` compilation hookup. It ran against its own mandatory PostgreSQL
cluster and includes the application harness (1133.341s), runtime race suites,
all 37 queue-conversion cases, all 24 queue-source cases, public V1/V2 queue
deployment, all 14 migration-fixture cases, and the remaining row, proof,
contract and retirement suites through the final runtime group. The complete
local log is `/tmp/opencode/tesl-public-jobs-migration-gate-complete.log`.
An earlier attempt reached the shell's one-hour timeout; the complete rerun
finished successfully with a longer shell budget. This verifies the current
source/adapters and existing deployment paths; installed changed-payload
conversion, typed repair and transforming retirement still require implementation.

After the WIP checkpoint, standalone `Migration.jobs` compilation now collects
checked queue converters alongside row fixtures and emits their adapters and
automatic fixture tests through the ordinary compiler route. It publishes no
database history and the application/physical-planner guards still refuse
changed queued payloads. A new source-deleted generated-project regression
executes the publicly compiled adapter, automatic fixture and metadata-substitution
tests. The existing 14 migration-fixture cases pass as well. This completes the
declaration-to-test-artifact link; protected database registration and mutation
remain the next integration boundary.

The first integration boundary now connects `Migration.jobs` source decisions
to the existing checked converter evidence. Changed retained payloads require
explicit `Migrate` coverage; helper ownership, nominal fixtures, duplicate
aliases and decision holes are checked. Queue and entity fixtures remain
separate. The source checker handles unsaved/formatter buffers and preserves
outer project views without masking later helper edits. Application codegen and
both physical planners retain explicit MIG028 refusals, including later-origin
planning, until protected registration and execution are implemented.

Review verification passes the 35-case conversion suite plus its additional
mixed queue/entity fixture case, all 24 queue-source cases against mandatory
private PostgreSQL, 43 existing transformation cases, 23 declaration cases and
21 refresh cases. The fixture-dependency omission was first reproduced as an
accepted freshly rehashed invalid descriptor, then refused by the corrected
reader. These focused results cover this integration boundary; they are not a
new full-gate result or evidence of durable payload conversion.

Checked queue conversions now have compiler-owned pure runtime adapters through
the internal `compile_queue_conversion_artifacts` seam. Emission binds exact
original declarations through the Go lowering graph rather than guessing names.
Runtime registration validates canonical payload/codec/callback/fixture bindings
and publishes source batches atomically; binding checks generated nominal types
and named wrappers. Conversion distinguishes malformed old payloads, explicit
Reject and accepted target bytes. Outcomes preserve original bytes and source
identity; traps and target codec failures yield no usable output. Automatic
fixture tests reject Nothing by name and accept deliberate Reject as a smoke
outcome. The expanded suite also covers helper cycles and stale emission.
All 32 conversion-source/adapter cases pass (142.618s), including generated
runtime metadata mutations with fresh hashes and registration atomicity.
The four pipeline unit groups pass with the race detector; all 24 queue source
cases, 14 existing migration-fixture cases and three runtime-file-gate cases
also pass. Compiler and documentation checks pass. This is focused verification;
the earlier complete migration gate predates the adapter-emission work.

This is byte-adapter execution, not durable queue mutation or deployment
activation. Typed repair receipts, protected conversion of claimed jobs and
transforming retirement are still required. Runtime gate tests also uncovered
an existing missing Dune dependency for `migration_row_contract_table_spec.go`;
it is now explicit, and all six embedded-runtime seam checks pass.

`Migration_queue_transform` now constructs opaque checked source evidence for
a same-identity payload conversion across adjacent revisions. It binds the exact
nominal callback signature, both explicit codec closures, payload contracts,
pure helper closure, fixtures and compiler/stored-value identities. Complete
frontend checking precedes lowering; source/import/directory guards protect
publication, including unsaved overlays. This component does not register a
runtime converter or admit public changed-payload builds. MIG028 remains intact.
All 27 source-checker regression cases pass; generated Go tests run the actual
old decoder, typed conversion and target codec after deleting the original
source tree, including proof-bearing accepted/rejected values. The neighboring
checked-graph and transform-link suites pass (7 and 21 cases). The new suite is
part of the default migration gate; the previous complete gate predates this
component. Lesson 96 explains the pure conversion/testing boundary.

The corrected September 27 default `scripts/run-migration-tests.sh` gate passes
in a single private PostgreSQL 17.10 execution: the compiled V1–V13 application
harness (1014.959s), four race-detected runtime groups, and all 31 compiler
suites, including the expanded physical Retype, proof-strengthening and
unchanged-payload queue retirement cases. The first attempted combined run
failed because a Worker verifier directly read `tesl_jobs`, which the Worker
role cannot access. That verifier was removed; the protected SQL admission
boundary now checks non-quarantined below-floor jobs instead. The final gate
passed after this correction. The later focused fixture also checks a held
old-version queue transaction across epoch closure and historical quarantine
visibility; its compiled application run passes (58.361s). This evidence does
not establish transforming payloads, typed queue repair or same-column codec
rewrite finality.

The same-column codec decision is explicit: encoder-changing codecs retain
old-format writes during overlap and rewrite only after old writers are
fenced; pruning a legacy decoder additionally needs a checked all-row
completion proof. No such rewrite authority exists yet. The executable path
remains Retype/WriteBack with distinct storage.

Queue-bearing additive epoch closure now has an atomic same-contract retirement
path. Protected SQL verifies the complete row/queue source prefix and exact
payload bytes/hashes, then restamps pending, delayed and dead jobs together with
the epoch receipt and floor advance. Surviving processing/dead-processing claims
retain all attempt and lease fields. Live retiring claims refuse; expired old
claims return to pending/dead with ownership cleared and sequences retained.
Quarantines block closure and keep their original payload/version. Row Contracts
and transforming queue histories retain their separate refusal guards.
Protected queue read/write admission now also refuses any non-quarantined job
stamp below the admitted floor. An adversarial direct catalog edit and both refused
request operations are exercised by the compiled application fixture; no
request-role direct table access was added. A below-floor quarantine remains
visible as dead-letter metadata and cannot be requeued. The fixture additionally holds a
real old-version queue transaction across the closing command, observes the
busy fence, and checks that no floor or job receipt publishes until release;
the subsequent before-commit crash still rolls the restamp back. Both focused
application scenarios pass again (57.731s, Go race detector).
The final application fixture also mutates a historical payload field in its
canonical contract, recomputes the table digest, and verifies that exact
source-inventory checking refuses the close-epoch command without changing
admission or jobs. It restores the catalog before proceeding through both
crash windows. Both compiled scenarios pass with the race detector (72.793s).

Queue source verification is shared as a SQL fragment, not an admission bypass.
Queue operations still require post-fence READ COMMITTED admission; epoch
publication uses its existing drained repeatable-read control transaction.
Concurrent surviving writes can cause serialization refusal and whole-operation
rollback. This initial path is one bounded atomic operation, not a resumable
background batch protocol. Earlier experimental catalog definitions fail exact
verification; no installed-catalog upgrade is supplied here.

The ordinary compiled V1/V2 queue application passes both retirement/crash and
quarantine-refusal scenarios against private PostgreSQL with race detection
(56.538s). It covers pending/delayed/dead states, surviving and retiring claims
in both processing modes, exact scheduling/payload/claim preservation, crashes
before/after commit, old-version refusal and idempotent retry. The queue compiler
suite passes all 24 cases (34.707s), broader queue/admission/epoch runtime checks
pass (88.416s), and the queue-free additive/transforming application still passes
(107.818s). The prior repeated-Retype native test now carries its required build
tag, restoring untagged runtime test compilation. Lesson 95 documents the new
queue lifecycle. These focused results do not replace a complete migration gate.

Same-column primitive Revalidate now accepts a field-local conjunction that
preserves all previous proof predicates through exact verified Same evidence.
It also accepts a conjunction as the first proof. The target establish still
returns its unchanged input with exactly the required subject-bound evidence;
the row constructor must use that establish's scoped Something binder. Existing
proof replacement, weakening, changed historical producers and codec changes
remain refused on this path. Lesson 94 documents the supported transition.
The source suite passes 25 cases and refresh passes 21. All four private
PostgreSQL Revalidate lifecycles pass with race detection (104.392s), including
old writers, rejected rows, repair, Contract and strengthening combined with
Legacy. These are focused results, not a rerun of the entire migration gate.

Queue recovery direction is now explicit in the queue roadmap: rejected jobs
keep their original bytes/version and require a typed repair migration;
discard requires a separate IgnoreOld decision. Typed queue callback dispatch,
repair authority, transforming retirement/restamping and same-column codec rewrite finality
still need implementation before their execution guards can be lifted.

The repeated-Retype source workflow now also has a mandatory PostgreSQL lifecycle
in `test_migration_row_retype_physical.ml`. Original V1 is publicly compiled
before freezing history; guarded generation produces V2 and V3, each with a
checked Contract, and the application source is byte-identical in all builds.
The source tree is removed before executing the three binaries. The test covers
two windows, premature V3 refusal, distinct JSONB codecs and columns, late V2
inserts/updates, non-materializing lazy reads, atomic failed bulk writes,
conversion rejection blocking retirement, repair through the retained V2 app,
both physical Contracts, old-reader refusal and settled restart. Lesson 92 now
links this live trace. All four physical Retype/removal compiler groups pass
against private PostgreSQL 17 with race detection (171.692s). A follow-up adds
assertions preserving the different existing/new-row counts through both
windows. That run exhausted the base fixture's 30-second whole-scenario budget
at the final Contract restart. This three-version scenario now has its own
bounded 75-second context, following the existing multi-stage worker fixtures;
operation deadlines are unchanged. The final focused case passes (70.928s,
including public compilation). The earlier combined-gate result below predates
this additional case.

Repeated Retype refresh now advances an inherited `@column` from the exact
previous field to the new introducing version, including Rename plus Retype.
Previously a second change to the same field retained its old annotation and
failed with MIG027. Custom, wrong-generation and ambiguous mappings remain
diagnosed rather than silently repaired. The guarded preview preserves frozen
history, source layout and publication preconditions. Lesson 92 documents this
workflow; lesson 93 collects the breaking-change test matrix.

The regression expansion adds fourteen Retype cases and six exact storage-edit
cases. Two cases execute the generated forward/reverse business tests with the
original Tesl sources absent. Those tests exposed a test-parser bug: skipping
all layout at the end of an indented case arm consumed the next arm. The parser
now retains that boundary, with two additional parser cases covering multiline,
commented, braced and nested arms. These changes complete this refresh path;
the remaining feature-wide deliverables listed below are still open.
The full Retype suite passes all 30 cases against mandatory PostgreSQL, including
the new generated-code tests with race detection (108.972s). The source-edit
suite passes 19 cases, refresh 21, and parser 62. Documentation integrity,
generated lesson-index coherence and manual coherence pass.

The September 25 default private-PostgreSQL gate completed in one execution on
PostgreSQL 17.10: the application harness (1100.809s), four runtime groups and 31
compiler suites (280 cases), including the expanded Retype suite and table Drop.
Go execution uses the race detector. This closes the outstanding combined-gate
verification for the currently supported paths. Pooler/replica/owned-cluster
optional tiers, other PostgreSQL majors and feature-wide unfinished work are not
covered by this result.

Breaking column changes have focused live coverage: primitive/JSONB removal,
proof strengthening, proof weakening and complete proof removal. Proof changes
use separate retained columns and exact historical proof-bearing reverse writes;
same-column replacement remains refused. See the detailed evidence below and
[lesson 90](../example/learn/lesson90-changing-field-proofs.md).

The complete default `scripts/run-migration-tests.sh` now passes in a single
execution on PostgreSQL 17.10: the application harness, three runtime groups and
29 compiler-driven suites (253 cases), with race detection in the Go lifecycles.
This includes the full Todo V1–V9 rolling deployment and V1–V13 transforming
application. Optional pooler/replica/owned-cluster tiers and the other PostgreSQL
majors were not enabled in this run. Earlier partial-run evidence below is
historical; this result closes the default combined-gate gap, not the remaining
implementation work or repository-wide CI/review gates.

Whole-entity `Drop` now has a bounded implementation: one ordinary table with
unchanged surviving entities under Worker topology. Explicit source-v5 and physical-v5 descriptors bind
the removed identity to both source snapshots and the exact retained predecessor
shape. Its `tesl-table-contract-v1` authority uses `Table Entity`, has no row
transforms/final generations, and removes only the reviewed table. Existing
non-Drop source/physical encodings remain unchanged. Lifetime entity/table-name
reuse, the last entity, mixed changes, queue-bearing histories, previously
transformed removed entities and removed tables with protected concurrent-index
jobs remain refused. See [lesson 91](../example/learn/lesson91-removing-a-table.md).

Contract verifies operation receipts before locking a potentially deleted table;
pending DDL uses `DROP TABLE ... RESTRICT` and commits its receipt atomically.
Known external dependencies refuse before Contract intent or retirement. A new
administrative dependency created afterwards may leave an already retired,
resumable Contract; it never authorizes cascading deletion. The protected SQL
validator independently binds the complete unchanged survivor inventory, exact
drop operation and empty finality. Table retirement cannot use additive epoch
closure, including its forced mode.

This adds protected SQL definitions to the fresh format5 catalog. Older catalog
definitions fail exact verification; there is no automatic installed-catalog
upgrade. The earlier complete default-gate result above predates this table-Drop
slice. Focused compiler/parser/SQL tests and the actual V1/V2/V3 PostgreSQL application
pass, including overlap, an admitted old writer, a crash after the committed drop
receipt, fresh V2 installation, dependency refusal and restart. The extended five
scenarios also verify V3 refusal before Contract, successful successor deployment,
and refusal of an unexplained missing table without changing protected state
(64.952s, race detector), including refusal of Embedded execution before protected
state changes. The broader regression gate is still being completed. Its first
run reached the worker lesson and found a diagnostic assertion tied to the old
expansion path; the new origin check correctly refused the same wrong login.
The assertion now checks the required Worker identity without depending on the
internal expansion stage.

Fresh format-5 Worker applications now link the checked queue runtime for
additive histories. Public compilation emits the row/queue companions from V1;
preflight requires exact database ownership, complete codecs and an additive
physical history. Pool admission retains the row verifier, and dedicated queue
listeners verify the same source, database identity and Request login when they
connect or reconnect. Legacy lazy table creation remains forbidden. Embedded
queues, transforming queue-bearing histories and queue retirement remain refused.

Public source-capture errors also propagate directly instead of selecting the
legacy emission path. A frontend-valid schema that collides with the reserved
row-generation marker now has a focused public-compiler refusal regression.
The queue compiler suite passes all 24 cases against mandatory PostgreSQL
(22.475s), and all 43 transformation compiler cases pass after this routing
change (14.407s). Existing queue runtime, operation and listener suites pass
with the race detector (35 cases, 41.085s).

The ordinary generated V1/V2 application regression passes (32.527s). It uses
public compilation, installation and migration workers, with identical application
source and the original source tree removed before execution. It verifies retained
pending/delayed/dead jobs, atomic entity-and-enqueue rollback, old-version claim
isolation, stale attempts and mutation-free forced/dry-run epoch refusal. The real
App then accepts HTTP work, runs its emitted typed handler, reconnects after its
dedicated LISTEN backend is terminated, and shuts down without creating legacy
facility tables. This mandatory PostgreSQL case is in `run-migration-tests.sh`.
Nested ADT payloads and long-running lease renewal are not exercised by this
particular application fixture; existing lower-level renewal coverage does not
replace future application-level coverage of those combinations.
Independent review and a second final review found no blocker in this bounded
integration. Build checks and documentation integrity pass.

The broader PostgreSQL audit exposed a real regression in ordinary Embedded
applications: the new row-history route refused concurrent indexes. Row startup
now attaches the existing scope-owned Embedded executor with its exact checked
row source. Connection transfer, readiness, cached scope acquisition and shutdown
retain the shared executor lifecycle. The original compiled additive application
passes again (67.20s), and shared executor/shutdown regressions pass with race
detection (27.33s). The complete V1–V9 rolling Todo regression also passes
(289.95s), including interrupted DDL and recovery under request traffic; the
Worker lesson passes (40.99s).

Other broad-run failures identified obsolete format-3 test drivers, failpoint
names and privilege probes, plus Unix socket path overflow under a long external
temporary directory. The repaired standalone expansion (30.36s), typed storage
round trip (9.82s) and shared database-owner baseline (3.07s) pass against real
PostgreSQL with race detection. Refusal snapshots now include durable row/queue
metadata and stable lease names, distinguish absent tables from empty tables,
and exclude volatile heartbeats and lease claims. Socket paths use the configured
short directory while builds and database data stay on the selected temporary
disk. The aggregate migration-test package budget is 30 minutes to accommodate
the complete compiled histories; individual scenario deadlines are unchanged.
These repaired cases do not by themselves establish a clean complete gate.

The repaired cross-compiler application lifecycle passes against PostgreSQL with
race detection (171.40s), including an interrupted migration, a matching-version
compiler ABI refusal, preserved durable metadata, and successful completion by
the original compiler. The control-format application regression also passes
(28.57s). Its legacy format-2 to format-3 bridge remains supported; these results
do not authorize format-3 to format-5 adoption. An original V1 row worker remains
quiescent, so the test checks its live request service rather than claiming that
it executes or observes a newer migration intent.

All remaining compiler gate sections have now completed against mandatory private
PostgreSQL: deletion/additive/new-table/index/additive-tail scenarios (15 cases),
derived/nominal/optional/captured-dependency scenarios (34 cases), and nominal
keys/Copy/cross-compiler retirement/physical Retype/Revalidate scenarios (48
cases). The earlier sections also completed, with stale negative diagnostic
expectations corrected and rerun separately. This is evidence from the broad run
plus focused repair reruns and disjoint gate sections, not a single clean execution
of the entire script. The final runtime review found no Embedded ownership or
cancellation blocker. Documentation integrity, `dune build @check`, and protocol
traceability pass.

Read-only source planning now handles transforming entity-only histories through
`planType: "row-history"`, retaining `kind: "migration-plan-preview"`, version 1
and `executable: false`. It validates the complete V1 history and reports tables,
generations, row/column mappings, runtime proof enforcement, codec observations
and exact checked Contract source summaries. The native guided CLI validates the
selected database/family/current revision and displays the current step and any
required prior Contract. Additive preview shape remains unchanged.

The row report explicitly sets `persistedStateObserved`,
`inPlaceRewriteAuthorized` and `decoderPruningAuthorized` to false. Codec reports
separate encoder syntax, ordered decoder alternatives and dependency-closure
changes, with `adapterOnlyEligible: false` in every case. Append-only alternatives
are not a compatibility proof or permission to rewrite data or prune decoders.
Typed `Retype` plus `WriteBack`, retained physical storage and checked Contract
cleanup remain the conservative representation-change path. Row previews with a
later installation origin, combined queue history, persisted finality and
pruning authorization remain outside this source-only feature.

The planner suite passes all 37 cases, including the complete V1–V13 todo
history, same-column proof revalidation, source/Contract change guards and
callback identity changes that leave field mappings unchanged. Eight codec
classifier groups cover decoder order, encoder direction, nested dependencies
and every affected stored occurrence. The guided CLI also consumes a real
compiler preview of the sealed lesson 89 app without changing its source.
The live PostgreSQL JSONB oracle passes with race detection (24.55s), including
conflicting old/new keys in records, optional records and nested ADTs, unchanged
storage after reads, and an explicit bridge rewrite. That oracle uses unversioned
codec applications; it does not establish production same-column rewrite finality.
Independent review and a second review found no blocker in this preview/report
slice. Documentation integrity and protocol traceability checks pass.

The September 20 public-path review restored entry diagnostics and a shared
captured-module judgment before Go emission. Regressions reject malformed
migration configuration, ill-typed private dependencies, and invalid unused
migration bodies. The live Todo lifecycle also exposed two integration gaps:
the test omitted additive epoch closure before V10, and Contract rejected even
valid indexes retained from V8. The test now closes the epoch with the V9 worker
while V9 requests keep serving. Contract verifies the complete protected index
inventory and catalog, then permits only valid indexes retained unchanged by the
settled plan. Pending, building, failed, missing, changed and removed index cases
remain refusals. The focused observer and retention regressions pass against
PostgreSQL 17 with the Go race detector. The complete V1–V13 lifecycle also passes
(382.54s in the final reviewed run), including a non-default retained priority of 4 becoming weight 5,
record-to-ADT conversion, V12 reads and writes of a V13-created row, and physical
Contract cleanup. The final review added reads of both rows and stored-value
assertions for both ADT constructors after the old JSONB column is dropped;
those assertions pass in the final run. Independent review found no remaining
blockers in the retained-index fix or the complex lifecycle assertions.
The current transformation compiler suite passes all 43 cases, including public
binary generation, optional proof/rejection execution, source integrity and
`Same` proof transport. The public dependency/body refusal regressions and
migration topology suite also pass. These focused results do not replace the
complete repository or private-PostgreSQL gates.

The feature is not ready for general use. The core row-migration engine has
substantial PostgreSQL application coverage, and ordinary application builds now
link checked row-transform companions. Queue payload transformations and retirement,
staged uniqueness and adoption remain separate deliverables. The default combined
private-PostgreSQL gate has since passed as recorded above.
The initial `Revalidate` implementation admits adding a single-field proof to an
unproved primitive field, retaining its exact value and physical column. The
target-owned optional establish must return its original input, and the row
initializer must use that establish's scoped `Something` binder. Generated field
metadata explicitly records `proofEnforcement: runtime-only`; SQL CHECK synthesis
and same-column replacement of an existing proof remain unfinished. A new proof
does not imply an older proof for future writes. Existing proofs can instead
change through retained-column Retype and proof-aware WriteBack, described below.

The reviewed initial path passes 18 compiler regression groups and two actual
PostgreSQL application lifecycles with the race detector (69.635s together).
The baseline builds byte-identical application source against V1 and V2 from
[lesson 89](../example/learn/lesson89-proof-revalidation.md). It verifies rejected
rows retain generation 1, lazy reads do not claim materialization, repair allows
worker completion, changed old writes invalidate the proof, and Contract refuses
retirement until repair succeeds. The second lifecycle combines Revalidate with
Legacy, changes an old-only field through V1, verifies V2 reconstructs that field
for old readers without changing the proven title, and drops the old storage at
Contract. The generated artifact explicitly states runtime-only enforcement;
forged, missing or SQL-CHECK enforcement claims are rejected. Query projection,
wire guards, public lesson tests, documentation integrity and protocol traceability
checks pass. Independent reviews found no remaining blocker in this initial path.

Breaking primitive proof changes now accept attached scalar results from
`WriteBack` and `LegacyWith`, provided their underlying type and exact historical
proof match. Predicate identities are resolved in each source owner; return
subjects are alpha-renamed, and conjunction structure is checked recursively.
Ordinary frontend proof discharge remains authoritative: no migration exception
can manufacture evidence. Cross-field entity predicates still refuse scalar
reverse callbacks.

The new reverse-proof matrix passes 18 cases: exact and alpha-renamed evidence,
conjunctions, wrong owners/subjects/types, missing or forged evidence, and removal
of a proven field. Three independently compiled PostgreSQL V1/V2 scenarios pass
with race detection (74.023s): strengthening rejects old-valid rows until repair;
weakening preserves a newly accepted value separately from its explicitly
old-valid reverse representation; removing the proof admits even an empty new
value while preserving proven old storage. A rejected bulk update leaves the
complete row/physical-column/generation/processing/shard snapshot unchanged.
The lifecycles cover late old writes, current writes,
old/current reads, Contract and physical column removal. The identical app source
uses unchanged `id` for ordering because Retype fields remain query-restricted.
The existing Retype/WriteBack suite passes all 16 groups against mandatory
PostgreSQL (87.550s); transformation (43) and Revalidate (18) checks also pass.
The removal suite additionally passes the new retained-window writes scenario
alongside its original Contract lifecycle (37.283s), including primitive/JSONB
removal, current-write LegacyWith regeneration, late old inserts, and exact
rollback after failed bulk writes. These are focused gates, not evidence of a
completed repository-wide migration gate.
Two independent reviews found no blocker in historical-proof matching or the
compiled lifecycle coverage. Bulk snapshots establish atomic observed outcomes;
they do not inject failure after a specified row update. The compiler now retains each branch's lexical receiver type when checking a
returned proven field, including a let-bound projection alias. Scoped contexts
restore on every exit; unrelated types, raw siblings, shadowing and forgotten
proofs still refuse. Ten focused cases and the broader proof/fail-closed suites
pass (1,279 Alcotest cases plus the proof-kind registry check). A direct
function-call receiver still needs a local binding for stable subject identity;
no arbitrary call-result identity or proof-checking exemption was introduced.
The migration reverse-proof matrix now passes 19 cases including that local
projection in a reverse callback.
The final review also prompted a post-Contract empty-string assertion for proof
removal; both affected PostgreSQL scenarios pass again (54.842s). The unchanged
strengthening case was deliberately excluded from that final two-case rerun.

Removing a proven scalar field now also has an actual compiled PostgreSQL
LegacyWith lifecycle (35.158s, race detector). New inserts and updates establish
the old field proof, late old writes invalidate the generation, a failed bulk
unique update leaves complete row/progress snapshots unchanged, and a new empty
memo receives an explicit valid old-title fallback. Contract removes the old
column, preserves the empty current value, refuses old requests and restarts
idempotently. This complements the earlier primitive/JSONB removal tests.

Lesson 90 now includes a runnable `example/learn/db-proof-change/` PostgreSQL
Worker app, frozen/current schemas, CLI-generated seals and Contract, and three
migration tests. All five Tesl source files pass agent-context and the source
migration tests pass. The live proof-change fixture reads these exact files,
resealing the checked histories for each isolated build. All three live
PostgreSQL scenarios pass from these lesson files (80.169s, race detector).

The post-gate follow-up makes that lesson's fallback return a proven field from
a branch-local record binding. The exact lesson source tests pass, and all three
live proof-change variants pass again (78.853s, race detector). Weakening/removal
now explicitly test an unrelated old `memo` update: it invalidates the whole row,
and the new reader reconstructs the valid old fallback instead of the newer-only
value. Lazy reads leave the stored target bytes and old generation untouched.
This is the documented limit of lossy WriteBack, not a lossless round-trip
guarantee. Exact retention requires retiring old writers before admitting values
they cannot represent.

Refresh now explains the supported Retype/WriteBack route when an existing
primitive field's proof contract changes, including establish/helper changes
without a spelling change. It keeps an unresolved `todo`; it never invents a
reverse callback or authorizes a migration. All 21 refresh cases pass, including
exclusions for primary keys, cross-field proofs, changed physical columns and
nominal codec carriers. Both the guidance and overlap follow-ups received
independent final review without remaining blockers.

The broader `dune build @check` now passes. Its earlier missing-interface and
Yojson failures came from the first test stanza implicitly including modules
owned by other stanzas; an explicit module list fixes that ownership. This
compile check does not execute the full repository suite, and the broader
migration completion gates below remain open.

Same-column JSONB fallback rewriting is also unfinished. The demonstrated JSONB
path uses typed `Retype` with a separate
physical column and a reverse adapter; it does not establish support for every
codec-history transition.

| Area | What is demonstrated | What remains |
| --- | --- | --- |
| Additive migrations | PostgreSQL expansion, retained writers, Worker deployment, explicit epoch closure and heartbeats | Remaining mixed histories and a reliable complete regression gate |
| Data transformations | Unchanged applications, lazy conversion, dual writes, backfill, repeated revisions, Contract, and generated physical row companions | Legacy installation adoption, mixed-history breadth and the complete private-PostgreSQL gate |
| Removal and JSONB | Actual field removal and record/ADT conversion, including reverse compatibility, SQL NULL, retained writers, and the V10–V13 todo showcase | Adoption remains separate; the compiled Todo V1→V13 PostgreSQL lifecycle is covered by `TestCompiledTodoComplexHistoryPostgres` in the private cluster gate |
| Proof and codec evolution | Typed `Retype` and reverse writes; checked same-value primitive `Revalidate` with explicit runtime-only enforcement | Same-column proof replacement, SQL CHECK synthesis, and same-column fallback rewrite/finality |
| Ordinary CLI | Public `tesl migrate` dispatch reaches the native publisher; ordinary builds link checked row transforms and retain compiler-owned previews | Native publisher end-to-end adoption/rollback coverage and remaining compatibility cases |
| Queue migration | Checked source inventories, combined row/queue catalog, fresh additive Worker application execution and atomic same-contract epoch retirement | Payload transformations, typed repairs and transforming retirement/finality |
| Staged uniqueness | Design and prerequisites | Implementation and application regressions |

The next acceptance milestones are the full private-PostgreSQL lifecycle for the
ordinary application workflow, followed by combined queue execution and staged
uniqueness. Concurrent-index safety, row-history index execution, checked migration
fixtures, typed deletion, read-only legacy-adoption inspection, and public row
transform linking are integrated; the adoption inspector deliberately does not
authorize a transition. The manual, lessons, showcase and comprehensive regression
run are kept as completion requirements.

The first queue execution milestone is fresh-install, additive mixed
entity/queue applications on format 5; transforming job syntax remains separate.
Attempt fencing already exists in `pgstores.go`; the queue roadmap's original
job-ID-only completion warning describes the pre-fix implementation. The missing
boundary was ordinary format-5 queue pool, listener and backend integration;
the Worker application path now supplies it. The format-5 queue admission
function verifies the fresh baseline,
complete source prefix, canonical inventory bindings and exact completed physical
expansion receipts. Claim, retry, renewal and completion retain the existing
attempt-fenced lifecycle; the format-4 candidate functions remain unchanged.
Those protected-SQL checks also remain directly covered by the earlier private
installer fixture, independently of the ordinary application regression.

The complete queue compiler suite passes (23 cases, 22.479s), including actual
generated V1/V2 PostgreSQL artifacts using the private installer boundary. The
SQL tests cover V2 claiming a retained V1 job, stale-attempt rejection after
reclaim, post-fence retirement observation, exact metadata tampering, and
unchanged durable state after direct SQL and forced/dry-run epoch refusals.
The format-4 operation/runtime suites also pass with race detection (31 cases,
33.854s); their shared attempt/lease behavior remains unchanged.

Queue-bearing history now explicitly refuses close-epoch, retirement, Contract
registration and the compatibility switch. The command path checks before
registering an intent; protected SQL checks again after acquiring the state lock.
An empty job table and `--force` do not bypass the inventory-based refusal.
Queue-free retirement remains verified: three runtime epoch cases pass (2.238s),
the actual additive application closes its epoch (103.505s), and three physical
Retype/WriteBack/Contract application cases pass (107.426s). Independent review
and the final review found no blocker in this bounded queue prerequisite.
Until queue finality exists, moving the admission floor could otherwise strand
pending, delayed or dead jobs. The experimental format-5 function catalog changes
in this slice; an earlier experimental catalog is refused by exact verification,
not silently upgraded. Merely accepting a new format number does not supply
inventory, codec and admission checks. Keep
changed-payload MIG028 refusals and queue-bearing retirement/Contract refusals
until their respective execution and restamping lifecycles are implemented.

Before the latest epoch/heartbeat integration, the runtime/compiler union passed
all 83 focused groups:
application access (11), nominal keys (19), nominal Copy/Rename (5), primitive
Derived (6), Retype/WriteBack (16), physical removal and JSONB Contract (3), and
Contract source/CLI checks (23). This run includes the bounded preparation retry,
Legacy, nominal reverse transport, Derived, and relative Contract path fixes.
It resolves the earlier nominal fixture's incomplete runtime dependency evidence.
The ordinary CLI prototype also passes an actual PostgreSQL lifecycle with V1
built before freezing history, byte-identical V1/V2 application source, and the
original source directory removed before execution. It covers Worker conversion,
lazy reads without materialization, old/new writes, Contract, settled inserts,
and retired V1 HTTP 503. A reusable exporter now reproduces that ordinary CLI
workflow with pinned compiler/CLI binaries, original V1 provenance, and identical
application-source hashes. Its newly built applications pass the PostgreSQL
lifecycle gate (4.101s). This remains an isolated first-transform prototype.
The refreshed ordinary workflow also passes with three original versions
(7.44s; 8.462s including the Go race suite). It covers the first transformation,
Contract, and a subsequent optional-field addition, including an original V2
writer preserving V3 data. V1 is built before freezing history, all three
application-source hashes match, and the original source directory is absent
during execution. Public dispatch is still isolated; this trace predates the
combined queue catalog and does not establish general mixed-history or legacy
adoption support.

Nominal Derived mapping certificates are integrated after two source reviews.
The final producer runs pass 36 affected groups; the fresh shared build and all
20 composed groups pass: nine nominal Derived groups (74.841s), five nominal
inverse groups (23.071s), and six primitive Derived groups (50.548s). These include
actual unchanged record/ADT applications, Worker conversion, Contract, lossy
codec inputs, optional records and SQL NULL, and nested lists. Direct stored List
carriers still refuse with MIG016. Ordinary Migrate transport of optional
records/ADTs is now integrated after two source reviews, 99 producer groups and
all ten fresh shared groups (90.161s). The latter includes unchanged record/ADT
applications through PostgreSQL Worker, late old writes, reverse writes and
Contract. Whole-field nominal transport preserves original codec inputs and SQL
NULL; wrong-field, helper, wrapper-shadow and missing-proof cases refuse.

Public-path review found missing frozen foreign-helper integrity checks and
unsupported cyclic/lifted ordinary-module emission. The deterministic integrity
check is restored in the shared internal route after independent reviews and a
fresh 28-group closure run (13.952s). The follow-up guarding adjacent foreign
metadata between checking and publication is also integrated after independent
reviews. Its immutable directory/source capture passes 127 producer groups and
82 fresh shared groups, including ordinary compiled histories and scoped nominal
mapping. Separate guard-removal mutants fail before emission and at publication;
integrity-only metadata never becomes an emitted module. The isolated ordinary
CLI workflow still builds both original versions with this guard. Deterministic
captured helper-cycle lowering is also integrated after two source reviews and
90 producer groups. Fresh shared validation passes the four SCC groups (28.211s)
and all 21 module-system groups (10.503s), after updating an existing test to use
the extracted graph API. It preserves original
callback/expression ownership and the existing codec/database-cycle and lexical
shadowing refusals. Captured lifted CivilTime support is integrated after two
reviews; all five fresh shared groups pass (11.668s).
Explicit additive-epoch closure and live request heartbeats are also integrated
after two reviews. Their fresh shared native wrapper passes (95.326s), including
ordinary compiled applications, explicit retirement, drain and heartbeat recovery.
The broader shared application-access suite initially passed ten of eleven groups
(252.486s): a fresh V2 process exhausted its existing 400ms startup budget during
the extra heartbeat connection verification. The corrected startup transfers its
already verified Request connection to the heartbeat, preserving the deadline and
full reconnect verification. Two reviews, original-app tests, and a precise
connection-count mutant cover ownership and cleanup. The fresh shared compiler
build and affected application/heartbeat group now pass (58.492s).
The shared compiler build and nine optional transport source groups pass. After
current-codec and queue-source integration, all 16 Retype/WriteBack groups pass
(71.332s), as do all three physical-removal/JSONB groups (81.772s). The forward
protocol wrapper passes (67.718s), covering independently compiled ABI ordering,
crash prefixes and cancellation rollback. Its first rerun hit the Unix socket
path-length limit in a test fixture under the external scratch directory; using
the existing configurable socket root fixes that fixture without changing its
cancellation assertions or production code.
Current-codec composition for an additive successor after Contract is integrated,
with an independent codec-owner field-order witness. Original V1/V2/V3 apps pass
the PostgreSQL lifecycle (7.49s), including late V2 writes, defaults, SQL NULL,
rollback and no invented backfill or ABI pin; three independent repeats pass.
One earlier run timed out during Contract V2. Its cause remains unexplained and
its failure is retained alongside the later passes. The reliability gate remains
open. New-entity expansion is also integrated: original apps pass table/index
creation, complete birth-provenance validation, later transformation, Contract,
and five publication/crash cases (25.750s). Its missing-birth guard mutant fails.
Fresh shared validation passes all six additive-successor groups (32.013s) and
the new-table lifecycle wrapper (40.039s). An earlier shared run timed out while
creating its test database during a 110-second PostgreSQL checkpoint, before
application startup. The private cluster was moved to external scratch storage
and restarted with the same configuration and test deadlines before these passes.
This fixture-setup incident is separate from the unresolved Contract timeout.
Optional nominal JSONB successor coverage is integrated after two reviews. Its
original record and ADT applications pass (14.258s), including distinct
retained-writer updates that preserve both new payloads. The fresh shared build
and all eight combined successor groups pass (154.095s, including compilation of
the original applications). Queue source projection is also integrated after two
reviews and two guard-removal tests; all 22 fresh shared groups pass (12.785s).
That projection binds complete source inventories and preserves the legacy
reader's refusals. It does not activate queue execution with row migrations.

The ordinary CLI workflow exposed a warning-exit regression: `tesl check` returned
failure for an otherwise valid application carrying only MIG031. It now bases its
exit status on error severity, preserving printed warnings. The new real-process
regression fails on the previous implementation and passes with the fix; it also
checks a mixed warning/error invocation. The focused check and all 37 diagnostic
groups pass after independent source review.

Concurrent-index review found a real readiness bug in the public additive
protocol. New writers could populate an unbounded key before its concurrent
index was valid; a failed second scan could then make the maintained invalid
index reject an old writer's unrelated-field update. Introducing and later
versions now wait for both physical and protected completion. Earlier versions
keep serving, and bounded plain indexes retain their existing readiness behavior.
The actual PostgreSQL failure and a precise guard-removal regression are recorded.
Two independent reviews, fresh shared runtime race checks (3.528s native, 1.050s
unit), and all 34 compiler planner groups (19.998s) pass. The native fixture uses
the real format-3 executor, Request readiness and index worker with a sealed
test history; this is not evidence of row-format-5 index execution. Existing
executables do not acquire the new readiness rule retroactively.

The row-history index observer is integrated after independent review. It binds
every index job to its checked physical operation and accounts for both index
and row-shard leases. Fresh shared unit and PostgreSQL observation checks pass
(1.740s and 2.728s). Its separate worker-execution candidate passes original
application readiness, failed-build recovery and atomic registration checks, but
review found that an idle old-version worker could indefinitely block Contract.
That candidate remains isolated pending a lifecycle fix and regression with the
old worker kept alive. Original nonphysical V1 worker compatibility also needs
preserving in that candidate.

The combined row/queue catalog is integrated after independent review. Every
original row application carries its complete queue inventory, including explicit
emptiness. Protected registration binds the physical contract to its source
schema and storage identities atomically; a precise guard-removal test detects
unrelated identities. All 23 fresh shared queue groups pass (22.146s) after fixture
integration. This changes the unpublished format-5 candidate layout; it does not
upgrade existing catalogs or activate queue dispatch, transformation or finality.

Checked migration fixtures now run through ordinary generated tests, including
fixtures returning the builtin Maybe of the exact previous entity. Nothing and
traps fail by fixture name. Both Row and Reject are valid smoke-test outcomes;
business assertions remain the author's responsibility. Emission checks the
complete original captured source graph, including imported helper bodies, and
retains the original proof context. Independent review found and fixed an
equal-owner/different-helper-body gap. The integrated compiler build and all 14
fixture, 43 transformation, 21 linker and 21 module-system groups pass, as do the
composed runtime unit race checks. Generated fixture tests run after their Tesl
source files are removed.

The broader shared application suite passed ten of eleven groups (296.289s).
The repeated-window group stopped on a stale expected diagnostic: the runtime
now refuses premature V3 expansion at its explicit Contract-V2 preflight, before
the older physical-manifest check. Updating that exact expectation preserves
the assertions that no new columns or compatibility floor are published. The
complete repeated-application scenario then passes (57.100s including source
rebuild), after independent review of the test correction. This is separate
from the historical unexplained Contract timeout retained above.

Migration-aware deletes are now supported for transforming entities. The checked
compiler emits a typed delete adapter for `delete` and
`deleteAndReturnResult`, using only Copy/Rename predicate fields. The runtime
executes one admitted parameterized DELETE, returns its command-tag count, and
does not decode rows, invoke conversion callbacks, or latch row-processing ABI.
The source tests cover computed/Retype refusals; the original source-deleted V1/V2
applications pass PostgreSQL delete, rejection-row removal, count-zero/count-many,
operand effects, old-writer deletion, rollback, timeout and post-Contract
retirement checks (Go race 11.231s). The same handler remains unchanged.

Remaining mixed-history combinations, adoption, queue execution, staged
uniqueness and the final comprehensive private-PostgreSQL gates remain open.
The transforming todo showcase, its lessons and public compiler linking are now
present. `TestCompiledTodoComplexHistoryPostgres` is part of
`scripts/run-migration-tests.sh` and skips only when no PostgreSQL DSN is supplied;
the private CI cluster therefore exercises the complete sequential V1→V13 rollout.
Manual coherence and documentation integrity must still pass after each
documentation change.

## Earlier integration evidence

These records preserve the results and limitations at each earlier integration
point. The current assessment above supersedes their pending-work statements.

An earlier increment preserves record and ADT primary keys through
exact `Same` evidence and an unchanged `old.id` projection. Two independent
reviews, the shared full compiler build, tagged row race checks (1.800s), and
all eighteen shared nominal-key groups pass (70.148s). The groups include actual
PostgreSQL Worker and Contract applications, source removal before execution,
lossy codecs, nullary ADTs, and rejected attempts to move the identity proof to
another field, helper or intermediate constructor.

The runtime and compiler/access support for repeated transforming revisions are
integrated after two reviews. The independently generated V1/V2/V3 trace covers
the original V2 process reading and writing generation 3, a caller-owned
transaction delaying publication without replayed effects, size-one pool
observation while holding an SQL row lock, and old-reader HTTP 503 after
retirement. Its isolated final eleven groups pass (250.597s). The shared run
passes ten of eleven groups (253.208s), including the repeated application trace,
but a competing Worker exits with SQLSTATE 40001 during shard registration. This
is a real regression, not a passing combined gate. A deterministic application
test reproduces progress committing after the registration snapshot. The narrow
internal registration retry and test are integrated after two reviews; removing
only that retry reproduces the failure. The subsequent shared eleven-group run
passes (276.392s). A follow-up review found that Contract, unlike Worker, passed a
long-lived service context to preparation. A single operation deadline now bounds
both callers' entire retry loop. Its actual application regression passes with
the two worker cases (14.406s); the unbounded predecessor fails the new deadline
test by completing Contract after expiry. That follow-up is integrated after two
reviews; its final shared union run remains pending.

Logical field removal via `Legacy` and `LegacyWith` is integrated after the
second compiler and runtime reviews. Its exact corrected source passes all 138
affected groups, including the three actual PostgreSQL removal/record/ADT
Contract scenarios (75.777s) and sixteen Retype/WriteBack groups (70.634s).
Coverage includes primitive and JSONB compatibility values, unchanged handlers,
late old writers, obsolete column/index removal, exact old nominal callback
ownership, closure drift and old cross-field proof boundaries. Review found two
closed-format validation gaps; both fixes have precise guard-removal mutants
that fail the intended freshly hashed regression. Full compiler build, runtime
race checks (1.724s), tagged lint, production-only nil analysis and manual
coherence pass. The integrated union is being rebuilt. These results remain on
the internal compiler route; ordinary application builds now link the same checked
row companion, and the transforming todo showcase is present. Its complete
private-PostgreSQL rollout remains an environment-gated acceptance item.

General nominal Copy/Rename and compiler-owned reverse transport are integrated
after final source reviews. Exact source-site certificates preserve unchanged
record/ADT values, including codec-omitted fields and nested nil/empty lists,
when another field requires Legacy or WriteBack. The producer's 137 focused
groups pass; its earlier native runtime dependency gap is explicitly recorded,
and fresh complete shared native acceptance remains required. Derived primitive
adapters are also integrated after compiler/runtime reviews. All six isolated
Derived groups pass (60.508s), including actual unchanged PostgreSQL applications
and Derived plus Legacy/LegacyWith using the old JSONB codec. Five overlapping
nominal inverse groups pass on the composed emitter. The shared compiler build
passes; the next combined native run must cover this complete union. Nominal
Derived values still require a distinct checked mapping certificate.

The ordinary CLI path is being exercised in a separate checkout. It already
builds the original V1 before any source freeze, then generates and builds V2
with byte-identical application source. This isolated compiler change is not
activated in the shared tree. Public activation still requires mixed additive
histories, checked additive tails, explicit epoch closure, and deliberate
control-format-3 adoption; a passing first-transform trace cannot replace them.

Reassessment, 2026-09-12: the feature is not near completion. Additive PostgreSQL
evolution and supported compiler upgrades are demonstrated with retained
rows and unchanged application code in lesson 83. Compiler, source-edit and model
tests are supporting evidence; they do not implement transforming migrations.
Independent architecture and editor reviews confirmed that the next work must
prioritize executable application scenarios over further editor machinery.

As of 2026-09-13, the internal checked compiler route runs unchanged V1/V2
application handlers through typed lazy conversion, dual writes and bounded
multi-row updates on PostgreSQL. The cursor and MIG031 cost warning have two
completed reviews; the integrated full compiler build and four application test
groups pass (37.959s). This remains a private implementation route. Backfill,
finality, live contraction and the next transforming revision are the current
acceptance target. The public feature and the requested transforming todo
showcase and lessons are not yet delivered. Their completion requires actual
application traces through the full lifecycle, then the full gates and another
review; additive example runs do not substitute for that evidence.

Physical Retype and WriteBack are also integrated after two independent reviews.
The real application tests use distinct record JSON keys and ADT constructors,
including constructors without fields, while V1 and V2 handlers remain unchanged.
The shared PostgreSQL runs pass both Retype scenarios (86.241s), all four cursor
access groups (46.589s), and seventeen retained-layout groups. Runtime race checks
and lint pass. A deliberately wrong reverse codec fails the expected old-column
read, and freshly hashed substitutions fail the physical source binder. A common
test-output helper was moved outside a build tag after the combined suites caught
a native test compilation dependency. Pure settled descriptions and explicit
prior-Contract prerequisites are source-bound metadata; they do not grant DDL or
establish runtime finality. Live contraction remains the next acceptance target.

Checked Contract source and its guarded CLI generator are integrated with the
private atomic runtime registry after a second review. The compiler derives a
global preparation prefix that relaxes obsolete required columns before settled
inserts, followed by the exact reviewed cleanup. Current Contract edits invalidate
captured source; starting another revision freezes the companion's presence and
raw dependencies. The shared native Contract suite passes eighteen groups
(27.700s), including source-absent generated binaries and freshly rehashed missing
operations. Native CLI/source-edit race checks and both documentation gates pass.
These results establish source authority and binding, not worker execution. The
first full runtime trace now passes in the isolated lifecycle/settled union: actual
worker backfill, a late V1 write, finality and same-process V2 reads and writes
before and after removal. Its five access groups pass (66.406s). A separate
record/ADT JSONB union passes both lazy/dual-write and full Contract scenarios
(63.997s), including durable final-pass conversion and retired V1 HTTP 503. These
were isolated application results. The lifecycle, settled access and JSONB
Contract regressions are now integrated after independent reviews. The shared
compiler build, runtime row race checks (1.740s), tagged lint and nil analysis pass;
the fresh combined PostgreSQL application gate passes all nine groups (204.595s).
Its ten lifecycle/native race cases pass together (116.080s), including every
review correction. The shared record/ADT full Contract suite also passes both
groups (67.581s), the four A/B compatibility races pass (74.350s compiler group),
and all 22 Contract source groups pass (42.473s). Public activation and the next
transforming revision remain separate requirements.

The private lifecycle evidence includes actual lease renewal across a final pass,
a healthy competing Worker, internal claim/CAS serialization retries and backend
termination before and after atomic row/ABI/cursor publication. Distinct compiler
A/B applications pass four completed-history and first-write/retirement races
(72.738s compiler group, 20.727s native Go race run). A second review found normal
batch completion could cancel a pending renewal and close a reusable connection;
it now drains that bounded query. The same review found complete deletion of a
retired version's shard inventory could evade an observed-row count; the reader
now requires that version's complete inventory even when no rows remain. Both
actual application regressions pass (15.870s), and removing either correction
fails its precise regression. A later supplemental run timed out during batch
commit and subsequent fixture setup under host contention; its cause was not
captured, so it is not counted as a passing rerun. The subsequent shared combined
gate passes with the original deadlines; the earlier failure remains recorded.

Staged NOT NULL validation is the next contraction gate. The compiler derives
four internal operations from the existing one-field selector. This compiler and
private registry union is integrated after independent reviews: the shared full
compiler build and all 22 source-absent Contract groups pass (56.471s), runtime
race checks pass (1.138s), and lint and both documentation gates pass. Three
guard-removal mutants fail. A separate PostgreSQL 16–18 mechanism witness verifies concurrent
updates during validation and scan-free final tightening. Neither result alone
establishes the full staged application lifecycle. The separately frozen
runtime union passes six actual application groups (93.656s), including all four
DDL crash stages and three batch commit stages; eight catalog identity and proof
validity cases pass. The runtime is now integrated and its fresh combined
application gate passes. Public activation remains a separate requirement.

The compiler-upgrade design gate passed under stored-value contract
revision 4: actual A/B/C executables retain data, a different compiler ABI may
serve completed compatible history, and pending execution remains ABI-pinned
(115.28s, including pending-worker recovery).
Build provenance and stored-value compatibility now have separate identities.
The explicit contract binds a compiler-owned semantic revision and active lifted
stdlib digests; its maintainer promise includes proof/check/establish semantics,
lowering, codecs and SQL representation. Fully checked historical source/storage
must reproduce the same identity before a different build can serve completed
additive history. Pending intents keep the original build ABI. Old provenance is
preserved, and legacy metadata lacking the contract is refused. Compiler migration
and embedding suites passed (495 cases), and the actual A/B/C retained-database
scenario passed before the proof-owner correction below. The runtime
expansion/boot gate also passed (142.080s), as did native migration CLI race tests
and targeted lint. Mandatory migration CI
now fails instead of skipping unavailable PostgreSQL; its negative subprocess
tests pass. Transforming execution and different-contract
revalidation retain their separate phase-3 requirements.

The simplified example uses `Schema.Todo.VCurrent` and fully prefixed historical
imports, with each frozen schema beside the current file. This exposed a proof
identity defect through imported functions and higher-order `Fact` parameters.
The correction preserves each predicate's original declaring module during
checking and lowering without rewriting source hash inputs. An unmodified main
compiler accepted a cross-owner proof through hidden forwarding functions; the
corrected compiler refuses it. Stored-value semantics therefore advance to
revision 3. Its fresh nine-revision showcase and native rolling/index gate passed.
A subsequent review reproduced an HTTP boundary accepting `Role "reader"`
evidence for a handler requiring `Role "admin"`; the handler could then store
that invalid evidence. Complete proof applications now cross auth, capture and
response boundaries, preserving owners, subjects, literals and quantified
conjunctions. A separate reproduction showed raw HTTP body annotations and a
parsed-but-unexecuted `body via` clause passing unvalidated evidence to handlers;
these forms now fail at the frontend, while codec-validated fields remain usable.
This correction advances the current contract to revision 4.
Contract-2/3 histories are not relabeled, and bookkeeping upgrades do not
revalidate their stored proofs. The contract-3 native result below remains exact
historical slice evidence. The regenerated revision-4 nine-release application
passes its retained-PostgreSQL rolling/index/crash gate (123.08s), all twelve
workflow/proxy regressions, and the documented `tesl test` and `tesl build --local`
commands. Focused owner/HTTP and ForAll suites pass (48 and 61 cases).

The current stored-value contract is revision 5. Review of the first typed row
converter reproduced a different-subject proof forgery in revision 4: an optional
producer returned a transformed value, but a decomposed success witness could
be attached to the unchanged input and stored in a proof-bearing record. Success
proofs now follow the returned payload, independently of input/return binder
spelling. Direct, bound, aliased, decomposed and forwarded optional values are
covered. The adjacent review also found an ordinary attached result promising
its input's identity while returning a different value through a branch. Every
returning branch now verifies that identity; fresh result binders and partial
calls cannot borrow an input subject. The author's combined 403-case gate passes,
including five generated Go race executions. The shared full compiler gate caught
an additional compatibility regression: a nested check result bound through a
local name lost its input identity. The correction joins identity only when every
returning branch preserves the same outer subject; an always-failing value has
no returning continuation. It preserves `forgetFact` removal and rejects unrelated
branch-local subjects. The old spelling-only alias negative now has paired valid
alias and wrong-subject tests. The 233-case focused gate, including actual Go
execution and all emission cases, passes. The resumed baseline compiler gate
reported 10,815 passing cases and two native Go compilation timeouts with a cold
cache; both affected suites pass on rerun after warming the runtime build. No
other baseline failure was reported. The Same/linker union passed all
10,879 reported cases across 236 successful suite reports, with the exhaustive
proof suite enabled and no failure lines.
An additional regression preserves proof returns from nullary `()` calls.
Contract-4 databases are not relabeled or silently trusted. The earlier
retained-database results remain historical evidence. Fresh revision-5 compiler
upgrade, nine-release rolling application and separate-worker lesson tests pass
on PostgreSQL 17 (623.095s combined, including pending-worker recovery). Source
history was regenerated with the compiler; old contract-4 databases and archives
were preserved without relabeling.

PostgreSQL deployment settings now use `PostgresConfig.migrations: MigrationConfig
{ topology, controlOwner, requestRole, workerRole, ddlConnection }`.
`Database.migrations` continues to select the history module; namespace and
application connection settings remain on `PostgresConfig`. The typed record
supplies the usual field completion, hover and documentation. Historical flat
spelling remains readable, but mixing it with grouped fields is rejected.
Focused compiler/configuration gates pass, as do the real applications above.
The documented `tesl test` and `tesl build --local` commands also pass. The
configuration has two completed reviews; its expanded focused suite passes all
16 groups. Documentation integrity and standalone manual coherence pass after
adding the new contributor guides to their index.

The checked-graph extraction shares complete source/type capture between schema
inventories and the forthcoming transform linker, preserving the exact previous
inventory digest. Its 90-group compiler union passes, including explicit role
re-lowering, private proof/codec closure, unsaved imports and early complexity
refusal. The checked proof context and semantic linker are now integrated.
`Same` transports primitive self-subject field proofs only at verified final-row
Copy/Rename projections. Prepared evidence remains distinct from checked
descriptors; complete source/import-owner guards cover both transforming and
additive-only roots. Independent review caught and fixed intermediate-constructor
proof credit, conflicting import owners and stale additive preparation. The
97-group source gate passes, including source-deleted native execution and two
sealed adjacent history edges in an application.

The semantic linker retains its exact checked source descriptor, complete
old/new type and callback/fixture closures, verified Same identities and compiler
ABI. Its 109-group union passes, including source/ABI drift, explicit From/To
roles, private codec/proof dependencies and context isolation. Both patches have
two completed source reviews. Their shared integration gate passes, as do the manual
and documentation-integrity checks. Actual retained-PostgreSQL compiler upgrade,
nine-release todo rollout and separate-worker lesson tests also pass (184.392s
combined). These application runs still exercise additive/index migrations;
they are not evidence of a working transforming executor.

The compiler-generated row callback companion is now integrated. Complete source
history assigns generations per entity and binds exact checked old/new types,
private helpers and codecs to concrete typed callbacks. The 142-group focused
compiler union passes, including actual Tesl Row/Reject execution after deleting
source and loose metadata, proof-bearing Same helpers, multiple databases, and a
full App that refuses unsupported startup before telemetry or network effects.
Runtime registration/preflight race tests and lint pass. Three deliberate guard
removals are caught by nine isolated regression witnesses, and canonical framing
passes a 42,044-execution fuzz campaign. Compiler, runtime and the fuzz/CI follow-up
have two completed reviews. The larger shared compiler gate passes all 10,902
reported cases across 237 successful suite reports with exhaustive proofs enabled.
The separate PostgreSQL migration gate found three fixture failures: mixed output
streams, missing traceability metadata, and a process deadline shorter than the
server drain interval. These are corrected. A subsequent rollout failure recorded
an 8.5-second PostgreSQL COMMIT exceeding the test's three-second HTTP deadline;
the request deadline is now fifteen seconds while separate ten-second per-node
progress checks remain unchanged. Failure diagnostics sample actual PostgreSQL
waits and blockers through a separate bounded connection. The disposable-cluster
nine-release rollout passes (148.107s), as do the separate-worker lesson (28.794s),
native storage/required-PostgreSQL cases (11.633s), and traceability gate (19.254s).
The integrated baseline/storage/retained-plan compiler gate passes with exhaustive
proofs enabled: 10,870 reported cases across 232 successful suite reports, with no
failure lines. Some unchanged Dune targets were cached; this is a reported run
count, not a count of the repository's test inventory. The disposable PostgreSQL
application/harness lane also passes (490.495s). Its next lane exposed an obsolete
Embedded queue fixture: the production refusal is correct, and the fixture now
asserts that refusal without expecting unsupported claims. The corrected admission
suite passes with race detection (19.334s); removing the refusal kills both new
negative witnesses. Independent review is complete.

The complete production control lane passes all 103 top-level groups (254.469s)
within its unchanged 300-second watchdog. A concurrent diagnostic run had exhausted
the aggregate budget; the repository runs these lanes sequentially. The baseline
lane also passes (147.983s). The index retry fixture now pauses at the existing
build-tagged boundary mechanism after the first durable release, verifies that
attempt's exact error and cleanup, repairs the data, and resumes the same worker
for attempt two. Its focused PostgreSQL race tests pass (11.772s) and two source
reviews are complete. The complete fixed index lane passes sequentially on an
isolated PostgreSQL cluster (96.248s), under the unchanged 300-second watchdog.
These results do not claim a complete mandatory-script pass.
The reviewed NilAway corrections reduce the full-module baseline from 31 diagnostic
headers to zero, with runtime/CLI race and mutation evidence.

The bounded V1-to-V2 physical/runtime foundation is now integrated after two
source reviews. Its compiler-generated canonical physical history binds complete
source owners, retained columns, exact index lineage and checked callback behavior.
Build ABI remains a separate execution constraint. Source-only parsing grants no
execution authority. Compiler mutation tests cover callback/helper/proof/codec/
fixture/Same changes, and a separate two-entity test verifies that changing either
callback invalidates both windows' shared behavior identity. Rehashed column/alias/
index mutations and partial multi-database registration are rejected.

The mandatory native suite now builds V1 before V2 and an independent compatible
compiler B, using actual generated runtime files and untouched generated manifests.
It passes on PostgreSQL with race detection (91.710s total, 56.543s native lane),
covering worker expansion, retained-writer invalidation, typed lazy reads and writes,
actual Tesl Reject, nine crash prefixes, preopened A/B pools, and concurrent
read-then-write transactions. Reads do not latch an ABI. The first materializing
write records it in the same transaction; even a caller that ignores a subsequent
error cannot commit unlatchable data. A completed V1 worker reconnects after V2
without replaying its old intent. Four narrow guard removals fail their intended
regressions. Baseline/trigger race tests also pass (89.809s), and NilAway reports no
findings. Standalone unused-code lint remains pending the application access layer.

This internal foundation explicitly supports only the first V1-to-V2 window. Its
protected format must be generalized before a public multi-migration release;
backfill/finality, contraction, physical Retype and queue execution remain unfinished.
The separate query integration has passed an initial actual Main/HTTP scenario
with unchanged handlers, but is still under review with expanded regression tests.
These results do not mark the complete transforming feature or documentation done.

Typed Retype and WriteBack source support is also integrated. A checked reverse
constructor retains the old nominal record type and its proof obligations; JSONB
records/ADTs and optional SQL NULL values exercise actual PostgreSQL codecs. The
runtime checks a one-to-one correspondence between every declared reverse field
and its checked semantic closure. This is compiler/codec support; physical Retype
execution remains a separate requirement. Malformed field types, annotations and
proofs now report an error instead of silently discarding a field or its proof.
The complete shared compiler build passes, including all AST consumers.

The mandatory PostgreSQL workflow and local migration script explicitly run the
source/target storage, Retype and actual generated forward-runtime suites. They
inherit the required-database setting, so these checks cannot silently skip SQL.
The gate correction has an independent source review. The full application access
layer must join the same mandatory lane when its review is complete.

The source prerequisite for queues is integrated: pure `queueSchema` declarations,
complete payload/proof/codec closure, immutable family-relative identities,
incompatible-change errors and complete application binding checks. Its 21 grouped
regressions pass and two source reviews are complete. Old source seals remain
unknown inventories, including through later freeze/refresh operations. This is
not runtime admission: a newly frozen, previously unsealed V1 cannot prove that
an older deployed V1 never had queues outside its schema. Protected storage must
require persisted baseline inventory evidence or explicit legacy adoption before
any cross-version claims are enabled. See [the prerequisite contract](queue-schema-prerequisite.md).

The checked queue history now reaches emitted binaries as a separate immutable
companion, preserving the existing expansion wire format. Every database and
installation origin is validated before publication, and actual queue codecs
are bound to their declaring schema and database. Compiler program/queue suites
pass (21 groups each), including executed generated codecs with the loose JSON
files removed; the companion and registration race tests pass. Two reviews found
no remaining blocker in this metadata slice. It does not enable durable claims
or establish a persisted installation baseline. See
[the projection contract](queue-history-projection.md).

Protected queue storage has an unpublished format-4 candidate. Fresh installation
records the complete checked inventory; upgrading format 3 records an unknown
legacy baseline and cannot enable claims. Exact table/sequence/FK/trigger/grant
verification, immutable semantic inventory, compatible compiler changes and
source-seal provenance are covered. The combined PostgreSQL control/candidate
gate passes 246 cases, including 16 real backend-kill boundaries; the candidate
race gate passes (24.583s). The protected operation candidate also passes real
PostgreSQL race regressions (12.321s), including a reproduced and fixed lease
check after waiting on an unchanged row lock, mixed-version claims, backend loss
and atomic handler/queue commit. A private runtime dispatcher and dedicated
queue listener now execute the protocol; production installation and CLI still
use format 3 and refuse versioned queues. See
[the candidate contract](queue-control-format4-candidate.md) and
[operation invariants](queue-operations-candidate.md).

The candidate now registers each deployed queue inventory immutably, before
publishing expansion. The worker verifies complete canonical contracts, preserves
original creator provenance on compatible replay, and rejects removal/movement or
payload changes until typed job migrations exist. Old observers verify future
inventories without claiming their jobs. UNKNOWN upgraded inventories cannot
publish an expansion or imply historical absence. Candidate installation now
includes the closed operation function catalog. The integrated control,
registration, operation and App preflight race gate passes 430 cases (103.642s),
with no skips and zero lint findings.

The integrated private backend, pool admission and queue-only listener pass the
combined PostgreSQL race suite (80.591s), with zero lint findings. Pool replacement
and listener teardown are covered without leaked test goroutines. The compiled
full-App witness exercises actual generated handlers, nested proof codecs,
regular/dead workers and transaction rollback with loose metadata removed. The
private bridge supplies installation/binding only; public startup remains
refused. Background-worker cancellation/join now preserves the database binding
through in-flight completion, interrupts idle polling, and refuses a different
nested database while workers are active. The integrated worker/Embedded/HTTP
shutdown race gate passes (109.578s), including real signal shutdown before serving.
Two bounded reviews cover the lifecycle implementation and its Memory-only runtime
boundary. Neither this witness nor the additive todo history implements
transforming or removing stored payloads.

A later repeated integration run caught renewal stopping between handler return
and queue completion. Renewal now continues through the final store mutation,
including failure and panic paths. Deterministic scheduling and real protected
PostgreSQL tests reproduce that interval for ordinary and dead-letter workers.
The race result above includes the correction and its two bounded reviews.

Dead-letter metadata now has five typed accessors and an exhaustive four-reason
ADT. Memory and legacy queues report only known provenance. Legacy quarantines
remain `LegacyUnresolved`; a stale retryable handle cannot override the live
quarantine marker. Compiler/native metadata, import/export, Memory and PostgreSQL
regressions pass. See [the metadata contract](dead-letter-metadata.md).

App startup now validates its explicit active database before entering its scope
or running user startup effects. It prepares every target before closing any
registration, preserves retry after a refusal, and closes codec/constructor races
without reversing the database/codec lock order. Source metadata cannot enable
legacy queue storage: versioned queues refuse in both Worker and Embedded paths,
including lazy access through a cached binding. The actual generated Main and
queue binaries, all 22 compiler/program groups, runtime race tests (7.731s) and
focused lint pass. Unversioned queues and Memory keep their existing behavior.

The same lease-after-row-lock defect also reproduced in the existing unversioned
queue backend. Its completion, renewal, failure and decoder-quarantine SQL now
materializes and locks the exact attempt before checking the lease clock. The
actual backend regression covers all four paths; the broader queue/candidate/SQL
operation race suite passes (33.923s). Independent review confirmed that existing
claim identity and explicit-transaction ownership remain intact.

The broad compiler run after the revision-4 proof correction exposed five old
test groups that relied on unchecked HTTP body annotations or unexecuted wire
adapters. Those fixtures now perform real validation; the compiler restriction remains. Response validation now also accepts equivalent
attached and quantified conjunctions without losing owner or argument identity.
Its focused ownership and ForAll suites pass (48 and 61 cases). The full
`dune runtest -j2` gate passed after those corrections. An additional native
regression calls the actual emitted todo handler with valid batches and invalid
IDs in every batch position; all ten cases pass.

The production Worker request/executor split and concurrent index worker pass
their PostgreSQL regression gates. The protected row protocol now understands
recorded generation/trigger objects and the public compiler links its typed row
companion. Current
additive binaries reject unknown control formats and triggers; they cannot be
treated as compatible transforming predecessors without that bridge. Queues and
outboxes require real versioned storage/restamping, or an explicit restricted
entity-only protocol from inception. A one-time check for absent queue tables is
not sufficient evidence about older admitted binaries.

Embedded index supervision is implemented with scope-owned executor generations,
startup-to-server signal cancellation and joined handler shutdown. Focused real
PostgreSQL and race tests cover concurrent scopes, reconnects, permanent failures,
plain/unique indexes and shutdown. Both PostgreSQL lanes pass without skips:
core (206.402s) and index/Embedded/Serve (101.460s). The compiled full-app index
lesson still requires its final run. The lanes are disjoint mandatory selections with
the existing 300-second limit each; the former combined selection outgrew that
limit. This is slice evidence, not completion of phase 2.

Use these application scenarios as the progress surface. Each requires production
execution, retained PostgreSQL data, failure/restart regressions, a runnable lesson,
and both reviews. The normative phase prerequisites remain in force.

| Scenario | Current evidence / remaining work |
|---|---|
| Existing database survives a supported compiler upgrade | Revision-5 A/B/C retained-database and pending-worker recovery passes; isolated completed-transform A/B app and first-write race regressions also pass |
| Adopt/deploy the notes app; add fields and indexes | Additive/Worker lessons and the nine-release todo rolling/index gate pass; adoption remains |
| Transform an entity while old/new apps keep serving | Public V10–V13 todo source links derived, removal, record JSONB and ADT row companions; fixtures and generated Go tests pass; `TestCompiledTodoComplexHistoryPostgres` covers the sequential private PostgreSQL worker, provisional/final backfill and Contract lifecycle |
| Reject a row, repair it, retire old code and contract | Actual row Reject rolls back whole updates; isolated worker/Contract crash recovery passes; quarantine, repair and full lifecycle integration remain |
| Evolve a stored record/ADT without changing the HTTP API | V12/V13 todo migrations convert record and ADT JSONB while app handlers and API tests stay unchanged; the complex private PostgreSQL test covers retained readers/writers and both Contracts; nominal primary-key transport and pruning remain |
| Carry delayed, dead and in-flight jobs through a roll | Checked source/codec inventories and unpublished protected storage pass; claim integration, payload executor and effects remain |
| Stage and promote uniqueness under concurrent writes | Production reservation, reconciliation and promotion remain |
| Restore an old database, catch up, migrate offline and prune | Production orchestration and durable completion evidence remain |

Storage-only lessons must assert byte-identical handlers, routes and API contracts.
The todo showcase now has runnable scenario lessons for derived backfills,
field removal, record JSONB conversion and record-to-ADT retyping
([85](../example/learn/lesson85-derived-backfill.md)–[88](../example/learn/lesson88-jsonb-adt-retype.md)).
JSONB evolution uses the same migration history and transformation engine as rows;
a fallback decoder alone is not completion or permission to prune old decoders.

The editor apply coordinator is an **internal, disabled slice**. Review found that
a negative client reply need not precede every resulting buffer notification, and
auto-save can make generated files dependencies of saved user source. Public apply
capability activation is disabled; negative replies retain recovery state, and
restoration rechecks open inputs' saved bytes before removing generated files.
Re-enabling requires an explicit editor snapshot barrier and complete wire-level
failure/recovery tests. Read-only previews and the saved-source CLI remain usable.

| Delivery gate | Implementation | Regression gate | First review | Final review |
|---|---|---|---|---|
| 0: deterministic harness, independent model and traceability | pending | pending | pending | pending |
| 1: schema history, planner, additive executor, permanent admission, editor | pending | pending | pending | pending |
| 2: worker roles, concurrent indexes, durable queues and effects | pending | pending | pending | pending |
| 3: typed transformations, compatibility, backfill, epoch closure | pending | pending | pending | pending |
| 4: contract, repairs, pruning, offline and catch-up | pending | pending | pending | pending |
| 5: JSONB codec integration | pending | pending | pending | pending |
| Queue payload migration language and executor | pending | pending | pending | pending |
| Staged uniqueness runtime guard | pending | pending | pending | pending |
| Dev docs, manual, and runnable scenario lessons | pending | pending | pending | pending |

## Documentation acceptance

The maintainer added this completion requirement on 2026-09-05: update the
developer documentation and manual, and teach migrations through several major
lessons that compile and run in CI. The initial lesson split is:

1. Schema ownership, adoption, and an additive column.
2. Typed transformations, renames, defaults, and row proofs.
3. Rolling deployments, admission, epoch closure, and contract.
4. Quarantine, repair, and compiler ABI consistency.
5. Queue payloads, outboxes, and idempotent external effects.
6. Staged uniqueness and promotion.
7. Offline changes and restoring an old database through catch-up.
8. JSONB codec history and evidence-backed pruning.

Each lesson must exercise its actual generated runtime and refusal cases; source
checking alone does not meet this gate. This is a planned inventory, not a claim
that these scenarios currently work.

The maintainer also requires `example/db-migration-example/`: a full PostgreSQL
todo application with an Elm frontend following the chat example, separate schema
worker and request processes, and a recorded history of at least five migrations
(preferably more). Common migration kinds recur, and the final history must cover
the implemented transformation, index, JSONB and lifecycle scenarios rather than
only nullable additions. Its README gives concrete database-change steps and a
cluster rolling-update recipe. Regression tests must compile the actual history,
retain data across revisions, verify unchanged handlers for storage-only changes,
and continuously exercise the load-balanced HTTP API during replacement. Startup
readiness, worker interruption/recovery, invalid input and request-role isolation
are explicit assertions. The additive showcase covers continuous rolling traffic.
Lessons 85–88 and `TestCompiledTodoComplexHistoryPostgres` additionally exercise
the V10–V13 transformations, retained readers/writers, worker backfill and
Contracts against the same app. The complex test checks requests at lifecycle
boundaries with overlapping versions; continuous traffic across transforming
rollouts remains an acceptance gap.

The maintainer also requires full-application scenarios: migrations are difficult
to learn if examples show only entities and row functions. Lessons 1–4 and 6 will
evolve the same runnable notes HTTP app. Each scenario will identify the changed
files, preserve application handlers/routes/codecs byte-for-byte where behavior is
unchanged, and run the same API assertions against the app before and after the
migration. PostgreSQL cases must retain existing rows through the actual executor;
starting a fresh Memory store is not evidence of migration compatibility. A
scenario that adds a derived value maintained by application writes must show the
necessary handler change and explain why it is necessary. Database connection
settings stay in the application; versioned schema and migration modules contain
no handlers or effects. These comparisons are regression assertions, not just prose.

The JSONB lesson also uses that app. It compares a representation-only codec
adapter with a typed record/ADT transformation under the same migration history.
It must demonstrate both reader/writer directions during a roll and an untouched
old JSON value surviving later deployments. Retiring an old binary does not prove
that its JSON representation is gone; decoder pruning requires final rewrite
evidence. The clarified rules are in the main roadmap's section 10. Integration
with the planner, backfill and pruning is pending.

The first part of [lesson82-database-migrations](../example/learn/lesson82-database-migrations.tesl)
now compiles and runs through `tesl test`: five direct tests cover schema-owned title
proofs, rejected writes, length boundaries, Unicode and missing rows. Its thin
schema root exports nothing and imports a child entity module; the application
owns the database declaration and effects. It is also a runnable notes HTTP app:
four API tests cover create/read, validation failure without insertion, malformed
JSON without insertion, and isolated test state. HTTP request/reply records and
codecs live in the application, separately from the stored entity. All three source files pass
agent-context and formatting. Generated Go snapshots and the manual lesson index
are included. Adoption and the remaining lessons are pending. The following lesson now tests
additive execution through the real PostgreSQL application path.

[Lesson83-additive-migrations](../example/learn/lesson83-additive-migrations.tesl)
now evolves a full PostgreSQL notes app. Its permanent regression copies the
lesson, compiles V1, generates and refreshes V2, and adds a nullable category plus
the corresponding field in the schema's pure constructor. It asserts the complete
application file stays byte-identical, runs both revisions' unit/API tests, deletes
source and build directories, and runs the standalone HTTP binaries. The operator
installer creates only control state; actual application boot performs the DDL.
The trace retains a V1 row through V2, runs both servers concurrently, checks both
writer/reader directions, and restarts V1 while V2 continues serving. Validation
and malformed-input failures leave no rows. This is an additive scenario; the
adoption, transformations and the other planned scenarios remain
pending. The lesson exposed a linter omission for bulk-insert input names, now
covered for both local bindings and function parameters.

## Slices under development

- Qualified schema families now accept `Schema.Todo.VCurrent` at
  `schema/todo/v-current.tesl`, with matching frozen and migration namespaces.
  Legacy `TodoSchema.*` remains supported as a separate source identity, never a
  spelling alias for already recorded history. The new compiler suite exercises
  three generated revisions, a private entity module and proof producer, Same
  evidence, concurrent-index emission, preserved application/snapshot bytes,
  frozen-source tampering, historical-import fixes and wrong-family refusal.
  Source rewrite and canonical-role tests include lowercase function names,
  qualified prefix boundaries, tabs, CRLF and interpolation. The todo example has
  been regenerated from its baseline under contract 3; its old sealed bytes were
  preserved separately, not relabelled. Each schema revision is now one file.
  Actual TextMate/Oniguruma tests cover contextual migration highlighting without
  changing ordinary identifiers. The full editor command passes, including real
  compiler/debugger fixtures and parser assertions.

- The control-format bridge now has exact format-2/3 definitions, an explicit
  transactional installer upgrade and protected index job/lease APIs. The upgrade
  preserves existing rows, lifecycle/source provenance, UUID and fence identity;
  real backend-kill tests cover both sides of its commit. Request observers verify
  finite registered index shapes without TEMP, distinguish pending plain indexes
  from uniqueness readiness, and independently check future indexes against old
  writer domains. The long-lived Worker executor now registers existing-table
  index jobs during expansion and executes CIC outside the startup deadline.
  Dedicated DDL and coordinator connections renew protected leases, retain a
  shared version fence, verify actual index progress before invalid-remnant
  cleanup, and recover with a new full execution identity after connection loss.
  Expired-holder cleanup locks and rechecks the exact lease before signalling
  only the same Worker login's exact old backend group; takeover waits for that
  group to disappear. Active external builds, valid indexes and unrecorded names
  are never dropped. Unique readiness needs both durable and physical success.
  Pure observers can inspect another ABI's pending expansion, while executors
  remain pinned to its creator ABI. The PostgreSQL 17 integrated race/tag gate
  passes (99.097s, no skips), including real backend kills, lease/renewal races,
  active independent CIC, catalog collisions and old/new request writes. Runtime
  lint is clean. Before the semantic-revision-3 correction, the authentic format-2 application fixture built and ran
  both old and bridge executables against retained rows, verifies atomic installer
  upgrade and retry after a lost acknowledgement, then verifies old binaries
  refuse format 3 (21.16s; package 22.182s). Two executor reviews found and fixed
  the valid-commit/renewal race and a post-failpoint ownership check. The current
  native gate uses three authentic compiler generations: format 2/contract 2,
  the historical format-3/contract-2 bridge, and current contract 4. Both archived
  emissions have closed source/file inventories; 34 tamper cases and package lint
  pass. The current native replay passes (36.33s), preserving the original
  contract and refusing to relabel old stored proofs. Embedded supervision is now implemented
  as described above; retirement/contract and feature-wide final reviews remain.

- The todo showcase now contains eight real CLI-generated migration edges across
  nine source revisions under `Schema.Todo`, with one schema file per revision.
  Its app, handlers, DTOs and tests are identical across all nine releases; replay
  preserves exact frozen source and actual creator provenance. Twelve published
  source/proxy/compiler-refusal tests pass, including actionable diagnostics when
  archived source is changed. Actual `tesl check`, `test`, `build --local` and
  `run` commands pass for V9 with separate worker/request logins, retained-data
  restart, CRUD/proof rejection and SQL default/NULL checks. Installing fresh V9
  is a command smoke, not evidence that earlier migration edges executed.
  The independent native race gate executes every edge through real load-balanced
  old/new writes: V4 worker death rolls back uncommitted table DDL, V8 pauses a
  real concurrent index behind an old writer and replaces its killed worker,
  and V1 restarts and writes after V9. It passes in 121.73s (package 122.758s).
  All releases use one copied actual compiler; source/build trees are removed
  before deployment. Two unchanged disk-backed attempts hit ordinary HTTP write
  timeouts before the next migration worker started, with PostgreSQL COMMIT up
  to 6.879s and host I/O pressure. The successful run uses an owned PostgreSQL
  17.10 cluster on tmpfs, private Unix sockets, and verified `fsync`,
  `synchronous_commit` and `full_page_writes` all on. Its three-second HTTP limit
  is unchanged. This proves process interruption/recovery, not physical host
  power-loss durability; the owned cluster was removed afterward.
  The preceding seven-release layout also passed the real local proxy walkthrough
  and retained-data restart. Elm assets compiled and were served, but no browser
  was available for interactive UI verification; that evidence is not a nine-roll
  UI walkthrough. Two script reviews corrected ambient PostgreSQL overrides and
  ensured probes drain before cluster shutdown. Typed transforms, JSONB evolution
  and lifecycle scenarios remain required before the showcase is complete.

- The separate Worker topology now has real PostgreSQL 17 and 18 coverage.
  Request startup verifies control and entity catalogs in read-only snapshots
  without CREATE or TEMP privilege; the worker owns expansion and grants entity
  DML atomically. The broad PostgreSQL 17 runtime gate passes (149.337s), followed
  by owner-isolation, credential, cancellation/restart and preflight regressions.
  The PostgreSQL 18 Worker/catalog gate passes (16.650s) and runtime lint reports
  zero issues. Two reviews found and corrected database-owner role reachability,
  unsupported durable-facility startup and executor identity-check ordering.
  Worker refuses queues, caches, email and SSE until their protected installation
  exists; this is not evidence authorizing epoch closure. The full-app lesson84
  race gate passes (24.87s): both compiled revisions run their unit/API tests,
  then standalone worker/request processes preserve rows with identical app bytes.
  Requests have no TEMP or namespace/public CREATE grants. The trace checks pending
  readiness, denied DDL/lifecycle calls, wrong identities and an old-binary restart.
  Compiler checks pass (190 cases plus the strengthened emission suite); actual
  lesson emission exposed and fixed a missing ADT import allowlist entry. Four
  source files pass formatting/agent-context, generated snapshots are included,
  traceability and documentation integrity pass, and integration-test lint is clean.
  Background jobs, heartbeat/reconnect supervision and deployment recipes remain.

- Main's September security fixes are merged, preserving source overlays and the
  bounded import scanner. A combined regression covers unsaved files/directories
  while refusing external symlinks. The stored-value semantic revision advances
  to 2 because proof-boundary checks changed; historical contract 1 is not silently
  accepted as equivalent. The merged-build A/B/C compiler-upgrade race scenario
  passes (68.93s), including retained rows, interrupted-expansion ABI refusal and
  recovery, and incompatible-contract refusal. Its isolated compiler fixture now
  copies regular documentation files rather than using symlinks, preserving the
  merged generator's source-boundary checks; integration-test lint reports zero
  issues. A deterministic editor test now covers
  both a supplied Nix toolchain and unavailable-Nix fallback without depending on
  the host's PostgreSQL environment. The full exact editor package command with
  default test isolation passes, including the parser assertions. Its DAP
  fixture uses an isolated Memory copy for debugger behavior; migration deployment
  evidence continues to use actual PostgreSQL binaries and retained data.

- Compiler upgrades now have a production full-app regression. It builds actual A,
  B and C compilers from one isolated source tree: B changes only query source;
  C changes the stored-value semantic revision. A authors V1–V3 including a completed
  V2 migration, B recompiles V3 and authors V4, and the complete lesson83 app and API
  assertions stay byte-identical. The test kills A after its intent commit, verifies
  that B refuses without mutation, lets A finish, serves both builds concurrently,
  restarts old A against V4, and checks retained rows, omission defaults and rejected
  invalid writes. B rejects tampered frozen schema/migration bytes; C rejects sealed
  compilation and database startup. Old source and protected creator provenance
  remain A's; only V4 records B. The native race regression passes (354.97s including
  three compiler builds). The source/compiler and runtime changes each received
  independent reviews; final integration review and broad gates are tracked
  separately. The lesson83 prose companion explains the scenario and limitations.

- The editor tooling now has a non-mutating migration-preview client that sends
  exact open-buffer bytes and versions to the compiler. Returned application,
  database, operation and content/version guards must match the request. Focused
  transport tests and a real compiler fixture pass, including virtual unsaved
  files and ambiguous target refusal. Cancellation cleans private transport files.
  Complete tooling/source-edit/LSP race suites, native CLI regressions and static
  gates pass. Follow-up review added exact overlay-content checks and prevented
  diagnostic-style handling from accepting a failed compiler process.
  The LSP now retains a bounded immutable preview and exposes per-file original/
  proposed contents. Focused real-compiler, cancellation, expired-handle, refusal
  and oversized-response regressions pass. Complete race suites, static gates and
  documentation checks pass; follow-up review tightened malformed-request handle
  expiry and bounded both raw and encoded diff sizes.
  The Change Schema UI and mixed open/closed source application remain pending.

- The LSP can now send bounded client requests and handle replies on its document
  event loop. Acknowledgements cannot overtake preceding document notifications;
  incoming and outgoing request identities are separate. Duplicate/late replies
  cannot complete another operation, and timeout/disconnect outcomes remain
  explicitly unknown. The response envelope rejects ambiguous identities and
  malformed errors. Full LSP/protocol race suites and static gates pass, and
  609,689 response-parser fuzz cases pass; the fuzzer is in CI. Follow-up review
  avoided copying whole notification buffers during reply classification.
  The read-only application planner now checks the complete open-input set and
  document lifetimes, retains every manifest guard, and prepares exact versioned
  forward/inverse edits. Focused tests cover stale dependencies, reopened files,
  Unicode/CRLF, caller mutation and preserving user edits during an inverse. A
  real compiler fixture freezes an unsaved migration buffer, creates a later
  revision in its preview and restores the exact buffer preimage in memory;
  the saved migration and application remain unchanged. Focused native tests and
  static gates and the complete LSP/tooling/source-edit race suites pass. It does not yet send
  migration edits or perform mixed source transactions.

- The source-edit package now provides a mixed transaction API with a version-2
  journal retaining the original compiler manifest and every open-buffer guard.
  Closed files publish under retained ownership; editor requests require a durable
  pending marker and commits require actual observed buffer versions and contents.
  Guarded restoration preserves unrelated user edits. Unknown client outcomes
  retain the journal and refuse automatic disk-only recovery. Fifteen process-exit
  checkpoints exercise preparation, publication, pending replies and terminal
  cleanup. Complete source-edit race tests and static checks pass after review,
  including closed-only proposals, cancellation and stale/missing acknowledgements.
  LSP application, editor reconciliation and the Change Schema UI remain pending.

- The merge of main's workspace navigation, search and standalone installation
  preserves the migration query endpoints and typed-node collection. Migration
  source rewriting now uses the lexer's interpolation byte provenance. Workspace
  rename respects frozen schema and completed migration ownership, including
  references from mutable declarations into frozen files. Focused compiler suites,
  complete LSP/tooling/source-edit race suites, native CLI/MCP/installation tests
  and static checks pass. The merged corpus inventory contains 212 sources.

- The LSP now provides `source.fixAll.tesl` to clients supporting versioned
  document edits. It rechecks current buffers, consumes producer eligibility,
  excludes decisions/commands, and returns only a guarded single-document edit.
  Conflict, compound-fix, Unicode and request-cancellation regressions pass.
  A real compiler fixture corrects both the historical import and its
  qualified schema use, checks idempotence and preserves the saved application.
  The complete LSP/tooling race suites, compiler diagnostic-protocol tests and
  static gates pass. The source-boundary fuzzer completed 1,363,010 cases without
  failure and is in CI. Follow-up review added shared source indexing, aggregate
  edit bounds, no-op suppression and cancellation coverage; those checks pass.
  Multi-file application and the Change Schema UI remain pending.

- The compiled binary now dispatches `--schema install --worker ROLE`. The
  history-bound installer chooses the current revision for a fresh database and
  verifies existing origin/source history inside its protected transaction. The
  native HTTP lesson invokes this command with a temporary, non-administrative
  installer login and then revokes its owner membership. Focused and broad
  control/status/crash regressions pass, including refused installation origins,
  fresh later origins, interrupted earlier baselines, source drift, login isolation
  and output failure. The complete standalone lesson, compiler checks, static
  gates, manual coherence and documentation integrity pass. Follow-up review
  found no further issue in this command. Adoption and role-script generation
  remain pending.

- Compiled applications now dispatch `--schema status` before their main or
  debug startup. Explicit database selection, JSON and human output, source
  mismatch reporting, cancellation and output failures have focused regression
  coverage. Status performs no expansion or adoption. The full HTTP lesson now
  invokes standalone status before installation completes, before V2 expands, and
  from V1 against V2; each observation leaves the database version unchanged.
  The status/control suites, native lesson, compiler entrypoint/embedding tests
  and static gates pass. Follow-up review verified that an origin-specific refusal
  remains visible in status while a different supported origin can boot. No
  further issue was found in this status slice.

- Versioned `WithDatabase` now runs the linked-history executor before publishing
  its pool. Failed initialization can retry after installation; revisions have
  distinct immutable pool bindings. Every physical pool or listener connection
  checks database identity, protocol and actual worker login. Writes hold their
  version fence through commit and then-current admission follows the lock in a
  separate statement; reads scan before admission and commit before returning.
  Queue claims/renewals and pub/sub operations use these gates too. Startup and
  admission tests cover retirement interleavings, caught refusals, pool-size-one
  transaction reuse, concurrent opens, retained rows, old-binary restarts,
  source/catalog/role drift and replacement connections. The complete migration
  gate and full runtime/CLI/tooling/LSP race suites pass; the latter has no skips.
  Compiler configuration tests and runtime static gates pass. The full compiler
  run passes all 220 test groups; the affected native catalog/storage/expansion
  and lesson tests pass after rebuilding it. Documentation integrity passes. The independent
  phase-0 storage/codec fixtures explicitly use unversioned application connections,
  because they do not represent production migration history; actual compiled
  history tests remain versioned and refuse uninstalled storage. `--schema status` is now available; installation/adoption commands,
  heartbeat/readiness, worker topology and later phases remain pending.


- Production control installation and additive execution now consume linked
  compiler history. The installer protects role ownership, catalog definitions,
  grants and immutable installation provenance. The executor validates recorded
  source/ABI/step identities, holds the session boot lock, and commits each DDL
  operation with its progress record after comparing the uncommitted catalog.
  Retained-row tests cover defaults, nullable additions, old writers and restarts,
  late origins, lookalike refusal and recorded drift. Twenty-two backend-death
  boundaries and ten concurrent executors pass. Actual compiler-built V1–V3
  binaries execute after deleting sources and sidecars. Review found PostgreSQL's
  integer rendering of numeric defaults prevented old-binary restarts; comparison
  now preserves the original integer range before widening. It also added actual
  worker-login checks. The combined control and executor suites pass PostgreSQL 14–18. Additional
  regressions cover DDL lock timeout with retained old writes, empty-schema
  installation, pre-canceled entry and refusal before installation. The expanded
  constant fuzzer passed 209,411 executions across text, numeric, integer, float
  and boolean inputs. Complete runtime, native CLI, tooling and LSP race suites
  pass against PostgreSQL with no skips; vet, staticcheck, tagged lint, gosec,
  nilaway, compiler embedding, native catalog regressions, manual coherence and
  documentation integrity pass. Follow-up review found no further issue in this
  installer and additive-executor slice. [Execution details](migration-execution.md)
  distinguish the implemented startup/admission path from pending schema commands
  and later migration phases. No delivery row above
  is complete.

- Transaction routing now retains the owning opened database as well as the
  goroutine. Cross-database queries, writes, pub/sub and nested database scopes
  refuse before SQL or bootstrap; nested transactions refuse before borrowing a
  second connection. A live two-database regression proves that the attempted
  cross-server write is rejected, the caller's prior write rolls back, and the
  other server is unchanged. It also verifies recovery and nested refusal with a
  one-connection pool. The full runtime race suite passes all 640 test groups
  against PostgreSQL, with no skips. Debugger regressions, embedding checks, vet,
  staticcheck, lint, gosec, nilaway, manual coherence and documentation integrity
  pass. Follow-up review found no further issue in the routing fix. This fixes a
  pre-existing defect; the versioned startup and admission slice above now builds
  on that owning-connection routing.

- Compiled histories now use compact format 2. The runtime validates every
  connection and installation origin, reconstructs catalogs from ordered
  operations, checks physical contracts and independently recomputes each
  `stepHash`. Source previews retain full catalogs. Step identities survive
  connection renaming and appended revisions but include omission defaults and
  installation-specific storage. Thirty-three compiler plan groups and twelve
  build groups pass, including cross-language golden vectors for every operation
  and supported constant. Runtime tests cover malformed and incomplete histories,
  explicit origin refusals, invalid physical histories with recomputed hashes,
  exact Unicode decoding, and independent concurrent readers. A native V1–V3
  application compares every reconstructed catalog and identity with its source
  preview; the standalone binary and PostgreSQL storage fixture also consume the
  linked plan after the JSON sidecar is removed. Review added rejection of lossy
  Unicode decoding. The strengthened fuzzer passed 201,057 executions and is in
  CI. Complete runtime/CLI/tooling/LSP race suites, embedding checks, vet,
  staticcheck, lint, gosec, nilaway, manual coherence and documentation integrity
  pass. Follow-up review found no further issue in this input boundary. The
  production executor must still bind this source plan to trusted control state,
  installation provenance, ownership and permanent transaction admission.

- Versioned PostgreSQL Go builds now produce `migration-history.json`, containing
  every reachable connection's checked history and every installation-origin
  variant. `Migration_selection` shares target discovery and source guards without
  depending on the compiler driver. Builds pin captured application/history bytes
  and actual stdlib resources, check the complete application through Go emission,
  verify the emitted bindings, then recheck source, disk, imports and discovery.
  Review added protection against temporary saved-byte changes and explicit
  origin-specific refusals instead of empty plans. Twelve build regression groups
  pass, including new unsaved entry files, imported connection owners, frozen edits
  and stable prior steps. Twenty-seven manifest groups and the existing planning,
  selection, preview, command and application suites pass. The native CLI compiles
  V1–V3 and compares every transported origin with its source plan. Complete
  CLI/tooling/LSP race suites, the compiled PostgreSQL storage round-trip, vet,
  staticcheck, lint, manual coherence and documentation integrity pass. The fresh
  full compiler gate passes all 220 suite groups. Follow-up review found no further
  issue in this slice. Boot admission and execution remain pending.

  The same artifact is now linked into standalone Go binaries and bound to the
  application-owned connection. Read-only inspection returns an immutable copy;
  missing, conflicting and namespace-mismatched registrations refuse. Four runtime
  groups pass under the race detector. An executable imported-connection regression
  removes the source tree and JSON sidecar before reading its history; the compiled
  PostgreSQL storage fixture also runs with the sidecar removed. Review found and
  fixed loss of the family reference during schema lowering by passing the checked
  binding explicitly to the emitter. Twelve compiler build groups, runtime
  embedding checks, native V1–V3 transport, vet, staticcheck, lint, gosec and nilaway
  pass. Complete runtime/CLI/tooling/LSP race suites, manual coherence and
  documentation integrity pass. The full compiler gate again passes all 220 suite
  groups. Follow-up review found no additional issue in the linking change. The
  linked information does not yet enforce admission or execute migrations.

- Diagnostic protocol 2 now carries related source locations, documentation links,
  compiler-owned action classes, explicit confirmation, and separate fix-all
  eligibility. Version 1 keeps its existing bytes and diagnostic hints. The LSP
  publishes cross-file links using each file's unsaved bytes for UTF-16 conversion;
  retained sessions invalidate when an implicit frozen-history dependency changes.
  Decision actions cannot become ordinary quick fixes. Six compiler regression
  groups and the complete LSP/tooling/native CLI race suites pass. Review found
  duplicate-key interpretation differences between exact JSON maps and Go struct
  decoding; the transport now rejects ASCII and Unicode case-fold collisions as
  well as escaped duplicates. The strengthened fuzzer checks interpretation
  agreement and completed 205,284 executions without failure. Vet, staticcheck,
  lint, gosec, nilaway, manual coherence and documentation integrity pass. The full
  compiler gate passes all 219 suite groups. Follow-up review found no additional
  issue in this slice. The Change Schema command, general fix-all provider and
  phase-3 typed-hole workflow remain pending.

- Read-only source plans now take `--initial-version N` and derive storage from the
  database's first installation revision. They still validate every source edge
  from V1. Later installations omit earlier dropped tables and omission defaults;
  a reintroduced index is rebuilt when it did not exist at installation, with
  fresh compatibility and relation-name collision checks. The plan hash binds the
  selected origin. Twenty-nine compiler plan regression groups pass, including
  late-origin refusal of edited frozen history and invalid earlier defaults. The
  complete native CLI race suite passes with every valid origin through V3 and
  unchanged application files. Review added an origin-specific index collision
  witness; follow-up review found no further issue. The full compiler gate passed
  217 groups; its remaining SSE listener test passed on rerun with local socket
  access. Vet, staticcheck and lint pass. This remains read-only source planning;
  the executor must obtain installation identity from trusted control state.
  The current compiled row executor starts from V1 and does not execute these
  alternate-origin previews.
  Physical derivation is now shared through `Migration_expansion`, independent
  of the compiler driver. Thirty plan regression groups pass, including rejection
  of swapped/missing edges and mixed ABI inventories, and stable canonical prior
  steps across source freezing. The command suite and native CLI planning race
  regression also pass after extraction. Runtime metadata and execution remain
  pending.

- Frozen-source formatting is protected in the compiler, native CLI and LSP.
  Numbered schema snapshots and completed migration namespaces retain their
  exact bytes, including private helpers and symlink aliases. The editor uses
  a read-only formatting query over all open buffers, so unsaved sibling
  snapshots and completed roots protect helpers before saving. It bypasses
  retained-query caching until sibling ownership dependencies are represented
  there. Nine compiler regression groups and the existing formatter suite pass;
  native generation/freezing/format/refusal/refresh and real LSP/compiler tests
  pass. Review replaced a marker-text heuristic with the existing closure
  metadata reader and added host rejection of a read-only response that changes
  source bytes. Complete LSP, tooling and native CLI race suites pass, alongside
  vet, staticcheck, lint, gosec and nilaway. The fresh full compiler gate passes
  all 218 suite groups; follow-up review found no additional issue in this slice.
  This prevents accidental formatting edits and does not replace source-seal or
  persisted-history checks. The Change Schema editor lifecycle remains pending.

- Live catalog inspection now compares compiler-derived physical projections
  with PostgreSQL metadata. Every source-plan revision carries its retained
  tables, columns, installed defaults and allocated index names. The runtime uses
  same-server temporary comparison objects and canonical expression rendering;
  physical column ordinals and equivalent index/constraint names do not change
  its fingerprint. Extra columns pass only through a closed literal/type/typmod
  classifier which never evaluates computing defaults or writes application
  rows. Twelve PostgreSQL regression groups pass on every supported major,
  14–18, including invalid concurrent indexes, ownership, RLS, constraints,
  triggers, rules, partitioning/inheritance, custom casts, session settings,
  cancellation, missing objects and caller-owned temporary tables. Review fixed
  numeric default spelling, fingerprint normalization and session-dependent
  rendering. The literal fuzzer completed 53,210 executions without failure and
  is registered in CI. Native V1–V3 generation/plan tests verify the transport of
  each physical projection. A compiled PostgreSQL application matches its actual
  compiler plan and retains Unicode and integer boundary values after inspection.
  Unit/race checks, embedding/file gates, vet, staticcheck, lint, gosec and nilaway
  pass. The fresh full compiler gate passes all 217 suite groups. Follow-up review
  found no additional issue in this slice. This is catalog observation, not
  execution: missing recorded storage, lookalike objects and ABI/history mismatches
  still require the pending executor's provenance and ownership decisions.
  Bootstrap, admission, expansion and all delivery rows above remain pending.

- Read-only PostgreSQL source expansion plans are connected to `tesl migrate
  plan`. The selected complete application must pass Go emission; every adjacent
  declaration and required source seal is checked. The storage mapping preserves
  semantic/ABI identity, typed defaults, private entities and JSONB dependencies.
  Plans retain dropped tables/indexes, refuse retained-name reuse, classify
  admitted-writer index risks and never authorize execution. Twenty-six plan
  regression groups and eleven storage groups pass. Review exposed and fixed an
  emitter bug choosing integer storage for an application-owned `Int32 = String`;
  an isolated compiled PostgreSQL race test now verifies actual column types and
  round-trips text plus built-in integer bounds. The complete native CLI and source
  writer race suites pass, including native generate/refresh/plan through V1–V3
  with an unchanged connection owner. Multi-revision planning also exposed a V3
  refresh deadlock on its stale current seal: completed bodies now check in the
  proposed refreshed view after their frozen seals pass, with regression coverage
  for valid changes, new holes and refusal of old-byte tampering. Review also added
  retained-index write restrictions and prevented repeated removal operations in
  unchanged later revisions. The fresh full compiler gate passes all 217 suite
  groups; manual coherence and documentation integrity pass. All compiled
  PostgreSQL fixtures pass under the race detector with the updated compiler.
  Vet, staticcheck, lint, gosec and nilaway pass; the follow-up review found no
  additional issue in this slice. See [migration planning](migration-planning.md) for the protocol and
  bounded storage/index support. Live catalog comparison, persisted ABI/admission,
  the executor and the remaining delivery gates are still pending.

- Guarded saved-source publication is now connected to the native CLI's plain
  `migrate generate`, with explicit `migrate recover-source` for interrupted writes.
  The compiler remains the sole producer of edits. The Go consumer strictly
  validates its protocol, independently checks source/discovery guards, preserves
  racing saves through retained inodes, and uses durable prepared/committed/restored
  outcomes for restart recovery. Review closed foreign-directory ownership,
  unfinished-state/no-op refresh, unsaved directory-view, and bounded compiler-output
  gaps. Real compiler/native CLI lifecycle and decision-hole regressions pass;
  publication, inverse and cleanup process-exit tests pass under the race detector.
  The full compiler gate passes all 215 suite groups, followed by manual coherence
  and documentation integrity. The complete native CLI and source consumer suites
  pass under the race detector; vet, staticcheck, lint, gosec and nilaway pass.
  Native CLI builds also cross-compile for Windows and macOS (mutation there still
  refuses). The real native writer generated/refreshed/completed the notes app's
  source history: all generated files passed agent-context, the full application
  stayed byte-identical, its five direct/four API tests passed before and after,
  and a changed frozen helper refused with MIG013. Follow-up review added
  no-replace inverse capture, pre-journal failure/process-exit, old-file-handle
  saves, inverse save races and redirected-source recovery regressions. That race
  suite passes with 80.3% aggregate source-consumer statement coverage; uncovered
  statements include filesystem-error paths and are not claimed as verified.
  Fuzz runs completed 297,356 and 193,095 executions without failure, and the
  manifest fuzzer is now registered in the repository CI gate. See
  [source write design](migration-source-writes.md). Linux mutation is implemented;
  other platforms, editor lifecycle and production database execution are pending.

- Public non-mutating source previews now use the executing compiler's build and
  captured lifted-stdlib identity, with resource bytes/resolution pinned throughout
  generation. `tesl migrate generate <entry> --manifest-json` checks the complete
  proposed app, exposes `compilable` separately from preview success, refreshes by
  default and accepts explicit `--new-revision`. It supports guarded editor buffers
  and virtual entries. Review closed a nested-schema selection gap: the source
  actually imported by the connection must match the discovered history root.
  Focused ABI (21), preview (10), target (22) and command (12) groups pass, including
  a real compiler process; the complete native CLI suite passes with its required
  local listeners. The full compiler gate passes all 215 suite groups, followed by
  manual coherence and documentation integrity. A real CLI consumer generated,
  refreshed and completed revisions in a disposable full-app project; every source
  passed agent-context, a changed frozen helper refused with MIG013 in both helper
  and app, and all five direct/four API tests passed with byte-identical app source.
  Follow-up review found no additional issue in this slice.
  This is source integration, not a persisted execution ABI or a physical plan.
  The source writer is tracked above; editor lifecycle and the production
  executor remain pending.

- Completed migration source now has an independent raw closure seal. Starting
  the next revision retargets source before sealing the root, its schema metadata
  and all transitive private helpers. Current references, changed bytes, missing
  metadata and changed import resolution refuse. Direct/private/unsaved queries,
  application builds and start/refresh enforce these records; unchanged shared
  helpers remain reusable. Source records are not the persisted runtime backstop.
  Twenty-seven closure regression groups pass. Review found and closed a direct
  helper-query bypass when a metadata member was removed; membership is now
  validated before it can select queries. All 212 groups in the fresh compiler
  gate pass, followed by manual coherence and documentation integrity. A fresh
  independent CLI scenario generated successive revisions with a private helper,
  rejected a valid typed helper edit in both helper and full app with MIG013, and
  passed the unchanged app’s five direct and four API tests after restoration.
  The application remained byte-identical; this is source integration using
  Memory, not PostgreSQL migration execution.

- Application checking now follows a database’s declared migration history even
  without ordinary imports of migration modules. A full-app CLI probe exposed
  the previous gap: MIG003 in the migration did not prevent the app from checking.
  The shared frontend now checks current/completed migration bodies and private
  helpers, requires recorded schema seals, preserves application name boundaries,
  and refuses missing history. Regressions cover Go emission, imported owners,
  independent families, shared imports, unsaved edits, whole-snapshot editor
  sessions and ordinary application types. Source checking does not constitute
  runtime migration execution. All twenty-four application dependency groups pass,
  followed by all 211 groups in the complete compiler gate. The original real CLI
  reproduction now refuses both files with MIG003; restoring the migration passes
  every source query and the unchanged app’s five direct and four API tests.
  Manual coherence, documentation integrity and the follow-up review pass.

- Explicit application target resolution now finds the connection owner through
  the import graph and infers only a single database. Nineteen regression groups
  cover qualified/ambiguous names, imported owners, legacy/invalid ownership,
  unsaved/virtual applications, stale selections, changed imports, malformed and
  special files, and shared/cyclic dependencies. Target-bound start/refresh retain
  the application guards in their manifests. Composition adds six groups (26
  manifest groups total) for stale source/disk/document/discovery inputs and
  conflicting operations; it never re-captures a changed selection. Focused target,
  manifest, generation and refresh gates pass. The fresh complete compiler gate
  passes all 210 suite groups; manual coherence and documentation integrity pass.
  An independent JSON consumer exercised start, refresh and another start on a
  disposable copy of the full lesson 82 app. All generated files passed the real
  CLI's agent-context, saved hashes matched, and the full app stayed byte-identical.
  Its five direct and four API tests passed before and after. This is source
  integration with Memory, not PostgreSQL row migration through an executor.
  Workspace entry discovery/preferences, public CLI/editor transport, complete
  application diagnostics and atomic apply/recovery remain pending.
- JSONB design review identified a further rolling-compatibility obligation:
  decoder-compatible wire changes can change equality predicates and indexes for
  admitted builds. Section 10 now requires preserving SQL behavior and describes
  separate physical storage as the conservative transforming path. A generation
  marker also cannot prove new representation if current writers emit old wire
  data. The compiled codec oracle now pins the equality counterexample with actual
  PostgreSQL predicates before/after a bridge rewrite; planner/query adaptation is
  still pending. The fresh compiled PostgreSQL regression passes under the race
  detector, and its traceability map is regenerated.
- Initial source refresh now returns guarded previews with full compiler
  diagnostics. It verifies frozen history, updates the undeployed target seal,
  rechecks generated Same claims, and reconciles individual entity entries while
  retaining handwritten rules, helpers, tests and comments. Automatic entries are
  limited to New, Drop and checked additive adapters; remaining decisions emit
  compile-blocking MIG003 placeholders. Deliberate Same omissions are retained.
  Review caught a Same shared by record/codec namespaces needing all namespaces
  checked, duplicate diagnostics for the same dependency, and edited entity aliases
  needing ownership protection. Source merge has twelve regression groups; refresh
  has nineteen, and declaration checking has twenty-two including placeholder
  imports and backend refusal. Focused checks pass, followed by the fresh complete
  compiler gate: all 209 suite groups pass. Manual coherence and documentation
  integrity also pass.
  Public CLI/editor target resolution, atomic apply/recovery, general row functions
  and the production planner/executor remain unfinished.
- Refresh ownership now has precise source ranges and generated-node markers.
  Thirteen syntax groups cover raw literal spellings, diagnostic-span overreach,
  comments/separators, Unicode/tabs/CRLF, stale AST identities and overlapping edits.
  Twelve provenance groups protect edited bodies, added comments and existing line
  tails; matching annotations remain stable under formatting and target freezing.
  The starter annotates its Same claims, with integration assertions before and
  after finalization. The sparse checker now exposes checked requirements before
  entry selection; its fifteen groups retain every stored occurrence and reject
  invalid identity claims without placeholder entries. Public commands remain
  pending. Focused syntax, provenance, sparse, additive,
  declaration and generation suites pass. The fresh full compiler gate passes all
  207 suite groups; manual coherence and documentation integrity also pass.
- Revision starting now builds a checked, non-mutating source manifest: freeze
  the complete current closure, retarget the existing migration and unshared
  helpers, recreate its target seal, and create the next initially unchanged
  migration. Fourteen regression groups cover successive revisions, private
  records/codecs/facts, unsaved sources, preserved user tests/comments, selected
  version drift, ABI refusal and concurrent creation. Review caught preexisting
  equal frozen helpers omitted from the edit list; their bytes are now guarded as
  inputs. A helper shared with completed history is refused if retargeting would
  modify that history. Target resolution, refresh/provenance, migration-closure
  freezing, actual build ABI identity, public CLI/editor commands and application
  of the manifest remain pending. This preview is not a physical execution plan.
  An independent JSON consumer materialized two successive previews in a disposable
  project: every emitted file passed the real CLI's agent-context, disk hashes
  matched, and the application database module stayed byte-identical. The fresh
  full compiler gate for generation and manifests passes all 205 suite groups;
  manual coherence and documentation integrity also pass.
- The source edit manifest captures independent saved/source hashes, editor
  versions, directory membership and import resolution. Twenty regression groups
  cover missing versus empty paths, raw byte preservation through JSON, output
  conflicts, private dependencies, stale documents, symlinks/special files, and
  proposed versus saved imports. Review found that an existing dangling import
  candidate can become resolvable without changing previously read files or their
  parent membership; explicit import preconditions close that gap. The resolver
  uses the same algorithm for disk and source views. A complete private schema
  freeze is type-checked in the proposed view without writing its files. The
  manifest's apply/recovery protocol and public transport remain pending.
- Snapshot source seals and migration history headers now have separate integrity
  and semantic checks. Fifteen seal regression groups cover complete private
  closures, raw-byte edits, malformed/forged metadata, stale inputs, canonical paths,
  same-ABI semantics and distinct ABI refusals. Twenty-one header groups check public
  MIG001/MIG013 diagnostics, imported and unsaved headers, current versus frozen
  changes, formatting and replacing the target seal at the next freeze. Direct
  schema queries, application imports and private-only imports enforce the recorded
  hashes, including malformed source, changed module names, missing roots and
  non-regular files. Review found and closed gaps in direct-query coverage and
  metadata path validation; imported declarations do not duplicate diagnostics or
  re-read stale saved headers over unsaved edits. A decoded
  header cannot skip type/proof checks or assert persisted database history. The
  declaration result retains optional source-integrity evidence; mandatory sealed
  history, public generator integration, build ABI identity and runtime checks remain pending.
  Focused seal/header/source-view/declaration suites pass. The fresh full compiler
  gate for these integrations passes all 203 suite groups. Manual coherence and
  documentation integrity also pass. A real CLI probe caught an additional
  parse-error path in agent-context that omitted integrity diagnostics; checking,
  agent-context and Go emission now share that path and its regression assertions.
- Read-only source views now reach import resolution, the full type/proof/validation
  pipeline, migration inventories, history discovery and freeze proposals. Proposed
  files and directories remain entirely in memory. Nineteen regression groups cover
  raw bytes, nested/exceptional scopes, private dependencies, changed proof contracts
  and fact producers, transitive effects, cycles, stale guards, filesystem aliases,
  and differential checking against saved files. Review caught a symlink alias being
  reported as a regular freeze target; source-view `kind` now retains `lstat`
  semantics. A malformed imported-buffer test also exposed lexer failures being
  attributed to the importer; the parser now preserves the actual failing file.
  The public manifest CLI, document-version guards and editor apply/undo remain
  pending. The full compiler gate for this integration passes all 201 suite groups;
  manual coherence and documentation integrity also pass.
- The initial contextual Migration declaration now reaches `Compile.check_source`
  and the CLI. It validates adjacent checked schemas, private entity keys, sparse
  coverage, Same and literal defaults; context-only constants have no runtime value
  or exported binding. A real three-file CLI probe passes `agent-context`. Twenty
  regression groups cover imports, source locations, unsaved migration buffers,
  retained query state, complete-record defaults, formatting, pure helper execution
  in generated Go, and refusal cases. Review exposed and fixed boolean literal
  handling, `Entity(..)` emission, contextual field names being mistaken for effects,
  missing migration roots and constructor import visibility. A subsequent review
  caught nominal ADT constructors called True/False being mistaken for primitive
  Bool defaults. Defaults now resolve their constructor ownership; local and imported
  lookalikes refuse, while qualified-only imports do not shadow primitive literals.
  Contextual import groups are also separate from ordinary runtime ADT groups, so
  the existing constructor/exhaustiveness gates retain their full checks. The twenty
  declaration groups and affected constructor/stdlib gates pass. The subsequent
  complete compiler gate passes all 200 suite groups; manual coherence and
  documentation integrity also pass. This is still source checking and logical adaptation: frozen seals,
  persisted ABI identity, physical plans, execution and transformation forms remain
  pending.
- The shared frontend extraction passed all 199 compiler suite groups. Review
  verified every moved definition byte-for-byte against the pre-refactor source.
  `Frontend_check` now supplies the same type/proof/validation judgment to ordinary
  compilation and schema inventories. The later contextual extension also passes its own complete gate (200 groups).
- The complete compiler gate passes 199 suite groups with sparse coverage and
  additive row projection included. Manual coherence and documentation integrity
  pass. A subsequent review found the roadmap claiming that adding a Maybe field
  requires no application edits; the CLI proves that an unchanged current record
  literal instead gets T001 for the new field. The roadmap and manual now separate
  migration adapters from current writes. The explicit-construction regression passes,
  including its generated Go test. Neither feature-wide review is
  complete.
- The initial additive row projection now derives one value source per field
  from the inventories bound into sparse coverage. It handles new proof-free
  Maybe fields and exact primitive defaults, rejects changed existing contracts,
  field removals, table/primary-key changes and invented proofs, and keeps index
  changes visible for later classification. Fourteen regression groups
  pass, including cross-type defaults, arbitrary-precision integers, non-finite
  floats, JSONB containing facts, nominal optional-type refusals and one changed
  entity among 300. These are logical adapters,
  not SQL/executor integration; nominal/Money defaults and physical catalog,
  all-version index safety and admission checks remain pending.
- Sparse migration coverage now re-verifies explicit Same pairs and requires
  every changed owned entity to have exactly one appropriate entry. Omitting an
  equal fact/type/codec pair forces revalidation at every stored occurrence;
  an enclosing record's Same cannot conceal a missing child pair. Fourteen
  regression groups cover nested/optional/generic/recursive JSONB types, direct
  field proofs, private entity aliases, stale/duplicate identities, table/index
  changes and 300 independent occurrences. The affected inventory, equality,
  field/entity impact and history suites pass. This is the coverage checker;
  transformation source elaboration and execution remain pending.
- The checked inventory now verifies compiler-local `Same` equality and proposes
  equal type/fact/codec pairs, including private declarations. Comparisons use the
  full canonical tree, preserve nominal identity and report the first differing
  dependency with both source locations. Fifteen regression groups cover private
  validators, added/removed producers, encoder and legacy-decoder changes,
  recursive/generic ADTs, source invariance, ABI/family refusals and retained editor
  caches. This is the equality component; it grants no permission to cast persisted
  proofs. Runtime ABI evidence remains required.
- Entity impact now covers complete owned tables as well as individual fields.
  Ten regression groups require table, primary-key and index changes to surface
  when every field remains equal, preserve private module identities, follow
  transitive proof/JSONB dependencies and keep 299 unaffected entities folded out
  when one of 300 changes. Additions/removals and empty schemas retain the same
  ABI/family checks. Online classification remains pending.
- Reviewing the equality boundary exposed a fact-ownership bypass: an application
  could establish a schema's multi-argument `Fact (InBounds 1 100 n)` and compile
  with zero diagnostics. The core ownership check now traverses the complete
  predicate under both `Fact` and `Maybe (Fact ...)`; qualified compiler AST names
  also require the declaring module. Nine regression groups cover applications,
  migration revisions, sibling schema modules, ordinary libraries, several arities,
  valid owning validators and forwarding of proof-carrying values. The reproducer
  failed the new regression before the fix. The focused type/proof and inventory
  suites pass; full-gate and feature-wide reviews are still required.
- Main's retained compiler query sessions and native editor tooling are integrated.
  Typed migration IR collection bypasses metadata-only cache hits so it records
  the exact checked AST identities; saved inventories clear semantic query state
  between dependency snapshots. Pure migrations may import old/current views with
  matching physical index names, while each schema still rejects its own index
  collisions. The merged compiler gate passed 194 suite groups before the final
  index fix; focused index/import/IR/inventory suites and the editor race/lint gates
  passed afterward. Subsequent implementation changes require a fresh full gate.
- Saved-source history discovery now derives `VCurrent`'s version and loads every
  consecutive frozen schema through the checked semantic inventory. It records
  raw-byte guards for private schema dependencies and transitive migration helpers,
  including import diamonds and cycles. Missing intermediate snapshots/migrations,
  invalid version numbering, noncanonical paths, symlinks, special files and local
  import shadowing refuse discovery. Rechecking an inventory also checks revision
  directory membership and import resolution, so adding a shadowing source file
  cannot redirect an existing import silently. Fifteen regression groups pass.
  This is an internal saved-source API, not the public generator or editor overlay
  API: migration modules are parsed and checked for ownership and declaration
  purity, but their records/types and amendment files still need elaboration.
  Frozen-header verification, prune evidence and atomic manifest application remain
  pending. Discovery failures retain their own categories; a schema type error is
  not mislabeled as MIG013 edited-history evidence.
- Ordinary application modules and their imported libraries now reject historical
  schema imports with MIG015, including nested modules and unsaved buffers.
  Adding a test block grants no exception. Pure tests are permitted in migration
  modules as the roadmap specifies; capability declarations, connection selection
  and implicit effects are rejected. The multi-version nominal-type regression
  now runs in a migration test module instead of an ordinary application. The
  focused import suite and diagnostic registry pass. MIG015 now carries a single
  source-verified action for the import, qualified types and qualified expressions,
  including interpolations. It shares the frozen-copy token walk and preserves
  comments, literals, Unicode, tabs and CRLF. Tests check the unsaved buffer even
  when the file does not exist, and applying the action produces a valid application.
  Generated compatibility-store authority and the versioned diagnostic metadata
  protocol remain pending.
- Recursive ADT JSONB emission now reserves recursive decoder names, boxes decoded
  self-fields and unwraps them during encoding. Recursive encoders use a forwarder
  without changing nonrecursive helper names. Explicit `adtJson` codecs now retain
  constructor payloads and check their children. The regression executes recursive
  HTTP responses, codec round trips, raw SQL scans and invalid nested inputs using
  both flat and boxed Go layouts. It also found structural OCaml type equality in
  `expect`, which failed on recursive types; that site now uses nominal type equality.
  The complete compiler suite and tracked corpus build pass for this slice.
  A second review found imported boxed payload types losing their declaring package,
  explicit forbidden ADT codec directions being bypassed, and generic columns losing
  their type arguments. These are fixed. The expanded matrix keeps different
  instantiations separate within one row and through nested/optional fields; it also
  checks imported boxed constructors, single-constructor values and tagless runtime
  tuples. A generic boxed comparison exposed an unguarded inactive payload access;
  its disjunction now stays inside the tag guard. All 17 JSONB regression groups
  pass, including emitted HTTP responses, raw scanner refusals and Memory round trips.
  The codec-direction check also walks nested generic arguments before its nominal
  recursion guard; forbidden codecs cannot hide behind `Envelope (Envelope State)`.
  Explicit codecs on generic ADT declarations and additional container payloads still
  require dedicated coverage and implementation; this does not certify every ADT shape.
- A full root CI run exposed failures in NilAway, generated-file synchronization,
  documentation count checks, corpus inventory and clean installation. Model clone
  maps now remain writable when empty, and repair/registry tests establish their
  non-nil inputs explicitly. NilAway and the subsequent model race run pass.
  The documentation counts and corpus inventory are corrected. The clean-install
  failure came from Go probing an incomplete parent `.git` above generated output;
  container builds disable automatic VCS stamping and keep the explicit image source
  revision. The scrubbed-environment regression creates that condition and passes.
  The subsequent committed-tree root CI run passed 22 of 23 phases, including the
  full compiler suite, exact snapshots, shipped clean installation and browser tests.
  Its migration harness failed during database setup; the other runtime static-analysis
  checks and all five skipped fuzz targets subsequently passed. Both timed-out cases
  pass in isolation, and the complete PostgreSQL 17 suite passes in 79 seconds with
  poolers, replica and owned-cluster crash cases. The setup failure is intermittent;
  its cause has not been established. SQL failures now dump activity, blockers and
  transaction/query start times, and a failed private-cluster run preserves the full
  server log with slow-statement and lock-wait diagnostics. Timeouts and durability
  settings are unchanged. A later full compiler run passed the language/runtime
  suites but exposed stale Dune input in the suite-registration meta-test: its
  copied configuration omitted newly registered suites. The test now declares its
  configuration and test-file dependencies, and its focused gate passes. The
  expanded compiler slices require the next full gate;
  neither feature-wide review is complete.

- The deterministic scheduler, independent model, real control-template tests,
  and compiled V7/V8/V9 process oracle run against disposable PostgreSQL 17.
  The process oracle explicitly prepares its catalog; it is not the production
  migration executor. Release binaries are checked for absence of test controls.
- An independent bootstrap catalog model now compares first-install state with
  PostgreSQL after each committed object and lifecycle step. V8/V9 races cover
  every partial-install crash boundary, a lease expiring while its backend still
  holds the boot lock, a newer executor finishing the persisted target, equal
  recorder retries, and death before/after the initial history commit. A V8 winner
  permits additive V9 expansion; a V9 winner never invents V8 history. The fixture
  creates application objects as the worker role and checks their actual types,
  nullability, primary key, defaults and ownership. The production installer and
  control-format upgrade recovery remain pending.
- The reference model now includes append-only repair chains, prefix-compatible
  admission, whole-chain executor checks, ordered repairs of rejected rows only,
  and quarantine revision/reason checks after retirement aborts. Symbolic row
  function results exercise protocol decisions; they do not replace generated
  Tesl transformation tests. PostgreSQL repair-history traces compare every
  success, refusal, rollback and persisted chain against the separate model.
  Those traces found the normative recorder accepting an empty repair hash; the
  recorder now refuses an empty artefact identity before writing history.
- Index model cases distinguish catalog validity, active server statements,
  scheduling leases and shared DDL-job locks. Actual PostgreSQL builds are paused
  by an existing writer while a lease expires and a successor arrives. A successful
  build is retained; a terminated build leaves an invalid remnant that is rebuilt.
  Contract waits for catalog verification and records terminal before dropping,
  including coordinator death between those steps and a surviving stale worker.
  Creation, executor-admission and removal versions are distinct: a V9 worker can
  finish a V8 index while V8 retires, and a V9 removal waits for V9's plan switch.
  The model and actual PostgreSQL case cover those boundaries. The control fixture
  persists `terminal_version`; recovery refuses a changed removal target before
  updating any job or dropping an object. These cases caught the model incorrectly
  using the creating version for both the worker fence and the contract target.
  These remain protocol fixtures, not the production index executor. Nightly
  model traces run eight times the per-PR trace length with recorded seeds.
  A deterministic first-scan pause also lets an old writer insert a duplicate;
  PostgreSQL then leaves a ready-but-invalid unique index after validation fails.
  The test proves that it rejects further duplicate writes until the remnant is
  dropped, pinning the documented rolling-deployment risk independently of readiness.
- A machine-checked harness inventory now maps registered `INV-*`/`TR-*` IDs to
  model guards/operations, actual test declarations, named test events and configured
  PostgreSQL lanes. It rejects unmapped operations, untested transitions, tests with
  no invariant, duplicate definitions and incorrectly labelled direct database tests.
  It currently covers 54 invariants, 57 transitions and 81 top-level test declarations.
  This is explicitly a kernel inventory with uncovered scopes listed in the generated
  report; the complete normative inventory and production path mapping are still pending.
- The control bootstrap now has one executable SQL fixture under the harness's
  `testdata/`. Its documentation sync gate renders the exact transaction into a
  marked region of the normative roadmap, refusing ambiguous boundaries and
  preserving surrounding statements. Other normative templates still need this
  fixture/execution correspondence.
- Registry fixtures run in separate databases and compare the normative CREATE
  against an independently specified temporary catalog. They refuse wrong owners,
  writable table/column/sequence grants, changed constraints or identity sequences,
  unlogged storage, inheritance and rewrite rules, while keeping the caller's
  transaction usable. Ten family allocations are observed waiting at the bootstrap
  lock before release; their namespaces and UUIDs remain distinct. Rollback consumes
  a namespace without publishing it, and exhaustion fails before a reserved key can
  be registered. These cases pass on PostgreSQL 14–18. This is a test implementation
  of the registry hook; the production installer and full role-membership audit
  remain pending.
- Catalog-expression fixtures compare CHECKs, defaults, generated columns, index
  expressions and predicates using one server and matching temporary column types
  and collations. Equal deparsed text still requires matching column collation.
  Default tests exposed an unsafe roadmap assumption: a volatile user-defined cast
  can deparse as a literal followed by `::type`. The fixture recognizer now accepts
  only a closed scalar-constant grammar, and column checks reject domains and invalid
  typmod assignments. Tests demonstrate both the cast's side effect and a domain's
  deceptively plain stored default. Computing defaults are never evaluated during
  classification; recognized constants are probed only on temporary tables. The
  normative acceptance rule now includes these refusals. The production catalog
  verifier and full drift classifier remain pending.
  Raw catalog evidence also covers table flags, column identity/generation,
  constraints, indexes, triggers and policies. Paired tests change exactly one
  index/constraint property and require every other property to stay equal;
  recreating an equivalent CHECK must not differ merely because its OID changes.
  Another regression disproves the roadmap's blanket benign-nonunique-index rule:
  expression and predicate errors, and oversized plain B-tree keys, reject rows
  the table previously accepted. Unrecorded indexes now require explicit adoption;
  generated plain indexes need an old-key domain proof to remain epoch-preserving.
  Implementing that proof and the resulting planner classification remains pending.
- The documented V8 contract is also an executed, labelled fixture. Each SQL
  boundary and callback is followed by database/model checks; backend death at
  every boundary resumes from durable database evidence. Tests retain accepted
  row values, compare server-parsed CHECK definitions, validate before NOT NULL,
  check removal of temporary objects, and enforce settled constraints. Running
  it under the worker role found missing progress/observability grants in the
  normative control bootstrap; the grants now match the declared role boundary,
  with negative tests for direct state, history, activation and barrier writes.
  Initial-history boundary tests also found the SQL recorder accepting nonpositive
  versions; it now rejects those, the reserved boot-lock version, missing snapshot
  hashes and invalid protocol identities before publishing any lifecycle rows.
  Recipe hooks use a small stand-in row function and pending/dead job restamps;
  generated Tesl transforms, processing-claim semantics and production contract
  orchestration remain separate delivery gates.
- The direct compiler now routes `tesl test` through every emitted test package.
  Name and kind must match the same test, and a missing selection fails.
- Durable queue claims have monotone attempts, stored expiry, renewal, and stale
  outcome checks. Transaction-owned claims retain their row-lock guarantee only
  in the exact claiming transaction. Versioned decoders and admission remain pending.
- SHA-256 has published and independent binary/padding vectors. Dotted schema
  module headers, directory resolution, qualified calls, constructors, and nominal
  version separation have executable regression coverage. Qualified-only migration
  imports support constructor patterns, including nested `Maybe`, with negative
  cases for version mismatches, missing cases and arity. Semantic IR freezing and
  the planner remain pending.
- Canonical encoding format 1 is specified in LANGUAGE-SPEC, with independent
  Python/hashlib wire/hash vectors and a separate test decoder. Schema references
  retain `from`/`to` roles while alpha-renaming revision numbers; otherwise switching
  between old/new same-named helpers could go undetected. This is the wire layer,
  not yet the typed AST elaborator or a verified semantic closure.
  The checker now offers opt-in expression-identity capture with each node's final
  function-local substitution, since editor source positions are not unique IR
  identities. Tests keep numeric/text `Nothing` nodes distinct at coincident spans,
  resolve earlier branch types after later unification, and retain let-polymorphism.
- Typed declaration encoding now covers pure expressions, signatures, proofs,
  schema mappings and codecs. Its dependency graph follows private helpers, all
  conservative fact owners, constructor definitions and type-to-codec reverse
  dependencies, with cycle and missing-definition checks. Fourteen focused regression
  groups pass, including an independently constructed typed wire/SHA-256 golden,
  semantic mutations, alpha-renaming and frozen-copy invariance. These low-level
  APIs do not assert that their caller has supplied a complete schema inventory.
  The subsequent saved-source loader now constructs that inventory from its root,
  validates every private module with the public compiler judgment, resolves
  declaration/builtin identities, and wraps results with the compiler ABI. Its
  abstract result prevents callers from omitting a private fact producer. Thirteen
  regression groups pass. They found stale cached import interfaces admitting a
  newly ill-typed helper, physical table collisions hidden in private modules,
  ambiguous builtin predicate resolution, and an omitted regex-literal gate. All
  four cases now refuse or resolve correctly. Nested record/ADT and codec edits
  change the containing entity's closure even when its SQL JSONB field is unchanged.
  Contextual Same verification, compiler ABI allocation, source-history identity,
  editor overlays and manifest/runtime-history integration remain pending.
- Four generated codec API tests now run in the compiler gate. They demonstrate
  the asymmetry of a legacy decoder, failure after premature decoder removal,
  ordered fallback behavior and corrupt JSON refusal, and incompatible nested ADT
  constructors in both directions. These are serialization counterexamples, not
  PostgreSQL rewrite or production migration tests. The roadmap's JSONB section
  now requires a unified plan, bidirectional rolling compatibility and durable
  evidence before removing a decoder.
- Record JSONB storage now uses an explicit bidirectional codec. Five compiler
  regression groups execute emitted scanners and codecs for local/private/transitive
  records, nested records/ADTs, nullable fields, exact large integers, ordered
  fallback selection, proof failures, and missing/forbidden codec directions.
  The declaration is refused even without queries or with `@db(jsonb)` when its
  record codec contract is incomplete. Review regressions caught a missing
  transitive Go import, same-named ADTs sharing a decoder, and an annotation
  bypassing the record contract; those cases are fixed.
- The checked inventory now projects semantic contracts for every stored entity
  field using the same IR lowering as complete declarations. A changed codec,
  nested ADT, or fact producer reaches all containing fields, including private
  entities, optional fields and newtype wrappers. Nine regression groups cover
  exact affected locations, fallback removal/order, proof subjects, annotations,
  additions/removals, frozen copies, same-named private types, ABI/family refusals,
  and one codec shared by 300 private entities. Unstored records/codecs and
  unrelated fields remain outside the change report. Field proof subjects use
  stable names so adding or reordering a sibling does not create spurious changes.
  This is planner input; physical catalog diffing, compatibility classification,
  persisted ABI/history checks, queue occurrences and decoder-pruning gates are
  still pending.
- A complete V7/V8/V9 HTTP app now runs in separate generated binaries against
  PostgreSQL with byte-identical application source. Raw JSONB checks and unchanged
  HTTP assertions cover old/new read directions, untouched old values surviving
  later versions, partial rewrites leaving nullable/ADT occurrences behind, complete
  application re-encoding, and proof-invalid rows in all three positions. This
  exposed pgx's pointer JSON scan conflating JSON null with SQL NULL; generated
  scans now preserve the distinction. Runtime tests also exercise pgx's JSON and
  JSONB scan plans in text and binary formats, legacy JSON wrapping, malformed
  input and checked rejection. The focused PostgreSQL 17 regression passes with
  the race detector. The production migration executor and JSONB lesson are pending.
  A compatible V8 bridge writes both keys and remains readable by V7 and V9 with
  identical handlers; a late V7 write reintroduces legacy-only JSON and demonstrates
  why a rewrite alone is insufficient evidence. Versioned processes now coexist
  throughout the trace, eliminating per-request process/race-detector shutdown cost.
  This preserves the existing hard deadline; it does not relax a protocol timeout.
- Compiling the roadmap's optional establish example exposed a pre-existing
  rejection of `Maybe (value: T ::: P value)`. This return form now accepts bare
  proof attachment and checks every successful payload with path-sensitive return
  discharge; it retains the restrictions on HTTP `ok`/`fail`. The regression matrix
  rejects wrong subjects, wrong predicates, missing conjunctions, unproven branches
  and aliases, discarded evidence, and minting from an ordinary fn. Generated Go
  preserves successful values and Nothing, and a caller requiring the proof runs.
  Check/auth return matching now resolves decomposed witnesses from each returning
  branch's semantic environment. Regression cases cover nested optional subjects,
  alias chains, sibling branches, conjunction projection and delegated auth. This
  also removed an unsafe assumption that a check's distinct result binder aliases
  its first argument. The roadmap's establish/check snippet is read directly by a
  compiler regression and executed in generated Go, including Nothing and HTTP
  failure. Its indentation and declared return binder were corrected to match the
  language. The full compiler suite passes after these changes; the final snippet
  additions also pass the focused compiler/Go suite.
- Source-preserving freeze previews include the whole owned import closure, private
  declarations and cycles. The tests cover interpolation, literals, CRLF, tabs,
  idempotence, edited history, missing modules, and symlinks (including dangling
  directory symlinks). Applying a manifest and semantic history checks remain pending.
- The maintainer clarified that fixtures must model the same ownership boundary
  as production: `app.tesl` owns connections, `operations.tesl` owns effects, and
  `schema/notes/v-current.tesl` owns entities. Separating the fixtures exposed
  imported entities incorrectly emitting Memory-only queries. The project-wide
  database binding fix and schema-content rejection tests pass, including three
  separately compiled applications sharing PostgreSQL rows. The schema files contain
  no database, environment access, application operations, or tests.
  The same boundary now applies when checking a schema file directly, before an
  App binds it to a database, and to unsaved schema buffers. Ten focused compiler
  regression groups pass, including the generated multi-module Go applications.
  Migration-family modules now also reject application declarations, connections,
  effects, entity declarations and application imports, while allowing pure
  migration/fixture constants. Standalone, imported and unsaved checks pass in
  the expanded eleven-group suite. Generated test/support modules still need
  their explicit test-build capability boundary before that surface ships.
  The twelfth group verifies whole-application schema ownership: splitting child
  modules between database declarations, combining families and binding historical
  entities are refused before emission. The checker and emitter share entity
  resolution, preserving local declarations versus qualified-only imports. A new
  unsaved-file test exposed the graph walk skipping files without a disk copy;
  it now checks the parsed entry and its imports, including ownership, in that case.
  Module references now select the complete private entity closure and keep the
  physical PostgreSQL namespace separate in `PostgresConfig.namespace`. Source,
  unsaved-file and direct project entrypoints resolve the same ownership; the
  single-module emitter refuses an unresolved reference. Tests cover private
  membership, diamonds, cycles, duplicate tables, same-named local and imported
  declarations, empty roots, malformed config, and App capability wiring. They
  caught imported metadata replacing a local entity and omitting its table, and
  legacy config validation accepting private or nonexistent entities. Both are
  fixed with regression cases. V7–V9 now use module references; all nine source
  files pass agent-context. The updated PostgreSQL process run passes, including
  shared rows and transaction pauses. An earlier attempt timed out during fixture
  role creation before application queries; server logs are now retained in the
  failure output. The complete compiler gate passes after correcting older GET/POST
  fixtures that incorrectly listed a plain record in `Database.entities`. The
  PostgreSQL 17 database, replica and crash cases pass; pooler cases also pass after
  supplying the installed PgBouncer path. Optional test dependencies are now checked
  before cluster setup. History/executor integration remains pending. The later
  import-boundary slice below implements the general MIG015 refusal.
- A storage-identity review found that distinct Tesl fields such as `userID` and
  `userId` map to one SQL column, and overlong PostgreSQL identifiers can silently
  truncate. Validation and emission now share the column-name conversion; checks
  reject these collisions and overlong/NUL table names, including private schema
  members. Focused tests pass for ASCII and Unicode byte boundaries, acronym and
  underscore aliases, and names that grow during conversion. The whole ownership
  projection is also checked for explicit index-name collisions across modules.
  The expanded compiler gate passes, including all seventeen migration import,
  ownership and source-freeze groups. The private-index case checks that the
  diagnostic identifies both declaring modules.
- PostgreSQL tests interpose retirement between a read and its admission, for old
  and surviving versions and six query forms: rows, a missing key, constant false,
  LIMIT 0, an empty aggregate, and EXISTS. They verify that contract DDL
  waits for the reader's transaction and that backend termination before/after commit
  rolls back/preserves the floor and lifecycle evidence together.
  Disposable primary clusters also pass immediate-shutdown/WAL-recovery cases on
  both sides of that commit, followed by exactly-once coordinator resumption.
  Nightly/manual matrix runs select matching-major server binaries for these
  owned clusters; they never stop the shared matrix service or a developer server.
  A paused physical replica also demonstrates stale admission and physical schema
  across retirement/DDL, then catches up to both. This is a protocol counterexample
  to replica-local admission, not support for routing application reads to replicas.
- Private PgBouncer session/transaction fixtures pass on PostgreSQL 17 and are wired
  into the PostgreSQL major-version CI matrix. The transaction case forces backend
  reuse and checks that fences and refused transactions do not leak. These exercise
  the protocol oracle; generated runtime admission remains pending.
- The independent TLA+ admission/contract kernel passes exhaustive finite checks:
  1,404 states for three-version admission and 6,288 for two-version queue attempts.
  Seven deliberately broken protocols must produce their specific invariant or
  action-property counterexample. Mutation testing caught an initially unreachable
  transforming-expansion branch in the model; it now exercises both expansion
  forms. The locked Nix toolchain, root CI and dedicated workflow run this gate.
  Production correspondence, complete INV/TR mappings and both reviews remain
  pending; finite model checks do not establish unbounded progress or PostgreSQL
  implementation correctness. See `dev-docs/models/README.md` for assumptions.
- The complete root CI gate is not yet green. Its generated Memory-only analyzer
  failure was fixed by moving renewal logic into the PostgreSQL runtime file.
  The full compiler regression suite passed after the fixture split and project-wide
  binding changes and again after qualified-pattern, canonical wire and typed-node
  capture changes, then again after statement-position let capture and typed IR.
  The subsequent generic-type encoding adjustment passes its focused suite. The full
  PostgreSQL harness, runtime lint gate, and direct compiler test-command regressions
  pass. Local gate runs disable
  Go VCS stamping because the sandbox exposes an empty `/tmp/.git` mount.
  A later run exhausted disk space; only this task's disposable Go cache was removed.
  Its replacement compiler run passed the language suites but timed out in one
  mutation baseline while rebuilding the cache; the isolated warmed-cache rerun
  passed all four mutation tests. The latest queue decoder attempt-ownership fix
  also passes the complete runtime lint gate.
  Running the compiler suite concurrently with PostgreSQL later saturated host I/O;
  PostgreSQL timed out in WALWrite. The isolated rerun passed the full protocol
  harness, compiled applications and both pooler modes in 35 seconds. Keep these
  disk-heavy local gates sequential.
  A subsequent complete compiler run exposed Alcotest's shared `latest` symlink
  race between emission shards. Each shard now uses its own log directory and
  the complete compiler suite passes. Old entries in this task's disposable Go
  cache were pruned when disk filled again; source files and other caches were
  left intact.
  The later full PostgreSQL harness passes in 51 seconds with repair, index,
  quarantine-model, pooler, primary recovery and replica cases; runtime lint is
  clean. The standalone schema-boundary change passes its focused compiler suite
  and the complete compiler gate. That gate caught an auth proof fixture living
  in a schema namespace; it now uses an application module and still checks
  proof-specific refusals. All nine V7/V8/V9 fixture files also pass direct
  `agent-context` checks with zero diagnostics.
  The PostgreSQL 17 nightly-length run also passes (107 seconds): 512,000 model
  operations plus poolers, owned primary crashes and a lagged replica. The matrix
  now verifies the actual connected PostgreSQL major, including owned clusters.
  The later complete local matrix also passes on PostgreSQL 14.23 (85 seconds),
  15.18 (86 seconds), 16.14 (93 seconds), 17.10 (89 seconds), and 18.4 (88 seconds).
  Every lane includes the race detector, compiled fixture applications, both
  PgBouncer modes, a lagged replica and owned-cluster crash recovery. Matching-major
  tools initialise, back up and restart each cluster. These functional results do
  not satisfy the separately pinned performance gate.
  The bootstrap/contract extension passes the full PostgreSQL harness in 62 seconds
  and lint with zero issues. Subsequent lifecycle identity guards pass the focused
  PostgreSQL bootstrap, contract, repair and control-template tests in 21 seconds.
  After the migration-module boundary change, the complete compiler gate and doc
  integrity gate pass again. The complete PostgreSQL suite with lifecycle identity
  fixes, all compiled fixtures, poolers, replica and owned-cluster crash cases also
  passes (89 seconds).
  The subsequent catalog slice passes on PostgreSQL 14–18, including the native
  NULLS NOT DISTINCT identity cases on 15–18. Runtime lint remains clean. The manual
  coherence gate found the new ledger's missing audience banner; after adding it,
  that gate also passes. These checks still leave the complete root CI and both
  feature-wide reviews pending.
  Whole-application ownership and new unsaved-file checking then pass the complete
  compiler gate, the manual coherence gate and all nine fixture agent-context checks.
  The following full PostgreSQL 17 run, including the target-write ABI model, passes
  in 56 seconds with poolers, replica and owned-primary crash cases; lint is clean.
  The subsequent schema-reference corpus refresh also passes Kanel's seven API
  tests through the public CLI. Imported queries now honor the application's
  database binding; the refreshed Kanel snapshot includes its PostgreSQL statements
  and decoders. Registry membership refusal tests pass on PostgreSQL 14, 16, 17 and
  18, including indirect and NOINHERIT membership and a temporary installer role.
  The migration package lint gate passes with those membership checks included.
  The JSONB storage slice passes the complete compiler suite, runtime race suite,
  full runtime lint and manual coherence check. The 192-file snapshot refresh
  changes Kanel's imported ADT helper names and reuses its declared InvoiceStatus
  encoder; its direct and API suites pass. The first combined
  PostgreSQL 17 run with JSONB cases fails only during the owned replica's backup
  setup deadline; the isolated replica test subsequently passes in seven seconds.
  This is recorded as a setup failure, not a successful combined gate.
  A subsequent combined run exposed the per-request process exit cost in the new
  JSONB trace. After switching to coexisting app processes, the full PostgreSQL 17
  harness passes in 95 seconds, including the compatible codec bridge, PgBouncer
  modes, replica and owned-primary crash tests. The race detector remains enabled
  and the existing fixture deadline is unchanged. Migration-package lint is clean.
  The final JSONB app trace, including the compatible bridge and late old-writer
  counterexample, also passes on PostgreSQL 14 and 18. A second codec-ownership
  review removes redundant inherited metadata copying, and the complete compiler
  suite passes again. These are completed slice checks; the delivery table above
  still records the remaining implementation and feature-wide review gates.
  The next compiler run, with field-impact tests, found two unrelated tuple-arity
  failures. An isolated regression established the cause: import suggestions
  parsed an unimported malformed sibling and replaced the real type diagnostic
  with its lexer error. Discovery now skips lexer-invalid candidates, while
  checking the broken source still fails. The suggestion tests and original
  tuple/type regression suite pass. Test directories now use unique temporary names
  and cleanup; PID reuse previously caused collisions on repeated isolated runs.

## Implementation decisions

The authoritative target-mechanisms table remains the baseline except for the
execution-model decision below. Computed columns initially use
materialisation, and their introducing-version SQL restrictions remain in force.
The speculative overfetch refinement is not part of the initial implementation.

Execution model (maintainer preference, 2026-09-05): record the compiler ABI rather
than freezing stdlib implementations or retaining historical lowerings. Record
`processing_abi` atomically with the first processed batch or application write at
the target generation. A different ABI may be selected only before either kind of
write and before any provisional pass;
after that, it is refused. Recovery uses the original ABI executor or a new entity
generation that reprocesses every row. Frozen source closure hashes still detect
edited history. Catch-up records one ABI for every replayed version. The superseded
frozen-slice passages in the original proposal require reconciliation in phase 3.
That reconciliation must also cover persisted proofs and `Same`: locking an ABI
for backfill batches does not justify interpreting facts established by another
ABI as facts under the current one. The explicit stored-value contract now supplies
a bounded compatibility promise for fully checked, completed additive history.
A new-generation recovery across different contracts must re-establish facts from
untrusted decoded values. That production path remains pending; the execution-ABI
model alone is still only a consistency oracle.
The model now distinguishes a committed target-generation application write from
backfill progress. It locks the ABI even when `rows_done` is zero and no provisional
pass exists, requires that application's admitted fence, survives a crash and rejects
a different ABI in another entity or pass. The actual write/ABI transaction and
persisted-proof typing remain production gates.

The permanent entity generation is a PostgreSQL `smallint`; generation 32767 is
the last legal generation. Generation allocation refuses overflow before producing
an edit manifest or executing DDL. Schema versions are positive signed 32-bit
integers; 2147483647 is reserved for the boot fence and cannot be allocated.

Module references are contextual to `Database.schema` and `Database.migrations`,
as specified in section 1. They cannot escape into ordinary value expressions.
The schema's import closure defines membership, including unexported entities.

Tests must distinguish executable coverage from planned coverage. In particular,
passing a model test does not demonstrate that PostgreSQL obeys that model, and
local microbenchmarks do not satisfy the pinned-environment latency release gate.

## Baseline observations

- The tree initially has a user move of `reduce_keywords.md` from `next` to `later`.
- The compiler builds using `nix develop --command …`.
- Existing queues and email outboxes already have random claim tokens and stale
  outcome regression tests. Monotone attempts, fenced renewal, versioned codecs,
  and retirement remain separate requirements.
- PostgreSQL 14–18 and PgBouncer are available locally; the complete functional
  matrix, including owned primary/replica clusters, passes. The pinned performance
  environment remains a separate, unfulfilled gate.
