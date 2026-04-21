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
queue NotificationQueue {
  database AppDatabase   # backed by PostgreSQL — no Redis, no extra service
  jobs     [NotifyJob]
  retry {
    maxAttempts:   3
    backoff:       exponential
    initialDelay:  5     # seconds before the first retry
  }
}
```

The queue is backed by PostgreSQL using `SELECT ... FOR UPDATE SKIP LOCKED` — safe concurrent dequeue with no coordination layer. Retry with exponential backoff is declarative, not wired up in application code.

---

## Declare the worker

```tesl
worker notifyWorker(job: NotifyJob ::: FromQueue (Id == jobId) job)
  requires [emailCap] =
  sendEmail(job.userId, job.message)
  job

workers NotificationWorkers for NotificationQueue {
  NotifyJob = notifyWorker
}
```

Workers are typed and capability-governed — exactly like handlers. The `FromQueue` proof says: "this job came from the queue, not from application code." Capabilities work the same way as everywhere else.

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

deadWorkers FailedNotifications for NotificationQueue {
  NotifyJob = handleFailed
}
```

Jobs that exhaust all retry attempts land in the dead-letter queue. Handle them declaratively — no polling loop, no custom failure table.

---

## Start workers with concurrency control

```tesl
main with capabilities [appService, emailCap] {
  with database AppDatabase {
    startWorkers 3 NotificationWorkers with capabilities [emailCap]
    startDeadWorkers FailedNotifications with capabilities [alertCap]
    serve AppServer on 8080 with capabilities [appService]
  }
}
```

`3` concurrent worker threads, each pulling with `SELECT ... FOR UPDATE SKIP LOCKED`. No coordination needed — PostgreSQL handles it. Dead workers always run single-threaded to prevent duplicate compensating actions.

---

*Next: [Real-time SSE →](07-realtime.md)*
