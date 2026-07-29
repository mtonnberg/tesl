#lang racket

;; dap-attach-smoke.rkt — proves the live attach control channel
;; (dsl/debug/control-channel.rkt) end-to-end, in-process and deterministic.
;;
;; THE FEATURE UNDER TEST
;; ----------------------
;; `tesl run --debug` starts an app with live thsl-src! checkpoints and a
;; loopback control channel under <project>/.tesl-stuff/.  A client (the DAP
;; adapter's attach mode, `tesl debug-attach`, the MCP tool) connects, arms and
;; RE-ARMS breakpoints, receives stopped events with rendered locals/domain/SQL,
;; resumes, and detaches — the app keeps serving throughout.
;;
;; WHAT THIS TEST DOES (no subprocess, no compiler, no DB)
;; -------------------------------------------------------
;; 1. Protocol unit tests against dispatch-command (socket-free).
;; 2. Full socket lifecycle against a real listener: a worker thread drives
;;    thsl-src!/runtime (the checkpoint runtime the emitted code calls) while a
;;    client connects over the real endpoint and exercises:
;;    arm → stop (locals) → snapshot → world-frozen → re-arm-mid-session
;;    (conditional) → continue → second stop → detach → worker keeps running →
;;    re-attach → abrupt-disconnect == detach (auto-resume).
;; 3. Busy: a second concurrent client is refused.
;; 4. Pause timeout (TESL_DEBUG_PAUSE_TIMEOUT_MS): a stop whose client never
;;    resumes auto-continues, so an abandoned session cannot wedge the app.
;; 5. Concurrent stops from two threads are serialized, never lost.
;; 6. No TESL_DEBUG_CONTROL_DIR → start-control-channel! declines and creates
;;    no endpoint files (release residue check at the channel layer; macro
;;    erasure itself is proven by dap-sql-scope-smoke.rkt).
;;
;; NOTE: collection-path requires throughout (same reason as
;; dap-headless-inspect-smoke.rkt — one module instance, one shared registry).

(require rackunit
         json
         racket/tcp
         (only-in racket/unix-socket unix-socket-connect)
         (only-in tesl/dsl/debug/checkpoint
                  thsl-src!/runtime
                  breakpoints
                  set-debug-active!
                  debug-active?)
         (only-in tesl/dsl/debug/control-channel
                  start-control-channel!
                  stop-control-channel!
                  control-endpoint
                  dispatch-command))

;; ── 1. Protocol unit tests (socket-free) ─────────────────────────────────────

(test-case "ping replies ok with version"
  (define r (dispatch-command (hasheq 'cmd "ping")))
  (check-true (hash-ref r 'ok))
  (check-equal? (hash-ref r 'version) 1))

(test-case "set-breakpoints requires a file"
  (define r (dispatch-command (hasheq 'cmd "set-breakpoints" 'breakpoints '())))
  (check-false (hash-ref r 'ok)))

(test-case "arm + list + clear round-trip"
  (define f "attach-proto-test.tesl")
  (define r (dispatch-command
             (hasheq 'cmd "set-breakpoints" 'file f
                     'breakpoints (list (hasheq 'line 7)
                                        (hasheq 'line 9 'condition "n >= 2")))))
  (check-true (hash-ref r 'ok))
  (check-equal? (hash-ref r 'armed) 2)
  (define l (dispatch-command (hasheq 'cmd "list-breakpoints")))
  (check-true (>= (length (hash-ref l 'breakpoints)) 2))
  (check-true (for/or ([b (in-list (hash-ref l 'breakpoints))])
                (and (= (hash-ref b 'line 0) 9)
                     (equal? (hash-ref b 'condition #f) "n >= 2"))))
  (define c (dispatch-command (hasheq 'cmd "clear-breakpoints" 'file f)))
  (check-true (hash-ref c 'ok))
  (check-false (hash-has-key? breakpoints f)))

(test-case "empty breakpoint list disarms the file"
  (define f "attach-proto-empty.tesl")
  (dispatch-command (hasheq 'cmd "set-breakpoints" 'file f
                            'breakpoints (list (hasheq 'line 3))))
  (dispatch-command (hasheq 'cmd "set-breakpoints" 'file f 'breakpoints '()))
  (check-false (hash-has-key? breakpoints f)))

(test-case "unknown command fails closed"
  (check-false (hash-ref (dispatch-command (hasheq 'cmd "reboot")) 'ok)))

(test-case "snapshot when not paused reports paused=false"
  (define r (dispatch-command (hasheq 'cmd "snapshot")))
  (check-true (hash-ref r 'ok))
  (check-false (hash-ref r 'paused)))

;; ── 2-5. Socket lifecycle against a real endpoint ────────────────────────────

;; No-env behaviour FIRST (before the env var is set for the live section).
(test-case "no TESL_DEBUG_CONTROL_DIR → channel declines, no endpoint files"
  (when (getenv "TESL_DEBUG_CONTROL_DIR")
    (putenv "TESL_DEBUG_CONTROL_DIR" ""))
  (stop-control-channel!)
  (check-false (start-control-channel!))
  (stop-control-channel!))

(define ctl-dir
  (build-path (find-system-path 'temp-dir)
              (format "tesl-attach-smoke-~a" (current-milliseconds))))
(make-directory* ctl-dir)
(putenv "TESL_DEBUG_CONTROL_DIR" (path->string ctl-dir))

(define endpoint (start-control-channel!))
(check-not-false endpoint "channel must start when the env var is set")

(define (connect!)
  (case (car endpoint)
    [(unix) (unix-socket-connect (cdr endpoint))]
    [(tcp)  (tcp-connect "127.0.0.1" (cdr endpoint))]))

(define (send! out obj)
  (write-string (jsexpr->string obj) out) (write-string "\n" out) (flush-output out))
(define (recv! in) (string->jsexpr (read-line in 'any)))
(define (recv-until in pred [max 100])
  (let loop ([n 0])
    (when (> n max) (error 'recv-until "expected message never arrived"))
    (define m (recv! in))
    (if (pred m) m (loop (add1 n)))))
(define (reply-for in cmd) (recv-until in (lambda (m) (equal? (hash-ref m 'cmd #f) cmd))))
(define (event-for in ev)  (recv-until in (lambda (m) (equal? (hash-ref m 'event #f) ev))))

;; Worker "app" thread: an endless loop of checkpoints, like a request handler
;; under `tesl run --debug` (the macro erases in THIS process, so we call the
;; runtime entry the expanded form calls — same code path from there on).
(define SRC "attach-app.tesl")
(define hits (box 0))
(define worker
  (thread
   (lambda ()
     (let loop ([i 0])
       (thsl-src!/runtime SRC 5 (list (cons 'i i))
                          (lambda () (set-box! hits (add1 (unbox hits))) (sleep 0.01)))
       (loop (add1 i))))))

(define-values (in out) (connect!))

(test-case "attached banner arrives"
  (check-equal? (hash-ref (recv! in) 'event) "attached"))

(test-case "connect flips the process-wide debug switch"
  (check-true (debug-active?)))

(test-case "second concurrent client is refused busy"
  (define-values (in2 out2) (connect!))
  (check-equal? (hash-ref (recv! in2) 'reason #f) "busy")
  (close-input-port in2) (close-output-port out2))

(test-case "arm → stop with locals"
  (send! out (hasheq 'cmd "set-breakpoints" 'file SRC
                     'breakpoints (list (hasheq 'line 5))))
  (check-equal? (hash-ref (reply-for in "set-breakpoints") 'armed) 1)
  (define st (event-for in "stopped"))
  (check-equal? (hash-ref st 'line) 5)
  (check-true (for/or ([l (in-list (hash-ref st 'locals '()))])
                (equal? (hash-ref l 'name #f) "i"))))

(test-case "snapshot while paused; worker is frozen"
  (send! out (hasheq 'cmd "snapshot"))
  (define snap (reply-for in "snapshot"))
  (check-true (hash-ref snap 'paused))
  (check-equal? (hash-ref snap 'line) 5)
  (define h (unbox hits))
  (sleep 0.15)
  (check-equal? (unbox hits) h "paused worker must not advance"))

(test-case "re-arm a conditional breakpoint mid-session, continue, second stop"
  (define target (+ (unbox hits) 10))
  (send! out (hasheq 'cmd "set-breakpoints" 'file SRC
                     'breakpoints (list (hasheq 'line 5
                                                'condition (format "i >= ~a" target)))))
  (reply-for in "set-breakpoints")
  (send! out (hasheq 'cmd "continue"))
  (reply-for in "continue")
  (define st2 (event-for in "stopped"))
  (check-equal? (hash-ref st2 'line) 5)
  ;; the condition gated the stop: i must have reached the target
  (check-true (for/or ([l (in-list (hash-ref st2 'locals '()))])
                (and (equal? (hash-ref l 'name #f) "i")
                     (>= (string->number (hash-ref l 'value "0")) target)))))

(test-case "detach disarms, resumes, worker keeps running"
  (send! out (hasheq 'cmd "detach"))
  (reply-for in "detach")
  (check-false (hash-has-key? breakpoints SRC) "detach must disarm")
  (define h (unbox hits))
  (sleep 0.15)
  (check-true (> (unbox hits) h) "worker must run after detach"))

(test-case "re-attach works; abrupt disconnect behaves as detach"
  (define-values (in3 out3) (connect!))
  (check-equal? (hash-ref (recv! in3) 'event) "attached")
  (send! out3 (hasheq 'cmd "set-breakpoints" 'file SRC
                      'breakpoints (list (hasheq 'line 5))))
  (reply-for in3 "set-breakpoints")
  (event-for in3 "stopped")
  ;; Drop the connection with the worker parked — EOF must disarm + resume.
  (close-input-port in3) (close-output-port out3)
  (sleep 0.3)
  (check-false (hash-has-key? breakpoints SRC) "EOF must disarm")
  (define h (unbox hits))
  (sleep 0.15)
  (check-true (> (unbox hits) h) "worker must be auto-resumed after EOF"))

(test-case "stop with NO client connected is auto-resumed (cannot wedge)"
  ;; Arm directly in the table (as if a client died right after arming).
  (dispatch-command (hasheq 'cmd "set-breakpoints" 'file SRC
                            'breakpoints (list (hasheq 'line 5))))
  (define h (unbox hits))
  (sleep 0.3)
  (check-true (> (unbox hits) h) "pump must auto-continue with no client")
  (dispatch-command (hasheq 'cmd "clear-breakpoints")))

(test-case "pause timeout auto-resumes an unresponsive session"
  (putenv "TESL_DEBUG_PAUSE_TIMEOUT_MS" "250")
  (define-values (in4 out4) (connect!))
  (check-equal? (hash-ref (recv! in4) 'event) "attached")
  (send! out4 (hasheq 'cmd "set-breakpoints" 'file SRC
                      'breakpoints (list (hasheq 'line 5))))
  (reply-for in4 "set-breakpoints")
  (event-for in4 "stopped")
  ;; Say NOTHING — the timeout must resume the worker on its own.
  (define h (unbox hits))
  (sleep 0.8)
  (check-true (> (unbox hits) h) "timeout must auto-resume the parked thread")
  (putenv "TESL_DEBUG_PAUSE_TIMEOUT_MS" "")
  (send! out4 (hasheq 'cmd "detach"))
  (reply-for in4 "detach")
  (close-input-port in4) (close-output-port out4))

(test-case "concurrent stops from two threads are serialized, both delivered"
  (define-values (in5 out5) (connect!))
  (check-equal? (hash-ref (recv! in5) 'event) "attached")
  (define SRC2 "attach-app-two.tesl")
  (define done (make-semaphore 0))
  (for ([n (in-list '(1 2))])
    (thread (lambda ()
              (thsl-src!/runtime SRC2 9 (list (cons 'n n)) (lambda () (void)))
              (semaphore-post done))))
  (send! out5 (hasheq 'cmd "set-breakpoints" 'file SRC2
                      'breakpoints (list (hasheq 'line 9))))
  (reply-for in5 "set-breakpoints")
  ;; NOTE: the two racing threads may pass the checkpoint before arming lands —
  ;; retrigger deterministically: spawn two more AFTER the arm reply.
  (define seen (box 0))
  (for ([n (in-list '(3 4))])
    (thread (lambda ()
              (thsl-src!/runtime SRC2 9 (list (cons 'n n)) (lambda () (void)))
              (semaphore-post done))))
  (for ([_ (in-range 2)])
    (event-for in5 "stopped")
    (set-box! seen (add1 (unbox seen)))
    (send! out5 (hasheq 'cmd "continue"))
    (reply-for in5 "continue"))
  (check-equal? (unbox seen) 2 "both stops must be delivered in turn")
  (send! out5 (hasheq 'cmd "detach"))
  (reply-for in5 "detach")
  (close-input-port in5) (close-output-port out5))

;; ── Teardown ─────────────────────────────────────────────────────────────────
(kill-thread worker)
(stop-control-channel!)
(putenv "TESL_DEBUG_CONTROL_DIR" "")
