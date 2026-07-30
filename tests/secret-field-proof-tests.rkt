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
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/api-test statusOk)
)


(provide Password RegisterBody RegisterOut register RegisterApi RegisterServer register-signature)

(define LongEnough 'LongEnough)

(define-secret-newtype Password String)

(define-checker
  (isLongEnough [text : String])
  #:returns [text : String ::: (LongEnough text)]
  (thsl-src! "tests/secret-field-proof-tests.tesl" 48 (list (cons 'text *text)) (lambda () (if (tesl-ge? (raw-value (tesl_import_String_length *text)) 8) (accept (LongEnough text) #:value *text) (reject "Password too short" #:http-code 400)))))

(define-record RegisterBody
  [email : String]
  [password : Password ::: (LongEnough password)]
)

(define-record RegisterOut
  [registered : Boolean]
)

(define (tesl-codec-encode-RegisterBody _v)
  (error "toJson is forbidden for type RegisterBody: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-RegisterBody-0 _j)
  (define _f_email (tesl-decode-prim-field _j "email" tesl-decode-prim-string))
  (define _fraw_password (tesl-decode-prim-field _j "password" tesl-decode-prim-string))
  (define _r1_password
    (let ([_r (isLongEnough _fraw_password)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_password
    (if (check-ok? _r1_password)
        (ensure-named 'password (Password (check-ok-value _r1_password)) (check-ok-facts _r1_password) (check-ok-bindings _r1_password) #:subject 'password)
        _r1_password))
  (or (and (check-fail? _f_password) _f_password)
      (record-value 'RegisterBody (tesl-hash 'email _f_email 'password _f_password))))
(register-type-codec! 'RegisterBody tesl-codec-encode-RegisterBody (list tesl-codec-decode-RegisterBody-0))

(define-handler
  (register [body : RegisterBody])
  #:returns RegisterOut
  (let ([out (thsl-src! "tests/secret-field-proof-tests.tesl" 72 (list (cons 'body *body)) (lambda () (RegisterOut #:registered (tesl-equal? (raw-value body.password) (raw-value (Password "unused-comparison"))))))]) (thsl-src! "tests/secret-field-proof-tests.tesl" 73 (list (cons 'out *out) (cons 'body *body)) (lambda () (raw-value out)))))

(define RegisterServer-sse-routes '())
(define-api RegisterApi
  [register :
    "register"
    :> (ReqBody JSON [body : RegisterBody])
    :> (Post JSON RegisterOut)
    ]
)

(define-server RegisterServer
  #:api RegisterApi
  [register register]
)

(module+ test
  (require rackunit)
  (test-case "a too-short password is rejected before it ever becomes a secret"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/secret-field-proof-tests.tesl" 86 (list) (lambda () (dispatch-api-test-request RegisterServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "a@example.com" (string->symbol "password") "short") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/secret-field-proof-tests.tesl" 87 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a long-enough password validates directly into a redacted field"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/secret-field-proof-tests.tesl" 91 (list) (lambda () (dispatch-api-test-request RegisterServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "a@example.com" (string->symbol "password") "hunter2222") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/secret-field-proof-tests.tesl" 92 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
          ))
      ))
  )
)
