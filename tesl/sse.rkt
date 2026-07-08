#lang racket

;;; Server-Sent Events (SSE) support for Tesl.
;;;
;;; SSE replaces the WebSocket server: events flow server→client over standard
;;; HTTP, on the SAME port as the API server.  No nginx WebSocket proxy config
;;; or separate port is needed.  Clients use the browser's native EventSource API.
;;;
;;; Protocol:
;;;   Content-Type: text/event-stream
;;;   Each event:   data: <json>\n\n
;;;   Heartbeat:    : heartbeat\n\n   (keeps connection alive through proxies)
;;;
;;; This module provides make-sse-connection-handler, which returns a procedure
;;; (output-port? -> void?) suitable for response/output.

(require "queue.rkt"
         (only-in "../dsl/types.rkt" runtime-value->jsexpr)
         (only-in "../tesl/logging.rkt" tesl-log-active? tesl-log!)
         (only-in "../dsl/metrics.rkt"
                  metrics-active? metric-counter-add! metric-gauge-set!)
         json
         racket/async-channel
         racket/format)

(provide make-sse-connection-handler)

;; ── Listener registry bookkeeping (issue #32) ─────────────────────────────────
;;
;; channel-spec-listeners is a mutable hash (key → (listof callback)).
;; Register/unregister are read-modify-write (hash-ref + cons/remove +
;; hash-set!) — NOT atomic on a mutable hash, so two concurrent connects on the
;; same key could silently drop one listener.  All registry mutations go
;; through this lock.  Delivery (call-in-memory-listeners in queue.rkt) only
;; hash-refs an immutable list snapshot, which IS atomic, so it takes no lock.
;;
;; KILL-SAFETY: the lock is only ever taken by the per-connection janitor
;; threads below, which live under the module-level custodian and are never
;; killed mid-operation.  It must NOT be taken from a connection thread — the
;; web server kills those at arbitrary points (custodian shutdown on client
;; disconnect / response-send-timeout), and a kill landing inside the critical
;; section would strand the lock and freeze the registry forever.
(define listeners-lock (make-semaphore 1))

(define (register-listener! listeners channel-key cb)
  (call-with-semaphore listeners-lock
    (lambda ()
      (hash-set! listeners channel-key
                 (cons cb (hash-ref listeners channel-key '()))))))

;; Idempotent: `remove` drops one occurrence of cb if present and no-ops
;; otherwise.  When the key's listener list becomes empty the key itself is
;; dropped, so a churn of one-off channel keys does not leak hash entries.
(define (unregister-listener! listeners channel-key cb)
  (call-with-semaphore listeners-lock
    (lambda ()
      (define remaining (remove cb (hash-ref listeners channel-key '())))
      (if (null? remaining)
          (hash-remove! listeners channel-key)
          (hash-set! listeners channel-key remaining)))))

;; Custodian for the per-connection janitor threads.  Created at module
;; instantiation (server startup), so it is a child of the SERVER custodian —
;; never of a per-connection custodian.  The web server tears an SSE connection
;; down by shutting down the connection custodian; that KILLS the handler
;; thread without running its dynamic-wind post-thunks, which is exactly how
;; listeners leaked before (issue #32: 109 stale listeners on one channel key
;; after a day of dev, each costing publish up to 1 s).  Janitor threads must
;; therefore live outside the connection custodian, or they would die together
;; with the very thread they are watching.
(define sse-janitor-custodian (make-custodian))

;; ── Metrics ───────────────────────────────────────────────────────────────────
;;
;; Active-connection gauge, maintained at the SAME two janitor-thread points
;; that own registry membership (register at connect, unregister on every exit
;; path incl. custodian kill), so the gauge cannot drift from the registry.
;; Labeled by channel NAME only — channel keys are often per-user/per-entity
;; values and would explode metric cardinality.
;;
;; The COUNT is updated UNCONDITIONALLY — it mirrors registry membership, which
;; exists whether or not metrics are on.  Gating the count on metrics-active?
;; would let connects/disconnects during a metrics-off window permanently skew
;; the gauge after re-enabling.  Only the gauge EMISSION is gated (inside
;; metric-gauge-set! itself).  The gauge write happens INSIDE the lock so two
;; concurrent register/unregister events cannot publish out of order and leave
;; a stale value.  Lock order: sse-metrics-lock → the metrics registry's atomic
;; section; the registry never takes this lock, so no deadlock.  Kill-safety:
;; both callers run on janitor threads, which are never killed mid-operation
;; (see listeners-lock above).
(define sse-metrics-lock (make-semaphore 1))
(define sse-active-counts (make-hash))

(define (bump-sse-active! channel-name delta)
  (call-with-semaphore sse-metrics-lock
    (lambda ()
      (define new (max 0 (+ (hash-ref sse-active-counts channel-name 0) delta)))
      (hash-set! sse-active-counts channel-name new)
      (when (metrics-active?)
        (metric-gauge-set! "tesl.sse.connections.active" new
                           (list (cons "tesl.channel" (~a channel-name))))))))

;; How many undelivered events one SSE connection may buffer before further
;; events for it are dropped.  See on-event below for the slow-vs-dead
;; consumer semantics this bound implements.
(define SSE-EVENT-BUFFER-LIMIT 64)

;; Returns a procedure (output-port? -> void?) that:
;;   1. Registers a listener on channel-spec for the given key.
;;   2. Streams SSE events until the client disconnects.
;;   3. Sends a : heartbeat comment every 10 s to keep the connection alive.
;;   4. Removes the listener on EVERY exit path — orderly loop exit (write
;;      failure), escaping exception/break, AND thread kill via custodian
;;      shutdown — through the kill-safe janitor thread.
(define (make-sse-connection-handler channel-spec channel-key)
  (lambda (out)
    ;; Bounded per-connection event buffer (issue #32).  Previously this was a
    ;; rendezvous channel and the listener callback did
    ;; (sync/timeout 1 (channel-put-evt ...)): every event published to a
    ;; connection not already parked in sync cost the PUBLISHER up to 1 s, and
    ;; a dead-but-still-registered connection cost 1 s on every publish.
    ;; publish usually runs inside a request handler, so N stale listeners made
    ;; unrelated requests hang ~N seconds (issue #32: >60 s chat turns).
    (define event-ch (make-async-channel SSE-EVENT-BUFFER-LIMIT))

    ;; Listener callback — must NEVER block the publisher (issue #32).
    ;; (sync/timeout 0 (async-channel-put-evt ...)) enqueues when the buffer
    ;; has room and returns immediately either way (#f = buffer full → drop).
    ;;
    ;; Slow-vs-dead semantics: the old 1-second grace existed so a LIVE
    ;; consumer momentarily mid-write would not lose events.  The bounded
    ;; buffer preserves that more generously — a slow consumer now has
    ;; SSE-EVENT-BUFFER-LIMIT queued events of grace instead of "whatever it
    ;; can drain within 1 s while the publisher stalls".  Events are dropped
    ;; only once a consumer falls a whole buffer behind — a state in which the
    ;; old code also dropped (after first blocking the publisher for 1 s per
    ;; event).  So no live consumer receives fewer events than before, and the
    ;; publisher's cost per listener is O(1) instead of up to 1 s.
    (define (on-event evt)
      (unless (sync/timeout 0 (async-channel-put-evt event-ch evt))
        ;; Buffer full → the event was silently dropped for this consumer.
        ;; Count it: a rising dropped counter is the observable symptom of a
        ;; consumer stuck a whole buffer behind.  O(1), never raises, so the
        ;; publisher-must-never-block contract above still holds.
        (when (metrics-active?)
          (metric-counter-add! "tesl.sse.events.dropped" 1
                               (list (cons "tesl.channel"
                                           (~a (channel-spec-name channel-spec))))))))

    (define listeners  (channel-spec-listeners channel-spec))
    ;; registered — posted by the janitor once the listener is in the registry;
    ;; the connection thread waits for it before streaming, so a client that
    ;; sees onopen is guaranteed to be subscribed.
    ;; done — posted by the dynamic-wind post-thunk on orderly exit, so the
    ;; janitor cleans up promptly instead of waiting for the connection thread
    ;; itself to die.
    (define registered (make-semaphore 0))
    (define done       (make-semaphore 0))
    (define conn-thread (current-thread))

    ;; Janitor thread (issue #32): owns this connection's registry mutations.
    ;; It registers the listener, then waits for either orderly completion
    ;; (`done`, posted by the post-thunk) or the connection thread dying for
    ;; ANY reason (kill-thread via custodian shutdown runs no post-thunks —
    ;; the exit path the old in-line cleanup missed), then unregisters.
    ;; Runs under the module-level custodian so it survives the connection
    ;; custodian; see listeners-lock above for why the mutations must happen
    ;; here and not on the (killable) connection thread.
    (parameterize ([current-custodian sse-janitor-custodian])
      (thread
       (lambda ()
         (register-listener! listeners channel-key on-event)
         (bump-sse-active! (channel-spec-name channel-spec) 1)
         (semaphore-post registered)
         (sync (thread-dead-evt conn-thread) done)
         (unregister-listener! listeners channel-key on-event)
         (bump-sse-active! (channel-spec-name channel-spec) -1)
         (when (tesl-log-active?)
           (tesl-log! "SSE" (format "disconnect ~a(~a)"
                                     (channel-spec-name channel-spec)
                                     channel-key))))))

    ;; Wait for registration.  If this thread is killed while waiting, the
    ;; janitor still proceeds: it observes thread-dead-evt and unregisters.
    (semaphore-wait registered)

    (when (tesl-log-active?)
      (tesl-log! "SSE" (format "connect ~a(~a)"
                                (channel-spec-name channel-spec) channel-key)))

    (dynamic-wind
     void
     (lambda ()
       ;; Send an immediate comment so the browser fires onopen without waiting
       ;; for the first heartbeat timeout.  With HTTP chunked encoding (the default
       ;; when connection-close? is #f) the browser only fires onopen after
       ;; receiving the first body chunk; this ensures that happens instantly.
       (with-handlers ([exn? void])
         (write-bytes #": ok\n\n" out)
         (flush-output out))

       ;; SSE event loop.  Ends when a write fails (client disconnect).
       (let loop ()
         (define evt (sync/timeout 10 event-ch))
         (define ok?
           (with-handlers ([exn? (lambda (_) #f)])
             (cond
               ;; Timeout → send heartbeat comment (browsers need this to detect drops)
               [(not evt)
                (write-bytes #": heartbeat\n\n" out)
                (flush-output out)
                #t]
               ;; Real event → encode as SSE data line
               [else
                (define payload (runtime-value->jsexpr evt))
                (define json-str
                  (jsexpr->string
                   (hash 'channel (symbol->string (channel-spec-name channel-spec))
                         'payload payload)))
                (write-bytes (string->bytes/utf-8 (format "data: ~a\n\n" json-str)) out)
                (flush-output out)
                (when (metrics-active?)
                  (metric-counter-add! "tesl.sse.events.sent" 1
                                       (list (cons "tesl.channel"
                                                   (~a (channel-spec-name channel-spec))))))
                #t])))
         (when ok? (loop))))
     (lambda ()
       ;; Orderly exits (loop end on write failure, escaping exception/break):
       ;; wake the janitor, which removes the listener.  semaphore-post is a
       ;; single atomic step, safe even on this killable thread; if a kill
       ;; lands before it, thread-dead-evt wakes the janitor instead.
       (semaphore-post done)))))
