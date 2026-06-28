#lang racket/base
;; Non-zero-cost runner for the body-proof regression SUITE.
;;
;; Unlike check-test / exists-test / … (whose rackunit checks run at module
;; instantiation, so run-nzc.rkt's `dynamic-require … #f` exercises them), the
;; body-proof regressions are packaged as a `body-proof-suite` value that the
;; caller must hand to `run-tests`.  They assert on evidence-bearing proof
;; behaviour (detach-proof / attached proofs / Skolem-witness scoping) that is
;; ERASED under the production zero-cost default, so they only pass when proofs
;; are NOT erased — the caller sets TESL_ZERO_COST_PROOFS=0.
;;
;; `use-compiled-file-paths` is cleared so the non-zero-cost build is in-memory:
;; it neither reads nor clobbers the default zero-cost bytecode cache shared with
;; the zero-cost example-batch (the bytecode-accident the suite must avoid — see
;; roadmap/next/nonzero_cost_test_harness.md).
(require rackunit/text-ui
         racket/runtime-path)

(define-runtime-path body-proof-path "body-proof-test.rkt")

(parameterize ([use-compiled-file-paths null])
  (define suite (dynamic-require `(file ,(path->string body-proof-path)) 'body-proof-suite))
  (when (positive? (run-tests suite)) (exit 1)))
