# Protected queue operations (unpublished)

> Audience: contributors implementing and verifying fenced queue operations.

This implements the operation portion of the format-4 candidate described in
[queue-control-format4-candidate.md](queue-control-format4-candidate.md). Production
format selection remains disabled. The SQL is executed
by PostgreSQL regression tests through restricted request and worker logins.
Candidate installation now creates and verifies the closed operation catalog
alongside immutable source registration.
Private backend dispatch and typed dead-letter accessors are implemented.
Database scopes cancel and join background workers before releasing their binding.
Retirement and external-effect idempotency remain separate gates before publication.

## Private application runtime

The private opener verifies the closed compiled application, persisted inventory,
exact catalog and restricted login on every physical pool connection. The queue
backend uses frozen schema identities rather than application variable names,
selects the registered codec by job identity, and preserves failed decodes as
quarantines. Its dedicated listener subscribes only to the queue channel, verifies
each reconnect, and wakes checked queues after a reconnect to recover missed
notifications. It neither creates nor reads SSE storage.

A compiled full-App regression drives emitted HTTP handlers, nested proof-checked
codecs, regular workers and a dead-letter worker against PostgreSQL. A test-only
bridge installs and binds the unpublished candidate using the actual linked
history; it supplies no hand-written history or codec. Loose history JSON is
removed before execution. Public `Main` remains refused even after this private
installation. This is evidence for generated handler/runtime integration, not
production startup or a rolling payload migration.

Worker cancellation stops new claims and wakes idle polling immediately. An active
claim finishes its handler, lease renewal and completion before the database scope
returns, including on signal shutdown or panic. Nested calls on the same database
borrow that binding; switching databases while workers are active is refused.
Each new scope owns a fresh cancellation context. Memory-only applications retain
their existing unscoped worker behavior.

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
The combined queue, registration, runtime, listener, dead-letter and preflight
race gate passes (80.591s), with zero lint findings. The generated-App gate is
also part of the required PostgreSQL matrix. The integrated worker, Embedded and
HTTP shutdown race gate passes (109.578s), including actual signal cancellation
before serving, in-flight success/failure with lease renewal, pending-job
preservation, panic unwinding and nested database bindings. These tests exercise
background workers separately from the compiled witness's synchronous dispatch.

A repeated integration run exposed a completion race: the worker stopped lease
renewal after the handler returned, before its result reached the queue store.
Renewal now lasts through completion, failure or panic persistence, and its
deferred cancellation joins afterward. Deterministic schedule tests and protected
PostgreSQL tests cover ordinary and dead-letter workers, successful and failed
handlers, and a delayed store write after handler return. The combined race gate
above includes this fix; both implementation reviews found no remaining issue in
that lifetime boundary.
