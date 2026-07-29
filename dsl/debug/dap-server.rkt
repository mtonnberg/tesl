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
;; (The GDP/record value predicates this module used to import for its own
;; infer-type-string + expandability tests are gone: both questions are answered
;; by dsl/debug/value-tree.rkt now — see the require below.)

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
                  sql-capture-for-thread))
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
                  registry-object-label
                  domain-registry-objects))

;; THE structured-value renderer, shared with headless-inspect.rkt (and hence with
;; this adapter's own ATTACH mode, which consumes what that streams).  `value-children`
;; is the single answer to "what can this value be expanded into" and `value-display`
;; / `value-type` the single answer to how it reads — see dsl/debug/value-tree.rkt's
;; header for the drift this replaced.  Everything below builds DAP variables on top
;; of those three functions and nothing else.
(require (only-in tesl/dsl/debug/value-tree
                  value-children
                  value-display
                  value-type
                  child-display
                  node-children
                  hash-display))

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

;; Run the tesl CLI with [args], capturing stdout/stderr; returns (values code out err).
(define (run-tesl-capture tesl args)
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f tesl args))
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait proc)
  (define exit-code (subprocess-status proc))
  (close-input-port stdout)
  (close-output-port stdin)
  (close-input-port stderr)
  (values exit-code out err))

;; Compile a .tesl file with --debug, write output to a temp .rkt, return the path.
;;
;; Multi-module: the emitter requires local imports as RELATIVE `(file "dep.rkt")`
;; paths, resolved against the requiring module's own directory.  So the compiled
;; main module must not sit alone in the system temp dir (the old behaviour —
;; loading it died with `open-input-file: cannot open module file` on the first
;; local import).  Instead, emit into a fresh temp DIRECTORY and compile every
;; transitive local import (from `tesl --deps`) into it as a sibling .rkt —
;; debug-instrumented too, so breakpoints set in imported modules also bind.
(define (compile-debug program-path #:test-name [test-name #f] #:test-kind [test-kind #f])
  (define tesl (find-tesl-binary))
  (unless tesl
    (error "tesl binary not found; set TESL_COMPILER env var or install via nix"))
  ;; Ensure absolute path so thsl-src file strings match VSCode's setBreakpoints paths.
  (define abs-path (path->string (path->complete-path (string->path program-path))))
  (define temp-dir (make-temporary-directory "tesl-debug-~a"))
  ;; Transitive local imports.  Tolerate a tesl without the --deps verb (older
  ;; wrapper): a single-module program debugs fine with zero deps.
  (define deps
    (let-values ([(code out _err) (run-tesl-capture tesl (list "--deps" abs-path))])
      (if (= code 0)
          (filter (lambda (l) (and (non-empty-string? l) (not (equal? l abs-path))))
                  (map string-trim (string-split out "\n")))
          '())))
  (define (emit-rkt! src-path args)
    (define-values (code out err) (run-tesl-capture tesl args))
    (unless (= code 0)
      (error (format "tesl --debug failed for ~a:\n~a" src-path err)))
    (define rkt (build-path temp-dir
                            (path-replace-extension (file-name-from-path src-path) ".rkt")))
    (call-with-output-file rkt #:exists 'replace
      (lambda (o) (display out o)))
    (path->string rkt))
  (for ([dep (in-list deps)])
    (define dep-abs (path->string (path->complete-path (string->path dep))))
    (emit-rkt! dep-abs (list "--debug" dep-abs)))
  ;; Main module: --test-name/--test-kind pin the single selected test block.
  (emit-rkt! abs-path
             (cond
               [(and test-name test-kind)
                (list "--debug" "--test-name" test-name "--test-kind" test-kind abs-path)]
               [test-name (list "--debug" "--test-name" test-name abs-path)]
               [else (list "--debug" abs-path)])))

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

;; Best-effort TCP reachability probe with a hard timeout. Used to fail FAST with
;; a clear message instead of letting the debuggee hang inside postgresql-connect
;; — on some platforms (e.g. WSL2) a connect to a port with no listener does not
;; refuse promptly, it hangs, so the debug session would silently stall at the
;; `with database` line with no error. Returns #t iff a TCP connection opened
;; within `timeout-secs`.
(define (tcp-port-reachable? host port [timeout-secs 2.0])
  (define ch (make-channel))
  (define worker
    (thread (lambda ()
      (with-handlers ([(lambda (_) #t) (lambda (_) (channel-put ch #f))])
        (define-values (in out) (tcp-connect host port))
        (close-input-port in)
        (close-output-port out)
        (channel-put ch #t)))))
  (define result (sync/timeout timeout-secs ch))
  (kill-thread worker)
  (eq? result #t))

;; If the launch env points the app at a database (TESL_POSTGRES_HOST/PORT — set
;; from .vscode/launch.json), check it is actually reachable BEFORE running the
;; program. If not, emit actionable guidance and end the session cleanly rather
;; than hang/crash silently at `with database`. Returns #t to proceed, #f to abort.
(define (db-preflight-ok?)
  (define host (getenv "TESL_POSTGRES_HOST"))
  (define port-str (getenv "TESL_POSTGRES_PORT"))
  (define port (and port-str (string->number port-str)))
  (cond
    [(not (and host port (exact-integer? port))) #t]   ; no DB configured → nothing to check
    [(tcp-port-reachable? host port) #t]
    [else
     (dap-event "output"
       (hasheq 'category "stderr"
               'output (format
                 (string-append
                  "[dbg] ── Cannot reach the database at ~a:~a — not starting the program.\n"
                  "[dbg]    The app would block/fail at its `with database` block. Fix it by:\n"
                  "[dbg]      • starting the database — managed project:  tesl db start\n"
                  "[dbg]      • or correcting TESL_POSTGRES_* in .vscode/launch.json\n"
                  "[dbg]        (host/port/user/database must match a running server;\n"
                  "[dbg]         a managed port can differ from the default — see `tesl db status`).\n")
                 host port)))
     (dap-event "exited" (hasheq 'exitCode 1))
     (dap-event "terminated" (hasheq))
     #f]))

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

  ;; Enable the PROCESS-WIDE debug switch (not just the thread-local
  ;; `debug-enabled?` parameter): a `serve`d app handles each request on a fresh
  ;; web-server thread that does NOT inherit the program thread's parameterize, so
  ;; without this, breakpoints inside handlers / SQL never fired once `serve` was
  ;; running.  Set before the program thread spawns so every descendant sees it.
  (set-debug-active! #t)

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
                     "No main found — add a 'main() -> App = App { ... }' entry point or switch to test mode."))
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
    ;; Preflight the database connection so a down/misconfigured DB yields a clear
    ;; message instead of a silent hang at `with database`.
    (when (db-preflight-ok?)
    (dap-event "output" (hasheq 'category "console"
      'output (format "[dbg] Launching (~a) with debug-enabled?=#t ...\n" submod-sym)))
    (define t
      (thread
        (lambda ()
          (parameterize ([debug-enabled? #t])
            (with-handlers
                ([exn:fail?
                  (lambda (e)
                    (define msg (exn-message e))
                    (dap-event "output"
                      (hasheq 'category "stderr"
                              'output (format "[dbg] Runtime error: ~a\n" msg)))
                    ;; Turn an opaque DB connection failure into actionable guidance
                    ;; instead of a bare stack trace + silent session close. This is
                    ;; the common "stepped onto `with database` and it crashed" case.
                    (when (regexp-match?
                           #px"(?i:tcp-connect|connection (failed|refused)|postgresql-connect|errno=111|database .* does not exist)"
                           msg)
                      (dap-event "output"
                        (hasheq 'category "stderr"
                                'output (string-append
                                  "[dbg] ── The app could not connect to its database. Check that:\n"
                                  "[dbg]    • the database is running — for a managed project run:  tesl db start\n"
                                  "[dbg]    • TESL_POSTGRES_* in .vscode/launch.json point at it\n"
                                  "[dbg]      (host/port/user/database must match the running server)\n"
                                  "[dbg]    • the port matches `tesl db status` (a managed port can differ\n"
                                  "[dbg]      from the launch.json default if it was relocated).\n"))))
                    (dap-event "exited" (hasheq 'exitCode 1))
                    (dap-event "terminated" (hasheq)))])
              (dap-event "output" (hasheq 'category "console"
                'output "[dbg] Program thread started.\n"))
              (dynamic-require require-target #f)
              (dap-event "output" (hasheq 'category "console"
                'output "[dbg] Program thread finished.\n"))
              (dap-event "exited" (hasheq 'exitCode 0))
              (dap-event "terminated" (hasheq)))))))
    (set-box! program-thread t)))))  ; close: when db-preflight / when submod / parameterize / define

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

;; Was a hand-copied twin of headless-inspect's version; both are now the single
;; `value-type` in value-tree.rkt.  Alias kept because call sites below read better.
(define infer-type-string value-type)

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

;; ── evaluateName registry (Copy Value / hover / watch) ────────────────────────
;;
;; DAP clients do NOT copy the `value` string they already hold: VSCode/VSCodium's
;; "Copy Value" issues an `evaluate` request for the variable's `evaluateName`
;; (with context "clipboard" when the adapter advertises supportsClipboardContext)
;; and copies THAT response.  This adapter previously implemented no `evaluate`
;; handler at all and answered every unknown command with an empty successful
;; body, so the client copied an empty string — which is why Copy Value silently
;; did nothing, on the SQL preview and on every other variable alike.
;;
;; Rather than expose an expression evaluator (a debugger that can run arbitrary
;; code against a paused production process is a hazard we do not need), every
;; variable we emit registers a stable dotted PATH as its evaluateName, and
;; `evaluate` is a pure lookup in this table.  Nothing is executed.
;;
;; Each entry holds:
;;   display — the (possibly truncated/summarised) string shown in the panel
;;   full    — the COMPLETE untruncated text, which is what a copy must yield
;;   raw     — the underlying value, so a copied composite can still be expanded
(struct eval-entry (display full raw) #:transparent)
(define evalname-registry (make-hash))

(define (reset-varrefs!)
  (hash-clear! varref-registry)
  (hash-clear! evalname-registry)
  (set-box! varref-counter 100))

(define (alloc-varref! thunk)
  (define r (unbox varref-counter))
  (set-box! varref-counter (+ r 1))
  (hash-set! varref-registry r thunk)
  r)

;; Register `path` as an evaluateName for a value and return the path.  The FULL
;; text is safe-display's complete rendering (never the compact hash summary), so
;; copying a large record or a long SQL preview yields the whole thing.
(define (register-evalname! path display-str raw [full #f])
  (when (and (string? path) (non-empty-string? path))
    (hash-set! evalname-registry path
               (eval-entry display-str
                           (or full (full-text-of raw display-str))
                           raw)))
  path)

;; The complete, copy-worthy text for a value: safe-display's full rendering,
;; falling back to the display string if that raises.
(define (full-text-of raw display-str)
  (with-handlers ([(lambda (_) #t) (lambda (_) display-str)])
    (safe-display raw)))

;; A child's evaluateName: `parent.field`, or `parent[3]` for an index (the child
;; name already carries its own brackets), matching how a user would write it.
(define (child-eval-path parent-path child-name)
  (cond
    [(not (and (string? parent-path) (non-empty-string? parent-path))) #f]
    [(string-prefix? child-name "[") (string-append parent-path child-name)]
    [else (string-append parent-path "." child-name)]))

;; Build a single DAP variable hash for a (name, value) pair, allocating a child
;; varref whenever `value-children` says the value has structure.
;;
;; Expandability is NOT decided here any more.  It used to be, by testing the
;; outer Racket representation (record-value? / list? / hash? / domain-object?),
;; which silently excluded every WRAPPED value — a proof-carrying record is a
;; `named-value`, a checked one a `check-ok`, a Money/units one a `newtype-value`,
;; and an ADT payload (`Ok(record)`) matched nothing at all.  Those all *display*
;; as composites, so the panel showed inner structure next to a variable that
;; claimed to have no children: the "just a string, not a tree" bug.  The single
;; `value-children` in value-tree.rkt unwraps before deciding, and
;; tests/dap-value-tree-tests.rkt pins display and expansion to agree.
;;
;; `eval-path` is this variable's dotted evaluateName (see the registry above);
;; #f suppresses registration for synthetic rows that cannot be copied.
(define (make-variable name value-str type-str raw-val [eval-path #f])
  (define kids (value-children raw-val))
  (define path (and eval-path (register-evalname! eval-path value-str raw-val)))
  (define child-ref
    (if (pair? kids)
        (alloc-varref! (lambda () (children->variables raw-val kids path)))
        0))
  (define base
    (hasheq 'name               name
            'value              value-str
            'type               (or type-str "")
            'variablesReference child-ref
            'presentationHint   (hasheq 'kind "data")))
  ;; evaluateName is what the client sends back on Copy Value / hover / watch.
  (if path (hash-set base 'evaluateName path) base))

;; One level of children for `parent`, from the shared enumeration.  `child-display`
;; supplies the live-count labels for a domain object's fields (an SSE channel's
;; listeners read "3 connected client(s)", a store reads "{7 entries}") — the same
;; strings the attach path shows, because both call the same function.
(define (children->variables parent kids parent-path)
  (with-handlers ([exn:fail? (lambda (e)
                               (list (hasheq 'name "<error>" 'value (exn-message e)
                                             'variablesReference 0)))])
    (for/list ([kv (in-list kids)])
      (define cname (car kv))
      (define cval  (cdr kv))
      (make-variable cname
                     (child-display parent cname cval)
                     (value-type cval)
                     cval
                     (child-eval-path parent-path cname)))))

;; Collect the domain objects present in the paused frame's locals as a list of
;; (name . value) pairs, for the Domain scope.
(define (domain-locals locals)
  (filter (lambda (pair)
            (and (pair? pair) (symbol? (car pair)) (domain-object? (cdr pair))))
          locals))

;; ── DAP command dispatch ──────────────────────────────────────────────────────

;; ── ATTACH MODE: proxy to a running `tesl run --debug` process ────────────────
;;
;; Real attach: the debuggee is a SEPARATE OS process started by the user with
;; `tesl run --debug`, exposing the control channel from
;; dsl/debug/control-channel.rkt (unix socket / loopback TCP under
;; <project>/.tesl-stuff/).  In attach mode this adapter does NOT compile or
;; load anything — it is a thin DAP↔control-channel proxy:
;;   setBreakpoints → {"cmd":"set-breakpoints"}     continue/step → resume cmds
;;   stopped events ← the channel's NDJSON stream    disconnect → detach
;; The launch-mode machinery (compile-debug, dynamic-require, in-process
;; domain-registry reads) is untouched and still serves `request:"launch"`.
;;
;; Known v1 limitation, by design: the channel streams locals/domain/SQL
;; ALREADY RENDERED ({name,value,type} strings), so the Variables panel in
;; attach mode is flat — no structured drill-down into records/hashes.  The
;; values shown are the same strings launch mode renders; only expansion is
;; missing.  Deep drill-down needs a varref RPC on the channel (future work).

(define attach-conn (box #f))          ; (cons in out) when attached
(define attach-last-stopped (box #f))  ; last rendered stopped event (jsexpr)

(define (attach-mode?) (and (unbox attach-conn) #t))

(define (attach-send! obj)
  (let ([conn (unbox attach-conn)])
    (when conn
      (with-handlers ([exn:fail? (lambda (e) (log! "attach-send failed: " (exn-message e)))])
        (write-string (jsexpr->string obj) (cdr conn))
        (write-string "\n" (cdr conn))
        (flush-output (cdr conn))))))

;; Resolve the control endpoint from attach args: explicit socket/port win,
;; else <project>/.tesl-stuff/{debug.sock,debug.port}.  `project` defaults to
;; the directory of `program` (so an attach entry can reuse "${file}").
(define (attach-endpoint args)
  (define socket (hash-ref args 'socket #f))
  (define port   (hash-ref args 'port #f))
  (define project
    (or (let ([p (hash-ref args 'project #f)]) (and (non-empty-string? p) p))
        (let ([p (hash-ref args 'program #f)])
          (and (string? p) (non-empty-string? p)
               (path->string (path-only (path->complete-path (string->path p))))))))
  (cond
    [(and (string? socket) (non-empty-string? socket)) (cons 'unix socket)]
    [(exact-positive-integer? port) (cons 'tcp port)]
    [project
     (define dir (build-path project ".tesl-stuff"))
     (define sock (build-path dir "debug.sock"))
     (define pfile (build-path dir "debug.port"))
     (cond
       [(file-exists? sock) (cons 'unix (path->string sock))]
       [(file-exists? pfile)
        (let ([p (string->number (string-trim (file->string pfile)))])
          (and p (cons 'tcp p)))]
       [else #f])]
    [else #f]))

(define (attach-connect! endpoint)
  (case (car endpoint)
    [(unix)
     (define us (dynamic-require 'racket/unix-socket 'unix-socket-connect))
     (us (cdr endpoint))]
    [(tcp) (tcp-connect "127.0.0.1" (cdr endpoint))]))

;; Reader pump: control-channel NDJSON → DAP events.  A stopped line is
;; mirrored into last-stopped-event (file/line only — the shared stackTrace
;; handler reads those) plus attach-last-stopped (rendered locals/domain/sql
;; for the attach variables path).  EOF/detached ends the DAP session but
;; leaves the debuggee serving.
(define (start-attach-reader! in)
  (thread
   (lambda ()
     (let loop ()
       (define line (with-handlers ([exn:fail? (lambda (_e) eof)]) (read-line in 'any)))
       (cond
         [(eof-object? line)
          (log! "attach: channel closed")
          (set-box! attach-conn #f)
          (dap-event "terminated" (hasheq))]
         [else
          (define msg (with-handlers ([exn:fail? (lambda (_e) #f)]) (string->jsexpr line)))
          (when (hash? msg)
            (case (hash-ref msg 'event #f)
              [("stopped")
               (set-box! attach-last-stopped msg)
               (set-box! last-stopped-event
                         (hasheq 'file (hash-ref msg 'file "")
                                 'line (hash-ref msg 'line 0)
                                 'locals '()
                                 'reason (hash-ref msg 'reason "breakpoint")))
               (set-box! paused? #t)
               (dap-event "stopped"
                 (hasheq 'reason (hash-ref msg 'reason "breakpoint")
                         'threadId 1
                         'allThreadsStopped #t
                         'source (hasheq 'path (hash-ref msg 'file ""))
                         'line (hash-ref msg 'line 0)))]
              [("resumed")
               (set-box! paused? #f)
               ;; A timeout/no-client auto-resume also lands here; tell the
               ;; client execution moved on so the UI leaves the paused state.
               (dap-event "continued" (hasheq 'threadId 1 'allThreadsContinued #t))]
              [("detached")
               (set-box! attach-conn #f)
               (dap-event "terminated" (hasheq))]
              [else (void)]))          ; command replies: fire-and-forget
          (loop)])))))

;; ── Attach-mode variables: rebuild the tree from the streamed nodes ───────────
;;
;; The control channel streams each local/domain object as a NESTED node
;; ({name, value, type, children?, truncated?} — see value-tree.rkt), so attach
;; mode gets the same expandable Variables tree launch mode does.  It used to
;; stream flat {name,value,type} rows and this function hardcoded
;; `variablesReference: 0`, which is why every record / list / queue in an
;; attached session was one unexpandable string.
;;
;; Refs are allocated over the RECEIVED nodes rather than over live values (the
;; debuggee is another process — there is nothing local to walk), and the
;; evaluateName registry is populated from the node text so Copy Value works when
;; attached exactly as it does when launching.
(define (node->variable n parent-path)
  (define name  (format "~a" (hash-ref n 'name "")))
  (define value (format "~a" (hash-ref n 'value "")))
  (define kids  (node-children n))
  (define path  (if parent-path (child-eval-path parent-path name) name))
  (when path
    ;; `raw` is #f: there is no local value behind an attached node, so the copy
    ;; text is the streamed string itself (already the full rendering — the
    ;; debuggee applied the same renderer before sending it).
    (hash-set! evalname-registry path (eval-entry value value #f)))
  (define base
    (hasheq 'name name
            'value (if (hash-ref n 'truncated #f)
                       ;; Say so rather than let a clipped tree read as complete.
                       (string-append value "  …(truncated)")
                       value)
            'type (format "~a" (hash-ref n 'type ""))
            'variablesReference
            (if (pair? kids)
                (alloc-varref! (lambda () (nodes->variables kids path)))
                0)
            'presentationHint (hasheq 'kind "data")))
  (if path (hash-set base 'evaluateName path) base))

(define (nodes->variables nodes parent-path)
  (for/list ([n (in-list nodes)] #:when (hash? n))
    (node->variable n parent-path)))

;; Streamed local nodes → DAP variables (top level: no parent path).
(define (rendered->variables rows) (nodes->variables rows #f))

;; Domain scope when attached.  Each bucket entry carries its own `children`
;; tree (queue store entries, per-key SSE listener counts, worker liveness), so
;; queues/caches/channels expand here just as they do in launch mode.
(define (attach-domain-variables)
  (define evt (unbox attach-last-stopped))
  (define dom (and evt (hash-ref evt 'domain #f)))
  (if (hash? dom)
      (for*/list ([bucket '(queues caches sse email workers)]
                  [obj (in-list (hash-ref dom bucket '()))]
                  #:when (hash? obj))
        (define label (format "~a" (hash-ref obj 'label (hash-ref obj 'name bucket))))
        (define kids (node-children obj))
        (define path (register-evalname! label
                                         (format "~a" (hash-ref obj 'summary ""))
                                         #f
                                         (format "~a" (hash-ref obj 'summary ""))))
        (hasheq 'name  label
                'value (format "~a" (hash-ref obj 'summary ""))
                'type  (format "~a" (hash-ref obj 'kind bucket))
                'evaluateName path
                'variablesReference
                (if (pair? kids)
                    (alloc-varref! (lambda () (nodes->variables kids path)))
                    0)
                'presentationHint (hasheq 'kind "data")))
      '()))

;; SQL scope when attached.  Mirrors the launch-mode row set and naming exactly
;; (`sql` / `table` / `operation` / `params` / `preview` / `status`), so the panel
;; does not change shape depending on how the session started, and every row is
;; copyable through the same evaluateName registry.
(define (attach-sql-variables)
  (define evt (unbox attach-last-stopped))
  (define sql (and evt (hash-ref evt 'sql #f)))
  (define (row name value type)
    (hasheq 'name name
            'value value
            'type type
            'variablesReference 0
            'evaluateName (register-evalname! (string-append "sql." name) value #f value)
            'presentationHint (hasheq 'kind "data")))
  (cond
    [(not (hash? sql)) '()]
    [else
     (define (str k [dflt ""]) (format "~a" (hash-ref sql k dflt)))
     (define params (hash-ref sql 'params '()))
     (define param-vars
       (for/list ([p (in-list params)] #:when (hash? p))
         (define idx (hash-ref p 'index 0))
         (define v (format "~a" (hash-ref p 'value "")))
         (hasheq 'name (format "$~a" idx)
                 'value (format "~a : ~a" v (hash-ref p 'type ""))
                 'type (format "~a" (hash-ref p 'type ""))
                 'variablesReference 0
                 'evaluateName (register-evalname! (format "sql.params.$~a" idx) v #f v)
                 'presentationHint (hasheq 'kind "data"))))
     (append
      (list (row "sql" (str 'sql) "parameterized ($1,$2…)")
            (row "table" (str 'table "(unknown)") "")
            (row "operation" (str 'operation "(unknown)") "")
            (hasheq 'name "params"
                    'value (format "~a bound param(s)" (length params))
                    'type "ordered, typed"
                    'variablesReference (if (pair? param-vars)
                                            (alloc-varref! (lambda () param-vars))
                                            0)
                    'presentationHint (hasheq 'kind "data"))
            (row "preview" (str 'preview) "read-only — never executed; escaped")
            (row "status" (str 'status) ""))
      (if (hash-has-key? sql 'row-count)
          (list (row "row-count" (str 'row-count) "Int"))
          '()))]))

(define (handle-initialize req)
  (log! "handle-initialize")
  (dap-response req #t
    (hasheq 'supportsConfigurationDoneRequest       #t
            'supportsVariablesRequest               #t
            'supportsSingleStepRequest              #t
            'supportsStepInTargetsRequest           #f
            'supportsConditionalBreakpoints         #t
            'supportsHitConditionalBreakpoints      #t
            ;; Copy Value: the client resolves a variable's `evaluateName` through
            ;; an `evaluate` request with context "clipboard" and copies THAT
            ;; result — so advertising this is half of making the copy button work
            ;; (handle-evaluate below is the other half).
            'supportsClipboardContext               #t
            ;; Hovering a name in the editor while paused resolves it the same way.
            'supportsEvaluateForHovers              #t))
  (dap-event "initialized" (hasheq)))

(define (handle-set-breakpoints req)
  (let* ([args (hash-ref req 'arguments (hasheq))]
         [source (hash-ref args 'source (hasheq))]
         [path (hash-ref source 'path "")]
         [bps (hash-ref args 'breakpoints '())])
    (when (attach-mode?)
      ;; Proxy: translate the DAP breakpoint rows to the control-channel shape
      ;; (hitCondition → hit) and hand them to the running process.  Replies on
      ;; the channel are fire-and-forget; verification is optimistic exactly
      ;; like launch mode below.
      (attach-send!
       (hasheq 'cmd "set-breakpoints"
               'file path
               'breakpoints
               (for/list ([bp (in-list bps)])
                 (let* ([b (hasheq 'line (hash-ref bp 'line 0))]
                        [b (let ([c (hash-ref bp 'condition #f)])
                             (if (and (string? c) (non-empty-string? c))
                                 (hash-set b 'condition c) b))]
                        [b (let ([h (hash-ref bp 'hitCondition #f)])
                             (if (and (string? h) (non-empty-string? h))
                                 (hash-set b 'hit h) b))])
                   b))))
      (dap-response req #t
        (hasheq 'breakpoints
                (map (lambda (bp) (hasheq 'verified #t 'line (hash-ref bp 'line 0))) bps)))
      (log! "setBreakpoints (attach proxy): path=" path))
    (unless (attach-mode?)
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
                   records))))))

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
         [test-name (hash-ref args 'testName #f)]
         [test-kind (hash-ref args 'testKind #f)])
    (dap-response req #t (hasheq))

    ;; Apply the launch config's `env` to THIS process. The debuggee runs
    ;; in-process (dynamic-require), so it reads env via getenv — and previously
    ;; we ignored `env` entirely, which meant the TESL_POSTGRES_* vars set in
    ;; .vscode/launch.json never reached the program. The app then defaulted to
    ;; localhost:5432, `with database` failed to connect, and the session died at
    ;; that line ("debug crashes after main"). Honor `env` so a managed/existing
    ;; DB config in launch.json actually takes effect.
    (let ([env-hash (hash-ref args 'env (hasheq))])
      (when (hash? env-hash)
        (for ([(k v) (in-hash env-hash)])
          (define key (if (symbol? k) (symbol->string k) (format "~a" k)))
          (when (and (string? key) (non-empty-string? key))
            (putenv key (if (string? v) v (format "~a" v)))))))

    ;; Prefer the EFFECTIVE managed-DB port over a possibly-stale launch.json
    ;; value: `tesl db`/`tesl run` relocate a managed cluster when the configured
    ;; port is taken and persist the choice in <project>/.tesl-postgres/PORT. The
    ;; init-time launch.json bakes the ORIGINAL port, which then no longer matches
    ;; the running server — debug would connect to the wrong (dead) port. If a
    ;; PORT file exists, it wins, so debug targets the same DB as `tesl run`.
    (when (non-empty-string? program)
      (define-values (proj-dir _name _root?)
        (split-path (path->complete-path (string->path program))))
      (when (path? proj-dir)
        (define port-file (build-path proj-dir ".tesl-postgres" "PORT"))
        (when (file-exists? port-file)
          (define raw (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
                        (with-input-from-file port-file read-line)))
          (define m (and (string? raw) (regexp-match #px"[0-9]+" raw)))
          (when m
            (putenv "TESL_POSTGRES_PORT" (car m))
            (unless (getenv "TESL_POSTGRES_HOST") (putenv "TESL_POSTGRES_HOST" "127.0.0.1"))))))
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
      (define compiled (compile-debug program #:test-name test-name #:test-kind test-kind))
      (dap-event "output" (hasheq 'category "console"
        'output (format "[dbg] Compiled OK → ~a\n[dbg] Waiting for breakpoints...\n" compiled)))

      ;; Store for configurationDone — don't start yet
      (set-box! pending-compiled compiled)
      (set-box! pending-mode mode)
      (set-box! pending-program program))))

(define (handle-launch req) (prepare-session! req "launch"))

;; DAP `attach`.  Two shapes:
;;
;; REAL ATTACH (config has `project`, `socket`, or `port`): connect to the
;; control channel of an already-running `tesl run --debug` process and proxy
;; (see the ATTACH MODE section above).  Nothing is compiled or loaded; the
;; debuggee keeps running when the session disconnects.
;;
;; LEGACY ALIAS (config has only `program`, like launch): historical behaviour —
;; attach acts as launch for that program (the debuggee is loaded in-process via
;; dynamic-require).  Kept so existing attach entries in launch.json continue to
;; work unchanged.
(define (handle-attach req)
  (define args (hash-ref req 'arguments (hasheq)))
  (define wants-real-attach?
    (or (let ([p (hash-ref args 'project #f)]) (and (string? p) (non-empty-string? p)))
        (let ([s (hash-ref args 'socket #f)]) (and (string? s) (non-empty-string? s)))
        (exact-positive-integer? (hash-ref args 'port #f))))
  (cond
    [wants-real-attach?
     (define ep (attach-endpoint args))
     (cond
       [(not ep)
        (dap-response req #f
          (hasheq 'message "No debug endpoint found — start the app with `tesl run --debug` first (looked for .tesl-stuff/debug.sock / debug.port)."))
        (dap-event "terminated" (hasheq))]
       [else
        (with-handlers
            ([exn:fail?
              (lambda (e)
                (dap-response req #f
                  (hasheq 'message (format "Cannot attach: ~a — is the app still running?" (exn-message e))))
                (dap-event "terminated" (hasheq)))])
          (define-values (in out) (attach-connect! ep))
          ;; Consume the attached/busy banner synchronously so a busy refusal
          ;; fails the request instead of surfacing as a confusing later event.
          (define hello
            (with-handlers ([exn:fail? (lambda (_e) #f)])
              (string->jsexpr (read-line in 'any))))
          (cond
            [(and (hash? hello) (equal? (hash-ref hello 'event #f) "attached"))
             (set-box! attach-conn (cons in out))
             (start-attach-reader! in)
             (dap-response req #t (hasheq))
             (dap-event "output"
               (hasheq 'category "console"
                       'output (format "[dbg] === Tesl Debug Session (attach) ===\n[dbg] Endpoint: ~a\n[dbg] The app keeps running when you disconnect.\n"
                                       (cdr ep))))]
            [else
             (dap-response req #f
               (hasheq 'message (format "Attach refused by the process: ~a"
                                        (if (hash? hello) (hash-ref hello 'reason "busy") "no banner"))))
             (dap-event "terminated" (hasheq))]))])]
    [else (prepare-session! req "attach")]))

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
  ;; Attach mode: the debuggee is another process, so the in-process registry is
  ;; empty here — decide from the RENDERED domain/sql the channel streamed.
  (define attach-evt (and (attach-mode?) (unbox attach-last-stopped)))
  (define (attach-domain-nonempty?)
    (define dom (and attach-evt (hash-ref attach-evt 'domain #f)))
    (and (hash? dom)
         (for/or ([b '(queues caches sse email workers)])
           (pair? (hash-ref dom b '())))))
  (define has-domain?
    (if (attach-mode?)
        (attach-domain-nonempty?)
        (or (pair? (domain-locals locals))
            (pair? (domain-registry-objects)))))
  ;; SQL scope (task #43): advertise it ONLY when a SQL statement ran or is pending
  ;; on this pause (so the panel isn't cluttered with an empty scope otherwise).
  ;; Label it with the op + table so multiple queries are distinguishable rather
  ;; than a bare "SQL".
  (define sql-cap
    (if (attach-mode?)
        (let ([s (and attach-evt (hash-ref attach-evt 'sql #f))])
          (and (hash? s)
               (hasheq 'op (hash-ref s 'operation #f) 'table (hash-ref s 'table #f))))
        (current-sql-capture-record)))
  (define has-sql? (and sql-cap #t))
  (define sql-scope-name
    (if sql-cap
        (let ([op (hash-ref sql-cap 'op #f)] [table (hash-ref sql-cap 'table #f)])
          (cond
            [(and op table) (format "SQL · ~a ~a" op table)]
            [op             (format "SQL · ~a" op)]
            [table          (format "SQL · ~a" table)]
            [else           "SQL"]))
        "SQL"))
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
                 (list (hasheq 'name sql-scope-name
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
                 [display   (value-display raw-val)]
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
                 ;; make-variable allocates a child varref whenever value-children
                 ;; reports structure, and registers `var-name` as the
                 ;; evaluateName so Copy Value / hover / watch resolve it.  The
                 ;; copyable text is the FULL value, not the proof-annotated
                 ;; display string.
                 (make-variable var-name value-str type-str raw-val var-name)))))
   locals))

;; One DAP variable hash for a domain object, labelled `label`.  Allocates a child
;; varref so the object expands to its fields in the panel.  (registry-object-label
;; and domain-registry-objects are imported from domain-inspect.rkt.)
(define (domain-object-variable label v)
  (make-variable label (value-display v) (~a (domain-struct-name v)) v label))

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
;; Use the ACTUALLY-PAUSED thread's capture — NOT the program thread's, and never
;; a global "most recent across all threads" fallback. A `serve`d handler runs on
;; its own request thread, so the program thread has no capture and the global
;; fallback showed an UNRELATED query (e.g. the startup `seedExampleData` insert)
;; on every pause. Reading the paused thread means: the SQL scope reflects what
;; THIS thread actually ran/has-pending, and is empty (scope hidden) when the
;; paused thread has not run a query — so it can't show a stale/unrelated one.
(define (current-sql-capture-record)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define pt (current-paused-thread))
    (and pt (sql-capture-for-thread pt))))

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
                   (format "~a : ~a" (value-display p) tag)
                   tag
                   p
                   ;; Copyable as `sql.params.$1` — and the registered full text is
                   ;; the bare value, not the " : Int" annotated display string.
                   (format "sql.params.$~a" i))))

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
    ;; Every row is copyable: each registers its own evaluateName so the client's
    ;; Copy Value round-trip resolves (see the evalname registry above — the SQL
    ;; preview was the most-reported casualty of that request being unimplemented).
    ;; The registered text is the FULL statement/preview, never a truncated one.
    ;; `raw` is #f and `full` is the string itself: these rows are ALREADY rendered
    ;; text, so re-rendering them through safe-display would wrap the statement in
    ;; quotes and copy `"SELECT …"` instead of `SELECT …`.
    (define (sql-row name value type)
      (hasheq 'name name
              'value value
              'type type
              'variablesReference 0
              'evaluateName (register-evalname! (string-append "sql." name)
                                                value #f value)
              'presentationHint (hasheq 'kind "data")))
    (define preview (sql-inline-preview sql params))
    (append
     (list
      ;; `sql` is the exact text handed to the driver — the one you paste into psql
      ;; alongside the params.
      (sql-row "sql" sql "parameterized ($1,$2…)")
      (sql-row "table" (or table "(unknown)") "")
      (sql-row "operation" (if op (~a op) "(unknown)") "")
      (hasheq 'name "params"
              'value (format "~a bound param(s)" (length params))
              'type "ordered, typed"
              'variablesReference param-ref
              'presentationHint (hasheq 'kind "data"))
      ;; Short NAME (the caveat lives in the type column): a name long enough to
      ;; push the value out of the panel is unreadable, and it made the copy target
      ;; awkward to refer to.
      (sql-row "preview" preview "read-only — never executed; escaped")
      (sql-row "status" (~a status) ""))
     ;; Row count only once the statement has actually executed (and is known).
     (if (and (eq? status 'executed) (exact-nonnegative-integer? rowcount))
         (list (sql-row "row-count" (number->string rowcount) "Int"))
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
        ;; Attach mode: values arrive pre-rendered over the channel — flat rows.
        [(attach-mode?)
         (define evt (unbox attach-last-stopped))
         (cond
           [(= ref 1) (rendered->variables (if evt (hash-ref evt 'locals '()) '()))]
           [(= ref 2) (attach-domain-variables)]
           [(= ref 3) (attach-sql-variables)]
           [else '()])]
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

;; ── evaluate: Copy Value / hover / watch ──────────────────────────────────────
;;
;; A pure LOOKUP against the evaluateName registry the current stop populated —
;; deliberately not an expression evaluator.  A debugger that can execute
;; arbitrary code inside a paused, possibly live process is a hazard, and nothing
;; the Copy/hover/watch features need requires it.
;;
;; Contexts:
;;   "clipboard"  Copy Value — return the COMPLETE untruncated text.  This is the
;;                request that used to fall through to the unknown-command handler
;;                and get an empty successful body, which is precisely why the copy
;;                button silently produced nothing.
;;   "hover"      the hovered identifier; unknown names fail QUIETLY (success #f
;;                with no message) so hovering ordinary source text shows no popup.
;;   "watch"/other  a watch row or Debug Console entry; an unknown name fails with
;;                a message naming what IS available, rather than a blank row.
(define (handle-evaluate req)
  (define args (hash-ref req 'arguments (hasheq)))
  (define expr (let ([e (hash-ref args 'expression "")])
                 (if (string? e) (string-trim e) "")))
  (define context (let ([c (hash-ref args 'context "")])
                    (if (string? c) c "")))
  (define entry (hash-ref evalname-registry expr #f))
  (cond
    [entry
     (define clipboard? (equal? context "clipboard"))
     (define text (if clipboard? (eval-entry-full entry) (eval-entry-display entry)))
     (define raw (eval-entry-raw entry))
     ;; Offer expansion for a composite result so a watch row can be drilled into.
     ;; Skipped for clipboard (the client only reads `result`) and when attached
     ;; (no local value behind the node).
     (define kids (if (or clipboard? (not raw)) '() (value-children raw)))
     (dap-response req #t
       (hasheq 'result text
               'type (if raw (value-type raw) "")
               'variablesReference
               (if (pair? kids)
                   (alloc-varref! (lambda () (children->variables raw kids expr)))
                   0)))]
    ;; Hover over something that is not an in-scope variable: stay silent.
    [(equal? context "hover")
     (dap-response req #f (hasheq))]
    [else
     (define known (sort (hash-keys evalname-registry) string<?))
     (dap-response req #f
       (hasheq 'message
               (if (null? known)
                   "Not paused, or no variables are in scope at this stop."
                   (format "`~a` is not a variable at this stop. In scope: ~a"
                           expr
                           (string-join (if (> (length known) 12)
                                            (append (take known 12) (list "…"))
                                            known)
                                        ", ")))))]))

;; Resume verbs: proxy the command over the control channel in attach mode,
;; else resume the in-process debuggee.  The channel's own "resumed" event (or
;; the next stop) keeps client state truthful in attach mode.
(define (attach-resume! cmd)
  (set-box! paused? #f)
  (attach-send! (hasheq 'cmd cmd)))

(define (handle-continue req)
  (if (attach-mode?) (attach-resume! "continue") (resume! 'continue))
  (dap-response req #t (hasheq 'allThreadsContinued #t)))

(define (handle-next req)
  ;; Step over: resume, but pause at next thsl-src! in same file.
  (cond
    [(attach-mode?) (attach-resume! "step-over")]
    [else
     (let ([evt (unbox last-stopped-event)])
       (when evt
         (set-box! step-next-file (hash-ref evt 'file #f))))
     (resume! 'step-over)])
  (dap-response req #t (hasheq 'allThreadsContinued #t)))

(define (handle-step-in req)
  ;; Step into: pause at the very next thsl-src! call (any file).
  (cond
    [(attach-mode?) (attach-resume! "step-in")]
    [else
     (set-box! step-into-next? #t)
     (resume! 'step-in)])
  (dap-response req #t (hasheq 'allThreadsContinued #t)))

;; Step out: run until this thread returns to a SHALLOWER checkpoint frame (the
;; caller). The runtime now tracks per-thread checkpoint depth, so 'step-out stops
;; at the next checkpoint with depth < the depth where stepOut was issued. At the
;; top frame (depth 0) nothing is shallower, so it runs to the next breakpoint or
;; completion — i.e. behaves like continue.
(define (handle-step-out req)
  (if (attach-mode?) (attach-resume! "step-out") (resume! 'step-out))
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
  (cond
    [(attach-mode?)
     ;; DETACH, don't kill: disarm everything this session armed, resume a
     ;; parked thread, close the channel — the debuggee KEEPS SERVING.  Only
     ;; this adapter process exits.
     (attach-send! (hasheq 'cmd "detach"))
     (sleep 0.2)                       ; give the detach line time to flush
     (let ([conn (unbox attach-conn)])
       (when conn
         (with-handlers ([exn:fail? void])
           (close-input-port (car conn))
           (close-output-port (cdr conn)))))
     (set-box! attach-conn #f)]
    [else
     ;; Launch mode: wake up a paused thread (if any) so the process can exit
     ;; cleanly.  resume! is a no-op when not paused, so this never blocks.
     (resume! 'continue)])
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
      [(equal? cmd "evaluate")         (handle-evaluate req)]
      [(equal? cmd "disconnect")       (handle-disconnect req)]
      ;; Commands we deliberately accept as no-ops.  Clients send these
      ;; unconditionally during setup regardless of advertised capabilities, and a
      ;; failure response would surface as a spurious error notification.  Listing
      ;; them EXPLICITLY is what lets the default below be strict.
      [(member cmd '("setExceptionBreakpoints" "setFunctionBreakpoints"
                     "setDataBreakpoints" "setInstructionBreakpoints"
                     "cancel" "terminate" "pause"))
       (dap-response req #t (hasheq))]
      [else
       ;; Anything else genuinely is not implemented — say so.
       ;;
       ;; This used to answer `success: true` with an empty body "to keep the
       ;; session alive", which made every unimplemented request fail SILENTLY and
       ;; look like a working feature that returned nothing.  That is how the Copy
       ;; Value button came to do nothing at all: the client's `evaluate` request
       ;; got a cheerful empty success and copied the empty result, with no error
       ;; anywhere to hint that `evaluate` was simply missing.  A truthful failure
       ;; makes the client fall back or report, and makes the next such gap loud
       ;; instead of invisible.
       (log! "dispatch: UNIMPLEMENTED command " cmd)
       (dap-response req #f
         (hasheq 'message (format "The Tesl debug adapter does not implement `~a`." cmd)))])))

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

  ;; Expand one level through the varref registry, exactly as a `variables`
  ;; request does.
  (define (expand var)
    (define r (hash-ref var 'variablesReference 0))
    (if (and (> r 0) (hash-has-key? varref-registry r))
        ((hash-ref varref-registry r))
        '()))
  (define (names-of vars) (map (lambda (v) (hash-ref v 'name)) vars))
  (define (child-named vars n)
    (for/or ([v (in-list vars)]) (and (equal? (hash-ref v 'name) n) v)))

  (test-case "a job hash expands to its status / payload / attempts children"
    (reset-varrefs!)
    (define kids (expand (make-variable "job-1" (hash-display job-entry) "Hash" job-entry)))
    (define names (names-of kids))
    (check-not-false (member "status" names) "status child present")
    (check-not-false (member "payload" names) "payload child present")
    (check-not-false (member "attempts" names) "attempts child present"))

  (test-case "the record-valued payload child drills FURTHER into its fields"
    (reset-varrefs!)
    (define kids (expand (make-variable "job-1" (hash-display job-entry) "Hash" job-entry)))
    (define payload-var (child-named kids "payload"))
    (check-true (and payload-var #t) "payload child exists")
    (check-true (> (hash-ref payload-var 'variablesReference) 0)
                "payload (a record) must itself be expandable")
    (define pnames (names-of (expand payload-var)))
    (check-not-false (member "amount" pnames) "record field amount drilled")
    (check-not-false (member "currency" pnames) "record field currency drilled"))

  ;; ── evaluateName / Copy Value ───────────────────────────────────────────────
  ;; The copy button issues `evaluate` for a variable's evaluateName; these pin
  ;; that the names are emitted, nest correctly, and resolve to the FULL text.

  (test-case "variables carry a dotted evaluateName, nested by path"
    (reset-varrefs!)
    (define v (make-variable "job" (hash-display job-entry) "Hash" job-entry "job"))
    (check-equal? (hash-ref v 'evaluateName) "job")
    (define payload (child-named (expand v) "payload"))
    (check-equal? (hash-ref payload 'evaluateName) "job.payload")
    (define amount (child-named (expand payload) "amount"))
    (check-equal? (hash-ref amount 'evaluateName) "job.payload.amount"))

  (test-case "list element evaluateNames use index syntax, not a dot"
    (reset-varrefs!)
    (define v (make-variable "xs" "[1, 2]" "List" (list 1 2) "xs"))
    (check-equal? (sort (map (lambda (c) (hash-ref c 'evaluateName)) (expand v)) string<?)
                  '("xs[0]" "xs[1]")))

  (test-case "a registered evaluateName resolves to the COMPLETE value text"
    ;; The panel shows a truncated 3-key summary for a wide hash; a copy must
    ;; still yield the whole value, which is the point of storing `full`.
    (reset-varrefs!)
    (define wide (hash 'a 1 'b 2 'c 3 'd 4 'e 5))
    (void (make-variable "wide" (hash-display wide) "Hash" wide "wide"))
    (define entry (hash-ref evalname-registry "wide" #f))
    (check-true (and entry #t) "evaluateName registered")
    (check-true (string-contains? (eval-entry-display entry) "…")
                "the DISPLAYED value is the truncated summary")
    (check-false (string-contains? (eval-entry-full entry) "…")
                 "the COPYABLE value is not truncated")
    (for ([k '("a" "b" "c" "d" "e")])
      (check-true (string-contains? (eval-entry-full entry) k)
                  (format "copied text includes key ~a" k))))

  (test-case "reset-varrefs! clears evaluateNames too (no cross-stop leakage)"
    (reset-varrefs!)
    (void (make-variable "x" "1" "Int" 1 "x"))
    (check-true (hash-has-key? evalname-registry "x"))
    (reset-varrefs!)
    (check-false (hash-has-key? evalname-registry "x")
                 "a name from the previous pause must not resolve at the next one"))

  ;; ── Attach mode rebuilds a real tree from streamed nodes ────────────────────
  ;; The launch/attach equivalence itself is pinned in tests/dap-value-tree-tests.rkt;
  ;; here we check the DAP-side node→variable conversion.

  (test-case "streamed child nodes become EXPANDABLE attach-mode variables"
    (reset-varrefs!)
    (define node
      (hasheq 'name "order" 'value "Order {…}" 'type "Order"
              'children (list (hasheq 'name "amount" 'value "4200" 'type "Int"))))
    (define vars (rendered->variables (list node)))
    (check-equal? (length vars) 1)
    (define v (car vars))
    (check-true (> (hash-ref v 'variablesReference) 0)
                "a node WITH children must be expandable — this hardcoded 0 before")
    (check-equal? (hash-ref v 'evaluateName) "order")
    (define kids (expand v))
    (check-equal? (names-of kids) '("amount"))
    (check-equal? (hash-ref (car kids) 'evaluateName) "order.amount")
    (check-equal? (hash-ref (car kids) 'variablesReference) 0
                  "a leaf node stays a leaf"))

  (test-case "a leaf node is not given a dead expand arrow"
    (reset-varrefs!)
    (define vars (rendered->variables
                  (list (hasheq 'name "n" 'value "42" 'type "Int"))))
    (check-equal? (hash-ref (car vars) 'variablesReference) 0))

  (test-case "a TRUNCATED streamed node says so instead of looking complete"
    (reset-varrefs!)
    (define vars (rendered->variables
                  (list (hasheq 'name "deep" 'value "Big {…}" 'type "Big"
                                'truncated #t))))
    (check-true (string-contains? (hash-ref (car vars) 'value) "truncated")))

  ;; (The hash summary/label rendering itself now lives in value-tree.rkt and is
  ;; covered by tests/dap-value-tree-tests.rkt, alongside the composite-implies-
  ;; expandable invariant that ties display and expansion together.)

  ;; ── SQL scope rows ──────────────────────────────────────────────────────────

  (test-case "every SQL scope row is copyable (has an evaluateName that resolves)"
    (reset-varrefs!)
    (define cap (hash 'sql "SELECT * FROM users WHERE id = $1"
                      'params (list 42)
                      'table "users" 'op 'select 'status 'pending))
    (define rows (sql->variables cap))
    (define by-name
      (for/hash ([r (in-list rows)]) (values (hash-ref r 'name) r)))
    (for ([n '("sql" "table" "operation" "preview" "status")])
      (define row (hash-ref by-name n #f))
      (check-true (and row #t) (format "row ~a present" n))
      (define en (hash-ref row 'evaluateName #f))
      (check-true (and en #t) (format "row ~a carries an evaluateName" n))
      (check-true (hash-has-key? evalname-registry en)
                  (format "row ~a's evaluateName resolves — an unresolvable one is what made Copy Value copy nothing" n))))

  (test-case "the SQL preview row copies the FULL inlined statement"
    (reset-varrefs!)
    (define cap (hash 'sql "SELECT * FROM users WHERE id = $1 AND name = $2"
                      'params (list 42 "ada")
                      'table "users" 'op 'select 'status 'pending))
    (void (sql->variables cap))
    (define entry (hash-ref evalname-registry "sql.preview" #f))
    (check-true (and entry #t) "sql.preview is registered")
    (check-equal? (eval-entry-full entry)
                  "SELECT * FROM users WHERE id = 42 AND name = 'ada'"))

  (test-case "the SQL preview row NAME is short (the caveat lives in the type column)"
    (reset-varrefs!)
    (define rows (sql->variables (hash 'sql "SELECT 1" 'params '() 'status 'pending)))
    (define preview (for/or ([r (in-list rows)])
                      (and (equal? (hash-ref r 'name) "preview") r)))
    (check-true (and preview #t))
    (check-true (< (string-length (hash-ref preview 'name)) 20)
                "a long name pushes the value out of the panel")
    (check-true (string-contains? (hash-ref preview 'type) "never executed")
                "and the not-executed caveat is still stated, in the type column"))

  (test-case "bound params are copyable as sql.params.$N, bare of the type suffix"
    (reset-varrefs!)
    (void (sql-param-variables (list 42 "ada")))
    (check-equal? (eval-entry-full (hash-ref evalname-registry "sql.params.$1")) "42")
    ;; The panel shows `"ada" : String`; the copy is just the value.
    (check-equal? (eval-entry-full (hash-ref evalname-registry "sql.params.$2")) "\"ada\""))

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
