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
  (only-in tesl/tesl/prelude Bool Int String Fact)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/api-test statusOk)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.startsWith tesl_import_String_startsWith] [String.requireNonEmpty tesl_import_String_requireNonEmpty] IsNonEmpty)
)


(provide R48AuthServer R48ConjAuthServer)

(define Authenticated 'Authenticated)
(define HasValidSession 'HasValidSession)
(define IsAdmin 'IsAdmin)
(define Positive 'Positive)
(define Small 'Small)

(define-checker
  (checkPositive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 31 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (Positive n) #:value *n) (reject "must be positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (Small n)]
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 37 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (Small n) #:value *n) (reject "must be < 100" #:http-code 400)))))

(define-checker
  (checkPosAndSmall [n : Integer])
  #:returns [n : Integer ::: ((Positive n) && (Small n))]
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 43 (list (cons 'n *n)) (lambda () ((check-and checkPositive checkSmall) n))))

(define-checker
  (checkIsAdmin [userId : String])
  #:returns [userId : String ::: (IsAdmin userId)]
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 46 (list (cons 'userId *userId)) (lambda () (if (tesl_import_String_startsWith *userId "admin") (accept (IsAdmin userId) #:value *userId) (reject "not admin" #:http-code 403)))))

(define-auther
  (simpleAuth [request : HttpRequest])
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "tests/critical-review-48-auth-api-tests.tesl" 57 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 58 (list) (lambda () (reject "not authenticated" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 59 (list (cons 'userId userId)) (lambda () (accept (Authenticated userId) #:value *userId))))])))))

(define-auther
  (checkedAuth [request : HttpRequest])
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "tests/critical-review-48-auth-api-tests.tesl" 63 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 64 (list) (lambda () (reject "not authenticated" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 66 (list (cons 'userId userId)) (lambda () (let/check ([tesl-checked-2 (tesl_import_String_requireNonEmpty userId)]) (let ([validId tesl-checked-2]) (accept (Authenticated validId) #:value *validId))))))])))))

(define-auther
  (adminAuth [request : HttpRequest])
  #:returns [user : String ::: ((IsAdmin user) && (Authenticated user))]
  (thsl-src-control! "tests/critical-review-48-auth-api-tests.tesl" 71 (list (cons 'request *request)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 72 (list) (lambda () (reject "not authenticated" #:http-code 401)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 74 (list (cons 'userId userId)) (lambda () (let ([tesl-proof-binding-4 (checkIsAdmin userId)]) (let ([admin (forget-proof tesl-proof-binding-4)] [p (detach-all-proof tesl-proof-binding-4)]) (accept (p && (Authenticated admin)) #:value *admin))))))])))))

(define-auther
  (conjunctionAuth [request : HttpRequest])
  #:returns [user : String ::: ((Authenticated user) && (HasValidSession user))]
  (thsl-src-control! "tests/critical-review-48-auth-api-tests.tesl" 80 (list (cons 'request *request)) (lambda () (let ([tesl-case-5 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 81 (list) (lambda () (reject "not authenticated" #:http-code 401)))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 83 (list (cons 'userId userId)) (lambda () (let ([tesl-case-6 (raw-value (tesl_import_Dict_lookup "session" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 84 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 86 (list) (lambda () (accept ((Authenticated userId) && (HasValidSession userId)) #:value *userId)))])))))])))))

(define-record ValueRequest
  [value : Integer]
)

(define (tesl-codec-encode-ValueRequest _v)
  (error "toJson is forbidden for type ValueRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-ValueRequest-0 _j)
  (define _f_value (tesl-decode-prim-field _j "value" tesl-decode-prim-int))
  (record-value 'ValueRequest (hash 'value _f_value)))
(register-type-codec! 'ValueRequest tesl-codec-encode-ValueRequest (list tesl-codec-decode-ValueRequest-0))

(define-record ValueResponse
  [result : Integer]
  [label : String]
)

(define (tesl-codec-encode-ValueResponse _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'result (tesl-encode-prim-int (raw-value (hash-ref _fields 'result)))
        'label (tesl-encode-prim-string (raw-value (hash-ref _fields 'label)))
  ))
(register-type-codec! 'ValueResponse tesl-codec-encode-ValueResponse (list ))

(define-record ConjResponse
  [tripled : Integer]
)

(define (tesl-codec-encode-ConjResponse _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'tripled (tesl-encode-prim-int (raw-value (hash-ref _fields 'tripled)))
  ))
(register-type-codec! 'ConjResponse tesl-codec-encode-ConjResponse (list ))

(define-record AuthInfoResponse
  [userId : String]
)

(define (tesl-codec-encode-AuthInfoResponse _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'userId (tesl-encode-prim-string (raw-value (hash-ref _fields 'userId)))
  ))
(register-type-codec! 'AuthInfoResponse tesl-codec-encode-AuthInfoResponse (list ))

(define-handler
  (doublePositive [user : String ::: (Authenticated user)] [req : ValueRequest])
  #:returns ValueResponse
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 146 (list (cons 'user *user) (cons 'req *req)) (lambda () (let/check ([tesl-checked-7 (checkPositive (raw-value req.value))]) (let ([v tesl-checked-7]) (ValueResponse #:result (* (raw-value v) 2) #:label "doubled"))))))

(define-handler
  (tripleConj [user : String ::: (Authenticated user)] [req : ValueRequest])
  #:returns ConjResponse
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 151 (list (cons 'user *user) (cons 'req *req)) (lambda () (let/check ([tesl-checked-8 (checkPosAndSmall (raw-value req.value))]) (let ([v tesl-checked-8]) (ConjResponse #:tripled (* (raw-value v) 3)))))))

(define-handler
  (inlineConj [user : String ::: (Authenticated user)] [req : ValueRequest])
  #:returns ConjResponse
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 156 (list (cons 'user *user) (cons 'req *req)) (lambda () (let/check ([tesl-checked-9 ((check-and checkPositive checkSmall) (raw-value req.value))]) (let ([v tesl-checked-9]) (ConjResponse #:tripled (* (raw-value v) 3)))))))

(define-handler
  (whoami [user : String ::: (Authenticated user)])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 160 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (whoamiAdmin [user : String ::: ((IsAdmin user) && (Authenticated user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 163 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (conjAuthWhoami [user : String ::: ((Authenticated user) && (HasValidSession user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 167 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define R48AuthServer-sse-routes '())
(define-api R48AuthApi
  [doublePositive :
    (Auth [user : String ::: (Authenticated user)] #:via simpleAuth)
    :> "double"
    :> (ReqBody JSON [req : ValueRequest])
    :> (Post JSON ValueResponse)
    ]
  [tripleConj :
    (Auth [user : String ::: (Authenticated user)] #:via simpleAuth)
    :> "triple-conj"
    :> (ReqBody JSON [req : ValueRequest])
    :> (Post JSON ConjResponse)
    ]
  [inlineConj :
    (Auth [user : String ::: (Authenticated user)] #:via simpleAuth)
    :> "inline-conj"
    :> (ReqBody JSON [req : ValueRequest])
    :> (Post JSON ConjResponse)
    ]
  [whoami :
    (Auth [user : String ::: (Authenticated user)] #:via checkedAuth)
    :> "whoami-checked"
    :> (Get JSON AuthInfoResponse)
    ]
  [whoamiAdmin :
    (Auth [user : String ::: ((IsAdmin user) && (Authenticated user))] #:via adminAuth)
    :> "whoami-admin"
    :> (Get JSON AuthInfoResponse)
    ]
)

(define-server R48AuthServer
  #:api R48AuthApi
  [doublePositive doublePositive]
  [tripleConj tripleConj]
  [inlineConj inlineConj]
  [whoami whoami]
  [whoamiAdmin whoamiAdmin]
)

(define R48ConjAuthServer-sse-routes '())
(define-api R48ConjAuthApi
  [conjAuthWhoami :
    (Auth [user : String ::: ((Authenticated user) && (HasValidSession user))] #:via conjunctionAuth)
    :> "conj-whoami"
    :> (Get JSON AuthInfoResponse)
    ]
)

(define-server R48ConjAuthServer
  #:api R48ConjAuthApi
  [conjAuthWhoami conjAuthWhoami]
)

(module+ test
  (require rackunit)
  (test-case "unauth returns 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "double") #:headers (hash) #:body (hash (string->symbol "value") 5) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "auth + single proof: positive doubled"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "double") #:cookie "user=alice" #:headers (hash) #:body (hash (string->symbol "value") 5) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'result)) 10)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "auth + single proof: zero rejected 400"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "double") #:cookie "user=alice" #:headers (hash) #:body (hash (string->symbol "value") 0) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "auth + single proof: negative rejected 400"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "double") #:cookie "user=alice" #:headers (hash) #:body (hash (string->symbol "value") -5) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conj wrapper: 50 tripled"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "triple-conj") #:cookie "user=alice" #:headers (hash) #:body (hash (string->symbol "value") 50) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'tripled)) 150)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conj wrapper: boundary 1"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "triple-conj") #:cookie "user=alice" #:headers (hash) #:body (hash (string->symbol "value") 1) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'tripled)) 3)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conj wrapper: boundary 99"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "triple-conj") #:cookie "user=alice" #:headers (hash) #:body (hash (string->symbol "value") 99) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'tripled)) 297)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conj wrapper: rejects 0"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "triple-conj") #:cookie "user=alice" #:headers (hash) #:body (hash (string->symbol "value") 0) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conj wrapper: rejects 100"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "triple-conj") #:cookie "user=alice" #:headers (hash) #:body (hash (string->symbol "value") 100) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "inline conj: 50 tripled"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "inline-conj") #:cookie "user=bob" #:headers (hash) #:body (hash (string->symbol "value") 50) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'tripled)) 150)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "inline conj: rejects 0"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'post (list "inline-conj") #:cookie "user=bob" #:headers (hash) #:body (hash (string->symbol "value") 0) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "checkedAuth: valid user passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'get (list "whoami-checked") #:cookie "user=alice" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "checkedAuth: empty cookie rejected"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'get (list "whoami-checked") #:cookie "user=" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "checkedAuth: no cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'get (list "whoami-checked") #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "adminAuth: admin user passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'get (list "whoami-admin") #:cookie "user=admin_alice" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "admin_alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "adminAuth: non-admin rejected"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'get (list "whoami-admin") #:cookie "user=alice" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 403)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "adminAuth: no cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48AuthServer 'get (list "whoami-admin") #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conjAuth: user+session passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjAuthServer 'get (list "conj-whoami") #:cookie "user=alice; session=abc123" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conjAuth: missing session 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjAuthServer 'get (list "conj-whoami") #:cookie "user=alice" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conjAuth: no cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjAuthServer 'get (list "conj-whoami") #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(define-auther
  (conjManualAuth [request : HttpRequest])
  #:returns [user : String ::: ((Authenticated user) && (HasValidSession user))]
  (thsl-src-control! "tests/critical-review-48-auth-api-tests.tesl" 346 (list (cons 'request *request)) (lambda () (let ([tesl-case-10 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Nothing)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 347 (list) (lambda () (reject "no cookie" #:http-code 401)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-10) 'value)]) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 349 (list (cons 'userId userId)) (lambda () (let ([tesl-case-11 (raw-value (tesl_import_Dict_lookup "session" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Nothing)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 350 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Something)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 352 (list) (lambda () (accept ((Authenticated userId) && (HasValidSession userId)) #:value *userId)))])))))])))))

(define-auther
  (conjCheckAuth [request : HttpRequest])
  #:returns [user : String ::: ((Authenticated user) && (IsAdmin user))]
  (thsl-src-control! "tests/critical-review-48-auth-api-tests.tesl" 356 (list (cons 'request *request)) (lambda () (let ([tesl-case-12 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing)) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 357 (list) (lambda () (reject "no cookie" #:http-code 401)))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 359 (list (cons 'userId userId)) (lambda () (let/check ([tesl-checked-13 (checkIsAdmin userId)]) (let ([admin tesl-checked-13]) (accept ((Authenticated admin) && (IsAdmin admin)) #:value *admin))))))])))))

(define-handler
  (conjManualWhoami [user : String ::: ((Authenticated user) && (HasValidSession user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 364 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (conjCheckWhoami [user : String ::: ((Authenticated user) && (IsAdmin user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-auth-api-tests.tesl" 368 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define R48ConjInAuthServer-sse-routes '())
(define-api R48ConjInAuthApi
  [conjManualWhoami :
    (Auth [user : String ::: ((Authenticated user) && (HasValidSession user))] #:via conjManualAuth)
    :> "conj-manual"
    :> (Get JSON AuthInfoResponse)
    ]
  [conjCheckWhoami :
    (Auth [user : String ::: ((Authenticated user) && (IsAdmin user))] #:via conjCheckAuth)
    :> "conj-check"
    :> (Get JSON AuthInfoResponse)
    ]
)

(define-server R48ConjInAuthServer
  #:api R48ConjInAuthApi
  [conjManualWhoami conjManualWhoami]
  [conjCheckWhoami conjCheckWhoami]
)

(module+ test
  (require rackunit)
  (test-case "conjManual: user+session passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjInAuthServer 'get (list "conj-manual") #:cookie "user=alice; session=abc" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conjManual: missing session 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjInAuthServer 'get (list "conj-manual") #:cookie "user=alice" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conjManual: no cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjInAuthServer 'get (list "conj-manual") #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conjCheck: admin passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjInAuthServer 'get (list "conj-check") #:cookie "user=admin_bob" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "admin_bob")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conjCheck: non-admin 403"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjInAuthServer 'get (list "conj-check") #:cookie "user=bob" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 403)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "conjCheck: no cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request R48ConjInAuthServer 'get (list "conj-check") #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)
