# Background Jobs — No Infrastructure Tax

Setting up a job queue normally means picking a library, configuring Redis or a broker, writing serialization code, handling retry logic, and running extra services in docker-compose. In Tesl, queues are first-class declarations.

---

## Declare the job

```tesl
record NotifyJob {
  userId:  String
  message: String
}
```

A job is a plain record. It's serialized and stored automatically.

---

## Declare the queue

```tesl
queue NotificationQueue requires [emailCap, alertCap] = Queue {
  database: AppDatabase   # backed by PostgreSQL — no Redis, no extra service
  jobs: [Job NotifyJob notifyWorker (Something handleFailed)]
  retry: QueueRetryStrategy {
    maxAttempts: 3
    backoff: Exponential
    initialDelay: 5      # seconds before the first retry
  }
  numberOfWorkers: 3     # 3 concurrent worker threads
}
```

The queue is a folded record: each `Job <JobType> <workerFn> (<deadSlot>)` entry pairs a job record with its worker function and an optional dead-letter worker. Here `NotifyJob` is processed by `notifyWorker`, with `handleFailed` as the dead-letter worker (`(Something handleFailed)`); use `(Nothing)` when a job has no dead-letter worker.

The queue is backed by PostgreSQL using `SELECT ... FOR UPDATE SKIP LOCKED` — safe concurrent dequeue with no coordination layer. `numberOfWorkers: 3` runs three concurrent worker threads; `requires` lists the capabilities the workers need. Retry with exponential backoff is declarative, not wired up in application code.

---

## Declare the worker

```tesl
worker notifyWorker(job: NotifyJob ::: FromQueue (Id == jobId) job)
  requires [emailCap] =
  sendEmail(job.userId, job.message)
  job
```

Workers are typed and capability-governed — exactly like handlers. The `FromQueue` proof says: "this job came from the queue, not from application code." There is no separate `workers` declaration — the worker is wired to its job type directly in the queue's `jobs` list above. Capabilities work the same way as everywhere else.

---

## Enqueue from a handler

```tesl
handler postComment(user: User ::: Authenticated user, body: CommentBody)
  -> Comment
  requires [dbWrite, queueWrite] =
  with transaction {
    let c = insert Comment { content: body.content, authorId: user.id, ... }
    enqueue NotifyJob { userId: body.targetUserId, message: "New comment" }
    c
  }
```

Enqueue inside a transaction: if the DB write rolls back, the job is never enqueued. If both succeed, they commit atomically. No "job was enqueued but the insert failed" edge case.

---

## Dead-letter queues built in

```tesl
deadWorker handleFailed(job: NotifyJob ::: FromDeadQueue (Id == jobId) job)
  requires [alertCap] =
  sendAlert "delivery failed for " + job.userId
  job
```

Jobs that exhaust all retry attempts land in the dead-letter queue. The dead-letter worker is folded into the queue via the job's dead slot (`(Something handleFailed)` in the `jobs` list above) — no separate `deadWorkers` declaration, no polling loop, no custom failure table.

---

## Start workers with concurrency control

`main` is an ordinary function that returns an `App` description; the runtime starts everything from it. Listing `NotificationQueue` in `App.queues` activates its workers — the `numberOfWorkers: 3` normal worker threads plus the single dead-letter worker (from the job's `(Something handleFailed)` slot). There is no `startWorkers`/`startDeadWorkers`/`serve` call.

```tesl
main() -> App requires [appService, emailCap, alertCap] =
  App {
    database: AppDatabase
    api: AppServer
    port: 8080
    queues: [NotificationQueue]
  }
```

The `numberOfWorkers: 3` set on the queue gives 3 concurrent worker threads, each pulling with `SELECT ... FOR UPDATE SKIP LOCKED`. No coordination needed — PostgreSQL handles it. Capabilities are granted at the App root, derived from `main`'s `requires`. Dead workers always run single-threaded to prevent duplicate compensating actions.

---

*Next: [Real-time SSE →](07-realtime.md)*
