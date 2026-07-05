#lang racket
;;; tesl-mcp — Model Context Protocol (MCP) stdio server for the Tesl agent API.
;;;
;;; Exposes the Tesl compiler's agent-facing query surface (the same flags the
;;; LSP shells: --agent-context-json, --check-json, --type-at-json, …, plus the
;;; headless `tesl debug-inspect`) as first-class, discoverable MCP TOOLS so any
;;; MCP-capable agent (Claude Code, etc.) gets them for free.
;;;
;;; Transport: JSON-RPC 2.0 over stdio with LSP-style Content-Length framing —
;;; the SAME framing and compiler-discovery as editor/tesl-lsp/tesl-lsp.rkt.

(require json
         racket/port
         racket/string
         racket/runtime-path)

(define server-version "0.1.0")
(define mcp-protocol-version "2024-11-05")

;; ── Logging (stderr only — stdout is the JSON-RPC channel) ─────────────────────

(define (log msg)
  (fprintf (current-error-port) "[tesl-mcp] ~a\n" msg)
  (flush-output (current-error-port)))

;; ── Compiler discovery (mirrors the LSP) ───────────────────────────────────────

(define-runtime-path script-dir ".")

(define (find-compiler)
  (define (ocaml-at root)
    (let ([p (build-path root "compiler" "_build" "default" "bin" "main.exe")])
      (and (file-exists? p) p)))
  (or (let ([e (getenv "TESL_COMPILER")])  (and e (file-exists? e) (string->path e)))
      (let ([r (getenv "TESL_REPO_ROOT")]) (and r (ocaml-at r)))
      ;; editor/tesl-mcp/ → repo root is two levels up
      (ocaml-at (simplify-path (build-path script-dir ".." "..")))
      #f))

;; ── JSON-RPC / LSP framing (identical to the LSP) ──────────────────────────────

(define (read-message in)
  (let ([headers (make-hash)])
    (let loop ()
      (let ([line (read-line in 'any)])
        (cond
          [(eof-object? line)               (error 'mcp "stdin EOF")]
          [(string=? (string-trim line) "") (void)]
          [else
           (let ([m (regexp-match #rx"^([^:]+):(.*)" line)])
             (when m
               (hash-set! headers
                          (string-downcase (string-trim (cadr m)))
                          (string-trim (caddr m)))))
           (loop)])))
    (let* ([n   (string->number (hash-ref headers "content-length" "0"))]
           [buf (make-bytes n)])
      (read-bytes! buf in)
      (with-handlers ([exn? (lambda (e) (log (format "json-parse: ~a" (exn-message e))) (hash))])
        (read-json (open-input-bytes buf))))))

(define (write-message out msg)
  (let ([body (jsexpr->bytes msg)])
    (fprintf out "Content-Length: ~a\r\n\r\n" (bytes-length body))
    (write-bytes body out)
    (flush-output out)))

;; ── Subprocess helper ──────────────────────────────────────────────────────────
;; Run the compiler binary with args; return (values stdout-string stderr-string
;; exit-code). Never raises — failures surface as a non-zero exit code.

(define (run-compiler compiler args)
  (let-values ([(proc pout pin perr)
                (apply subprocess #f #f #f
                       (path->string compiler)
                       args)])
    (close-output-port pin)
    (let* ([out (port->string pout)]
           [err (port->string perr)]
           [_   (subprocess-wait proc)]
           [code (subprocess-status proc)])
      (close-input-port pout)
      (close-input-port perr)
      (values out err code))))

;; A tool result is the compiler's compact JSON on stdout. We pass it through
;; verbatim (token economy: no re-pretty-printing). If stdout is empty but there
;; is stderr, we surface that as the (error) text instead.
(define (compiler-json-result compiler args)
  (define-values (out err code) (run-compiler compiler args))
  (define text (string-trim out))
  (if (string=? text "")
      (values (if (string=? (string-trim err) "")
                  (jsexpr->string (hasheq 'error (format "no output (exit ~a)" code)))
                  (string-trim err))
              #t)               ; isError
      (values text #f)))        ; the compact JSON, not an error

;; ── Tool argument helpers ───────────────────────────────────────────────────────

(define (arg-ref args key [default #f])
  (if (hash? args) (hash-ref args key default) default))

(define (require-string args key)
  (let ([v (arg-ref args (string->symbol key))])
    (unless (string? v)
      (error 'mcp (format "missing/invalid required string argument '~a'" key)))
    v))

(define (require-int args key)
  (let ([v (arg-ref args (string->symbol key))])
    (cond [(exact-integer? v) v]
          [(and (string? v) (string->number v)) (inexact->exact (string->number v))]
          [else (error 'mcp (format "missing/invalid required integer argument '~a'" key))])))

;; ── Breakpoint-spec assembly for tesl.debug_inspect ────────────────────────────
;; The agent may pass either `break_at` (a list of pre-formed SPEC strings) or a
;; structured `breakpoints` list of {line, condition?, hit?}. We translate the
;; structured form into the CLI's SPEC syntax:
;;   LINE                       — bare
;;   "LINE: <condition>"        — conditional
;;   "LINE: <hit>"              — hit-count (==|>=|<=|>|<|% N)

(define (breakpoint->spec bp)
  (define line (hash-ref bp 'line (hash-ref bp "line" #f)))
  (define cnd (or (hash-ref bp 'condition #f) (hash-ref bp "condition" #f)))
  (define hit  (or (hash-ref bp 'hit #f) (hash-ref bp "hit" #f)))
  (define line-str
    (cond [(exact-integer? line) (number->string line)]
          [(and (string? line) (string->number line)) line]
          [else (error 'mcp "breakpoint missing integer 'line'")]))
  (cond
    [(and (string? cnd) (not (string=? (string-trim cnd) "")))
     (format "~a: ~a" line-str cnd)]
    [(and (string? hit) (not (string=? (string-trim hit) "")))
     (format "~a: ~a" line-str hit)]
    [else line-str]))

(define (debug-inspect-args args)
  (define file (require-string args "file"))
  (define mode (arg-ref args 'mode))
  (define break-at (arg-ref args 'break_at))
  (define breakpoints (arg-ref args 'breakpoints))
  (define specs
    (cond
      [(and (list? break-at) (not (null? break-at)))
       (map (lambda (s) (if (string? s) s (format "~a" s))) break-at)]
      [(and (list? breakpoints) (not (null? breakpoints)))
       (map breakpoint->spec breakpoints)]
      [else (error 'mcp "debug_inspect requires 'breakpoints' or 'break_at'")]))
  (define base (list "debug-inspect" file))
  (define with-bps
    (append base (append-map (lambda (s) (list "--break-at" s)) specs)))
  (define with-mode
    (if (and (string? mode) (member mode '("program" "test")))
        (append with-bps (list "--mode" mode))
        with-bps))
  ;; `continue: true` → headless F5: stop at each breakpoint in turn, resume after
  ;; each, and let the program finish (issue #16). Result becomes
  ;; {mode:"continue", snapshots:[…], completed}. Absent → one-shot first-stop dump.
  (if (eq? (arg-ref args 'continue) #t)
      (append with-mode (list "--continue"))
      with-mode))

;; ── proof_obligations: derive from --agent-context-json ────────────────────────

(define (proof-obligations-result compiler file)
  (define-values (out _err _code)
    (run-compiler compiler (list "--agent-context-json" file)))
  (define text (string-trim out))
  (with-handlers ([exn? (lambda (e)
                          (values (jsexpr->string (hasheq 'error (exn-message e))) #t))])
    (define j (read-json (open-input-string text)))
    (define obls (hash-ref j 'proof_obligations '()))
    (values (jsexpr->string (hash 'proof_obligations obls)) #f)))

;; ── Tool registry ──────────────────────────────────────────────────────────────
;; Each tool: (hasheq 'name … 'description … 'inputSchema … 'run proc).
;; `run` takes (compiler args) and returns (values text isError).

(define (schema props required)
  (hasheq 'type "object"
          'properties props
          'required required))

(define str-prop  (hasheq 'type "string"))
(define int-prop  (hasheq 'type "integer"))

(define (file-line-col-schema)
  (schema (hasheq 'file str-prop 'line int-prop 'col int-prop)
          '("file" "line" "col")))

(define (file-only-schema) (schema (hasheq 'file str-prop) '("file")))

(define (positional-json-tool flag)
  ;; A tool that shells `<flag> <file> <line> <col>`.
  (lambda (compiler args)
    (compiler-json-result
     compiler
     (list flag (require-string args "file")
           (number->string (require-int args "line"))
           (number->string (require-int args "col"))))))

(define (file-json-tool flag)
  (lambda (compiler args)
    (compiler-json-result compiler (list flag (require-string args "file")))))

(define tools
  (list
   (hasheq
    'name "tesl.agent_context"
    'description (string-append
                  "PRIMARY tool — read this after EVERY edit. Returns the compact "
                  "agent-context snapshot for a Tesl file: {ok, summary, "
                  "diagnostics (coded), symbols, proof_obligations}. One call gives "
                  "the whole compiler/linter picture in a token-efficient form.")
    'inputSchema (file-only-schema)
    'run (file-json-tool "--agent-context-json"))

   (hasheq
    'name "tesl.check"
    'description (string-append
                  "Type-check a Tesl file. Returns coded diagnostics (errors + "
                  "warnings) each with a code and, where available, a suggested fix.")
    'inputSchema (file-only-schema)
    'run (file-json-tool "--check-json"))

   (hasheq
    'name "tesl.type_at"
    'description "Type of the expression at a position (0-based line, 0-based col)."
    'inputSchema (file-line-col-schema)
    'run (positional-json-tool "--type-at-json"))

   (hasheq
    'name "tesl.signature"
    'description "Signature help for the call at a position (0-based line, 0-based col)."
    'inputSchema (file-line-col-schema)
    'run (positional-json-tool "--signature-help-json"))

   (hasheq
    'name "tesl.completions"
    'description "In-scope completions at a position (0-based line, 0-based col)."
    'inputSchema (file-line-col-schema)
    'run (positional-json-tool "--completions-json"))

   (hasheq
    'name "tesl.definition"
    'description "Go-to-definition for the symbol at a position (0-based line, 0-based col)."
    'inputSchema (file-line-col-schema)
    'run (positional-json-tool "--definition-json"))

   (hasheq
    'name "tesl.references"
    'description (string-append
                  "Find references/occurrences of the symbol at a position "
                  "(0-based line, 0-based col). Same-file only.")
    'inputSchema (file-line-col-schema)
    'run (positional-json-tool "--occurrences-json"))

   (hasheq
    'name "tesl.proof_obligations"
    'description (string-append
                  "Just the proof_obligations slice of the agent-context: the GDP "
                  "obligations the compiler still needs discharged.")
    'inputSchema (file-only-schema)
    'run (lambda (compiler args)
           (proof-obligations-result compiler (require-string args "file"))))

   (hasheq
    'name "tesl.debug_inspect"
    'description (string-append
                  "Headless step-debugger. YOU set the breakpoints. Compiles the "
                  "file with debug instrumentation, runs to the first breakpoint "
                  "that fires, and returns {stopped, source, locals, domain, sql, "
                  "breakpoint}. Pass either 'break_at' (list of SPEC strings) or "
                  "'breakpoints' (list of {line, condition?, hit?}). condition is a "
                  "boolean over locals (e.g. \"n == -10\"); hit is a hit-count spec "
                  "(==|>=|<=|>|<|% N). Optional 'mode' is \"program\" (default) or "
                  "\"test\" to run inside the file's test blocks. Set 'continue': true "
                  "for headless F5 — stop at EACH breakpoint in turn, resume after "
                  "each, and let the program finish; the result then has "
                  "{mode:\"continue\", snapshots:[…], completed} instead of a single "
                  "first-stop dump (so multiple breakpoints all fire and a handler's "
                  "response actually completes).")
    'inputSchema
    (schema
     (hasheq
      'file str-prop
      'break_at (hasheq 'type "array" 'items str-prop
                        'description "SPEC strings: LINE | \"LINE: <cond>\" | \"LINE: <hit>\" | L1,L2,L3")
      'breakpoints (hasheq 'type "array"
                           'items (schema (hasheq 'line int-prop
                                                  'condition str-prop
                                                  'hit str-prop)
                                          '("line")))
      'mode (hasheq 'type "string" 'enum '("program" "test"))
      'continue (hasheq 'type "boolean"
                        'description "Headless F5: run through every breakpoint (resume after each) until the program completes; result is {mode:\"continue\", snapshots:[…], completed}."))
     '("file"))
    'run (lambda (compiler args)
           (compiler-json-result compiler (debug-inspect-args args))))))

(define (tool-by-name name)
  (for/or ([t (in-list tools)])
    (and (string=? (hash-ref t 'name) name) t)))

(define (tool-defs)
  ;; The public list/list response: strip the internal 'run proc.
  (for/list ([t (in-list tools)])
    (hasheq 'name        (hash-ref t 'name)
            'description  (hash-ref t 'description)
            'inputSchema  (hash-ref t 'inputSchema))))

;; ── JSON-RPC plumbing ──────────────────────────────────────────────────────────

(define (rpc-result out id result)
  (write-message out (hasheq 'jsonrpc "2.0" 'id id 'result result)))

(define (rpc-error out id code message)
  (write-message out (hasheq 'jsonrpc "2.0" 'id id
                             'error (hasheq 'code code 'message message))))

(define (has-id? msg) (hash-has-key? msg 'id))

;; tools/call handler — every tool body is wrapped so a failure becomes an
;; isError text result (the agent sees the message) rather than crashing.
(define (handle-tools-call compiler params)
  (define name (hash-ref params 'name #f))
  (define args (hash-ref params 'arguments (hasheq)))
  (define tool (and name (tool-by-name name)))
  (cond
    [(not tool)
     (hasheq 'content (list (hasheq 'type "text"
                                    'text (format "unknown tool: ~a" name)))
             'isError #t)]
    [(not compiler)
     (hasheq 'content (list (hasheq 'type "text"
                                    'text "tesl compiler binary not found (set TESL_REPO_ROOT or TESL_COMPILER)"))
             'isError #t)]
    [else
     (with-handlers
       ([exn? (lambda (e)
                (hasheq 'content (list (hasheq 'type "text" 'text (exn-message e)))
                        'isError #t))])
       (define-values (text isError) ((hash-ref tool 'run) compiler args))
       (hasheq 'content (list (hasheq 'type "text" 'text text))
               'isError (and isError #t)))]))

(define (handle-message out compiler msg)
  (define method (hash-ref msg 'method #f))
  (define id     (hash-ref msg 'id #f))
  (define params (hash-ref msg 'params (hasheq)))
  (cond
    ;; ── notifications (no id) ──
    [(equal? method "notifications/initialized") (void)]
    [(equal? method "initialized") (void)]
    [(equal? method "exit") (void)]

    ;; ── requests (have id) ──
    [(equal? method "initialize")
     (rpc-result out id
                 (hasheq 'protocolVersion mcp-protocol-version
                         'capabilities (hasheq 'tools (hasheq))
                         'serverInfo (hasheq 'name "tesl-mcp"
                                             'version server-version)))]
    [(equal? method "ping")
     (rpc-result out id (hasheq))]
    [(equal? method "shutdown")
     (rpc-result out id 'null)]
    [(equal? method "tools/list")
     (rpc-result out id (hasheq 'tools (tool-defs)))]
    [(equal? method "tools/call")
     (rpc-result out id (handle-tools-call compiler params))]

    ;; ── unknown ──
    [else
     (if id
         (rpc-error out id -32601 (format "method not found: ~a" method))
         (void))]))

(define (main)
  (define in  (current-input-port))
  (define out (current-output-port))
  (define compiler (find-compiler))
  (if compiler
      (log (format "compiler: ~a" compiler))
      (log "WARNING: tesl compiler not found; tool calls will return errors"))
  (log (format "tesl-mcp ~a ready (protocol ~a)" server-version mcp-protocol-version))
  (let loop ()
    (define msg
      (with-handlers ([exn? (lambda (e) eof)])
        (read-message in)))
    (cond
      [(eof-object? msg) (void)]    ; stdin closed → exit cleanly
      [else
       ;; Per-message guard: a handler failure becomes a JSON-RPC error (if the
       ;; message had an id) and never breaks the loop.
       (with-handlers
         ([exn? (lambda (e)
                  (log (format "handler error: ~a" (exn-message e)))
                  (when (and (hash? msg) (hash-ref msg 'id #f))
                    (rpc-error out (hash-ref msg 'id #f)
                               -32603 (format "internal error: ~a" (exn-message e)))))])
         (when (hash? msg)
           (handle-message out compiler msg)))
       (loop)])))

(module+ main (main))
