#lang racket

;; dap-stop-the-world-smoke.rkt — proves the DAP "stop-the-world" pause (task #42)
;; actually FREEZES registered background threads while the debuggee is paused and
;; THAWS them cleanly on resume, without ever suspending the thread that must
;; service `continue` (the breakpoint thread = current-thread here).
;;
;; This is a focused unit smoke over the suspend/resume mechanism in
;; dsl/debug/checkpoint.rkt + the dsl/private/domain-registry.rkt thread registry,
;; so it is deterministic (no DAP stdio session needed). The full pause flow
;; (suspend! → park on paused-ch → resume!) is exercised by the integration tests.

(require rackunit
         "../dsl/debug/checkpoint.rkt"
         "../dsl/private/domain-registry.rkt")

;; Background-thread registration is DEBUG-GATED (only records under TESL_DEBUG),
;; mirroring how the DAP server sets the env before launching the debuggee.
(putenv "TESL_DEBUG" "1")

(define (spin)
  ;; a long-lived background worker that would keep running if not frozen
  (thread (lambda () (let loop () (sleep 0.001) (loop)))))

(test-case "stop-the-world freezes registered bg threads, excludes the bp/current thread, resumes cleanly"
  (define w1 (register-background-thread! (spin)))
  (define w2 (register-background-thread! (spin)))
  (sleep 0.05) ; let them start running
  (check-true (thread-running? w1) "w1 running before pause")
  (check-true (thread-running? w2) "w2 running before pause")

  ;; Freeze the world. This test thread stands in for the breakpoint thread and
  ;; MUST be excluded (it would otherwise self-deadlock the resume).
  (stop-the-world-suspend!)
  (check-false (thread-running? w1) "w1 suspended while paused")
  (check-false (thread-running? w2) "w2 suspended while paused")
  (check-true  (thread-running? (current-thread)) "bp/current thread never suspended")
  (check-true  (>= (stop-the-world-suspended-count) 2)
               "suspended-count counts the frozen background threads")

  ;; Thaw exactly what we froze.
  (stop-the-world-resume!)
  (sleep 0.03)
  (check-true (thread-running? w1) "w1 resumed after continue")
  (check-true (thread-running? w2) "w2 resumed after continue")

  (kill-thread w1)
  (kill-thread w2))

(test-case "a dead background thread is skipped (suspend never raises on it)"
  (define d (register-background-thread! (thread (lambda () (void)))))
  (sync (thread-dead-evt d))
  (check-not-exn (lambda () (stop-the-world-suspend!)))
  (check-not-exn (lambda () (stop-the-world-resume!))))

(module+ main (void))
