# Durable email with Worker migration topology

`NewOutboxOn` uses the existing SMTP dispatcher, body variants, status values,
five-attempt limit, and `5 * 2^attempts` minute retry schedule. The schema Worker
does not dispatch mail. Dispatch runs in the application using Request credentials.

## Installation and rollout

Installer creates an optional format5 extension when the application declares an
email outbox:

- `tesl_email_runtime`: the fixed `tesl-email-envelope-v1` identity and a
  transactionally allocated numeric message ID;
- `tesl_email_messages`: the existing nullable runtime message envelope;
- exact security-definer functions for enqueue, claim, outcome, inspection and
  pruning, with an empty search path and Request-only execution grants.

Run the email-capable binary's `--schema install` before starting its application.
This works on a fresh installation and as an additive extension to an existing
format5 installation. One invocation installs all declared cache/email/SSE
extensions in one transaction. Requests only verify the catalog; they never create
or repair storage. Both catalog verifiers and the exact function inventory
recognize the extension when a later application has no email declaration.
Removing a declaration does not delete retained mail. Partial storage, orphaned
routines and extra overloads are rejected.

The extension does not change the immutable row/queue baseline inventory. Email
bodies contain no application entity or queue codec: an admitted newer schema
version can dispatch older pending messages using the same runtime envelope.
The SQL definitions and envelope identifier must not be edited in place for a
future incompatible runtime release; that requires an explicit protocol upgrade.

Binaries predating this extension fail closed on its protected catalog. Deploy
extension-aware runtimes for retained versions before enabling email. This does
not adopt an old lazily-created `tesl_email_outbox` from an unversioned database.
That requires explicit adoption, rather than treating arbitrary rows or ACLs as
Installer-owned storage.

## Transactions, claims and restart

Enqueue joins the caller's transaction, including rollback of its allocated ID.
All functions take the existing shared version fence, then perform a fresh
admission check. A request that waited behind retirement cannot write using a
pre-wait admission snapshot.

Claims select due pending rows with `FOR UPDATE SKIP LOCKED`, assign random
server-generated tokens and use the existing ten-minute claim window. Inspection
does not reveal tokens. Completion locks the matching pending row before checking
its deadline and token. Retry increments the stored attempt count; caller-supplied
attempt counts, scheduling or status fields are not authoritative. A crashed
dispatcher's expired claim can be replaced by another application instance; its
late outcome cannot overwrite the replacement. Sent-only pruning retains pending
and dead messages. Protected storage rejects destructive `reset`.

SMTP is not transactional or exactly-once. A process can deliver a message and
crash before recording success; reclaim can deliver it again. A version retired
during SMTP can likewise fail to record its outcome. No database lock is held
across SMTP by the ordinary dispatch path.

## Integration verification

`migration_email_test.go` covers storage/backend calls, rollback, claims across
request connections, expired-claim replacement, forged outcomes, retry scheduling/
exhaustion, permissions, catalog drift, optional installation, the prior nullable
scanner envelope, and post-wait version admission. The mandatory `email-runtime`
route in `scripts/run-migration-tests.sh` includes these tests and existing SMTP
tests. The `combined-facilities` route covers all three extensions together.

Integration has only been syntax-checked. PostgreSQL and compiler/runtime gates
remain pending. Regenerate `compiler/lib/go_runtime/embedded/embedded_go_runtime.ml`
once through the existing generator before building emitted applications. Real
process-kill and independently compiled old/new email release tests are not added;
restart is modeled by expiring a persisted claim and reclaiming through another
database binding.
