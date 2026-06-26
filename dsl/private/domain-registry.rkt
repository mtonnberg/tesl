#lang racket/base

;;; domain-registry.rkt — a global, process-wide registry of the live domain
;;; runtime objects created by the Tesl DSL macros.
;;;
;;; WHY THIS MODULE EXISTS
;;; ----------------------
;;; Domain specs (queues, caches, SSE channels, email outboxes) and worker pools
;;; are created by `define-queue` / `define-cache` / `define-channel` /
;;; `define-email` / `start-workers!` at the TOP LEVEL of an emitted program —
;;; they are bound to module-level identifiers, never stored in any shared place.
;;; The DAP debugger could therefore only see the ones that happened to be in the
;;; paused frame's *locals*.  This registry gives every such object a second,
;;; always-reachable home so the debugger (which loads the debuggee in-process via
;;; dynamic-require, into THIS same Racket runtime/namespace) can enumerate the
;;; FULL live domain state when paused.
;;;
;;; NO IMPORT CYCLE — BY CONSTRUCTION
;;; --------------------------------
;;; This module requires NOTHING from queue/cache/email/sse/web.  The dependency
;;; edges all point INTO this module:
;;;     queue.rkt   ──require──▶ domain-registry.rkt
;;;     cache.rkt   ──require──▶ domain-registry.rkt
;;;     email.rkt   ──require──▶ domain-registry.rkt
;;;     dap-server  ──require──▶ domain-registry.rkt   (read-only)
;;; Because the registry stores specs as OPAQUE values (it never inspects their
;;; struct types — that is the debugger's job, done via generic struct->vector
;;; introspection), it needs zero knowledge of the spec struct definitions, so it
;;; can sit below them in the module graph with no back-edge.  Hence no cycle.
;;;
;;; PURITY / ZERO RUNTIME-BEHAVIOUR CHANGE
;;; --------------------------------------
;;; The only effect of registration is appending an (eq?-deduped) entry to a
;;; private box.  Nothing reads the registry during normal (non-debug) execution,
;;; and the macros' EXPANSION shape is unaffected at the emitted-.rkt level (the
;;; emitter only CALLS the macros), so program behaviour and the byte-exact emit
;;; are both unchanged.

(provide domain-registry-add!
         domain-registry-entries        ; -> (listof (cons kind spec))
         domain-registry-of-kind         ; kind -> (listof spec)
         domain-registry-kinds           ; the recognised kind symbols
         domain-registry-clear!          ; tests only
         ;; ── Background-thread tracking (DAP "stop-the-world", task #42) ──────
         register-background-thread!     ; thread -> thread  (registers + returns it)
         background-threads              ; -> (listof thread)  every registered bg thread
         ;; ── SQL transparency capture (DAP "SQL" scope, task #43) ─────────────
         sql-capture-pending!            ; sql params table op -> void (before exec)
         sql-capture-executed!           ; row-count -> void       (after exec, same thread)
         sql-capture-for-thread          ; thread -> capture-hash or #f
         current-sql-capture             ; -> capture-hash or #f   (calling thread)
         most-recent-sql-capture         ; -> capture-hash or #f   (any thread, newest)
         sql-capture-clear!)             ; tests only

;; The set of kinds we register.  Kept as data (not an enum) so adding a new kind
;; needs no change here — but documenting the expected set aids the reader.
;;   'queues   — queue-spec    (define-queue)
;;   'caches   — cache-spec    (define-cache)
;;   'channels — channel-spec  (define-channel)         ← holds connected SSE clients
;;   'emails   — email-spec    (define-email)           ← the outbox
;;   'workers  — worker-pool   (start-workers!/start-dead-workers!)
;;   'threads  — thread        (EVERY Tesl-spawned background thread, see below)
(define domain-registry-kinds '(queues caches channels emails workers threads))

;; A private, process-wide list of (cons kind spec).  A box of a list keeps the
;; mutation trivially atomic-enough for our use: registration happens at module
;; instantiation / start-workers! time, which is single-threaded relative to the
;; reads that the debugger performs only while the program is PAUSED.
(define registry (box '()))

;; Register a live domain object under `kind`.  De-duplicates by eq? so that a
;; spec re-registered (e.g. start-workers! called twice on the same pool object,
;; or a module re-instantiated) is not listed twice.  Never raises and returns
;; (void) so it composes cleanly inside a `begin`/macro expansion.
(define (domain-registry-add! kind spec)
  (define cur (unbox registry))
  (unless (for/or ([e (in-list cur)])
            (and (eq? (car e) kind) (eq? (cdr e) spec)))
    (set-box! registry (append cur (list (cons kind spec))))))

;; All entries, in registration order, as (cons kind spec).
(define (domain-registry-entries)
  (unbox registry))

;; Just the specs registered under one kind, in registration order.
(define (domain-registry-of-kind kind)
  (for/list ([e (in-list (unbox registry))]
             #:when (eq? (car e) kind))
    (cdr e)))

;; Drop everything.  Intended for tests that want a clean slate; normal programs
;; never call this.
(define (domain-registry-clear!)
  (set-box! registry '()))

;; ── Background-thread tracking (DAP "stop-the-world", task #42) ────────────────
;;
;; Every long-lived background thread the Tesl runtime spawns (queue workers +
;; pollers + LISTEN threads, dead-letter pollers, pub/sub sweep/LISTEN threads, the
;; email delivery + cleanup threads, the cache TTL sweeper, …) registers its thread
;; descriptor here under the 'threads kind.  Some of those handles are ALSO captured
;; inside a worker-pool's `threads` box, but most were previously fire-and-forget and
;; thus invisible to the debugger.  Registering them all gives the DAP server one
;; authoritative place to enumerate EVERY Tesl background thread so it can freeze
;; them on a breakpoint stop (and resume them on continue/step).
;;
;; CRITICAL EXCLUSION — by construction: this registry is populated ONLY by the
;; Tesl runtime's own spawn sites.  The DAP adapter's threads (its stdio server loop,
;; the checkpoint event pump, the debuggee runner, the resume helper) are NOT Tesl
;; background threads and never call this, so registry-driven suspension can never
;; freeze the thread that must service `continue`.
;;
;; Registration is DEBUG-GATED here (one place), mirroring the checkpoint TESL_DEBUG
;; gate: only a debug session (TESL_DEBUG ∈ {1,true,yes,on}) records thread handles,
;; so a release run accumulates nothing.  The flag is read PER CALL (one getenv per
;; spawned thread) rather than once at module load, because the DAP server sets
;; TESL_DEBUG via putenv at LAUNCH time — AFTER this module is already required — so a
;; load-time snapshot would miss it.  Spawning happens at worker-startup (not per
;; operation), so a per-spawn getenv is negligible.  This module otherwise stays
;; policy-free: it just records whatever it is handed.  Returns the thread so a call
;; site can write `(register-background-thread! (thread …))` inline.
(define (tesl-debug?)
  (let ([v (getenv "TESL_DEBUG")])
    (and v (and (member (string-downcase v) '("1" "true" "yes" "on")) #t))))

(define (register-background-thread! t)
  (when (and (thread? t) (tesl-debug?))
    (domain-registry-add! 'threads t))
  t)

;; Every registered background thread, in registration order.  (Threads that have
;; since terminated are still listed; callers filter on thread-running? as needed.)
(define (background-threads)
  (domain-registry-of-kind 'threads))

;; ── SQL transparency capture (DAP "SQL" scope, task #43) ───────────────────────
;;
;; When paused on/at a SQL statement, the DAP server shows EXACTLY what the driver
;; runs — the parameterized text ($1,$2…), the ordered bound params and the
;; post-exec row count — instead of "SQL magic".  The DSL's SQL layer (dsl/sql.rkt)
;; calls `sql-capture-pending!` just before handing the parameterized statement to
;; db-lib, then `sql-capture-executed!` with the row count once the query returns.
;;
;; PER-THREAD, NEVER-CLOBBERING:  the capture is keyed by the thread that ran the
;; query (a thread-keyed hash), so the program thread and any frozen worker thread
;; each keep their own "last + pending" SQL — concurrent queries never overwrite
;; one another.  The DAP server reads the PAUSED thread's capture (with a global
;; most-recent fallback) while the debuggee is parked at the checkpoint.
;;
;; DEBUG-GATED — ZERO RELEASE COST:  capture is a no-op unless TESL_DEBUG ∈
;; {1,true,yes,on}, mirroring `register-background-thread!` and the checkpoint
;; gate.  The flag is read PER CALL (the DAP server sets TESL_DEBUG via putenv at
;; launch, AFTER this module is required, so a load-time snapshot would miss it);
;; the cost in a release run is exactly one getenv guard that short-circuits.  Even
;; that guard only runs because dsl/sql.rkt itself wraps the calls in the same
;; existing `tesl-verbose?`-style gate, so a non-debug program does no extra work.
;;
;; FAIL-OPEN:  every entry point swallows its own errors and returns (void)/#f, so
;; a capture failure can never crash the debuggee or the adapter.

;; thread -> capture-hash.  A capture-hash has keys:
;;   'sql        (string, parameterized — $1,$2…)
;;   'params     (list, ordered, raw runtime db-values)
;;   'table      (string-or-#f)
;;   'op         (symbol, e.g. 'select-many / 'insert-one!)
;;   'status     ('pending | 'executed)
;;   'row-count  (exact-nonnegative-integer or #f when pending/unknown)
;;   'seq        (monotonically increasing — lets the DAP pick the newest across threads)
(define sql-captures (make-hasheq))   ; weak not needed: bounded by live thread count
(define sql-capture-seq (box 0))

(define (sql-capture-enabled?) (tesl-debug?))

;; Record a statement about to be executed BY THE CALLING THREAD.  Replaces that
;; thread's previous capture (the "last" becomes the new "pending").
(define (sql-capture-pending! sql params table op)
  (when (sql-capture-enabled?)
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
      (define n (add1 (unbox sql-capture-seq)))
      (set-box! sql-capture-seq n)
      (hash-set! sql-captures (current-thread)
                 (hasheq 'sql       (if (string? sql) sql (format "~a" sql))
                         'params    (if (list? params) params (list params))
                         'table     (and (string? table) table)
                         'op        op
                         'status    'pending
                         'row-count #f
                         'seq       n))))
  (void))

;; Mark the calling thread's pending capture as executed, attaching the row count.
;; A no-op (beyond the gate) if there is no pending capture for this thread.
(define (sql-capture-executed! row-count)
  (when (sql-capture-enabled?)
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
      (define cur (hash-ref sql-captures (current-thread) #f))
      (when (hash? cur)
        (hash-set! sql-captures (current-thread)
                   (hash-set* cur
                              'status 'executed
                              'row-count (and (exact-nonnegative-integer? row-count) row-count))))))
  (void))

;; The capture for a specific thread (or #f).  Used by the DAP server for the
;; PAUSED thread.
(define (sql-capture-for-thread t)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (and (thread? t) (hash-ref sql-captures t #f))))

;; The calling thread's own capture (or #f).
(define (current-sql-capture)
  (sql-capture-for-thread (current-thread)))

;; The single most-recently-recorded capture across ALL threads (or #f) — the DAP
;; server's fallback when the paused thread itself ran no SQL but a now-frozen
;; worker did just before the stop.
(define (most-recent-sql-capture)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (for/fold ([best #f]) ([(_t c) (in-hash sql-captures)])
      (cond
        [(not (hash? c)) best]
        [(or (not best) (> (hash-ref c 'seq 0) (hash-ref best 'seq 0))) c]
        [else best]))))

;; Drop all captures.  Tests only; normal programs never call this.
(define (sql-capture-clear!)
  (set-box! sql-capture-seq 0)
  (hash-clear! sql-captures))
