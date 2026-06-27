#lang racket

(require rackunit/text-ui
         racket/port
         racket/runtime-path
         racket/string
         "private/postgres-test-support.rkt")

(define (run-command/capture . argv)
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f argv))
  (close-output-port stdin)
  (define out-ch (make-channel))
  (define err-ch (make-channel))
  (thread (lambda () (channel-put out-ch (port->string stdout))))
  (thread (lambda () (channel-put err-ch (port->string stderr))))
  (subprocess-wait proc)
  (values (subprocess-status proc)
          (channel-get out-ch)
          (channel-get err-ch)))

(define-runtime-path check-test-path "check-test.rkt")
(define-runtime-path body-proof-test-path "body-proof-test.rkt")
(define-runtime-path exists-test-path "exists-test.rkt")
(define-runtime-path sql-test-path "sql-test.rkt")
(define-runtime-path postgres-test-path "postgres-test.rkt")
(define-runtime-path example-api-test-path "example-api-test.rkt")
(define-runtime-path web-test-path "web-test.rkt")
(define-runtime-path record-test-path "record-test.rkt")
(define-runtime-path surface-regression-test-path "surface-regression-test.rkt")
(define-runtime-path existential-regression-test-path "existential-regression-test.rkt")
(define-runtime-path tesl-test-path "tesl-test.rkt")
(define-runtime-path port-test-path "port-test.rkt")
(define-runtime-path codec-specialization-test-path "codec-specialization-test.rkt")

(define (ensure-test-module-compiled path)
  (define raco-path
    (or (find-executable-path "raco")
        (error 'tests "could not find raco on PATH")))
  (define-values (status out err)
    (run-command/capture (path->string raco-path)
                         "make"
                         (path->string path)))
  (unless (zero? status)
    (display out)
    (unless (string=? err "")
      (display err (current-error-port)))
    (error 'tests (format "failed to compile test module: ~a" path))))

(define (load-test-module path)
  (ensure-test-module-compiled path)
  (dynamic-require `(file ,(path->string path)) #f))

(define (load-test-suite path suite-name)
  (ensure-test-module-compiled path)
  (dynamic-require `(file ,(path->string path)) suite-name))

(define (inline-external-tests?)
  (define value (getenv "TESL_TEST_INLINE_EXTERNAL"))
  (not (and value
            (member (string-downcase value)
                    '("0" "false" "no" "off")))))

(define (run-inline-test path label)
  (ensure-test-module-compiled path)
  (define test-namespace (make-base-namespace))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (error 'tests
                            (format "inline test failed: ~a (~a)"
                                    label
                                    (exn-message exn))))])
    (parameterize ([current-namespace test-namespace])
      (dynamic-require `(file ,(path->string path)) #f))))

(define (run-external-test path label)
  (ensure-test-module-compiled path)
  (define racket-path
    (or (find-executable-path "racket")
        (error 'tests "could not find racket on PATH")))
  (define-values (status out err)
    (run-command/capture (path->string racket-path)
                         (path->string path)))
  (display out)
  (unless (string=? err "")
    (display err (current-error-port)))
  (when (or (not (zero? status))
            (regexp-match? #px"(^|\n)(FAILURE|ERROR)(\n|$)" out)
            (regexp-match? #px"(^|\n)(FAILURE|ERROR)(\n|$)" err))
    (error 'tests (format "external test failed: ~a" label))))

(define (run-self-contained-test path label)
  (if (inline-external-tests?)
      (run-inline-test path label)
      (run-external-test path label)))

;; Several internal tests (check-test, exists-test, sql-test, web-test,
;; record-test) validate the *evidence-bearing* proof/validation machinery —
;; detach-proof / detached-proof-* / attach-proof / facts-of, and check-exn on
;; validation exceptions that are *erased* under the default zero-cost mode.  That
;; machinery only exists when proofs are NOT erased (TESL_ZERO_COST_PROOFS=0).
;; Zero-cost erasure is the production default and the mode this suite otherwise
;; runs in, so these must be compiled+run with the flag flipped.  We run them all
;; in ONE subprocess (tests/run-nzc.rkt) with use-compiled-file-paths cleared: the
;; non-zero-cost build is in-memory (never clobbering the default zero-cost cache
;; shared with the zero-cost example-batch) and the shared deps compile once,
;; instead of a full recompile per test.  See
;; roadmap/next/nonzero_cost_test_harness.md.
(define-runtime-path nzc-driver-path "run-nzc.rkt")

(define (run-non-zero-cost-tests paths)
  (define racket-path
    (or (find-executable-path "racket")
        (error 'tests "could not find racket on PATH")))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"TESL_ZERO_COST_PROOFS" #"0")
  (define argv
    (cons (path->string nzc-driver-path)
          (for/list ([p (in-list paths)]) (path->string p))))
  (define-values (status out err)
    (parameterize ([current-environment-variables env])
      (apply run-command/capture (path->string racket-path) argv)))
  (display out)
  (unless (string=? err "")
    (display err (current-error-port)))
  (when (or (not (zero? status))
            (regexp-match? #px"(^|\n)(FAILURE|ERROR)(\n|$)" out)
            (regexp-match? #px"NZC-ERROR" out)
            (regexp-match? #px"NZC-ERROR" err))
    (error 'tests "one or more non-zero-cost proof tests failed")))

(define (run-internal-tests)
  (run-non-zero-cost-tests
   (list check-test-path exists-test-path sql-test-path
         web-test-path record-test-path))
  (load-test-module postgres-test-path)
  (load-test-module example-api-test-path)
  (run-self-contained-test tesl-test-path 'tesl-test)
  (run-self-contained-test port-test-path 'port-test)
  (run-self-contained-test codec-specialization-test-path 'codec-specialization-test)
  (define failures
    (+ (run-tests (load-test-suite body-proof-test-path 'body-proof-suite))
       (run-tests (load-test-suite surface-regression-test-path 'surface-regression-suite))
       (run-tests (load-test-suite existential-regression-test-path 'existential-regression-suite))))
  (unless (zero? failures)
    (error 'tests (format "~a supplemental regression tests are failing" failures))))

(if (postgres-tooling-available?)
    (call-with-shared-postgres-cluster (lambda (_cluster-config) (run-internal-tests)))
    (run-internal-tests))
