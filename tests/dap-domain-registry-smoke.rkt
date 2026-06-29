#lang racket

;; dap-domain-registry-smoke.rkt — proves the FULL-LIVE-DOMAIN-STATE fix.
;;
;; THE FIX UNDER TEST
;; ------------------
;; Before this change the DAP "Domain" scope could only show domain objects that
;; happened to be in the PAUSED FRAME'S LOCALS.  Queues, caches, SSE channels, the
;; email outbox and worker pools are created at the TOP LEVEL of an emitted program
;; (never as locals of an arbitrary helper), so pausing inside a function that does
;; NOT take them as parameters showed an empty Domain scope.
;;
;; The fix: each define-queue / define-cache / define-channel / define-email and
;; start-workers! / start-dead-workers! now registers its LIVE spec in a global,
;; dependency-free registry (dsl/private/domain-registry.rkt).  The DAP server reads
;; that registry (in addition to locals) when building the Domain scope, because the
;; debuggee is loaded IN-PROCESS (dynamic-require, same Racket namespace), so the
;; registry it populates at module-instantiation time is the SAME module instance.
;;
;; WHAT THIS TEST DOES
;; -------------------
;; It reproduces exactly that scenario WITHOUT a flaky subprocess/protocol session
;; or a live database:
;;   1. Creates a queue + cache + SSE channel + email + workers via the REAL DSL
;;      macros at module top level (so they register into the REAL global registry),
;;      just as the emitted lesson .rkt would.  None of them is passed as a param to
;;      `probe` below — they are pure module-level definitions.
;;   2. Populates their LIVE in-memory state (pending jobs, cache entries, CONNECTED
;;      SSE clients in the listeners hash, outbox emails) exactly as the runtime
;;      would, and starts real worker threads.
;;   3. Calls `probe` — a function that takes NO domain objects — and, while
;;      "paused" there (its locals contain none of the domain objects), builds the
;;      Domain scope the SAME way dap-server's `domain->variables` does, using the
;;      REAL shared rendering module dsl/debug/domain-inspect.rkt.
;;   4. Asserts the Domain scope lists the queue / cache / SSE-channel (+ connected
;;      client count) / email outbox / worker pool, each with its live counts.

(require rackunit
         racket/string
         "../tesl/queue.rkt"
         "../tesl/cache.rkt"
         "../tesl/email.rkt"
         (only-in "../dsl/capability.rkt" define-capability)
         (only-in "../dsl/private/domain-registry.rkt"
                  domain-registry-clear!
                  domain-registry-entries)
         (only-in "../dsl/debug/domain-inspect.rkt"
                  domain-object?
                  domain-struct-name
                  domain-object-summary
                  registry-object-label
                  domain-registry-objects))

;; Start from a clean registry so this test is independent of load order.
(domain-registry-clear!)

;; ── 1. TOP-LEVEL domain definitions (exactly as an emitted program would) ───────
;;    These are NOT parameters of `probe`; they register into the global registry
;;    at module-instantiation time.

(define-queue SmokeJobs
  #:job-types (SmokeJob)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 5)

(define-capability cacheCap_SmokeCache)
(define-cache SmokeCache #:default-ttl 60)

(define-channel SmokeUpdates)

(define-email SmokeMailer
  #:smtp-host "localhost"
  #:smtp-port 25
  #:smtp-username "noreply@example.com"
  #:smtp-password "secret"
  #:smtp-tls #f)

;; ── 2. Populate LIVE in-memory state, just as the runtime would ─────────────────

;; Two pending jobs in the queue store (in-memory fallback: id → entry-hash).
(hash-set! (queue-spec-store SmokeJobs) "job-1"
           (hash 'payload (hash) 'status 'pending 'attempts 0))
(hash-set! (queue-spec-store SmokeJobs) "job-2"
           (hash 'payload (hash) 'status 'pending 'attempts 0))

;; Three cache entries (in-memory fallback: key → (vector value expires-at)).
(hash-set! (cache-spec-store SmokeCache) "k1" (vector "v1" #f))
(hash-set! (cache-spec-store SmokeCache) "k2" (vector "v2" #f))
(hash-set! (cache-spec-store SmokeCache) "k3" (vector "v3" #f))

;; Two CONNECTED SSE clients on channel key "room-1" plus one on "room-2".  Each
;; callback in the listeners hash is one connected EventSource client — this is
;; precisely what make-sse-connection-handler registers on connect.
(hash-set! (channel-spec-listeners SmokeUpdates) "room-1"
           (list (lambda (e) (void)) (lambda (e) (void))))
(hash-set! (channel-spec-listeners SmokeUpdates) "room-2"
           (list (lambda (e) (void))))

;; Outbox: 1 pending, 2 sent, 1 dead.
(set-box! (email-spec-store SmokeMailer)
          (list (hash 'to "a@x" 'subject "s" 'status 'pending)
                (hash 'to "b@x" 'subject "s" 'status 'sent)
                (hash 'to "c@x" 'subject "s" 'status 'sent)
                (hash 'to "d@x" 'subject "s" 'status 'dead)))

;; Start real worker threads (concurrency 2) — registers a worker-pool.  No DB
;; runtime is active, so this is the in-memory path; the threads sit idle on the
;; queue semaphore, which is exactly what we want to inspect as "live".
(start-workers! (list (cons SmokeJobs (lambda (job) job)))
                '()
                #:concurrency 2)

;; ── 3. The "paused frame": a function with NO domain objects in scope ───────────

;; `probe` takes only plain values.  Its locals never contain SmokeJobs/SmokeCache/
;; SmokeUpdates/SmokeMailer or the worker pool — mirroring a breakpoint inside a
;; pure helper.  We capture its locals as the dap-server would (name . value pairs).
(define (probe a b)
  (define sum (+ a b))
  ;; locals here = ((a . 1) (b . 2) (sum . 3)) — zero domain objects.
  (list (cons 'a a) (cons 'b b) (cons 'sum sum)))

(define paused-locals (probe 1 2))

;; Build the Domain-scope variable list the SAME way dap-server's domain->variables
;; does: locals' domain objects (none here) ∪ the global registry, de-duped by eq?.
;; We reuse the REAL shared rendering helpers from domain-inspect.rkt.
(define (domain-locals locals)
  (filter (lambda (p) (and (pair? p) (domain-object? (cdr p)))) locals))

(define (domain-scope-variables locals)
  (define local-objs (domain-locals locals))
  (define local-specs (map cdr local-objs))
  (append
   (map (lambda (p) (cons (symbol->string (car p)) (cdr p))) local-objs)
   (filter-map
    (lambda (spec)
      (and (not (memq spec local-specs))
           (cons (registry-object-label spec) spec)))
    (domain-registry-objects))))

(define DOMAIN-SCOPE (domain-scope-variables paused-locals))

;; Convenience: the (label . summary-string) view of the Domain scope.
(define DOMAIN-SUMMARIES
  (map (lambda (e) (cons (car e) (domain-object-summary (cdr e)))) DOMAIN-SCOPE))

(define (summary-for kind)
  ;; Find the summary whose object's struct name is `kind`.
  (for/or ([e (in-list DOMAIN-SCOPE)])
    (and (eq? (domain-struct-name (cdr e)) kind)
         (domain-object-summary (cdr e)))))

;; ── 4. Assertions ───────────────────────────────────────────────────────────────

(test-case "paused frame has NO domain objects in its locals (the old limitation)"
  (check-equal? (domain-locals paused-locals) '()
                "probe's locals must contain zero domain objects"))

(test-case "Domain scope is non-empty even though no local binds a domain object"
  (check-true (pair? DOMAIN-SCOPE)
              "the global registry must surface the domain objects"))

(test-case "Domain scope lists the QUEUE with its pending-job count"
  (define s (summary-for 'queue-spec))
  (check-true (and s (string-contains? s "Queue")) "queue listed")
  (check-true (and s (string-contains? s "SmokeJobs")) "queue named")
  (check-true (and s (string-contains? s "2 pending")) "live pending count"))

(test-case "Domain scope lists the CACHE with its entry count"
  (define s (summary-for 'cache-spec))
  (check-true (and s (string-contains? s "Cache")) "cache listed")
  (check-true (and s (string-contains? s "SmokeCache")) "cache named")
  (check-true (and s (string-contains? s "3 entries")) "live entry count"))

(test-case "Domain scope lists the SSE CHANNEL with its CONNECTED-CLIENT count"
  (define s (summary-for 'channel-spec))
  (check-true (and s (string-contains? s "SSE Channel")) "SSE channel listed")
  (check-true (and s (string-contains? s "SmokeUpdates")) "channel named")
  ;; 2 clients on room-1 + 1 on room-2 = 3 connected clients.
  (check-true (and s (string-contains? s "3 connected client")) "live connected-client count"))

(test-case "Domain scope lists the EMAIL OUTBOX with pending/sent/dead counts"
  (define s (summary-for 'email-spec))
  (check-true (and s (string-contains? s "Email")) "email listed")
  (check-true (and s (string-contains? s "SmokeMailer")) "email named")
  (check-true (and s (string-contains? s "1 pending")) "pending count")
  (check-true (and s (string-contains? s "2 sent")) "sent count")
  (check-true (and s (string-contains? s "1 dead")) "dead count"))

(test-case "Domain scope lists the WORKER POOL with concurrency + live threads"
  (define s (summary-for 'worker-pool))
  (check-true (and s (string-contains? s "Workers")) "worker pool listed")
  (check-true (and s (string-contains? s "SmokeJobs")) "drained queue named")
  (check-true (and s (string-contains? s "concurrency 2")) "concurrency surfaced")
  ;; 2 worker threads were just spawned and are alive on the semaphore.
  (check-true (and s (string-contains? s "2 live")) "live thread count")
  (check-true (and s (string-contains? s "running")) "status running"))

(test-case "every Domain-scope entry is a recognised domain object"
  (for ([e (in-list DOMAIN-SCOPE)])
    (check-true (domain-object? (cdr e))
                (format "entry ~a is a domain object" (car e)))))

(test-case "all five domain kinds are present exactly once (no duplicates)"
  (define kinds (map (lambda (e) (domain-struct-name (cdr e))) DOMAIN-SCOPE))
  (for ([k '(queue-spec cache-spec channel-spec email-spec worker-pool)])
    (check-equal? (length (filter (lambda (x) (eq? x k)) kinds)) 1
                  (format "exactly one ~a" k))))

;; Print the surfaced Domain scope for human eyeballing when run directly.
(module+ main
  (printf "\n=== Domain scope surfaced from the GLOBAL registry ===\n")
  (for ([e (in-list DOMAIN-SUMMARIES)])
    (printf "  ~a\n      → ~a\n" (car e) (cdr e))))
