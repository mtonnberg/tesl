#!/usr/bin/env racket
#lang racket

;; headless-inspect.rkt — headless (non-interactive) breakpoint inspector for Tesl.
;;
;; AC2: run a compiled Tesl program to a breakpoint, capture the runtime state
;; with STOP-THE-WORLD active, and emit it as one JSON object on stdout — with NO
;; DAP client and NO interactive protocol.  This is the engine behind the
;; `tesl debug-inspect <file.tesl> --break-at SPEC... [--when EXPR] [--hit SPEC]
;;  [--mode program|test]` subcommand: main.ml compiles the .tesl with `--debug`
;; (so the thsl-src! checkpoints survive expansion) and shells `racket` on this
;; driver with the compiled .rkt + the ORIGINAL source path + the breakpoint set.
;;
;; BREAKPOINTS THE AGENT SETS (full control):
;;   • MULTIPLE breakpoints — register all; stop at whichever fires FIRST and
;;     report WHICH one in the JSON ("breakpoint" field).
;;   • CONDITIONAL breakpoints — each breakpoint may carry a boolean `condition`
;;     (e.g. "n == 100") evaluated over the paused frame's locals, and/or a
;;     `hit-condition` (e.g. "%3" / ">=5") gating on the per-line hit count.
;;   We REUSE checkpoint.rkt's make-bp-record + eval-bp-condition / eval-hit-condition
;;   verbatim (the same safe evaluator the DAP uses); a bad condition FAILS OPEN
;;   (treated as #t) so a typo never silently drops a breakpoint.
;;
;; Direct invocation (the documented wrapper forms):
;;   ;; legacy single positional line (back-compat):
;;   racket dsl/debug/headless-inspect.rkt <compiled.rkt> <srcfile.tesl> <line> [mode]
;;   ;; structured multi/conditional form (what main.ml uses):
;;   racket dsl/debug/headless-inspect.rkt <compiled.rkt> <srcfile.tesl> <mode> <bp-json>
;; where mode ∈ {program, test} (default program) and <bp-json> is a JSON array of
;; breakpoint objects: [{"line":N, "condition":STR?, "hit":STR?}, ...].
;;
;; DESIGN — mirrors dsl/debug/dap-server.rkt's launch+breakpoint+stop flow:
;;   • set TESL_DEBUG=1 so the debuggee's thsl-src! macros expand to real
;;     checkpoints (they are expansion-time gated — see checkpoint.rkt);
;;   • register the requested breakpoints (line + optional condition / hit) in the
;;     SAME `breakpoints` table that checkpoint.rkt's thsl-src!/runtime consults;
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
         (struct-out bp-spec)
         parse-bp-spec
         bp-specs->json
         build-result-json
         run-headless-inspect)

;; ── Version (bumped on JSON-shape changes) ──────────────────────────────────
;; v2: added the top-level "breakpoint" field (which breakpoint stopped) and
;; support for multiple + conditional + hit-count breakpoints.
(define headless-version 2)

;; ── Breakpoint specs ──────────────────────────────────────────────────────────
;; The agent's requested breakpoints, before they are registered as
;; checkpoint.rkt bp-records.  `line` is a 1-based integer; `condition` and `hit`
;; are source strings or #f.  Kept as a small struct so the driver can both
;; register them (via make-bp-record) and report them ("breakpoint" field).
(struct bp-spec (line condition hit) #:transparent)

;; Parse ONE textual breakpoint spec into a bp-spec, or #f if it carries no usable
;; line number.  Accepted forms (whitespace-insensitive):
;;   "LINE"                     bare, unconditional         e.g. "42"
;;   "LINE:COL"                 COL accepted and ignored    e.g. "42:7"
;;   "LINE: <expr>"             conditional                 e.g. "42: n == 100"
;;   "LINE: <hit-spec>"         hit-count                   e.g. "42: %3" / "42: >=5"
;; The text AFTER the first colon is classified: a pure DAP hit-condition pattern
;; ((==|>=|<=|>|<|%)?N — see checkpoint.rkt's eval-hit-condition) is treated as a
;; `hit` spec; otherwise it is a boolean `condition` expression.  A leading bare
;; integer with NO operator is a COLUMN (legacy LINE:COL), not a hit count, so it
;; is dropped.  Defaults [when-cond] / [hit-cond] fill in a missing slot.
(define (classify-after-colon rest)
  (define s (string-trim rest))
  (cond
    [(string=? s "") (values #f #f)]
    ;; bare integer → legacy COLUMN, ignored (no condition, no hit)
    [(regexp-match? #px"^[0-9]+$" s) (values #f #f)]
    ;; explicit hit-condition operator form: (==|>=|<=|>|<|%) N
    [(regexp-match? #px"^(==|>=|<=|>|<|%)\\s*[0-9]+$" s) (values #f s)]
    ;; otherwise a boolean condition expression
    [else (values s #f)]))

(define (parse-bp-spec text [when-cond #f] [hit-cond #f])
  (define t (string-trim text))
  (cond
    [(string=? t "") #f]
    [else
     (define ci (let ([m (regexp-match-positions #rx":" t)]) (and m (caar m))))
     (define line-part (if ci (substring t 0 ci) t))
     (define rest      (if ci (substring t (add1 ci)) ""))
     (define line (string->number (string-trim line-part)))
     (cond
       [(not (exact-positive-integer? line)) #f]
       [else
        (define-values (c h) (classify-after-colon rest))
        (bp-spec line
                 (or c when-cond)
                 (or h hit-cond))])]))

;; Render the bp-specs as JSON (for the "requested" list, optional).
(define (bp-spec->json bp)
  (define base (hasheq 'line (bp-spec-line bp)))
  (let* ([b (if (bp-spec-condition bp) (hash-set base 'condition (bp-spec-condition bp)) base)]
         [b (if (bp-spec-hit bp)       (hash-set b 'hit (bp-spec-hit bp))             b)])
    b))

(define (bp-specs->json bps) (map bp-spec->json bps))

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
;;   evt        — the checkpoint `stopped` hasheq (or #f if no bp ever fired)
;;   src        — original .tesl source path (for source.file)
;;   bps        — the requested bp-spec list (used for source.line fallback when
;;                not stopped, and to identify WHICH breakpoint fired)
;;   reason     — string reason when not stopped (e.g. "breakpoint-not-hit")
;;   sql-cap    — the SQL capture record, or #f
;;
;; When stopped, a top-level "breakpoint" object identifies the breakpoint that
;; fired: {line, condition?, hit?}.  The line comes from the stop event; the
;; condition/hit are looked up from the matching requested spec (so the agent sees
;; exactly which of its breakpoints stopped, and under what condition).
(define (matching-bp-spec bps line)
  (for/or ([b (in-list bps)]) (and (= (bp-spec-line b) line) b)))

(define (build-result-json evt src bps reason sql-cap)
  ;; Back-compat: accept a bare integer line in the `bps` slot (legacy callers /
  ;; existing smoke test) — wrap it as a single unconditional spec.
  (define specs
    (cond [(list? bps) bps]
          [(exact-integer? bps) (list (bp-spec bps #f #f))]
          [else '()]))
  (define fallback-line
    (cond [(pair? specs) (bp-spec-line (car specs))] [else 0]))
  (define stopped? (and evt #t))
  (define locals (if evt (hash-ref evt 'locals '()) '()))
  (define stop-line (if evt (hash-ref evt 'line fallback-line) fallback-line))
  (define base
    (hasheq 'version headless-version
            'stopped stopped?
            'source  (hasheq 'file (if evt (hash-ref evt 'file src) src)
                             'line stop-line)
            'locals  (locals->json locals)
            'domain  (domain->json locals)
            'sql     (or (sql->json sql-cap) 'null)))
  (cond
    [stopped?
     ;; Identify which requested breakpoint stopped us (line + its condition/hit).
     (define spec (matching-bp-spec specs stop-line))
     (define bp (if spec (bp-spec->json spec) (hasheq 'line stop-line)))
     (hash-set base 'breakpoint bp)]
    [else (hash-set base 'reason reason)]))

;; ── Live runner ──────────────────────────────────────────────────────────────
;; Compile-time gate: TESL_DEBUG must be set BEFORE the debuggee is expanded via
;; dynamic-require, or every thsl-src! checkpoint erases to the bare body and no
;; breakpoint can fire (see checkpoint.rkt's B5 note).
;;
;; Returns the result JSON hasheq.  Never throws on a debuggee runtime error —
;; reports it as stopped=false with a reason instead.
;; `bps` is a list of bp-spec (the agent's requested breakpoints) OR — for
;; back-compat with the legacy single-line callers — a bare integer line.
;; Continue-mode result: one snapshot per breakpoint HIT (in order), plus whether
;; the program ran to completion. This is the headless equivalent of DAP F5 — the
;; program is RESUMED after each stop (not killed), so multiple --break-at all
;; fire and the computation / HTTP response actually completes (issue #16).
(define (build-continue-result snapshots completed?)
  (hasheq 'version   headless-version
          'mode      "continue"
          'completed completed?
          'breakpointsHit (length snapshots)
          'snapshots snapshots))

;; Emit ONE newline-delimited JSON object (flushed) to `out`. Used by the
;; persistent server mode to stream a snapshot the instant each breakpoint fires.
(define (emit-ndjson-line out obj)
  (write-string (jsexpr->string obj) out)
  (write-string "\n" out)
  (flush-output out))

(define (run-headless-inspect compiled-path src-path bps [mode "program"] #:continue? [continue? #f])
  (putenv "TESL_DEBUG" "1")
  (define specs
    (cond [(list? bps) bps]
          [(exact-integer? bps) (list (bp-spec bps #f #f))]
          [else '()]))
  ;; Register ALL requested breakpoints in the SAME table thsl-src!/runtime reads,
  ;; each with its optional condition / hit-condition.  REUSE make-bp-record —
  ;; the runtime evaluates condition + hitCondition via eval-bp-condition /
  ;; eval-hit-condition (fail-open) exactly as the DAP does.  The inspector stops
  ;; at whichever fires FIRST; build-result-json reports which.
  (hash-set! breakpoints src-path
             (for/list ([b (in-list specs)])
               (make-bp-record (bp-spec-line b)
                               (bp-spec-condition b)
                               (bp-spec-hit b))))
  (define rkt-path   (path->complete-path compiled-path))
  (define submod-sym (if (equal? mode "test") 'test 'main))
  (define require-target `(submod ,rkt-path ,submod-sym))

  ;; Silence the debuggee's own stdout so user prints can never corrupt our JSON
  ;; (our JSON is written to the real stdout AFTER the run, below).
  (define real-out (current-output-port))
  (define captured-event (box #f))
  (define prog-thread (box #f))
  (define done (make-semaphore 0))
  ;; Continue-mode state: snapshots accumulated newest-first, and whether the
  ;; program finished (vs. still running — e.g. a `serve`d app that never returns,
  ;; where we stop after an idle window and report completed=#f).
  (define snapshots-box (box '()))
  (define completed-box (box #f))
  ;; #t once the persistent server mode has streamed its output directly to
  ;; real-out (so `main` must not also write a final JSON object).
  (define streamed?-box (box #f))
  (define idle-secs
    (let ([e (getenv "TESL_DEBUG_INSPECT_IDLE_MS")])
      (cond [(and e (string->number e)) (/ (string->number e) 1000.0)]
            [else 15.0])))

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
       (define (capture-sql)
         (with-handlers ([exn:fail? (lambda (_e) #f)])
           (or (sql-capture-for-thread t) (most-recent-sql-capture))))
       (cond
         ;; PERSISTENT server (program + continue): the backend must STAY UP after
         ;; each response so an agent driving a browser (Playwright) can make many
         ;; requests / hit many breakpoints in one session. Stream one NDJSON
         ;; snapshot the instant each breakpoint fires, resume, and NEVER tear the
         ;; server down on idle — run until the process is killed. (A program that
         ;; does terminate emits a final "exited" line and returns.)
         [(and continue? (equal? mode "program"))
          (set-box! streamed?-box #t)
          (emit-ndjson-line real-out
            (hasheq 'version headless-version 'event "session-started"
                    'breakpoints (bp-specs->json specs)))
          (let loop ()
            (sync
             (handle-evt event-ch
               (lambda (evt)
                 ;; Tag with event:"stopped" so the NDJSON stream is uniformly
                 ;; discriminable (session-started / stopped / exited).
                 (emit-ndjson-line real-out
                   (hash-set (build-result-json evt src-path specs "stopped" (capture-sql))
                             'event "stopped"))
                 (channel-put paused-ch 'continue)   ; resume → response completes, server keeps serving
                 (loop)))
             (handle-evt (semaphore-peek-evt done)
               (lambda (_)
                 (emit-ndjson-line real-out
                   (hasheq 'version headless-version 'event "exited"))))))]
         ;; CONTINUE for a COMPLETING program (test / program-that-exits): stop at
         ;; each breakpoint in turn, snapshot, resume, until completion; then emit
         ;; one batched result. An idle window bounds a non-terminating program.
         [continue?
          (let loop ()
            (define r
              (sync/timeout idle-secs
                (handle-evt event-ch (lambda (evt) (cons 'stop evt)))
                (handle-evt (semaphore-peek-evt done) (lambda (_) 'done))))
            (cond
              [(eq? r 'done) (set-box! completed-box #t)]
              [(not r) (void)]  ; idle: still running — stop, completed=#f
              [(and (pair? r) (eq? (car r) 'stop))
               (set-box! snapshots-box
                         (cons (build-result-json (cdr r) src-path specs "stopped" (capture-sql))
                               (unbox snapshots-box)))
               (channel-put paused-ch 'continue)
               (loop)]))]
         ;; ONE-SHOT: wait for EITHER the first stopped event OR completion.
         [else
          (sync (handle-evt event-ch
                            (lambda (evt) (set-box! captured-event evt)))
                (handle-evt (semaphore-peek-evt done) (lambda (_) (void))))])]))

  (define result
    (cond
      ;; Persistent server mode already streamed everything to real-out.
      [(unbox streamed?-box) 'streamed]
      [continue?
        (build-continue-result (reverse (unbox snapshots-box)) (unbox completed-box))]
      [else
        (let* ([evt (unbox captured-event)]
               ;; Capture SQL while the world is still frozen (bp thread parked on
               ;; paused-ch, stop-the-world active), per-thread with a most-recent
               ;; fallback — exactly like dap-server.
               [sql-cap
                (with-handlers ([exn:fail? (lambda (_e) #f)])
                  (or (let ([t (unbox prog-thread)]) (and t (sql-capture-for-thread t)))
                      (most-recent-sql-capture)))])
          (build-result-json evt src-path specs
                             (if evt "stopped" "breakpoint-not-hit")
                             sql-cap))]))
  ;; Tear down: kill the (parked or running) debuggee thread so no further user
  ;; output can race our JSON write and the process can exit promptly.  The
  ;; suspended background threads are torn down with the process on exit.
  (let ([t (unbox prog-thread)])
    (when t
      (with-handlers ([exn:fail? (lambda (_e) (void))]) (kill-thread t))))
  ;; Hand the JSON back to the caller; the `main` entry writes it to real stdout.
  (values result real-out))

;; ── Entry point ────────────────────────────────────────────────────────────
;; Two argv shapes are accepted:
;;   LEGACY (single positional line):  <compiled.rkt> <srcfile> <line> [mode]
;;   STRUCTURED (multi/conditional):   <compiled.rkt> <srcfile> <mode> <bp-json>
;; The two are distinguished by argv[2]: a NUMBER is the legacy line; otherwise it
;; is the mode and argv[3] is a JSON array of breakpoint objects
;; ([{"line":N,"condition":STR?,"hit":STR?}, ...]).  main.ml always emits the
;; structured form; the legacy form keeps hand/test invocation working.
(define (bp-specs-from-json arr)
  (for/list ([o (in-list arr)] #:when (hash? o))
    (define line (hash-ref o 'line #f))
    (define cond* (let ([c (hash-ref o 'condition #f)]) (and (string? c) (non-empty-string? (string-trim c)) c)))
    (define hit   (let ([h (hash-ref o 'hit #f)])       (and (string? h) (non-empty-string? (string-trim h)) h)))
    (and (exact-positive-integer? line) (bp-spec line cond* hit)))
  )

(module+ main
  (define argv (current-command-line-arguments))
  (when (< (vector-length argv) 3)
    (eprintf "usage: headless-inspect.rkt <compiled.rkt> <srcfile> <line> [program|test]\n")
    (eprintf "   or: headless-inspect.rkt <compiled.rkt> <srcfile> <mode> <bp-json>\n")
    (exit 2))
  (define compiled (vector-ref argv 0))
  (define src      (vector-ref argv 1))
  (define legacy-line (string->number (vector-ref argv 2)))
  (define-values (mode bps)
    (cond
      ;; legacy: argv[2] is a number → single unconditional line, optional mode
      [(exact-positive-integer? legacy-line)
       (values (if (>= (vector-length argv) 4) (vector-ref argv 3) "program")
               (list (bp-spec legacy-line #f #f)))]
      ;; structured: argv[2] is mode, argv[3] is the bp JSON array
      [else
       (define m (vector-ref argv 2))
       (define arr
         (if (>= (vector-length argv) 4)
             (with-handlers ([exn:fail? (lambda (_e) '())])
               (let ([j (string->jsexpr (vector-ref argv 3))]) (if (list? j) j '())))
             '()))
       (values m (filter values (bp-specs-from-json arr)))]))
  ;; Optional trailing token "continue" enables headless F5 (run through every
  ;; breakpoint, resuming after each, until the program completes). Absent/"once"
  ;; keeps the one-shot behaviour. Scanning argv keeps it position-tolerant; no
  ;; mode / bp-json / path ever equals "continue".
  (define continue? (for/or ([a (in-vector argv)]) (equal? a "continue")))
  (define-values (result real-out)
    (run-headless-inspect compiled src bps mode #:continue? continue?))
  ;; Persistent server mode (result = 'streamed) already wrote its NDJSON lines to
  ;; real-out AS breakpoints fired — nothing to emit here. Otherwise emit EXACTLY
  ;; one JSON object (+ trailing newline). write-string results are voided so the
  ;; module-top-level printer can't append their char counts to the protocol stream.
  (unless (eq? result 'streamed)
    (void (write-string (jsexpr->string result) real-out))
    (void (write-string "\n" real-out))
    (flush-output real-out))
  (exit 0))
