#lang racket/base

;;; domain-inspect.rkt — dependency-free recognition + summarisation of the Tesl
;;; DSL's live domain runtime objects, for the DAP "Domain" scope.
;;;
;;; The DSL's domain runtime objects (queues, pub/sub / SSE channels, caches, the
;;; email outbox) and the worker-pool tracking record are all #:transparent
;;; structs.  Rather than couple to their modules — which pull in the full web/db
;;; runtime and several of which do not load in isolation — we recognise them
;;; GENERICALLY: every such struct prints its constructor name (queue-spec,
;;; channel-spec, cache-spec, email-spec, worker-pool, dead-job), which we read via
;;; the struct type name, and we read its fields via struct->vector.  This keeps the
;;; debugger zero-dependency on the web/db runtime while still surfacing the FULL
;;; live domain state.
;;;
;;; This module is shared by dsl/debug/dap-server.rkt (the live debugger) and the
;;; smoke test (tests/dap-domain-registry-smoke.rkt), so the rendering logic is
;;; exercised by a deterministic test rather than only through a flaky subprocess
;;; protocol session.  Its only requires are the lightweight value predicates and
;;; the (dependency-free) global domain registry.

(require (only-in "../private/evidence.rkt"
                  named-value? check-ok?)
         (only-in "../types.rkt"
                  newtype-value? record-value?)
         (only-in "../private/domain-registry.rkt"
                  domain-registry-entries))

(provide domain-struct-name
         domain-object?
         DOMAIN-STRUCT-NAMES
         domain-object-summary
         domain-object-fields
         domain-field-names
         channel-connected-count
         worker-pool-live
         email-outbox-counts
         pending-job-count-of
         registry-object-label
         domain-registry-objects)

;; The struct type name (a symbol) of v, or #f if v is not a struct we can name.
;; Excludes the proof/value wrapper structs so they are never mistaken for a
;; domain object.
(define (domain-struct-name v)
  (and (not (or (named-value? v) (check-ok? v) (newtype-value? v) (record-value? v)))
       (struct? v)
       (let-values ([(st _skipped?) (struct-info v)])
         (and st
              (let-values ([(name _ic _fc _ar _aw _imm _spr _skp?) (struct-type-info st)])
                name)))))

;; The recognised domain runtime structs.
(define DOMAIN-STRUCT-NAMES
  '(queue-spec channel-spec cache-spec email-spec dead-job worker-pool))

;; Is v one of the recognised domain runtime objects?
(define (domain-object? v)
  (let ([n (domain-struct-name v)])
    (and n (memq n DOMAIN-STRUCT-NAMES) #t)))

;; The struct fields of a domain object (the struct-id tag dropped).
(define (domain-object-fields v)
  (cdr (vector->list (struct->vector v))))

;; The display field names for a domain struct kind.
(define (domain-field-names name field-count)
  (case name
    [(queue-spec)   '("name" "jobTypes" "store" "semaphore" "maxAttempts" "backoff" "initialDelay" "jobTypeRefs")]
    [(channel-spec) '("name" "store" "listeners")]
    [(cache-spec)   '("name" "defaultTtl" "codec" "capability" "store")]
    [(email-spec)   '("name" "database" "smtpHost" "smtpPort" "smtpUsername" "smtpPassword" "smtpTls" "store")]
    [(worker-pool)  '("kind" "queue" "queues" "concurrency" "threads")]
    [(dead-job)     '("queue" "id" "payload")]
    [else           (for/list ([i (in-range field-count)]) (format "field~a" i))]))

;; ── Summary helpers (all dependency-free, never raise) ──────────────────────────

;; Count pending jobs in an in-memory queue store (hash job-id → entry-hash with a
;; 'status key).  Returns the count of 'pending entries, or the total count if the
;; entries are not the expected shape.
(define (pending-job-count-of store)
  (and (hash? store)
       (with-handlers ([exn:fail? (lambda (_) (hash-count store))])
         (for/sum ([(_k v) (in-hash store)]
                   #:when (and (hash? v) (eq? (hash-ref v 'status #f) 'pending)))
           1))))

;; Count connected SSE clients across all keys of a channel's listeners hash
;; (key → (listof callback)).  Each callback is one connected client.
(define (channel-connected-count listeners)
  (if (hash? listeners)
      (with-handlers ([exn:fail? (lambda (_) 0)])
        (for/sum ([(_k cbs) (in-hash listeners)])
          (if (list? cbs) (length cbs) 1)))
      0))

;; Tally pending/sent/dead from an email-spec store (box of (listof entry-hash),
;; each with a 'status key).  Returns three values.
(define (email-outbox-counts store)
  (define entries
    (cond [(and (box? store) (list? (unbox store))) (unbox store)]
          [(list? store) store]
          [else '()]))
  (with-handlers ([exn:fail? (lambda (_) (values (length entries) 0 0))])
    (for/fold ([p 0] [s 0] [d 0]) ([e (in-list entries)])
      (define st (and (hash? e) (hash-ref e 'status #f)))
      (case st
        [(pending) (values (add1 p) s d)]
        [(sent)    (values p (add1 s) d)]
        [(dead)    (values p s (add1 d))]
        [else      (values (add1 p) s d)]))))

;; Live worker count = threads still running, from a worker-pool's threads field
;; (a box of a list of threads, or a bare list).
(define (worker-pool-live threads-box)
  (with-handlers ([exn:fail? (lambda (_) 0)])
    (define ts (cond [(box? threads-box) (unbox threads-box)]
                     [(list? threads-box) threads-box]
                     [else '()]))
    (for/sum ([t (in-list ts)] #:when (and (thread? t) (thread-running? t))) 1)))

;; A short human label for a domain object, e.g. "Queue emailJobs (2 pending)".
;; Best-effort and never raises — falls back to the struct name.
(define (domain-object-summary v)
  (with-handlers ([exn:fail? (lambda (_e) (format "~a" (domain-struct-name v)))])
    (define name (domain-struct-name v))
    (define fields (domain-object-fields v))
    (define (field-ref idx) (and (> (length fields) idx) (list-ref fields idx)))
    (define (store-count idx)
      (let ([s (field-ref idx)]) (and (hash? s) (hash-count s))))
    (case name
      ;; queue-spec: (name job-types store semaphore max-attempts backoff initial-delay)
      [(queue-spec)
       (format "Queue ~a (~a pending)" (field-ref 0)
               (or (pending-job-count-of (field-ref 2)) 0))]
      ;; channel-spec: (name store listeners) — listeners holds CONNECTED SSE CLIENTS
      [(channel-spec)
       (let ([n (channel-connected-count (field-ref 2))])
         (format "SSE Channel ~a (~a connected client~a)" (field-ref 0)
                 n (if (= n 1) "" "s")))]
      ;; cache-spec: (name default-ttl codec capability store)
      [(cache-spec)
       (format "Cache ~a (~a entries)" (field-ref 0) (or (store-count 4) 0))]
      ;; email-spec: (name database smtp-host smtp-port ... store) — store is last
      [(email-spec)
       (let-values ([(p s d) (email-outbox-counts (last-of fields))])
         (format "Email ~a outbox (~a pending, ~a sent, ~a dead)"
                 (field-ref 0) p s d))]
      ;; worker-pool: (kind queue-name queue-names concurrency threads)
      [(worker-pool)
       (let ([live (worker-pool-live (field-ref 4))])
         (format "~a [~a] (concurrency ~a, ~a live, ~a)"
                 (if (eq? (field-ref 0) 'dead-worker) "DeadWorkers" "Workers")
                 (field-ref 1)
                 (field-ref 3)
                 live
                 (if (> live 0) "running" "stopped")))]
      [(dead-job)
       (format "DeadJob ~a" (field-ref 1))]
      [else (format "~a" name)])))

;; A display label for a registry-only domain object (no local binds it):
;; "<structName> <specName>", e.g. "queue-spec emailJobs".
(define (registry-object-label v)
  (with-handlers ([exn:fail? (lambda (_) (format "~a" (domain-struct-name v)))])
    (define sname (domain-struct-name v))
    (define fields (domain-object-fields v))
    ;; worker-pool's identifying field is its queue name (field 1); everything
    ;; else carries its name in field 0.
    (define id (cond [(eq? sname 'worker-pool) (and (>= (length fields) 2) (list-ref fields 1))]
                     [(pair? fields) (car fields)]
                     [else #f]))
    (if id (format "~a ~a" sname id) (format "~a" sname))))

;; All live domain objects from the GLOBAL registry, as a flat list of specs.
;; This is the FULL live domain state — every queue / cache / SSE channel / email
;; outbox / worker pool the debuggee created, regardless of paused-frame locals.
(define (domain-registry-objects)
  (with-handlers ([exn:fail? (lambda (_) '())])
    (for/list ([e (in-list (domain-registry-entries))]
               #:when (domain-object? (cdr e)))
      (cdr e))))

;; Local helper: last element of a list, or #f for the empty list.
(define (last-of lst)
  (cond [(null? lst) #f]
        [(null? (cdr lst)) (car lst)]
        [else (last-of (cdr lst))]))
