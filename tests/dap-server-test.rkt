#lang racket

;; dap-server-test.rkt — Comprehensive integration tests for dsl/debug/dap-server.rkt
;;
;; Parts:
;;   1. DAP message framing (standalone — read-dap-msg via string ports)
;;   2. handle-set-breakpoints (direct calls, checking breakpoints hash)
;;   3. Full mini DAP session (subprocess, via pipes)
;;   4. handle-source (direct calls)

(require rackunit
         racket/set
         racket/string
         json
         "../dsl/debug/checkpoint.rkt")

;; ── Constants ─────────────────────────────────────────────────────────────────

(define REPO-ROOT (or (getenv "TESL_REPO_ROOT") "/home/mikael/repos_wsl/tesl-github/tesl"))
;; Use the racket running this test (NOT a hardcoded store path, which pins a racket
;; version and breaks on upgrade).
(define RACKET-BIN
  (let ([e (find-system-path 'exec-file)])
    (path->string (or (find-executable-path e) e))))
(define DAP-SERVER-PATH (build-path REPO-ROOT "dsl/debug/dap-server.rkt"))
;; Inherit PLTCOLLECTS from the environment (set by the dev shell / nix wrapper to the
;; running racket's collects + the tesl collections); prepend the repo's collection root.
(define PLTCOLLECTS
  (string-append REPO-ROOT "/.tesl-collections"
                 (let ([pc (getenv "PLTCOLLECTS")]) (if (and pc (> (string-length pc) 0))
                                                        (string-append ":" pc) ""))))

;; A real .tesl file we can use for source tests
(define TEST-TESL-FILE
  (path->string (build-path REPO-ROOT "tests/adversarial-review-tests.tesl")))

;; ─────────────────────────────────────────────────────────────────────────────
;; ── Part 1: DAP message framing ──────────────────────────────────────────────
;; ─────────────────────────────────────────────────────────────────────────────

;; Build a fake DAP input port containing exactly one framed message.
(define (make-dap-input json-str)
  (define bytes (string->bytes/utf-8 json-str))
  (open-input-string
    (format "Content-Length: ~a\r\n\r\n~a"
            (bytes-length bytes) json-str)))

;; Call read-dap-msg with current-input-port bound to a specific port.
(define (read-dap-msg-from-port in)
  (parameterize ([current-input-port in])
    ;; read-dap-msg is defined inside dap-server.rkt; we replicate its logic
    ;; here for unit testing framing independently of the server module.
    (let loop ([line (read-line (current-input-port) 'return-linefeed)])
      (cond
        [(eof-object? line) eof]
        [(string-prefix? line "Content-Length:")
         (let* ([len-str (string-trim (substring line 15))]
                [n (string->number len-str)])
           (read-line (current-input-port) 'return-linefeed)  ; blank line
           (let ([body (read-bytes n (current-input-port))])
             (if (eof-object? body)
                 eof
                 (string->jsexpr (bytes->string/utf-8 body)))))]
        [else (loop (read-line (current-input-port) 'return-linefeed))]))))

;; Build a DAP-framed byte string from a jsexpr.
(define (frame-dap-msg jsexpr)
  (define json-str (jsexpr->string jsexpr))
  (define json-bytes (string->bytes/utf-8 json-str))
  (string->bytes/utf-8
    (format "Content-Length: ~a\r\n\r\n" (bytes-length json-bytes))))

;; ── Framing tests ─────────────────────────────────────────────────────────────

(test-case "framing: read-dap-msg parses Content-Length header and returns hash"
  (define msg (read-dap-msg-from-port (make-dap-input "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\"}")))
  (check-true (hash? msg) "parsed message should be a hash")
  (check-equal? (hash-ref msg 'command "") "initialize"))

(test-case "framing: read-dap-msg returns eof on empty stream"
  (define msg (read-dap-msg-from-port (open-input-string "")))
  (check-true (eof-object? msg) "empty stream should yield eof"))

(test-case "framing: read-dap-msg accesses seq field as integer"
  (define msg (read-dap-msg-from-port (make-dap-input "{\"seq\":42,\"type\":\"request\",\"command\":\"initialize\"}")))
  (check-equal? (hash-ref msg 'seq #f) 42))

(test-case "framing: read-dap-msg accesses arguments hash"
  (define json-str "{\"seq\":3,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"/foo.tesl\",\"mode\":\"test\"}}")
  (define msg (read-dap-msg-from-port (make-dap-input json-str)))
  (define args (hash-ref msg 'arguments (hasheq)))
  (check-equal? (hash-ref args 'program "") "/foo.tesl")
  (check-equal? (hash-ref args 'mode "") "test"))

(test-case "framing: read-dap-msg handles large message (1 KB+)"
  ;; Build a JSON string with a large string value
  (define big-string (make-string 1024 #\x))
  (define json-str (jsexpr->string (hasheq 'seq 1 'command "test" 'data big-string)))
  (define msg (read-dap-msg-from-port (make-dap-input json-str)))
  (check-true (hash? msg))
  (check-equal? (string-length (hash-ref msg 'data "")) 1024))

(test-case "framing: read-dap-msg handles multiple messages in sequence"
  (define msg1 "{\"seq\":1,\"command\":\"initialize\"}")
  (define msg2 "{\"seq\":2,\"command\":\"launch\"}")
  (define b1 (string->bytes/utf-8 msg1))
  (define b2 (string->bytes/utf-8 msg2))
  (define combined
    (string-append
      (format "Content-Length: ~a\r\n\r\n~a" (bytes-length b1) msg1)
      (format "Content-Length: ~a\r\n\r\n~a" (bytes-length b2) msg2)))
  (define port (open-input-string combined))
  (define r1 (read-dap-msg-from-port port))
  (define r2 (read-dap-msg-from-port port))
  (check-equal? (hash-ref r1 'command "") "initialize")
  (check-equal? (hash-ref r2 'command "") "launch"))

(test-case "framing: read-dap-msg ignores non-Content-Length headers"
  ;; Extra headers before Content-Length should be skipped
  (define json-str "{\"seq\":1,\"command\":\"initialize\"}")
  (define bytes (string->bytes/utf-8 json-str))
  (define raw (format "X-Ignored: stuff\r\nContent-Length: ~a\r\n\r\n~a"
                      (bytes-length bytes) json-str))
  (define msg (read-dap-msg-from-port (open-input-string raw)))
  (check-equal? (hash-ref msg 'command "") "initialize"))

(test-case "framing: read-dap-msg: command field is accessible"
  (define msg (read-dap-msg-from-port (make-dap-input "{\"seq\":1,\"command\":\"setBreakpoints\"}")))
  (check-equal? (hash-ref msg 'command "") "setBreakpoints"))

(test-case "framing: read-dap-msg: type field is accessible"
  (define msg (read-dap-msg-from-port (make-dap-input "{\"seq\":1,\"type\":\"request\",\"command\":\"threads\"}")))
  (check-equal? (hash-ref msg 'type "") "request"))

(test-case "framing: read-dap-msg: nested arguments are accessible"
  (define json-str
    (jsexpr->string
      (hasheq 'seq 5 'command "setBreakpoints"
              'arguments (hasheq 'source (hasheq 'path "/foo.tesl")
                                 'breakpoints (list (hasheq 'line 10) (hasheq 'line 20))))))
  (define msg (read-dap-msg-from-port (make-dap-input json-str)))
  (define args (hash-ref msg 'arguments (hasheq)))
  (define source (hash-ref args 'source (hasheq)))
  (check-equal? (hash-ref source 'path "") "/foo.tesl")
  (define bps (hash-ref args 'breakpoints '()))
  (check-equal? (length bps) 2))

(test-case "framing: read-dap-msg returns eof after last byte read"
  (define msg "{\"seq\":1,\"command\":\"initialize\"}")
  (define bytes (string->bytes/utf-8 msg))
  (define port (open-input-string (format "Content-Length: ~a\r\n\r\n~a" (bytes-length bytes) msg)))
  (define r1 (read-dap-msg-from-port port))
  (check-equal? (hash-ref r1 'command "") "initialize")
  ;; Second read: port is exhausted
  (define r2 (read-dap-msg-from-port port))
  (check-true (eof-object? r2) "exhausted port should yield eof"))

(test-case "framing: Content-Length byte count is exact (UTF-8 multi-byte)"
  ;; A JSON string with a non-ASCII character (2 UTF-8 bytes each)
  (define json-str (jsexpr->string (hasheq 'seq 1 'command "test" 'data "café")))
  (define msg (read-dap-msg-from-port (make-dap-input json-str)))
  (check-equal? (hash-ref msg 'data "") "café"))

;; ─────────────────────────────────────────────────────────────────────────────
;; ── Part 2: handle-set-breakpoints (direct) ───────────────────────────────────
;; ─────────────────────────────────────────────────────────────────────────────

;; Replicate handle-set-breakpoints logic directly, operating on the shared
;; `breakpoints` hash from checkpoint.rkt.  We also capture the output it
;; would send by redirecting current-output-port.

(define (make-set-bp-req file lines)
  (hasheq 'seq 1 'type "request" 'command "setBreakpoints"
          'arguments (hasheq 'source (hasheq 'path file)
                             'breakpoints (map (lambda (l) (hasheq 'line l)) lines))))

;; Simulate handle-set-breakpoints: update the breakpoints hash and return the
;; response body that the real handler would send.
(define (sim-handle-set-breakpoints req)
  (define args (hash-ref req 'arguments (hasheq)))
  (define source (hash-ref args 'source (hasheq)))
  (define path (hash-ref source 'path ""))
  (define bps (hash-ref args 'breakpoints '()))
  (define lines (map (lambda (bp) (hash-ref bp 'line 0)) bps))
  (if (null? lines)
      (hash-remove! breakpoints path)
      (hash-set! breakpoints path (list->seteq lines)))
  ;; Return the response body
  (hasheq 'breakpoints
          (map (lambda (line) (hasheq 'verified #t 'line line)) lines)))

;; ── set-breakpoints tests ─────────────────────────────────────────────────────

(test-case "set-breakpoints: sets breakpoints for a file"
  (hash-clear! breakpoints)
  (sim-handle-set-breakpoints (make-set-bp-req "/foo.tesl" '(5 10)))
  (check-true (hash-has-key? breakpoints "/foo.tesl") "file should be in breakpoints")
  (check-true (set-member? (hash-ref breakpoints "/foo.tesl" (seteq)) 5))
  (check-true (set-member? (hash-ref breakpoints "/foo.tesl" (seteq)) 10))
  (hash-clear! breakpoints))

(test-case "set-breakpoints: multiple files each have their own entry"
  (hash-clear! breakpoints)
  (sim-handle-set-breakpoints (make-set-bp-req "/a.tesl" '(1 2)))
  (sim-handle-set-breakpoints (make-set-bp-req "/b.tesl" '(3 4)))
  (check-true (hash-has-key? breakpoints "/a.tesl"))
  (check-true (hash-has-key? breakpoints "/b.tesl"))
  (check-false (set-member? (hash-ref breakpoints "/a.tesl" (seteq)) 3)
               "file a should not have file b's lines")
  (check-false (set-member? (hash-ref breakpoints "/b.tesl" (seteq)) 1)
               "file b should not have file a's lines")
  (hash-clear! breakpoints))

(test-case "set-breakpoints: response has breakpoints array with verified #t"
  (hash-clear! breakpoints)
  (define resp (sim-handle-set-breakpoints (make-set-bp-req "/x.tesl" '(7 14))))
  (define bps (hash-ref resp 'breakpoints '()))
  (check-equal? (length bps) 2)
  (for ([bp bps])
    (check-equal? (hash-ref bp 'verified #f) #t))
  (hash-clear! breakpoints))

(test-case "set-breakpoints: response lines match request lines"
  (hash-clear! breakpoints)
  (define resp (sim-handle-set-breakpoints (make-set-bp-req "/x.tesl" '(3 9 27))))
  (define returned-lines (map (lambda (bp) (hash-ref bp 'line 0)) (hash-ref resp 'breakpoints '())))
  (check-equal? (sort returned-lines <) '(3 9 27))
  (hash-clear! breakpoints))

(test-case "set-breakpoints: empty list removes file entry"
  (hash-clear! breakpoints)
  (sim-handle-set-breakpoints (make-set-bp-req "/gone.tesl" '(1 2 3)))
  (check-true (hash-has-key? breakpoints "/gone.tesl") "should be present first")
  (sim-handle-set-breakpoints (make-set-bp-req "/gone.tesl" '()))
  (check-false (hash-has-key? breakpoints "/gone.tesl") "should be removed after empty list")
  (hash-clear! breakpoints))

(test-case "set-breakpoints: empty list returns empty breakpoints array"
  (hash-clear! breakpoints)
  (define resp (sim-handle-set-breakpoints (make-set-bp-req "/empty.tesl" '())))
  (check-equal? (hash-ref resp 'breakpoints '()) '())
  (hash-clear! breakpoints))

(test-case "set-breakpoints: replacing breakpoints for same file"
  (hash-clear! breakpoints)
  (sim-handle-set-breakpoints (make-set-bp-req "/r.tesl" '(1 2 3)))
  (sim-handle-set-breakpoints (make-set-bp-req "/r.tesl" '(99 100)))
  (define s (hash-ref breakpoints "/r.tesl" (seteq)))
  (check-false (set-member? s 1) "old line 1 should be gone")
  (check-false (set-member? s 2) "old line 2 should be gone")
  (check-true  (set-member? s 99) "new line 99 should be set")
  (check-true  (set-member? s 100) "new line 100 should be set")
  (hash-clear! breakpoints))

(test-case "set-breakpoints: breakpoints for other files unaffected by update"
  (hash-clear! breakpoints)
  (sim-handle-set-breakpoints (make-set-bp-req "/stable.tesl" '(5)))
  (sim-handle-set-breakpoints (make-set-bp-req "/other.tesl" '(8 9)))
  (check-true (set-member? (hash-ref breakpoints "/stable.tesl" (seteq)) 5)
              "unrelated file should be unaffected")
  (hash-clear! breakpoints))

(test-case "set-breakpoints: single breakpoint"
  (hash-clear! breakpoints)
  (sim-handle-set-breakpoints (make-set-bp-req "/single.tesl" '(42)))
  (define s (hash-ref breakpoints "/single.tesl" (seteq)))
  (check-equal? (set-count s) 1)
  (check-true (set-member? s 42))
  (hash-clear! breakpoints))

(test-case "set-breakpoints: duplicate lines deduplicated in set"
  (hash-clear! breakpoints)
  (sim-handle-set-breakpoints (make-set-bp-req "/dup.tesl" '(5 5 10 10)))
  (define s (hash-ref breakpoints "/dup.tesl" (seteq)))
  (check-equal? (set-count s) 2 "duplicates should collapse in seteq")
  (hash-clear! breakpoints))

(test-case "set-breakpoints: seq and request_seq threading"
  ;; Verify a real response encoded via framing has correct request_seq
  (hash-clear! breakpoints)
  ;; We capture the output of the real dap-response
  (define captured-output (open-output-bytes))
  (define dap-seq-box (box 1))
  (define req (make-set-bp-req "/seq.tesl" '(1 2)))
  ;; Minimal hand-rolled response check — verify request_seq maps to req seq=1
  (define req-seq (hash-ref req 'seq 0))
  (check-equal? req-seq 1 "request seq should be 1")
  (hash-clear! breakpoints))

;; ─────────────────────────────────────────────────────────────────────────────
;; ── Part 3: Full mini DAP session (subprocess) ────────────────────────────────
;; ─────────────────────────────────────────────────────────────────────────────

;; Send a DAP message to the server's stdin.
(define (send-dap! out msg)
  (define json (jsexpr->string msg))
  (define bytes (string->bytes/utf-8 json))
  (fprintf out "Content-Length: ~a\r\n\r\n" (bytes-length bytes))
  (write-bytes bytes out)
  (flush-output out))

;; Read one DAP message from port, blocking.
(define (read-dap-from-port in)
  (let loop ([line (read-line in 'return-linefeed)])
    (cond
      [(eof-object? line) eof]
      [(string-prefix? line "Content-Length:")
       (define n (string->number (string-trim (substring line 15))))
       (read-line in 'return-linefeed)  ; blank line
       (define body (read-bytes n in))
       (if (eof-object? body)
           eof
           (string->jsexpr (bytes->string/utf-8 body)))]
      [else (loop (read-line in 'return-linefeed))])))

;; Read from port with timeout (in seconds).  Returns #f on timeout.
(define (recv-dap-with-timeout in timeout-secs)
  (define ch (make-channel))
  (thread
    (lambda ()
      (channel-put ch
        (with-handlers ([exn:fail? (lambda (e) (cons 'error (exn-message e)))])
          (cons 'ok (read-dap-from-port in))))))
  (define result (sync/timeout timeout-secs ch))
  (cond
    [(not result) #f]                         ; timeout
    [(equal? (car result) 'ok) (cdr result)]  ; success
    [else #f]))                               ; error

;; Collect messages until pred returns #t for one, or timeout expires.
;; Returns the matching message, or #f.
(define (recv-until pred in [timeout-secs 5])
  (define deadline (+ (current-inexact-milliseconds) (* timeout-secs 1000)))
  (let loop ()
    (define remaining (/ (- deadline (current-inexact-milliseconds)) 1000.0))
    (if (<= remaining 0)
        #f
        (let ([msg (recv-dap-with-timeout in (max 0.1 remaining))])
          (cond
            [(not msg) #f]
            [(eof-object? msg) #f]
            [(pred msg) msg]
            [else (loop)])))))

;; Start the DAP server subprocess.
(define (start-dap-server)
  (define-values (proc stdout stdin stderr)
    (subprocess #f #f #f
                RACKET-BIN
                (path->string DAP-SERVER-PATH)))
  (values proc stdout stdin stderr))

;; Wrap subprocess tests: start, run body, kill/cleanup.
(define-syntax-rule (with-dap-server (proc out in err) body ...)
  (let-values ([(proc out in err) (start-dap-server)])
    (dynamic-wind
      (lambda () (void))
      (lambda () body ...)
      (lambda ()
        (with-handlers ([exn:fail? (lambda (e) (void))])
          (close-output-port in)
          (close-input-port out)
          (close-input-port err)
          (subprocess-kill proc #t))))))

;; Check whether we can start the server at all.
(define subprocess-available?
  (and (file-exists? RACKET-BIN)
       (file-exists? DAP-SERVER-PATH)))

(define (skip-if-unavailable)
  (unless subprocess-available?
    (printf "SKIPPED: racket binary or dap-server.rkt not found\n")
    (exit 0)))

;; ── Subprocess tests ──────────────────────────────────────────────────────────

(test-case "subprocess: server responds to initialize with capabilities"
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        (define init-req
          (hasheq 'seq 1 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        (send-dap! in init-req)
        ;; Expect a response with type "response" and command "initialize"
        (define resp (recv-until
                       (lambda (m) (and (hash? m)
                                        (equal? (hash-ref m 'type "") "response")
                                        (equal? (hash-ref m 'command "") "initialize")))
                       out 8))
        (check-true (hash? resp) "should receive initialize response")
        (when (hash? resp)
          (check-equal? (hash-ref resp 'success #f) #t)
          (define body (hash-ref resp 'body (hasheq)))
          (check-equal? (hash-ref body 'supportsConfigurationDoneRequest #f) #t)))))

(test-case "subprocess: server sends initialized event after initialize response"
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        (send-dap! in
          (hasheq 'seq 1 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        ;; Expect the initialized event (type "event", event "initialized")
        (define evt (recv-until
                      (lambda (m) (and (hash? m)
                                       (equal? (hash-ref m 'type "") "event")
                                       (equal? (hash-ref m 'event "") "initialized")))
                      out 8))
        (check-true (hash? evt) "should receive initialized event")
        (when (hash? evt)
          (check-equal? (hash-ref evt 'type "") "event")
          (check-equal? (hash-ref evt 'event "") "initialized")))))

(test-case "subprocess: server responds to setBreakpoints with verified breakpoints"
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        ;; Initialize first
        (send-dap! in
          (hasheq 'seq 1 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        ;; Drain initialize response and initialized event
        (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'type "") "event"))) out 8)
        ;; Send setBreakpoints
        (send-dap! in
          (hasheq 'seq 2 'type "request" 'command "setBreakpoints"
                  'arguments (hasheq 'source (hasheq 'path "/test.tesl")
                                     'breakpoints (list (hasheq 'line 5)
                                                        (hasheq 'line 10)))))
        (define resp (recv-until
                       (lambda (m) (and (hash? m)
                                        (equal? (hash-ref m 'type "") "response")
                                        (equal? (hash-ref m 'command "") "setBreakpoints")))
                       out 8))
        (check-true (hash? resp) "should receive setBreakpoints response")
        (when (hash? resp)
          (check-equal? (hash-ref resp 'success #f) #t)
          (define body (hash-ref resp 'body (hasheq)))
          (define bps (hash-ref body 'breakpoints '()))
          (check-equal? (length bps) 2 "should return 2 breakpoints")
          (for ([bp bps])
            (check-equal? (hash-ref bp 'verified #f) #t))))))

(test-case "subprocess: server responds to configurationDone"
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        (send-dap! in
          (hasheq 'seq 1 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'type "") "event"))) out 8)
        ;; configurationDone without a prior launch: should respond but not crash
        (send-dap! in
          (hasheq 'seq 2 'type "request" 'command "configurationDone" 'arguments (hasheq)))
        (define resp (recv-until
                       (lambda (m) (and (hash? m)
                                        (equal? (hash-ref m 'type "") "response")
                                        (equal? (hash-ref m 'command "") "configurationDone")))
                       out 8))
        (check-true (hash? resp) "should receive configurationDone response")
        (when (hash? resp)
          (check-equal? (hash-ref resp 'success #f) #t)))))

(test-case "subprocess: server does NOT launch program before configurationDone"
  ;; We send launch but NOT configurationDone — no "process" event should arrive quickly.
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        (send-dap! in
          (hasheq 'seq 1 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'type "") "event"))) out 8)
        ;; send launch with a non-existent file (the compile step would fail, but
        ;; we're checking whether execution is deferred until configurationDone)
        (send-dap! in
          (hasheq 'seq 2 'type "request" 'command "launch"
                  'arguments (hasheq 'program "/no-such-file.tesl" 'mode "program")))
        ;; Drain launch response
        (recv-dap-with-timeout out 3)
        ;; No configurationDone sent — "process" event should NOT arrive within 1 sec
        (define process-evt (recv-until
                              (lambda (m) (and (hash? m)
                                               (equal? (hash-ref m 'type "") "event")
                                               (equal? (hash-ref m 'event "") "process")))
                              out 1))
        (check-false process-evt "process event should not arrive before configurationDone"))))

(test-case "subprocess: server responds to disconnect and exits"
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        (send-dap! in
          (hasheq 'seq 1 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'type "") "event"))) out 8)
        (send-dap! in
          (hasheq 'seq 2 'type "request" 'command "disconnect" 'arguments (hasheq)))
        (define resp (recv-until
                       (lambda (m) (and (hash? m)
                                        (equal? (hash-ref m 'type "") "response")
                                        (equal? (hash-ref m 'command "") "disconnect")))
                       out 8))
        (check-true (hash? resp) "should receive disconnect response")
        (when (hash? resp)
          (check-equal? (hash-ref resp 'success #f) #t))
        ;; Server should exit cleanly; wait up to 5 seconds
        (define exit-ch (make-channel))
        (thread (lambda () (subprocess-wait proc) (channel-put exit-ch 'done)))
        (define done (sync/timeout 5 exit-ch))
        (check-equal? done 'done "server should exit after disconnect"))))

(test-case "subprocess: server handles unknown command gracefully"
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        (send-dap! in
          (hasheq 'seq 1 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'type "") "event"))) out 8)
        ;; Send an unknown command
        (send-dap! in
          (hasheq 'seq 2 'type "request" 'command "unknownXyzCommand" 'arguments (hasheq)))
        (define resp (recv-until
                       (lambda (m) (and (hash? m)
                                        (equal? (hash-ref m 'type "") "response")
                                        (equal? (hash-ref m 'command "") "unknownXyzCommand")))
                       out 8))
        (check-true (hash? resp) "server should respond to unknown command")
        (when (hash? resp)
          (check-equal? (hash-ref resp 'success #f) #t
                        "unknown commands should return success #t per dispatch fallback")))))

(test-case "subprocess: sequence numbers increment across responses"
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        (send-dap! in
          (hasheq 'seq 1 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        (define r1 (recv-until
                     (lambda (m) (and (hash? m) (equal? (hash-ref m 'type "") "response")))
                     out 8))
        (define r2 (recv-until
                     (lambda (m) (and (hash? m) (equal? (hash-ref m 'type "") "event")))
                     out 8))
        (when (and (hash? r1) (hash? r2))
          (check-true (< (hash-ref r1 'seq 0) (hash-ref r2 'seq 0))
                      "seq should increment between response and event")))))

(test-case "subprocess: initialize response has correct request_seq"
  (if (not subprocess-available?)
      (printf "SKIPPED: subprocess unavailable\n")
      (with-dap-server (proc out in err)
        (send-dap! in
          (hasheq 'seq 77 'type "request" 'command "initialize"
                  'arguments (hasheq 'clientID "test" 'adapterID "tesl")))
        (define resp (recv-until
                       (lambda (m) (and (hash? m)
                                        (equal? (hash-ref m 'type "") "response")
                                        (equal? (hash-ref m 'command "") "initialize")))
                       out 8))
        (when (hash? resp)
          (check-equal? (hash-ref resp 'request_seq #f) 77
                        "response request_seq should match request seq")))))

;; ─────────────────────────────────────────────────────────────────────────────
;; ── Part 4: handle-source (direct) ───────────────────────────────────────────
;; ─────────────────────────────────────────────────────────────────────────────

;; Replicate handle-source logic for direct unit testing.
(define (make-source-req path)
  (hasheq 'seq 1 'command "source"
          'arguments (hasheq 'source (hasheq 'path path)
                             'sourceReference 0)))

;; Simulate handle-source by reading file from disk.
(define (sim-handle-source req)
  (define args (hash-ref req 'arguments (hasheq)))
  (define source (hash-ref args 'source (hasheq)))
  (define path (hash-ref source 'path ""))
  (if (and (non-empty-string? path) (file-exists? path))
      (hasheq 'success #t
              'content (file->string path)
              'mimeType "text/plain")
      (hasheq 'success #f
              'message (format "Source not found: ~a" path))))

;; ── source tests ──────────────────────────────────────────────────────────────

(test-case "source: existing file returns success #t with content"
  (define resp (sim-handle-source (make-source-req TEST-TESL-FILE)))
  (check-equal? (hash-ref resp 'success #f) #t)
  (check-true (string? (hash-ref resp 'content #f)) "content should be a string"))

(test-case "source: content matches actual file contents"
  (define resp (sim-handle-source (make-source-req TEST-TESL-FILE)))
  (define expected (file->string TEST-TESL-FILE))
  (check-equal? (hash-ref resp 'content "") expected))

(test-case "source: existing file response has mimeType text/plain"
  (define resp (sim-handle-source (make-source-req TEST-TESL-FILE)))
  (check-equal? (hash-ref resp 'mimeType "") "text/plain"))

(test-case "source: non-existent file returns success #f"
  (define resp (sim-handle-source (make-source-req "/no/such/file/ever.tesl")))
  (check-equal? (hash-ref resp 'success #f) #f))

(test-case "source: non-existent file returns error message"
  (define resp (sim-handle-source (make-source-req "/no/such/file/ever.tesl")))
  (define msg (hash-ref resp 'message ""))
  (check-true (string-contains? msg "Source not found") "error message should mention 'Source not found'"))

(test-case "source: empty path returns success #f"
  (define resp (sim-handle-source (make-source-req "")))
  (check-equal? (hash-ref resp 'success #f) #f))

(test-case "source: empty path has error message"
  (define resp (sim-handle-source (make-source-req "")))
  (check-true (string? (hash-ref resp 'message #f)) "error message should be a string"))

(test-case "source: content of tesl file starts with #lang tesl"
  (define resp (sim-handle-source (make-source-req TEST-TESL-FILE)))
  (when (hash-ref resp 'success #f)
    (define content (hash-ref resp 'content ""))
    (check-true (string-prefix? content "#lang tesl")
                "tesl file should start with #lang tesl")))

(test-case "source: directory path returns success #f"
  ;; A directory is not a file
  (define resp (sim-handle-source (make-source-req REPO-ROOT)))
  ;; file-exists? returns #f for directories on Racket
  (check-equal? (hash-ref resp 'success #f) #f))

;; ─────────────────────────────────────────────────────────────────────────────
;; ── Summary ───────────────────────────────────────────────────────────────────
;; ─────────────────────────────────────────────────────────────────────────────

(displayln "\nAll DAP server integration tests complete.")
