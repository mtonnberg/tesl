# Database migrations — executive review 11

Original review: 2026-10-07, baseline **`ebca5fe` (`wip`)**. Current assessment:
2026-10-12, including readiness fixes after **`f436e7f`**. Technical discovery history, test inventory,
commands and logs: [db-migration-review-11.md](db-migration-review-11.md).
The [delivery status](dev-docs/migration-delivery-status.md) maps the implementation
to the original roadmap and final acceptance gates.

## Bottom line

**Local acceptance is green:** authoritative `./ci.sh` completed with all 24 phases
OK, no skips and exit 0 in 12,489 seconds. The same invocation includes all 47
migration phases, 244 adversarial cases and V1–V20. Log:
`.tesl-stuff/readiness-ci-final-gate.log`. Hosted PostgreSQL matrix results remain
required; the broader original roadmap stays open.

**Latest performance result:** after `3242931`, repeated inventory work was reduced
without changing per-job commits or ownership/finality obligations. The 257-type
reference workload now reaches all types in **24.54s and 24.55s**, versus 685.73s
previously—about 28× faster. The 25-second check passes with a small margin, not a
general SLA. Enqueue setup remains about 45s. All 117 review cases and 127 existing
cases pass in the complete gate above. The performance samples retain their
original binary provenance; they are not a new Go 1.26.9 throughput measurement.

**Latest remediation decision:** following the maintainer's request for both
preservation and explicit loss policies, `QueueRepair` now supports
`on: "execution-failed"` for corrected conversion and `on: "unconverted"` with a
reason for audited discard. Both complete real deployment/retirement witnesses.
The separate recovery-keyword proposal is superseded, not a release blocker.

**Baseline local validation is complete. The clarified release requires automatic
deployment, catch-up and an executable ordered row/queue migration path; current
implementation progress is recorded below.**

**Subsequent release clarification:** automatic production migration and catch-up
from any earlier supported schema version are required. Two ordered row/queue
migrations are acceptable with a constructive diagnostic. At that clarification,
the retained-history refusal still blocked this sequence; subsequent increments
below implement it. CI preview is sufficient; editor apply and other operator conveniences
are not merge blockers. Thus green local CI establishes the implemented scope,
not completion of the clarified release. The [delivery requirements](dev-docs/migration-delivery-status.md#clarified-release-requirements-maintainer-2026-10-12)
record the updated acceptance criteria.

**Implementation continuation after `b5cddb9`:** additive catch-up now executes
missing checked row revisions using the latest Worker, with restart, concurrency,
source/ABI refusal and index-readiness witnesses. Compatible row/queue compiler
upgrades still pass. Subsequent increments add row-transforming and queue catch-up,
then the tested ordered row-first / payload-second path with atomic job restamping
and intermediate finality. `--schema deploy` and a gated Compose rollout now wire
the separate Installer and Worker phases into production deployment.
See the delivery status for current targeted evidence; the earlier full CI pass
is not claimed for these continuations.

The system now demonstrates genuine repeated deployments, exact immutable history,
typed conversion and repair, separate operating roles, overlap, retirement and
restart. Recent performance work also gets 257-type applications through build,
installation and replay.

The latest focused evidence is **117 review cases plus 127 existing adversarial
cases**, 58 compiler queue-source/PostgreSQL cases and focused runtime race and
embedding checks. A confirmed status defect and poisoned-callback progress failure
were fixed. Explicit typed recovery and audited discard now have deployment and
retirement witnesses.

A historical uninterrupted default gate includes a real **V1–V20 four-table
application history and 95 PostgreSQL-backed Tesl API tests**. It found and fixed
three composition defects around unchanged-table codecs, additive epochs after
completed Contracts and predecessor reads during the next transformation. That
full pass predates the latest queue remediation/admission work. A later run stalled
in nominal-PK fixture 18; its isolated retry passed. The final authoritative run
now includes all that work and passes uninterrupted.

## 1. Decision-oriented status

| Area | Assessment | Implication |
|---|---|---|
| Frozen source, nominal types and proof obligations | Strong implemented foundation | Preserve it; ordinary writers and historical codecs remain part of the safety argument. |
| Row migration lifecycle | Real V1–V20 multi-table deployment and 95 API cases pass | Interleaved additive and transforming releases preserve twenty data cohorts across four tables, overlap, rejection/repair, retirement and restart. |
| Queue conversion, repair and retirement | Real repeated deployments pass within restricted history rules | Keep the consecutive queue-only model until broader composition has its own full-lifecycle witness. |
| Permissions, catalog integrity and replay | Strong targeted adversarial results | Weakened SQL functions/indexes/grants and mismatched staging refuse; batch retries preserve exact history. |
| Status correctness | New defect fixed | Current-version quarantine remains visible without falsely blocking retirement or hiding old backlog. |
| Callback failure recovery | Explicit recovery and discard now implemented and tested | New typed revisions consume exact operational failure, or deliberately discard obsolete old work with immutable audit. Healthy peers continue; active claims and Contract fences remain authoritative. |
| Scale | Two ordinary-build samples meet the 25s reference target | 24.535s/24.549s, with busy-head work remaining. Small margin; contention and broader workloads remain unmeasured. This is separate from the pinned p99 release gate. |
| Verification | Authoritative local CI passes all 24 phases | Includes the complete 47-phase migration runner, both V1–V4 examples, 244 adversarial cases and V1–V20/95 API cases. Hosted supported-major results remain pending. |

## 2. What this review found

### Fixed: status could prescribe the wrong work

A quarantined current-version job was reported as a historical migration blocker.
It could also suppress the warning for an unrelated old job awaiting conversion.
Contract correctly allowed retirement when only the current quarantine remained,
so status and the actual retirement decision disagreed.

The fix separates operational totals from historical blocker counts. New tests
reproduce both failures and verify the correction through protected public tools.
This was an operator-correctness defect, not an observed data-loss or unsafe-
retirement defect.

### Fixed within the documented policy: execution failure and recovery

A converter that passed ordinary fixtures but recursed on one historical value
originally stopped the shared Worker without a useful diagnosis. The follow-up
records a distinct immutable execution-failure audit and suppresses automatic retries of the same
checked source/bytes for that job. Healthy jobs, including peers of the same type,
continue. Protected status explains the failure; old work still blocks retirement.
Cancellation and database errors remain rollback events, not callback verdicts.

An end-to-end test also exercises existing predecessor claim/completion while that
version remains admitted: the original job is processed, Contract succeeds, and
the audit survives. New typed `on: "execution-failed"` revisions now also consume
the exact failure/source/original-byte identity. Explicit `on: "unconverted"`
discard revisions resolve obsolete work, including malformed bytes, without
decoding it and with immutable audit. These policies preserve active claims and
Contract obligations. The separate recovery-keyword proposal is superseded.
See [queue remediation](manual/queue-remediation.md) for the authored decisions and
fixture requirements. Execution budgets still do not prove termination or bound
memory, and unresolved old work still blocks retirement.

### Measured: large-inventory progress; broader scale acceptance remains open

The recent optimizations have concrete value: shared compiler checking, bounded
filenames, validated metadata reuse, and fenced staging groups get 257 types through
installation and exact replay. They preserve the important safety boundaries.

The full ordinary-build workload now enqueues 1,024 head jobs plus 256 rare jobs
and reaches first conversion for every type within the unchanged 25-second target
in two runs. Profiling identified repeated inventory set comparison, parsing and
transaction-local validation as the dominant costs. The final implementation
retains full admission at Begin and exact transaction-bound publication authority.
See [performance evidence](dev-docs/queue-admission-performance.md). This measures
first progress, not full backlog drain, retirement at that scale or a production SLA.

## 3. Architectural judgment

**Keep:** frozen schemas/codecs, distinct old/new nominal types, explicit
transformation decisions, immutable receipts, actual source/compatibility fences,
installer/Worker/Request separation and explicit Contract finality.

**Keep with its stated boundary:** sharing checked immutable source metadata and
grouping up to 32 staging lineages. New tests establish rollback of the current
group and replay of earlier committed groups. This is resumable installation,
not one atomic transaction for the entire deployment.

**Do not infer:** totality from purity, full policy correctness from a few fixtures,
runtime finality from an empty scan, production scale from successful compilation,
or arbitrary compiler/catalog substitution from one compatible upgrade witness.

Types and proofs already reduce what a human must review. Humans still own the
meaning of conversion, rejection, reverse writes, fixtures and data-loss/recovery
policy. Making those choices explicit is a strength, not unnecessary ceremony.

## 4. Deliberate scope and remaining product decisions

The maintainer's fresh-catalog-first policy remains reasonable during development.
Missing or incompatible catalog objects must refuse explicitly. Before a release
promise is made, catalog compatibility and adoption need an explicit contract.

Other boundaries remain visible:

- Consecutive queue-only non-additive histories with retained membership and
  unchanged stored entities.
- No unrestricted mixed row/queue history claim.
- Malformed bytes can be explicitly discarded with audit, not reconstructed as
  typed values. General schema-level `IgnoreOld` remains unsupported.
- No arbitrary active-edge compiler replacement.
- No static termination proof, memory sandbox or hard intrinsic preemption.

These are not all bugs. They are constraints that must be reflected in the product
promise and refusal diagnostics. Expanding them should start with a concrete user
scenario and its proof/fencing/recovery obligations.

## 5. Recommended order of work

1. **Preserve acceptance and obtain hosted results.** The shared complete migration
   runner and authoritative CI pass locally. Keep phase timings/failure diagnostics
   and require the configured PostgreSQL matrix before merging.
2. **Reconcile the release contract.** Keep the original roadmap open. The
   [delivery matrix](dev-docs/migration-delivery-status.md) names missing operator,
   editor, durable-facility, composition and pinned-performance requirements.
3. **Broaden performance evidence.** Measure contention, history growth, repair
   depth and expensive callbacks. Preserve the separate pinned p99 release gate.
4. **Widen composition with an explicit witness.** Choose a representative mixed-history application
   and require full overlap, claim, repair, restart and retirement evidence.

## Overall recommendation

Continue the work; do not rewrite the architecture. The recent improvements and
adversarial results are substantive. Keep the release claim narrow until safe
refusal becomes an explainable, recoverable lifecycle under the workload users
will actually deploy.

The next success metric should be **“the operator can safely finish or recover an
accepted deployment”**, not simply more syntax or more green test cases.
