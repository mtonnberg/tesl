# Resolve old queue work before retirement

Queue jobs may be short-lived in purpose while still being durable in PostgreSQL.
Tesl does not infer that an old job is obsolete. An unresolved old job blocks
retirement until it is processed, converted, or explicitly discarded.

Use a new immutable `QueueRepair` revision for the existing transition. Do not edit
the deployed conversion, change historical codecs, or advance admission floors
manually. The declaration names a directly imported, exported predecessor and the
same exact job type/source/target contracts. Revisions are consecutive, beginning
at 1, and limited to 128 per chain.

## Preserve work with a corrected converter

Business rejection uses the existing policy (`on` omitted or `"rejected"`). For
callback traps, execution-budget exhaustion or unusable callback results, select
the operational failure policy explicitly:

```tesl
module Schema.Mail.Migrate.Recover1 exposing [repair]
import Tesl.Prelude exposing [String, Int]
import Tesl.Migration exposing [QueueRepair, Migrated(..)]
import Schema.Mail.Migrate.V2
import Schema.Mail.V1
import Schema.Mail.VCurrent

repair = QueueRepair {
  predecessor: Schema.Mail.Migrate.V2.migration
  job: "Delivery"
  revision: 1
  on: "execution-failed"
  migrate: recover
  fixtures: [failedJob]
}
fn recover(old: Schema.Mail.V1.Delivery) -> Migrated Schema.Mail.VCurrent.Delivery =
  Row (Schema.Mail.VCurrent.Delivery { body: old.text, priority: 17 })
fn failedJob() -> Schema.Mail.V1.Delivery =
  Schema.Mail.V1.Delivery { text: "poison" }
```

The names and record fields must match your frozen schema. The fixture must
actually reproduce the predecessor's execution failure under the normal bounded
adapter execution, then exercise the corrected converter. This is a regression
witness, not a universal termination proof. Prefer a deterministic failing input;
wall-clock exhaustion alone can depend on host load. If the predecessor accepts or
business-rejects the fixture, the generated recovery test fails.

The runtime separately requires the exact durable failure record and still-locked
original payload/attempt. A successful recovery writes target bytes/version with
its own conversion receipt. The earlier failure audit remains. If the corrected
converter returns `Reject`, a later ordinary `QueueRepair` may consume that precise
business rejection. Cancellation and database errors remain rollback events.

This cannot fabricate a decoded old value when the frozen decoder rejects the
historical bytes. Use the explicit discard policy if that work is obsolete.

## Discard obsolete original-version jobs explicitly

```tesl
module Schema.Mail.Migrate.Discard1 exposing [repair]
import Tesl.Migration exposing [QueueRepair]
import Schema.Mail.Migrate.V2
import Schema.Mail.V1
import Schema.Mail.VCurrent

repair = QueueRepair {
  predecessor: Schema.Mail.Migrate.V2.migration
  job: "Delivery"
  revision: 1
  on: "unconverted"
  discard: "Obsolete notifications from the retired release"
}
```

**This authorizes deletion of every remaining old-version Delivery job for the
named transition**, not just the jobs currently reporting errors. It covers
pending, delayed, dead and quarantined work, including malformed historical bytes.
Current-version jobs and other job types are unaffected. There is no typed callback
or fixture because deletion deliberately does not depend on decoding the old value.
The reason must be nonempty and at most 256 UTF-8 bytes.

Choose either recovery or discard at a particular revision; they cannot be competing
branches. If a prior remediation revision is already installed, name that revision
as predecessor and use the next number. Discard is terminal for that job's edge.

## Deploy and inspect before execution

1. Import the new remediation module in the target app. Run `agent-context` and the
   generated tests, then build with the edge's compatible pinned executable identity.
2. Run the target's installer command with installer credentials. This appends the
   immutable source lineage; it does not mutate jobs or retire the edge.
3. Run `app --schema status --json` as a read-capable application principal.
   `discardPlans` reports type, source/target versions, revision, reason, `pendingJobs`
   and `liveClaims`. `discardPlansComplete: false` marks a list beyond 100 plans.
   These counts describe the observation; admitted predecessor writers may add work.
4. Stop obsolete schema Workers and start the rebuilt Worker. A Worker that lacks
   the newly staged executable refuses rather than pretending the revision is done.
5. For discard, live claims are protected. Let handlers complete or stop them and
   wait for lease expiry. Each authorized deletion commits with its audit; rollback
   preserves both job and prior evidence. Prior conversion/failure receipts survive.
6. Stop retiring applications, wait for heartbeat requirements, and run the current
   target's ordinary Contract. It still drains the actual fences and checks all old
   jobs/claims/attempts. Neither policy can append new authority after retirement.

Status includes the cumulative `discarded` audit count. Neither Request nor Worker
can directly read/delete the private audit. Job IDs recorded in the audit cannot
be reused after deletion. No implicit expiry, operator SQL cleanup, or force-retire
bypass is introduced by these policies.
