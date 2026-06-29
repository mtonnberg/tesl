# Lesson 23: Queues and Workers

> **Implemented — including horizontal scaling via LISTEN/NOTIFY.** When a `with database` context is active, all queue operations go through PostgreSQL automatically. Workers in **multiple OS processes** all receive wakeup signals via `NOTIFY` and compete safely via `FOR UPDATE SKIP LOCKED` — no duplicate processing. No code changes are needed; the runtime detects the database context at call time.
>
> An in-memory fallback is active when no database context is present (unit tests, REPL exploration).
>
> See `example/chat/chat-backend.tesl` and `example/learn/lesson28-dead-letter-queue.tesl` for complete working examples.

---

## QUICK START — just use it, no theory needed

### 1. Job types are ordinary `record` declarations

A job is just a record. Fields can carry proof annotations, and those proofs are validated at the time the job is submitted — so invalid jobs can never enter the queue.

```tesl
record SendEmail {
  to:      String ::: ValidEmail to      via checkValidEmail
  subject: String
  body:    String
}

record GeneratePDF {
  documentId: String ::: DocumentId documentId
  format:     String
}
```

The field-level `via` annotation works exactly like `check` function binding: when you call `enqueue SendEmail { to: addr, ... }`, the compiler runs `checkValidEmail(addr)` and the job is only inserted if the check passes.

### 2. Declare a queue

A `queue` declaration is a folded record: it ties each job type to its worker (and optional dead-letter worker) in a single `jobs` list, names the backing database, and configures retry behaviour and worker concurrency. Capabilities the workers need are listed in the queue's `requires`.

```tesl
queue EmailQueue requires [emailCap] = Queue {
  database: MainDatabase
  jobs: [Job SendEmail sendEmailWorker (Nothing)]
  retry: QueueRetryStrategy {
    maxAttempts: 3
    backoff: Exponential
    initialDelay: 60
  }
  numberOfWorkers: 1
}
```

- `database` — which Postgres database stores the jobs. The compiler creates the `tesl_jobs` table automatically.
- `jobs` — a list of `Job <JobType> <workerFn> (<deadSlot>)` entries. Each entry folds a record type together with its normal worker function and an optional dead-letter worker: `(Something deadFn)` to wire one, or `(Nothing)` if there is none. Each job type belongs to exactly one queue.
- `retry` — a `QueueRetryStrategy` describing what happens when a worker fails. With `backoff: Exponential` and `initialDelay: 60`, failures are retried after 60 s, 120 s, 240 s. After `maxAttempts` the job is dead.
- `numberOfWorkers` — how many parallel normal-worker threads to run (default 1). Listing the queue in `App.queues` activates these workers; there is no explicit start call.
- `requires` — the capabilities the queue's worker functions need; capabilities flow from here, granted at the App root.

### 3. Submit a job with `enqueue`

Inside any handler or function that has `queueWrite` capability, write:

```tesl
enqueue SendEmail { to: req.email, subject: "Welcome!", body: welcomeText }
```

The job type (`SendEmail`) tells the compiler which queue to use. You never name the queue directly in `enqueue`.

For guaranteed, atomic delivery — where the job only enters the queue if your database writes also succeed — wrap everything in `with transaction`:

```tesl
with transaction {
  let user = insert User { id: newId, email: req.email }
  enqueue SendEmail { to: req.email, subject: "Welcome!" }
  user
}
```

If the `insert` fails, the `enqueue` is rolled back. The worker will never see a job for a user that was never created.

### 4. Write a worker function

A `worker` function processes one job at a time. It receives a proof-bearing job value (`FromQueue` proof) exactly like a handler receives a proof-bearing HTTP request. Normal completion marks the job done. Calling `fail` marks the job failed and, if retries remain, re-queues it with the configured backoff.

```tesl
worker sendEmailWorker(job: SendEmail ::: FromQueue (Id == jobId) job)
  requires [smtpSend] =
  sendMail(job.to, job.subject, job.body)
```

The `FromQueue (Id == jobId) job` proof confirms this value came through the trusted dequeue boundary — it was not constructed by user code. This is the same guarantee as `FromDb (Id == pk) entity` for database-fetched records.

### 5. Workers are wired inside the queue's `jobs` list

There is no separate `workers` declaration. Each job type is paired with its worker function directly in the folded queue's `jobs` list:

```tesl
queue EmailQueue requires [smtpSend] = Queue {
  database: MainDatabase
  jobs: [
    Job SendEmail   sendEmailWorker  (Nothing)
    Job GeneratePDF generatePdfWorker (Nothing)
  ]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
  numberOfWorkers: 1
}
```

Every job type the queue handles appears exactly once as a `Job <JobType> <workerFn> (<deadSlot>)` entry. The dead slot is `(Something deadFn)` to attach a dead-letter worker, or `(Nothing)` when there is none.

### 6. Start the background processing from `main`

`main` is an ordinary function that returns an `App` description; the runtime starts everything from it. Listing a queue in `App.queues` activates its workers — the `numberOfWorkers` normal workers plus, if the job has a dead slot, the single dead-letter worker. There is no explicit `startWorkers`/`serve` call; the App root does it. Capabilities are granted at the App root, derived from `main.requires`.

```tesl
main() -> App requires [appService, smtpSend] =
  App {
    database: MainDatabase
    api: MyServer
    port: 8080
    queues: [EmailQueue]
  }
```

- All `numberOfWorkers` workers per queue compete via `FOR UPDATE SKIP LOCKED` — no duplicate processing.
- A LISTEN connection wakes workers in the same process AND in other processes (horizontal scaling) via PostgreSQL NOTIFY.
- A stuck-job sweeper resets jobs stuck in `processing` for > 10 minutes (handles crashed workers).
- SSE pub/sub LISTEN starts automatically — no separate start call is needed.

---

## UNDERSTANDING — what is actually happening

### Why PostgreSQL as the queue: eliminating the dual-write problem

In a typical web service with a separate queue (Redis, RabbitMQ), you face a fundamental reliability problem: after the database write succeeds but before the queue write happens, the process can crash. You end up with a committed user record and no welcome email — or a sent email and no user.

Postgres's native `LISTEN/NOTIFY` and `FOR UPDATE SKIP LOCKED` eliminate this entirely. When `enqueue` runs inside `with transaction`:

1. The job row is inserted into `tesl_jobs` as part of the database transaction.
2. A `NOTIFY` is issued on the same transaction connection.
3. Postgres holds the `NOTIFY` until the transaction commits. If the transaction rolls back, the `NOTIFY` is silently discarded — and the job row was never committed.

The job only exists if and only if the transaction committed. There is no window for inconsistency.

### The `FromQueue` proof: the dequeue boundary

When a worker receives a job, it receives a proof-bearing value. The `FromQueue (Id == jobId) job` proof means:

- `jobId` is the subject of the job's primary key — the specific row in `tesl_jobs`.
- `job` is the subject of the job record value — the specific deserialized payload.
- Both are in scope inside the worker function body.

This mirrors `FromDb (Id == pk) entity` exactly. The worker function cannot be called from user code with an arbitrary `SendEmail` record — it can only be called via the `define-queue-worker` macro, which is the trusted proof introduction point. The dequeue boundary is where raw JSON becomes a typed, evidence-bearing value.

This means you can write worker functions that accept further proof-bearing arguments, or pass the job value to other functions that require `FromQueue` evidence, and the type system ensures those functions cannot be called with fabricated values.

### Vertical scaling: `FOR UPDATE SKIP LOCKED`

Multiple workers (threads within one process, or multiple processes) can safely contend on the same queue because the dequeue query uses `FOR UPDATE SKIP LOCKED`. Each worker atomically claims exactly one job row. If another worker has already locked that row, `SKIP LOCKED` skips it and tries the next one — no deadlocks, no duplicate processing.

Scaling up means raising the queue's `numberOfWorkers` (for more threads in one process) or running the compiled Tesl binary on multiple machines. The queue handles the contention correctly in all cases.

### Retry policy: preventing thundering-herd

With `backoff: exponential` and `initialDelay: 60`:

- Attempt 1 fails → retry after 60 seconds.
- Attempt 2 fails → retry after 120 seconds.
- Attempt 3 fails → retry after 240 seconds.
- After `maxAttempts: 3`, the job is marked `dead`.

Exponential backoff prevents a thundering herd of retries when a downstream service (SMTP server, PDF renderer) is temporarily unavailable. The delay grows so that a brief outage causes at most a few retries, not an avalanche.

`backoff: fixed` keeps the delay constant — useful when you want a predictable retry cadence regardless of how many failures have occurred.

### Field proofs validated at enqueue time

If `SendEmail` declares `to: String ::: ValidEmail to via checkValidEmail`, then every `enqueue SendEmail { to: addr, ... }` call is equivalent to:

```tesl
let checkedAddr = check checkValidEmail(addr)
```

before the insert. Invalid email addresses are rejected at submission time. The worker function can safely assume `job.to` is a valid email — the proof is there on the type. There is no need to re-validate in the worker.

---

## THEORY — how it works under the hood

### The multi-thread runtime model

Activating a queue (by listing it in `App.queues`) spawns N+2 Racket threads, where N is the queue's `numberOfWorkers` (PostgreSQL mode):

**Thread 1 — Fallback Poller.** Sleeps for 5 seconds, then posts to a shared semaphore. Ensures no job is ever stranded, regardless of whether a NOTIFY was dropped.

**Thread 2 — LISTEN Connection.** Opens a dedicated raw PostgreSQL connection (not from the pool) and issues `LISTEN tesl_queue_<name>`. When PostgreSQL delivers a notification (triggered by `enqueue!`'s `pg_notify` on the same channel), this thread posts to the semaphore. Reconnects with a 5-second backoff on failure. This enables sub-millisecond cross-process wakeup.

**Threads 3…N+2 — SKIP LOCKED Workers** (N threads, default 1). Each waits on the shared semaphore. When woken (by Threads 1, 2, or by `enqueue!` in the same process):

1. Drains the semaphore — collapses burst signals into one processing cycle.
2. Issues `FOR UPDATE SKIP LOCKED` against `tesl_jobs`.
3. If a job is found: invokes the worker function. On success, deletes the row. On failure, retries or marks it `dead` according to the retry policy.
4. Re-posts the semaphore immediately so the next job is picked up without waiting.
5. When no job is found: returns to waiting.

All N workers share the semaphore and compete safely — `SKIP LOCKED` ensures no duplicate processing even within the same process.

**`enqueue!` inside a transaction** defers `pg_notify` to commit, so workers only wake when the job is actually visible. The in-process semaphore is also posted after commit. This guarantees no wasted wakeups.

Multiple backend processes each run their own set of N+2 threads. They all contend on the same `tesl_jobs` table safely — no locks, no deadlocks, no duplicate processing.

### Why `NOTIFY` sends only a wake-up signal

For queues, `NOTIFY` carries only the static string `'wake_up'` — it does not carry the job ID. This is intentional.

If the notification carried `job_id = 'j_123'` and two worker threads woke up, both would try to fetch job `j_123`. One would succeed; the other would find the row already locked and do wasted work. The `SKIP LOCKED` dequeue query is designed to work without any hint about which job to pick next — it always fetches the oldest available job.

For pub/sub, `NOTIFY` carries only the outbox row ID. The full payload is fetched from `tesl_pubsub_outbox` by the LISTEN thread. This eliminates the 8 KB `NOTIFY` payload limit entirely — the payload stored in the database table has no size limit.

**Semaphore draining prevents thundering herd for burst enqueues.** If 1,000 users register simultaneously, 1,000 `NOTIFY` events fire. The semaphore accumulates 1,000 posts. The drain step collapses these into a single processing cycle. The worker processes one job, re-posts once, processes another, and so on — efficiently draining the queue without 999 empty SELECT queries.

### The stuck-job sweeper

If a worker crashes after claiming a job (OOM, process kill, unhandled exception that escapes the handler), the job row is stuck in `processing` state permanently. A background sweeper periodically runs:

```sql
UPDATE tesl_jobs
SET    status = 'pending', locked_at = NULL
WHERE  status = 'processing'
AND    locked_at < NOW() - INTERVAL '10 minutes'
```

This resets stuck jobs back to `pending` so they will be processed again. The 10-minute timeout is the default; it can be configured. This is why workers should be idempotent where possible — a stuck job will be retried from scratch, not resumed.

### GDP at the queue boundary: `define-queue-worker` as trusted macro

The compiler generates a `define-queue-worker` macro call for each worker function. This macro is the trusted proof introduction point, exactly like the SQL layer's trusted `select` boundary produces `FromDb` proofs.

The macro:

1. Dequeues a raw JSON string from `tesl_jobs`.
2. Parses it into a Racket hash (the raw record value).
3. Creates a fresh GDP subject for the job record.
4. Attaches a `FromQueue` proof fact to the subject.
5. Passes the proof-bearing value to the user-defined worker function.

Because this code is inside the compiler-generated trusted layer (not user-accessible Tesl code), it is allowed to construct proofs from scratch — just like `define-trusted` and the SQL runtime are allowed to produce `FromDb` proofs. User Tesl code cannot fabricate `FromQueue` proofs. The only way to obtain a `FromQueue`-bearing value is to have it delivered by the worker runtime.

---

## Complete Worked Example: Atomic User Registration

This example shows a handler that atomically creates a user AND enqueues a welcome email, with the worker processing the email, including retry behaviour.

### Job type and queue

```tesl
record SendEmail {
  to:      String ::: ValidEmail to      via checkValidEmail
  subject: String
  body:    String
}

queue EmailQueue requires [smtpSend] = Queue {
  database: MainDatabase
  jobs: [Job SendEmail sendEmailWorker (Nothing)]
  retry: QueueRetryStrategy {
    maxAttempts: 3
    backoff: Exponential
    initialDelay: 30
  }
  numberOfWorkers: 1
}
```

### The registration handler

```tesl
handler registerUser(req: RegistrationRequest ::: ValidRequest req)
  requires [dbWrite, queueWrite] =
  with transaction {
    let userId = generateId "usr_"
    let user   = insert User {
      id:    userId,
      email: req.email,
      name:  req.name
    }
    enqueue SendEmail {
      to:      req.email,
      subject: "Welcome to our service",
      body:    welcomeTemplate(req.name)
    }
    user    # returns the inserted user (carries FromDb proof from the insert)
  }
```

The `with transaction` block guarantees:
- If the `insert` fails (e.g., duplicate email), `enqueue` is rolled back — no orphan job.
- If `enqueue` fails (e.g., `checkValidEmail` rejects the address), `insert` is rolled back — no user without a valid email.
- If the process crashes between the transaction start and commit, both are rolled back.
- Only when the transaction commits does the worker see the job.

### The worker function

```tesl
worker sendEmailWorker(job: SendEmail ::: FromQueue (Id == jobId) job)
  requires [smtpSend] =
  let result = attemptSmtpSend(job.to, job.subject, job.body)
  case result of
    SmtpSuccess ->
      job   # return the job to acknowledge it (ack = success)
    SmtpTemporaryFailure err ->
      fail 503 ("SMTP temporarily unavailable: " <> err)
    SmtpPermanentFailure err ->
      fail 400 ("SMTP permanent failure: " <> err)
```

When `fail` is called:
- The job's `status` is set to `failed`.
- If `attempts < maxAttempts`, the job is re-queued with a delay based on the retry policy.
- If `attempts == maxAttempts`, the job is marked `dead`.

From the developer's perspective:
- `fail 503` on attempt 1: worker retries after 30 s.
- `fail 503` on attempt 2: worker retries after 60 s.
- `fail 503` on attempt 3: job is dead. The row remains in `tesl_jobs` with `status = 'dead'` for inspection.
- `fail 400` on any attempt: permanent failure — no retries regardless of `maxAttempts`.

### Wiring and starting

The worker is already wired to `SendEmail` inside the queue's `jobs` list (above). To start everything, return an `App` from `main` and list the queue in `App.queues`:

```tesl
main() -> App requires [appService, smtpSend] =
  App {
    database: MainDatabase
    api: AppServer
    port: 8080
    queues: [EmailQueue]
  }
```

---

## Capabilities

### `Tesl.Queue` built-ins

The module `Tesl.Queue` provides three built-in capabilities:

- `queueWrite` — required to call `enqueue`.
- `queueRead` — required to inspect queue status (future: queue monitoring API).
- `pubsub` — required to call `publish` and to hold open websocket subscriptions (see Lesson 24).

These are analogous to `dbRead` / `dbWrite` from `Tesl.DB`.

### Implying queue capabilities from application capabilities

Application capabilities imply queue capabilities with `implies`, exactly like database capabilities:

```tesl
capability emailWrite implies queueWrite
capability emailRead  implies queueRead
```

Any function with `requires [emailWrite]` automatically satisfies `queueWrite`. The `enqueue SendEmail` call in `registerUser` above works because `emailWrite` implies `queueWrite`.

This design lets you express application-level intent (`emailWrite` = "this code can send emails") while the language enforces the underlying infrastructure access (`queueWrite` = "this code can write to the job queue").

---

See `example/queue-api.tesl` and `example/learn/lesson28-dead-letter-queue.tesl` for complete annotated examples, `example/learn/lesson31-worker-concurrency.tesl` for `numberOfWorkers`, and `example/learn/lesson24-pubsub-sse.md` for pub/sub channels and SSE endpoints.
