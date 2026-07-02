# Tesl Queue / Pub-Sub / Websocket Design

**Status:** Accepted design, planned implementation.
**Tracked in:** `known_gaps.md` D-006, `LANGUAGE-SPEC.md` sections 11.15–11.17, 12.1, 16.10.
**Developer documentation:** `example/learn/lesson23-queues-and-workers.md`, `example/learn/lesson24-pubsub-websockets.md`.
**Reference example:** `example/queue-api.tesl` (planned syntax stub).

---

## Architecture: Why PostgreSQL, Not RabbitMQ or Redis

Tesl already mandates `backend postgres` for all database declarations (Section 11.9). Rather than introducing a second infrastructure dependency (RabbitMQ, Redis, SQS) for job queues and pub/sub, the design leans entirely into PostgreSQL's native capabilities:

- **Queues via `FOR UPDATE SKIP LOCKED`**: Safe concurrent dequeue without deadlocks.
- **Pub/sub via `LISTEN/NOTIFY`**: Instant event delivery with commit-phase semantics.
- **Transactional enqueue**: A job inserted inside a transaction only becomes visible if the transaction commits. No dual-write problem. No distributed transaction coordinator needed.
- **Outbox pattern for pub/sub**: Events written to `tesl_pubsub_outbox` inside a transaction; `NOTIFY` carries only the row ID. Eliminates the 8 KB `NOTIFY` payload limit and guarantees events only fire on commit.

The result is a fully reliable job queue and pub/sub system backed by a single Postgres instance — no additional infrastructure to operate, monitor, or scale.

---

## New Declarations

### `queue`

```text
<queue-decl> ::= "queue" <identifier> "{"
                   "database" <identifier>
                   "jobs" "[" <identifier> { "," <identifier> } "]"
                   [ "retry" "{" <retry-options> "}" ]
                 "}"

<retry-options> ::= { <retry-option> }
<retry-option>  ::= "maxAttempts" ":" <integer>
                  | "backoff"     ":" ( "exponential" | "fixed" )
                  | "initialDelay" ":" <integer>
```

A `queue` declaration creates a background job queue backed by the named `database`. The `jobs` list names the `record` types that can be enqueued. The compiler generates the `tesl_jobs` table schema automatically.

`retry` is optional. Defaults: `maxAttempts: 1` (no retries), `backoff: fixed`, `initialDelay: 0`.

With `backoff: exponential` and `initialDelay: N`, retry delays double: N, 2N, 4N, … seconds.

```tesl
queue EmailQueue {
  database MainDatabase
  jobs     [SendEmail, GeneratePDF]
  retry {
    maxAttempts:  3
    backoff:      exponential
    initialDelay: 60
  }
}
```

### `sseChannel`

```text
<channel-decl> ::= "sseChannel" <identifier> "(" <binding> { "," <binding> } ")" "{"
                     "database" <identifier>
                     "payload"  <identifier>
                   "}"
```

A `sseChannel` declaration creates a typed pub/sub channel backed by the named database (via the outbox pattern). Channel key parameters follow the same binding syntax as function parameters, including proof annotations. The `payload` type must be an ADT.

The runtime mangles the channel name and key into a Postgres channel string. `NOTIFY` carries only an outbox row ID; the actual payload is fetched from `tesl_pubsub_outbox`.

```tesl
type UserEvent
  = ProfileUpdated bio: String
  | AvatarChanged  url: String
  | AccountDeleted

sseChannel UserEvents(userId: String ::: UserId userId) {
  database MainDatabase
  payload  UserEvent
}
```

### `workers`

```text
<workers-decl> ::= "workers" <identifier> "for" <identifier> "{"
                     { <identifier> "=" <identifier> }
                   "}"
```

A `workers` declaration binds worker functions to job types, mirroring `server` for HTTP handlers. Each left-hand side is a job record type; each right-hand side is a `worker` function.

```tesl
workers EmailWorkers for EmailQueue {
  SendEmail   = sendEmailWorker
  GeneratePDF = generatePdfWorker
}
```

---

## New Function Kind: `worker`

`worker` is added to the function kind family alongside `fn`, `check`, `establish`, `auth`, and `handler`.

```text
<function-kind> ::= "check" | "establish" | "fn" | "auth" | "handler" | "worker"
```

Worker functions receive a proof-bearing job value. The `FromQueue` proof follows the same 2-argument pattern as `FromDb`:

```tesl
worker sendEmailWorker(job: SendEmail ::: FromQueue (Id == jobId) job)
  requires [smtpSend] =
  sendMail(job.to, job.subject, job.body)
```

Normal completion marks the job done. Calling `fail` marks the job failed; if the retry policy allows further attempts the job is re-queued with the configured backoff delay.

---

## New Statements

### `enqueue`

```text
<enqueue-statement> ::= "enqueue" <identifier> <record-literal>
```

Inserts a job into the queue associated with the named record type. Each job type belongs to exactly one queue — the compiler enforces this. Requires the relevant `queueWrite`-derived capability.

```tesl
enqueue SendEmail { to: req.email, subject: "Welcome!", body: welcomeBody }
```

Inside `with transaction`, the job is inserted atomically. Outside a transaction, delivery is at-most-once and the linter emits a warning.

### `publish`

```text
<publish-statement> ::= "publish" <identifier> "(" [ <expr> { "," <expr> } ] ")" <adt-constructor-expr>
```

Publishes an event to the named channel, parameterised by the channel key. The constructor must belong to the channel's `payload` ADT. Requires `pubsub` capability.

```tesl
publish UserEvents(userId) ProfileUpdated { bio: newBio }
```

Inside `with transaction`, uses the outbox pattern (durable delivery). Outside, sends a raw `NOTIFY` (at-most-once, linter warning).

### `with transaction`

```text
<with-transaction-statement> ::= "with" "transaction" "{" <body> "}"
```

Wraps all enclosed database operations (`insert`, `update`, `delete`, `enqueue`, `publish`) in a single Postgres transaction. The block returns its last expression. On any exception the transaction rolls back and no jobs or notifications escape. Nesting `with transaction` is a compile error.

```tesl
with transaction {
  let user = insert User { id: userId, email: req.email }
  enqueue SendEmail { to: req.email, subject: "Welcome!" }
  user
}
```

### `startWorkers` (in `main` blocks)

```text
<main-statement> ::= ...existing...
                   | "startWorkers" <identifier> "with" "capabilities" <capability-list>
```

Starts the three-thread orchestration for a worker group. Multiple `startWorkers` calls run independent worker groups concurrently.

```tesl
main {
  with database MainDatabase {
    with capabilities [appService] {
      serve        MyServer     on port          with capabilities [appService]
      startWorkers EmailWorkers                  with capabilities [smtpSend]
    }
  }
}
```

---

## New API Endpoint Kind: `websocket`

Websocket endpoints are declared with `websocket` instead of an HTTP method:

```text
<api-endpoint> ::= ...existing...
                 | "websocket" <string>
                     { <api-endpoint-line> }
                     { <subscribe-line> }

<subscribe-line> ::= "subscribe" <identifier> "(" [ <expr> { "," <expr> } ] ")"
```

A websocket endpoint authenticates the client, captures URL parameters, and subscribes the connection to one or more typed channels. No entry is needed in the `server` declaration — routing is automatic.

```tesl
websocket "/events/user/:userId"
  auth    session: Session ::: Authenticated session && ChannelOwner session userId
          via sessionOwnerAuth
  capture userId: String ::: UserId userId via userIdCapture
  subscribe UserEvents(userId)
```

Multiple `subscribe` lines subscribe the connection to multiple channels simultaneously. Each message sent to the client is a discriminated JSON envelope: `{ "channel": "ChannelName", "payload": { ... } }`.

---

## Capabilities: `Tesl.Queue`

A new built-in module `Tesl.Queue` provides:

- `queueRead` — required to inspect queue status.
- `queueWrite` — required to enqueue jobs.
- `pubsub` — required to publish channel events and to hold open websocket subscriptions.

Application capabilities imply queue capabilities using the same `implies` mechanism as databases:

```tesl
capability emailWrite implies queueWrite
capability emailRead  implies queueRead
```

---

## GDP Integration: `FromQueue` Proof

The worker boundary is the trusted proof introduction point for job values — exactly analogous to the SQL layer producing `FromDb` proofs.

The `define-queue-worker` macro (generated by the compiler) is a trusted boundary that:

1. Dequeues a raw JSON row from `tesl_jobs`.
2. Parses the JSON into a record value.
3. Fabricates a `FromQueue (Id == jobId) job` proof.
4. Passes the proof-bearing value to the user-defined worker function.

The developer's worker function only ever sees the typed, proof-bearing value. Raw SQL and JSON parsing are invisible.

`FromQueue (Id == jobId) job` follows the same 2-argument structure as `FromDb (Id == pk) entity`. Both subjects — the job's primary key and the job entity itself — are captured in the proof.

Field-level proofs on job records (e.g., `to: String ::: ValidEmail to via checkValidEmail`) are validated at enqueue time, not at dequeue time. This means invalid jobs cannot be inserted — the validation boundary is at the producer, not the consumer.

---

## PostgreSQL Runtime: The Three-Thread Model

Each `startWorkers` call launches exactly three threads:

**Thread 1 — Fallback Poller:** Wakes every 5 seconds and posts to the wake semaphore. Guarantees jobs are processed even if a `NOTIFY` is dropped due to a network interruption.

**Thread 2 — LISTEN Connection:** Holds a single dedicated Postgres connection open with `LISTEN`. When a `NOTIFY` fires (triggered by any `enqueue` inside a transaction that commits), it posts to the wake semaphore for instant wake-up.

**Thread 3 — SKIP LOCKED Worker:** Waits on the wake semaphore. When woken, drains the semaphore (de-bouncing burst enqueues) then runs:

```sql
UPDATE tesl_jobs
SET    status = 'processing', locked_at = NOW()
WHERE  id = (
  SELECT id FROM tesl_jobs
  WHERE  queue = $1 AND status = 'pending'
  ORDER BY created_at ASC
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING id, payload
```

If a job is found, the worker invokes the handler function. On success, the job is marked done. On `fail`, the job is marked failed and — if the retry policy allows — re-queued with the configured delay. After processing a job, the worker immediately re-posts to the semaphore to process the next job without waiting.

**Stuck-job sweeper:** A periodic background query resets jobs stuck in `processing` beyond a configurable timeout (default 10 minutes) back to `pending`. This handles worker crashes and OOM events.

**Semaphore draining:** If 50 enqueues arrive in one second, 50 `NOTIFY` events fire. The semaphore drain step de-bounces these into a single processing cycle, avoiding 49 redundant empty `SELECT` queries.

**Vertical scaling:** Multiple threads or processes can each call `startWorkers` on the same queue. `FOR UPDATE SKIP LOCKED` ensures each job is claimed by exactly one worker — no deadlocks, no duplicate processing.

**One LISTEN connection, N websocket clients:** For pub/sub, the Racket runtime holds a single dedicated `LISTEN` connection. When a `NOTIFY` arrives, it fans the event out in memory to all connected websocket clients. Ten thousand websocket clients do not produce ten thousand Postgres connections.

---

## Outbox Pattern for Pub/Sub

When `publish` is called inside `with transaction`:

1. The event payload is inserted into `tesl_pubsub_outbox` as part of the transaction.
2. A `NOTIFY` is issued on the same transaction with only the outbox row ID.
3. On commit, the `NOTIFY` is sent; on rollback, both the outbox row and the notification are discarded.

The LISTEN thread receives the notification, fetches the payload from `tesl_pubsub_outbox` by ID, delivers it to all subscribed websocket clients, then deletes the outbox row.

If the `NOTIFY` is dropped (network blip), the fallback poller sweeps `tesl_pubsub_outbox` for undelivered rows. This combines sub-millisecond latency (from `NOTIFY`) with durability (from the outbox table).

The developer never interacts with `tesl_pubsub_outbox` directly. The `publish` statement handles all of this transparently.

---

## Open Questions

The following design points are accepted in principle but the exact details are not yet settled.

**Concurrency setting for worker threads:** Should `startWorkers` accept a concurrency parameter (number of worker threads per group)? The current design runs one SKIP LOCKED worker thread per `startWorkers` call. Multiple concurrent workers can be achieved by calling `startWorkers` multiple times in `main`, but a dedicated `concurrency: N` option may be cleaner.

**Dead-letter queues:** After `maxAttempts` retries, a job is marked `dead`. Should the language provide a `deadLetter` declaration that routes dead jobs to a separate inspection queue? The current design leaves dead job handling to direct SQL inspection of the `tesl_jobs` table.

**Multiple subscription payload envelope:** The current design wraps multi-channel websocket messages as `{ "channel": "ChannelName", "payload": { ... } }`. The exact JSON key names and whether the channel name should be namespaced (e.g., `"QueueApiExample.UserEvents"`) is not finalised.

**`onSubscribe` initial state:** When a websocket client connects and subscribes to a channel, should the compiler support an optional `onSubscribe` expression that sends an initial snapshot? This would eliminate a common race condition between subscribing and fetching initial data. The design is open — it may be expressed as an `onSubscribe` line in the websocket endpoint declaration, or as a separate mechanism.
