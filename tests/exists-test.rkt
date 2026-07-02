#lang racket

(require rackunit
         racket/runtime-path
         racket/string
         "../dsl/web.rkt")

(define-runtime-path check-rkt "../dsl/check.rkt")
(define-runtime-path check-runtime-rkt "../dsl/private/check-runtime.rkt")
(define-runtime-path web-rkt "../dsl/web.rkt")

(define (run-temp-module source [provided #f])
  (define temp-path (make-temporary-file "tesl-exists-test-~a.rkt"))
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

(define (make-exists-server-module handler-name handler-body)
  (format "#lang racket
(require (file ~s) (file ~s))
(define-checker
  (positive-check [value : Integer])
  #:returns [value : Integer ::: (Positive value)]
  (if (> *value 0)
      (accept (Positive value))
      (reject \"not positive\" #:http-code 400)))
(define-trusted
  (trusted-helper [id : Integer ::: (Positive id)])
  #:returns (Exists [label : String]
              (Integer ::: ((Positive id) && (Tagged label))))
  ~a)
(define-handler
  (~a [id : Integer ::: (Positive id)])
  #:returns (Exists [label : String]
              (Integer ::: ((Positive id) && (Tagged label))))
  (trusted-helper id))
(define-api ExistsAPI
  [get-value :
    \"values\"
    :> (Capture [id : Integer ::: (Positive id)]
                #:parser integer-segment
                #:check positive-check)
    :> (Get JSON
         (Exists [label : String]
           (Integer ::: ((Positive id) && (Tagged label)))))])
(define-server ExistsServer
  #:api ExistsAPI
  [get-value ~a])
(provide ExistsServer)
"
          (path->string check-rkt)
          (path->string web-rkt)
          handler-body
          handler-name
          handler-name))

(define good-server-module
  (make-exists-server-module
   'good-handler
   "(pack ([label \"ok\"])
      (attach-proof
       (ensure-named id *id)
       (list (trusted-proof (Positive id))
             (trusted-proof (Tagged label)))))"))

(define missing-pack-server-module
  (make-exists-server-module
   'missing-pack-handler
   "(attach-proof
      (ensure-named id *id)
      (list (trusted-proof (Positive id))))"))

(define wrong-witness-type-server-module
  (make-exists-server-module
   'wrong-witness-type-handler
   "(pack ([label 1])
      (attach-proof
       (ensure-named id *id)
       (list (trusted-proof (Positive id))
             (trusted-proof (Tagged label)))))"))

(define wrong-body-proof-server-module
  (make-exists-server-module
   'wrong-body-proof-handler
   "(pack ([label \"ok\"])
      (attach-proof
       (ensure-named id *id)
       (list (trusted-proof (Positive id)))))"))

(define wrong-witness-name-server-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-checker
  (positive-check [value : Integer])
  #:returns [value : Integer ::: (Positive value)]
  (if (> *value 0)
      (accept (Positive value))
      (reject \"not positive\" #:http-code 400)))
(define-handler
  (wrong-witness-name-handler [id : Integer ::: (Positive id)])
  #:returns (Exists [label : String]
              (Integer ::: ((Positive id) && (Tagged label))))
  (packed-exists
    (list (packed-witness 'wrong (ensure-named 'wrong \"ok\")))
    5))
(define-api ExistsAPI
  [get-value :
    \"values\"
    :> (Capture [id : Integer ::: (Positive id)]
                #:parser integer-segment
                #:check positive-check)
    :> (Get JSON
         (Exists [label : String]
           (Integer ::: ((Positive id) && (Tagged label)))))])
(define-server ExistsServer
  #:api ExistsAPI
  [get-value wrong-witness-name-handler])
(provide ExistsServer)
"
          (path->string check-runtime-rkt)
          (path->string web-rkt)))

(define good-server (run-temp-module good-server-module 'ExistsServer))
(define missing-pack-server (run-temp-module missing-pack-server-module 'ExistsServer))
(define wrong-witness-type-server (run-temp-module wrong-witness-type-server-module 'ExistsServer))
(define wrong-body-proof-server (run-temp-module wrong-body-proof-server-module 'ExistsServer))
(define wrong-witness-name-server (run-temp-module wrong-witness-name-server-module 'ExistsServer))

(let ([response (dispatch-request good-server (make-request 'GET '("values" "5")) #:capabilities '())])
  (check-equal? (dsl-response-status response) 200)
  (check-equal? (dsl-response-body response) 5))

;; Handler-failure details are now REDACTED from the client response body
;; (web.rkt "A2" hardening): the 'details field is '() unless TESL_VERBOSE is set,
;; and TESL_VERBOSE is read once at module load so it cannot be toggled here.
;; Instead we capture the server-side diagnostic from current-handler-error-port
;; (an output-string) and assert on that, keeping the status=500 contract.

(let ([log (open-output-string)])
  (parameterize ([current-handler-error-port log])
    (let ([response (dispatch-request missing-pack-server (make-request 'GET '("values" "5")) #:capabilities '())])
      (check-equal? (dsl-response-status response) 500)))
  (check-true
   (regexp-match? #rx"explicitly packed value" (get-output-string log))))

(let ([log (open-output-string)])
  (parameterize ([current-handler-error-port log])
    (let ([response (dispatch-request wrong-witness-type-server (make-request 'GET '("values" "5")) #:capabilities '())])
      (check-equal? (dsl-response-status response) 500)))
  (check-true
   (regexp-match? #rx"declared return type" (get-output-string log))))

;; Within define-trusted, a body proof is ASSERTED and no longer runtime-validated
;; (zero-cost proofs / safetynets removed). The wrong-body-proof handler therefore
;; succeeds with the same shape as the good handler: status 200, body 5.
(let ([response (dispatch-request wrong-body-proof-server (make-request 'GET '("values" "5")) #:capabilities '())])
  (check-equal? (dsl-response-status response) 200)
  (check-equal? (dsl-response-body response) 5))

(let ([log (open-output-string)])
  (parameterize ([current-handler-error-port log])
    (let ([response (dispatch-request wrong-witness-name-server (make-request 'GET '("values" "5")) #:capabilities '())])
      (check-equal? (dsl-response-status response) 500)))
  (check-true
   (regexp-match? #rx"missing witness" (get-output-string log))))
