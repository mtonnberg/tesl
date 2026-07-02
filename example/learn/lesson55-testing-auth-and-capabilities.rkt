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
  (only-in tesl/tesl/prelude String Int)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/api-test statusOk statusClientError)
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide AuthServer)

(define Authenticated 'Authenticated)

(define-auther
  (sessionAuth [req : HttpRequest])
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 26 (list (cons 'req *req)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "session" (raw-value req.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 27 (list) (lambda () (reject "not authenticated" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 28 (list (cons 'token token)) (lambda () (accept (Authenticated token) #:value *token))))])))))

(define AuthServer-sse-routes '())
(define-api AuthApi
  [health :
    "health"
    :> (Get JSON String)
    ]
  [profile :
    (Auth [user : String ::: (Authenticated user)] #:via sessionAuth)
    :> "profile"
    :> (Get JSON String)
    ]
)

(define-handler
  (health)
  #:returns String
  (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 45 (list) (lambda () "ok")))

(define-handler
  (profile [user : String ::: (Authenticated user)])
  #:returns String
  (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 48 (list (cons 'user *user)) (lambda () (format "profile of ~a" (tesl-display-val *user)))))

(define-server AuthServer
  #:api AuthApi
  [health health]
  [profile profile]
)

(module+ test
  (require rackunit)
  (test-case "health endpoint is accessible without auth"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request AuthServer 'get (list "health") #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "profile endpoint returns 401 without cookie"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request AuthServer 'get (list "profile") #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "profile endpoint works with session cookie"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request AuthServer 'get (list "profile") #:cookie (hash 'session "alice") #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
          ))
      ))
  )
)
