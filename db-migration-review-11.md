# Database migrations — critical technical review 11

Date: 2026-10-07. Review baseline: **`ebca5fe` (`wip`)**, committed at the user's
request before this review. The status correction and new tests described below
are subsequent working-tree changes. See the
[executive review](db-migration-review-11-executive.md) for decisions and priorities.

## Bottom line

**Readiness update (2026-10-12):** authoritative `./ci.sh` now passes all 24 phases,
without skips, in one invocation on Go 1.26.9. It includes all 47 migration phases,
244 adversarial cases and V1–V20. `.tesl-stuff/readiness-ci-final-gate.log` records
exit 0. See [delivery status](dev-docs/migration-delivery-status.md) for the exact
scope and hosted/performance gates still open. Historical discovery assessments
below do not supersede that current status.

**Latest performance follow-up after `3242931`:** two ordinary-release runs of the
257-type/1,024-head workload reached all types in **24.535s and 24.549s**, preserving
payloads and admission floors and retaining busy-head work. This supersedes the
earlier 685.73s and partial-progress measurements below. The unchanged 25-second
check passes these samples with little margin; no production SLA is claimed.
Enqueue setup is now about 44–45s. The final 117-case review suite, 127 existing
cases and focused compiler/PostgreSQL/runtime gates pass. Details and safety
obligations are in [queue admission performance](dev-docs/queue-admission-performance.md).

**Keep the architecture. The supported lifecycle has strong identity, proof,
fencing and replay properties, but operational completion remains narrower than
source acceptance.** This is a functioning scoped migration system, not merely
schema-diff tooling. It is not yet a general production-readiness guarantee.

This review added **74 named adversarial/control cases** and reran the existing
**127-case suite against freshly built releases**: all 201 pass. Both ordinary
row and queue V1–V4 deployment examples and focused PostgreSQL/race gates pass.
One newly discovered status defect was reproduced and fixed. A new execution case
also confirms an open recovery/diagnosis limitation; its passing result means the
observed fail-stop behavior is characterized, not that the limitation is solved.

The most important next work is **a coherent outcome and recovery protocol for
callbacks that trap or exhaust their execution budget**, followed by measured
large-inventory enqueue/conversion costs. More syntax should not precede those.

### Current remediation follow-up after `4662e3f`

The maintainer subsequently required **both** corrected conversion and audited
discard, rather than leaving unresolved old work without a completion route.
Both policies now use the existing contextual `QueueRepair` declaration:

- Omitted `on` / `on: "rejected"` retains the existing business-rejection contract.
- `on: "execution-failed"` requires the exact predecessor's operational failure
  and a new typed converter. Generated fixtures actually execute the predecessor
  and must reproduce that outcome; a healthy predecessor is not sufficient.
- `on: "unconverted", discard: "reason"` explicitly authorizes every remaining
  original-version job of the named type on that transition. It requires no
  decoder, so malformed historical bytes have an audited resolution route. It
  is terminal, cannot carry a callback/fixtures, and leaves target-version jobs alone.

Each revision appends to exact immutable source history and is staged by the
installer, separately from Worker execution. The Worker checks the full source
binding and actual attempt/transaction ownership under admission fences. Live
claims remain protected; expiration permits the ordinary fenced reclaim path.
Discard commits its deletion and private audit together. Audits retain job,
source decision digest, attempt, payload hash and authored reason; prior failure
and conversion receipts survive. Audited job IDs cannot be reused. Status exposes
bounded discard plans and affected/live-claim counts before the Worker runs.

The full **111-case review suite passed in 487.557s** on fresh releases, including
the corrected-converter → business rejection → ordinary repair chain. Tests
097–111 cover both policies, exact replay/retirement, malformed bytes, live claims,
rollback, stale attempts, changed bytes, role restrictions, tampered policy,
invalid declarations, wrong fixture outcomes, competing revisions and refusal
after retirement. The existing **127 cases passed in 298.322s**; all **58 compiler
queue-source/PostgreSQL cases** passed in 339.949s, focused runtime race checks in
105.988s, and six embedding seam / three runtime-gate checks passed.
Logs: `.tesl-stuff/remediation-final.log` and
`.tesl-stuff/remediation-existing-final.log`. The first existing-suite run exposed
one stale test using `discard` as an unknown field; it now uses `forceAll` and
still requires MIG020. No safety assertion was removed.

This supersedes the earlier general-recovery deferral in the historical review.
The separate `QueueRecovery` constructor proposal remains in `roadmap/later` as
superseded design context. [Queue remediation](manual/queue-remediation.md) is the
active operator reference. Fresh-catalog-first and same-edge executable identity
restrictions remain; these changes do not add catalog adoption or an implicit
expiry policy. No new full default-gate result is claimed for this follow-up.

### Shared queue verification and row-volume measurements

Following the remediation implementation, source opening now shares one verified
read-only snapshot across at most 32 converter descriptors. Each descriptor's
complete lineage is still compared; every job remains independently transactional
and rechecks live admission, source binding and attempt ownership. No database
authority is cached across snapshot groups. Case 112 injects a late source-policy
mismatch and proves that earlier work in the group is not mutated. A Go boundary
test refuses empty/oversized batches and unregistered sources before database access.

This bounded change gives only a modest improvement: 246/257 types progressed in
600s, compared with 228/257 in the previous materialized-SQL measurement. The
remaining repeated per-job admission/inventory work is still material. The
25-second target remains unfulfilled at 257 types.

Final verification of remediation plus shared opening passed **112 review cases
in 496.829s**, all **127 existing cases in 353.793s**, all **58 compiler queue-source
and PostgreSQL cases in 341.354s**, protocol traceability, six embedding seam tests
and three runtime-gate tests. Log: `.tesl-stuff/remediation-shared-final.log`.

Controlled ordinary-build measurements, with the same 1,024-job busy head:

| Registered/changed types | Enqueue setup | Time until every type progresses | Head remaining |
|---:|---:|---:|---:|
| 3 | 3.40s | 3.07s | 938 |
| 17 | 11.55s | 3.07s | 1,008 |
| 257 | 198.92s | Not complete at 600s; 246 types progressed | 1,023 |

At 17 types, increasing the head backlog fourfold to 4,096 jobs increased enqueue
time to 46.11s but left time-to-first-service across types at 3.09s (4,080 head
jobs remained). The fairness scheduler allocates different per-type quanta, so the
three-type run converts more head jobs before serving all peers; these are not
equal-work throughput measurements. They nevertheless show a strong inventory-width
cost and an approximately linear enqueue-volume cost. All measured payload and
admission invariants passed. Logs: `remediation-scale-type-matrix.log`,
`remediation-scale-job-matrix.log`, `remediation-shared-open-scale257.log` under
`.tesl-stuff`, with per-run hashes and samples in the corresponding directories.

The inventory-width cost involves **total registered types**, not merely the number
of changed converters: protected enqueue validates the complete source inventory
even before conversions run. More changed types additionally cause more descriptor
opens/scheduler visits. More jobs multiply the per-job work. This benchmark changes
all its types, so it does not independently quantify the changed/unchanged split.

The row path is structurally different: typed physical plans are registered, and
future-generation observations are reused while their lifecycle identity remains
unchanged. Full history/catalog work is concentrated at startup and changed
observation boundaries, rather than the queue path's repeated whole-inventory
admission. That is a source-level distinction, not a large-database SLA.

A volume probe reused the exact previously verified V1–V20 race binaries and added
1,000 Tasks via the V1 HTTP API (5.14s seeding). All 95 API cases and all twenty
deployments passed with those Tasks retained and checked after every finality
boundary. V7/V13/V15 full phase times were 29.34/41.49/42.87s versus
28.02/39.42/40.31s in the earlier small-row run. These single-run phase timings
include startup, overlap, assertions and retirement: they are not isolated backfill
timings. They show no queue-like amplification at this modest row count; millions
of rows, hundreds of tables, expensive predicates and contention remain unmeasured.
Evidence: `.tesl-stuff/remediation-row-volume1000.log` and
`remediation-row-volume1000/{seed-workload,rollout}.json`. The reused binaries predate
the queue-remediation changes; this isolates row volume rather than certifying
those binaries as the latest queue implementation.

### Historical diagnostic follow-up after `2d70dae`

The initial review and fail-stop reproduction below are preserved as discovery
evidence. The application queue Worker now records recognized execution failures
separately and continues healthy work. The updated suite has **87 passing cases**;
the existing 127-case suite also passes. General typed callback-failure recovery
remains open, but durable diagnosis, restart suppression, and a limited existing
predecessor-processing recovery route now have regression evidence.

### Twenty-release continuation after `2a034d3`

**The full default migration gate passed uninterrupted before the subsequent
queue scale optimization**, including a freshly
generated and built **V1–V20 multi-table application** with **95 Tesl API tests
bound to the retained PostgreSQL database**. This supersedes R11-04's pending
gate evidence for this tree. Log: `.tesl-stuff/twenty-releases-full-gate-retry.log`.

The runnable scenario is [`example/db-twenty-releases/`](example/db-twenty-releases/README.md).
Projects, Tasks and Members begin at V1; Audit is introduced at V6. Nine
transforming releases are interleaved with nullable-field/table additions, ending
with two distinct tables transformed together at V20. Cases exercise Rename,
Retype/WriteBack twice on task metadata, Legacy/LegacyWith field removal and title
proof Revalidate. Each release adds a data cohort, and every later release checks
all cohorts before and after finality. Final counts are 21 Projects, 21 Tasks,
21 Members and 16 Audit rows, on one unchanged database UUID.

The simulation verifies predecessor/successor writes during overlap, reads from
both versions, deliberate rejection and predecessor repair at V7/V13/V15,
Contract replay, additive close-epoch dry-run/replay, refusal to use close-epoch
in place of a transforming Contract, and surviving Request restart. Independent
post-finality SQL fixtures seed valid non-default optional fields to detect lossy
copying in later releases. Business cohorts and edits use ordinary HTTP handlers.
The test-only Go launcher binds generated Tesl `api-test` bodies to PostgreSQL;
the router, handlers, generated test bodies and migration identities are unchanged.

This exposed and fixed three composition defects that narrower examples missed:

1. **Current codecs were suppressed database-wide if any table transformed.**
   V7 retyped Task while Project already had an earlier rename. Current-codec
   selection and admission now require a zero-window projection **per entity**;
   they still refuse a current codec for the entity with an active transform.
   After a peer Contract, the exact registered settled plan and unchanged entity
   projection must match before using that codec.
2. **Additive epoch closure required the entire historical prefix to be additive.**
   V6 followed completed Project Contract V5. Epoch closure now binds the entire
   original prefix but requires only the admitted tail to be additive. Earlier
   transforming revisions require exact completed Contracts/object counts and
   independently verified lifecycle evidence. Missing/active prerequisites still
   refuse; gaps between epoch receipts must be filled by completed Contracts.
3. **Future-generation observation required a predecessor marked `settled`.**
   An already complete additive-tail binary failed during the next transforming
   overlap. It may now observe the exact adjacent successor only when its own
   original plan is additive; full predecessor bytes, identity, projection and
   required-Contract relationships remain checked.

The first full gate attempt failed a lease-renewal test whose 30-second outer
fixture included deliberate 12-second and 6-second pauses plus process setup.
That scenario now has a dedicated 90-second outer budget; lease, operation and
boundary deadlines are unchanged. A focused retry separately exposed a short
400ms request-timeout test applying that budget to startup. Its test-only boundary
hook now arms the same 400ms budget after verified startup. The complete 11-case
access suite then passed (465.978s), followed by the uninterrupted full gate.

Evidence:

- `.tesl-stuff/twenty-releases-final.log`: twenty built releases and complete
  V1–V20 rollout, followed by `.tesl-stuff/twenty-releases-access-and-controls.log`
  for the stronger finality negative controls and second complete rollout.
- `.tesl-stuff/twenty-releases-final/`: archived source/binary hashes, per-release
  PostgreSQL API output, retained database UUID and rollout timings.
- `.tesl-stuff/twenty-releases-full-gate-retry.log`: main compiled application/kernel
  package (1436.768s), all subsequent mandatory sections, 127 review-05 cases,
  87 review-11 cases, both V1–V4 examples, and freshly built V1–V20/95 API cases.
No phase was resumed or skipped to claim this full-gate pass.

This establishes a longer mixed **row** history, not unrestricted mixed row/queue
non-additive evolution or high-volume capacity. General typed callback-failure
remediation and 257-type queue runtime acceptance remain separate work.

### Queue scale continuation

`scripts/measure-migration-queue-scale.py` now separates protected-enqueue setup
from the 25-second runtime progress target. It enqueues the same 1,024 head jobs
plus one job for each of 256 later types through normal Request-role operations,
using at most 32 calls per setup transaction. It measures a bounded longer
observation without converting that observation limit into a passing SLA.

The race build progressed only about 70 types in 600 seconds. An ordinary Go
release build progressed 80/257 types in 600.12 seconds, with 1,023 head jobs still
pending; enqueue setup took 201.98 seconds. This confirms the cost is not chiefly
the race detector. Source inspection identified repeated nested expansion of the
same JSON payload inventories in `tesl_row_queue_transition_valid`.

The verifier now materializes the old/new payload relations once **per statement**,
preserving its exact membership, contract, staging, installation and source-inventory
comparisons. This is not a cross-transaction admission cache. Nine new protected-SQL
controls cover exact acceptance, missing/renamed membership, changed source bytes,
unchanged contracts attempting to consume staged conversion, foreign installation,
and substituted inventory identity. The complete new suite is now 96 cases and
passed in 246.302 seconds on freshly built releases.

With this optimization the ordinary release build progressed 228 types in 600.34
seconds. A subsequent bounded observation reached **all 257 types in 685.73 seconds**,
with **1,023 head jobs still pending** and the Worker alive. It therefore demonstrates
eventual service beyond the 256-job turn boundary under this finite workload, but
**does not meet the unchanged 25-second latency target** or prove fairness under
arbitrary arrival patterns. Setup remained about 202 seconds. Next profile full
per-source dispatch validation and protected per-job admission before changing them.

Evidence: `.tesl-stuff/twenty-queue-scale-257{,-release}.log`,
`twenty-queue-scale-materialized-release.log`,
`twenty-queue-scale-materialized-complete.log`, and each named output directory's
`measurement.json` (compiler/binary hashes, runtime budget, per-half-second progress).
The SQL-regression run is `.tesl-stuff/twenty-scale-transition-checks.log`.

The distinct typed remediation proposal is
[`roadmap/later/queue-execution-recovery.md`](roadmap/later/queue-execution-recovery.md).
It explicitly requires a checked failure-reproducing fixture, immutable predecessor
and callback identity, exact byte/attempt ownership, a separately audited result,
and retirement verification. Source spelling and failure-code policy are not yet
implemented; existing `QueueRepair` has not been silently broadened.
Maintainer direction subsequently deferred this proposal: it is not a prerequisite
for the scoped database-migration release. Durable unresolved jobs still block
retirement; no guaranteed-completion or implicit-discard promise is made.

A second full-gate attempt on the optimized tree passed the main compiled-app
package (1340.515s), the early runtime groups, the complete 58-case conversion
source suite, and the 11-case typed access suite (433.993s), then stalled during
nominal-primary-key legacy fixture 18 until the three-hour outer command limit.
No assertion failure was printed at that point. Its isolated rerun passed in
97.442 seconds (`.tesl-stuff/twenty-nominal-pk-retry.log`); the stall's root cause
has not been established. The second attempt is recorded in
`.tesl-stuff/twenty-releases-full-gate-final.log`, not relabeled as an uninterrupted
pass. The earlier uninterrupted run verifies the twenty-release composition fixes;
the later SQL optimization additionally has the fresh 96-case and scale evidence
above. A fresh complete final-tree gate remains an outstanding verification item.

Final focused checks on the optimized runtime also passed: the existing 127-case
suite (391.705s), generated/application PostgreSQL conversion/repair group
(116.953s), six embedding seam tests and three runtime-gate tests. A 17-type
ordinary-build measurement verified payload contents and unchanged admission
`2,1,1`, not just type counts. Log: `.tesl-stuff/twenty-scale-final-checks.log`.

## 1. Scope, method and authority model

Reviewed the path from checked source and retained history to generated adapters,
application registration, installer staging, Worker execution, claims, receipts,
typed repair, status and Contract. Particular attention went to recently shared
source checking and cached source projections, and to the 32-source staging batch.

Methods:

- Compile actual positive and adversarial source, including ordinary application
  writes and row transformation declarations. Read coded `agent-context` results.
- Build ordinary race-instrumented application releases through the public
  compiler. Do not patch emitted identity metadata to make a test pass.
- Run on private PostgreSQL. Clone idle templates per database case.
- Use privileged observer access only to inject deliberate corruption and inspect
  exact state. The operation under test uses Request, Worker or installer as specified.
- Compare state before and after refusal across jobs, staging, receipts, attempts,
  retirement/restamp audits, schema state and lifecycle records. SQL sequences are
  not included in the rollback-equality claim: PostgreSQL sequence allocation is
  intentionally nontransactional.
- Preserve baseline failures and final results separately, with binary/compiler
  SHA-256 provenance and named inventories.

Primary paths:

- `compiler/lib/migration_{declaration,queue_transform,transform}.ml`, `emit_go.ml`.
- `runtime/go/teslrt/migration_queue_program.go` and
  `migration_row_{command,queue_control,queue_dispatch,queue_retirement}.go`.
- `runtime/go/teslrt/migration_queue_operations.go`, execution budgets and the
  generated PostgreSQL conversion/repair fixtures.
- Both `example/*-three-upgrades/` applications, lesson 96 and
  `manual/migration-operations.md`.

This is targeted adversarial evidence, not an exhaustive proof of all schedules,
all source constructions, all compiler upgrades or every PostgreSQL deployment.

## 2. Findings and disposition

| ID | Severity / classification | Finding | Disposition |
|---|---|---|---|
| R11-01 | Medium, confirmed correctness defect | Current-version quarantine was counted as a historical retirement blocker and could hide unrelated old backlog | **Fixed**, cases 044/045 reproduce both symptoms and now pass |
| R11-02 | High operational gap | Initially, a data-dependent exhausted callback stopped the whole Worker without durable diagnosis | **Addressed in the scoped application protocol**: failure audit/peer progress plus explicit corrected-converter and audited-discard revisions pass; see latest follow-up |
| R11-03 | High scale-acceptance gap | 257-type build/install/replay is verified, but the full workload does not reach conversion because bulk protected enqueue exceeds its setup deadline | **Open**, prior measured evidence retained; no large-inventory fairness claim |
| R11-04 | Medium verification gap | At initial review, a fresh uninterrupted default migration gate was missing | **Addressed in the twenty-release continuation**; complete gate including the new scenario passes |
| R11-05 | Explicit product scope, not a new defect | Fresh-catalog-first, consecutive queue-only histories and limited malformed-data recovery are narrower than a general migration product | **Retain clear refusal and documentation**; expansion requires separate lifecycle evidence |

### R11-01 — status confused operational quarantine with retirement blockers

**Reproduction uses protected Request operations**, not fabricated table rows:

1. Enqueue and claim a V2 job with an invalid current payload, then quarantine it.
2. Add one valid V1 job awaiting conversion.
3. Read public status as Request.

Before the fix, status reported `oldPayloads: 1`, `invalid: 1`, and only
`QUEUE_PAYLOAD_INVALID`. The unrelated historical backlog warning disappeared.
With only the V2 quarantine, status still reported a historical invalid-payload
blocker, while `contract V2` succeeded.

Cause: `tesl_row_queue_status()` first counted rejection/invalid bytes among old
jobs, then overwrote those variables with counts across all versions. Both blocker
construction and ordinary-old-work subtraction used the overwritten totals.

Fix in `migration_row_queue_retirement.go`:

- Keep historical rejection/invalid counts separately for retirement blockers.
- Retain total and per-type operational counts, so current quarantines remain visible.
- Calculate `QUEUE_OLD_PAYLOADS` using historical categories only.

Cases 044/045 now pass. Existing historical rejection, invalid-byte, claim and
status-privacy regressions also pass. Operator documentation explains the distinction.
The fix changes the protected function's expected body. Under the existing
fresh-catalog-first development policy, older catalogs refuse rather than silently
adopting the new implementation; this is not an old-catalog upgrade mechanism.

**Why it matters:** actionable status is part of correctness. A conservative
runtime can preserve data and still misdirect an operator into an ineffective
repair or conceal work that actually blocks retirement.

### R11-02 — safe callback refusal is not a complete recovery lifecycle

Case 074 compiles a two-type application whose converter behaves normally for its
fixtures but recurses on the specific historical value `"poison"`. The generated
Go tests pass before the hostile value is enqueued. An unrelated Other job has a
valid converter and payload.

Observed on two ordinary Worker launches:

- The Worker reports `migration execution stopped` and exits unsuccessfully.
- Both jobs remain pending at V1; neither the poison job nor its healthy peer converts.
- No conversion attempt or receipt is published.
- Restart repeats the same failure.
- Public status exposes only `QUEUE_OLD_PAYLOADS`, with an action to run the Worker.

**The safety half is good:** no usable late value, partial payload rewrite or
false conversion receipt. The budget bounds generated recursion. It is not a
static totality proof, memory sandbox, or hard preemption of an individual intrinsic.

**The operational half is incomplete:** one payload can halt the shared schema
Worker, and its durable status cannot explain that rerunning the Worker is
insufficient. Existing `QueueRepair` consumes the business-rejection lineage; this
case never produces that rejection. Source inspection therefore gives no supported
repair route for this exact failure through the current rejection protocol. This
review did not test or invent a repair/discard extension.

Recommended next design:

1. Specify a separate operational-failure outcome from typed business rejection.
2. Bind it to exact source, original bytes, attempt and installation identities.
3. Define whether and how healthy peer types continue; retain bounded execution.
4. Expose the failure through protected status without leaking payloads.
5. Provide an explicit immutable, audited recovery policy and prove retirement
   remains blocked until that policy's obligations are satisfied.

Do not equate trapping with `Reject`, edit installed converters in place, or treat
restarts as recovery evidence. Choosing continuation versus fail-stop is a product
decision; a passing type check does not decide it.

#### Follow-up: distinct failure evidence and healthy-peer progress

The application path now distinguishes three recognized pure-adapter faults:
`execution-budget`, `execution-trap` and `invalid-result`. A new private immutable
`tesl_row_queue_conversion_failures` table binds each observation to the job,
checked source digest, attempt sequence and original payload hash. It never stores
arbitrary callback exception text or grants a converted/business-rejected result.

Publication reuses the real completed-edge/source admission fences and requires
the exact active transaction, attempt, source binding, original payload and job
ownership. The failure record and attempt cleanup commit together. The monotone
claim sequence advances, while payload, schema version, retry count, schedule,
pending/dead disposition and conversion receipts remain unchanged. Cancellation,
SQL errors, binding errors and lost connections keep the rollback path; they are
not classified by matching an error-message string.

Selection and begin/replay suppress the same failed source on the same bytes for
that job. Healthy jobs of the same type and other types continue. Both global and
per-type protected status include `executionFailed`; the distinct blocker
`QUEUE_MIGRATION_EXECUTION_FAILED` replaces the ineffective restart instruction
for these jobs. The old row still blocks Contract: an empty scan does not become
finality. The failure audit is independently catalog/ACL checked and prevents
audited-ID reuse after completion.

Case 075 demonstrates one bounded recovery route already authorized by the
existing protocol: while the predecessor is admitted and the original job remains
processable, its normal protected claim/complete path consumes that job. Contract
then succeeds and replays, while the failure audit survives. This is **not** a new
callback-repair policy, permission to discard data, or a solution for every failed
repair/quarantine. A failed callback is not silently turned into `Reject`, and
`QueueRepair` still requires its exact business-rejection predecessor.

The isolated experimental conversion candidate retains its prior error/rollback
behavior; the new durable diagnostic is scoped to the application protocol.
Fresh control catalogs include the table/function; old development catalogs with
missing or mismatched objects refuse under the existing fresh-catalog-first policy.

### R11-03 — scale improvements are real; the acceptance boundary is still visible

Prior continuation established these measured milestones:

- Guarded shared source checking completes a 257-type preview in 78.42 seconds.
- Bounded wrapper filenames allow both 257-type release binaries to build.
- Registered, validated source projections avoid repeated full parsing while
  returning independent copies.
- Bounded staging and transaction-local admission reuse allow 257-type install
  and exact replay at the default command budget.
- The full 257-type fairness case then exceeds 90 seconds while enqueueing its
  1,024-job backlog through protected operations.

These are **race-instrumented regression workloads on a shared host**, not a
production capacity benchmark. This review did not establish a release-build
throughput number or a million-receipt latency bound. The earlier measured enqueue
failure remains valid evidence of an unresolved test/operational boundary, not a
claim that every production deployment will take the same time.

Source inspection shows complete installed-history admission on protected enqueue
and repeatedly within conversion selection/begin/finish. This explains why database
round trips alone are an inadequate cost model. Any optimization must preserve
post-wait admission, source/compatibility fences, and exact installed identity.

Recommended acceptance targets should distinguish:

- Number of job types, historical edges and repair revisions.
- Pending payload count and retained receipt count.
- Cold metadata initialization, install/replay, idle Worker turn and active conversion.
- Race/debug and ordinary release binaries.
- Normal work, rejection, decode failure and callback failure.

Keep the passing 17-type backlog, two-type continuous-load/restart and 1,024-receipt
indexed-lookup witnesses. They do not establish formal fairness latency across
inventories larger than the 256-job turn or across failing callbacks.

### R11-04 — verification is stronger, but the complete gate claim must stay precise

Fresh evidence for this review includes 201 Python cases, both multi-release public
examples, focused runtime race tests, the generated PostgreSQL conversion/repair
group and runtime embedding/gate checks. This is meaningful coverage.

It is not a new uninterrupted run of `scripts/run-migration-tests.sh`, nor a fresh
whole-compiler `dune runtest`. Earlier full compiler and resumed migration-gate
results are historical context, not evidence automatically inherited by this edit.
Review 11 is now registered in the default migration gate so future complete runs
must execute it. The gate wiring itself has syntax verification; the entire gate
was not executed as one command here.

### R11-05 — supported scope remains intentionally bounded

The following are limitations rather than newly discovered safety defects:

- Development control catalogs can break; missing required objects must refuse.
- Consecutive non-additive queue edges retain membership and unchanged stored
  entities. Later edges require the retired predecessor.
- The row example mixes row migration forms; it does **not** establish unrestricted
  mixed row/queue non-additive history.
- Arbitrary same-version compiler replacement is not supported by the compatible
  new-edge A/B/C compiler witness.
- Typed repair needs an interpretable old value. General malformed-byte recovery,
  `IgnoreOld`/audited discard and old-catalog adoption remain outside scope.

Fresh-install evaluation within these rules is reasonable. A broad deployment
promise must explicitly define catalog compatibility and supported recovery first.

## 3. Architecture: what the new tests support

### Preserve these decisions

- **Frozen nominal history:** old/new records and codecs carry distinct owners;
  `Same`, `Revalidate`, `Retype`, `WriteBack` and Legacy remain explicit decisions.
- **Independent runtime authority:** source evidence alone does not publish an
  expansion, admit a writer or prove retirement.
- **Strict catalog and role verification:** weakened functions, changed index
  shape/order, extra triggers, RLS, column grants and ownership drift refuse.
- **Immutable receipts and real fences:** stale claims cannot authorize rewritten
  jobs, and completed processing does not erase conversion history.
- **Shared pure derivation, scoped mutable authority:** validated source projections
  may be reused; database admission reuse stays inside its fenced transaction.

### The staging batch has the right documented contract

New case 029 crosses the real 32-source boundary using 33 changed types. A corrupt
last member leaves exactly the first committed group, publishes no target, and
leaves `current/minVersion/compatFloor` at `1/1/1`. Restoring the exact injected fault
allows ordinary installer replay to finish; another replay is byte-stable.

Cases 032–036 put different identity/contract faults into a late member of the
first batch. The whole current group rolls back. Worker and Request cannot install
the group. This proves **atomicity per group plus exact resumability**, not atomicity
of an arbitrarily large entire installation. The operator guide states this clearly.

### Types reduce review burden but do not eliminate business-policy review

New row controls show valid V2/V3/V4 source still compiles. Removing reverse/legacy
obligations, changing keys, fabricating title proof, substituting a Revalidate value,
or confusing nominal metadata is rejected. These are useful machine-checked
boundaries. Humans still review the meaning of a converter, its rejection policy,
representative fixtures, reverse-write behavior and the chosen recovery policy.

## 4. New antagonistic suite inventory

`scripts/test-db-migration-review-11.py` has 74 individually named cases:

| IDs | Count | Boundary | Oracle |
|---|---:|---|---|
| 001–016 | 16 | Selector/status function attributes, index shape, ACL, trigger, RLS and ownership drift | Public status refuses without row-state mutation |
| 017–028 | 12 | Request/Worker access to retained bytes, private audits, staging and privileged roles | Denied operation leaves state unchanged |
| 029–036 | 8 | 33-source cross-batch failure, installer role and late-member identity/contract faults | Exact committed prefix or atomic current-group rollback; safe replay |
| 037–048 | 12 | Enqueue/claim/complete rollback, changed-codec isolation, completion audit, status consistency, isolation and cancellation | Ownership/data preservation and status/Contract agreement |
| 049–060 | 12 | Queue callback/fixture ownership, nominal types, private exports, frozen codecs, unreachable bad code and coverage | Coded frontend refusal rather than acceptance or internal error |
| 061–073 | 13 | Three positive row releases plus ten destructive rule/proof/history mutations | Valid source accepted; invalid obligations rejected |
| 074 | 1 | Data-dependent callback exhaustion with healthy peer | Fail-stop/no-publication characterized; restart and status limitation exposed |

The original 074 oracle above describes the committed review baseline. Its current
follow-up oracle requires durable failure evidence, unchanged original data,
same-type and cross-type healthy progress, restart stability and blocked Contract.
New cases 075–087 add predecessor completion/retirement without erasing audit;
private audit access; rollback; stale attempt, foreign transaction, changed bytes
and substituted binding refusal; Request-role exclusion; ACL/missing-table drift;
dead-job schedule/count preservation; concurrent Workers; and independent evidence
for identical bytes on another job ID. The current new suite therefore totals 87.

There are no expected-failure markers or skipped cases in the final new suite.
Positive controls and limitation-characterization cases are explicitly included;
the count is not presented as 74 independent proofs of production readiness.

## 5. Execution evidence

| Check | Result | Evidence |
|---|---|---|
| Baseline new suite | 58/60 passed; cases 044/045 failed | `.tesl-stuff/review11-first.log`, `review11-first/{result,inventory,provenance}.json` |
| Additional row source matrix | 13/13 passed | `.tesl-stuff/review11-row-first.log` |
| Status fix with rebuilt releases | 73/73 passed in 127.901s | `.tesl-stuff/review11-final.log`, `review11-final/` |
| Existing adversarial suite on those releases | 127/127 passed in 448.487s | Same log; `.tesl-stuff/review11-existing-127/` |
| New data-dependent poison case | Passed characterization in 44.593s, including build/tests | `.tesl-stuff/review11-poison.log` |
| Final complete new suite | **74/74 passed in 109.883s**, zero errors/failures/skips/expected failures | `.tesl-stuff/review11-final-74.log`, `review11-final-74/` |
| Ordinary row V1–V4 lifecycle | Passed Retype/WriteBack, Rename, Legacy removal, Revalidate, overlap, repair and Contract | `.tesl-stuff/review11-lifecycle-gates.log` |
| Ordinary queue V1–V4 lifecycle | Passed three conversion/repair/retirement/restart edges | Same log |
| Focused runtime PostgreSQL/race checks | `Test(QueueProjection\|PgRowBaseline\|RowQueue\|QueueRuntime)` passed, 170.464s | Same log |
| Generated/application PostgreSQL conversion/repair group | Passed, 125.900s | Same log; selected compiler source case 51 |
| Embedded runtime and runtime gates | Six seam and three gate checks passed | Same log |

### Follow-up verification after `2d70dae`

| Check | Result | Evidence |
|---|---|---|
| First complete follow-up suite | 85/85 passed, 246.934s; existing 127/127 passed, 394.432s | `.tesl-stuff/review11-failure-final.log`; `review11-failure-final/`, `review11-failure-existing/` |
| Generated PostgreSQL conversion/repair group including cancellation | Passed, 139.400s | Same log |
| Pure adapter/budget race tests | Passed, 1.757s; traps/invalid results have fixed categories, unbound errors do not | `.tesl-stuff/review11-failure-final-gates.log` |
| Final new suite with concurrency/identity extensions | **87/87 passed, 202.211s** | `.tesl-stuff/review11-failure-final-disk.log`; `review11-failure-final-87-disk/` |
| Existing adversarial suite on disk-backed cluster | **127/127 passed, 355.655s** | Same log; `review11-failure-existing-disk/` |
| Focused PostgreSQL/race baseline, queue and runtime checks | Passed, 112.564s | Same log |
| Embedded runtime and gate file sets | Six seam and three gate tests passed | Same log |
| Required cancellation witness and ordinary queue V1–V4 lifecycle | Generated PostgreSQL group passed, 117.704s, with cancellation asserted as a named required pass; all three ordinary queue rollout edges passed | `.tesl-stuff/review11-failure-cancellation-required.log` |
| Direct failed-attempt replay and installed docs | Extended case 074 passed in 26.864s, including a committed protected begin/replay that acquires no new attempt; four detached-doc checks and formatting passed | `.tesl-stuff/review11-failure-replay-final.log` |

The first attempt to run the extended suite failed in PostgreSQL database cloning
with `Disk quota exceeded` and `checkpoint request failed` on shared `/tmp`; it
did not reach the new concurrency cases. The review harness now puts database/WAL
files under its output directory, keeps only the short socket/log path in `/tmp`,
and preserves `postgres.log`. The full rerun above passed without changing the
operation deadlines. These targeted results are not a new uninterrupted full gate.

The cancellation witness is a required named pass in compiler source group 51.
It cancels after an attempt is begun, requires exact pre/post job equality and zero
attempt/failure/receipt rows, then converts that same job successfully afterward.
Pure adapter tests additionally require sanitized stable classifications for traps
and invalid results, and no execution-fault classification for unbound versions.

These local `.tesl-stuff` artifacts are ignored evidence outputs, not committed
fixtures. The repository runners and examples reproduce the scenarios. Provenance
records the baseline commit and compiler/binary hashes; the baseline commit alone
does not describe the uncommitted fix. Broad runtime checks may contain fixture-
dependent tests not enabled by their focused environment; no claim that every
runtime test in the package executed is made.

### Reproduce

From the repo root, inside the Nix development environment, with a new artifact
directory and `TESL_REPO_ROOT` set:

```sh
python3 scripts/test-db-migration-review-11.py \
  --artifacts .tesl-stuff/review11-reproduction-releases \
  --output .tesl-stuff/review11-reproduction --build

python3 scripts/test-db-migration-review-05.py \
  --artifacts .tesl-stuff/review11-reproduction-releases \
  --output .tesl-stuff/review11-reproduction-existing

python3 example/db-three-upgrades/run.py \
  --output .tesl-stuff/review11-reproduction-releases/row --run-built
python3 example/queue-three-upgrades/run.py \
  --output .tesl-stuff/review11-reproduction-releases/queue --run-built
```

Use `--match 044`, `--match 029` or `--match 074` for a targeted regression.
The new suite is also mandatory at the end of the default migration gate.

## 6. Recommended next milestone

1. **Operational failure/recovery:** specify and test the poison-value lifecycle,
   including peer progress, protected diagnosis and immutable remediation.
2. **Measured scale:** finish the greater-than-turn-budget scenario without hiding
   enqueue/conversion costs behind broader timeouts; measure ordinary release builds.
3. **Gate completion:** obtain one uninterrupted default migration-gate result on
   the final tree, then keep the new cross-boundary cases mandatory.
4. **Scope expansion by acceptance scenario:** choose one representative mixed
   application history only after its claim, writer-overlap and retirement
   obligations are explicit. Preserve existing scope refusals meanwhile.

Exit criteria should be lifecycle statements, not a larger test count: every
accepted transition either completes under stated preconditions or has a precise,
supported recovery path; unsafe transitions refuse without invented authority;
and status tells the operator what actually prevents completion.
