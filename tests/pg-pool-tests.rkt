#lang racket

;; Connection-pool lease regression tests (GitHub issue #31).
;;
;; The bug: Racket's `connection-pool-lease` raises "connection pool limit
;; reached" IMMEDIATELY when every slot is leased, so ~4 concurrent GETs + one
;; SSE stream from a single page intermittently 500'd on the default 10-slot
;; pool.  The fix leases through `make-pool-lease-connector` (dsl/sql.rkt),
;; which waits — bounded — for a freed connection and raises the
;; distinguishable `exn:fail:tesl:pool-timeout` only after the wait expires;
;; dsl/web.rkt maps that exception to 503 instead of the generic 500.
;;
;; These tests need NO live PostgreSQL: `connection-pool` never inspects the
;; connections its connector produces beyond the `connection<%>` interface
;; (`connected?` / `transaction-status` / `disconnect` on release), so a fake
;; connection object exercises the full lease/wait/release lifecycle.  The
;; `connection<%>` interface itself is only exported from the db collection's
;; private layer — an accepted test-only dependency (the connector's result is
;; contract-checked with `connection?`, so a plain object% fake is rejected).

(require db
         racket/class
         rackunit
         (only-in db/private/generic/interfaces connection<%>)
         (only-in "../dsl/sql.rkt"
                  make-pool-lease-connector
                  exn:fail:tesl:pool-timeout
                  exn:fail:tesl:pool-timeout?)
         "../dsl/web.rkt")

;; ── Fake connection ──────────────────────────────────────────────────────────

(define fake-connection%
  (class* object% (connection<%>)
    (super-new)
    (define alive? #t)
    (define/public (connected?) alive?)
    (define/public (disconnect) (set! alive? #f))
    ;; #f = "not in a transaction" — the pool checks this on release to decide
    ;; whether the connection is reusable (idle) or must be discarded.
    (define/public (transaction-status fsym) #f)
    (define/public (get-base) this)
    (define/public (free-statement stmt need-lock?) (void))
    (define/public (list-tables fsym schema) '())
    (define/public (get-dbsystem) (error 'fake-connection "get-dbsystem: not implemented"))
    (define/public (query fsym stmt cursor?) (error 'fake-connection "query: not implemented"))
    (define/public (prepare fsym stmt close-on-exec?) (error 'fake-connection "prepare: not implemented"))
    (define/public (fetch/cursor fsym stmt fetch-size) (error 'fake-connection "fetch/cursor: not implemented"))
    (define/public (start-transaction fsym isolation option cwt?) (error 'fake-connection "start-transaction: not implemented"))
    (define/public (end-transaction fsym mode cwt?) (error 'fake-connection "end-transaction: not implemented"))))

;; Returns (values pool connect-count-thunk): a fresh
;; `#:max-connections size` pool over fake connections, plus a counter of how
;; many REAL connections were ever opened (reuse keeps it at the pool size).
(define (make-fake-pool size)
  (define connect-count 0)
  (define pool
    (connection-pool (lambda ()
                       (set! connect-count (add1 connect-count))
                       (new fake-connection%))
                     #:max-connections size))
  (values pool (lambda () connect-count)))

;; ── Lease waits for a freed slot instead of failing fast ────────────────────

(test-case "N+1th lease WAITS and succeeds when a connection is released"
  (define-values (pool connect-count) (make-fake-pool 2))
  (define lease (make-pool-lease-connector pool 'TestDB 2000))
  (define c1 (lease))
  (define c2 (lease))
  ;; Pool is exhausted.  A third lease from another thread must block — not
  ;; raise — and complete once c1 is released back to the pool.
  (define result-ch (make-channel))
  (define waiter
    (thread (lambda ()
              (channel-put result-ch
                           (with-handlers ([exn:fail:tesl:pool-timeout? (lambda (e) 'timed-out)])
                             (lease))))))
  (sleep 0.2)
  (check-pred thread-running? waiter "waiter must still be blocked while the pool is full")
  (disconnect c1) ;; releasing a leased proxy returns the slot to the pool
  (define leased (sync/timeout 5 result-ch))
  (check-pred connection? leased "waiter must receive a live connection after the release")
  (check-equal? (connect-count) 2
                "the freed underlying connection is REUSED — no third connect")
  (disconnect c2)
  (disconnect leased))

(test-case "exhausted pool raises exn:fail:tesl:pool-timeout after the bounded wait"
  (define-values (pool _connect-count) (make-fake-pool 1))
  (define lease (make-pool-lease-connector pool 'TestDB 300))
  (define held (lease))
  (define start (current-inexact-milliseconds))
  (check-exn exn:fail:tesl:pool-timeout?
             (lambda () (lease))
             "second lease on a 1-slot pool must raise the pool-timeout error")
  (check-true (>= (- (current-inexact-milliseconds) start) 250)
              "the failure must come AFTER the bounded wait, not immediately")
  ;; The message must name the database and the wait so operators can act on it.
  (with-handlers ([exn:fail:tesl:pool-timeout?
                   (lambda (e)
                     (check-regexp-match #rx"TestDB" (exn-message e))
                     (check-regexp-match #rx"pool lease timed out after 300ms" (exn-message e))
                     (check-regexp-match #rx"poolSize" (exn-message e)))])
    (lease)
    (fail "lease on an exhausted pool must not return"))
  (disconnect held))

;; ── virtual-connection integration (the production wiring) ──────────────────

(test-case "one thread holds ONE pooled connection — nested use re-uses it (no double lease)"
  ;; The nested-lease question from issue #31: a handler that queries twice
  ;; (or queries inside a query's continuation) must not lease two slots.
  ;; virtual-connection maps thread → actual connection, so the second use in
  ;; the same thread reuses the leased connection: a 1-slot pool suffices.
  (define-values (pool connect-count) (make-fake-pool 1))
  (define vconn (virtual-connection (make-pool-lease-connector pool 'TestDB 300)))
  (define first-use (send vconn get-base))
  (define second-use (send vconn get-base))
  (check-eq? first-use second-use "same thread must get the same leased connection")
  (check-equal? (connect-count) 1)
  (disconnect vconn))

(test-case "thread death releases the lease — a blocked waiter thread proceeds"
  ;; Mirrors a request handler finishing while another request waits: the web
  ;; server runs each request on its own thread, and virtual-connection
  ;; releases the thread's lease when the thread dies.
  (define-values (pool connect-count) (make-fake-pool 1))
  (define vconn (virtual-connection (make-pool-lease-connector pool 'TestDB 3000)))
  (define holder (thread (lambda ()
                           (send vconn get-base) ;; lease the only slot
                           (sleep 0.3))))
  (sleep 0.1)
  (define result-ch (make-channel))
  (thread (lambda ()
            (channel-put result-ch
                         (with-handlers ([exn:fail:tesl:pool-timeout? (lambda (e) 'timed-out)])
                           (send vconn get-base)
                           'leased))))
  (check-equal? (sync/timeout 5 result-ch) 'leased
                "waiter must lease once the holder thread dies")
  ;; No strict reuse assertion here: on thread death TWO release paths race
  ;; (the pool's own release-evt and virtual-connection's key expiration), and
  ;; one interleaving briefly empties the pool's proxy table before the freed
  ;; connection reaches the idle list — the waiter then opens a fresh
  ;; connection instead of reusing.  Benign (no slot is leaked; stock
  ;; `(virtual-connection pool)` wiring has the same race); the property that
  ;; matters is that the waiter LEASES rather than timing out.
  (check-true (<= (connect-count) 2))
  (void (sync holder))
  (disconnect vconn))

(test-case "explicit disconnect on the virtual connection releases the current thread's lease"
  ;; The SSE path (dsl/web.rkt) and idle queue workers (tesl/queue.rkt) release
  ;; their slot this way while their long-lived thread keeps running.
  (define-values (pool connect-count) (make-fake-pool 1))
  (define vconn (virtual-connection (make-pool-lease-connector pool 'TestDB 300)))
  (send vconn get-base)
  (disconnect vconn) ;; releases THIS thread's lease; vconn stays usable
  (define result-ch (make-channel))
  (thread (lambda ()
            (channel-put result-ch
                         (with-handlers ([exn:fail:tesl:pool-timeout? (lambda (e) 'timed-out)])
                           (send vconn get-base)
                           'leased))))
  (check-equal? (sync/timeout 5 result-ch) 'leased
                "another thread must lease immediately after the explicit release"))

;; ── HTTP mapping: pool timeout → 503, generic failure stays 500 ─────────────

(define-record PoolProbe
  [id : String])

(define-handler (pool-timeout-probe)
  #:returns PoolProbe
  (raise (exn:fail:tesl:pool-timeout
          "database 'TestDB': connection pool lease timed out after 10000ms"
          (current-continuation-marks))))

(define-handler (generic-failure-probe)
  #:returns PoolProbe
  (error 'generic-failure-probe "some unrelated handler crash"))

(define-api PoolProbeAPI
  [pool-timeout-probe :
    "pool-timeout"
    :> (Get JSON PoolProbe)]
  [generic-failure-probe :
    "generic-failure"
    :> (Get JSON PoolProbe)])

(define-server PoolProbeServer
  #:api PoolProbeAPI
  [pool-timeout-probe pool-timeout-probe]
  [generic-failure-probe generic-failure-probe])

(test-case "a pool-lease timeout surfaces as 503 Service Unavailable"
  (define response
    (dispatch-request PoolProbeServer (make-request 'GET '("pool-timeout"))))
  (check-equal? (dsl-response-status response) 503))

(test-case "a generic handler failure still surfaces as 500"
  (define response
    (dispatch-request PoolProbeServer (make-request 'GET '("generic-failure"))))
  (check-equal? (dsl-response-status response) 500))
