# Lesson 95 — Retire old producers without stranding queued work

An additive release can leave pending, delayed, dead-letter and in-flight jobs
stamped with an older schema version. Closing its additive epoch now restamps
those jobs to the surviving version before retiring the old applications.

This path requires a fresh, matching format-5 Worker installation and **identical
frozen payload contracts** throughout the retained history. It does not transform
payloads or remove a job type. Changed payloads still require the separate typed
queue transformation and repair protocol.

## Preview, stop old workers, then close the epoch

Use the surviving binary with its Worker login:

```sh
app --schema close-epoch --through V2 --dry-run --json
app --schema close-epoch --through V2 --json
```

Stop the old request and queue-worker processes first. Recent old heartbeats
refuse ordinary closure; `--force` explicitly overrides that heartbeat check.
It does not override live old claim leases, quarantine, payload compatibility,
or the transaction fences.

The dry run inspects source/admission state and reports recent instances. It
does not change jobs or establish that all claim leases have expired. If execution
reports a still-leased old attempt, let that lease expire after stopping the old
worker and retry the command.

## What happens to each job

| Existing state | Retirement behavior |
|---|---|
| Pending or delayed | Restamp; preserve payload, attempt count and schedule |
| Dead | Restamp; preserve payload, attempts and dead-letter reason |
| Processing or dead-letter processing, claimed by the surviving version | Restamp in place; preserve the claimant, token, sequence, transaction identity and lease |
| Processing or dead-letter processing, claimed by an old version with a live lease | Refuse closure without changing jobs or admission |
| Old claim whose lease expired | Restamp and release back to pending/dead; clear claim ownership but retain the sequence so a new claim gets a later attempt |
| Quarantined old payload | Refuse closure; preserve original payload/version for typed repair |

A surviving worker can complete its original attempt after retirement. A retired
producer cannot enqueue, and a retired claimant cannot complete or renew. Reclaimed
work uses a new attempt token and sequence. External effects retain the queue's
existing at-least-once semantics.

If an administrator later introduces a **non-quarantined** job stamp below the
floor, protected queue read and write operations refuse instead of silently
skipping the job. A historical quarantine remains visible through typed
dead-letter metadata, but cannot be claimed or requeued. The request role has
no direct permission to edit job storage.

## Atomic cleanup and retry

The command drains the retiring versions' transaction fences, validates the
complete queue source/receipt history, locks old job rows, and verifies their
states. Restamping, the retirement receipt, and the admission-floor advance
commit in **one transaction**. Payloads are not decoded or re-encoded.
An old queue transaction holding its fence delays that publication until the
transaction finishes; a still-leased old claim then refuses it without moving
the floor.

A crash before commit rolls all of that back. A crash after commit leaves the
epoch closed, and retry recognizes completion. No successfully closed epoch
leaves a job below its new admission floor.

This initial path uses one atomic transaction rather than a background batch
protocol. Large cohorts or concurrent surviving workers can cause an operation
deadline or serialization refusal; the transaction rolls back and can be retried.
The command never advances admission after only part of a cohort is restamped.

Quarantine is deliberately not an ordinary retry. `Requeue` cannot turn a
quarantined payload into a current typed job. The selected recovery policy is a
typed repair migration, with a separate explicit `IgnoreOld` decision for
discard; that transformation/repair execution path is still unfinished.

## Regression evidence

[`test_migration_queue_application.ml`](../../compiler/test/test_migration_queue_application.ml)
builds original V1/V2 apps through public compilation and deletes their source
tree before execution. The
[application assertions](../../compiler/test/fixtures/queue-application/application_test.go)
check both ordinary and dead-letter claims, delayed jobs, exact preserved job
fields, old-lease refusal, surviving attempt completion, old-version refusal,
quarantine protection, an old request transaction held across the closing
command, a forged below-floor job stamp, a canonically edited old payload
contract with its digest recomputed, pre/post-commit crashes and idempotent
retry.

The default [private PostgreSQL gate](../../scripts/run-migration-tests.sh) runs
this scenario with race detection. The protected SQL definitions changed for this
feature; older experimental format-5 catalogs fail exact verification rather than
being silently upgraded.
