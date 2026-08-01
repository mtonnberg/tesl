#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/dsl/debug/checkpoint
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool String)
  (only-in tesl/tesl/api-test statusOk)
)


(provide Password LoginBody LoginOut login InboundApi InboundServer login-signature)

(define-secret-newtype Password String)

(define-record LoginBody
  [email : String]
  [password : Password]
)

(define-record LoginOut
  [matched : Boolean]
)

(define-handler
  (login [body : LoginBody])
  #:returns LoginOut
  (let ([expected (thsl-src! "tests/secret-inbound-tests.tesl" 46 (list (cons 'body *body)) (lambda () (raw-value (Password "hunter2"))))]) (let ([out (thsl-src! "tests/secret-inbound-tests.tesl" 47 (list (cons 'expected *expected) (cons 'body *body)) (lambda () (LoginOut #:matched (tesl-equal? (raw-value (tesl-dot/runtime body 'password 'LoginBody)) (raw-value expected)))))]) (thsl-src! "tests/secret-inbound-tests.tesl" 48 (list (cons 'out *out) (cons 'expected *expected) (cons 'body *body)) (lambda () (raw-value out))))))

(define InboundServer-sse-routes '())
(define-api InboundApi
  [login :
    "login"
    :> (ReqBody JSON [body : LoginBody])
    :> (Post JSON LoginOut)
    ]
)

(define-server InboundServer
  #:api InboundApi
  [login login]
)

(module+ test
  (require rackunit)
  (test-case "a secret decodes from a JSON request body and compares constant-time"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define good (thsl-src! "tests/secret-inbound-tests.tesl" 61 (list) (lambda () (dispatch-api-test-request InboundServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "ab" (string->symbol "password") "hunter2") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/secret-inbound-tests.tesl" 62 (list (cons 'good good)) (lambda () (statusOk (raw-value (api-test-field-access-ref good 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/secret-inbound-tests.tesl" 63 (list (cons 'good good)) (lambda () (api-test-field-access-ref (api-test-field-access-ref good 'body) 'matched)))) #t)
            (define nope (thsl-src! "tests/secret-inbound-tests.tesl" 65 (list (cons 'good good)) (lambda () (dispatch-api-test-request InboundServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "ab" (string->symbol "password") "wrong") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/secret-inbound-tests.tesl" 66 (list (cons 'nope nope) (cons 'good good)) (lambda () (statusOk (raw-value (api-test-field-access-ref nope 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/secret-inbound-tests.tesl" 67 (list (cons 'nope nope) (cons 'good good)) (lambda () (api-test-field-access-ref (api-test-field-access-ref nope 'body) 'matched)))) #f)
          ))
      ))
  )
)
