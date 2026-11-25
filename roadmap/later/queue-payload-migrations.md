# Queue payload migrations (dependent on database-migrations)

Status: moved to `later/` 2026-11-25. The common cases ship; the rest has
workarounds and is not worth the cost now.

## What works today

| What you want to do | How |
|---|---|
| Add a job type or a queue | Just add it (additive change) |
| Change a job type's shape and convert old jobs | `jobs: { SendEmail: Migrate convertSendEmail }` |
| Fix jobs whose conversion failed | `QueueRepair` (retry with a new conversion) |
| Throw away old jobs instead of converting them | A `Migrate` whose function rejects every job, then `QueueRepair` with `on: "unconverted"` and a reason. Each deleted job is recorded in `tesl_row_queue_discards`. See [queue remediation](../../manual/queue-remediation.md). |
| Change database rows and job payloads together | Two migrations in order, rows first. The compiler explains the split. |
| Remove a whole queue | `RemoveEmpty`, once the queue has no jobs |

## What is not supported, and the workaround

| Not supported | Workaround | Cost of the workaround |
|---|---|---|
| Renaming a queue | Add a new queue; remove the old one with `RemoveEmpty` once it is empty | None |
| Renaming a job type, or moving it to another queue | Add a new job type (in the target queue) and enqueue that instead | The old job type cannot be removed while its queue exists, so it stays in the schema as dead code |
| Removing one job type from a queue that stays | None; keep the type | Same dead code |
| Removing a queue that still has jobs | Drain it first, then `RemoveEmpty` | Waiting for the queue to empty |
| A one-line "drop old jobs" decision (`IgnoreOld`) | The reject-then-discard route above | Two steps instead of one |
| Versioned queues with `topology: Embedded` | Use `topology: Worker` | A separate migration worker process |

## If this is picked up again

Start with **removing one job type from a queue** (at least when no jobs of that
type remain). It is the only gap that leaves permanent cruft, and it can reuse the
fenced, audited machinery of `RemoveEmpty`. `IgnoreOld` with a required reason was
designed on 2026-11-25 (accepted only for a changed type, reason of 1–256 UTF-8
bytes, part of the migration digest, old jobs deleted with one audit row each at
retirement). It needs its own decision form, because today's discard exists only
as a repair of an earlier conversion.

The original design text follows. It predates the shipped implementation; where
the two differ, `manual/queue-remediation.md`, LANGUAGE-SPEC ("Contextual queue
decisions") and [migration delivery status](../../dev-docs/migration-delivery-status.md)
describe what actually exists.

## What

Make queue job record types part of the versioned schema, so that a job enqueued by
the previous program version can be decoded — or deliberately dropped — by the next
one, with the same compile-time guarantees `database-migrations.md` gives entity rows.

## Why

`tesl_jobs` stores `payload jsonb` with a `job_type` naming the codec, and any
instance claims any row. During a rolling deploy a V8 worker can claim a V7-shaped
job and fail to decode it; today that job goes to the dead letter with
`next_attempt_at = infinity` and is never retried — silent loss of work, in both
directions. `database-migrations.md` §14 fixes the runtime half (a `schema_version`
column on job rows, a claim predicate over every **admitted** version
`schema_version in [min_version, mine]` — sound because a change to an existing job
type's shape is window-narrowing and closes an additive epoch, so inside one epoch every
shared job type has one frozen shape — typed and visible
dead-letter reasons, in-place migration of pending and dead jobs at retirement, a
`claim_seq` attempt token so a stale attempt cannot complete or re-schedule another
attempt's row, and the runtime-owned tables under the control-schema format
protocol). The `claim_seq` fix is a **prerequisite runtime bug fix** independent of
migrations: today `complete`/`fail` in `runtime/go/teslrt/pgstores.go` are keyed by job
id alone while `processing` rows are reclaimed after the visibility timeout. This item is the **language half**, split out so that the migration
feature's foundation phases stay small.

**Hard requirement carried over from `database-migrations.md`:** that feature may not
claim "all durable typed data is safe across a roll" until this item lands. The
honest statement, per stage: in a valid pre-language deployment an incompatible shape
change **cannot compile** (the prerequisite half below ships with cross-version
claiming); pre-feature legacy rows and corrupt payloads are visible, typed dead
letters; after the language half, an explicit `IgnoreOld` is an audited, counted
deletion.

## Two halves, in order

1. **Prerequisite (ships with the claim predicate, production-hardening phase):** job
   record types declared in the schema module, frozen, hashed and diffed across
   versions like entities, covered by `Same`; MIG028 as a compile **error** on a shape
   change to an existing job type. Cross-version claiming may not ship before this —
   without a frozen history the compiler has no authoritative previous shape.
2. **Migration surface (later):** `jobs:`, `Migrate`, `Rename`, `IgnoreOld`, fixtures,
    the transforming retirement pass that re-encodes payloads.

Current implementation (2026-10-13): fresh format-5 Worker histories support
unchanged-payload restamping and consecutive checked `jobs:` transformations,
business repair, execution-failure recovery and explicit audited discard. Latest-
binary catch-up also supports ordered row-first / payload-second revisions with
unchanged queue membership. Each row edge preserves payload contracts; each queue
edge preserves settled entities. Simultaneous row/payload changes, membership
rename/removal and the schema-level `IgnoreOld` constructor
remain open. See [delivery status](../../dev-docs/migration-delivery-status.md),
[lesson 95](../../example/learn/lesson95-retiring-unchanged-queue-payloads.md) and
[lesson 96](../../example/learn/lesson96-typed-queue-conversion.md).

## Design sketch (to be specified)

**Release sequencing decision (maintainer, 2026-10-12):** two ordered migrations
are acceptable when row and queue-payload changes cannot share an edge. The
compiler must explain which changes conflict, how to split/order them and what to
run next. The sequence must be supported by deployment/catch-up, including retained
jobs. The row-first / payload-second sequence now has a latest-binary PostgreSQL
witness in `scripts/test-ordered-row-queue.py`; row retirement atomically restamps
unchanged jobs, and the queue edge requires its settled row Contract. Simultaneous
unrestricted row/queue transformation is not required for
this release. See the [release requirements](../../dev-docs/migration-delivery-status.md#clarified-release-requirements-maintainer-2026-10-12).

- Job record types are declared in a schema-kind module (the schema module itself, or
  a `jobs module` revision), so they are frozen, hashed and diffed like entities and
  covered by the `Same` closure rule.
- The `Migration { … }` record gains a `jobs:` section: `jobs: { EmailJob: Migrate
  migrateEmailJob }` with `fn (Old.EmailJob) -> Migrated New.EmailJob`, or `EmailJob:
  IgnoreOld` — Lamdera's `MsgOldValueIgnored` — as an explicit decision to drop
  in-flight old jobs. An omitted job type must be verified unchanged.
- A changed job type with neither a migration nor `IgnoreOld` is a compile error
  (the MIG028 slot), never a dead letter.
- **Decoder identity.** A row's `(schema_version, job_type)` names a job type in a
  frozen schema module; the migration record's `jobs:` section maps old types to new
  ones (`Migrate f`, `Rename`, `IgnoreOld`, a removed type). No codec hash or separate
  type-revision column is needed: the schema version *is* the revision, and the
  compiler knows every type in it. The worker's supported-decoder set is every admitted
  version: inside an additive epoch all shared job types are provably identical
  (`Same`), and across an epoch boundary only the predecessor is admitted and is
  decoded through `jobs:`. A change to an existing job type's shape inside an epoch is
  refused as window-narrowing (close the epoch first), exactly like a unique index over
  an old-written column. `close-epoch` restamps every pending/dead job of the closed
  versions to the surviving version without decoding (`Same`), before the floor moves.
- **Interim rule between the two halves:** a shape change to an existing job type is a
  compile **error** (MIG028), so a worker never claims a row it cannot decode; a new
  job type is the only way to change a payload until `jobs:` exists. Processing rows
  are restamped in place at retirement (status, `claim_seq`, claimant and lease
  preserved), so "no job below `min_version`" holds at the floor's commit.
- **External effects** in job handlers carry an explicit `@effect "name" [key: expr]`
  annotation for a stable idempotency key `(job id, name, key)`; un-annotated sites are
  listed as at-least-once.
- **Identity covers the payload, not the handler** (decision in `database-migrations.md`
  §14): old jobs run the claiming worker's handler; a semantic change old jobs must not
  receive is spelled as a new job type or `IgnoreOld`.
- **Retirement migrates, it does not drain.** The final pass rewrites every `pending`
  (including delayed and retry-scheduled) and `dead` row of the retiring version
  through `jobs:` and stamps the new version; `IgnoreOld` deletes them. That is data
  loss by decision: `--schema dry-run` prints the count per job type, the plan header
  carries a decision-class entry, and the deletion is audited with the reason.
  `processing` rows follow one claimant rule: a row claimed by a *retiring* version's
  worker cannot renew under the fence and is restamped once its lease lapses (at most one
  lease period of waiting); a row claimed by a *surviving* version's worker is restamped
  in place immediately with `status`, `claim_seq`, claimant and lease preserved, and is
  never waited for. A `Reject` quarantines the job and blocks retirement like a row. No job can block retirement
  forever: there is no "older than the decoder window" state, because rows of a
  retired version do not exist.
- **Pub/sub outbox events** default to `IgnoreOld` **with the same count, entry and
  acknowledgement**; transient is not the same as free to lose silently.
- **Tests.** Generated: an old-shaped job enqueued and dequeued through the new worker
  for every migrated job type, using the developer's `fixtures:` (required for `Migrate
  f`, as for rows) or the property generators when the type has them; a stale-attempt
  case (claim, expire, reclaim, late complete must be a no-op); a delayed job and a
  dead job across the retirement pass; a mixed V7/V8 worker pair over one queue; a
  malformed payload landing as a typed dead letter; crash of the retirement pass
  mid-batch resuming idempotently; a delayed V1 job through a V1–V10 additive epoch,
  epoch closure and a transforming V11; a stale attempt's external effect after a newer
  attempt started (queue state untouched; the `(job id, effect name, key)` key in its canonical hashed wire form — stable across attempts, unlike `claim_seq` — deduplicates; canonicalisation cases: delimiter bytes in the key, an empty key, an oversized key); no non-quarantined job below `min_version` after retirement or `close-epoch`; a surviving-version claimant finishing an older payload leaves no old stamp; a crash between restamping and the floor advance resumes without advancing early.
- The existing `fromJson [current, legacy]` codec list is an alternative to a
  migration function when the payload change is a pure shape change.

## Open

### Recovery decision (maintainer direction, 2026-09-26)

Rejected transformations retain their original payload and source version in
quarantine and block retirement. Recovery uses a **typed repair migration**:
an additional checked repair revision retries conversion of that historical
payload into the target schema. It must not edit the already-deployed migration
or relabel the quarantined payload as a current value. Dropping those jobs
requires a separate explicit `IgnoreOld` migration decision, with the normal
count and audit record; an operator discard command is not part of this choice.

These bindings and typed business repairs now execute through the public Worker
path. The subsequent maintainer decision to support both preservation and explicit
loss is implemented through `QueueRepair`: `on: "execution-failed"` consumes exact
source-bound execution-failure evidence; `on: "unconverted"` with a reason discards
the named edge's remaining original jobs with immutable audit, including malformed
bytes. Active claims and retirement obligations remain enforced. See
[queue remediation](../../manual/queue-remediation.md) for the checked fixture and
policy rules. This supersedes the earlier requirement to use `IgnoreOld` for that
recovery decision; general schema membership changes still need their own surface.

- The prerequisite implementation already places job records in the ordinary
  versioned schema closure and lists them in `queueSchema`; no new module kind
  is needed for this implementation.
- Elaboration rules for `jobs:` in LANGUAGE-SPEC alongside `Migration` — done for
  `Migrate`; rename, removal and `IgnoreOld` remain (see Remaining work).
