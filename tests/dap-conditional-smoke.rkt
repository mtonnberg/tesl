#lang racket

;; dap-conditional-smoke.rkt — end-to-end smoke test for the conditional-breakpoint
;; and capability features added to THIS WORKTREE's dap-server.rkt.  It launches the
;; worktree dap-server as a subprocess, drives a real conditional-breakpoint session
;; against example/learn/lesson61-step-debugging.tesl in TEST mode, and asserts:
;;   1. initialize advertises supportsConditionalBreakpoints + supportsHitConditionalBreakpoints
;;   2. a conditional breakpoint (n == 100) on the checkScore checkpoint line fires
;;      ONLY for the n=100 invocation (not n=0 / n=75), proving condition eval works
;;   3. the stopped frame's variables include `n` with value 100
;;
;; Paths are taken from env so this runs in any worktree:
;;   TESL_REPO_ROOT  — worktree root (defaults to cwd's repo root)
;;   TESL_COMPILER   — tesl binary
;;   RACKET_BIN      — racket binary (defaults to the running racket)

(require rackunit racket/string json)

(define REPO-ROOT (or (getenv "TESL_REPO_ROOT")
                      (path->string (current-directory))))
(define RACKET-BIN (or (getenv "RACKET_BIN") (find-executable-path "racket")))
(define DAP-SERVER (build-path REPO-ROOT "dsl/debug/dap-server.rkt"))
(define TESL-FILE  (path->string (build-path REPO-ROOT "example/learn/lesson61-step-debugging.tesl")))

;; Pin the worktree-built compiler so the dap-server subprocess does not fall back
;; to a stale PATH `tesl` binary that may not match this worktree (or may not be
;; --debug-capable). Mirrors the gated sibling dap-headless-inspect-conditional-smoke.
(define TESL-BIN (build-path REPO-ROOT "compiler" "_build" "default" "bin" "main.exe"))
(when (and (not (getenv "TESL_COMPILER")) (file-exists? TESL-BIN))
  (putenv "TESL_COMPILER" (path->string TESL-BIN)))
;; The checkScore checkpoint line in lesson61 (thsl-src! "…" 91 (list (cons 'n *n)) …).
(define CHECK-LINE 91)

(define (send! out msg)
  (define b (string->bytes/utf-8 (jsexpr->string msg)))
  (fprintf out "Content-Length: ~a\r\n\r\n" (bytes-length b))
  (write-bytes b out) (flush-output out))

(define (read-msg in)
  (let loop ([line (read-line in 'return-linefeed)])
    (cond
      [(eof-object? line) eof]
      [(string-prefix? line "Content-Length:")
       (define n (string->number (string-trim (substring line 15))))
       (read-line in 'return-linefeed)
       (define body (read-bytes n in))
       (if (eof-object? body) eof (string->jsexpr (bytes->string/utf-8 body)))]
      [else (loop (read-line in 'return-linefeed))])))

(define (recv-with-timeout in secs)
  (define ch (make-channel))
  (thread (lambda () (channel-put ch (with-handlers ([exn:fail? (lambda (_) eof)])
                                       (read-msg in)))))
  (sync/timeout secs ch))

(define (recv-until pred in [secs 20])
  (define deadline (+ (current-inexact-milliseconds) (* secs 1000)))
  (let loop ()
    (define rem (/ (- deadline (current-inexact-milliseconds)) 1000.0))
    (if (<= rem 0) #f
        (let ([m (recv-with-timeout in (max 0.1 rem))])
          (cond [(or (not m) (eof-object? m)) #f]
                [(pred m) m]
                [else (loop)])))))

;; A --debug-capable compiler is required: either TESL_COMPILER is set (pinned above
;; or supplied by the gate) or the worktree binary is built. Without one, the
;; dap-server subprocess would compile with a mismatched/stale PATH `tesl` and the
;; conditional breakpoint could never fire — so we SKIP rather than report a false RED,
;; matching dap-headless-inspect-conditional-smoke.rkt's degrade-to-SKIP behavior.
(define have-compiler? (or (getenv "TESL_COMPILER") (file-exists? TESL-BIN)))
(define ready? (and RACKET-BIN (file-exists? DAP-SERVER) (file-exists? TESL-FILE)
                    have-compiler?))

(cond
  [(not ready?)
   (printf "SKIPPED: prerequisites missing (racket=~a server=~a tesl=~a compiler=~a)\n"
           RACKET-BIN (file-exists? DAP-SERVER) (file-exists? TESL-FILE) have-compiler?)]
  [else
   (define-values (proc out in err)
     (subprocess #f #f #f RACKET-BIN (path->string DAP-SERVER)))
   (dynamic-wind
     void
     (lambda ()
       ;; 1. initialize → capabilities
       (send! in (hasheq 'seq 1 'type "request" 'command "initialize"
                         'arguments (hasheq 'clientID "smoke")))
       (define init-resp
         (recv-until (lambda (m) (and (hash? m)
                                      (equal? (hash-ref m 'type "") "response")
                                      (equal? (hash-ref m 'command "") "initialize"))) out))
       (test-case "initialize advertises conditional-breakpoint capabilities"
         (check-true (hash? init-resp))
         (when (hash? init-resp)
           (define body (hash-ref init-resp 'body (hasheq)))
           (check-equal? (hash-ref body 'supportsConditionalBreakpoints #f) #t)
           (check-equal? (hash-ref body 'supportsHitConditionalBreakpoints #f) #t)))

       ;; 2. setBreakpoints with a CONDITION: n == 100
       (send! in (hasheq 'seq 2 'type "request" 'command "setBreakpoints"
                         'arguments (hasheq 'source (hasheq 'path TESL-FILE)
                                            'breakpoints (list (hasheq 'line CHECK-LINE
                                                                       'condition "n == 100")))))
       (define bp-resp
         (recv-until (lambda (m) (and (hash? m)
                                      (equal? (hash-ref m 'command "") "setBreakpoints"))) out))
       (test-case "conditional breakpoint verified"
         (check-true (hash? bp-resp))
         (when (hash? bp-resp)
           (check-equal? (hash-ref bp-resp 'success #f) #t)))

       ;; 3. launch in TEST mode (runs all tests; checkScore called with n=0,100,75,...)
       (send! in (hasheq 'seq 3 'type "request" 'command "launch"
                         'arguments (hasheq 'program TESL-FILE 'mode "test")))
       (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'command "") "launch"))) out)
       ;; 4. configurationDone → program starts
       (send! in (hasheq 'seq 4 'type "request" 'command "configurationDone" 'arguments (hasheq)))

       ;; 5. wait for the FIRST stopped event — must correspond to n == 100 only.
       (define stopped
         (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'type "") "event")
                                      (equal? (hash-ref m 'event "") "stopped"))) out 30))
       (test-case "conditional breakpoint fires (stopped received)"
         (check-true (hash? stopped) "should receive a stopped event for n==100"))

       (when (hash? stopped)
         ;; Request scopes then variables on the paused frame.
         (send! in (hasheq 'seq 5 'type "request" 'command "scopes"
                           'arguments (hasheq 'frameId 1)))
         (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'command "") "scopes"))) out)
         (send! in (hasheq 'seq 6 'type "request" 'command "variables"
                           'arguments (hasheq 'variablesReference 1)))
         (define vars-resp
           (recv-until (lambda (m) (and (hash? m) (equal? (hash-ref m 'command "") "variables"))) out))
         (test-case "paused frame shows n == 100 (condition matched the right invocation)"
           (check-true (hash? vars-resp))
           (when (hash? vars-resp)
             (define vars (hash-ref (hash-ref vars-resp 'body (hasheq)) 'variables '()))
             (define n-var (findf (lambda (v) (equal? (hash-ref v 'name "") "n")) vars))
             (check-true (hash? n-var) "variable n should be present")
             (when (hash? n-var)
               (check-true (string-contains? (hash-ref n-var 'value "") "100")
                           (format "n should be 100, got ~a" (hash-ref n-var 'value "")))))))

       ;; 6. disconnect
       (send! in (hasheq 'seq 99 'type "request" 'command "disconnect" 'arguments (hasheq)))
       (void))
     (lambda ()
       (with-handlers ([exn:fail? (lambda (_) (void))])
         (close-output-port in) (close-input-port out) (close-input-port err)
         (subprocess-kill proc #t))))
   (displayln "\nDAP conditional-breakpoint smoke test complete.")])
