# Database migration review 05 — critical assessment

Date: 2026-10-06. Baseline: `3081667` (requested WIP commit of verification docs),
following feature commit `84782f8`. The decision-oriented status assessment is in
[the executive report](db-migration-review-05-exec.md). Commands, logs and the
numbered test inventory are in [the evidence appendix](db-migration-review-05-evidence.md).

## Current status after fixing R05-01–R05-08

**All eight requested findings now have an implemented remedy and regression
evidence.** The feature is materially healthier than at the initial review:

| Finding | Implemented remedy | Current evidence |
|---|---|---|
| R05-01 | Shared SQL proof checks, including sibling dependencies and joint assignments | Negative and positive compiler cases pass |
| R05-02 | Assignment and insertMany element-type unification | Wrong scalar/collection cases refuse |
| R05-03 | Same-contract restamping inside fenced Contract; immutable private audit | Delayed/dead jobs, old/surviving claims, blockers, replay and transaction rollback pass |
| R05-04 | Generated migration entry/loop metering; shared fuel, depth, cooperative deadline and cancellation | Public Workers stop tail/mutual recursion without payload/receipt publication; runtime cancellation/isolation cases pass |
| R05-05 | Relative overlay fix; updated stale expectations; serialized lint runners; separate cleanup identity | Complete compiler suite passes; migration gate phases pass across interrupted-prefix/resumed-tail runs |
| R05-06 | Current operator-oriented lesson 96, with execution model and limitations | Current lesson checks pass |
| R05-07 | Bounded embedding of linked examples and detached-binary retrieval tests | Installed help retrieves README, runner and templates |
| R05-08 | Protected read-only aggregate queue status, blocker codes/actions, repair revisions, recent instances and index projection | Request-role status distinguishes blockers, preserves state and withholds original payloads |

The suite has grown to **127 cases with passing evidence and no expected failures**
(122 in one invocation, followed by catalog-refusal, multi-type and staging cases). Four
runtime budget tests are additional, not folded into that count. The initial
107-case results below are historical discovery evidence, not the current verdict.

The latest single migration-gate invocation was interrupted by the user during
the query suite after its application/kernel package and preceding phases passed.
The query suite was rerun successfully and the entire remaining tail completed on
a fresh private cluster. All mandatory phases therefore have passing evidence,
but this is **resumed verification**, not an uninterrupted full-gate pass.

### Execution policy chosen for R05-04

Migration execution is operationally bounded rather than statically proven total:
100,000 metered steps, 128 nested calls and a two-second cooperative deadline.
Nested helpers cannot renew fuel; budgets are isolated by execution goroutine.
Generated function entries and loop bodies are metered; results are checked before
returning usable outcomes. Queue attempts and row backfill accept their operation
cancellation context. Exhaustion returns an error without publishing a late result.

This is not process isolation, a memory sandbox, or hard preemption of one
intrinsic call. These limits remain explicit. Compatible new-edge compiler rollout
is addressed in the follow-up below; R05-10 now has bounded fairness/history evidence.

### R05-09 follow-up: compatible new-edge compiler rollout verified

After review-fix commit `a125d9c`, a real compiler A/B/C regression reproduced a
staging defect: the new converter ABI was required to equal the completed
predecessor's creator ABI. Staging now retains the predecessor's exact physical
identity/snapshots and stored-value contract, while pinning the new edge to its
linked executable compiler. All new-edge converters must agree on that ABI.

`TestCompiledQueueCompilerUpgradeRetainsPayloads` passes an A-installed/frozen V1
through B-built V2–V4 conversion, repair, retirement and typed completion. A/B have
different source ABIs and identical stored-value compatibility; C is rejected at
the runtime boundary. A separate probe verifies B cannot replace A's active V2,
but can create V3 after A retires V2. Frozen V1 bytes and installed receipt/UUID
identity are preserved. The tested new-edge upgrade gap is closed; arbitrary
same-version substitution, catalog adoption and R05-10 scale/fairness are not
claimed by this witness.

### R05-10 follow-up: durable service ordering and bounded history evidence

An ordinary two-job-type application reproduced starvation: continuously replenished
Delivery work exhausted each fixed-order turn while Other made no progress within
25 seconds. Dispatch now divides the remaining 1–256-job turn budget among remaining
descriptors and orders sources by their latest durable receipt sequence. Restart
therefore retains service ordering without a process-local cursor. The protected,
read-only selector uses a backward `(source_digest, attempt_seq)` index lookup;
catalog verification independently requires that index and the selector function.

Cases 120–123 verify continuous replenishment, restart with old backlog remaining,
indexed lookup after 1,024 actual conversion receipts, and missing-index refusal
without state changes. The 1,024-transaction workload took 41.086 seconds on this
shared host; this is a regression measurement, not a throughput target. The full
122-case suite and generated/application PostgreSQL group passed, followed by the
new case 123 and focused runtime race/catalog checks.

After commit `664428b`, case 124 extended the public workload to 17 changed nominal
types: every type progresses while 1,008 of the first type's 1,024 old jobs remain.
The initial build/run passed in 88.703 seconds. The runner can vary this workload
with `--scheduler-types`; fresh generated trees preserve interrupted build inputs.

A 257-type probe did not complete preparation: the original 120-second preparation
deadline expired, and a longer attempt hit the outer 660-second command deadline.
It therefore supplies no runtime scheduling result. Source inspection identifies
repeated per-converter capture/check/lowering in `prepare_queue_decisions` and
`check_conversion` as a preparation-cost candidate. The later profiling follow-up
below identifies specific hot paths without claiming a full timing attribution.

#### Preparation profiling after `b2f664f`

Five interrupted native stack snapshots exposed repeated fixture-signature
resolution in `prepare_queue_decisions`: every old payload walked every fixture
and repeated export lookup. Fixture routing now resolves the nominal return type
once per fixture inside the same captured source scope, then selects by exact
identity. For the 257-type fixture, the routing pass resolves 257 signatures
instead of 66,049 payload/fixture pairs. Parameterless-function, builtin Maybe,
ownership and independent converter checks still apply.

Subsequent snapshots reached whole-helper lowering, inventory closure derivation
and repeated content hashing. Broader graph/inventory/hash memoization trials did
not complete the large preparation workload within their deadlines and were
removed. The retained change is the local routing optimization; a final 257-type
preview still exceeded a bounded 90-second probe. No wall-clock speedup or 257-type
runtime result is claimed.

The final implementation passes all 51 non-PostgreSQL queue-source cases, 43 row
transformation cases and the generated/application PostgreSQL conversion/repair
group. The 17-type workload also passes after rebuilding with the current compiler.
The fixture cache now records the compiler binary hash and emits into fresh build
directories so stale or interrupted outputs cannot masquerade as new evidence.
Next quantify and consolidate repeated whole-graph work under an explicit shared
captured judgment, with source-mutation tests at its publication boundary.

#### Shared source judgment after `f5097a4`

That shared judgment is now implemented. Declaration preparation groups requests
by their original helper owner, checks each captured helper graph once, and derives
the adjacent queue inventories, helper IR and snapshot/storage digests once per
group. Every request retains its own exact payload, callback, fixture and codec
checks. The complete group returns only after the source/ABI postconditions pass;
each resulting opaque descriptor retains its publication guards. Original inventory
order is restored across helper groups. Ordinary single-converter and contextual
repair checking use the same factory with one request.

The 257-type preparation preview now completes: **78.42 seconds**, 219,420 KiB peak
RSS, `ok: true`, `compilable: true`, no diagnostics. The first complete build then
reproduced an emitter defect: unary collision suffixes made callback-wrapper
filenames exceed the filesystem component limit. Wrappers now use numbered symbol
seeds and bounded project-unique serial filenames. Both ordinary, race-instrumented
257-type V1/V2 binaries subsequently built successfully.

Five new compiler cases verify byte-identical single/batch certificates, whole-group
refusal for invalid members, pre/post source mutation, and separate helper ownership
and publication guards. All 51 earlier non-PostgreSQL queue-source cases, 43 row
transformation cases, the generated/application PostgreSQL group, and the fresh
17-type public workload also pass.

**The remaining large-inventory boundary is installation.** The 257-type V2 install
exceeds the default command deadline. A separately recorded 30-second pool/command
budget also fails to finish within the runner's 45-second outer limit; the runtime
progress oracle remains 25 seconds. Thus no greater-than-turn-budget fairness pass
is claimed. Go init tracing additionally measures 10.96 seconds before rejecting
an invalid schema command, with substantial metadata initialization allocation.
Next profile initialization and the repeated complete catalog inspections in
per-converter staging; preserve admission fences and independently checked catalog
identity when consolidating work.

#### Registered projection and bounded installation after `0f19866`

Measured installation failed before staging any converter. A CPU profile identified
repeated decoding of immutable linked queue metadata; the database log's initial
inspection spanned about 0.23 seconds. The registered companion now retains its
fully validated V1 source projection and serves independent deep copies for each
requested origin. Exact linked-history identity, all-origin validation, atomic
registration, absent-metadata refusal and independent live database checks remain.
A race regression mutates every returned slice level across concurrent origins,
compares with the strict reader, and rejects substituted linked bytes.

That change advanced the same default-budget probe from zero to 25 staged sources
and reduced wall time from 38.98 to 19.36 seconds. Staging now uses bounded groups
of at most 32 sources per transaction: one exact catalog inspection, then each
source's complete lineage, installed snapshot and immutable replay checks. A late
member failure rolls back its entire group. Completed earlier groups remain
durable and replayable; staging still grants no expansion or dispatch authority.
Admission is shared only for the same queue/version while its actual transaction
fences and the state-row lock remain held. Target staging likewise admits each
distinct queue once while checking every converter.

**257-type installation and exact replay now pass with the default 10-second
command budget.** Case 127 verifies all 257 staged roots and the exact target,
unchanged V1 admission/floors, no V2 physical publication and no jobs. The replay
process took 15.43 seconds including initialization before the internal command
budget starts. Cases 125/126 cover late-member rollback and concurrent replay.
The earlier 17-type runtime workload, PostgreSQL conversion/repair and embedding
gates pass with the new runtime.

The 257-type full fairness scenario now reaches fixture enqueueing, where 1,024
protected enqueue calls exceed the existing 90-second setup limit. No 257-type
runtime fairness pass is claimed. The next boundary is repeated admission cost
in public enqueue and conversion operations; measure these paths before changing
their transaction/finality guarantees.

The reproduced two-type starvation defect is addressed. R05-10 remains partial:
million-job/history scale, inventories larger than the turn budget, formal latency
bounds, memory limits and broad throughput acceptance have not been established.
Receipt ordering is scheduling evidence, never finality; Contract retains its
independent fences and blocker checks. Fresh catalogs contain the new index;
development catalogs missing it explicitly refuse.

## Original review verdict and discovery evidence

**The architecture is moving in the right direction; the supported deployment
lifecycle needs to become complete and operable before public scope expands.**
This is now a working, scoped typed deployment protocol, rather than merely a
schema-comparison prototype. Preserve its frozen history, typed transformations,
overlap storage, immutable receipts and explicit retirement model. Concentrate
the next milestone on the guarantees users experience across the whole lifecycle.

**Do not call this feature universally safe or complete.** The implemented subset
has unusually strong source identity, role separation, immutable history and
transactional fencing. The ordinary row and queue examples exercise genuine
deployments. However, a passing migration gate missed an ordinary SQL-write proof
hole, a missing SQL assignment-type check, and an admitted mixed-payload inventory
whose retirement cannot progress without consuming an unchanged delayed job.

This review added **107 individually named cases**, not 107 assertions or reruns.
They exercise the actual compiler, public binaries and protected PostgreSQL APIs.
The final focused result is **106 passing cases and one explicit expected failure**.
That expected failure is a confirmed unmet requirement, not evidence of safety.
The type/proof defects were corrected in the shared compiler. The liveness defect
remains open. The broad compiler suite also has baseline failures; do not use the
earlier green migration gate as a substitute for a green whole-compiler gate.

## Scope and method

Reviewed the paths from ordinary source through captured schema history, checked
transforms, emitted adapters, physical plans, installation, Worker publication,
attempt fencing, repair, finality, Contract, restart and read-only observation.
Also reviewed fixture semantics, proof producers, repeated deployments, lesson
navigation and installed-binary documentation fallback.

Principal files inspected:

- `compiler/lib/{checker,validation_advanced,migration_queue_transform,migration_queue_repair,migration_row_history,migration_program}.ml`
- `runtime/go/teslrt/migration_row_{command,queue_control,queue_dispatch,queue_retirement,queue_inventory,forward_spec}.go`
- `runtime/go/teslrt/{migration_queue_program,migration_queue_operations}.go`
- `compiler/gen/gen_docs.ml`, `compiler/bin/main.ml`
- `example/learn/lesson82*` through `lesson96*`, especially lessons 93–96;
  `manual/migration-contracts.md`; both four-release runnable examples
- `scripts/run-migration-tests.sh`, the generated queue PostgreSQL fixtures and
  `runtime/go/internal/migrationtest/todo_showcase_test.go`.

This is targeted adversarial review, not a machine-checked proof of every runtime
state or every language construction. Baseline comparisons used a detached
worktree at `3081667`; current source edits were not reverted to manufacture them.

## Original findings by priority at discovery

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| R05-01 | Critical | Structured SQL writes bypassed destination proof obligations | Fixed in shared proof validation; cases 82, 87, 89–94, 104–107 |
| R05-02 | High | SQL update assignments and insertMany elements escaped expected-type checking | Fixed in shared type checker; cases 86, 88, 95 |
| R05-03 | High | Unchanged delayed jobs can block an otherwise valid queue-only Contract indefinitely | Reproduced; open; case 96 is expected failure |
| R05-04 | High | Pure, typed callbacks are not known to terminate; SQL deadlines do not bound CPU execution | Confirmed source characterization; open; case 85 |
| R05-05 | High | Whole-compiler suite and migration gate have different blind spots | Seven failures reproduced on baseline; concurrent linter issue and cleanup flake also observed |
| R05-06 | Medium | Lesson 96 contradicted itself about shipped execution paths | Rewritten around the current operator workflow |
| R05-07 | Medium | Installed help omitted runnable examples linked by migration lessons | Added bounded embedding and seven isolated-help checks |
| R05-08 | Medium | Public status does not explain quarantine/repair progress or populate recent instances | Open; source inspection, not a newly executed assertion |
| R05-09 | High, scope boundary | Fresh-install-only catalog and same-build queue evidence are not a general upgrade story | Explicit limitation; cross-compiler queue upgrade remains unverified |
| R05-10 | Medium | Scale, multi-job fairness and retry ergonomics are under-evidenced | Open; no production-scale claim |

### R05-01 — SQL can destroy the invariant migrations are supposed to preserve

Before the fix, `agent-context` accepted an SQL `update` assigning a raw string to
`title: String ::: AllowedTitle title`. It reported zero errors and zero unproven
obligations. Narrow tests then showed the same omission for structured `insert`
and `upsert`, and for a computed string after validating a different value.

This is fundamental: Revalidate's postcondition cannot protect a schema if its
ordinary current writer can subsequently store values without the required proof.
The defect is in the normal language path, not merely in migration fixtures.
The old proof walker descended into `ESqlQuery` expressions but never checked the
destination field's obligation. A raw literal has no failing subexpression, so the
walk silently accepted it.

Fix in `validation_advanced.ml`:

1. Route structured insert/upsert/update fields through the same proof-call
   checker used for record construction.
2. Include plain supplied fields in proof-subject substitution; checking only
   annotated arguments does not bind a cross-field proof to actual assignments.
3. Reject updates that change a subject of a retained sibling proof without
   re-establishing the dependent field.
4. Reject assumptions that an unassigned stored sibling equals a local proof
   subject. For upserts, a conflict key can establish that particular equality;
   unrelated existing values cannot.

Cases 91, 93 and 105 are positive controls: validated fields and correctly bound
joint assignments continue to compile. Cases 104, 106 and 107 prevent a narrow
"just reject raw title literals" fix. This does not prove every ORM proof feature
sound; record-update and other representation boundaries still need independent
coverage. New diagnostics currently reuse V001 and call-style wording; a dedicated
SQL proof diagnostic would make the fix easier to act on.

The review reproduced compiler acceptance, not a successful persisted invalid
write. Do not inflate that evidence into a claim of demonstrated database
corruption. Compiler acceptance itself violates the promised static boundary.

### R05-02 — SQL assignment types were inferred but not compared

`checker.ml`'s `QueryUpdate` case inferred each RHS then discarded its type.
`QueryInsertMany` returned Unit without checking the named collection. Thus
ordinary source checking could admit a String/Bool assigned to an Int column, or
`insertMany` over `List Int` into an entity. A later emitter/driver failure is not
an acceptable replacement for the compiler-owned type judgment.

The fix unifies each assignment with its actual destination field type and checks
`insertMany` against `List Entity`. Existing insert/upsert scalar checks remain.
This closes a bypass rather than introducing a second migration-specific type
system. The full compiler run did not expose a new assertion failure attributable
to these checks, but its pre-existing failures prevent an unconditional green
compiler claim.

## Overall feature and solution analysis

### The problem being solved is larger than schema evolution

Several application versions may concurrently read, write and process data with
different meanings and representations. Deploying new DDL does not establish
that old writers are compatible, that queued bytes can be decoded, or that
cleanup is safe. The solution correctly treats schema history, physical storage,
application admission and runtime completion as separate but linked authorities.

That makes the architecture more complex than a conventional SQL migration
runner, but much of that complexity is inherent in the problem. The important
question is whether Tesl contains it behind checked plans and an explainable
lifecycle, or makes users reconstruct the protocol themselves. At present the
compiler/runtime foundation is ahead of the operator-facing experience.

### What has materially improved

The implementation now builds ordinary application releases and executes repeated
non-additive changes on one real database. Row examples combine Rename,
Retype/WriteBack, Legacy removal and proof Revalidate. Queue examples run normal
and repaired deployments across V1–V4, preserve receipts through restart and
completion, and reject substituted retirement authority. These are materially
stronger acceptance scenarios than isolated adapters or test-only metadata paths.

They demonstrate a useful abstraction boundary: the programmer reviews business
meaning and explicit compatibility policy; the compiler derives and checks much
of the mechanical migration work. This supports the stated goal of reducing the
amount of code a human must inspect. It does not eliminate the need to review
what a producer of evidence or repair callback actually decides.

### Where the abstraction still leaks

There are three distinct classes of incompleteness:

1. **Accepted scope that does not finish correctly:** the unchanged delayed-job
   retirement blocker. This needs a runtime fix or explicit source restriction.
2. **Missing guarantee within otherwise valid execution:** termination/execution
   bounds and useful blocker diagnostics. A typed, pure converter is not a bounded
   computation, and a generic refusal is not an operational recovery procedure.
3. **Deliberately unsupported scope:** old-catalog adoption, mixed row/queue
   evolution and broader history composition. These are design/scope decisions;
   they must not be conflated with defects in an advertised path.

The review's SQL holes add a fourth lesson: guarantees cannot stop at migration
code. Ordinary post-migration writers are part of the same invariant. Shared
checks are the correct repair; a special migration-only exemption would undermine
the architecture.

### Architectural decisions and their consequences

| Existing choice | Technical consequence | Review position |
|---|---|---|
| Frozen nominal schemas and transitive codec/proof identity | Historical meaning is preserved even when current source evolves | Keep; avoid replacing semantic identity with names or shape equality. |
| Separate unchanged/validation/representation-change rules | Different compatibility obligations can be checked explicitly | Keep; improve rule selection guidance and diagnostics. |
| Retained storage plus typed reverse writes | Old/new applications can overlap without early loss of representation | Keep; test every ordinary writer boundary and mixed composition. |
| Runtime receipts and real admission fences | Static plans cannot manufacture completion or authorize another installation | Keep; completion must consume exact authority, not numeric floors alone. |
| Append-only typed repair after rejection | Recovery policy stays auditable; original bytes are not relabeled | Keep; supply a distinct policy for malformed historical data. |
| Fresh-install-first control catalogs | Development can focus without silently adopting unknown history | Accepted maintainer direction; needs an explicit compatibility contract before release. |
| Narrow queue-only rollout first | Reduces simultaneous protocol dimensions | Reasonable staging; not evidence for unrestricted mixed-history behavior. |
| Installer/Worker/Request separation | Authority is narrower than connectivity | Keep; make credentials and permitted commands easy to understand. |

### Readiness and next step

The appropriate milestone is not "more operations compile." It is: an accepted
history finishes when its documented business preconditions hold, interruption
resumes without stale publication, every supported blocker has a public diagnosis
and recovery action, and the mandatory test gates agree with the shipped surface.

After those conditions hold, expand composition through a concrete mixed-history
application and cross-compiler queue rollout. Before then, broadening syntax would
increase the compatibility state space while known lifecycle holes remain.

### Decisions still needed

- Choose the callback execution contract: static termination restrictions,
  operational bounds, or a deliberate combination. Purity alone is insufficient.
- Specify safe recovery for malformed historical data and the eventual audited
  data-loss surface; do not let a generic force option erase typed history.
- Define stable compiler/stored-value/catalog compatibility promises for deployed
  databases. Same-build examples are not that promise.
- Decide the next supported history composition from user requirements and test
  its full lifecycle, rather than enabling every combination independently.
- Establish measured fairness and history-size targets before choosing caching,
  pruning or broader scheduling policies.

The executive report prioritizes these decisions and the evidence required for a
release claim. The findings below describe the concrete defects and limitations
that currently prevent that claim.

### R05-03 — retirement incorrectly depends on draining unchanged work

Reproducer: two schema-owned job types, one changed (`Delivery`) and one unchanged
(`Unchanged`). Both applications compile through public source previews. Enqueue
an unchanged V1 job with a 2099 schedule. Install and publish V2, run its Worker,
then request Contract.

The conversion dispatcher selects staged changed-payload descriptors only.
Nothing restamps the unchanged job. Finality correctly sees its old schema stamp
and refuses. Because the handler must respect its future schedule, this can block
retirement for years even though its payload contract is identical in V2.

This is **fail-closed safety with broken liveness**, not silent data loss. The
source checker currently admits the inventory, so documentation alone is not a
complete remedy. Case 96 is explicitly marked expected failure, with setup/build
errors outside that expected-failure body. The test confirms the retained payload
and the specific old-payload refusal; it does not count a build error as the bug.

Required fix: a fenced, audited same-contract restamping path inside this
non-additive retirement protocol. It must cover pending/delayed/dead jobs, old and
surviving claims, lease expiry, races with enqueue/complete, and crash/replay.
Do not loosen `tesl_row_queue_final`, delete delayed jobs, or run their handlers
early. An interim compiler refusal must explicitly narrow the supported scope if
the runtime fix is deferred.

### R05-04 — totality is not furnished by purity, fixtures or PostgreSQL timeout

Case 85 replaces a successful pure callback body with a self-call. The source
checker accepts it. This is a characterization test, not a proof that executing
the function is safe. It deliberately does not run an infinite loop in the test
process. `convertBytes` calls the generated callback synchronously; panic recovery
does not bound an infinite loop and a Go stack-overflow fatal error is not a
normal recoverable panic. A canceled database context cannot interrupt arbitrary
CPU-only callback code holding transaction/advisory locks.

Possible directions require an explicit design decision: a terminating subset,
compiler-inserted cooperative fuel, or process-isolated execution with a deadline.
Whichever is chosen must preserve the rule that a timed-out result cannot publish
after a newer attempt. A finite fixture set cannot prove totality. Long strings in
case 61 test realistic size handling, not an instruction or memory bound.

### R05-05 — green selective gate did not mean green feature-wide testing

`dune runtest --root compiler` exposed eight failing cases across seven suites:

- `test_migration_closure`: relative completed-root query.
- `test_migration_qualified_family`: full qualified family rewrite/resolution.
- `test_queue_candidate_app`: old expectation that public queued App is gated.
- `test_migration_program`: two old production-queue refusal expectations.
- `test_migration_plan`: last-table Drop expectation conflicts with current scope.
- `test_config_only_type_positions`: migration constructor suppression inventory.
- `test_migration_nominal_pk`: concurrent golangci-lint process collision.

The first six suites (seven cases) also fail on the untouched review baseline.
The linter failure was specifically a parallel-run collision; do not label it a
semantic compiler regression. These results require maintenance and triage, not
waiving the entire migration area. The separate migration gate omits several of
these suites, which explains how its earlier pass coexisted with this debt.

During verification, the new embedding traversal initially assumed both example
directories existed. The compiler-upgrade fixture deliberately builds from a
reduced tree. That was a **review-introduced regression**, corrected by matching the
generator's existing optional-directory convention; the real compiler-upgrade test
then passed. Isolated installed-help tests still require the complete examples in
the ordinary shipped compiler.

An all-gate run also observed
`TestPgMigrationEmbeddedPlainIndexServesCRUDAndRestartsAfterScopeCancellation`
finding a DDL backend immediately after scope cancellation. Its isolated rerun
passed in 2.903 seconds. That establishes intermittency, not whether it is a real
backend leak or a too-early observation. The review did not weaken the assertion
or extend deadlines. A Todo V10 Contract process also hit its deadline in an
earlier run; the later complete kernel/application package passed.

### R05-06/R05-07 — documentation shipped a development diary

Lesson 96 simultaneously described public repair deployment and claimed that
publication, dispatch and retirement were pending. This is operationally harmful:
a reader could reasonably conclude the commands are unsafe to use or miss the
required repaired-binary deployment. Replaced the accumulated milestones with one
current workflow: exact types, business tests, install/publication, typed repair,
retirement, totality limits, and the known unchanged-job blocker.

The generator embedded top-level lessons but not the nested runnable examples
those lessons link to. Installed help thus lost the strongest executable reference
while the source checkout worked. A bounded whitelist traversal now embeds both
examples' README, source templates and runner code, retaining path/symlink/size
checks. Cases 97–103 copy the compiler outside the checkout, clear TESL discovery
variables, use an unrelated working directory, and fetch actual embedded content.
They test availability and specific claims, not just presence of strings in the
generated OCaml source.

Still missing: a concise operator-oriented migration manual covering status,
credential selection, rejection diagnosis, repair deployment, drain policy and
recovery. Contributor ledgers and roadmap design sections contain historical
claims; they must be visibly distinguished from the current normative surface.
Embedding reference source does not install Go/PostgreSQL or turn snippets into
standalone projects. The lesson now states that boundary explicitly.

### R05-08 — type safety without recovery visibility is hard to operate

`pgRowSchemaStatus` initializes `Instances` and `Indexes` to empty slices and fills
schema expansion progress. It has no queue quarantine counts, repair-head
progress, or bounded reason inventory. Contract's generic "old payloads, claims or
conversion attempts" message identifies a class of blocker, not the affected job
type or safe remediation. Request/Worker rightly lack direct historical payload
table grants; documentation must not compensate by recommending raw mutation.

Add a protected read-only aggregate inspection interface with stable codes and
bounded/paginated detail. Distinguish malformed historical bytes from a typed
rejection, live claims, recent instances and missing executable revisions.
Test that diagnostics cannot mutate state or leak arbitrary retained payloads.
Also reconcile `agent-context`'s "0 unproven obligations" with V001 proof errors;
clients must currently inspect diagnostics rather than trusting that count.

### R05-09 — operational scope is smaller than the design

- The extended format-5 catalog is fresh-install-first; old missing definitions
  refuse. This was a deliberate maintainer choice, not an implemented adoption
  protocol. Reusing a format number for evolving development layouts is acceptable
  only while the release promise explicitly excludes those earlier catalogs.
- Queue staging compares the new source's compiler ABI with the predecessor
  physical ABI. Rebuilding several releases with one compiler proves repeated
  schema upgrades, **not** arbitrary cross-compiler queue rollout. The existing
  compiler-upgrade witness is row/additive coverage. Add separately built compiler
  A/B queue deployments before promising that capability.
- Queue histories currently require consecutive queue-only changed edges with
  unchanged entities and exact membership. Additive prefixes/tails, mixed entity
  transformations and membership evolution are not automatically covered.
- Invalid historical codecs cannot be repaired by pretending malformed bytes are
  an old nominal record (case 47). This safe refusal leaves an operational dead
  end without explicit audited discard/adoption policy. `IgnoreOld` remains absent.
- Types prove value shape and explicit evidence flow, not the human business
  policy inside `establish` or the semantic correctness of a chosen replacement.

### R05-10 — robustness and scalability need quantified evidence

Per-job transactions and immutable receipts make replay credible. Nevertheless,
every Worker turn re-inspects installed catalog/history; every edge and repair
adds retained state. The test corpus does not establish latency or memory bounds
for hundreds of jobs/types/repairs, long rejected reasons, millions of retained
receipts, or slow compiler/type graphs. Sorting and sequential per-descriptor
budgets also merit starvation/fairness tests under a permanently busy first job.

Priorities: benchmark catalog inspection separately from payload conversion;
measure descriptor growth; test concurrent repair deployment against stale Worker
binaries; test 128-revision boundary behavior end to end; instrument actual
deadline/cancellation latency. Do not replace these with more spelling variants
of one metadata hash test.

## What the tests substantiate

| Dimension | Concrete evidence | Important non-claim |
|---|---|---|
| Correctness | Tamper refusal, immutable replay, exact original receipts, preserved schedules/counts, floor refusal | No exhaustive interleaving proof |
| Types/proofs | Wrong callbacks, missing fixtures, frozen edits, proof-bearing SQL, dependent-field assignments, Same/Revalidate attacks | No universal termination or business-policy proof |
| Robustness | Roles, claims/expiry, malformed bytes, long/Unicode/injection-shaped payloads, old status and restart | No load/chaos/multi-major certification from this review |
| Ergonomics | Public commands tested; unsupported force/target/database selections refuse | Status/recovery UI still incomplete |
| Lessons | Current lesson rewritten with commands, boundaries and explicit known issue | Not a complete beginner learning path for every migration form |
| Embedded docs | Detached compiler can fetch linked runners/templates and current lesson | Does not package external tools or execute examples automatically |

## Release recommendations

1. Keep the SQL type/proof fixes and their fast regression cases mandatory.
2. Resolve R05-03 or explicitly refuse its currently admitted source scope before
   recommending general queue-only retirement in production.
3. Define totality/execution-budget policy. Do not market purity as termination.
4. Reconcile the baseline compiler suites with the shipped surface; investigate
   the DDL cleanup flake with a synchronized lifecycle witness.
5. Ship read-only queue progress/blocker diagnostics before broad operator use.
6. Add cross-compiler queue and additive→transforming→additive application tests,
   then multi-job fairness and large-history performance tests.
7. Keep observed failures, expected failures and untested design requirements
   separate in release evidence. "107 cases" is an inventory, not a completion
   percentage for this domain.
