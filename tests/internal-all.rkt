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

(define (run-internal-tests)
  (load-test-module check-test-path)
  (load-test-module exists-test-path)
  (load-test-module sql-test-path)
  (load-test-module postgres-test-path)
  (load-test-module example-api-test-path)
  (load-test-module web-test-path)
  (load-test-module record-test-path)
  (run-self-contained-test tesl-test-path 'tesl-test)
  (run-self-contained-test port-test-path 'port-test)
  (define failures
    (+ (run-tests (load-test-suite body-proof-test-path 'body-proof-suite))
       (run-tests (load-test-suite surface-regression-test-path 'surface-regression-suite))
       (run-tests (load-test-suite existential-regression-test-path 'existential-regression-suite))))
  (unless (zero? failures)
    (error 'tests (format "~a supplemental regression tests are failing" failures))))

(if (postgres-tooling-available?)
    (call-with-shared-postgres-cluster (lambda (_cluster-config) (run-internal-tests)))
    (run-internal-tests))
