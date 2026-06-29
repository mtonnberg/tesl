# 08 — Queue and Pub/Sub Runtime

The queue and pub/sub systems live in `tesl/queue.rkt` and use PostgreSQL's
`LISTEN/NOTIFY` for horizontal scaling.

---

## Architecture overview

```
User code                      queue.rkt runtime
─────────────────              ──────────────────────────────────────
enqueue Job {...}        →     INSERT INTO tesl_jobs ... (in transaction)
                               pg_notify('tesl_queue_<name>', 'wake_up')
                               (deferred to commit)
                                    │
                         NOTIFY ───►│  Thread 2: LISTEN connection
                                    │    semaphore-post
                                    ▼
                               Thread 3: SKIP LOCKED worker
                                    FOR UPDATE SKIP LOCKED
                                    → calls worker function
                                    → marks job done (or failed/retry/dead)
```

```
User code                      queue.rkt runtime
─────────────────              ──────────────────────────────────────
publish Chan(key) Evt {...}  → INSERT INTO tesl_pubsub_outbox (in transaction)
                               hash-set! process-delivered-outbox-ids row-id #t
                               NOTIFY 'tesl_pubsub' WITH row_id
                               call in-memory listeners (post-commit)
                                    │
                         NOTIFY ───►│  Thread: start-pubsub-listen!
                                    │    check process-delivered-outbox-ids
                                    │    (skip if already delivered)
                                    │    fetch outbox row by id
                                    │    call in-memory listeners
                                    ▼
                               SSE clients on this process
```

---

## Three-thread worker model (`start-workers!`)

For each `workers` group, `start-workers!` spawns N+2 threads:

### Thread 1: Fallback Poller + stuck-job sweeper

```racket
(thread (lambda ()
  (let loop ([n 0])
    (sleep 5)
    (semaphore-post sem)      ; wake workers every 5 s
    (when (= (modulo n 12) 0)
      ; Every ~1 minute: reset jobs stuck in 'processing' > 10 min
      (query-exec conn "UPDATE tesl_jobs SET status='pending' ..."))
    (loop (add1 n)))))
```

### Thread 2: LISTEN connection

```racket
(thread (lambda ()
  (let reconnect ()
    (with-handlers ([exn:fail? (lambda (_) (sleep 5) (reconnect))])
      (define listen-conn
        (make-dedicated-pg-conn db-runtime
          #:notification-handler
          (lambda (channel _payload)
            (when (string=? channel notify-ch)
              (semaphore-post sem)))))    ; wake workers on NOTIFY
      (query-exec listen-conn (~a "listen \"" notify-ch "\""))
      (let loop ()
        (sync (send listen-conn async-message-evt))
        (loop))))))
```

### Thread 3×N: SKIP LOCKED workers

```racket
(thread (lambda ()
  (let loop ()
    (semaphore-wait sem)        ; wait for signal
    (let drain ()               ; drain burst signals
      (when (semaphore-try-wait? sem) (drain)))
    (let work ()
      (define ok?
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (parameterize ([current-capabilities  capabilities]
                         [current-database-runtime db-runtime])
            (process-next-job! queue-s handler-fn))))
      (when ok? (work)))         ; keep processing while jobs available
    (loop))))
```

### `process-next-job!`

**Important:** Tesl's `fail N "msg"` compiles to `(reject ...)` which returns
a `check-fail` struct — it does NOT raise a Racket exception. The handler
return value must be checked for `check-fail?` explicitly; only exceptions
from crashing code are caught by `exn:fail?`.

```racket
(define (process-next-job! queue-s handler-fn)
  ; FOR UPDATE SKIP LOCKED — atomic claim
  (define row (query-maybe-row conn
    "SELECT id, payload, attempts FROM tesl_jobs
     WHERE queue_name = $1 AND status = 'pending'
       AND (next_attempt_at IS NULL OR next_attempt_at <= NOW())
     ORDER BY created_at
     LIMIT 1
     FOR UPDATE SKIP LOCKED"
    (symbol->string (queue-spec-name queue-s))))
  (when row
    ; Mark as processing; current-attempt = attempts + 1
    (query-exec conn "UPDATE tesl_jobs SET status='processing', locked_at=NOW() ...")
    ; Deserialize payload → typed record with FromQueue proof
    (define named-job (deserialize-job-payload ...))
    (with-handlers
      ([exn:fail? (lambda (e)
                    (fail-job! queue-s job-id)   ; retry or mark dead
                    #f)])
      (define result (handler-fn named-job))
      ; check-fail? catches `fail N "msg"` returns (not exceptions)
      (if (check-fail? result)
          (begin (fail-job! queue-s job-id) #f)
          (begin (complete-job! queue-s job-id) #t)))))  ; DELETE on success
```

The `FromQueue` proof is constructed in `deserialize-job-payload` using the
trusted macro boundary — user code cannot fabricate `FromQueue` proofs.

---

## Dead-letter workers (`start-dead-workers!`)

When a job reaches `maxAttempts` failures, `fail-job!` sets `status = 'dead'`.
Dead jobs are skipped by the normal worker loop and handled by a separate
dead-letter poll loop started by `startDeadWorkers` / `start-dead-workers!`.

```racket
(define (start-dead-workers! workers-alist capabilities)
  (for ([pair (in-list workers-alist)])
    (define queue-s    (car pair))
    (define handler-fn (cdr pair))
    (thread (lambda ()
              (let loop ()
                (sleep 10)   ; poll every 10 s (no NOTIFY for dead jobs)
                (with-handlers ([exn:fail? void])
                  (parameterize ([current-capabilities  capabilities]
                                 [current-database-runtime db-runtime])
                    (let drain ()
                      (when (process-next-dead-job! queue-s handler-fn)
                        (drain)))))
                (loop))))))
```

### `process-next-dead-job!`

```racket
(define (process-next-dead-job! queue-s handler-fn)
  ; FOR UPDATE SKIP LOCKED on status = 'dead'
  (define result (dequeue-next-dead! queue-s))
  (when result
    (let ([job-id (first result)] [named-job (second result)])
      (define (restore-dead!)
        (query-exec conn "UPDATE tesl_jobs SET status='dead', locked_at=null WHERE id=$1" job-id))
      (with-handlers ([exn:fail? (lambda (_) (restore-dead!) #f)])
        (define handler-result (handler-fn named-job))
        (if (check-fail? handler-result)
            (begin (restore-dead!) #f)
            (begin (complete-job! queue-s job-id) #t))))))  ; DELETE on success
```

- **Success** (job value returned): row is deleted — acknowledged.
- **`fail`** (check-fail?) or **exception**: status restored to `dead`, retried next poll.

The `FromDeadQueue` proof (on the job parameter of a `deadWorker`) is
constructed by `dequeue-next-dead!` — the trusted dead-queue boundary,
analogous to the `FromQueue` boundary in normal workers.

---

## Pub/sub outbox pattern (`publish-event!`)

Inside a `transaction {}` block, `publish` compiles to `publish-event!`:

```racket
(define (publish-event! channel-s key-str event-value)
  (cond
    [(pg-active?)
     ; Insert into outbox — always, regardless of transaction context
     (define outbox-id
       (query-value conn
         "INSERT INTO tesl_pubsub_outbox (channel_name, channel_key, payload)
          VALUES ($1, $2, $3) RETURNING id" ...))
     ;; ALWAYS mark BEFORE pg_notify — even outside a transaction.
     ;; Without this, events published by dead workers (outside a transaction)
     ;; would be re-delivered by the LISTEN thread and every 5-second sweep.
     (hash-set! process-delivered-outbox-ids outbox-id #t)
     (query-exec conn "SELECT pg_notify($1, $2)" PUBSUB-NOTIFY-CHANNEL (~a outbox-id))
     ; Inside transaction: defer listener delivery to post-commit
     ; Outside transaction: deliver immediately
     (define deferred (current-deferred-publishes))
     (if deferred
         (set-box! deferred (cons (list channel-s key-str event-value outbox-id)
                                  (unbox deferred)))
         (call-in-memory-listeners channel-s key-str event-value))]
    [else
     ; In-memory fallback (tests): direct delivery, no outbox
     (call-in-memory-listeners channel-s key-str event-value)]))
```

After the transaction commits:
1. `process-delivered-outbox-ids[outbox-id]` is already set (was set before `pg_notify`)
2. In-memory listeners are called for the current process
3. `NOTIFY tesl_pubsub outbox-id` fires (PostgreSQL deferred to commit)
4. Other processes' LISTEN threads see the NOTIFY, fetch the outbox row, deliver

### Duplicate delivery prevention

```racket
(define process-delivered-outbox-ids (make-hash))
```

A module-level hash. The LISTEN thread and the sweep both check before delivering:

```racket
(define (deliver-row! row-id)
  (if (hash-ref process-delivered-outbox-ids row-id #f)
      (void)    ; already delivered by this process — skip
      (... ; SELECT row, deliver to listeners ...)))
```

Entries are only removed when the TTL sweep deletes the outbox row — never
earlier. This prevents the sweep from re-delivering rows on every 5-second pass.

---

## SSE connection handling (`tesl/sse.rkt`)

`make-sse-connection-handler` returns a `(output-port? -> void?)` procedure
passed to `response/output`. It runs in a dedicated thread spawned by Racket's
web server chunked-response path.

```racket
(define (make-sse-connection-handler channel-spec channel-key)
  (lambda (out)
    (define event-ch (make-channel))

    ; Listener callback: non-blocking (sync/timeout 1) so the delivery
    ; thread never blocks on a dead connection whose loop has already exited.
    (define (on-event evt)
      (sync/timeout 1 (channel-put-evt event-ch evt)))

    ; Register listener for this (channel, key) pair
    (hash-set! (channel-spec-listeners channel-spec) channel-key
               (cons on-event (hash-ref ... channel-key '())))

    ; Send initial ": ok" comment immediately so the browser fires onopen
    ; without waiting for the first 10-second heartbeat timeout.
    ; (With HTTP chunked encoding the browser needs the first body chunk
    ; before it fires onopen — the headers alone are not enough in practice.)
    (write-bytes #": ok\n\n" out)
    (flush-output out)

    ; Event loop: ends when write fails (client disconnect)
    (let loop ()
      (define evt (sync/timeout 10 event-ch))   ; 10-second heartbeat
      (define ok?
        (with-handlers ([exn? (lambda (_) #f)])
          (if (not evt)
              (begin (write-bytes #": heartbeat\n\n" out) (flush-output out) #t)
              (begin (write-bytes (format-sse-event ...) out) (flush-output out) #t))))
      (when ok? (loop)))

    ; Cleanup: remove listener
    (hash-set! (channel-spec-listeners channel-spec) channel-key
               (remove on-event (hash-ref ... channel-key '())))))
```

### Connection stability: `connection-close? #f`

`serve/servlet` is called with `#:connection-close? #f`. This is critical for
SSE stability:

- `#:connection-close? #t` (old): web server uses the **non-chunked** response
  path. The connection timeout (60 s default) is set once on request arrival and
  **never reset**, so every SSE connection dies after ~60 seconds regardless of
  heartbeats.
- `#:connection-close? #f` (current): web server uses **chunked encoding**. The
  response path resets `response-send-timeout` (default 60 s) on **every chunk
  written**. Heartbeats every 10 s keep the timer from expiring, so connections
  stay alive indefinitely.

The SSE handler runs in a Racket thread spawned by `output-response-body/chunked`.
Response headers are flushed to the TCP socket immediately before the handler
thread starts, so the browser receives the 200 OK + `Content-Type: text/event-stream`
right away.

### DB pool release before SSE loop

In `handle-sse-request` (`dsl/web.rkt`), the database connection is released
back to the pool **before** entering the SSE loop:

```racket
(disconnect (database-runtime-connection (current-database-runtime)))
```

Without this, each open SSE connection permanently occupies a connection-pool
slot for its entire lifetime (minutes to hours), exhausting the default pool
of 10 connections after just a handful of browser tabs.

`disconnect` on a `virtual-connection` releases the **current thread's** leased
connection back to the pool — the `virtual-connection` object itself remains
valid and other threads are unaffected.

---

## Channel key and registry

`start-pubsub-listen!` takes a channel registry:

```racket
(define (start-pubsub-listen! channel-registry db-runtime schema)
  ; channel-registry: hash channel-name-symbol → channel-spec
  ; channel-spec: (struct channel-spec (name store listeners))
  ; listeners: hash key-string → list-of-listener-fns
```

Each SSE connection registers a listener function in `sse.rkt`:

```racket
; In sse.rkt when a client connects:
(hash-set! (channel-spec-listeners ch) channel-key
           (cons (lambda (evt)
                   (sync/timeout 1 (channel-put-evt event-ch evt)))
                 (hash-ref (channel-spec-listeners ch) channel-key '())))
```

When `call-in-memory-listeners` is called with a channel and key, it finds
all registered functions for that (channel, key) pair and calls each one.

---

## Queue job persistence format

Jobs are stored as JSON in `tesl_jobs.payload`:

```json
{
  "job_type": "SendEmail",
  "data": {"to": "user@example.com", "subject": "...", "body": "..."}
}
```

The deserialization function:
1. Parses JSON
2. Looks up the record spec for `SendEmail` via `lookup-record-spec`
3. Constructs a `record-value` with all fields
4. Attaches `FromQueue` (or `FromDeadQueue`) proof via the trusted macro

---

## Error handling and retry

When a worker function calls `fail N "msg"`:

- `fail` compiles to `(reject N "msg")` → returns a `check-fail` struct
- This is **not** a Racket exception — `with-handlers ([exn:fail? ...])` will NOT catch it
- `process-next-job!` checks `(check-fail? result)` after the handler returns
- On `check-fail?`: calls `fail-job!`
- On exception: the `exn:fail?` handler calls `fail-job!`

`fail-job!`:

```racket
(define (fail-job! queue-s job-id)
  (define attempts (add1 (current-attempts-from-db)))
  (define new-status (if (>= attempts max-attempts) "dead" "pending"))
  (query-exec conn
    "UPDATE tesl_jobs
     SET status=$1, attempts=$2,
         next_attempt_at = CASE WHEN $1='pending'
                                THEN now() + ($3 || ' seconds')::interval
                                ELSE null END,
         locked_at = null
     WHERE id = $4"
    new-status attempts (backoff-seconds attempts) job-id))
```

`compute-backoff` returns `initial-delay * 2^attempts` for exponential,
or `initial-delay` for fixed.
