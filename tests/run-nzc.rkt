#lang racket/base
;; Non-zero-cost proof-test driver.
;;
;; Runs each given .rkt test module with the evidence-bearing proof machinery
;; enabled — the caller sets TESL_ZERO_COST_PROOFS=0 so proofs are NOT erased.
;; These modules (check-test, exists-test, sql-test, web-test, record-test, …)
;; assert on detach-proof / detached-proof-* / attach-proof / facts-of and on
;; validation exceptions that are erased under the default zero-cost mode, so they
;; can only pass when compiled in non-zero-cost mode.
;;
;; use-compiled-file-paths is cleared so the non-zero-cost build is done in-memory
;; — it neither reads nor clobbers the default zero-cost bytecode cache that the
;; rest of the suite (and the zero-cost example-batch) shares.  Running every such
;; module in ONE process means the shared deps (dsl/*, tesl/*) compile once and are
;; reused, instead of a full recompile per test.
;;
;; Each module's rackunit checks run at instantiation; a check failure prints
;; "FAILURE" (caught by the caller's output scan), and a raised exn is reported as
;; "NZC-ERROR" and forces a non-zero exit.
(require racket/cmdline)

(define failed? #f)
(define paths (vector->list (current-command-line-arguments)))

(parameterize ([use-compiled-file-paths null])
  (for ([p (in-list paths)])
    (with-handlers ([(lambda (_) #t)
                     (lambda (e)
                       (set! failed? #t)
                       (eprintf "NZC-ERROR ~a: ~a\n"
                                p (if (exn? e) (exn-message e) e)))])
      (dynamic-require `(file ,p) #f))))

(when failed? (exit 1))
