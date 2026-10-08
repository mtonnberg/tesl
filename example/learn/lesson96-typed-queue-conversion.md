# Lesson 96 — Convert, repair and retire queued payloads

Consecutive **queue-only** upgrades can deploy through ordinary compiled Tesl
applications, `--schema install`, `--schema worker` and `--schema contract Vn`.
Each upgrade retains exact queue/job membership and unchanged stored entities.
The initial upgrade needs an expanded V1 database; later upgrades need their exact
fully retired adjacent predecessor. Mixed row/queue changes, job renames/removals,
`IgnoreOld`, and adoption of older control catalogs remain unsupported.

For a complete executable example, use
[queue-three-upgrades](../queue-three-upgrades/README.md). It builds original V1
and separate normal/repaired V2, V3 and V4 binaries and runs them on one private
PostgreSQL database. For unchanged-payload additive retirement, use
[lesson 95](lesson95-retiring-unchanged-queue-payloads.md).

## 1. Describe the old value's new meaning

The old record is `Delivery { text: String }`; its codec stores `oldText`.
The new record is `Delivery { body: String, priority: Int }`; its codec stores
`message` and `priority`. Use a pure migration helper with exact nominal types:

```tesl
fn convert(old: Schema.Mail.V1.Delivery) -> Migrated Schema.Mail.VCurrent.Delivery =
  if old.text == "" then
    Reject "empty job"
  else
    Row (Schema.Mail.VCurrent.Delivery { body: old.text, priority: 7 })

fn oldJob() -> Schema.Mail.V1.Delivery =
  Schema.Mail.V1.Delivery { text: "retained" }
```

Put these decisions in the ordinary `Migration` record, importing the helper and
both schema roots directly:

```tesl
fixtures: [Schema.Mail.Migrate.Helpers.oldJob]
jobs: { Delivery: Migrate Schema.Mail.Migrate.Helpers.convert }
```

Every changed retained payload requires a decision; unchanged payloads must not
invent one. The compiler checks callback purity, old/new nominal ownership,
complete codecs, fixtures, proof obligations, and the entire helper dependency
graph. A newly proven target field must obtain its proof through the target
schema's ordinary `establish` function.

The compiler's certificate binds the callback, fixture and codec closures, both
complete schema/storage snapshots and compiler identity. It is source evidence;
installed database identity, expansion receipts and fenced operations separately
grant runtime authority.

## 2. Test the business rule as well as the types

```tesl
test "old text and chosen priority survive" {
  case convert (oldJob()) of
    Row job ->
      expect job.body == "retained"
      expect job.priority == 7
    Reject reason -> expect False
}
```

Run `tesl agent-context migrations/mail/v2.tesl` after edits and
`tesl test migrations/mail/v2.tesl` to execute the generated fixtures. Fixtures
return the exact old record, directly or in the builtin `Maybe`; `Nothing` fails
by fixture name. A deliberate `Reject` is a valid smoke-test outcome. Therefore
fixtures alone do **not** prove conversion success or preservation of business
meaning. Include explicit success, rejection and round-trip assertions.

Purity is **not totality**. Recursive functions can type check; generated migration
code now has an operational execution budget: 100,000 function-entry/loop steps,
128 nested calls and a two-second cooperative deadline. Nested helpers share the
budget rather than renewing it. Queue attempts and row backfill also honor supplied
cancellation contexts. Exhaustion returns an error without a usable conversion or
late publication. This is not a static termination proof, memory sandbox or hard
preemption of an individual intrinsic call. Keep conversions bounded and test
large/adversarial values.

## 3. Deploy the checked edge

First install and expand V1. Build V2 from its checked history. With the same
compiled database/role configuration, run:

```sh
# Short-lived installer connection:
./v2/app --schema install --worker WORKER_ROLE --request REQUEST_ROLE --json
# Worker connection:
./v2/app --schema worker --json
```

Installation stages the immutable conversion and target; staging alone does not
admit V2. Worker publication drains the compatibility domain and records the exact
expanded target before new requests start. The Worker then discovers eligible jobs
in bounded turns (up to 256 job transactions), resolving staged digests to linked
typed adapters. Each job commits independently; committed receipts support restart.

When several job types change, a turn shares its remaining budget among conversion
descriptors and visits sources in durable least-recently-served receipt order.
Restart retains that ordering. Two-type continuous-load tests verify that a busy
first type does not starve a later type; this is not a wall-clock latency guarantee
for every inventory size. See the [operator guide](../../manual/migration-operations.md)
for scheduling evidence and scope.

| Outcome | Durable behavior |
|---|---|
| `converted` | Target bytes and schema version publish with their receipt |
| `migration-rejected` | Original payload/version stay in quarantine, with reason |
| `payload-invalid` | Frozen decoder cannot interpret the historical payload; typed repair cannot pretend it is valid |
| Trap/budget/encoding error | No conversion result publishes; the application Worker records separate failure evidence, preserves the old job, and continues healthy peers |

Delayed and dead jobs participate without running their business handlers; retry
counts, disposition and schedules are retained. Live claims are not rewritten.
Claim tokens prevent a stale attempt from acknowledging another attempt's job.
An empty Worker scan is not a finality proof.

For execution failure, public status reports `QUEUE_MIGRATION_EXECUTION_FAILED`
and `executionFailed` counts. Restart suppresses retries of the same checked source
on the same original bytes. This is not business rejection and does not authorize
`QueueRepair`. An admitted predecessor may still process a processable old job
through its normal handler; completion keeps the audit. General typed recovery
for failed callbacks is still outside scope. See the operator guide for limits.

## 4. Repair a rejected historical value

Keep the deployed migration unchanged. Add `migrations/mail/repair1.tesl`:

```tesl
module Schema.Mail.Migrate.Repair1 exposing [repair]
import Tesl.Prelude exposing [String, Int]
import Tesl.Migration exposing [QueueRepair, Migrated(..)]
import Schema.Mail.V1
import Schema.Mail.VCurrent
import Schema.Mail.Migrate.V2

repair = QueueRepair {
  predecessor: Schema.Mail.Migrate.V2.migration
  job: "Delivery"
  revision: 1
  migrate: repairEmpty
  fixtures: [emptyJob]
}
fn repairEmpty(old: Schema.Mail.V1.Delivery) -> Migrated Schema.Mail.VCurrent.Delivery =
  Row (Schema.Mail.VCurrent.Delivery { body: "repaired", priority: 9 })
fn emptyJob() -> Schema.Mail.V1.Delivery =
  Schema.Mail.V1.Delivery { text: "" }
```

`"repaired"` is an explicit application policy, not an automatically inferred
correction. The callback still consumes original `V1.Delivery`. Run:

```sh
tesl agent-context migrations/mail/repair1.tesl
tesl test migrations/mail/repair1.tesl
```

The generated test requires the fixture to reproduce predecessor rejection before
running the repair. Another `Reject` remains a valid smoke outcome. To require
success, add a business assertion. Revision 2 names the directly imported,
exported `Repair1.repair`, keeps both endpoints/codecs unchanged and uses a new
callback identity. Gaps, cycles, reused callbacks and competing branches refuse.
The checked source chain is bounded to 128 repair revisions.

Explicitly import the latest repair module in the V2 application, rebuild, rerun
its normal installer, and run the repaired binary's schema Worker:

```tesl
import Schema.Mail.Migrate.Repair1
```

The installer appends the complete immutable lineage. The Worker retries the
original rejected bytes and retains earlier receipts. Running `tesl test` only
tests pure fixtures; it does not mutate durable jobs. A new revision cannot be
installed after retirement.

## 5. Retire the old version

Stop V1 processes and wait for their last heartbeat to age past 30 seconds. Using
Worker credentials, run the current binary:

```sh
./v2-repaired/app --schema contract V2 --json
```

This queue-only Contract needs no row-cleanup source declaration. It refuses
before target expansion and while old payloads, claims, conversion attempts or
recent retiring instances remain. It drains source-writer and compatibility locks,
then atomically records finality and advances both admission floors. Replay and
Worker restart revalidate the history. Later edges retain earlier receipts.

An old delayed unchanged job beside a changed payload is restamped by Contract,
without running its handler or changing its bytes, retry count or schedule. This
work is audited in the same transaction as retirement. Live retiring claims still
block; expired old claims are released, and surviving claims retain completion
rights. Any changed/rejected/malformed blocker prevents partial restamping. Do not
delete or manually relabel jobs to manufacture finality.

`--schema status --json` reports bounded per-job-type counts, installed repair
revisions, old claims, conversion attempts and recent retiring instances. It emits
stable blocker codes and actions; human status prints them too. Historical payload
bytes and arbitrary rejection text are not disclosed. More than 100 job types is
explicitly marked `complete: false`. Malformed historical payloads still lack a
typed repair path; the planned `IgnoreOld` policy is not yet available.

## Executable coverage

- [Three ordinary queue upgrades](../queue-three-upgrades/README.md): public
  install/Worker/repair/Contract, late writes, immutable receipts, restart and
  final typed handler completion.
- [Varied row-data upgrades](../db-three-upgrades/README.md): Rename,
  Retype/WriteBack, Legacy removal and proof Revalidate across four releases.
- `compiler/test/test_migration_queue_transform.ml`: source/type/proof checks,
  generated byte adapters, PostgreSQL concurrency, crash and claim boundaries.
- `scripts/test-db-migration-review-05.py`: adversarial public-command, catalog,
  SQL proof/type, payload and documentation tests. Known failures are explicit.

The complete private-PostgreSQL gate is `nix develop --command bash
scripts/run-migration-tests.sh`. Checkout tooling and Go/PostgreSQL are required
to build the examples; an installed compiler's embedded lesson is reference text,
not a bundled PostgreSQL service.
