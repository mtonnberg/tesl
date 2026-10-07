# Database migrations — critical technical review 11

Date: 2026-10-07. Review baseline: **`ebca5fe` (`wip`)**, committed at the user's
request before this review. The status correction and new tests described below
are subsequent working-tree changes. See the
[executive review](db-migration-review-11-executive.md) for decisions and priorities.

## Bottom line

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
| R11-02 | High operational gap | A data-dependent exhausted callback stops the entire schema Worker, leaves no durable conversion outcome, and repeats on restart | **Confirmed and open**, new case 074; no unsafe partial publication observed |
| R11-03 | High scale-acceptance gap | 257-type build/install/replay is verified, but the full workload does not reach conversion because bulk protected enqueue exceeds its setup deadline | **Open**, prior measured evidence retained; no large-inventory fairness claim |
| R11-04 | Medium verification gap | A broad fresh targeted set passes, but no fresh uninterrupted default migration gate has completed for this review | **Open evidence item**, do not substitute counts for the complete gate |
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
