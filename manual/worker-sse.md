# Durable SSE with Worker migrations

Format5 Worker databases can use database-backed SSE channels, including Apps
with no queues. Run the new binary's `--schema install` as Installer before
starting requests. Installer adds `tesl_sse_clock` and `tesl_sse_broadcast`, owned
by the control Owner, and grants Request SELECT only on both tables. Mutations
go through `tesl_sse_publish` and `tesl_sse_prune`, Owner-owned SECURITY DEFINER
functions with an empty fixed `search_path`. Only Request receives EXECUTE;
Worker and PUBLIC receive none.

Request startup verifies table constraints/ACL and each function's exact body,
signature, owner, security settings and execution ACL; it does not create or
repair storage. Worker verifies the optional extension without access to event
contents. Partial or altered extensions fail inspection rather than being adopted.
One Installer invocation installs every declared cache/email/SSE extension before
committing. Both exact catalog inventories retain extensions when declarations
are removed.

Each publish updates one transactional counter row, inserts encoded JSON and
queues a PostgreSQL notification in the same transaction. The counter row lock
lasts through the outer application's commit or rollback. Concurrent publishers
cannot commit a later sequence before an earlier one. Rollback exposes neither
event nor notification. Pruning does not reset the counter. Request cannot insert,
update, delete or truncate clock/event rows, choose a sequence or timestamp, or
supply a shorter retention interval.

Both functions require read-committed isolation, acquire the shared representation
and writer migration fences, and call `tesl_admit(v)` before touching the clock.
These checks apply to direct SQL calls. The runtime retains admission/heartbeat
checks. The clock has a fixed singleton name, primary key and nonnegative-value
constraint; event sequences must be positive. Startup, reconnect, Installer retry
and protected mutations reject a missing clock or one below the retained maximum
rather than repairing it. The clock may exceed the retained maximum after pruning.

Every running process has its own delivery cursor. Notifications wake ordered,
bounded reads; they do not claim or consume events. Each row is broadcast to every
local subscriber of its channel/key. Reconnect keeps the process cursor and sweeps
retained rows, including missed notifications. A newly started process captures
the committed counter and skips older events. Existing per-browser bounded buffers
and slow-subscriber drop behavior remain.

Retention enforces a fixed one-hour minimum age inside the protected prune
function, measured from publication in the transaction. Runtime pruning passes
the process cursor; SQL rejects cursors outside zero through the current clock.
A direct caller cannot delete younger rows even with the current clock. This is
finite-retention SSE, not an acknowledged delivery log: disconnected processes
can miss events older than retention. Browser reconnects do not replay history
using Last-Event-ID.

SSE stores already-encoded wire JSON, not a queue-style typed envelope. The server
does not deserialize it into a release-specific application type. Every release
reads the same broadcast rows. Application authors must preserve the client-facing
JSON protocol when changing codecs; this extension neither transforms SSE payloads
nor isolates readers by binary hash.

Legacy non-Worker outboxes retain their separate implementation and are not adopted
or bridged. Pre-extension binaries reject the additional format5 tables; archived
versions need extension-aware runtimes before rollout. Format4 and unsupported
facility combinations retain refusal paths.

## Integration checks

The mandatory `sse-broadcast` phase in `scripts/run-migration-tests.sh` runs
`TestWorkerBroadcast*`: Installer addition/retry, missing storage, Request DDL/DML
refusal, unauthorized execution, body/owner/search-path/ACL tampering, direct-call
admission and fences, singleton corruption, independent cursors, concurrent
writers, rollback, reconnect and retention/clock continuity. `combined-facilities`
covers cache/email/SSE together, including SSE without queues.

These tests have not been run during integration. The embedded Go snapshot must
be regenerated once by the normal generator before compiler/runtime gates.
