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
  (only-in tesl/tesl/http HttpRequest [Http.sessionToken tesl_import_Http_sessionToken])
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup] [Dict.singleton tesl_import_Dict_singleton])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/api-test statusOk statusClientError)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/jwt jwt [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/crypto Secret)
  (only-in tesl/tesl/time time)
)


(provide AuthServer)

(define Authenticated 'Authenticated)

(define-capability sessionAuthCap (implies jwt time))

(define/pow
  (keyFromRaw [raw : String])
  #:returns Secret
  (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 50 (list (cons 'raw *raw)) (lambda () (raw-value (Secret *raw)))))

(define/pow
  (lessonSecret)
  #:returns Secret
  (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 52 (list) (lambda () (raw-value (keyFromRaw "lesson55-signing-key-not-for-production")))))

(define/pow
  (mintSession [user : String])
  #:capabilities [sessionAuthCap]
  #:returns String
  (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 56 (list (cons 'user *user)) (lambda () (tesl-dot/runtime (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" *user)) (raw-value (lessonSecret)))) 'value))))

(define/pow
  (forgedSession [user : String])
  #:capabilities [sessionAuthCap]
  #:returns String
  (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 61 (list (cons 'user *user)) (lambda () (tesl-dot/runtime (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" *user)) (raw-value (keyFromRaw "an-attackers-own-key")))) 'value))))

(define-auther
  (sessionAuth [req : HttpRequest])
  #:capabilities [sessionAuthCap]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 68 (list (cons 'req *req)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Http_sessionToken *req))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 69 (list) (lambda () (reject "not authenticated" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 75 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-1 (tesl_import_JWT_verify token (lessonSecret))]) (let ([claims tesl-checked-1]) (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "sub" claims))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 77 (list) (lambda () (reject "not authenticated" #:http-code 401)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([subject (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 78 (list (cons 'subject subject)) (lambda () (accept (Authenticated subject) #:value *subject))))])))))))])))))

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
  (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 95 (list) (lambda () "ok")))

(define-handler
  (profile [user : String ::: (Authenticated user)])
  #:returns String
  (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 98 (list (cons 'user *user)) (lambda () (format "profile of ~a" (tesl-display-val *user)))))

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
            (define resp (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 117 (list) (lambda () (dispatch-api-test-request AuthServer 'get (list "health") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 118 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
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
            (with-capabilities (sessionAuthCap)
              (define resp (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 123 (list) (lambda () (dispatch-api-test-request AuthServer 'get (list "profile") #:headers (tesl-hash) #:capabilities (list sessionAuthCap)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 124 (list (cons 'resp resp)) (lambda () (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "profile endpoint works with a signed session cookie"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessionAuthCap)
              (define resp (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 129 (list) (lambda () (dispatch-api-test-request AuthServer 'get (list "profile") #:cookie (tesl-hash '__Host-session (mintSession "alice")) #:headers (tesl-hash) #:capabilities (list sessionAuthCap)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 130 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "profile endpoint rejects a made-up cookie value"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessionAuthCap)
              (define resp (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 137 (list) (lambda () (dispatch-api-test-request AuthServer 'get (list "profile") #:cookie (tesl-hash '__Host-session "alice") #:headers (tesl-hash) #:capabilities (list sessionAuthCap)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 138 (list (cons 'resp resp)) (lambda () (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "profile endpoint rejects a token signed with the wrong key"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessionAuthCap)
              (define resp (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 145 (list) (lambda () (dispatch-api-test-request AuthServer 'get (list "profile") #:cookie (tesl-hash '__Host-session (forgedSession "alice")) #:headers (tesl-hash) #:capabilities (list sessionAuthCap)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson55-testing-auth-and-capabilities.tesl" 146 (list (cons 'resp resp)) (lambda () (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))))
            )
          ))
      ))
  )
)
