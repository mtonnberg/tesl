#lang racket

;;; Queue and pub/sub runtime for Tesl.
;;;
;;; When a PostgreSQL database runtime is active (current-database-runtime is set
;;; and the backend is 'postgres), all operations go through PostgreSQL:
;;;   - Jobs are stored in tesl_jobs (FOR UPDATE SKIP LOCKED dequeue)
;;;   - Transactions are real PostgreSQL transactions; enqueue/publish fire
;;;     NOTIFY after commit so other-process workers and WebSocket servers wake
;;;   - Pub/sub events are written to tesl_pubsub_outbox inside transactions
;;;     and delivered to in-memory listeners after commit
;;;
;;; Horizontal scaling:
;;;   start-workers! spawns a dedicated LISTEN connection per queue so that
;;;   workers in separate OS processes also receive NOTIFY wakeups.
;;;   publish-event! sends NOTIFY "tesl_pubsub" with the outbox row ID so
;;;   that ALL backend processes' WebSocket servers deliver to their local clients.
;;;   Each backend reads (SELECT, not DELETE) the outbox row independently;
;;;   rows are cleaned up by a TTL sweep after OUTBOX-TTL-SECONDS seconds.
;;;
;;; When no database runtime is active (tests, development), the in-memory
;;; fallback is used — no PostgreSQL required.

(require db
         (only-in db/util/postgresql postgresql-connection<%>)
         json
         racket/format
         racket/list
         racket/match
         (only-in "logging.rkt"
                  tesl-log-active?
                  tesl-log-enqueue!
                  tesl-log-dequeue!
                  tesl-log-worker-done!
                  tesl-log-worker-fail!
                  tesl-log-publish!
                  tesl-log-deliver!)
         (only-in "../dsl/metrics.rkt"
                  metrics-active?
                  metric-counter-add!
                  metric-histogram-record!
                  duration-histogram-boundaries)
         (only-in "../dsl/capability.rkt"
                  define-capability
                  require-capabilities!
                  current-capabilities)
         (only-in "../dsl/private/check-runtime.rkt"
                  named-value
                  named-value?
                  named-value-name
                  named-value-value
                  named-value-facts
                  named-value-bindings
                  raw-value)
         (only-in "../dsl/private/evidence.rkt"
                  check-fail?
                  check-fail-message)
         (only-in "../dsl/check.rkt"
                  check-fail-status)
         (only-in "../dsl/private/domain-registry.rkt"
                  domain-registry-add!
                  register-background-thread!)
         (only-in "../dsl/types.rkt"
                  runtime-value->jsexpr
                  jsexpr->typed-value
                  lookup-record-spec
                  record-value?
                  record-value-type
                  record-value-fields)
         (only-in "../dsl/sql.rkt"
                  current-database-runtime
                  database-runtime-connection
                  database-runtime-database
                  database-spec-backend
                  database-spec-config
                  database-schema-name
                  postgres-spec-user
                  postgres-spec-database
                  postgres-spec-password
                  postgres-spec-server
                  postgres-spec-port
                  postgres-spec-socket)
         (for-syntax racket/base racket/list syntax/parse))

(provide
 queueRead
 queueWrite
 pubsub
 ;; Queue
 define-queue
 enqueue!
 process-next-job!
 process-next-job/result!
 pending-job-count
 start-workers!
 call-with-queue-transaction
 ;; Pub/sub channel
 define-channel
 publish-event!
 received-events
 start-pubsub-listen!        ; for WebSocket server
 ;; Proof predicates
 FromQueue
 FromDeadQueue
 ;; Type name for dead-letter job structs
 DeadJob
 ;; Dead-letter queue
 deadJobs
 requeue
 process-next-dead-job!
 process-next-dead-job/result!
 start-dead-workers!
 ;; Struct accessors (tests)
 (struct-out queue-spec)
 (struct-out channel-spec)
 (struct-out dead-job)
 ;; Worker-pool tracking (for DAP inspection)
 (struct-out worker-pool)
 worker-pool-live-count
 worker-pool-status)

;; ── Capabilities ────────────────────────────────────────────────────────────

(define-capability queueRead)
(define-capability queueWrite (implies queueRead))
(define-capability pubsub)

(define FromQueue 'FromQueue)
(define FromDeadQueue 'FromDeadQueue)
;; DeadJob is the Tesl type name for dead-letter job structs (dead-job).
;; Defined here so that `import Tesl.Queue exposing [DeadJob]` can generate
;; a valid `(only-in ... DeadJob)` clause.  Runtime type validation is lenient
;; (no registered predicate) — structural correctness is ensured by deadJobs.
(define DeadJob 'DeadJob)

;; ── Data structures ──────────────────────────────────────────────────────────

(struct queue-spec
  (name           ; symbol  — queue identifier
   job-types      ; (listof symbol)
   store          ; mutable hash  — in-memory fallback: job-id → job-entry
   semaphore      ; semaphore    — signals the worker thread when a job is available
   max-attempts   ; integer
   backoff        ; 'exponential | 'fixed
   initial-delay) ; integer (seconds)
  #:transparent)

(struct channel-spec
  (name           ; symbol
   store          ; mutable hash  — in-memory: key → (listof event)
   listeners)     ; mutable hash  — key → (listof callback)
  #:transparent)

;; A dead-job bundles:
;;   queue-spec — which queue to requeue into
;;   id         — the job's primary key string
;;   named-val  — the payload wrapped with FromDeadQueue proof
(struct dead-job (queue-spec id named-val) #:transparent)

;; A worker-pool tracks a set of fire-and-forget worker threads spawned by
;; start-workers! / start-dead-workers!.  It exists purely so the DAP debugger can
;; inspect otherwise-untrackable running workers — the threads' behaviour is
;; unchanged.  `threads` is the mutable list of spawned thread descriptors; the
;; LIVE worker count is derived as (count thread-running? threads), and `status`
;; is a coarse 'running | 'stopped summary computed on demand.
;;   kind        — 'worker | 'dead-worker
;;   queue-name  — symbol — the (first) drained queue's name
;;   queue-names — (listof symbol) — all queues this pool drains
;;   concurrency — integer — worker threads requested per queue
;;   threads     — box of (listof thread) — the spawned worker threads
(struct worker-pool
  (kind queue-name queue-names concurrency threads)
  #:transparent)

;; Live count = threads still running.  Best-effort and never raises.
(define (worker-pool-live-count pool)
  (with-handlers ([exn:fail? (lambda (_) 0)])
    (for/sum ([t (in-list (unbox (worker-pool-threads pool)))]
              #:when (thread-running? t))
      1)))

;; Coarse status for display.
(define (worker-pool-status pool)
  (if (> (worker-pool-live-count pool) 0) 'running 'stopped))

;; ── PostgreSQL context helpers ───────────────────────────────────────────────

(define (pg-active?)
  (define r (current-database-runtime))
  (and r (eq? (database-spec-backend (database-runtime-database r)) 'postgres)))

(define (pg-conn)
  (database-runtime-connection (current-database-runtime)))

(define (pg-schema)
  (database-schema-name (database-runtime-database (current-database-runtime))))

;; Issue #31: the shared database connection is a `virtual-connection` — each
;; thread that queries through it leases one pooled connection and keeps it
;; until the THREAD DIES.  Background queue threads never die, so after their
;; first query the poller and every SKIP-LOCKED worker would each pin a pool
;; slot forever (a queue with numberOfWorkers 4 silently eats half the default
;; 10-slot pool, and request handlers start timing out).  `disconnect` on a
;; virtual connection releases only the CURRENT thread's lease back to the pool
;; (the same trick the SSE path in dsl/web.rkt uses); the next query simply
;; re-leases.  Call this whenever a background thread goes idle.
(define (release-pool-lease! db-runtime)
  (define conn (and db-runtime (database-runtime-connection db-runtime)))
  (when conn
    (with-handlers ([exn:fail? void])
      (disconnect conn))))

;; Quoted "schema"."table" string for SQL
(define (pg-table schema table)
  (~a "\"" schema "\".\"" table "\""))

;; ── Dedicated connection (for LISTEN threads) ────────────────────────────────

(define (make-dedicated-pg-conn runtime
                                #:notification-handler [handler void])
  (define config (database-spec-config (database-runtime-database runtime)))
  (postgresql-connect
   #:user     (postgres-spec-user     config)
   #:database (postgres-spec-database config)
   #:password (or (postgres-spec-password config) "")
   #:server   (or (postgres-spec-server   config) "127.0.0.1")
   #:port     (or (postgres-spec-port     config) 5432)
   #:socket   (let ([s (postgres-spec-socket config)])
                (and s (not (equal? s "")) s))
   #:notification-handler handler))

;; NOTIFY channel names (lowercase)
(define (queue-notify-channel queue-s)
  (~a "tesl_queue_" (string-downcase (symbol->string (queue-spec-name queue-s)))))

(define PUBSUB-NOTIFY-CHANNEL "tesl_pubsub")

;; ── Payload serialization (PostgreSQL) ──────────────────────────────────────

(define (serialize-job-payload value)
  (define raw (raw-value value))
  (define jsexpr (runtime-value->jsexpr raw))
  (if (and (record-value? raw) (hash? jsexpr))
      (hash-set jsexpr '__type (symbol->string (record-value-type raw)))
      jsexpr))

(define (deserialize-job-payload jsexpr)
  (define type-str (and (hash? jsexpr) (hash-ref jsexpr '__type #f)))
  (if type-str
      (let ([type-sym (string->symbol type-str)]
            [clean    (hash-remove jsexpr '__type)])
        (if (lookup-record-spec type-sym #f)
            (jsexpr->typed-value type-sym clean 'queue)
            jsexpr))
      jsexpr))

;; ── In-memory job store helpers ──────────────────────────────────────────────

(define (make-job-id)
  (symbol->string (gensym 'job)))

(define (job-entry payload [status 'pending] [attempts 0])
  (hash 'payload payload 'status status 'attempts attempts))

(define (pending-jobs store)
  (for/list ([(k v) (in-hash store)]
             #:when (eq? (hash-ref v 'status) 'pending))
    (cons k v)))

(define (pending-job-count queue-s)
  (require-capabilities! (list queueRead))
  (unless (queue-spec? queue-s)
    (raise-user-error 'pending-job-count "expected a queue-spec, got ~a" queue-s))
  (cond
    [(pg-active?)
     (define row
       (query-row (pg-conn)
         (format "select count(*) from ~a where queue_name = $1 and status = 'pending'"
                 (pg-table (pg-schema) "tesl_jobs"))
         (symbol->string (queue-spec-name queue-s))))
     (vector-ref row 0)]
    [else
     (length (pending-jobs (queue-spec-store queue-s)))]))

(define (job-ok-result named-job)
  (hash 'kind 'ok 'job (raw-value named-job)))

(define (job-failed-result named-job reason [status 500])
  (hash 'kind 'failed
        'job   (raw-value named-job)
        'error (hash 'reason reason 'status status)))

;; ── define-queue macro ───────────────────────────────────────────────────────

(define-syntax (define-queue stx)
  (syntax-parse stx
    [(_ name:id
        (~optional (~seq #:database _db:expr))
        #:job-types (job-type:id ...)
        #:max-attempts max-att:integer
        #:backoff backoff-sym:id
        #:initial-delay init-delay:integer)
     #'(define name
         (let ([spec (queue-spec 'name
                                 '(job-type ...)
                                 (make-hash)
                                 (make-semaphore 0)
                                 max-att
                                 'backoff-sym
                                 init-delay)])
           ;; Register the LIVE spec so the DAP debugger can enumerate this queue
           ;; (and read its pending jobs) even when it is not a paused-frame local.
           (domain-registry-add! 'queues spec)
           spec))]))

;; ── Proof attachment ─────────────────────────────────────────────────────────

(define (attach-queue-proofs job-id raw-payload)
  (define job-id-subject (gensym 'job-id))
  (define job-subject    (gensym 'job))
  (define fact (list 'FromQueue (list 'Id '== job-id-subject) job-subject))
  (named-value job-subject raw-payload (list fact) (hash job-id-subject job-id)))

;; ── Dead-letter queue ─────────────────────────────────────────────────────────

(define (attach-dead-queue-proofs queue-s job-id raw-payload)
  (define job-id-subject (gensym 'job-id))
  (define job-subject    (gensym 'job))
  (define fact (list 'FromDeadQueue (list 'Id '== job-id-subject) job-subject))
  (define nv   (named-value job-subject raw-payload (list fact) (hash job-id-subject job-id)))
  (dead-job queue-s job-id nv))

;; Return the list of dead jobs for the given queue.
;; Each element is a dead-job struct whose named-val carries a FromDeadQueue proof.
;; Requires queueRead capability.
(define (deadJobs queue-s)
  (require-capabilities! (list queueRead))
  (unless (queue-spec? queue-s)
    (raise-user-error 'deadJobs "expected a queue-spec, got ~a" queue-s))
  (cond
    [(pg-active?)
     (define schema (pg-schema))
     (define rows
       (query-rows (pg-conn)
         (format "select id, payload from ~a
                  where queue_name = $1 and status = 'dead'
                  order by created_at asc"
                 (pg-table schema "tesl_jobs"))
         (symbol->string (queue-spec-name queue-s))))
     (for/list ([row (in-list rows)])
       (let* ([job-id      (vector-ref row 0)]
              [payload-str (vector-ref row 1)]
              [jsexpr      (string->jsexpr payload-str)]
              [raw-payload (deserialize-job-payload jsexpr)])
         (attach-dead-queue-proofs queue-s job-id raw-payload)))]
    [else
     (for/list ([(k v) (in-hash (queue-spec-store queue-s))]
                #:when (eq? (hash-ref v 'status) 'dead))
       (attach-dead-queue-proofs queue-s k (hash-ref v 'payload)))]))

;; Reset a dead job back to pending so it will be retried.
;; Clears attempt counter to give the job a fresh slate.
;; Requires queueWrite capability.
(define (requeue dead-job-val)
  (require-capabilities! (list queueWrite))
  (unless (dead-job? dead-job-val)
    (raise-user-error 'requeue "expected a dead-job, got ~a" dead-job-val))
  (define queue-s (dead-job-queue-spec dead-job-val))
  (define job-id  (dead-job-id dead-job-val))
  (cond
    [(pg-active?)
     (query-exec (pg-conn)
       (format "update ~a
                set status = 'pending', attempts = 0,
                    next_attempt_at = null, locked_at = null
                where id = $1"
               (pg-table (pg-schema) "tesl_jobs"))
       job-id)
     (semaphore-post (queue-spec-semaphore queue-s))
     #t]
    [else
     (define store (queue-spec-store queue-s))
     (define entry (hash-ref store job-id #f))
     (if entry
         (begin
           (hash-set! store job-id
                      (hash-set (hash-set entry 'status 'pending) 'attempts 0))
           (semaphore-post (queue-spec-semaphore queue-s))
           #t)
         #f)]))

;; ── Dead worker: dequeue, process, start ─────────────────────────────────────

;; Like dequeue-next! but picks up the next dead (status='dead') job.
;; Locks it as 'processing' while being handled.
;; Returns (list job-id named-val) or #f.
(define (dequeue-next-dead! queue-s)
  (cond
    [(pg-active?)
     (define schema (pg-schema))
     (define row
       (query-maybe-row (pg-conn)
         (format "update ~a
                  set status = 'processing', locked_at = now()
                  where id = (
                    select id from ~a
                    where queue_name = $1
                      and status = 'dead'
                    order by created_at asc
                    for update skip locked
                    limit 1
                  )
                  returning id, payload"
                 (pg-table schema "tesl_jobs")
                 (pg-table schema "tesl_jobs"))
         (symbol->string (queue-spec-name queue-s))))
     (if (not row)
         #f
         (let* ([job-id      (vector-ref row 0)]
                [payload-str (vector-ref row 1)]
                [jsexpr      (string->jsexpr payload-str)]
                [raw-payload (deserialize-job-payload jsexpr)]
                [dj          (attach-dead-queue-proofs queue-s job-id raw-payload)])
           (list job-id (dead-job-named-val dj))))]
    [else
     (define dead-entries
       (for/list ([(k v) (in-hash (queue-spec-store queue-s))]
                  #:when (eq? (hash-ref v 'status) 'dead))
         (cons k v)))
     (if (null? dead-entries)
         #f
         (let* ([entry    (car dead-entries)]
                [job-id   (car entry)]
                [job-data (cdr entry)]
                [payload  (hash-ref job-data 'payload)]
                [dj       (attach-dead-queue-proofs queue-s job-id payload)])
           (hash-set! (queue-spec-store queue-s) job-id
                      (hash-set job-data 'status 'processing))
           (list job-id (dead-job-named-val dj))))]))

;; Like process-next-job! but for dead jobs:
;;   - On success: deletes the job (acknowledged, handled)
;;   - On failure: restores status to 'dead' (leaves for the next dead-worker pass)
(define (process-next-dead-job! queue-s handler-fn)
  (define result (dequeue-next-dead! queue-s))
  (if (not result)
      #f
      (let ([job-id    (first result)]
            [named-job (second result)])
        (define (restore-dead!)
          (cond
            [(pg-active?)
             (with-handlers ([exn:fail? void])
               (query-exec (pg-conn)
                 (format "update ~a
                          set status = 'dead', locked_at = null
                          where id = $1"
                         (pg-table (pg-schema) "tesl_jobs"))
                 job-id))]
            [else
             (let* ([store (queue-spec-store queue-s)]
                    [entry (hash-ref store job-id #f)])
               (when entry
                 (hash-set! store job-id
                            (hash-set entry 'status 'dead))))]))
        (with-handlers ([exn:fail? (lambda (_e)
                                     (restore-dead!)
                                     #f)])
          (define handler-result (handler-fn named-job))
          (if (check-fail? handler-result)
              (begin (restore-dead!) #f)
              (begin
                (complete-job! queue-s job-id)   ; delete on success
                #t))))))

(define (process-next-dead-job/result! queue-s handler-fn)
  (define result (dequeue-next-dead! queue-s))
  (if (not result)
      #f
      (let ([job-id    (first result)]
            [named-job (second result)])
        (define (restore-dead!)
          (cond
            [(pg-active?)
             (with-handlers ([exn:fail? void])
               (query-exec (pg-conn)
                 (format "update ~a
                          set status = 'dead', locked_at = null
                          where id = $1"
                         (pg-table (pg-schema) "tesl_jobs"))
                 job-id))]
            [else
             (let* ([store (queue-spec-store queue-s)]
                    [entry (hash-ref store job-id #f)])
               (when entry
                 (hash-set! store job-id
                            (hash-set entry 'status 'dead))))]))
        (with-handlers ([exn:fail? (lambda (e)
                                     (restore-dead!)
                                     (job-failed-result named-job (exn-message e) 500))])
          (define handler-result (handler-fn named-job))
          (if (check-fail? handler-result)
              (begin
                (restore-dead!)
                (job-failed-result named-job
                                   (check-fail-message handler-result)
                                   (check-fail-status handler-result)))
              (begin
                (complete-job! queue-s job-id)
                (job-ok-result named-job)))))))

;; Like start-workers! but for dead jobs.
;; Uses a simple periodic poller (no LISTEN needed — dead jobs don't fire NOTIFY).
;; Polls every 10 seconds; drains all dead jobs before sleeping again.
(define (start-dead-workers! workers-alist capabilities)
  (define db-runtime (current-database-runtime))
  ;; Track the dead-letter worker threads in a pool for DAP inspection (additive).
  (define worker-threads (box '()))
  (for ([pair (in-list workers-alist)])
    (define queue-s    (car pair))
    (define handler-fn (cdr pair))
    (define wt
      ;; register-background-thread! records the handle for DAP stop-the-world
      ;; (no-op unless TESL_DEBUG is set); behaviour is otherwise unchanged.
      (register-background-thread!
       (thread (lambda ()
                 (let loop ()
                   (sleep 10)
                   (with-handlers ([exn:fail? void])
                     (parameterize ([current-capabilities  capabilities]
                                    [current-database-runtime db-runtime])
                       (let drain ()
                         (when (process-next-dead-job! queue-s handler-fn)
                           (drain)))))
                   (loop))))))
    (set-box! worker-threads (cons wt (unbox worker-threads))))
  ;; Register the live dead-letter worker pool for DAP inspection.
  (define queue-names (map (lambda (p) (queue-spec-name (car p))) workers-alist))
  (domain-registry-add!
   'workers
   (worker-pool 'dead-worker
                (if (pair? queue-names) (car queue-names) '|<none>|)
                queue-names
                1
                worker-threads)))

;; ── Transaction parameters ───────────────────────────────────────────────────

;; Deferred pub/sub deliveries: (listof (list channel-s key-str event-value outbox-id))
;; After commit, the publisher process delivers to its local listeners and records
;; the outbox-id in process-delivered-outbox-ids so the LISTEN thread skips it.
(define current-deferred-publishes (make-parameter #f))

;; Deferred semaphore posts: (listof semaphore)
;; Posted after transaction commit so workers wake only when jobs are visible.
(define current-deferred-semaphores (make-parameter #f))

;; Process-local set of outbox row IDs already delivered in-process.
;; Maps row-id → #t.  Entries are created when publish-event! runs INSIDE a
;; transaction (before commit, so the entry is visible before NOTIFY fires).
;; Entries are only removed when sweep-and-cleanup! deletes the outbox row via
;; the TTL sweep — never by deliver-row! — so the sweep also skips these rows
;; instead of re-delivering every 5 seconds.
(define process-delivered-outbox-ids (make-hash))

;; ── call-with-queue-transaction ─────────────────────────────────────────────

(define (call-with-queue-transaction thunk)
  (cond
    [(pg-active?)
     (define db-runtime (current-database-runtime))
     (define deferred     (box '()))
     (define deferred-sem (box '()))
     (define result
       (call-with-transaction (pg-conn)
         (lambda ()
           (parameterize ([current-deferred-publishes  deferred]
                          [current-deferred-semaphores deferred-sem])
             (thunk)))))
     ;; Transaction committed.  Deliver pub/sub events to in-process listeners.
     ;; The hash entries were already set inside the transaction by publish-event!
     ;; so the LISTEN thread is guaranteed to skip them.
     (for ([delivery (in-list (reverse (unbox deferred)))])
       (match-let ([(list ch key evt _row-id) delivery])
         (call-in-memory-listeners ch key evt)))
     ;; Wake in-process workers now that the jobs are committed and visible.
     (for ([sem (in-list (unbox deferred-sem))])
       (semaphore-post sem))
     result]
    [else (thunk)]))

;; ── enqueue! ─────────────────────────────────────────────────────────────────

(define (enqueue! queue-s payload)
  (require-capabilities! (list queueWrite))
  (unless (queue-spec? queue-s)
    (raise-user-error 'enqueue! "expected a queue-spec, got ~a" queue-s))
  (define raw-payload (raw-value payload))
  (define job-type-name
    (and (tesl-log-active?)
         (if (record-value? raw-payload)
             (symbol->string (record-value-type raw-payload))
             (~a raw-payload))))
  (cond
    [(pg-active?)
     (define schema (pg-schema))
     (define job-id (make-job-id))
     (define jsexpr (serialize-job-payload raw-payload))
     (query-exec (pg-conn)
       (format "insert into ~a (id, queue_name, payload) values ($1, $2, $3)"
               (pg-table schema "tesl_jobs"))
       job-id
       (symbol->string (queue-spec-name queue-s))
       (jsexpr->string jsexpr))
     ;; NOTIFY deferred to transaction commit — workers in other processes wake.
     (query-exec (pg-conn)
       "select pg_notify($1, '')"
       (queue-notify-channel queue-s))
     ;; Defer semaphore post to commit so in-process workers wake after the job is visible.
     (define deferred-sem (current-deferred-semaphores))
     (if deferred-sem
         (set-box! deferred-sem (cons (queue-spec-semaphore queue-s) (unbox deferred-sem)))
         (semaphore-post (queue-spec-semaphore queue-s)))
     (when (tesl-log-active?) (tesl-log-enqueue! job-type-name job-id))
     (when (metrics-active?)
       (metric-counter-add! "tesl.queue.enqueued" 1
                            (list (cons "tesl.queue" (~a (queue-spec-name queue-s))))))
     job-id]
    [else
     (define job-id (make-job-id))
     (hash-set! (queue-spec-store queue-s) job-id (job-entry raw-payload))
     (semaphore-post (queue-spec-semaphore queue-s))
     (when (tesl-log-active?) (tesl-log-enqueue! job-type-name job-id))
     (when (metrics-active?)
       (metric-counter-add! "tesl.queue.enqueued" 1
                            (list (cons "tesl.queue" (~a (queue-spec-name queue-s))))))
     job-id]))

;; ── dequeue-next! ────────────────────────────────────────────────────────────

(define (dequeue-next! queue-s)
  (require-capabilities! (list queueRead))
  (cond
    [(pg-active?)
     (define schema (pg-schema))
     (define row
       (query-maybe-row (pg-conn)
         (format "update ~a
                  set status = 'processing', locked_at = now()
                  where id = (
                    select id from ~a
                    where queue_name = $1
                      and status = 'pending'
                      and (next_attempt_at is null or next_attempt_at <= now())
                    order by created_at asc
                    for update skip locked
                    limit 1
                  )
                  returning id, payload, attempts"
                 (pg-table schema "tesl_jobs")
                 (pg-table schema "tesl_jobs"))
         (symbol->string (queue-spec-name queue-s))))
     (if (not row)
         #f
         (let* ([job-id      (vector-ref row 0)]
                [payload-str (vector-ref row 1)]
                [attempts    (vector-ref row 2)]
                [jsexpr      (string->jsexpr payload-str)]
                [raw-payload (deserialize-job-payload jsexpr)]
                [named-job   (attach-queue-proofs job-id raw-payload)])
           (list job-id named-job attempts)))]
    [else
     (define pending (pending-jobs (queue-spec-store queue-s)))
     (if (null? pending)
         #f
         (let* ([entry    (car pending)]
                [job-id   (car entry)]
                [job-data (cdr entry)]
                [attempts (hash-ref job-data 'attempts 0)]
                [payload  (hash-ref job-data 'payload)]
                [named    (attach-queue-proofs job-id payload)])
           (hash-set! (queue-spec-store queue-s) job-id
                      (hash-set job-data 'status 'processing))
           (list job-id named attempts)))]))

;; ── complete-job! ────────────────────────────────────────────────────────────

(define (complete-job! queue-s job-id)
  (cond
    [(pg-active?)
     (query-exec (pg-conn)
       (format "delete from ~a where id = $1"
               (pg-table (pg-schema) "tesl_jobs"))
       job-id)]
    [else
     (hash-remove! (queue-spec-store queue-s) job-id)]))

;; ── fail-job! ────────────────────────────────────────────────────────────────

(define (retry-delay-seconds queue-s attempts)
  (define initial (queue-spec-initial-delay queue-s))
  (if (eq? (queue-spec-backoff queue-s) 'exponential)
      (* initial (expt 2 attempts))
      initial))

(define (fail-job! queue-s job-id)
  (cond
    [(pg-active?)
     (define schema (pg-schema))
     (define row
       (query-maybe-row (pg-conn)
         (format "select attempts from ~a where id = $1"
                 (pg-table schema "tesl_jobs"))
         job-id))
     (when row
       (define attempts  (add1 (vector-ref row 0)))
       (define max-att   (queue-spec-max-attempts queue-s))
       (define new-status (if (>= attempts max-att) "dead" "pending"))
       (define delay-secs (retry-delay-seconds queue-s attempts))
       (query-exec (pg-conn)
         (format "update ~a
                  set status = $1, attempts = $2,
                      next_attempt_at = case when $1 = 'pending'
                                             then now() + ($3 || ' seconds')::interval
                                             else null end,
                      locked_at = null
                  where id = $4"
                 (pg-table schema "tesl_jobs"))
         new-status
         attempts
         (~a delay-secs)
         job-id)
       ;; Count AFTER the UPDATE persists the dead status — a raise above means
       ;; the job was NOT dead-lettered (it can still retry to success), and a
       ;; counter that fired first would page on a dead letter that never happened.
       (when (and (string=? new-status "dead") (metrics-active?))
         (metric-counter-add! "tesl.queue.jobs.dead" 1
                              (list (cons "tesl.queue" (~a (queue-spec-name queue-s)))))))]
    [else
     (define store (queue-spec-store queue-s))
     (define entry (hash-ref store job-id #f))
     (when entry
       (define attempts (add1 (hash-ref entry 'attempts 0)))
       (define max-att  (queue-spec-max-attempts queue-s))
       (if (>= attempts max-att)
           (begin
             (hash-set! store job-id
                        (hash-set (hash-set entry 'status 'dead) 'attempts attempts))
             (when (metrics-active?)
               (metric-counter-add! "tesl.queue.jobs.dead" 1
                                    (list (cons "tesl.queue" (~a (queue-spec-name queue-s)))))))
           (hash-set! store job-id
                      (hash-set (hash-set entry 'status 'pending) 'attempts attempts))))]))

;; ── process-next-job! (synchronous — for tests and simple workers) ───────────

;; Metrics: one tesl.queue.job.duration point per finished job attempt, labeled
;; by queue and outcome (ok / check-fail / error).  start-ms is #f when metrics
;; are off, so the whole record collapses to nothing.
(define (record-job-duration-metric! queue-s start-ms outcome)
  (when start-ms
    (metric-histogram-record!
     "tesl.queue.job.duration"
     (/ (- (current-inexact-milliseconds) start-ms) 1000.0)
     (list (cons "tesl.queue" (~a (queue-spec-name queue-s)))
           (cons "tesl.outcome" outcome))
     #:unit "s"
     #:boundaries duration-histogram-boundaries)))

(define (process-next-job! queue-s handler-fn)
  (define result (dequeue-next! queue-s))
  (if (not result)
      #f
      (let ([job-id    (first result)]
            [named-job (second result)]
            [attempts  (third result)])
        (define current-attempt (add1 attempts))
        (define job-type-name
          (and (tesl-log-active?)
               (let ([raw (raw-value named-job)])
                 (if (record-value? raw)
                     (symbol->string (record-value-type raw))
                     (~a (queue-spec-name queue-s))))))
        (when (tesl-log-active?)
          (tesl-log-dequeue! job-type-name job-id current-attempt (queue-spec-max-attempts queue-s)))
        (define metric-start (and (metrics-active?) (current-inexact-milliseconds)))
        (with-handlers ([exn:fail? (lambda (e)
                                     (record-job-duration-metric! queue-s metric-start "error")
                                     (fail-job! queue-s job-id)
                                     (when (tesl-log-active?)
                                       (tesl-log-worker-fail! job-type-name job-id current-attempt
                                                                (queue-spec-max-attempts queue-s)
                                                                (exn-message e)))
                                     #f)])
          (define handler-result (handler-fn named-job))
          (if (check-fail? handler-result)
              (begin
                (record-job-duration-metric! queue-s metric-start "check-fail")
                (fail-job! queue-s job-id)
                (when (tesl-log-active?)
                  (tesl-log-worker-fail! job-type-name job-id current-attempt
                                          (queue-spec-max-attempts queue-s)
                                          (check-fail-message handler-result)))
                #f)
              (begin
                (record-job-duration-metric! queue-s metric-start "ok")
                (complete-job! queue-s job-id)
                (when (tesl-log-active?)
                  (tesl-log-worker-done! job-type-name job-id))
                #t))))))

(define (process-next-job/result! queue-s handler-fn)
  (define result (dequeue-next! queue-s))
  (if (not result)
      #f
      (let ([job-id    (first result)]
            [named-job (second result)]
            [attempts  (third result)])
        (define current-attempt (add1 attempts))
        (define job-type-name
          (and (tesl-log-active?)
               (let ([raw (raw-value named-job)])
                 (if (record-value? raw)
                     (symbol->string (record-value-type raw))
                     (~a (queue-spec-name queue-s))))))
        (when (tesl-log-active?)
          (tesl-log-dequeue! job-type-name job-id current-attempt (queue-spec-max-attempts queue-s)))
        (define metric-start (and (metrics-active?) (current-inexact-milliseconds)))
        (with-handlers ([exn:fail? (lambda (e)
                                     (record-job-duration-metric! queue-s metric-start "error")
                                     (fail-job! queue-s job-id)
                                     (when (tesl-log-active?)
                                       (tesl-log-worker-fail! job-type-name job-id current-attempt
                                                                (queue-spec-max-attempts queue-s)
                                                                (exn-message e)))
                                     (job-failed-result named-job (exn-message e) 500))])
          (define handler-result (handler-fn named-job))
          (if (check-fail? handler-result)
              (begin
                (record-job-duration-metric! queue-s metric-start "check-fail")
                (fail-job! queue-s job-id)
                (when (tesl-log-active?)
                  (tesl-log-worker-fail! job-type-name job-id current-attempt
                                          (queue-spec-max-attempts queue-s)
                                          (check-fail-message handler-result)))
                (job-failed-result named-job
                                   (check-fail-message handler-result)
                                   (check-fail-status handler-result)))
              (begin
                (record-job-duration-metric! queue-s metric-start "ok")
                (complete-job! queue-s job-id)
                (when (tesl-log-active?)
                  (tesl-log-worker-done! job-type-name job-id))
                (job-ok-result named-job)))))))

;; ── start-workers! ───────────────────────────────────────────────────────────
;;
;; Three-thread model per queue/handler pair (with PostgreSQL):
;;   Thread 1 — Fallback Poller + stuck-job sweeper:
;;              wakes every 5 s; every ~1 min resets jobs stuck in 'processing'
;;              for > 10 minutes (handles crashed worker processes).
;;   Thread 2 — LISTEN Connection (PostgreSQL only):
;;              dedicated raw connection, LISTEN tesl_queue_<name>.
;;              Posts semaphore immediately when NOTIFY fires on commit.
;;   Thread 3 — SKIP LOCKED Worker:
;;              waits on semaphore, drains bursts, calls process-next-job!.

(define (start-workers! workers-alist capabilities #:concurrency [concurrency 1])
  (define db-runtime (current-database-runtime))
  (define use-pg?
    (and db-runtime
         (eq? (database-spec-backend (database-runtime-database db-runtime)) 'postgres)))

  ;; Track the SKIP-LOCKED worker threads in a pool so the DAP debugger can
  ;; inspect these otherwise-untracked workers.  Purely additive: the threads'
  ;; behaviour is unchanged.
  (define worker-threads (box '()))

  (for ([pair (in-list workers-alist)])
    (define queue-s    (car pair))
    (define handler-fn (cdr pair))
    (define sem        (queue-spec-semaphore queue-s))

    ;; Thread 1: Fallback poller + stuck-job sweeper
    ;; register-background-thread! records the handle for DAP stop-the-world
    ;; (no-op unless TESL_DEBUG is set); this was previously fire-and-forget.
    (register-background-thread!
     (thread (lambda ()
               (let loop ([n 0])
                 (sleep 5)
                 (semaphore-post sem)
                 (when (and use-pg? (= (modulo n 12) 0))
                   (with-handlers ([exn:fail? void])
                     (query-exec
                      (database-runtime-connection db-runtime)
                      (format "update ~a
                              set status = 'pending', locked_at = null
                              where queue_name = $1
                                and status = 'processing'
                                and locked_at < now() - interval '10 minutes'"
                              (pg-table
                               (database-schema-name
                                (database-runtime-database db-runtime))
                               "tesl_jobs"))
                      (symbol->string (queue-spec-name queue-s))))
                   ;; Issue #31: this thread sweeps once a minute and then
                   ;; sleeps — don't pin a pool slot in between.
                   (release-pool-lease! db-runtime))
                 (loop (add1 n))))))

    ;; Thread 2: LISTEN connection (PostgreSQL only)
    (when use-pg?
      (define notify-ch (queue-notify-channel queue-s))
      (register-background-thread!
       (thread
        (lambda ()
          (let reconnect ()
            (with-handlers ([exn:fail? (lambda (_)
                                         (sleep 5)
                                         (reconnect))])
              (define listen-conn
                (make-dedicated-pg-conn
                 db-runtime
                 #:notification-handler
                 (lambda (channel _payload)
                   (when (string=? channel notify-ch)
                     (semaphore-post sem)))))
              (query-exec listen-conn (~a "listen \"" notify-ch "\""))
              (let loop ()
                (sync (send listen-conn async-message-evt))
                (loop))))))))

    ;; Thread 3 × concurrency: SKIP LOCKED Workers
    ;; Multiple workers compete safely via FOR UPDATE SKIP LOCKED — no duplicate processing.
    (for ([_ (in-range concurrency)])
      (define wt
        ;; Also registered globally (in addition to the worker-pool box) so DAP
        ;; stop-the-world enumerates it uniformly with all other bg threads.
        (register-background-thread!
         (thread (lambda ()
                   (let loop ()
                     (semaphore-wait sem)
                     (let drain ()
                       (when (semaphore-try-wait? sem)
                         (drain)))
                     (let work ()
                       (define ok?
                         (with-handlers ([exn:fail? (lambda (_) #f)])
                           (parameterize ([current-capabilities  capabilities]
                                          [current-database-runtime db-runtime])
                             (process-next-job! queue-s handler-fn))))
                       (when ok? (work)))
                     ;; Issue #31: the queue is drained — release this worker's
                     ;; pool lease while it blocks on the semaphore (kept for
                     ;; the whole burst above; re-leased on the next job).
                     (when use-pg?
                       (release-pool-lease! db-runtime))
                     (loop))))))
      (set-box! worker-threads (cons wt (unbox worker-threads)))))

  ;; Register the live worker pool for DAP inspection.
  (define queue-names (map (lambda (p) (queue-spec-name (car p))) workers-alist))
  (domain-registry-add!
   'workers
   (worker-pool 'worker
                (if (pair? queue-names) (car queue-names) '|<none>|)
                queue-names
                concurrency
                worker-threads)))

;; ── define-channel macro ─────────────────────────────────────────────────────

(define-syntax (define-channel stx)
  (syntax-parse stx
    [(_ name:id)
     #'(define name
         (let ([spec (channel-spec 'name (make-hash) (make-hash))])
           ;; Register the LIVE channel so the DAP debugger can show this SSE
           ;; channel and its CONNECTED CLIENTS (the listeners hash) when paused.
           (domain-registry-add! 'channels spec)
           spec))]))

;; ── In-memory listener delivery ──────────────────────────────────────────────

(define (call-in-memory-listeners channel-s key-str event-value [outbox-id #f])
  (define listeners (channel-spec-listeners channel-s))
  (define cbs (hash-ref listeners key-str '()))
  (when (and (tesl-log-active?) (pair? cbs))
    (tesl-log-deliver! (channel-spec-name channel-s) key-str
                        (or outbox-id "direct") (length cbs)))
  (for ([cb (in-list cbs)])
    (with-handlers ([exn:fail? void])
      (cb event-value))))

;; ── publish-event! ───────────────────────────────────────────────────────────

(define (publish-event! channel-s key-str event-value)
  (require-capabilities! (list pubsub))
  (unless (channel-spec? channel-s)
    (raise-user-error 'publish-event! "expected a channel-spec, got ~a" channel-s))
  (when (tesl-log-active?)
    (tesl-log-publish! (channel-spec-name channel-s) key-str))
  (cond
    [(pg-active?)
     (define schema (pg-schema))
     (define jsexpr (runtime-value->jsexpr event-value))
     (define outbox-id
       (query-value (pg-conn)
         (format "insert into ~a (channel_name, channel_key, payload)
                  values ($1, $2, $3) returning id"
                 (pg-table schema "tesl_pubsub_outbox"))
         (symbol->string (channel-spec-name channel-s))
         key-str
         (jsexpr->string jsexpr)))
     ;; Always mark BEFORE pg_notify so the LISTEN thread is guaranteed to
     ;; skip this row-id regardless of whether we're inside a transaction.
     ;; Without this, events published outside a transaction (e.g. dead workers)
     ;; would be re-delivered by the LISTEN thread and by every 5-second sweep.
     (hash-set! process-delivered-outbox-ids outbox-id #t)
     ;; NOTIFY with row ID; deferred to commit when inside a transaction.
     ;; All backend processes receive this NOTIFY and SELECT the same row,
     ;; giving true fan-out across all instances.
     (query-exec (pg-conn)
       "select pg_notify($1, $2)"
       PUBSUB-NOTIFY-CHANNEL
       (~a outbox-id))
     ;; Update in-memory store (for received-events / tests)
     (define store (channel-spec-store channel-s))
     (hash-set! store key-str (append (hash-ref store key-str '()) (list event-value)))
     ;; Inside a transaction: defer listener delivery to post-commit.
     ;; Outside a transaction: deliver immediately.
     (define deferred (current-deferred-publishes))
     (if deferred
         (set-box! deferred
                   (cons (list channel-s key-str event-value outbox-id)
                         (unbox deferred)))
         (call-in-memory-listeners channel-s key-str event-value))]
    [else
     (define store (channel-spec-store channel-s))
     (hash-set! store key-str (append (hash-ref store key-str '()) (list event-value)))
     (call-in-memory-listeners channel-s key-str event-value)]))

;; ── Outbox TTL ────────────────────────────────────────────────────────────────
;;
;; Outbox rows are not deleted on delivery (each backend reads them independently).
;; Rows older than OUTBOX-TTL-SECONDS are deleted by the sweep-and-cleanup! function.
;; All backend processes must run start-pubsub-listen! with sweep interval <  TTL.

(define OUTBOX-TTL-SECONDS 30)

;; ── start-pubsub-listen! ─────────────────────────────────────────────────────
;;
;; Starts two background threads for pub/sub delivery:
;;   - LISTEN thread: receives PostgreSQL NOTIFY, delivers the outbox row to local
;;     in-memory WebSocket listeners.  Uses SELECT (not DELETE) so all backend
;;     processes independently receive the same event.
;;   - Sweep + cleanup thread: runs every 5 s; delivers rows missed by NOTIFY;
;;     deletes rows older than OUTBOX-TTL-SECONDS.
;;
;; channel-registry : hash channel-name-symbol → channel-spec
;; db-runtime       : database-runtime (captured inside call-with-database)
;; schema           : string — the PostgreSQL schema name

(define (start-pubsub-listen! channel-registry db-runtime schema)

  ;; Deliver one outbox row identified by row-id to local in-memory listeners.
  ;; Skips if this process already delivered it via post-commit.
  (define (deliver-row! row-id)
    (with-handlers ([exn:fail? void])
      (if (hash-ref process-delivered-outbox-ids row-id #f)
          ;; This process published it and already called listeners post-commit.
          ;; Do NOT remove the hash entry here — keep it so the 5-second sweep
          ;; also skips this row.  The entry is removed only when sweep-and-cleanup!
          ;; deletes the outbox row (TTL expiry), preventing repeated re-delivery.
          (void)
          ;; Another process published it — SELECT and deliver here.
          (let ([fetch-conn (make-dedicated-pg-conn db-runtime)])
            (with-handlers ([exn:fail? (lambda (_) (disconnect fetch-conn))])
              (let ([row (query-maybe-row
                          fetch-conn
                          (format "select channel_name, channel_key, payload
                                   from \"~a\".\"tesl_pubsub_outbox\" where id = $1"
                                  schema)
                          row-id)])
                (disconnect fetch-conn)
                (when row
                  (let* ([ch-name   (string->symbol (vector-ref row 0))]
                         [key-str   (vector-ref row 1)]
                         [jsexpr    (string->jsexpr (vector-ref row 2))]
                         [channel-s (hash-ref channel-registry ch-name #f)])
                    (when channel-s
                      ;; Mark BEFORE delivery so the 5-second sweep skips this row.
                      ;; Without this, the sweep re-delivers every event published by
                      ;; another backend instance (causing duplicate SSE messages).
                      (hash-set! process-delivered-outbox-ids row-id #t)
                      (call-in-memory-listeners channel-s key-str jsexpr row-id))))))))))

  ;; Sweep recent outbox rows not yet seen by this process, and delete old ones.
  (define (sweep-and-cleanup!)
    (with-handlers ([exn:fail? void])
      (let ([conn (make-dedicated-pg-conn db-runtime)])
        (with-handlers ([exn:fail? (lambda (_) (disconnect conn))])
          (let ([rows (query-rows
                       conn
                       (format "select id, channel_name, channel_key, payload
                                from \"~a\".\"tesl_pubsub_outbox\"
                                where created_at >= now() - interval '~a seconds'
                                order by id asc"
                               schema OUTBOX-TTL-SECONDS))])
            ;; Deliver recent rows not yet seen by this process.
            ;; Skip rows in process-delivered-outbox-ids — they were published
            ;; by this process and already delivered via post-commit.
            (for ([row (in-list rows)])
              (let* ([row-id    (vector-ref row 0)]
                     [ch-name   (string->symbol (vector-ref row 1))]
                     [key-str   (vector-ref row 2)]
                     [jsexpr    (string->jsexpr (vector-ref row 3))]
                     [channel-s (hash-ref channel-registry ch-name #f)])
                (when (and channel-s
                           (not (hash-ref process-delivered-outbox-ids row-id #f)))
                  ;; Mark before delivery so subsequent sweeps skip this row.
                  (hash-set! process-delivered-outbox-ids row-id #t)
                  (call-in-memory-listeners channel-s key-str jsexpr row-id))))
            ;; Delete rows older than the TTL and clean up their hash entries.
            ;; Only remove hash entries here (when the row is gone) — never earlier.
            (let ([old-ids (query-rows
                            conn
                            (format "delete from \"~a\".\"tesl_pubsub_outbox\"
                                     where created_at < now() - interval '~a seconds'
                                     returning id"
                                    schema OUTBOX-TTL-SECONDS))])
              (for ([id-row (in-list old-ids)])
                (hash-remove! process-delivered-outbox-ids (vector-ref id-row 0)))))
          (disconnect conn)))))

  ;; Sweep + TTL cleanup thread (every 5 s)
  ;; register-background-thread! records the handle for DAP stop-the-world
  ;; (no-op unless TESL_DEBUG is set); previously fire-and-forget.
  (register-background-thread!
   (thread (lambda ()
             (let loop ()
               (sleep 5)
               (sweep-and-cleanup!)
               (loop)))))

  ;; LISTEN thread: woken by NOTIFY, delivers outbox row to local listeners
  (register-background-thread!
   (thread
    (lambda ()
      (let reconnect ()
        (with-handlers ([exn:fail? (lambda (_)
                                     (sleep 5)
                                     (reconnect))])
          (define listen-conn
            (make-dedicated-pg-conn
             db-runtime
             #:notification-handler
             (lambda (_channel payload-str)
               (with-handlers ([exn:fail? void])
                 (define row-id (string->number payload-str))
                 (when row-id
                   (deliver-row! row-id))))))
          (query-exec listen-conn (~a "listen \"" PUBSUB-NOTIFY-CHANNEL "\""))
          ;; Deliver any rows that arrived before LISTEN was established
          (sweep-and-cleanup!)
          (let loop ()
            (sync (send listen-conn async-message-evt))
            (loop))))))))

;; ── received-events (for test assertions) ────────────────────────────────────

(define (received-events channel-s key-str)
  (hash-ref (channel-spec-store channel-s) key-str '()))
