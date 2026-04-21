#lang racket

(require racket/port
         racket/runtime-path
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

(define-runtime-path tesl-test-path "tesl-test.rkt")

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

(define (run-frontend-tests)
  (run-external-test tesl-test-path 'tesl-test))

(if (postgres-tooling-available?)
    (call-with-shared-postgres-cluster (lambda (_cluster-config) (run-frontend-tests)))
    (run-frontend-tests))
