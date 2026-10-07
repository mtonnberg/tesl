# Database migrations — executive review 05

**Assessment as of review 05, 2026-10-06.** This is a decision-oriented assessment
of the feature, including the fixes made during the review. Detailed findings are
in [the technical review](db-migration-review-05.md); test counts, commands and
logs are in [the evidence appendix](db-migration-review-05-evidence.md).

## Bottom line

**Yes: db-migrations is moving in the right direction. Keep the architecture.
The next priority should be completing and hardening the supported deployment
lifecycle, rather than adding more migration forms.**

**R05-01–R05-08 have now been addressed.** SQL invariant holes are closed;
unchanged queued work can retire beside changed work; callback recursion is
operationally bounded; status explains blockers through protected public tools;
and stale gates and installed documentation gaps have been repaired. The current
adversarial suite has **123 cases with passing evidence and no expected failures**
(122 together, then the added catalog-refusal case). Follow-up work also verifies
compatible new-edge compiler rollout and fixes reproduced two-type starvation.

The feature has progressed from compiler checks and isolated runtime candidates
to real, repeated application deployments. Four-release examples now exercise
different non-additive database changes and successive queue conversions, repairs
and retirement on the same database. This is meaningful progress toward Tesl's
goal: less migration code and fewer implicit assumptions for a human to audit.

**It is not yet ready for a broad production-readiness claim.** The implementation
was strongest at deciding what is allowed and refusing unsafe changes. The follow-up
now closes the confirmed accepted-scope retirement hole and supplies bounded
execution and blocker diagnostics. A general recovery/discard path for malformed
historical bytes and unrestricted history composition remain outside scope. Ordinary
SQL writes could bypass the type/proof guarantees on which migration safety
depends. Those holes were fixed, but they justify broader invariant-based review.

My recommendation is a **hardening milestone with explicit exit criteria**, not a
rewrite and not an unrestricted release. Fresh-install, explicitly scoped
evaluation is a reasonable next use; treating every compiling history as a
complete operational solution is not.

## 1. Where the feature stands

| Area | Current status | What this means |
|---|---|---|
| Frozen schema history and checked transformations | Implemented and exercised | Old/new ownership, codecs and proof dependencies are explicit; edited history cannot quietly become new authority. |
| Non-additive row migrations | Working within supported rules | Public deployments cover Rename, Retype/WriteBack, Legacy removal and proof Revalidate; bounded whole-table Drop has separate coverage. |
| Repeated non-additive queue migrations | Working within a narrow supported scope | Ordinary V1–V4 binaries execute conversion, typed repair, Contract and restart. Queue/job membership and stored entities remain unchanged. |
| Overlap, retirement and replay | Substantial implementation and evidence | Old/new representations coexist; fences and durable receipts govern when old writers and storage can be retired. |
| Progress and recovery | Confirmed retirement defect fixed; broader recovery remains limited | Unchanged delayed/dead jobs are audited and restamped at Contract. Malformed historical data still lacks a general typed recovery/discard path. |
| Type/proof foundation | Shared defects fixed; complete compiler suite passes | SQL writes enforce destination types and proof dependencies; positive and adversarial controls pass. |
| Callback execution bounds | Operational policy implemented | Fuel/depth/cooperative deadlines stop generated recursion and loops without publication. No static totality or hard intrinsic-preemption claim. |
| Operator experience | Public blocker diagnosis implemented; further polish possible | Status reports counts, repair revisions, claims, attempts and recent instances with stable codes/actions, without exposing retained bytes. |
| Lessons and embedded reference | Current workflow and unified operator guide available | Installed help includes lesson 96, linked examples and the role/blocker/recovery guide. |
| Long-term compatibility and scale | Compatible new-edge rollout and bounded fairness verified; broader scale remains limited | Actual A/B/C tests cover new queue edges and active-edge refusal. Two-type load/restart and 1,024-receipt indexed lookup pass; production-scale latency and arbitrary binary substitution remain unproven. |

This is **a functioning scoped system undergoing hardening**, not a design-only
prototype. It is also not a general solution to every schema evolution pattern.
The distinction matters: missing scope should be refused clearly; supported scope
should work through completion and recovery.

## 2. Why the direction is good

### It models the actual problem: several versions sharing durable data

An SQL change alone cannot establish that an old binary can still read or write a
new representation. Tesl makes source schemas, stored representations and admitted
application versions separate concerns. That is the right foundation for rolling
deployment. Keeping old storage during overlap and requiring an explicit cleanup
phase is justified complexity, not incidental ceremony.

### It puts business decisions in typed code and mechanical decisions in the compiler

The developer decides what an old value means, when to reject it, what a repair
should do, and what old readers should see. The compiler checks identities,
dependencies and evidence, and derives much of the physical work. This division
can substantially reduce review burden. The developer should review a conversion
policy and its consequences, not manually reconstruct a distributed state machine.

### It distinguishes static evidence from runtime completion

A compiled converter is not permission to rewrite an arbitrary database. A
successful batch is not proof that retirement is safe. Installed identity,
immutable receipts, version fences and finality checks provide the runtime half.
That separation is one of the solution's strongest decisions and should be kept.

### It preserves failed work instead of manufacturing success

Rejected queue payloads keep their original representation and source version.
Repairs append new checked history rather than modifying the deployed converter.
This makes recovery explainable and auditable. The right follow-up is to complete
recovery and inspection, not weaken those guarantees to make deployment appear
successful.

## 3. Important decisions already made

These are existing implementation or maintainer decisions, not new approvals
requested by this report.

| Decision | Benefit | Cost or implication | Assessment |
|---|---|---|---|
| Schema-owned, frozen historical types and codec closures | Makes old data meaning explicit and detects changed history | History must be preserved; ordinary refactoring cannot rewrite deployed meaning | Keep. Essential to the safety claim. |
| Explicit `Same`, `Migrate`, `Revalidate`, `Retype`, `WriteBack` and legacy-value rules | Separates unchanged meaning, validation, representation change and reverse compatibility | More concepts for the developer to learn | Keep distinctions; simplify how they are explained and diagnosed. |
| Retain old representations during overlap, remove them through Contract | Supports old readers/writers without premature destructive cleanup | Temporary columns/triggers and multiple lifecycle phases | Keep. Expose the phases clearly rather than hiding them. |
| Immutable installed history bound to a database and physical plan | Prevents replay against the wrong installation or substituted history | More metadata and verification work | Keep; measure its growing operational cost. |
| Dedicated installer, Worker and Request roles | Limits who can register history, perform schema work and handle requests | Credential/configuration complexity | Keep; provide a clear role/command reference and actionable errors. |
| Rejection preserves source data; typed repairs append revisions | Avoids silent loss and editing history to fit current data | Rejected work can block retirement until policy is supplied | Keep. This is intentional business review, not an error to auto-discard. |
| No ad hoc operator discard; explicit `IgnoreOld` would carry that decision | Makes data loss deliberate and auditable | The planned discard mechanism is not implemented, leaving some recovery gaps | Keep the principle; decide and implement the supported recovery policy. |
| Fresh-install-first; old catalogs may refuse rather than auto-upgrade | Keeps implementation focused and avoids invented historical authority | Existing installations lack an adoption path | Accept for current development scope, as already directed. Define the release compatibility promise before freezing it. |
| Initial queue composition restricted to consecutive queue-only edges | Makes a complex protocol tractable to implement and verify | Mixed row/queue changes and broader history shapes remain unavailable | Sensible staging decision. Do not confuse it with the final product scope. |
| Later non-additive queue edges require the exact retired predecessor | Bounds the active compatibility problem | Operators must finish one edge before beginning the next | Keep for the supported model; make the prerequisite visible in planning/status. |
| Cooperative callback execution budget | Stops generated recursion/loops and prevents usable late results | 100,000 steps, 128 nested calls, two-second cooperative deadline; an individual intrinsic is not forcibly preempted | Implemented for R05-04. Do not present it as a static termination proof or memory sandbox. |

These choices form a coherent design. The principal risk is not that the choices
contradict each other; it is that some guarantees stop at subsystem boundaries or
cover only the simplest composition of otherwise supported cases.

## 4. What the review changed in our understanding

### A safe refusal is necessary, but not sufficient

The delayed unchanged-job bug was the most important architectural signal. The
compiler accepted the history but retirement could not finish without waiting for
future work. That supported-scope defect is now fixed by audited same-contract
restamping under the actual retirement fences. The general lesson remains:
**safe refusal alone does not establish operational completion.** Future scope
expansion must test that property rather than only successful type checking.

### Migration proofs are only as strong as ordinary application writes

The SQL proof/type bypasses show why reviewing converters alone is inadequate.
If a current writer can invalidate a stored proof after migration, finality does
not establish a durable guarantee. The fixes belong in the shared type system,
as implemented during this review. Future review must follow invariants through
creation, reads, updates, upserts, decoding and subsequent migrations.

### The examples now prove useful things, but not everything their names might suggest

The row example tests different non-additive changes across releases; the queue
example proves repeated public conversion/repair/retirement. Actual compiler A/B/C
coverage now additionally proves compatible new-edge rollout and active-edge
refusal. This does not establish arbitrary mixed histories, every production
topology, unrestricted binary substitution or bounded performance on large data/history. Keep using examples
as acceptance scenarios, with each guarantee and excluded dimension named.

### Verification quality needs attention alongside implementation quality

The initial 107-case suite exposed a failing requirement; the extended suite
now has 123 cases with passing evidence without expected failures. Baseline compiler failures were
repaired and the complete compiler suite passes. Cleanup now uses a separate
non-executor identity, while still waiting for all actual executor backends.

The final migration evidence is split: a user-interrupted run passed the main
application/kernel package and preceding phases; the query suite and complete
remaining tail passed on resumed private-cluster runs. This verifies every
mandatory phase, but is not described as one uninterrupted invocation. Keeping
that distinction visible is part of making the gate trustworthy.

## 5. Open questions and recommended direction

| Question | Why it matters | Recommended direction |
|---|---|---|
| How far should the progress guarantee extend beyond the fixed subset? | Broader composition creates new overlap and claim states | Preserve audited restamping/finality; require a full lifecycle acceptance scenario for each scope expansion. |
| Is stronger isolation needed beyond the implemented execution budget? | Cooperative bounds do not hard-preempt a single intrinsic or constrain all memory allocation | Keep fuel/depth/deadline enforcement now; measure intrinsic and large-input behavior before deciding on process isolation or a stricter language subset. |
| How does an operator recover malformed historical data? | Typed repair correctly requires a decodable old value, but cannot handle every corruption | Keep malformed bytes distinct from business rejection. Specify supported recovery or explicit audited loss; do not add an untracked force/discard escape hatch. |
| How far should compiler compatibility extend beyond the tested new-edge upgrade? | Actual A/B/C rollout now passes, but does not establish arbitrary same-version binary substitution | Keep stored-value compatibility separate from pinned active execution identity; specify any additional supported substitution through its own acceptance scenario. |
| Which mixed history is the next supported unit? | Users will combine additive changes, row transformations and queue evolution | Start with a concrete application scenario and its compatibility obligations; generalize only after the current lifecycle closes correctly. |
| What additional operator detail is necessary? | Aggregate blocker codes now exist, but malformed-data recovery and large inventories remain difficult | Extend bounded inspection only where a concrete recovery workflow needs it; preserve payload privacy and explicit completeness flags. |
| How much retained history can the system support efficiently? | Catalog checks, repair chains and receipts grow over time | Measure inspection/dispatch cost and fairness before choosing caching, pruning or larger batch policies. |
| When is the control-catalog compatibility contract frozen? | Fresh-install-first is reasonable during development, but cannot remain an implicit release policy | Preserve the current scope decision; explicitly version the release contract before promising upgrades of deployed catalogs. |

## 6. Recommended next milestone and exit criteria

**The R05-01–R05-08 hardening work has now landed in the working tree.** The next
milestone should prove compatibility and composition rather than reopen the fixed
defects as if they were still missing. I recommend:

1. **Close invariant holes.** Keep the SQL fixes, test ordinary writer boundaries,
   and resolve dependent-field cases without migration-specific exceptions.
2. **Preserve lifecycle closure.** Keep the new unchanged-job, claim, rollback and
   audit tests mandatory as mixed histories are introduced.
3. **Define malformed-data recovery.** Execution exhaustion now refuses publication;
   decide the distinct audited recovery policy for undecodable historical bytes.
4. **Polish operations.** Validate the new blocker/actions against real operator
   workflows and complete a unified credential/recovery guide.
5. **Keep gates reproducible.** Preserve the repaired expectations and cleanup
synchronization; obtain an uninterrupted full run when the host permits it.
6. **Then expand composition and compatibility.** Keep the new compiler A/B/C
   queue regression mandatory and add a representative mixed-history application
   before widening the public scope.

R05-10 now has a concrete scheduling fix: durable least-recently-served receipt
ordering and per-descriptor turn quotas. Keep its continuous-load, restart and
catalog-refusal regressions mandatory. Next set latency/history-size targets and
measure larger inventories and retained history before claiming production scale.

Exit evidence should be a small set of end-to-end guarantees, not a target test
count: accepted histories finish when their stated business preconditions hold;
unsafe transitions refuse without partial publication; interruption resumes from
durable state; and the operator can explain and resolve every supported blocker.

## Overall assessment

The investment is justified. Tesl is building a typed deployment protocol, not
merely a schema-diff tool, and the implementation now demonstrates that model in
real applications. Its conservative history and finality choices are appropriate
for a foundational feature.

The next improvement in quality will come from **closing the gap between the
guarantees promised by the model and the entire lifecycle experienced by a user**.
More migration syntax or more isolated happy paths will not close that gap.
Preserve the architecture, prioritize compositional correctness and operational
completion, and keep the release claim narrower than the design until the
remaining evidence supports it.
