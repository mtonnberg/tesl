# Database migration review 05 — test and execution evidence

Companion assessment: [db-migration-review-05.md](db-migration-review-05.md).
Executive assessment: [db-migration-review-05-exec.md](db-migration-review-05-exec.md).
Date: 2026-10-06. Baseline commit: `3081667` (`wip`, created before review).

## Follow-up result after implementing R05-01–R05-08

The original discovery record below is retained. It is superseded for current
status by this follow-up: **119 cases pass, with zero errors, failures, skips or
expected failures**. Four Go runtime budget cases are additional. Current results
and hash provenance are in `.tesl-stuff/review05-r01-r08-final-record/`.

| Evidence | Result | Log |
|---|---|---|
| Complete compiler suite after fixes | Passed | `.tesl-stuff/review05-allfix-compiler.log` |
| Main application/kernel gate and preceding mandatory phases | Passed before user interruption during query suite | `.tesl-stuff/review05-r01-r08-gate.log` |
| Query suite resumed | All 11 cases passed, 418.089 seconds | `.tesl-stuff/review05-row-access-retry.log` |
| All remaining compiler/runtime phases and both V1–V4 examples | Passed on fresh private cluster | `.tesl-stuff/review05-r01-r08-tail-final.log` |
| Final adversarial suite and embedded-runtime seam | 119 cases passed; seam passed | `.tesl-stuff/review05-r01-r08-final-record.log` |
| Public V1–V13 and Worker lesson after row-status fix | Passed, 668.325 seconds combined | `.tesl-stuff/review05-final-public-history.log` |
| Cleanup identity regression | Passed | `.tesl-stuff/review05-cleanup-fixed.log` |

This covers every mandatory migration-gate phase across a verified prefix and a
resumed tail. It is not claimed as one uninterrupted invocation. The first tail
attempt encountered a startup-busy failure in the query suite; its isolated retry
passed before proceeding. Neither timeouts nor safety assertions were weakened.
Build parallelism was reduced because the shared host had severe memory pressure.
The aborted invocation was visibly progressing; `PGCONNECT_TIMEOUT` was an
environment setting, not a stalled connection command.

### New follow-up cases (108–119)

| ID | Additional regression | Oracle |
|---|---|---|
| 108 | Dead unchanged work | Retain attempts, status and schedule while restamping |
| 109 | Live retiring claim | Refuse with no job/audit/floor progress |
| 110 | Expired retiring claim | Release claim and record exact sequence audit |
| 111 | Surviving claim | Preserve token and completion right across retirement; audit survives deletion |
| 112 | Changed payload blocker beside unchanged work | No partial restamping |
| 113 | Protected retirement transaction rolled back | Jobs, audit and floors restored; subsequent Contract succeeds |
| 114 | Tail-recursive generated converter | Public Worker stops with no payload/attempt/receipt publication |
| 115 | Mutually recursive generated converter | Stops at depth bound instead of stack overflow; no publication |
| 116 | Public rejection/invalid-byte status and installed repair | Correct distinct codes, revision, privacy and read-only behavior |
| 117 | Recent versus stale instance status | Report current retiring instance and exclude stale one |
| 118 | Old live-claim status | Report lease blocker through restricted public command |
| 119 | Detached installed operator guide | Retrieve role guide, blocker actions and execution policy |

Case 96 now passes and has no expected-failure marker. The budget unit tests cover
fuel exhaustion and cleanup, non-renewable nested budgets, canceled context/depth,
and goroutine isolation. Budget fixtures allocate fresh output directories so
rerunning the same release inventory is supported. The privacy test checks the
`original` JSON key and a secret sentinel, not an innocuous use of the word
"original" in a remediation sentence.

### Remediation implementation

- **R05-01/R05-02:** shared SQL destination proofs/types, including dependent
  subjects and collection element types; no migration-only exemption.
- **R05-03:** locked preflight of every old job before mutation; exact-contract
  restamps, preserved schedules/counts/surviving claims; private immutable audit
  tied to canonical retirement. Rollback covers audit and floor publication.
- **R05-04:** generated entry/loop metering, 100,000 steps, depth 128 and two-second
  cooperative deadline, shared nested budgets and operation cancellation. No
  detached work or usable late result; no claim of hard intrinsic preemption,
  memory sandboxing or static totality.
- **R05-05:** canonical relative overlay paths; expectations updated to current
  Worker/Embedded and Drop scope; serial lint coordination; cleanup sessions get
  a non-executor tag while all original executors are joined.
- **R05-06/R05-07:** current lesson, unified `manual/migration-operations.md`, bounded
  example embedding, isolated installed-help checks.
- **R05-08:** protected aggregate status with stable actions/codes, repair revisions,
  explicit 100-type completeness flag, recent instances and verified row-index
  projection. The row-specific verifier remains authoritative; the legacy lease
  verifier is not applied to row-shard leases.

## R05-10 fairness follow-up (2026-10-07)

Current inventory: **123 named cases with passing evidence**, zero expected failures.
The 122-case suite passed together; case 123 was subsequently added and passed
separately. This is not a claim of a new uninterrupted default migration-gate run.

| Case / check | Oracle / result | Evidence |
|---|---|---|
| 120, before fix | Later type fails its 25-second progress deadline while the first type is replenished | `.tesl-stuff/review05-fairness-before.log` |
| 120, fixed | Later type progresses with continuous first-type load | `.tesl-stuff/review05-fairness-fixed.log` |
| 121 | Restart preserves durable service order; rare type progresses with old backlog remaining | `.tesl-stuff/review05-fairness-regressions.log` |
| 122 | 1,024 actual conversion receipts; last-service lookup uses fairness index without sequential scan; repeated selector calls are read-only | `.tesl-stuff/review05-history-index/` and `.tesl-stuff/review05-history-index.log` |
| All 122 cases | Passed in 322.158 seconds | `.tesl-stuff/review05-fairness-regressions.log` |
| Generated/application conversion and repair PostgreSQL group | Passed in 128.346 seconds | `.tesl-stuff/review05-fairness-regressions.log` |
| 123 | Drop required fairness index; public status refuses without state changes | `.tesl-stuff/review05-fairness-index-refusal/{result,inventory,provenance}.json` |
| Focused runtime/catalog race checks | `Test(RowQueue\|PgRowBaseline\|QueueConversion)` passed in 93.246 seconds, private PostgreSQL, migration test tag | Terminal verification, 2026-10-07 |
| Compiler build and runtime embedding | Build passed; six byte-identity/dependency tests and three runtime-gate tests passed | Terminal verification, 2026-10-07 |
| Updated installed guide and lesson | Four detached-binary checks passed after regenerating embedded docs | `.tesl-stuff/review05-fairness-installed-docs/{result,inventory,provenance}.json` |
| Formatting and diff | Go formatting clean; `git diff --check` passed | Terminal verification, 2026-10-07 |

The bulk-history case initially used the 25-second single-job progress deadline and
timed out. It now has its own 120-second workload budget; single-job fairness
deadlines remain 25 seconds. The recorded 1,024-transaction workload took 41.086
seconds. These measurements establish a regression workload and indexed selection,
not a production throughput promise or bounded total catalog-verification cost.

Dispatch uses durable last-receipt ordering and a share of the remaining turn
budget per descriptor. A protected stable selector and independently checked
`tesl_row_queue_conversion_fair (source_digest, attempt_seq)` index implement the
ordering without granting Worker direct historical-table access. Missing required
objects refuse; no old-catalog adoption is implied. Million-job/history scale,
more-than-budget descriptor counts, formal fairness latency and memory bounds
remain follow-up work.

## Original result summary and execution history

### Later R05-09 verification

Review fixes were committed as `a125d9c`. The next actual compiler A/B/C queue
regression first failed at V2 installation with `queue target has no exact
compiler-linked conversion` (`.tesl-stuff/queue-compiler-upgrade-first.log`). The
staging ABI was tied to the wrong edge. After correction, the full public rollout
passed in 254.976 seconds; the extended active-edge pinning/post-retirement new-edge
probe passed in 283.350 seconds (`.tesl-stuff/queue-compiler-upgrade-pinning.log`).
The final run, including exact frozen-byte assertions and the protocol traceability
gate, passed in 257.002 seconds (`.tesl-stuff/queue-compiler-upgrade-final.log`).
The same-compiler generated PostgreSQL conversion/repair suite also passed after
the fix (`.tesl-stuff/queue-compiler-upgrade-same-compiler.log`, 117.820 seconds).

The test independently reads emitted queue-history headers and requires A/B source
ABIs to differ, A/B stored-value contracts to agree and C's to differ. A freezes V1
before switching compilers; frozen bytes are checked after each later release.
The runner also rejects C at the installed database without state/payload changes.
The source tree used for compiler variants is isolated; emitted metadata is never
patched. The protocol inventory classifies this as compiled-PostgreSQL evidence
and its deterministic coverage map was regenerated and checked.

- **107 new individually named test cases** in
  `scripts/test-db-migration-review-05.py`.
- **106 pass; 1 explicit expected failure** (R05-03, unchanged delayed-job
  retirement). No skipped cases and no unexpected failures in the final focused run.
- Compiler type/proof defects discovered and fixed, including a second
  dependent-field variant found during fix review.
- Lesson 96 rewritten; nested runnable migration references embedded and checked
  using a copied compiler outside the checkout.
- Both ordinary V1–V4 example lifecycles pass using freshly rebuilt binaries.
- **Whole compiler suite is not green. Full default migration gate did not finish
  green during this review.** Details below; the earlier pre-review full pass is
  not relabeled as verification of these edits.

## Reproduce

Run from the repository root with a new artifacts directory:

```sh
nix develop --command dune build --root compiler bin/main.exe
GOTMPDIR="$PWD/.tesl-stuff" nix develop --command python3 \
  scripts/test-db-migration-review-05.py \
  --artifacts .tesl-stuff/review05-releases \
  --output .tesl-stuff/review05-results --build
```

The runner builds the two examples, then starts its own private PostgreSQL cluster.
It requires `initdb`, `pg_ctl`, `psql`, Go and Python. There is no external database
fallback and no silent PostgreSQL skip. `--build` builds seven queue binaries and
four row binaries, running the examples' generated race-test suites. A further
two-payload fixture is built through ordinary guarded source previews for case 96.

Repeat using those exact binaries by omitting `--build`. `--match test_82` selects
one named case. An empty selection is an error. The complete inventory must retain
at least 50 cases. The runner retains `inventory.json`, `result.json`, compiler and
binary SHA-256 provenance, and Worker logs under `--output`. Temp databases and the
private cluster are cleaned up.

The default `scripts/run-migration-tests.sh` now invokes this runner after the two
examples, reusing their just-built release directories rather than building them
again. Known failures are emitted by unittest as expected failures and retained
separately in the JSON report. An unexpected success forces removal/reclassification
of the known-failure marker; build/setup faults are not swallowed by that marker.

## Test isolation and oracle

- A fresh private cluster owns installer/owner/Worker/Request roles.
- Idle V1, expanded V2, and retired V2 templates are prepared through real public
  install/Worker/Contract commands. Every database case gets its own cloned database.
- Cloning is test isolation, not a production adoption mechanism. No application
  handles are transferred between clones. Production commands establish their own
  connections and inspect the installed catalog.
- Corruption tests use the privileged observer to inject a fault that PostgreSQL
  actually accepts, then ask the restricted public status command to refuse it.
  They compare admission state before and after refusal.
- Role/command tests use the wrong principal or invalid command intentionally and
  require refusal without state change or a panic.
- Payload tests enqueue as Request, execute real generated conversion code as
  Worker, compare target JSON and replay the immutable receipt.
- Source tests copy frozen source releases; mutate a single selected boundary;
  run the real `agent-context`; inspect diagnostics. SQL grammar failures do not
  count as proof/type rejection. Positive controls prevent an always-reject fix.
- Installed-doc tests copy the compiler to an unrelated `/tmp` directory, clear
  `TESL_*` discovery variables and query help from that directory. They cannot
  succeed by reading the checkout's source lesson.

## Numbered inventory

Each row is a separately named unittest case. Names beginning `test_N` are stable
execution identifiers. Repeated Worker turns and multiple assertions inside a case
are not counted as additional tests.

### Installed authority and catalog attacks — 01–28

| ID | Attack | Required oracle |
|---|---|---|
| 01 | Replace installation UUID | Status refuses; floors unchanged |
| 02 | Change advisory fence namespace | Same |
| 03 | Claim unsupported catalog format | Same |
| 04 | Raise both floors without retirement | Same |
| 05 | Remove completed expansion receipt | Same |
| 06 | Substitute expansion artifact hash | Same |
| 07 | Substitute expansion compiler ABI | Same |
| 08 | Bind staged target to another UUID | Same |
| 09 | Bind root staging to another fence | Same |
| 10 | Change staged predecessor identity | Same |
| 11 | Remove immutable conversion root | Same |
| 12 | Change payload contract and recompute its digest | Same; a matching hash is insufficient authority |
| 13 | Lie about queue payload count | Same |
| 14 | Change full source schema snapshot | Same |
| 15 | Change full source storage snapshot | Same |
| 16 | Change queue source expansion binding | Same |
| 17 | Relabel narrowing physical plan as epoch-preserving | Same |
| 18 | Remove staged target descriptor | Same |
| 19 | Grant Request direct raw job reads | Exact ACL inspection refuses |
| 20 | Grant Worker direct historical receipt reads | Exact ACL inspection refuses |
| 21 | Grant PUBLIC retirement-function execution | Exact function privileges refuse |
| 22 | Remove job schema-version CHECK | Exact constraint inventory refuses |
| 23 | Make jobs UNLOGGED | Durability/catalog inspection refuses |
| 24 | Change identity-sequence increment | Sequence contract refuses |
| 25 | Append retirement bytes and recompute digest | Exact canonical retirement refuses |
| 26 | Delete retirement receipt after raising floor | History refuses |
| 27 | Delete installed repair revision after retirement | Complete lineage refuses |
| 28 | Change contracted lifecycle artifact | Receipt/lifecycle binding refuses |

### Principals and command boundaries — 29–40

| ID | Attempt | Required oracle |
|---|---|---|
| 29 | Request invokes installer | Refuse, no admission change |
| 30 | Worker invokes installer | Refuse, no installer authority |
| 31 | Request starts schema Worker | Refuse |
| 32 | Installer impersonates Worker | Refuse despite broader SQL privileges |
| 33 | Request executes Contract | Refuse |
| 34 | Installer executes Worker-only Contract | Refuse |
| 35 | Force additive epoch closure across changed payload | Refuse; force does not bypass shape policy |
| 36 | Contract V0 | Refuse invalid version |
| 37 | Contract V3 with V2 binary | Refuse unbound target |
| 38 | Force queue Contract | Refuse unsupported option |
| 39 | Select unrelated database declaration | Refuse |
| 40 | Swap compiled Worker/Request roles at installation | Refuse |

### Real job lifecycle attacks — 41–54

| ID | Scenario | Required oracle |
|---|---|---|
| 41 | Future binary contracts before target publication | Cannot replay prior edge as success |
| 42 | Stage successor before predecessor retirement | Refuse; zero successor staging rows |
| 43 | Job delayed until 2099, attempts=5 | Convert without handling; preserve schedule/count/status |
| 44 | Dead job, attempts=7, infinite retry time | Convert, retain dead disposition/reason/schedule |
| 45 | Live old claim | No rewrite; Contract remains blocked |
| 46 | Expired old claim | Recover and convert; clear stale claim fields |
| 47 | Historical codec receives wrong JSON value type | Quarantine as payload-invalid; typed repair cannot sanitize it |
| 48 | Typed rejection followed by repair | Original rejection receipt byte-for-byte retained; new success receipt |
| 49 | Enqueue with retired source stamp | Refuse; no inserted job |
| 50 | Original V1 status reads retired V2 | Correct current/min version observation |
| 51 | Reinstall same repaired retired binary | Exact staging replay, no rewritten lineage |
| 52 | Recent V1 instance with empty queue | Contract refuses without moving floors |
| 53 | Reuse converted job ID after deletion | Refuse; historical receipt remains |
| 54 | Complete converted job with expired old claim token | False/no-op; current job remains |

### Awkward payload preservation — 55–64

Each case checks exact decoded target value, chosen priority and immutable replay.
These are semantic payload classes, not superficial identifier permutations.

| ID | Payload class |
|---|---|
| 55 | Combining Unicode; no accidental normalization |
| 56 | Non-BMP Unicode characters |
| 57 | Right-to-left text and explicit bidi control |
| 58 | Quotes, backslashes, newline and tab |
| 59 | SQL-injection-shaped text remains data |
| 60 | Whitespace is not mistaken for empty string |
| 61 | 64 KiB string crosses normal small-fixture assumptions |
| 62 | Canonical-frame-looking delimiters/control separator |
| 63 | Huge integer-looking text remains a string |
| 64 | JSON-looking text remains a string, including prototype-looking keys |

### Source, migration, type and proof boundaries — 65–95

| ID | Attack/control | Oracle |
|---|---|---|
| 65 | Empty old fixture set | MIG003 |
| 66 | Duplicate job decision | Migration diagnostic |
| 67 | Omit changed job | MIG028 |
| 68 | Name absent job | Migration diagnostic |
| 69 | Repair revision zero | MIG028 |
| 70 | Skip repair revisions | MIG028 |
| 71 | Repair another job | MIG028 |
| 72 | Reuse root callback for repair | MIG028 |
| 73 | Invent discard field in repair | MIG020 |
| 74 | Repair without fixtures | MIG003 |
| 75 | Unqualified repair predecessor | MIG020 |
| 76 | Rename contextual repair declaration | MIG020 |
| 77 | Converter returns wrong field type | Type diagnostic |
| 78 | Ill-typed unused private helper | Whole-body checking refuses |
| 79 | Duplicate repair revision field | MIG023 |
| 80 | Arbitrary predecessor member | MIG020 |
| 81 | Edit frozen old codec, then check full app | MIG013 |
| 82 | Raw string SQL update into proven current field | Proof diagnostic; **failed before fix** |
| 83 | Revalidate a substitute instead of original title | Migration refusal |
| 84 | Change copied metadata codec under Same | Migration refusal |
| 85 | Pure recursive converter | Accepted characterization: type checking does not prove termination |
| 86 | String assigned to Int SQL column | Type refusal |
| 87 | Direct raw proven-field update | Proof refusal |
| 88 | Bool assigned to Int SQL column | Type refusal |
| 89 | Direct insert fabricates field proof | Proof refusal |
| 90 | Upsert fabricates field proof | Proof refusal; **failed before fix** |
| 91 | SQL update with exact validated success binder | Accept |
| 92 | Validate one value, assign another | Refuse; **failed before fix** |
| 93 | SQL insert with exact validated success binder | Accept |
| 94 | String computation after validation | Refuse lost proof; **failed before fix** |
| 95 | insertMany List Int into entity | Type refusal; **failed before fix** |

### Confirmed gap and installed docs — 96–103

| ID | Scenario | Outcome |
|---|---|---|
| 96 | Unchanged delayed payload beside changed job | **Expected failure**: Contract still blocks; R05-03 |
| 97 | Detached help retrieves current lesson/scope | Pass; no stale pending-dispatch claims |
| 98 | Detached lesson distinguishes purity from totality | Pass |
| 99 | Detached lesson names unchanged-job blocker | Pass |
| 100 | Linked queue example README | Embedded and available |
| 101 | Linked row example README | Embedded with Legacy/Revalidate coverage |
| 102 | Linked queue runner | Embedded source available |
| 103 | Linked proof-revalidation template | Embedded source available |

### Dependent-field proof attacks — 104–107

| ID | Scenario | Oracle |
|---|---|---|
| 104 | Change lower bound without re-establishing upper's proof | Refuse; **failed before second fix** |
| 105 | Assign both dependent fields with exact joint evidence | Accept |
| 106 | Proof made for different assigned lower bound | Refuse |
| 107 | Assume stored sibling equals local proof subject | Refuse |

## Observed execution history

All paths below are local evidence, intentionally not committed build output.

| Run | Result | Log |
|---|---|---|
| Initial 85 cases | 84 pass; case 82 exposes SQL proof bypass | `.tesl-stuff/review05-first.log` |
| Corrected SQL fixture grammar, before fix | Cases 90/92/94/95 fail; positive controls pass | `.tesl-stuff/review05-sql-before2.log` |
| First proof/type fix | Case 82 refuses; its old diagnostic-prefix assertion needed V001 | `.tesl-stuff/review05-checker-fixed.log` |
| Two-payload lifecycle | Confirmed unchanged delayed-job blocker | `.tesl-stuff/review05-mixed.log` |
| 103-case run | 102 pass, one expected failure | `.tesl-stuff/review05-complete.log` |
| Dependent-field probe | Case 104 fails before fix | `.tesl-stuff/review05-sibling.log` |
| 107-case run | 106 pass, one expected failure, 99.847 seconds | `.tesl-stuff/review05-final-checks.log` |
| Freshly rebuilt release run | 106 pass, one expected failure, 116.135 seconds | `.tesl-stuff/review05-rebuilt.log` |
| Freshly rebuilt full examples | Both row and queue V1–V4 lifecycles pass | `.tesl-stuff/review05-examples-final.log` |
| Final recorded run with hash provenance | 106 pass, one expected failure, 99.123 seconds | `.tesl-stuff/review05-final-record.log` |

The initial one-line `if` in a newly written SQL probe was a **test-authoring
error**, not a compiler discovery. It was corrected; probes explicitly reject
E000 parse errors as an oracle. Similarly, case 82's post-fix diagnostic was V001,
not P/T-prefixed; the expected code/message was corrected without loosening the
requirement that the compiler reject the unproved write.

### Broad regression results and limits

`dune runtest --root compiler` was run with disk-backed scratch storage. It produced
eight failed cases across seven suites. Six suites/seven cases were reproduced
on an untouched detached baseline worktree at `3081667`; they are not attributed
to the new SQL checks. The seventh suite's failure was concurrent golangci-lint.
Logs: `.tesl-stuff/review05-compiler.log`, `review05-baseline-tests.log`, and
`review05-baseline-rest.log`. Two initially mistyped baseline executable names
were corrected in the latter run; missing executables were not counted as
reproduced test failures.

The first complete migration-gate attempt during review found the introduced
missing-example-directory assumption in the docs generator and a Todo V10 Contract
deadline. The generator was corrected. The actual compiler-upgrade test then
passed (197.324 seconds) in `.tesl-stuff/review05-upgrade-retest.log`.

The next full migration-gate attempt passed the kernel/application package
(1166.807 seconds) and first runtime group (191.325 seconds), then failed the
embedded plain-index cancellation backend assertion. Its isolated run passed in
2.903 seconds. Logs: `.tesl-stuff/review05-migration-gate-final.log` and
`.tesl-stuff/review05-index-retest.log`. The cause of that intermittent observation
was not established. No deadline was enlarged, assertion removed or result
reclassified as a complete pass. Consequently later gate sections were not all
executed by that attempt; the focused adversarial suite and examples have their
own successful runs above.

Compiler `@check`, documentation regeneration, `git diff --check`, and shell syntax
checking were also used. These validate build/synchronization, not semantic
completeness. The root all-language/compiler gate remains separate from the
database migration runner.

After the dependent-field fix, focused existing suites also pass: Types (88),
Proofs (32), Validation (99), return-field lexical scope (10), and SQL registry.
Their output precedes the final 107-case run in
`.tesl-stuff/review05-final-record.log`. The existing cases are not included in the
107 new-case count. Final `inventory.json`, `result.json`, and `provenance.json`
are under `.tesl-stuff/review05-final-record/`.

## Remaining work, in executable terms

1. Make case 96 pass for the correct reason: actual same-contract restamping under
   real retirement fences, then add old/surviving live-claim and crash cases.
2. Add a bounded callback-execution mechanism and a safely isolated nontermination
   runtime test; case 85 currently proves only the absence of a static restriction.
3. Repair/triage the baseline compiler failures and synchronize DDL cancellation
   observation; rerun the full gates without hiding known failures.
4. Add public aggregate queue progress/rejection diagnostics with privilege tests.
5. Add cross-compiler queue deployments and multi-job fairness/scale workloads.

The requested review files are source artifacts. Logs, generated releases,
database copies and the baseline worktree are verification artifacts, not changes
to be committed as part of this review.
