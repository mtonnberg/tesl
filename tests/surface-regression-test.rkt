#lang racket

(require rackunit
         racket/runtime-path)

(provide surface-regression-suite)

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

(define let-binding-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-trusted
  (let-helper [n : Integer])
  #:returns [result : Integer ::: (Positive result)]
  (let ([result 5])
    (attach-proof (ensure-named result *result)
                  (trusted-proof (Positive result)))))
(define-handler
  (let-handler [n : Integer])
  #:returns [result : Integer ::: (Positive result)]
  (let-helper n))
(provide let-handler)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define lambda-binding-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-handler
  (lambda-handler [n : Integer])
  #:returns Integer
  ((lambda (local)
     *local)
   5))
(provide lambda-handler)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define surface-regression-suite
  (test-suite
   "surface regressions"
   (test-case "let bindings in DSL bodies should get hidden-name support"
     (check-not-exn (lambda ()
                      (run-temp-module let-binding-module 'let-handler))))
   (test-case "lambda parameters in DSL bodies should get hidden-name support"
     (check-not-exn (lambda ()
                      (run-temp-module lambda-binding-module 'lambda-handler))))))
