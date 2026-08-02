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
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/list [List.member tesl_import_List_member] [List.length tesl_import_List_length])
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/api-test statusOk)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide PermissionServer)

(define Authenticated 'Authenticated)
(define Grants 'Grants)
(define MayUse 'MayUse)

(define-adt Permission
  [WriteCostRates]
  [ReadProjects]
  [ManageUsers]
)

(define-record Caller
  [name : String]
  [granted : (List Permission)]
)

(define-checker
  (mayWriteCostRates [c : Caller])
  #:returns [c : Caller ::: (MayUse c WriteCostRates)]
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 43 (list (cons 'c *c)) (lambda () (if (raw-value (tesl_import_List_member WriteCostRates (tesl-dot/runtime c 'granted 'Caller))) (accept (MayUse c WriteCostRates) #:value *c) (reject "missing permission write:cost-rates" #:http-code 403)))))

(define-checker
  (mayReadProjects [c : Caller])
  #:returns [c : Caller ::: (MayUse c ReadProjects)]
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 49 (list (cons 'c *c)) (lambda () (if (raw-value (tesl_import_List_member ReadProjects (tesl-dot/runtime c 'granted 'Caller))) (accept (MayUse c ReadProjects) #:value *c) (reject "missing permission read:projects" #:http-code 403)))))

(define-checker
  (mayManageUsers [c : Caller])
  #:returns [c : Caller ::: (MayUse c ManageUsers)]
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 55 (list (cons 'c *c)) (lambda () (if (raw-value (tesl_import_List_member ManageUsers (tesl-dot/runtime c 'granted 'Caller))) (accept (MayUse c ManageUsers) #:value *c) (reject "missing permission manage:users" #:http-code 403)))))

(define/pow
  (writeCostRatesCore [c : Caller ::: (MayUse c WriteCostRates)])
  #:returns String
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 64 (list (cons 'c *c)) (lambda () "wrote cost rates")))

(define/pow
  (readProjectsCore [c : Caller ::: (MayUse c ReadProjects)])
  #:returns String
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 67 (list (cons 'c *c)) (lambda () "read projects")))

(define/pow
  (manageUsersCore [c : Caller ::: (MayUse c ManageUsers)])
  #:returns String
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 70 (list (cons 'c *c)) (lambda () "managed users")))

(define-checker
  (grantsReadProjects [c : Caller])
  #:returns [c : Caller ::: (Grants c ReadProjects)]
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 77 (list (cons 'c *c)) (lambda () (if (raw-value (tesl_import_List_member ReadProjects (tesl-dot/runtime c 'granted 'Caller))) (accept (Grants c ReadProjects) #:value *c) (reject "not granted read:projects" #:http-code 403)))))

(define/pow
  (describeGrant [c : Caller ::: (Grants c ReadProjects)])
  #:returns String
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 83 (list (cons 'c *c)) (lambda () (string-append (raw-value (tesl-dot/runtime c 'name 'Caller)) " may read projects"))))

(define/pow
  (mkCaller [name : String] [granted : (List Permission)])
  #:returns Caller
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 86 (list (cons 'name *name) (cons 'granted *granted)) (lambda () (Caller #:name *name #:granted *granted))))

(define/pow
  (grantedCount [c : Caller])
  #:returns Integer
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 89 (list (cons 'c *c)) (lambda () (raw-value (tesl_import_List_length (tesl-dot/runtime c 'granted 'Caller))))))

(define-record CapabilityReport
  [outcome : String]
)

(define (tesl-codec-encode-CapabilityReport _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'outcome (tesl-encode-prim-string (raw-value (hash-ref _fields 'outcome)))
  ))
(register-type-codec! 'CapabilityReport tesl-codec-encode-CapabilityReport (list ))

(define/pow
  (permissionsFor [claim : String])
  #:returns (List Permission)
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 110 (list (cons 'claim *claim)) (lambda () (if (tesl-equal? *claim "write") (raw-value (list WriteCostRates)) (raw-value (list ReadProjects))))))

(define-auther
  (resolveCaller [request : HttpRequest])
  #:returns [c : Caller ::: (Authenticated c)]
  (thsl-src-control! "tests/adt-indexed-fact-tests.tesl" 116 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "perm" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/adt-indexed-fact-tests.tesl" 117 (list) (lambda () (reject "no caller" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([claim (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/adt-indexed-fact-tests.tesl" 119 (list (cons 'claim claim)) (lambda () (let ([c (mkCaller "cookie-caller" (permissionsFor claim))]) (accept (Authenticated c) #:value *c)))))])))))

(define-handler
  (writeCostRates [c : Caller ::: (Authenticated c)])
  #:returns CapabilityReport
  (thsl-src! "tests/adt-indexed-fact-tests.tesl" 123 (list (cons 'c *c)) (lambda () (let/check ([tesl-checked-1 (mayWriteCostRates c)]) (let ([allowed tesl-checked-1]) (CapabilityReport #:outcome (writeCostRatesCore allowed)))))))

(define PermissionServer-sse-routes '())
(define-api PermissionApi
  [writeCostRates :
    (Auth [c : Caller ::: (Authenticated c)] #:via resolveCaller)
    :> "cost-rates"
    :> (Get JSON CapabilityReport)
    ]
)

(define-server PermissionServer
  #:api PermissionApi
  [writeCostRates writeCostRates]
)

(module+ test
  (require rackunit)
  (test-case "a granted caller reaches the constructor-indexed core"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (thsl-src! "tests/adt-indexed-fact-tests.tesl" 137 (list) (lambda () (dispatch-api-test-request PermissionServer 'get (list "cost-rates") #:cookie "perm=write" #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 138 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 139 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'outcome)))) "wrote cost rates")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a caller without the permission is rejected by the check"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (thsl-src! "tests/adt-indexed-fact-tests.tesl" 143 (list) (lambda () (dispatch-api-test-request PermissionServer 'get (list "cost-rates") #:cookie "perm=read" #:headers (tesl-hash) #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 144 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 403)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "no caller cookie is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (thsl-src! "tests/adt-indexed-fact-tests.tesl" 148 (list) (lambda () (dispatch-api-test-request PermissionServer 'get (list "cost-rates") #:headers (tesl-hash) #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 149 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a caller granted WriteCostRates passes its own check"
    (call-with-fresh-memory-db '() (lambda ()
  (define c (thsl-src! "tests/adt-indexed-fact-tests.tesl" 153 (list) (lambda () (mkCaller "alice" (list WriteCostRates)))))
  (define tesl-checked-2 (mayWriteCostRates c))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let proven: ~a" (check-fail-message tesl-checked-2)))
  (define proven tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 155 (list (cons 'proven proven) (cons 'c c)) (lambda () (writeCostRatesCore proven)))) "wrote cost rates")
    ))
  )

  (test-case "a caller granted ReadProjects passes its own check"
    (call-with-fresh-memory-db '() (lambda ()
  (define c (thsl-src! "tests/adt-indexed-fact-tests.tesl" 159 (list) (lambda () (mkCaller "bob" (list ReadProjects)))))
  (define tesl-checked-3 (mayReadProjects c))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let proven: ~a" (check-fail-message tesl-checked-3)))
  (define proven tesl-checked-3)
  (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 161 (list (cons 'proven proven) (cons 'c c)) (lambda () (readProjectsCore proven)))) "read projects")
    ))
  )

  (test-case "one caller can mint every constructor-indexed proof it holds"
    (call-with-fresh-memory-db '() (lambda ()
  (define c (thsl-src! "tests/adt-indexed-fact-tests.tesl" 165 (list) (lambda () (mkCaller "root" (list WriteCostRates ReadProjects ManageUsers)))))
  (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 166 (list (cons 'c c)) (lambda () (grantedCount c)))) 3)
  (define tesl-checked-4 (mayWriteCostRates c))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let w: ~a" (check-fail-message tesl-checked-4)))
  (define w tesl-checked-4)
  (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 168 (list (cons 'w w) (cons 'c c)) (lambda () (writeCostRatesCore w)))) "wrote cost rates")
  (define tesl-checked-5 (mayReadProjects c))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let r: ~a" (check-fail-message tesl-checked-5)))
  (define r tesl-checked-5)
  (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 170 (list (cons 'r r) (cons 'w w) (cons 'c c)) (lambda () (readProjectsCore r)))) "read projects")
  (define tesl-checked-6 (mayManageUsers c))
  (when (check-fail? tesl-checked-6)
    (raise-user-error 'tesl-test "unexpected failure in let m: ~a" (check-fail-message tesl-checked-6)))
  (define m tesl-checked-6)
  (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 172 (list (cons 'm m) (cons 'r r) (cons 'w w) (cons 'c c)) (lambda () (manageUsersCore m)))) "managed users")
    ))
  )

  (test-case "a second fact over the same ADT works the same way"
    (call-with-fresh-memory-db '() (lambda ()
  (define c (thsl-src! "tests/adt-indexed-fact-tests.tesl" 176 (list) (lambda () (mkCaller "dave" (list ReadProjects)))))
  (define tesl-checked-7 (grantsReadProjects c))
  (when (check-fail? tesl-checked-7)
    (raise-user-error 'tesl-test "unexpected failure in let proven: ~a" (check-fail-message tesl-checked-7)))
  (define proven tesl-checked-7)
  (check-equal? (raw-value (thsl-src! "tests/adt-indexed-fact-tests.tesl" 178 (list (cons 'proven proven) (cons 'c c)) (lambda () (describeGrant proven)))) "dave may read projects")
    ))
  )

)
