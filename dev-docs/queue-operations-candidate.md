# Protected queue operations (unpublished)

This implements the operation portion of the format-4 candidate described in
[queue-control-format4-candidate.md](queue-control-format4-candidate.md). Production
format selection and queue backend dispatch remain disabled. The SQL is executed
by PostgreSQL regression tests through restricted request and worker logins.
Candidate installation now creates and verifies the closed operation catalog
alongside immutable source registration.
Typed dead-letter accessors, retirement, external-effect
idempotency and the final generated-app integration are separate remaining gates.

## Admission and payload identity

Every operation requires read-committed isolation, takes the calling version's
shared transaction fence, and checks admission in a subsequent statement. A call
that waited behind retirement must observe the new floor before reading or
changing jobs. Repeatable-read and serializable transactions cannot provide that
fresh snapshot and are refused before job access; generated versioned requests
already use explicit read-committed transactions.

A complete, persisted fresh-install inventory and a matching expanded source
version are mandatory. Source-only metadata and an UNKNOWN upgraded baseline
cannot authorize operations. The compiled runtime supplies its version; the SQL
interface does not attest which executable holds a shared request login. Request
and worker logins have no direct job-table or sequence privileges.

Enqueue records the calling version and registered payload identity. Claims only
select versions from the admitted floor through the calling version, with exact
matching frozen payload bytes and digest. They never reclaim expired future jobs
or incompatible payloads. Expired compatible claims are reclaimed in batches of
64 with `FOR UPDATE SKIP LOCKED`; the next due eligible job is selected in enqueue
order with the same locking rule. Processing and dead-letter processing have
separate states.

## Attempts, leases and transactions

PostgreSQL creates a random token plus monotone attempt sequence, records the
claiming version and transaction ID, and sets a finite lease. Completion, renewal,
retry and quarantine first lock the exact attempt, then check the clock. A lease
predicate only in an UPDATE/DELETE WHERE is insufficient: PostgreSQL may evaluate
it before waiting on an unchanged row lock. The regression suite reproduces that
failure against the earlier implementation and checks all four corrected paths.

An expired attempt cannot mutate a job in a later transaction. A handler that
claimed and finishes inside the same transaction can complete, fail or quarantine
past its lease because PostgreSQL proves the transaction identity and retains the
row lock. Renewal cannot revive an expired lease. No caller-supplied transaction
ownership flag is accepted. Rolled-back sequence increments may repeat; random
tokens prevent an abandoned attempt from matching a replacement.

Retry increments the stored attempt count, restamps unchanged payloads to the
claimant's current version, clears the claim and either schedules another attempt
or records `attempts-exhausted`. Quarantine preserves the original bytes and source
version and records `payload-invalid`. Acknowledgement and ordinary database
handler effects commit or roll back together when the handler uses one transaction.
This does not make external effects exactly once.

## Dead-letter inspection

The candidate metadata listing returns identity, source job type, source version,
attempt count and reason. It never decodes or returns raw JSON as a current typed
job. Quarantines remain visible below the admission floor. Inspection and counts
omit future versions; they do not imply claimability.

Requeue only accepts an unclaimed, compatible `dead` row inside the admitted
window. It resets attempts, restamps the current version and notifies the queue on
commit. It cannot retry a quarantine, an in-flight dead-letter claim or a future
job. Enqueue notifications also follow transaction commit/rollback.

## Evidence

The real PostgreSQL suite covers mixed versions, bounded nonblocking claims,
concurrent workers, stale token/sequence/version checks, renewal, retry restamping,
dead-letter metadata, refused quarantine requeue, unknown/incompatible admission,
retirement while a call waits, unchanged row-lock expiry, atomic business effects,
actual backend termination, transactional notifications and exact function
catalog/grants. It runs with `-race` in the mandatory migration PostgreSQL matrix.
These direct SQL tests are not a claim that a generated Tesl application already
uses this unpublished protocol.
