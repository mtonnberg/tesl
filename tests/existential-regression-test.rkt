#lang racket

(require rackunit
         racket/runtime-path)

(provide existential-regression-suite)

(define-runtime-path check-rkt "../dsl/check.rkt")
(define-runtime-path web-rkt "../dsl/web.rkt")

(define (run-temp-module source [provided #f])
  (define temp-path (make-temporary-file "tesl-regression-~a.rkt"))
  (call-with-output-file temp-path
    (lambda (out)
      (display source out))
    #:exists 'replace)
  (dynamic-wind
    void
    (lambda ()
      (dynamic-require temp-path provided))
    (lambda ()
      (when (file-exists? temp-path)
        (delete-file temp-path)))))

(define unpack-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define packed-value
  (pack ([userId \"anna\"])
    *userId))
(define unpacked
  (unpack packed-value ([userId] value)
    value))
(provide unpacked)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define existential-regression-suite
  (test-suite
   "existential regressions"
   (test-case "existential unpacking should be available"
     (check-not-exn (lambda ()
                      (run-temp-module unpack-module 'unpacked))))))
