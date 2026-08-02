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
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/api-test statusOk)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide CallerServer)

(define Authenticated 'Authenticated)
(define TenantScoped 'TenantScoped)

(define-adt Caller
  [HumanActs [value : String]]
  [AppActs [value : String]]
  [SystemActs]
)

(define-newtype TenantId String)

(define-record WhoAmI
  [actor : String]
)

(define (tesl-codec-encode-WhoAmI _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'actor (tesl-encode-prim-string (raw-value (hash-ref _fields 'actor)))
  ))
(register-type-codec! 'WhoAmI tesl-codec-encode-WhoAmI (list ))

(define/pow
  (describe [c : Caller])
  #:returns String
  (thsl-src-control! "tests/api-auth-sum-type-tests.tesl" 58 (list (cons 'c *c)) (lambda () (let ([tesl-case-0 *c]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'HumanActs)) (let ([name (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/api-auth-sum-type-tests.tesl" 59 (list (cons 'name name)) (lambda () (raw-value (string-append "human:" *name)))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'AppActs)) (let ([name (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/api-auth-sum-type-tests.tesl" 60 (list (cons 'name name)) (lambda () (raw-value (string-append "app:" *name)))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'SystemActs)) (thsl-src! "tests/api-auth-sum-type-tests.tesl" 61 (list) (lambda () (raw-value "system")))])))))

(define/pow
  (callerFor [claim : String])
  #:returns Caller
  (thsl-src! "tests/api-auth-sum-type-tests.tesl" 64 (list (cons 'claim *claim)) (lambda () (if (tesl-equal? *claim "system") (raw-value SystemActs) (if (tesl-equal? *claim "app") (raw-value (raw-value (AppActs "deploy-bot"))) (raw-value (raw-value (HumanActs *claim))))))))

(define-auther
  (resolveCaller [request : HttpRequest])
  #:returns [c : Caller ::: (Authenticated c)]
  (thsl-src-control! "tests/api-auth-sum-type-tests.tesl" 73 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "actor" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/api-auth-sum-type-tests.tesl" 74 (list) (lambda () (reject "not authenticated" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([claim (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/api-auth-sum-type-tests.tesl" 76 (list (cons 'claim claim)) (lambda () (let ([c (callerFor claim)]) (accept (Authenticated c) #:value *c)))))])))))

(define-handler
  (whoami [c : Caller ::: (Authenticated c)])
  #:returns WhoAmI
  (thsl-src! "tests/api-auth-sum-type-tests.tesl" 80 (list (cons 'c *c)) (lambda () (WhoAmI #:actor (describe c)))))

(define CallerServer-sse-routes '())
(define-api CallerApi
  [whoami :
    (Auth [c : Caller ::: (Authenticated c)] #:via resolveCaller)
    :> "whoami"
    :> (Get JSON WhoAmI)
    ]
)

(define-server CallerServer
  #:api CallerApi
  [whoami whoami]
)

(define-checker
  (checkTenant [t : TenantId])
  #:returns [t : TenantId ::: (TenantScoped t)]
  (thsl-src! "tests/api-auth-sum-type-tests.tesl" 96 (list (cons 't *t)) (lambda () (if (tesl-equal? (raw-value (raw-value t.value)) "") (reject "tenant required" #:http-code 400) (accept (TenantScoped t) #:value *t)))))

(define/pow
  (tenantLabel [t : TenantId ::: (TenantScoped t)])
  #:returns String
  (thsl-src! "tests/api-auth-sum-type-tests.tesl" 102 (list (cons 't *t)) (lambda () (string-append "tenant:" (raw-value (raw-value t.value))))))

(module+ test
  (require rackunit)
  (test-case "a human caller is served"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (thsl-src! "tests/api-auth-sum-type-tests.tesl" 105 (list) (lambda () (dispatch-api-test-request CallerServer 'get (list "whoami") #:cookie "actor=alice" #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 106 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 107 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'actor)))) "human:alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an app caller is served"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (thsl-src! "tests/api-auth-sum-type-tests.tesl" 111 (list) (lambda () (dispatch-api-test-request CallerServer 'get (list "whoami") #:cookie "actor=app" #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 112 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 113 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'actor)))) "app:deploy-bot")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a nullary variant is served"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (thsl-src! "tests/api-auth-sum-type-tests.tesl" 117 (list) (lambda () (dispatch-api-test-request CallerServer 'get (list "whoami") #:cookie "actor=system" #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 118 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 119 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'actor)))) "system")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "no actor cookie is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (thsl-src! "tests/api-auth-sum-type-tests.tesl" 123 (list) (lambda () (dispatch-api-test-request CallerServer 'get (list "whoami") #:headers (tesl-hash) #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 124 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the sum type describes each variant"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 128 (list) (lambda () (describe (HumanActs "bob"))))) "human:bob")
  (check-equal? (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 129 (list) (lambda () (describe (AppActs "ci"))))) "app:ci")
  (check-equal? (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 130 (list) (lambda () (describe SystemActs)))) "system")
    ))
  )

  (test-case "a same-module newtype still carries a proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/api-auth-sum-type-tests.tesl" 134 (list) (lambda () (raw-value (TenantId "acme")))))
  (define tesl-checked-2 (checkTenant t))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let scoped: ~a" (check-fail-message tesl-checked-2)))
  (define scoped tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "tests/api-auth-sum-type-tests.tesl" 136 (list (cons 'scoped scoped) (cons 't t)) (lambda () (tenantLabel scoped)))) "tenant:acme")
    ))
  )

)
