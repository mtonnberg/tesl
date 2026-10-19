# Migration PR requirement register: agreed scope

> Audience: contributors reviewing migration requirements and their acceptance evidence.

This is an explicit PR contract, not a claim to have implemented all three original
roadmaps. Each `PR-*` clause below has exactly one entry in the
[requirement register](migration-pr-register.json). The roadmap reconciliation
report lists every nonblank source block not explicitly classified, including
examples and headings: it does not guess which English sentences are normative.
Reviewers must resolve those blocks before claiming roadmap completeness.

- PR-KERNEL: Preserve the existing kernel invariant/transition inventory, finite models, counterexamples, traceability checks and supported-major protocol gate.
- PR-QUEUE: Checked queue histories retain compiler-owned identities, payload contracts and application bindings.
- PR-CATCHUP: Latest-artifact catch-up executes ordered row-first/payload-second history, retained jobs, restart and intermediate Contracts without intermediate deployments.
- PR-DEPLOY: A finite production deploy installs then closes Installer connections, completes Worker catch-up/Contract, and gates service startup on successful exit.
- PR-COMBINED: The combined worker --install command installs then closes Installer connections before long-running Worker work and preserves supported rolling overlap.
- PR-K8S: Retain the Kubernetes rolling example evidence; distinguish its executable local scenario from a mandatory CI execution route.
- PR-UNIQUE: Implement the agreed three-release staged uniqueness per-key guard, with concurrent writes, old-writer fencing, PostgreSQL equality/null semantics and promotion/recovery witnesses. This is not the deferred reservation-table subsystem.
- PR-LATENCY: Require a pinned base-versus-candidate latency regression comparison in the full gate, with a failure threshold and retained measurements.
- PR-CACHE: Support cache facilities in Worker topology with migration and privilege-boundary witnesses.
- PR-EMAIL: Support email facilities in Worker topology with migration and privilege-boundary witnesses.
- PR-SSE: Support SSE facilities in Worker topology with migration and privilege-boundary witnesses.
- PR-EMPTY-QUEUE: Support removal of an empty queue with durable admission/catalog checks and negative nonempty witnesses.
- PR-DROP: Support safe Drop of an unrelated table when queues exist, preserving retained jobs and refusing actual dependencies.
- PR-SCALE: Defer the large 10M/100M sweep until after merge; small-scale tests are not this evidence.
- PR-RESERVATIONS: Defer the reservation-table subsystem described by the original staged-uniqueness roadmap; it is distinct from the required per-key guard.
- PR-RENAME: Queue identity rename is unsupported by design; reject rather than silently treating it as a safe identity-preserving migration.
- PR-SIMULTANEOUS: Simultaneous row and payload changes are unsupported by design; diagnose the supported ordered split.
- PR-CONVENIENCES: Editor apply, pruning and dedicated offline/operator conveniences are nonblockers for this PR.

## Checks and interpretation

From the repository root:

```sh
python3 scripts/check-migration-pr.py
python3 -m unittest discover -s scripts -p 'test_migration_pr.py'
python3 scripts/check-migration-pr.py --json
python3 scripts/check-migration-pr.py --release-ready
python3 scripts/check-migration-pr.py --roadmap-reconciled
```

Consistency is mandatory in the migration workflow and shared full gate. It checks
the scoped contract's inventory bijection, dispositions, production declarations,
named witnesses and runner selection **against live checkout files**, including
unstaged changes. There is no historical-reference override. It does not execute
witnesses or prove their assertions imply the requirements. `evidenced` means linked
existing evidence, not a passing result from this checkout or a whole-program formal
proof. Existing kernel IDs, inventory and finite model checks retain their original
scope and remain independently gated.

Scoped static readiness (`release_ready`) rejects every required pending entry.
Full-roadmap reconciliation is reported separately as `roadmap_reconciled`; it
does not require implementation of every historical paragraph, heading or example.
CI runs consistency rather than treating this register as release approval.
**A successful complete authoritative `./ci.sh` invocation, including the full
migration runner, remains required**, alongside the supported-major execution
requirements recorded in [delivery status](migration-delivery-status.md).
Static output always reports `full_ci_required: true` and `execution_verified: false`.
A failed runtime run, a passing prefix or an isolated retry cannot become completed
acceptance merely because declarations and runner links resolve. Before release,
finish pending production work and reviewed protocol witnesses, run the full gate
and review retained results. A green static readiness check alone is insufficient.

The checker uses Python AST declarations and bounded Go/OCaml declaration and
test-registration patterns. Runner checks resolve named runtime phases, Go selection
expressions, compiler suites (including literal loops), native fixture harnesses and
Python entrypoints back to the migration workflow. They are static reference checks,
not a general shell or YAML execution proof. Refactoring runner syntax may require
updating the validator and its negative tests together.

## Exhaustive source rule

The source universe is fixed in the validator: this contract, database-migrations,
queue-payload-migrations, staged-uniqueness-guard and migration-delivery-status.
Every maximal nonblank block in the four background sources is reported with file,
line, text and classification. A mapping must quote the entire block exactly once,
name registered requirements, give a disposition and rationale. Missing, changed,
duplicate or overlapping mappings fail consistency; new unclassified blocks are
reported as `unmapped` and prevent a full-roadmap reconciliation claim, independently
of scoped readiness. Code fences/tables/examples are included conservatively rather
than silently excluded. Classifying a block as contextual, superseded, deferred,
nonblocker or unsupported requires an explicit rationale; mapping a section heading
alone never covers its body. Reconciliation is intentionally incomplete, and makes
no completeness claim about original roadmap clauses. Changes to the source universe
or PR contract require scope review.

The Kubernetes scenario has explicitly accepted **manual local** evidence in
`.tesl-stuff/worker-install-kube.log`, recorded in delivery status: 731 successful
samples, zero failures, two Ready pods, both overlaps, 81 conversions and 121 correct
results. Retaining that acceptance does not add a mandatory live-cluster CI gate.
The validator checks the recorded acceptance and scenario link, not the log contents.

## Integrated scope and current boundaries

Exactly **18 reviewed clauses** are retained: 13 required, two postmerge deferrals,
two unsupported-by-design boundaries, and one nonblocker. The validator pins their
IDs/dispositions so deleting a Markdown clause and its JSON entry together cannot
turn the report green.

| Current increment | Register linkage and execution route | Evidence boundary |
|---|---|---|
| Facilities `61c0732` | `PR-CACHE`, `PR-EMAIL`, `PR-SSE`: named runtime/ACL tests and combined Installer test; `cache-runtime`, `email-runtime`, `sse-broadcast`, `combined-facilities` | Recorded 16 new PostgreSQL tests and existing regressions passing; not new execution by this checker |
| Budget `427d6b2` | Kernel package 2,400s, outer 2,460s | Individual scenario deadlines unchanged; complete rerun still needed |
| Drop `ec07129` | `PR-DROP`: compiler PostgreSQL suite invokes two native application/source witnesses with generated fixtures | Recorded 16 planning cases, PostgreSQL suite and six embedded seam tests. Standalone `row-retirement` selection would skip these fixtures |
| Latency `923f51f` | `PR-LATENCY`: comparator entrypoint and threshold/calibration tests; `latency-regression` and `latency-statistics` | Recorded standalone calibrated comparison pass; no absolute overhead or hosted reliability claim |
| Preparation `ce73748`, following groundwork `4f03e6f` | `PR-UNIQUE`: stage history, protected registration/observation; `test_staged_indexes` and `test_migration_row_indexes` compiler-loop routes | Connected bounded Stage/Carry builds NONUNIQUE indexes and retains pending records. Targeted native preparation and Memory results are not V9 guards, promotion or V10 reliance |
| Connected staged lifecycle and major verification | `PR-UNIQUE`: source/context/guard/protected Contract/index/recovery/cancellation/reliance links and real compiled fixture routes are required | Selected suites passed with race instrumentation on PostgreSQL 14.23, 17.10 and 18.4, with no skipped Go tests; full CI and universal histories are not claimed |
| Bounded empty-queue removal | `PR-EMPTY-QUEUE`: explicit source decision, Installer staging, fenced execution and protected SQL mutation; registered source and both native cases in `test_migration_queue_removal` | Merged source checks and real V1/V2 and V1→additive V2→RemoveEmpty V3→additive V4 PostgreSQL/race fixtures passed. One removal edge, additive prefixes/suffixes; not universal history support or full CI |

**PR-UNIQUE is now scoped evidenced** after the
[major verification](stage-major-verification.md) of the connected lifecycle on
PostgreSQL 14/17/18. The unconditional pending switch was replaced by concrete
required implementation and runtime-fixture links, with negative tests rejecting
helper-only evidence, missing paths, wrong handoff order and skipped native routes.
Scoped static readiness passes; `execution_verified` remains false and complete
CI is still required. Bounded empty-queue
removal is technically accepted and evidenced by its actual implementation and
executed native fixtures; no separate human approval flag is required. Its validator
checks require source/staging/execution/protected-mutation links, the real compiled
fixture harness and mandatory native selection. Borrowing another feature's tests,
substituting an isolated emptiness helper or flipping a status string cannot pass.
The latest complete CI invocation recorded in delivery status failed; these targeted
results do not supersede that result or establish full-roadmap reconciliation.
