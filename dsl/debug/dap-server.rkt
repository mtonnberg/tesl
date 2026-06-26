#!/usr/bin/env racket
#lang racket

;; dap-server.rkt — Debug Adapter Protocol (DAP) server for Tesl.
;;
;; Communicates with a DAP client (e.g. VSCode) over stdin/stdout using
;; the standard Content-Length framing.  Launches a Tesl program compiled
;; with --debug and proxies breakpoint/step events through checkpoint.rkt.
;;
;; Protocol reference: https://microsoft.github.io/debug-adapter-protocol/

;; Logging is OFF by default (retired the always-on ~/tesl-dap.log crutch).
;; Enable diagnostics by setting TESL_DAP_LOG to a file path, or to "1"/"stderr"
;; to log to stderr.  Logging never touches stdout — that channel is reserved
;; exclusively for Content-Length-framed DAP traffic.
(require racket/port
         racket/system
         json)

(define LOG-DEST
  (let ([v (getenv "TESL_DAP_LOG")])
    (cond
      [(or (not v) (string=? v "") (string=? v "0")) #f]
      [(or (string=? v "1") (string-ci=? v "stderr")) 'stderr]
      [else v])))  ; a file path

(define (log! . parts)
  (when LOG-DEST
    (define line (apply string-append (map ~a parts)))
    (cond
      [(eq? LOG-DEST 'stderr)
       (displayln line (current-error-port))
       (flush-output (current-error-port))]
      [else
       (call-with-output-file LOG-DEST #:exists 'append
         (lambda (out) (displayln line out) (flush-output out)))])))

(log! "=== Racket started — stdlib loaded OK ===")
(log! "PLTCOLLECTS=" (or (getenv "PLTCOLLECTS") "UNSET"))
(log! "TESL_COMPILER=" (or (getenv "TESL_COMPILER") "UNSET"))

;; Now load checkpoint — this requires PLTCOLLECTS to resolve tesl/dsl/debug/checkpoint
(log! "requiring tesl/dsl/debug/checkpoint ...")
(require tesl/dsl/debug/checkpoint)
(log! "=== checkpoint loaded OK ===")
;; Predicates needed by infer-type-string / handle-variables
(require (only-in tesl/dsl/private/evidence
                  named-value? named-value-value
                  check-ok? check-ok-value)
         (only-in tesl/dsl/types
                  newtype-value? newtype-value-type-name newtype-value-value
                  record-value? record-value-type record-value-fields))

;; FULL LIVE DOMAIN STATE: the global domain registry lists every queue / cache /
;; SSE channel / email outbox / worker pool the debuggee created via define-queue /
;; define-cache / define-channel / define-email / start-workers!.  The debuggee is
;; loaded IN-PROCESS (dynamic-require, same namespace), so the registry it populates
;; at module-instantiation time is the SAME module instance we read here.  The
;; registry module is dependency-free (it pulls in none of the web/db runtime), so
;; this require keeps the debugger loadable in isolation — unlike the spec modules
;; themselves, which we still deliberately do NOT require (see note above).
(require (only-in tesl/dsl/private/domain-registry
                  domain-registry-entries))

;; SQL TRANSPARENCY (task #43): read the per-thread "last + pending" SQL capture
;; recorded by dsl/sql.rkt so the paused frame can show EXACTLY what the driver
;; runs.  domain-registry is dependency-free, debug-gated, and already required
;; above — these readers add no new runtime dependency.
(require (only-in tesl/dsl/private/domain-registry
                  sql-capture-for-thread
                  most-recent-sql-capture))
;; sql-null? recognises the db-lib NULL sentinel among captured params so the SQL
;; scope can tag/escape it correctly.  db/base is the LIGHTWEIGHT base layer of the
;; `db` package (no DB connector pulled in) and loads in isolation, so this keeps
;; the debugger dependency-light — we deliberately do NOT require the full `db`.
(require (only-in db/base sql-null?))

;; Dependency-free recognition + summarisation of the live domain objects — shared
;; with the smoke test so the rendering logic is exercised deterministically.
(require (only-in tesl/dsl/debug/domain-inspect
                  domain-struct-name
                  domain-object?
                  domain-object-summary
                  domain-object-fields
                  domain-field-names
                  channel-connected-count
                  worker-pool-live
                  registry-object-label
                  domain-registry-objects))

;; Domain runtime inspection (queues, channels, caches, email outbox) is done
;; via GENERIC, dependency-free struct introspection — see domain-struct-name and
;; describe-domain-object below.  We deliberately do NOT (require tesl/tesl/queue
;; …): those modules pull in the full web/db runtime and several do not load in
;; isolation, so a hard dependency would risk breaking the debugger itself.  The
;; domain structs are all #:transparent, so `struct->vector` + the struct type's
;; printed name give us everything we need without coupling to their modules.
(require racket/struct)

;; ── DAP framing ──────────────────────────────────────────────────────────────
;;
;; Robust, byte-level DAP stdio framing for Linux/WSL.  The DAP wire format is:
;;
;;     Content-Length: <N>\r\n
;;     [other headers]\r\n
;;     \r\n
;;     <N bytes of UTF-8 JSON>
;;
;; We read the header block one byte at a time until the CRLFCRLF terminator,
;; tolerating bare-LF line endings (some clients/pipes strip CRs), then read
;; exactly N bytes with a loop that re-reads on short reads.  Returns a parsed
;; jsexpr, or eof on a clean end-of-stream.  Reading bytes (not read-line)
;; avoids both the buffered-port hangs and the CR-handling pitfalls of the old
;; read-line approach.

;; Read raw header bytes up to and including the blank-line terminator.
;; Returns the header bytes (without the final terminator) or eof.
(define (read-header-bytes in)
  (let loop ([acc '()])
    (define b (read-byte in))
    (cond
      [(eof-object? b)
       (if (null? acc) eof (list->bytes (reverse acc)))]
      [else
       (define acc* (cons b acc))
       ;; Detect terminator: \r\n\r\n  OR  \n\n (bare-LF clients).
       (cond
         [(and (= b 10)                              ; current is LF
               (>= (length acc*) 4)
               (= (list-ref acc* 1) 13)              ; \r
               (= (list-ref acc* 2) 10)              ; \n
               (= (list-ref acc* 3) 13))             ; \r  → matched \r\n\r\n
          (list->bytes (reverse (drop acc* 4)))]
         [(and (= b 10)                              ; current is LF
               (>= (length acc*) 2)
               (= (list-ref acc* 1) 10))             ; previous also LF → \n\n
          (list->bytes (reverse (drop acc* 2)))]
         [else (loop acc*)])])))

;; Parse "Content-Length: N" out of a header block (case-insensitive).
(define (header->content-length header-bytes)
  (define text (bytes->string/utf-8 header-bytes #\?))
  (for/or ([line (in-list (regexp-split #rx"\r?\n" text))])
    (define m (regexp-match #px"(?i:content-length)\\s*:\\s*([0-9]+)" line))
    (and m (string->number (cadr m)))))

;; Read exactly n bytes, looping on short reads; eof if the stream ends early.
(define (read-exactly in n)
  (let loop ([remaining n] [chunks '()])
    (if (<= remaining 0)
        (apply bytes-append (reverse chunks))
        (let ([chunk (read-bytes remaining in)])
          (if (eof-object? chunk)
              eof
              (loop (- remaining (bytes-length chunk)) (cons chunk chunks)))))))

(define (read-dap-msg)
  (define in DAP-IN)
  (define header (read-header-bytes in))
  (cond
    [(eof-object? header) eof]
    [else
     (define n (header->content-length header))
     (cond
       [(not n)
        (log! "read-dap-msg: header with no Content-Length: " (bytes->string/utf-8 header #\?))
        ;; Malformed frame — try to recover by reading the next frame.
        (read-dap-msg)]
       [else
        (define body (read-exactly in n))
        (cond
          [(eof-object? body) eof]
          [else
           (with-handlers
               ([exn:fail?
                 (lambda (e)
                   (log! "read-dap-msg: JSON parse error: " (exn-message e))
                   ;; Skip the bad frame and continue.
                   (read-dap-msg))])
             (string->jsexpr (bytes->string/utf-8 body)))])])]))

;; Capture the REAL stdout/stdin ports at module load, BEFORE any code path can
;; rebind current-output-port (the program thread will rebind its own copy to
;; redirect user prints into DAP "output" events — see launch-program).  All DAP
;; frames are written to DAP-OUT regardless of dynamic rebinding, so user-program
;; output can never corrupt the protocol stream.
(define DAP-OUT (current-output-port))
(define DAP-IN  (current-input-port))

(define dap-seq (box 1))
;; Serialize frame writes: the main loop, the event-pump thread, and the program
;; thread all emit frames; without a lock, concurrent writes could interleave
;; bytes within a single Content-Length frame and corrupt the stream.
(define dap-write-sem (make-semaphore 1))

;; Atomically assign a seq, serialize the message, and write one framed message.
(define (emit-frame! make-msg)
  (call-with-semaphore dap-write-sem
    (lambda ()
      (define seq (unbox dap-seq))
      (set-box! dap-seq (+ seq 1))
      (define json-bytes (string->bytes/utf-8 (jsexpr->string (make-msg seq))))
      (write-string (format "Content-Length: ~a\r\n\r\n" (bytes-length json-bytes)) DAP-OUT)
      (write-bytes json-bytes DAP-OUT)
      (flush-output DAP-OUT))))

(define (write-dap-msg type cmd body)
  (emit-frame! (lambda (seq)
    (hasheq 'seq seq 'type type 'command cmd 'body body))))

(define (dap-response req success body)
  (emit-frame! (lambda (seq)
    (hasheq 'seq seq
            'type "response"
            'request_seq (hash-ref req 'seq 0)
            'success success
            'command (hash-ref req 'command "")
            'body body))))

(define (dap-event name body)
  (emit-frame! (lambda (seq)
    (hasheq 'seq seq 'type "event" 'event name 'body body))))

;; Make an output port whose writes are forwarded to the DAP client as "output"
;; events under the given category ("stdout" / "stderr").  This lets the user
;; program's print/displayln/telemetry land in VSCode's Debug Console instead of
;; corrupting the Content-Length-framed protocol stream on real stdout.
(define (make-dap-output-port category)
  (make-output-port
   category
   always-evt
   (lambda (bs start end non-block? breakable?)
     (define n (- end start))
     (when (> n 0)
       (define s (bytes->string/utf-8 (subbytes bs start end) #\?))
       (dap-event "output" (hasheq 'category category 'output s)))
     n)
   void))

;; ── State ─────────────────────────────────────────────────────────────────────

;; Last stopped event received from the running program.
(define last-stopped-event (box #f))

;; The thread running the user's Tesl program.
(define program-thread (box #f))

;; #t exactly while the program thread is blocked in checkpoint.rkt awaiting a
;; resume command on paused-ch.  Set by the event pump on "stopped", cleared by
;; resume!.  Guards against blocking the dispatch loop: paused-ch is unbuffered,
;; so a channel-put when nobody is waiting would hang the whole server.
(define paused? (box #f))

;; Send a resume command to the program thread iff it is currently paused.
;; Non-blocking with respect to the dispatch loop: if (somehow) the thread is not
;; yet ready to receive, the put runs in a detached thread so dispatch continues.
(define (resume! cmd)
  (when (unbox paused?)
    (set-box! paused? #f)
    (thread (lambda () (channel-put paused-ch cmd)))))

;; ── Tesl compiler lookup ──────────────────────────────────────────────────────

;; Find the tesl compiler binary.
(define (find-tesl-binary)
  (or (getenv "TESL_COMPILER")
      (let ([p (find-executable-path "tesl")])
        (and p (path->string p)))
      (let ([p (build-path (find-system-path 'home-dir) ".nix-profile" "bin" "tesl")])
        (and (file-exists? p) (path->string p)))
      (let ([p "/nix/var/nix/profiles/default/bin/tesl"])
        (and (file-exists? p) p))
      #f))

;; Compile a .tesl file with --debug, write output to a temp .rkt, return the path.
(define (compile-debug program-path #:test-name [test-name #f])
  (define tesl (find-tesl-binary))
  (unless tesl
    (error "tesl binary not found; set TESL_COMPILER env var or install via nix"))
  ;; Ensure absolute path so thsl-src file strings match VSCode's setBreakpoints paths.
  (define abs-path (path->string (path->complete-path (string->path program-path))))
  (define temp-rkt (path->string (make-temporary-file "tesl-debug-~a.rkt")))
  ;; Run: tesl --debug [--test-name NAME] <abs-path>  → stdout = compiled Racket
  (define-values (proc stdout stdin stderr)
    (if test-name
        (subprocess #f #f #f tesl "--debug" "--test-name" test-name abs-path)
        (subprocess #f #f #f tesl "--debug" abs-path)))
  (define racket-src (port->string stdout))
  (define err-str (port->string stderr))
  (subprocess-wait proc)
  (define exit-code (subprocess-status proc))
  (close-input-port stdout)
  (close-output-port stdin)
  (close-input-port stderr)
  (unless (= exit-code 0)
    (error (format "tesl --debug failed:\n~a" err-str)))
  ;; Write compiled output to temp file
  (call-with-output-file temp-rkt #:exists 'replace
    (lambda (out) (display racket-src out)))
  temp-rkt)

;; ── Checkpoint event pump ─────────────────────────────────────────────────────

;; Pump thread: reads events from checkpoint.rkt's event-ch and forwards
;; them to the DAP client as "stopped" events.
(define (start-event-pump)
  (thread
   (lambda ()
     (let loop ()
       (let ([evt (channel-get event-ch)])
         (log! "event-pump received: " (~a evt))
         (set-box! last-stopped-event evt)
         ;; The program thread is now blocked awaiting a resume command.
         (set-box! paused? #t)
         (dap-event "stopped"
           (hasheq 'reason (hash-ref evt 'reason "breakpoint")
                   'threadId 1
                   'allThreadsStopped #t
                   'source (hasheq 'path (hash-ref evt 'file ""))
                   'line (hash-ref evt 'line 0)))
         (loop))))))

;; ── Program launch ────────────────────────────────────────────────────────────

;; mode is "program" (load (submod ... main)) or "test" (load (submod ... test))
(define (launch-program compiled-path mode)
  (start-event-pump)
  (define rkt-path (path->complete-path compiled-path))
  (define submod-sym (if (equal? mode "test") 'test 'main))
  (define require-target `(submod ,rkt-path ,submod-sym))

  ;; B5: `thsl-src!` checkpoints are now expansion-time-gated on TESL_DEBUG (one
  ;; emission path — a release/non-debug build erases them to the bare body).  The
  ;; debuggee is expanded HERE via dynamic-require, so TESL_DEBUG must be set first
  ;; or every checkpoint vanishes and no breakpoint can fire.  The debuggee .rkt is
  ;; freshly emitted per session (no stale .zo), so this expansion sees it; the DSL
  ;; itself keeps its bytecode (its `thsl-src!` macro reads the env per use-site).
  (putenv "TESL_DEBUG" "1")

  ;; Redirect program output (stdout→Debug Console, stderr→stderr category) so
  ;; user prints never reach the raw protocol stream.  Bind it for the whole
  ;; launch — the spawned program thread inherits this parameterization.
  (parameterize ([current-output-port (make-dap-output-port "stdout")]
                 [current-error-port  (make-dap-output-port "stderr")])

  (dap-event "output" (hasheq 'category "console"
    'output (format "[dbg] Loading top-level module: ~a\n" (path->string rkt-path))))

  ;; Load the top-level module first so submodules become declared.
  (dynamic-require rkt-path #f)

  (dap-event "output" (hasheq 'category "console"
    'output (format "[dbg] Checking for (~a) submodule...\n" submod-sym)))

  (define submod-present? (module-declared? require-target #f))
  (dap-event "output" (hasheq 'category "console"
    'output (format "[dbg] (~a) submodule present: ~a\n" submod-sym submod-present?)))

  (unless submod-present?
    (define hint (if (equal? mode "test")
                     "No test blocks found — add 'test \"name\" { ... }' blocks."
                     "No main block found — add 'main with capabilities [...] { ... }' or switch to test mode."))
    (dap-event "output" (hasheq 'category "stderr" 'output (format "~a\n" hint)))
    (dap-event "exited" (hasheq 'exitCode 0))
    (dap-event "terminated" (hasheq)))

  (when submod-present?
    (dap-event "output" (hasheq 'category "console"
      'output (format "[dbg] Registered breakpoints:\n~a\n"
                      (string-join
                        (hash-map breakpoints
                          (lambda (file entry)
                            (define lines (set->list (file-breakpoint-lines breakpoints file)))
                            ;; Annotate conditional lines so the console log shows
                            ;; the attached condition/hitCondition, not just the line.
                            (define annots
                              (if (list? entry)
                                  (filter-map
                                    (lambda (r)
                                      (and (bp-record? r)
                                           (or (bp-record-condition r) (bp-record-hit-condition r))
                                           (format "    line ~a if ~a~a"
                                                   (bp-record-line r)
                                                   (or (bp-record-condition r) "(always)")
                                                   (if (bp-record-hit-condition r)
                                                       (format " [hit ~a]" (bp-record-hit-condition r)) ""))))
                                    entry)
                                  '()))
                            (string-append
                              (format "  ~a: lines ~a" file lines)
                              (if (null? annots) "" (string-append "\n" (string-join annots "\n"))))))
                        "\n"))))
    (dap-event "output" (hasheq 'category "console"
      'output (format "[dbg] Launching (~a) with debug-enabled?=#t ...\n" submod-sym)))
    (define t
      (thread
        (lambda ()
          (parameterize ([debug-enabled? #t])
            (with-handlers
                ([exn:fail?
                  (lambda (e)
                    (dap-event "output"
                      (hasheq 'category "stderr"
                              'output (format "[dbg] Runtime error: ~a\n" (exn-message e))))
                    (dap-event "exited" (hasheq 'exitCode 1))
                    (dap-event "terminated" (hasheq)))])
              (dap-event "output" (hasheq 'category "console"
                'output "[dbg] Program thread started.\n"))
              (dynamic-require require-target #f)
              (dap-event "output" (hasheq 'category "console"
                'output "[dbg] Program thread finished.\n"))
              (dap-event "exited" (hasheq 'exitCode 0))
              (dap-event "terminated" (hasheq)))))))
    (set-box! program-thread t))))  ; close: when / parameterize / define

;; ── Compile-time proof/type overlay ───────────────────────────────────────────
;;
;; Runtime-agnostic-debugger principle: OCaml owns the static knowledge (types
;; and proofs); the Racket runtime is a thin agent that reports raw locals.  Under
;; unconditional proof erasure the runtime value of a proof-carrying binding is
;; just its raw value (e.g. 80) with NO proof struct attached.  To show the proof
;; we query the compiler's READ-ONLY JSON endpoint --local-bindings-json for the
;; ORIGINAL .tesl file and overlay each binding's static type — which already
;; carries the proof annotation, e.g. "Int ::: ValidPort port".
;;
;; The displayed type for a local at the paused line is the innermost in-scope
;; binding of that name whose source span starts at or before the paused line
;; (the binding's defining line), preferring the one with the greatest start line
;; (most recent shadowing).  This makes a paused `port` show `Int ::: ValidPort
;; port` rather than the runtime-inferred bare `Int`.

;; The original .tesl source path of the running program (set on launch).
(define current-program-path (box #f))

;; Per-file cache of parsed local bindings: path(string) -> (listof binding-hash)
;; where each binding-hash has keys: 'name 'line 'col 'end_line 'end_col 'type 'note
(define local-bindings-cache (make-hash))

;; Shell out to `tesl --local-bindings-json <file>` and parse the result.
;; Returns a list of binding hashes, or '() on any failure (overlay is best-effort
;; and must never break the Variables panel).
(define (query-local-bindings path)
  (cond
    [(hash-has-key? local-bindings-cache path)
     (hash-ref local-bindings-cache path)]
    [else
     (define result
       (with-handlers ([exn:fail? (lambda (e)
                                    (log! "query-local-bindings failed: " (exn-message e))
                                    '())])
         (define tesl (find-tesl-binary))
         (cond
           [(not tesl) '()]
           [(not (file-exists? path)) '()]
           [else
            (define-values (proc stdout stdin stderr)
              (subprocess #f #f #f tesl "--local-bindings-json" path))
            (define out (port->string stdout))
            (port->string stderr)
            (subprocess-wait proc)
            (close-input-port stdout)
            (close-output-port stdin)
            (close-input-port stderr)
            (define parsed (string->jsexpr out))
            (hash-ref parsed 'bindings '())])))
     (hash-set! local-bindings-cache path result)
     result]))

;; Find the best compile-time type string for a local `name` visible at `line`.
;; Returns a type string (possibly with ` ::: Proof`) or #f if none is known.
(define (overlay-binding-type name line)
  (define path (unbox current-program-path))
  (cond
    [(not path) #f]
    [else
     (define candidates
       (filter (lambda (b)
                 (and (equal? (hash-ref b 'name #f) name)
                      ;; in scope: binding defined at or before the paused line.
                      ;; (A parameter's line is the signature line, a let's line is
                      ;; its own line — both are <= the line where we're paused.)
                      (<= (hash-ref b 'line 0) line)))
               (query-local-bindings path)))
     (cond
       [(null? candidates) #f]
       [else
        ;; innermost/most-recent: greatest defining line
        (define best (argmax (lambda (b) (hash-ref b 'line 0)) candidates))
        (hash-ref best 'type #f)])]))

;; ── Variable display helpers ──────────────────────────────────────────────────

;; safe-display is now defined in checkpoint.rkt and re-exported.
;; It handles GDP unwrapping and type-appropriate formatting in one pass.             ; numbers, lists, records etc.

;; ── Variable type inference ───────────────────────────────────────────────────

;; Infer a human-readable type string from a Tesl runtime value.
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

;; ── Domain runtime inspection ──────────────────────────────────────────────────
;;
;; The DSL's domain runtime objects (queues, SSE channels, caches, the email
;; outbox) and the worker-pool tracking record are recognised GENERICALLY — by
;; struct type name + struct->vector — so the debugger stays zero-dependency on the
;; web/db runtime while surfacing the FULL live domain state.  That recognition /
;; summarisation logic lives in dsl/debug/domain-inspect.rkt (required above), which
;; is also exercised directly by tests/dap-domain-registry-smoke.rkt.  Below we keep
;; only the parts that depend on the per-stop variablesReference registry (children
;; expansion + make-variable).

;; ── Structured variables registry ──────────────────────────────────────────────
;;
;; DAP exposes nested data via `variablesReference`: a non-zero ref means "the
;; client may send a `variables` request with this ref to get the children".  We
;; allocate refs lazily per stop: 1 = Locals, 2 = Domain, and ≥100 for expandable
;; values.  The registry maps a ref to a 0-arg thunk that yields the child
;; variable hashes.  It is rebuilt on every stop (see reset-varrefs!) so refs never
;; leak across pauses.
(define varref-registry (make-hash))
(define varref-counter (box 100))
(define (reset-varrefs!)
  (hash-clear! varref-registry)
  (set-box! varref-counter 100))
(define (alloc-varref! thunk)
  (define r (unbox varref-counter))
  (set-box! varref-counter (+ r 1))
  (hash-set! varref-registry r thunk)
  r)

;; Compact, never-raising one-line summary of a raw hash, so a nested store
;; entry (a queue JOB {status, payload, attempts}, an email {to, subject, body,
;; status}, …) reads as e.g. `{status: pending, attempts: 0, …}` in the value
;; column INSTEAD of a raw `#hash(...)` dump — while still being expandable to
;; the full set of keys via its child varref.  Dependency-free; any error
;; falls back to safe-display so it can never break the panel.
(define HASH-SUMMARY-KEYS 3)       ; keys shown inline before the ellipsis
(define HASH-SUMMARY-VALUE-LEN 24) ; per-value truncation inside the summary

(define (truncate-str s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 (max 0 (- n 1))) "…")
      s))

(define (hash-summary h)
  (with-handlers ([(lambda (_) #t) (lambda (_) (safe-display h))])
    (define n (hash-count h))
    (cond
      [(zero? n) "{}"]
      [else
       ;; Stable ordering: sort keys by their printed form so the inline preview
       ;; is deterministic across runs (hash iteration order is unspecified).
       (define keys (sort (hash-keys h) string<? #:key ~a))
       (define shown (if (> n HASH-SUMMARY-KEYS) (take keys HASH-SUMMARY-KEYS) keys))
       (define parts
         (for/list ([k (in-list shown)])
           (define vs (truncate-str (safe-display (hash-ref h k)) HASH-SUMMARY-VALUE-LEN))
           (format "~a: ~a" (~a k) vs)))
       (string-append "{" (string-join parts ", ")
                      (if (> n HASH-SUMMARY-KEYS) ", …" "")
                      "}")])))

;; Friendlier label for a hash whose shape we recognise — only when CHEAP and
;; UNAMBIGUOUS (presence of the diagnostic keys), so we never special-case
;; fragilely.  Returns a short prefix or #f (fall back to hash-summary).
(define (hash-shape-label h)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (cond
      ;; A queue JOB entry: id (optional) + status + attempts.
      [(and (hash-has-key? h 'status) (hash-has-key? h 'attempts))
       (define id (or (and (hash-has-key? h 'id) (hash-ref h 'id))
                      (and (hash-has-key? h 'job-id) (hash-ref h 'job-id)) #f))
       (if id
           (format "job ~a — ~a" (safe-display id) (~a (hash-ref h 'status)))
           (format "job — ~a" (~a (hash-ref h 'status))))]
      ;; An email outbox entry: to + subject + status.
      [(and (hash-has-key? h 'to) (hash-has-key? h 'subject) (hash-has-key? h 'status))
       (format "email → ~a — ~a [~a]"
               (~a (hash-ref h 'to))
               (truncate-str (~a (hash-ref h 'subject)) HASH-SUMMARY-VALUE-LEN)
               (~a (hash-ref h 'status)))]
      [else #f])))

;; Value-column display for a (non-empty) hash: a recognised-shape label when we
;; have one, otherwise the compact key summary.  Never raises.
(define (hash-display h)
  (or (hash-shape-label h) (hash-summary h)))

;; Build a single DAP variable hash for (name . value), allocating a child
;; varref when the value is structured (domain object, record, ADT, non-empty
;; list, or any non-empty raw hash).  `type-str` is the display type (may carry
;; a proof); `value-str` the display string.
(define (make-variable name value-str type-str raw-val)
  (define child-ref
    (cond
      [(domain-object? raw-val)
       (alloc-varref! (lambda () (domain-object-children raw-val)))]
      [(record-value? raw-val)
       (alloc-varref! (lambda () (record-children raw-val)))]
      [(and (list? raw-val) (pair? raw-val))
       (alloc-varref! (lambda () (list-children raw-val)))]
      ;; Every nested non-empty raw hash (e.g. a queue JOB entry, an email outbox
      ;; entry, a cache value that is itself a hash) is recursively expandable —
      ;; hash-children recurses through make-variable, so a job's payload that is
      ;; a record will then drill on into its fields.
      [(and (hash? raw-val) (positive? (hash-count raw-val)))
       (alloc-varref! (lambda () (hash-children raw-val)))]
      [else 0]))
  (hasheq 'name               name
          'value              value-str
          'type               (or type-str "")
          'variablesReference child-ref
          'presentationHint   (hasheq 'kind "data")))

;; Children of a domain object: one variable per struct field, plus a synthesised
;; summary line.  Stores (hashes) are themselves rendered as expandable.
(define (domain-object-children v)
  (with-handlers ([exn:fail? (lambda (e)
                               (list (hasheq 'name "<error>" 'value (exn-message e)
                                             'variablesReference 0)))])
    (define name (domain-struct-name v))
    (define fields (domain-object-fields v))
    (define field-names (domain-field-names name (length fields)))
    (for/list ([fn (in-list field-names)]
               [fv (in-list fields)])
      (cond
        ;; channel-spec listeners: key → (listof callback) — each callback is one
        ;; CONNECTED SSE CLIENT.  Render per-key connected-client counts so the
        ;; panel shows exactly how many clients are subscribed to each channel key.
        [(and (eq? name 'channel-spec) (string=? fn "listeners") (hash? fv))
         (hasheq 'name fn
                 'value (format "~a connected client(s)" (channel-connected-count fv))
                 'variablesReference (if (> (hash-count fv) 0)
                                         (alloc-varref! (lambda () (listener-children fv)))
                                         0))]
        ;; worker-pool threads: box of (listof thread).  Render the live count and
        ;; expand to one entry per worker thread with its running/dead status.
        [(and (eq? name 'worker-pool) (string=? fn "threads"))
         (define ts (if (box? fv) (unbox fv) (if (list? fv) fv '())))
         (hasheq 'name fn
                 'value (format "~a live / ~a total" (worker-pool-live fv) (length ts))
                 'variablesReference (if (pair? ts)
                                         (alloc-varref! (lambda () (thread-children ts)))
                                         0))]
        [(hash? fv)
         (hasheq 'name fn
                 'value (format "{~a entries}" (hash-count fv))
                 'variablesReference (if (> (hash-count fv) 0)
                                         (alloc-varref! (lambda () (hash-children fv)))
                                         0))]
        [(and (box? fv) (list? (unbox fv)))
         (hasheq 'name fn
                 'value (format "[~a items]" (length (unbox fv)))
                 'variablesReference (if (pair? (unbox fv))
                                         (alloc-varref! (lambda () (list-children (unbox fv))))
                                         0))]
        [else
         (hasheq 'name fn 'value (safe-display fv) 'variablesReference 0)]))))

;; Children of a channel's listeners hash: one entry per channel key, showing the
;; number of connected SSE clients subscribed to that key.
(define (listener-children listeners)
  (for/list ([(k cbs) (in-hash listeners)])
    (define n (if (list? cbs) (length cbs) 1))
    (hasheq 'name (~a k)
            'value (format "~a connected client(s)" n)
            'variablesReference 0)))

;; Children of a worker-pool's thread list: one entry per worker thread with its
;; live/dead status.
(define (thread-children ts)
  (for/list ([t (in-list ts)] [i (in-naturals)])
    (hasheq 'name (format "worker[~a]" i)
            'value (if (and (thread? t) (thread-running? t)) "running" "stopped")
            'variablesReference 0)))

;; Display string for a value inside a structured-children list: a hash gets the
;; compact, expandable summary (never a raw #hash dump); everything else uses
;; safe-display.
(define (child-value-display val)
  (if (and (hash? val) (positive? (hash-count val)))
      (hash-display val)
      (safe-display val)))

;; Children of an in-memory store hash: key → value, value expandable if itself
;; structured.  Iterate in a stable key order so the panel is deterministic.
(define (hash-children h)
  (for/list ([k (in-list (sort (hash-keys h) string<? #:key ~a))])
    (define val (hash-ref h k))
    (make-variable (~a k) (child-value-display val) (infer-type-string val) val)))

;; Children of a record value: one variable per field.
(define (record-children rv)
  (define fields (record-value-fields rv))
  (for/list ([(k val) (in-hash fields)])
    (make-variable (~a k) (child-value-display val) (infer-type-string val) val)))

;; Children of a list: indexed elements.
(define (list-children lst)
  (for/list ([el (in-list lst)] [i (in-naturals)])
    (make-variable (format "[~a]" i) (child-value-display el) (infer-type-string el) el)))

;; Collect the domain objects present in the paused frame's locals as a list of
;; (name . value) pairs, for the Domain scope.
(define (domain-locals locals)
  (filter (lambda (pair)
            (and (pair? pair) (symbol? (car pair)) (domain-object? (cdr pair))))
          locals))

;; ── DAP command dispatch ──────────────────────────────────────────────────────

(define (handle-initialize req)
  (log! "handle-initialize")
  (dap-response req #t
    (hasheq 'supportsConfigurationDoneRequest       #t
            'supportsVariablesRequest               #t
            'supportsSingleStepRequest              #t
            'supportsStepInTargetsRequest           #f
            'supportsConditionalBreakpoints         #t
            'supportsHitConditionalBreakpoints      #t))
  (dap-event "initialized" (hasheq)))

(define (handle-set-breakpoints req)
  (let* ([args (hash-ref req 'arguments (hasheq))]
         [source (hash-ref args 'source (hasheq))]
         [path (hash-ref source 'path "")]
         [bps (hash-ref args 'breakpoints '())])
    ;; Carry the full {line, condition, hitCondition} per breakpoint as bp-records
    ;; (see checkpoint.rkt) so conditional / hit-conditional breakpoints can be
    ;; evaluated at the checkpoint.  A blank/absent condition becomes #f inside
    ;; make-bp-record.  An empty breakpoints list clears the file's entry so a
    ;; stale conditional record can never linger.
    (define records
      (map (lambda (bp)
             (make-bp-record (hash-ref bp 'line 0)
                             (hash-ref bp 'condition #f)
                             (hash-ref bp 'hitCondition #f)))
           bps))
    (log! "setBreakpoints: path=" path " records="
          (~a (map (lambda (r) (list (bp-record-line r)
                                     (bp-record-condition r)
                                     (bp-record-hit-condition r)))
                   records)))
    (if (null? records)
        (hash-remove! breakpoints path)
        (hash-set! breakpoints path records))
    (dap-response req #t
      (hasheq 'breakpoints
              (map (lambda (r)
                     (hasheq 'verified #t 'line (bp-record-line r)))
                   records)))))

;; Pending launch: compile during launch, start program during configurationDone.
;; This ensures setBreakpoints messages are processed before the program runs.
(define pending-compiled (box #f))
(define pending-mode     (box "program"))
(define pending-program  (box ""))

(define (handle-configuration-done req)
  (dap-response req #t (hasheq))
  ;; NOW start the program — all setBreakpoints have already been processed.
  (define compiled (unbox pending-compiled))
  (define mode     (unbox pending-mode))
  (define program  (unbox pending-program))
  (when compiled
    (with-handlers
        ([exn:fail?
          (lambda (e)
            (dap-event "output"
              (hasheq 'category "stderr"
                      'output (format "[dbg] FATAL during launch: ~a\n" (exn-message e))))
            (dap-event "exited" (hasheq 'exitCode 1))
            (dap-event "terminated" (hasheq)))])
      (launch-program compiled mode)
      (dap-event "process" (hasheq 'name program 'isLocalProcess #t)))))

;; Shared launch/attach preparation: compile the .tesl with --debug and stage it
;; for configurationDone.  `verb` is "launch"/"attach" purely for log/console text.
(define (prepare-session! req verb)
  (let* ([args      (hash-ref req 'arguments (hasheq))]
         [program   (hash-ref args 'program "")]
         [mode      (hash-ref args 'mode "program")]
         [test-name (hash-ref args 'testName #f)])
    (dap-response req #t (hasheq))
    (with-handlers
        ([exn:fail?
          (lambda (e)
            (dap-event "output"
              (hasheq 'category "stderr"
                      'output (format "[dbg] FATAL: ~a\n" (exn-message e))))
            (dap-event "exited" (hasheq 'exitCode 1))
            (dap-event "terminated" (hasheq)))])

      (log! "handle-" verb ": program=" program " mode=" mode " test-name=" test-name)
      ;; Record the absolute source path for the compile-time proof/type overlay.
      ;; It must match the file string the emitter bakes into thsl-src! (which is
      ;; also path->complete-path) so binding line numbers line up.
      (when (non-empty-string? program)
        (set-box! current-program-path
                  (path->string (path->complete-path (string->path program)))))
      (dap-event "output" (hasheq 'category "console"
        'output (format "[dbg] === Tesl Debug Session (~a) ===\n[dbg] File: ~a\n[dbg] Mode: ~a~a\n"
                        verb program mode
                        (if test-name (format "\n[dbg] Test: ~a" test-name) ""))))

      (define tesl (find-tesl-binary))
      (dap-event "output" (hasheq 'category "console"
        'output (format "[dbg] Compiler: ~a\n" (or tesl "NOT FOUND — set TESL_COMPILER"))))
      (unless tesl (error "tesl compiler binary not found"))

      (dap-event "output" (hasheq 'category "console"
        'output (format "[dbg] Running: tesl --debug~a ...\n" (if test-name (format " --test-name ~s" test-name) ""))))
      (define compiled (compile-debug program #:test-name test-name))
      (dap-event "output" (hasheq 'category "console"
        'output (format "[dbg] Compiled OK → ~a\n[dbg] Waiting for breakpoints...\n" compiled)))

      ;; Store for configurationDone — don't start yet
      (set-box! pending-compiled compiled)
      (set-box! pending-mode mode)
      (set-box! pending-program program))))

(define (handle-launch req) (prepare-session! req "launch"))

;; DAP `attach`.  Tesl programs are debugged IN-PROCESS (the debuggee is loaded
;; via dynamic-require into this adapter's own Racket runtime — there is no
;; separate OS process to attach to), so a remote/PID attach is out of scope and
;; would be unbounded.  Instead we support the bounded, useful case: attach
;; behaves like launch for a given `program` path — the client may use an
;; "attach" configuration (e.g. to skip a build task or to reuse a launch.json
;; attach entry) and still get full breakpoint/step/variable debugging.  This
;; keeps client wiring trivial (same arguments as launch) while honouring the DAP
;; attach request rather than rejecting it.
(define (handle-attach req) (prepare-session! req "attach"))

(define (handle-threads req)
  (dap-response req #t
    (hasheq 'threads (list (hasheq 'id 1 'name "main")))))

(define (handle-stack-trace req)
  (let ([evt (unbox last-stopped-event)])
    (log! "stackTrace: evt=" (~a evt))
    (if evt
        (let* ([file-path (hash-ref evt 'file "")]
               [_ (log! "stackTrace: file-path=[" file-path "] line=" (hash-ref evt 'line 0))]
               [file-name (if (non-empty-string? file-path)
                              (path->string (file-name-from-path file-path))
                              "unknown")])
          (dap-response req #t
            (hasheq 'stackFrames
                    (list (hasheq 'id 1
                                  'name file-name
                                  'line (hash-ref evt 'line 0)
                                  'column 1  ; DAP is 1-based
                                  'source (hasheq 'name file-name
                                                  'path file-path)))
                    'totalFrames 1)))
        (dap-response req #t (hasheq 'stackFrames '() 'totalFrames 0)))))

(define (handle-scopes req)
  ;; A scopes request marks the start of inspecting a fresh stop frame — reset the
  ;; structured-variables registry so child refs from the previous pause can't be
  ;; reused (DAP clients request scopes before variables on each stop).
  (reset-varrefs!)
  (define evt    (unbox last-stopped-event))
  (define locals (if evt (hash-ref evt 'locals '()) '()))
  ;; Advertise the Domain scope when there are domain objects in scope OR anywhere
  ;; in the global registry (the full live domain state) — so queues/caches/SSE
  ;; channels/email outboxes/worker pools surface even when no local binds them.
  (define has-domain? (or (pair? (domain-locals locals))
                          (pair? (domain-registry-objects))))
  ;; SQL scope (task #43): advertise it ONLY when a SQL statement ran or is pending
  ;; on this pause (so the panel isn't cluttered with an empty scope otherwise).
  (define has-sql? (and (current-sql-capture-record) #t))
  (dap-response req #t
    (hasheq 'scopes
            (append
             (list (hasheq 'name "Locals"
                           'variablesReference 1
                           'expensive #f))
             ;; Only advertise the Domain scope when there are live domain objects
             ;; (in scope or globally registered), so the panel isn't cluttered for
             ;; plain functions with no domain state at all.
             (if has-domain?
                 (list (hasheq 'name "Domain"
                               'variablesReference 2
                               'expensive #f))
                 '())
             ;; SQL scope shows exactly what the driver runs when paused on/at a
             ;; query; omitted entirely when no SQL ran/pending on this thread.
             (if has-sql?
                 (list (hasheq 'name "SQL"
                               'variablesReference 3
                               'expensive #f))
                 '())))))

;; Build the Locals-scope variable list from the paused frame.
(define (locals->variables locals line)
  (filter-map
   (lambda (pair)
     ;; Guard: each pair must be a cons of (symbol . value)
     (and (pair? pair)
          (symbol? (car pair))
          (let* ([var-name  (symbol->string (car pair))]
                 ;; Skip compiler-generated names (underscore, tesl_ prefix)
                 [user-var? (and (not (string=? var-name "_"))
                                 (not (string-prefix? var-name "tesl_")))]
                 [raw-val   (cdr pair)]
                 [display   (safe-display raw-val)]
                 ;; PROOF/TYPE OVERLAY: prefer the compile-time type (which
                 ;; carries the proof annotation) over the runtime-inferred
                 ;; bare type.  Falls back to runtime inference if the
                 ;; compiler has no binding for this name at this line.
                 [overlay   (overlay-binding-type var-name line)]
                 [type-str  (or overlay (infer-type-string raw-val))]
                 ;; If the type carries a proof (`:::`), fold it into the
                 ;; value column too, so it reads e.g. "8080 : Int ::: ValidPort
                 ;; port" even in clients that don't surface the type column.
                 [has-proof? (and (string? type-str)
                                  (regexp-match? #rx":::" type-str))]
                 [value-str (if has-proof?
                                (string-append display " : " type-str)
                                display)])
            (and user-var?
                 ;; make-variable allocates a child varref for structured values
                 ;; (records / lists / domain objects) so they expand in the panel.
                 (make-variable var-name value-str type-str raw-val)))))
   locals))

;; One DAP variable hash for a domain object, labelled `label`.  Allocates a child
;; varref so the object expands to its fields in the panel.  (registry-object-label
;; and domain-registry-objects are imported from domain-inspect.rkt.)
(define (domain-object-variable label v)
  (hasheq 'name               label
          'value              (domain-object-summary v)
          'type               (~a (domain-struct-name v))
          'variablesReference (alloc-varref! (lambda () (domain-object-children v)))
          'presentationHint   (hasheq 'kind "data")))

;; Build the Domain-scope variable list.  Merges TWO sources, de-duped by eq?:
;;   1. domain objects bound in the paused frame's LOCALS (labelled by their
;;      Tesl variable name), and
;;   2. every domain object in the GLOBAL registry (labelled by struct + name),
;;      so queues/caches/SSE-channels/email-outboxes/worker-pools are visible even
;;      when the paused function does NOT take them as parameters.
;; Locals win the label when an object appears in both (so it is shown once).
(define (domain->variables locals)
  (define local-objs (domain-locals locals))                  ; (listof (name . spec))
  (define local-specs (map cdr local-objs))
  (append
   ;; 1. Locals, labelled by their variable name.
   (map (lambda (pair) (domain-object-variable (symbol->string (car pair)) (cdr pair)))
        local-objs)
   ;; 2. Registry objects not already shown as a local (eq? de-dup).
   (filter-map
    (lambda (spec)
      (and (not (memq spec local-specs))
           (domain-object-variable (registry-object-label spec) spec)))
    (domain-registry-objects))))

;; ── SQL transparency scope (task #43) ──────────────────────────────────────────
;;
;; When paused on/at a SQL statement, a dedicated "SQL" scope shows EXACTLY what
;; the driver runs — no "SQL magic".  The capture is recorded per-thread by
;; dsl/sql.rkt (debug-gated, fail-open) and read here for the PAUSED thread (the
;; program thread), with a most-recent-across-threads fallback so a query a
;; now-frozen worker ran just before the stop is still visible.  All rendering is
;; fail-open: any error yields no scope rather than crashing the adapter.

;; The SQL capture to display for the current pause, or #f if none ran/pending.
(define (current-sql-capture-record)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define pt (unbox program-thread))
    (or (and pt (sql-capture-for-thread pt))
        (most-recent-sql-capture))))

;; A short, human type tag for a bound param's runtime db-value.  Params are the
;; ALREADY-ENCODED db-values dsl/sql.rkt hands the driver (strings, numbers,
;; sql-null, JSON strings for ADTs), so we tag by Racket type.  Never raises.
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

;; Escape a runtime db-value into a SQL literal for the READ-ONLY preview.  This
;; is NEVER executed — it exists only so a human can read the statement with its
;; values folded in.  Strings/JSON are single-quoted with '' doubling (standard
;; SQL escaping); NULL/numbers/booleans render bare.  Never raises.
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

;; Substitute $1,$2… placeholders in the parameterized SQL with the escaped
;; literals, producing a read-only preview string.  Replaces longest indices
;; first ($10 before $1) so no prefix-collision corrupts the text.  Never raises.
(define (sql-inline-preview sql params)
  (with-handlers ([(lambda (_) #t) (lambda (_) sql)])
    (define indexed
      (sort
       (for/list ([p (in-list params)] [i (in-naturals 1)]) (cons i p))
       > #:key car))
    (for/fold ([s sql]) ([pair (in-list indexed)])
      (string-replace s (format "$~a" (car pair)) (sql-escape-literal (cdr pair))))))

;; One DAP variable per bound param, ordered $1..$N, each expandable to its
;; type + raw value.
(define (sql-param-variables params)
  (for/list ([p (in-list params)] [i (in-naturals 1)])
    (define tag (sql-param-type-tag p))
    (make-variable (format "$~a" i)
                   (format "~a : ~a" (safe-display p) tag)
                   tag
                   p)))

;; Build the SQL-scope variable list from a capture record.  Order: the exact
;; parameterized statement, the table/op, the ordered params (expandable), the
;; clearly-labelled read-only preview, and the row count if already executed.
(define (sql->variables cap)
  (with-handlers ([exn:fail? (lambda (e)
                               (log! "sql->variables error: " (exn-message e))
                               '())])
    (define sql      (hash-ref cap 'sql ""))
    (define params   (hash-ref cap 'params '()))
    (define table    (hash-ref cap 'table #f))
    (define op       (hash-ref cap 'op #f))
    (define status   (hash-ref cap 'status 'pending))
    (define rowcount (hash-ref cap 'row-count #f))
    (define param-ref
      (if (pair? params)
          (alloc-varref! (lambda () (sql-param-variables params)))
          0))
    (append
     (list
      (hasheq 'name "sql"
              'value sql
              'type "parameterized ($1,$2…)"
              'variablesReference 0
              'presentationHint (hasheq 'kind "data"))
      (hasheq 'name "table"
              'value (or table "(unknown)")
              'type "" 'variablesReference 0)
      (hasheq 'name "operation"
              'value (if op (~a op) "(unknown)")
              'type "" 'variablesReference 0)
      (hasheq 'name "params"
              'value (format "~a bound param(s)" (length params))
              'type "ordered, typed"
              'variablesReference param-ref
              'presentationHint (hasheq 'kind "data"))
      (hasheq 'name "preview (not executed; DB receives the parameterized form)"
              'value (sql-inline-preview sql params)
              'type "read-only; escaped"
              'variablesReference 0
              'presentationHint (hasheq 'kind "data"))
      (hasheq 'name "status"
              'value (~a status)
              'type "" 'variablesReference 0))
     ;; Row count only once the statement has actually executed (and is known).
     (if (and (eq? status 'executed) (exact-nonnegative-integer? rowcount))
         (list (hasheq 'name "row-count"
                       'value (number->string rowcount)
                       'type "Int" 'variablesReference 0))
         '()))))

(define (handle-variables req)
  (let* ([args   (hash-ref req 'arguments (hasheq))]
         [ref    (hash-ref args 'variablesReference 1)]
         [evt    (unbox last-stopped-event)]
         [locals (if evt (hash-ref evt 'locals '()) '())]
         [line   (if evt (hash-ref evt 'line 0) 0)])
    ;; Diagnostic: log the raw locals so mismatches are visible when TESL_DAP_LOG is on.
    (log! "handle-variables: ref=" ref " " (length locals) " locals @ line " line "; raw=" (~a locals))
    (define vars
      (cond
        [(= ref 1) (locals->variables locals line)]
        [(= ref 2) (domain->variables locals)]
        ;; ref 3: the SQL scope (task #43) — exactly what the driver runs.  A #f
        ;; capture (the scope wasn't advertised) yields [], never an error.
        [(= ref 3) (let ([cap (current-sql-capture-record)])
                     (if cap (sql->variables cap) '()))]
        ;; ≥100: a structured child ref allocated by make-variable.  Guard with
        ;; the registry so a stale/unknown ref returns [] instead of erroring.
        [(hash-has-key? varref-registry ref)
         (with-handlers ([exn:fail? (lambda (e)
                                      (log! "variables: child thunk error: " (exn-message e))
                                      '())])
           ((hash-ref varref-registry ref)))]
        [else '()]))
    (dap-response req #t (hasheq 'variables vars))))

(define (handle-continue req)
  (resume! 'continue)
  (dap-response req #t (hasheq 'allThreadsContinued #t)))

(define (handle-next req)
  ;; Step over: resume, but pause at next thsl-src! in same file.
  (let ([evt (unbox last-stopped-event)])
    (when evt
      (set-box! step-next-file (hash-ref evt 'file #f))))
  (resume! 'step-over)
  (dap-response req #t (hasheq 'allThreadsContinued #t)))

(define (handle-step-in req)
  ;; Step into: pause at the very next thsl-src! call (any file).
  (set-box! step-into-next? #t)
  (resume! 'step-in)
  (dap-response req #t (hasheq 'allThreadsContinued #t)))

;; Step out: Tesl's checkpoint model is a flat per-statement stream (no call-stack
;; frames in the runtime), so there is no enclosing frame to run to completion.  We
;; therefore treat stepOut as a plain resume — equivalent to continue — which also
;; guarantees the paused bp thread is released so STOP-THE-WORLD thaws the frozen
;; background threads (leaving stepOut unhandled would strand them suspended).
(define (handle-step-out req)
  (resume! 'continue)
  (dap-response req #t (hasheq 'allThreadsContinued #t)))

;; VSCodium sends 'source' when it wants file content from the adapter.
;; We read the .tesl file from disk and return it so the editor can display it.
(define (handle-source req)
  (let* ([args (hash-ref req 'arguments (hasheq))]
         [source (hash-ref args 'source (hasheq))]
         [path (hash-ref source 'path "")]
         [source-ref (hash-ref args 'sourceReference 0)]
         [_ (log! "handle-source: path=[" path "] sourceRef=" source-ref " source=" (~a source))])
    (if (and (non-empty-string? path) (file-exists? path))
        (dap-response req #t
          (hasheq 'content (file->string path)
                  'mimeType "text/plain"))
        (dap-response req #f
          (hasheq 'message (format "Source not found: ~a" path))))))

(define (handle-disconnect req)
  (dap-response req #t (hasheq))
  ;; Wake up a paused thread (if any) so the process can exit cleanly, then exit.
  ;; resume! is a no-op when not paused, so this never blocks.
  (resume! 'continue)
  (dap-event "terminated" (hasheq))
  (exit 0))

(define (dispatch req)
  (let ([cmd (hash-ref req 'command "")])
    (log! "dispatch: " cmd)
    (cond
      [(equal? cmd "initialize")       (handle-initialize req)]
      [(equal? cmd "setBreakpoints")   (handle-set-breakpoints req)]
      [(equal? cmd "configurationDone")(handle-configuration-done req)]
      [(equal? cmd "launch")           (handle-launch req)]
      [(equal? cmd "attach")           (handle-attach req)]
      [(equal? cmd "threads")          (handle-threads req)]
      [(equal? cmd "stackTrace")       (handle-stack-trace req)]
      [(equal? cmd "scopes")           (handle-scopes req)]
      [(equal? cmd "variables")        (handle-variables req)]
      [(equal? cmd "continue")         (handle-continue req)]
      [(equal? cmd "next")             (handle-next req)]
      [(equal? cmd "stepIn")           (handle-step-in req)]
      [(equal? cmd "stepOut")          (handle-step-out req)]
      [(equal? cmd "source")           (handle-source req)]
      [(equal? cmd "disconnect")       (handle-disconnect req)]
      [else
       ;; Unknown command: respond with empty success to keep the session alive.
       (dap-response req #t (hasheq))])))

;; ── In-module tests (task #44: DEEP-INSPECT raw hashes) ─────────────────────────
;;
;; Exercises the internal make-variable / hash-children / hash-summary helpers
;; directly (they are not exported), proving a NESTED RAW HASH — a queue JOB
;; entry {status, payload, attempts} or an email entry — is now drillable rather
;; than rendered as a single #hash(...) blob, and that a record-valued payload
;; drills on into its fields.  This submodule never runs the stdin message loop
;; (that lives in `module+ main`), so `raco test` cannot block.
(module+ test
  (require rackunit
           (only-in tesl/dsl/types record-value))

  ;; A queue JOB entry whose payload is a RECORD value (drills further), exactly
  ;; the shape define-queue stores: id → {status, payload, attempts}.
  (define payload-record
    (record-value 'Order 'order-identity (hash 'amount 4200 'currency "USD")))
  (define job-entry
    (hash 'status 'pending 'payload payload-record 'attempts 0))

  (test-case "make-variable on a non-empty raw hash yields a drillable child ref"
    (reset-varrefs!)
    (define v (make-variable "job-1" (hash-display job-entry) "Hash" job-entry))
    (check-true (> (hash-ref v 'variablesReference) 0)
                "a nested non-empty hash must be expandable")
    (check-true (hash-has-key? varref-registry (hash-ref v 'variablesReference))
                "its child ref must be registered"))

  (test-case "make-variable on an EMPTY hash is NOT expandable (no dead ref)"
    (reset-varrefs!)
    (define v (make-variable "empty" (hash-display (hash)) "Hash" (hash)))
    (check-equal? (hash-ref v 'variablesReference) 0))

  (test-case "hash-children returns the status / payload / attempts children"
    (reset-varrefs!)
    (define kids (hash-children job-entry))
    (define names (map (lambda (k) (hash-ref k 'name)) kids))
    (check-not-false (member "status" names) "status child present")
    (check-not-false (member "payload" names) "payload child present")
    (check-not-false (member "attempts" names) "attempts child present"))

  (test-case "the record-valued payload child drills FURTHER into its fields"
    (reset-varrefs!)
    (define kids (hash-children job-entry))
    (define payload-var
      (for/or ([k (in-list kids)]) (and (equal? (hash-ref k 'name) "payload") k)))
    (check-true (and payload-var #t) "payload child exists")
    (define pref (hash-ref payload-var 'variablesReference))
    (check-true (> pref 0) "payload (a record) must itself be expandable")
    (define payload-kids ((hash-ref varref-registry pref)))
    (define pnames (map (lambda (k) (hash-ref k 'name)) payload-kids))
    (check-not-false (member "amount" pnames) "record field amount drilled")
    (check-not-false (member "currency" pnames) "record field currency drilled"))

  (test-case "hash value display is a compact summary, NOT a raw #hash dump"
    (define s (hash-display job-entry))
    (check-false (regexp-match? #rx"#hash" s) "no raw #hash blob")
    ;; Recognised job shape → friendly label by id/status (here no id key, so by status).
    (check-true (string-contains? s "pending") "status surfaced in the summary line"))

  (test-case "an email-shaped hash gets a friendly to/subject/status label"
    (define email (hash 'to "a@x" 'subject "Welcome" 'body "hi" 'status 'sent))
    (define s (hash-display email))
    (check-true (string-contains? s "a@x") "recipient surfaced")
    (check-true (string-contains? s "Welcome") "subject surfaced")
    (check-true (string-contains? s "sent") "status surfaced"))

  (test-case "hash-summary truncates to the first few keys with an ellipsis"
    (define big (hash 'a 1 'b 2 'c 3 'd 4 'e 5))
    (define s (hash-summary big))
    (check-true (string-contains? s "…") "large hashes are truncated")
    (check-false (regexp-match? #rx"#hash" s) "no raw blob"))

  (test-case "hash-summary / hash-display never raise on hostile input"
    ;; A hash whose value errors when displayed must fall back, never throw.
    (check-not-exn (lambda () (hash-summary (hash 'k (hash))))) ; empty inner hash
    (check-not-exn (lambda () (hash-display (hash)))))

  ;; ── SQL transparency render helpers (task #43) ──────────────────────────────
  (test-case "sql-inline-preview folds escaped literals into the parameterized text"
    (check-equal? (sql-inline-preview "SELECT * FROM users WHERE id = $1 AND name = $2"
                                      (list 42 "ada"))
                  "SELECT * FROM users WHERE id = 42 AND name = 'ada'"))
  (test-case "sql-inline-preview substitutes $10 before $1 (no prefix collision)"
    (check-equal? (sql-inline-preview "$1 $10" (list 1 2 3 4 5 6 7 8 9 10)) "1 10"))
  (test-case "sql-escape-literal doubles single quotes (the read-only preview can't inject)"
    (check-equal? (sql-escape-literal "O'Brien") "'O''Brien'")
    (check-equal? (sql-escape-literal 7) "7")
    (check-equal? (sql-escape-literal #t) "TRUE"))
  (test-case "sql-param-type-tag tags runtime db-values"
    (check-equal? (sql-param-type-tag 42) "Int")
    (check-equal? (sql-param-type-tag "x") "String")
    (check-equal? (sql-param-type-tag #f) "Bool")))

;; ── Main loop ─────────────────────────────────────────────────────────────────
;;
;; The stdin/stdout message loop lives in the `main` submodule so that
;; `racket dap-server.rkt` (and the launcher's `exec racket … dap-server.rkt`)
;; still runs it, while `raco test dsl/debug/dap-server.rkt` runs ONLY the
;; in-module `test` submodule (below) and never blocks reading stdin.
(module+ main
  (log! "=== entering message loop ===")
  (let loop ()
    (log! "waiting for next message...")
    (let ([msg (read-dap-msg)])
      (log! "read-dap-msg returned: " (if (eof-object? msg) "EOF" (hash-ref msg 'command "?")))
      (unless (eof-object? msg)
        (dispatch msg)
        (loop))))
  (log! "=== message loop exited (EOF) ==="))
