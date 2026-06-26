#!/usr/bin/env racket
#lang racket

;; headless-inspect.rkt — headless (non-interactive) breakpoint inspector for Tesl.
;;
;; AC2: run a compiled Tesl program to a single breakpoint, capture the runtime
;; state with STOP-THE-WORLD active, and emit it as one JSON object on stdout —
;; with NO DAP client and NO interactive protocol.  This is the engine behind the
;; `tesl debug-inspect <file.tesl> --break-at LINE[:COL] [--mode program|test]`
;; subcommand: main.ml compiles the .tesl with `--debug` (so the thsl-src!
;; checkpoints survive expansion) and shells `racket` on this driver with the
;; compiled .rkt + the ORIGINAL source path + the breakpoint line.
;;
;; Direct invocation (the documented wrapper form):
;;   racket dsl/debug/headless-inspect.rkt <compiled.rkt> <srcfile.tesl> <line> [mode]
;; where mode ∈ {program, test} (default program).
;;
;; DESIGN — mirrors dsl/debug/dap-server.rkt's launch+breakpoint+stop flow:
;;   • set TESL_DEBUG=1 so the debuggee's thsl-src! macros expand to real
;;     checkpoints (they are expansion-time gated — see checkpoint.rkt);
;;   • register ONE breakpoint at the requested source line in the SAME
;;     `breakpoints` table that checkpoint.rkt's thsl-src!/runtime consults;
;;   • load + run the debuggee IN-PROCESS in a thread (same namespace, so the
;;     global domain-registry the program populates is the one we read here);
;;   • the checkpoint runtime, on the first matching line, calls
;;     stop-the-world-suspend! (freezing every other Tesl background thread so
;;     the captured state is consistent), then puts a `stopped` event on
;;     event-ch and blocks on paused-ch;
;;   • we receive that FIRST stopped event, capture locals + the live domain
;;     registry + the current/most-recent SQL capture, emit the JSON, then
;;     resume the parked thread (which thaws the world) and exit 0.
;;
;; The JSON rendering REUSES the exact shared renderers the live debugger uses —
;; safe-display (checkpoint.rkt), the domain-inspect.rkt summaries/field readers,
;; and the SQL-capture readers — so the headless JSON matches what the DAP
;; Variables/Domain/SQL panels show.

(require racket/port
         json
         tesl/dsl/debug/checkpoint
         (only-in tesl/dsl/private/evidence
                  named-value? named-value-value
                  check-ok? check-ok-value)
         (only-in tesl/dsl/types
                  newtype-value? newtype-value-type-name newtype-value-value
                  record-value? record-value-type record-value-fields)
         (only-in tesl/dsl/private/domain-registry
                  sql-capture-for-thread
                  most-recent-sql-capture)
         (only-in db/base sql-null?)
         (only-in tesl/dsl/debug/domain-inspect
                  domain-struct-name
                  domain-object?
                  domain-object-summary
                  domain-object-fields
                  domain-field-names
                  channel-connected-count
                  worker-pool-live
                  email-outbox-counts
                  pending-job-count-of
                  registry-object-label
                  domain-registry-objects))

(provide headless-version
         infer-type-string
         locals->json
         domain->json
         sql->json
         build-result-json
         run-headless-inspect)

;; ── Version (bumped on JSON-shape changes) ──────────────────────────────────
(define headless-version 1)

;; ── Type inference (same logic as dap-server's infer-type-string) ───────────
;; A human-readable type string from a Tesl runtime value, GDP-unwrapped.
(define (infer-type-string v)
  (cond
    [(named-value? v)    (infer-type-string (named-value-value v))]
    [(check-ok? v)       (infer-type-string (check-ok-value v))]
    [(newtype-value? v)  (~a (newtype-value-type-name v))]
    [(record-value? v)   (~a (record-value-type v))]
    [(string? v)         "String"]
    [(integer? v)        "Int"]
    [(boolean? v)        "Bool"]
    [(list? v)           "List"]
    [(hash? v)           "Hash"]
    [else                ""]))

;; ── Locals → JSON ───────────────────────────────────────────────────────────
;; One {name, value, type} per user-visible local in the paused frame.  Uses the
;; SAME proof-unwrapping renderer (safe-display) as the DAP Variables panel, and
;; skips compiler-generated names ("_" and the tesl_ prefix) exactly as
;; dap-server's locals->variables does.
(define (locals->json locals)
  (filter-map
   (lambda (pair)
     (and (pair? pair)
          (symbol? (car pair))
          (let* ([name (symbol->string (car pair))]
                 [user? (and (not (string=? name "_"))
                             (not (string-prefix? name "tesl_")))]
                 [raw   (cdr pair)])
            (and user?
                 (hasheq 'name  name
                         'value (safe-display raw)
                         'type  (infer-type-string raw))))))
   locals))

;; ── Domain → JSON ─────────────────────────────────────────────────────────────
;; Render the FULL live domain state from the global registry (the same source
;; the DAP Domain scope reads), bucketed by kind.  Each entry carries its label,
;; one-line summary (via domain-object-summary), and a few cheap, recognised
;; counters so an agent gets the live numbers without a follow-up drill.  All
;; reads are fail-open — a render error on one object never aborts the dump.
(define (domain-object->json label v)
  (define base
    (hasheq 'label   label
            'kind    (~a (domain-struct-name v))
            'summary (domain-object-summary v)))
  (with-handlers ([exn:fail? (lambda (_e) base)])
    (define name   (domain-struct-name v))
    (define fields (domain-object-fields v))
    (define (field-ref idx) (and (> (length fields) idx) (list-ref fields idx)))
    (define extra
      (case name
        [(queue-spec)
         (hasheq 'name    (~a (field-ref 0))
                 'pending (or (pending-job-count-of (field-ref 2)) 0))]
        [(cache-spec)
         (let ([s (field-ref 4)])
           (hasheq 'name    (~a (field-ref 0))
                   'entries (if (hash? s) (hash-count s) 0)))]
        [(channel-spec)
         (hasheq 'name      (~a (field-ref 0))
                 'connected (channel-connected-count (field-ref 2)))]
        [(email-spec)
         (let-values ([(p s d) (email-outbox-counts (last fields))])
           (hasheq 'name (~a (field-ref 0))
                   'pending p 'sent s 'dead d))]
        [(worker-pool)
         (hasheq 'queue       (~a (field-ref 1))
                 'concurrency (field-ref 3)
                 'live        (worker-pool-live (field-ref 4)))]
        [else (hasheq)]))
    (for/fold ([h base]) ([(k val) (in-hash extra)])
      (hash-set h k val))))

;; Build the domain JSON object, bucketing the live registry objects by kind.
;; locals lets a domain object bound in the paused frame win a nicer label.
(define (domain->json locals)
  (define (domain-locals locs)
    (filter (lambda (p) (and (pair? p) (symbol? (car p)) (domain-object? (cdr p)))) locs))
  (define local-objs  (domain-locals locals))
  (define local-specs (map cdr local-objs))
  ;; (label . spec) for every live domain object: locals first (named), then the
  ;; rest of the registry (de-duped by eq?), exactly like dap-server.
  (define labelled
    (append
     (map (lambda (p) (cons (symbol->string (car p)) (cdr p))) local-objs)
     (filter-map
      (lambda (spec)
        (and (not (memq spec local-specs))
             (cons (registry-object-label spec) spec)))
      (domain-registry-objects))))
  (define (bucket kind)
    (filter-map
     (lambda (pair)
       (and (eq? (domain-struct-name (cdr pair)) kind)
            (domain-object->json (car pair) (cdr pair))))
     labelled))
  (hasheq 'queues  (bucket 'queue-spec)
          'caches  (bucket 'cache-spec)
          'sse     (bucket 'channel-spec)
          'email   (bucket 'email-spec)
          'workers (bucket 'worker-pool)))

;; ── SQL capture → JSON ──────────────────────────────────────────────────────
;; The current/most-recent SQL capture (task #43) as the parameterized statement
;; + ordered, typed params + a READ-ONLY inlined preview.  Never executed; the
;; DB always receives the parameterized form.  Returns #f when nothing ran.
(define (sql-param-type-tag v)
  (with-handlers ([(lambda (_) #t) (lambda (_) "Value")])
    (cond
      [(sql-null? v)       "Null"]
      [(boolean? v)        "Bool"]
      [(exact-integer? v)  "Int"]
      [(rational? v)       "Number"]
      [(string? v)         "String"]
      [(bytes? v)          "Bytes"]
      [else                "Value"])))

(define (sql-escape-literal v)
  (with-handlers ([(lambda (_) #t) (lambda (_) "?")])
    (cond
      [(sql-null? v)       "NULL"]
      [(boolean? v)        (if v "TRUE" "FALSE")]
      [(exact-integer? v)  (number->string v)]
      [(rational? v)       (number->string (exact->inexact v))]
      [(string? v)         (string-append "'" (string-replace v "'" "''") "'")]
      [(bytes? v)          (string-append "'" (string-replace (bytes->string/utf-8 v #\?) "'" "''") "'")]
      [else                (string-append "'" (string-replace (format "~a" v) "'" "''") "'")])))

(define (sql-inline-preview sql params)
  (with-handlers ([(lambda (_) #t) (lambda (_) sql)])
    (define indexed
      (sort (for/list ([p (in-list params)] [i (in-naturals 1)]) (cons i p))
            > #:key car))
    (for/fold ([s sql]) ([pair (in-list indexed)])
      (string-replace s (format "$~a" (car pair)) (sql-escape-literal (cdr pair))))))

(define (sql->json cap)
  (and cap
       (with-handlers ([exn:fail? (lambda (_e) #f)])
         (define sql      (hash-ref cap 'sql ""))
         (define params   (hash-ref cap 'params '()))
         (define table    (hash-ref cap 'table #f))
         (define op       (hash-ref cap 'op #f))
         (define status   (hash-ref cap 'status 'pending))
         (define rowcount (hash-ref cap 'row-count #f))
         (define param-json
           (for/list ([p (in-list params)] [i (in-naturals 1)])
             (hasheq 'index i
                     'value (safe-display p)
                     'type  (sql-param-type-tag p))))
         (define base
           (hasheq 'sql       sql
                   'table     (if table (~a table) 'null)
                   'operation (if op (~a op) 'null)
                   'params    param-json
                   'preview   (sql-inline-preview sql params)
                   'status    (~a status)))
         (if (and (eq? status 'executed) (exact-nonnegative-integer? rowcount))
             (hash-set base 'row-count rowcount)
             base))))

;; ── Result assembly ──────────────────────────────────────────────────────────
;; Build the top-level JSON object from a (possibly #f) stopped event.  Shared by
;; the live runner and the smoke test so the exact shape is exercised directly.
;;   evt        — the checkpoint `stopped` hasheq (or #f if the bp never fired)
;;   src        — original .tesl source path (for source.file)
;;   line       — requested breakpoint line
;;   reason     — string reason when not stopped (e.g. "program-finished")
;;   sql-cap    — the SQL capture record, or #f
(define (build-result-json evt src line reason sql-cap)
  (define stopped? (and evt #t))
  (define locals (if evt (hash-ref evt 'locals '()) '()))
  (define base
    (hasheq 'version headless-version
            'stopped stopped?
            'source  (hasheq 'file (if evt (hash-ref evt 'file src) src)
                             'line (if evt (hash-ref evt 'line line) line))
            'locals  (locals->json locals)
            'domain  (domain->json locals)
            'sql     (or (sql->json sql-cap) 'null)))
  (if stopped? base (hash-set base 'reason reason)))

;; ── Live runner ──────────────────────────────────────────────────────────────
;; Compile-time gate: TESL_DEBUG must be set BEFORE the debuggee is expanded via
;; dynamic-require, or every thsl-src! checkpoint erases to the bare body and no
;; breakpoint can fire (see checkpoint.rkt's B5 note).
;;
;; Returns the result JSON hasheq.  Never throws on a debuggee runtime error —
;; reports it as stopped=false with a reason instead.
(define (run-headless-inspect compiled-path src-path line [mode "program"])
  (putenv "TESL_DEBUG" "1")
  ;; ONE breakpoint at the requested line, in the SAME table thsl-src!/runtime reads.
  (hash-set! breakpoints src-path (list (make-bp-record line)))
  (define rkt-path   (path->complete-path compiled-path))
  (define submod-sym (if (equal? mode "test") 'test 'main))
  (define require-target `(submod ,rkt-path ,submod-sym))

  ;; Silence the debuggee's own stdout so user prints can never corrupt our JSON
  ;; (our JSON is written to the real stdout AFTER the run, below).
  (define real-out (current-output-port))
  (define captured-event (box #f))
  (define prog-thread (box #f))
  (define done (make-semaphore 0))

  ;; The debuggee's stdout/stderr are routed to nowhere for the WHOLE lifetime of
  ;; the run — user prints (and the rackunit test runner's summary lines) must
  ;; never reach the real stdout, which is reserved exclusively for our one JSON
  ;; object.  The program thread inherits this parameterization, so even after we
  ;; capture the stop its output stays sunk.
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port  (open-output-nowhere)])
    (with-handlers ([exn:fail? (lambda (_e) (void))])
      (dynamic-require rkt-path #f))
    (define submod-present? (module-declared? require-target #f))
    (cond
      [(not submod-present?)
       (semaphore-post done)]
      [else
       ;; Run the debuggee in a thread; the checkpoint runtime puts the first
       ;; stopped event on event-ch and blocks on paused-ch.
       (define t
         (thread
          (lambda ()
            (parameterize ([debug-enabled? #t])
              (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
                (dynamic-require require-target #f))
              ;; Program finished without hitting the breakpoint.
              (semaphore-post done)))))
       (set-box! prog-thread t)
       ;; Wait for EITHER the first stopped event OR program completion.
       (sync (handle-evt event-ch
                         (lambda (evt) (set-box! captured-event evt)))
             (handle-evt (semaphore-peek-evt done) (lambda (_) (void))))]))

  (define evt (unbox captured-event))
  ;; Capture the SQL while the world is still frozen (the bp thread is parked on
  ;; paused-ch and stop-the-world is active).  For the program thread we read the
  ;; per-thread capture with a most-recent fallback, just like dap-server.
  (define sql-cap
    (with-handlers ([exn:fail? (lambda (_e) #f)])
      (or (let ([t (unbox prog-thread)]) (and t (sql-capture-for-thread t)))
          (most-recent-sql-capture))))
  (define result
    (build-result-json evt src-path line
                       (if evt "stopped" "breakpoint-not-hit")
                       sql-cap))
  ;; Tear down: kill the (parked or running) debuggee thread so no further user
  ;; output can race our JSON write and the process can exit promptly.  The
  ;; suspended background threads are torn down with the process on exit.
  (let ([t (unbox prog-thread)])
    (when t
      (with-handlers ([exn:fail? (lambda (_e) (void))]) (kill-thread t))))
  ;; Hand the JSON back to the caller; the `main` entry writes it to real stdout.
  (values result real-out))

;; ── Entry point ────────────────────────────────────────────────────────────
;; racket headless-inspect.rkt <compiled.rkt> <srcfile> <line> [mode]
(module+ main
  (define argv (current-command-line-arguments))
  (when (< (vector-length argv) 3)
    (eprintf "usage: headless-inspect.rkt <compiled.rkt> <srcfile> <line> [program|test]\n")
    (exit 2))
  (define compiled (vector-ref argv 0))
  (define src      (vector-ref argv 1))
  (define line     (string->number (vector-ref argv 2)))
  (define mode     (if (>= (vector-length argv) 4) (vector-ref argv 3) "program"))
  (define-values (result real-out)
    (run-headless-inspect compiled src line mode))
  ;; Emit EXACTLY one JSON object (+ trailing newline) on the real stdout.  The
  ;; write-string results are voided so the module-top-level printer can't append
  ;; their char counts to the protocol stream.
  (void (write-string (jsexpr->string result) real-out))
  (void (write-string "\n" real-out))
  (flush-output real-out)
  (exit 0))
