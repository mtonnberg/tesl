# PR 102: migration design, usability and performance review

> Audience: contributors and operators assessing migration scope, safety and developer tooling.

Reviewed range: `3e89b637980a814435ee385a3cbc6840a543a9f7` →
`846a7fbb9454ede1e993861624e9c3b5cb1e87f1` (989 changed files,
173,739 additions). The findings below describe that immutable PR head. The
implementation section records the improvements made after the review.

## Verdict

The central target is good: preserve the meaning of stored data, require typed
conversions and explicit business decisions, allow compatible old/new applications
to overlap, and retire old representations behind database-enforced checks.
Immutable source history, separate Installer/Worker/Request permissions, live
transaction admission and resumable work are worthwhile foundations.

The PR has substantial implementation and real integration evidence. It does not
complete the original roadmap, support every rolling transformation, or establish
production-scale performance. The developer experience at the reviewed head did
not adequately expose the existing capabilities or their limits. Green CI was
necessary evidence, but insufficient for those broader claims.

| Question | Assessment |
|---|---|
| Does it deliver its agreed target? | The register covers 18 agreed clauses, 13 required. Scoped consistency/readiness passes, with no required pending clauses. The reviewed head passed all 11 PR checks and all three workflows. |
| Is the original target complete? | No. Historical-roadmap reconciliation reports 645 unmapped blocks out of 650. Those are unreconciled source blocks, **not 645 demonstrated missing features**. Explicit postmerge deferrals remain. |
| Is the target appropriate? | Yes, when expressed as checked compatibility classes and explicit refusals. Automatically deciding defaults, loss policy or arbitrary semantic equivalence would be the wrong target. |
| Is it secure? | The reviewed paths have meaningful privilege, identity, fencing and source-write defenses. No exploitable bypass was confirmed in those paths. This was not an exhaustive review of every changed file; see coverage below. |
| Is it ergonomic for developers and AI? | Compact diagnostics and guarded JSON previews are useful, but migration-specific editor actions, reliable completion and a decision-oriented CLI were missing. This pass improves those surfaces. |
| Does it fully support rolling updates? | It supports tested adjacent/additive and ordered histories, with explicit compatibility restrictions. Universal zero-downtime conversion and rollback after retirement are not supported. |
| Is it fast enough? | Not established for the original production-scale target. A real concurrent-request bottleneck was measured and improved in this pass. Build feedback remains slow. |
| Is it tested enough? | Strong correctness breadth for the scoped protocol; incomplete evidence for all compositions, the real installed editor journey, production p99 and large-table rollout behavior. |

## Findings and decisions

### P2: migration authoring was largely invisible in the editor

The extension had test CodeLens but no migration commands or migration UI. The
compiler had contextual migration vocabulary, but completion could remain in
import mode after `migration =`, returning `Tesl.*` modules where migration fields
were expected. A green native portability workflow did not exercise this journey.

This pass adds migration commands and CodeLens, contextual completion/help, and a
read-only overview with individual decisions, expandable explanations, compiler
templates and source diffs. A matching extension and language server must be
installed; an already installed older VSIX does not update from repository edits.

### P2: the CLI exposed diagnostics instead of a decision workflow

The existing wizard prepared a revision, waited for edits, refreshed and printed
all diagnostics. A new required `String` field produced a long MIG003 `todo`
reason, but no concise presentation of the available value-source decision.

The CLI and LSP now share guidance. The wizard shows an overview and individual
review items, with numbered templates, expanded help, navigation and rechecking.
The compiler preview carries structured `decisions` metadata. Literal-default
templates are offered only when the actual additive classifier accepts the
checked inventory shape with correctly typed probe literals. Probe values never
become business defaults; displayed templates retain explicit custom-code holes.

Templates remain proposals. Selecting or copying one does not apply a source edit,
authorize database work or prove the completed migration. General conversion
function scaffolding and safe multi-buffer editor application remain unfinished.
The editor's existing apply coordinator stays disabled because standard LSP
apply acknowledgements do not establish the required snapshot barrier.

### P2: expected draft hash drift appeared as an unexplained error

The compiler already distinguished current-source drift (MIG001) from frozen
history integrity failures (MIG013), but both appeared as editor errors. Moreover,
MIG001 also covers missing or invalid-layout current inputs: lowering that code
globally would hide real failures.

Only verified current-source **byte mismatch** receives the new expected-draft
message and editor information severity. The compiler still rejects stale source
for build/run. Missing files, invalid layouts, malformed seals and frozen-history
changes remain errors. The tools cannot infer whether a revision was deployed:
refresh an undeployed revision; restore deployed source and start a forward
revision otherwise.

### P2: proof migration choices needed precise, discoverable guidance

`Same` compares complete canonical semantic closures, including reached helpers,
proof producers and codecs. It is neither matching physical types nor a user
waiver. Changing a threshold from 120 to 80 changes a stored proof's meaning even
if its field is still `String`; changed helper bodies are also detected.

| Change | Supported decision to investigate |
|---|---|
| Complete old/new meaning unchanged | Compiler-verified `Same`. |
| First field-local proof added | Supported revalidation preserving the original primitive value. Test rejected old rows. |
| Additional field-local conjunction | Revalidation only while preserving every historical proof through exact `Same` evidence. |
| Existing historical proof replaced | Supported typed `Migrate` with `Retype` and `WriteBack`; the reverse callback returns the exact old type and proof. Generic `Revalidate` is insufficient. |
| Cross-field historical reverse proof | Unsupported by the scalar reverse-callback path; do not suggest it as an automatic repair. |

Diagnostics, catalog/hover help and the new [migration guide](../manual/migration-guide.md)
now explain these distinctions. Stronger predicates can reject stored rows;
weaker predicates can admit values old versions cannot represent. A valid reverse
value need not be lossless. The developer must decide the policy and test overlap.
Typed functions establish their checked source/target types and attached facts;
they do not prove arbitrary business intent or a mathematical inverse. Fixtures
must assert the expected converted values or rejection, rather than treating
either outcome as sufficient evidence for the intended policy.

### P2: valid branch-local proof returns were rejected

The changed optional-establish return checker ignored each return leaf's lexical
type environment. Returning a proven record field directly worked, while the
equivalent branch-local `let local = note; Something local.title` was rejected
with V001. A `case` payload binding had the same problem. This is an actual
compiler correctness/usability regression in `proof_discharge.ml`, separate from
the missing migration help.

The fix checks field evidence using the exact leaf's types, matching the existing
scalar-return approach. Tests cover valid aliases and case payloads, an unproven
record with an equally named field, and a shadowed proven parameter. The latter
was already rejected by the language's independent no-shadowing rule before the
fix: this review did not establish a proof-forgery exploit.

### P2: broad rolling-update claims would exceed implemented compatibility

The safe rolling order is:

1. Start the new `worker --install` and wait for its supported readiness.
2. Roll the Request application processes while compatible versions overlap.
3. Drain retiring applications/claims, then run retirement/Contract.

Finite `schema deploy` completes final Contract. Using it as a pre-roll readiness
job can wait on old pods that the deployment controller has not yet replaced.
Contract closes a compatibility window; it is not a general reversible down
migration. Incompatible gap catch-up requires stopping incompatible processes and
waiting for the heartbeat grace period. Simultaneous row/payload changes must be
split into ordered revisions. Queue identity rename and arbitrary removal remain
refused; bounded empty-queue removal and unrelated table Drop beside exact
unchanged queue contracts have narrower supported paths.

The K8s example records 731 successful samples, both adjacent overlaps and no
failures. This is useful local evidence, not a mandatory live-cluster PR gate or
a database-HA/production-SLA test. Operator documentation and stale capability
tables have been corrected without broadening the implementation's guarantees.

### P2: valid schema names could be corrupted during SQL generation

`pgRowQueueConversionFunctions` applied global function/table-name substitutions
after inserting the quoted application namespace. Consequently valid namespaces
such as `tenant_tesl_queue_conversion_begin`, `...finish` and `...receipts` were
silently rewritten inside protected function bodies. Actual baseline installation
failed with PostgreSQL SQLSTATE 3F000 because those bodies referenced a different,
nonexistent schema. All three cases were reproduced on PostgreSQL 18.4.

The fix protects the complete quoted namespace during template replacement and
prefix extraction, then restores it. Existing SQL-literal quoting is unchanged.
Regression tests exercise real installation, execution, Request readiness and
conversion permissions for eleven namespace cases. Complete row-format-5 and
queue-format-4 function definitions for `mail` and `notes_app` remain byte-for-byte
identical. The new tests use the mandatory supported-major baseline selection.
This was not
established as a privilege-escalation exploit; the reproduced failure refused
installation rather than publishing an unchecked migration.

### P2: performance acceptance was narrower than its apparent name

The mandatory latency comparator uses an earlier **migration-enabled** commit
(`9852f26`), three rows, concurrency one and p50/p95. Its threshold permits a
50% relative regression or absolute floors of 0.5ms p50 / 2ms p95. Calibration and
alternating measurements make it a useful internal regression test. It does not
measure the total overhead of this PR against an application without migration
machinery, active backfill/index contention, p99, saturation or 10M/100M rows.

This pass profiles edit-loop queries and measures a concurrent-request bottleneck;
see [the performance report](migration-performance-review.md). The retained-query
cache works well for unchanged inputs, but representative one-shot checked-history
queries remain appreciable. Source-integrity validation must not be removed merely
to make these measurements smaller.

Further performance work should measure:

- Old/new read/write p99 during backfill and index preparation at realistic row,
  history and entity counts, including network and pooler conditions.
- Backfill throughput: the current scheduler owns one full-key-range shard per
  entity generation; multiple Workers do not multiply that entity's throughput.
- Contract lock duration: `ACCESS EXCLUSIVE NOWAIT` bounds acquisition attempts,
  but catalog checks, DDL and receipt verification still occur while holding the
  lock. Measure request-blocking time, not only lock acquisition.
- Independent CI shards with private clusters and retained per-phase evidence.
  Latency experiments must remain isolated from competing shards.

### P2: successful CI has almost no scheduling headroom

The reviewed authoritative job ran from 01:05:44 to 07:04:05 UTC on 2026-11-01:
**5h 58m 21s**, against a six-hour limit. PG14 and PG18 protocol lanes also took
hours. Increasing the allowance was useful to expose the complete result, but
does not improve successful feedback time. Preserve the assertions while reducing
duplicate compilation or sharding independent scenarios; do not describe the
current green run as proof of reliable timing headroom.

## Security and test evidence

Inspected runtime paths enforce Installer/Worker/Request separation, reject
privileged membership on runtime connections, verify catalog functions and ACLs,
pin database UUID/fence/origin, and check admission inside application
transactions. Conversion publication uses fresh transactions and conditional
updates; retirement checks dependencies and uses restrictive deletion. Source
publication binds exact bytes/document versions, rejects symlinks and path escapes,
and uses guarded journal/recovery operations. The new decision metadata never
replaces those guards or changes compiler compilability.

Important trust boundaries remain: migration callbacks are trusted application
code. Cooperative fuel/depth/time checks are not hard intrinsic preemption or a
memory sandbox. Closing the Installer connection and unsetting its DSN do not
erase credentials or isolate a compromised process. Request deployments must
receive only their own credentials.

Fresh review verification includes real PostgreSQL 18.4 race tests for catalog
ACLs/drift, inherited privileges, old/new writers, heartbeat shutdown and deployment
identity (13 root tests, no skips), plus nine queue/facility root tests covering
protected registration, exact repair inputs, email tokens, cache permissions and
SSE admission/function tampering (also no skips). Seven source-bound queue
publication attacks additionally passed on PostgreSQL 18.4, covering rollback,
stale attempts, foreign transactions, original-byte and binding substitution,
Worker-only publication and missing transaction attempts. The performance patch additionally has
deterministic original-code failure evidence, corrected PG17 tests and independent
PG18.4 race verification covering contention, UUID/admission refusal, ownership,
deadlines and future-generation waiting. Compiler, CLI, editor and source-preview
tests cover the new authoring behavior and retained refusal boundaries.
The optional-establish fix passed 229 focused proof/configuration tests, including
native identity and revalidation execution. Final authoring validation also passed
the complete CLI, LSP, shared-guide and guarded-source-edit packages, extension
tests, manual coherence, the 44 register negative tests, and changed-package Go
vet/lint checks. A graphical VSCodium session was not available; editor behavior
was exercised through command/provider/webview tests and real compiler/LSP calls.

Coverage is deliberately bounded: the initial runtime review read 21 production
files, followed by queue publication/repair/discard and cache/email/SSE permission
paths and selected SQL definitions/callers/tests; separate passes reviewed proof identity,
source integrity, guarded writes, CLI, LSP/extension and measurement infrastructure.
This does not account for every changed file or every emitted SQL function,
queue-repair/discard composition, facility callback, crash point or resource
exhaustion path. The security plugin's referenced preflight resources were
unavailable, so this report is a manual review, not a completed plugin scan or
security certification. The protocol coverage map is explicitly kernel-scoped;
finite models and mutation counterexamples do not establish all feature compositions.

## Remaining work after this pass

1. Complete safe compiler-backed scaffolding for broader conversion decisions and
   the editor snapshot/application protocol. Current templates are read-only and
   intentionally partial. Saved-source publication/guided authoring remains Linux
   only; portable manifest preview is not portable mutation.
2. Establish realistic active-rollout p99, throughput and lock-duration acceptance;
   execute the deferred large-table workload before making scale claims.
3. Reduce CI wall time with measured, correctness-preserving isolation/sharding.
4. Reconcile the original requirements and conduct remaining security/composition
   review before claiming whole-roadmap completion.

These limitations should stay visible alongside the implemented capability. The
right target is a predictable checked migration workflow whose supported paths,
required decisions and refusals are easy to see in both CLI and editor.
