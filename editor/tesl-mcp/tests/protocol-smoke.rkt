#lang racket
;;; Protocol smoke test for tesl-mcp.
;;;
;;; Spawns the server as a subprocess, pipes a real JSON-RPC-over-stdio session
;;; through its stdin, frames/parses the responses, and makes REAL assertions:
;;;   • initialize           → serverInfo.name == "tesl-mcp", capabilities.tools
;;;   • tools/list           → contains every expected tool name WITH inputSchema
;;;   • tools/call agent_ctx  → content text parses as the agent-context JSON
;;;   • tools/call debug_insp → conditional breakpoint on lesson61 stops with the
;;;                             expected local (n == -10)
;;;   • unknown method        → JSON-RPC error -32601
;;;
;;; Run: racket editor/tesl-mcp/tests/protocol-smoke.rkt
;;; Exit code 0 on success, 1 on any failed assertion.

(require json
         racket/port
         racket/runtime-path)

(define-runtime-path here ".")
(define server-path (simplify-path (build-path here ".." "tesl-mcp.rkt")))
(define repo-root   (simplify-path (build-path here ".." ".." "..")))
(define lesson61    (build-path repo-root "example" "learn" "lesson61-step-debugging.tesl"))

(define failures 0)
(define (check! ok? label)
  (if ok?
      (printf "  ok   ~a\n" label)
      (begin (set! failures (add1 failures))
             (printf "  FAIL ~a\n" label))))

;; ── Framing (write a JSON-RPC message, read one back) ──────────────────────────

(define (write-msg out msg)
  (define body (jsexpr->bytes msg))
  (fprintf out "Content-Length: ~a\r\n\r\n" (bytes-length body))
  (write-bytes body out)
  (flush-output out))

(define (read-msg in)
  ;; Read headers until a blank line, then the Content-Length bytes.
  (let loop ([clen #f])
    (define line (read-line in 'any))
    (cond
      [(eof-object? line) (error 'smoke "server closed stdout (EOF)")]
      [(string=? (string-trim line) "")
       (define n (or clen (error 'smoke "no Content-Length header")))
       (define buf (make-bytes n))
       (read-bytes! buf in)
       (read-json (open-input-bytes buf))]
      [else
       (define m (regexp-match #rx"(?i:content-length):[ ]*([0-9]+)" line))
       (loop (if m (string->number (cadr m)) clen))])))

;; ── Drive the server ────────────────────────────────────────────────────────────

(printf "tesl-mcp protocol smoke\n")
(printf "  server: ~a\n" server-path)

(define-values (proc pout pin perr)
  (parameterize ([current-environment-variables
                  (let ([e (environment-variables-copy (current-environment-variables))])
                    (environment-variables-set! e #"TESL_REPO_ROOT"
                                                (path->bytes (path->complete-path repo-root)))
                    e)])
    (subprocess #f #f #f (find-executable-path "racket") (path->string server-path))))

;; Drain stderr in the background so the server never blocks on a full pipe.
(define stderr-thread
  (thread (lambda () (port->string perr))))

(define (request id method [params (hasheq)])
  (write-msg pin (hasheq 'jsonrpc "2.0" 'id id 'method method 'params params))
  (read-msg pout))

(define (notify method [params (hasheq)])
  (write-msg pin (hasheq 'jsonrpc "2.0" 'method method 'params params)))

(with-handlers ([exn? (lambda (e)
                        (printf "EXCEPTION: ~a\n" (exn-message e))
                        (set! failures (add1 failures)))])

  ;; ── initialize ──
  (printf "\n[initialize]\n")
  (define init (request 1 "initialize"
                        (hasheq 'protocolVersion "2024-11-05"
                                'capabilities (hasheq)
                                'clientInfo (hasheq 'name "smoke" 'version "0"))))
  (define init-res (hash-ref init 'result (hasheq)))
  (check! (equal? (hash-ref init 'id #f) 1) "response id echoes request id")
  (check! (equal? (hash-ref (hash-ref init-res 'serverInfo (hasheq)) 'name #f) "tesl-mcp")
          "serverInfo.name == tesl-mcp")
  (check! (hash-has-key? (hash-ref init-res 'capabilities (hasheq)) 'tools)
          "capabilities.tools present")
  (check! (string? (hash-ref init-res 'protocolVersion #f)) "protocolVersion present")

  (notify "notifications/initialized")

  ;; ── ping ──
  (printf "\n[ping]\n")
  (define pong (request 2 "ping"))
  (check! (hash? (hash-ref pong 'result #f)) "ping returns a result object")

  ;; ── tools/list ──
  (printf "\n[tools/list]\n")
  (define tl (request 3 "tools/list"))
  (define tools (hash-ref (hash-ref tl 'result (hasheq)) 'tools '()))
  (define names (map (lambda (t) (hash-ref t 'name #f)) tools))
  (for ([expected (in-list '("tesl.agent_context" "tesl.check" "tesl.type_at"
                             "tesl.signature" "tesl.completions" "tesl.definition"
                             "tesl.references" "tesl.proof_obligations"
                             "tesl.debug_inspect"))])
    (check! (member expected names) (format "tools/list contains ~a" expected)))
  (check! (andmap (lambda (t) (hash? (hash-ref t 'inputSchema #f))) tools)
          "every tool has an inputSchema object")
  (check! (andmap (lambda (t) (string? (hash-ref t 'description #f))) tools)
          "every tool has a description")

  ;; ── tools/call tesl.agent_context on a real lesson ──
  (printf "\n[tools/call tesl.agent_context]\n")
  (define ac (request 4 "tools/call"
                      (hasheq 'name "tesl.agent_context"
                              'arguments (hasheq 'file (path->string lesson61)))))
  (define ac-res (hash-ref ac 'result (hasheq)))
  (check! (not (hash-ref ac-res 'isError #f)) "agent_context not an error")
  (define ac-text (hash-ref (car (hash-ref ac-res 'content '(#f))) 'text ""))
  (define ac-json
    (with-handlers ([exn? (lambda (_) #f)]) (read-json (open-input-string ac-text))))
  (check! (hash? ac-json) "agent_context content text parses as JSON")
  (when (hash? ac-json)
    (for ([k (in-list '(ok summary diagnostics symbols proof_obligations))])
      (check! (hash-has-key? ac-json k)
              (format "agent_context JSON has key ~a" k)))
    (define syms (hash-ref ac-json 'symbols '()))
    (check! (member "checkScore" (map (lambda (s) (hash-ref s 'name #f)) syms))
            "agent_context symbols include checkScore"))

  ;; ── tools/call tesl.debug_inspect with a conditional breakpoint ──
  (printf "\n[tools/call tesl.debug_inspect (conditional)]\n")
  (define di (request 5 "tools/call"
                      (hasheq 'name "tesl.debug_inspect"
                              'arguments (hasheq
                                          'file (path->string lesson61)
                                          'mode "test"
                                          'breakpoints
                                          (list (hasheq 'line 191
                                                        'condition "n == -10"))))))
  (define di-res (hash-ref di 'result (hasheq)))
  (check! (not (hash-ref di-res 'isError #f)) "debug_inspect not an error")
  (define di-text (hash-ref (car (hash-ref di-res 'content '(#f))) 'text ""))
  (define di-json
    (with-handlers ([exn? (lambda (_) #f)]) (read-json (open-input-string di-text))))
  (check! (hash? di-json) "debug_inspect content text parses as JSON")
  (when (hash? di-json)
    (check! (eq? (hash-ref di-json 'stopped #f) #t) "debug_inspect stopped == true")
    (define locals (hash-ref di-json 'locals '()))
    (define n-local
      (for/or ([l (in-list locals)])
        (and (equal? (hash-ref l 'name #f) "n") l)))
    (check! (and n-local (equal? (hash-ref n-local 'value #f) "-10"))
            "debug_inspect local n == \"-10\" at the conditional breakpoint")
    (check! (equal? (hash-ref (hash-ref di-json 'breakpoint (hasheq)) 'line #f) 191)
            "debug_inspect breakpoint line == 191"))

  ;; ── unknown method → JSON-RPC error -32601 ──
  (printf "\n[unknown method]\n")
  (define unk (request 6 "totally/bogus"))
  (check! (equal? (hash-ref (hash-ref unk 'error (hasheq)) 'code #f) -32601)
          "unknown method → error -32601")

  ;; ── shutdown ──
  (define sd (request 7 "shutdown"))
  (check! (hash-has-key? sd 'result) "shutdown returns a result"))

;; ── Teardown ────────────────────────────────────────────────────────────────────

(close-output-port pin)            ; EOF → server exits its loop
(void (sync/timeout 5 (thread (lambda () (subprocess-wait proc)))))
(when (eq? 'running (subprocess-status proc))
  (subprocess-kill proc #t))
(void (sync/timeout 2 stderr-thread))
(close-input-port pout)
(close-input-port perr)

(printf "\n~a\n" (if (zero? failures)
                     "ALL PASS"
                     (format "~a FAILURE(S)" failures)))
(exit (if (zero? failures) 0 1))
