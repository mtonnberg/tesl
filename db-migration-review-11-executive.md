# Database migrations — executive review 11

Date: 2026-10-07. Baseline: **`ebca5fe` (`wip`)**. Technical findings, test inventory,
commands and logs: [db-migration-review-11.md](db-migration-review-11.md).

## Bottom line

**The architecture is sound enough to keep investing in. The next milestone
should complete failure recovery and establish practical scale limits—not add
more migration forms.**

The system now demonstrates genuine repeated deployments, exact immutable history,
typed conversion and repair, separate operating roles, overlap, retirement and
restart. Recent performance work also gets 257-type applications through build,
installation and replay.

This review added **74 adversarial/control cases** and reran **127 existing cases
against fresh releases**. All 201 pass. Both row and queue V1–V4 applications and
focused runtime/PostgreSQL gates pass. A confirmed status defect was fixed.

Those results justify **scoped fresh-install evaluation**. They do not justify an
unrestricted production-readiness claim: one poisoned conversion can still halt
the shared Worker without a useful durable recovery diagnosis, and large-inventory
runtime throughput/fairness remains unverified.

**Follow-up after `2d70dae`:** durable callback-failure diagnosis and peer progress
are now implemented and verified. The new suite has grown to 87 passing cases,
alongside the 127 existing cases. An admitted predecessor can resolve a still-
processable failed job without erasing the audit. General typed callback-failure
recovery and large-inventory runtime acceptance remain open.

## 1. Decision-oriented status

| Area | Assessment | Implication |
|---|---|---|
| Frozen source, nominal types and proof obligations | Strong implemented foundation | Preserve it; ordinary writers and historical codecs remain part of the safety argument. |
| Row migration lifecycle | Real V1–V4 deployments pass | Retype/WriteBack, Rename, Legacy removal and proof Revalidate work in the tested scope. |
| Queue conversion, repair and retirement | Real repeated deployments pass within restricted history rules | Keep the consecutive queue-only model until broader composition has its own full-lifecycle witness. |
| Permissions, catalog integrity and replay | Strong targeted adversarial results | Weakened SQL functions/indexes/grants and mismatched staging refuse; batch retries preserve exact history. |
| Status correctness | New defect fixed | Current-version quarantine remains visible without falsely blocking retirement or hiding old backlog. |
| Callback failure recovery | Diagnosis and peer isolation implemented; general typed recovery remains open | Recognized execution faults retain original data and durable evidence; healthy jobs proceed. A limited admitted-predecessor processing route is verified. |
| Scale | Measurable progress, incomplete acceptance | 257-type install/replay passes; protected bulk enqueue still prevents the full fairness workload reaching conversion. |
| Verification | Broad fresh evidence; full-gate result still pending | Follow-up evidence covers 214 Python cases and focused gates; no new uninterrupted default migration gate or whole-compiler run is claimed. |

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

### Open: preserving failed data is not the same as recovering it

A new test supplies a converter that passes its ordinary fixtures but recurses on
one specific historical value. The execution budget stops it safely. However:

- The shared schema Worker exits before converting a healthy peer type.
- Restart hits the same poison value again.
- No durable conversion outcome records the operational failure.
- Status only says old payloads remain and recommends running the Worker.

The existing typed repair protocol handles business rejection. This failure does
not produce that rejection, so its recovery cannot be assumed. The passing test
characterizes the limitation; it does not certify healthy progress.

That was the committed review's behavior. The follow-up now records a distinct
immutable execution-failure audit and suppresses automatic retries of the same
checked source/bytes for that job. Healthy jobs, including peers of the same type,
continue. Protected status explains the failure; old work still blocks retirement.
Cancellation and database errors remain rollback events, not callback verdicts.

An end-to-end test also exercises existing predecessor claim/completion while that
version remains admitted: the original job is processed, Contract succeeds, and
the audit survives. This covers still-processable old work. It does not invent a
business rejection, reinterpret `QueueRepair`, or solve all failed repairs and
quarantines. The remaining decision is the general typed remediation protocol.

**Highest-priority remaining decision:** define typed callback-failure remediation
that consumes this new evidence while retaining exact source identity and original
data. Healthy-peer continuation is now implemented and tested. General remediation
should be an auditable protocol with explicit retirement obligations, not an
operator escape hatch or an edit to deployed history.

### Open: large-inventory installation is ahead of runtime acceptance

The recent optimizations have concrete value: shared compiler checking, bounded
filenames, validated metadata reuse, and fenced staging groups get 257 types through
installation and exact replay. They preserve the important safety boundaries.

The full workload still fails while enqueueing 1,024 jobs through protected APIs.
These are race-instrumented measurements on a shared host, so they are not a
production throughput benchmark. They do show that a complete lifecycle at that
inventory size has not been established. Increasing deadlines alone would not
answer the throughput or fairness question.

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
- No general malformed-byte recovery or implemented `IgnoreOld`/audited discard.
- No arbitrary active-edge compiler replacement.
- No static termination proof, memory sandbox or hard intrinsic preemption.

These are not all bugs. They are constraints that must be reflected in the product
promise and refusal diagnostics. Expanding them should start with a concrete user
scenario and its proof/fencing/recovery obligations.

## 5. Recommended order of work

1. **Complete operational failure recovery.** Produce one end-to-end witness where
   a poison callback stops safely, status explains it, an immutable remediation is
   deployed, healthy work has the chosen progress behavior, and Contract eventually
   completes without discarding authority or original data.
2. **Establish scale targets.** Measure startup, enqueue, idle/active conversion,
   history growth and repair depth with both race and ordinary release builds.
   Finish the 257-type runtime scenario with stated latency and resource budgets.
3. **Complete the full gate.** Run the entire mandatory gate uninterrupted on the
   final tree. Review 11's new suite is now wired into it.
4. **Then widen composition.** Choose a representative mixed-history application
   and require full overlap, claim, repair, restart and retirement evidence.

## Overall recommendation

Continue the work; do not rewrite the architecture. The recent improvements and
adversarial results are substantive. Keep the release claim narrow until safe
refusal becomes an explainable, recoverable lifecycle under the workload users
will actually deploy.

The next success metric should be **“the operator can safely finish or recover an
accepted deployment”**, not simply more syntax or more green test cases.
