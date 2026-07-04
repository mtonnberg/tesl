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


(provide Fix1Server Fix2MultiArgServer Fix4RoutingCaptureServer)

(define Active 'Active)
(define Authenticated 'Authenticated)
(define HasValidSession 'HasValidSession)
(define InBounds 'InBounds)
(define IsAdmin 'IsAdmin)
(define ItemAuth 'ItemAuth)
(define UserAuth 'UserAuth)
(define Validated 'Validated)
(define Verified 'Verified)

(define-checker
  (checkValidated [n : Integer])
  #:returns [n : Integer ::: (Validated n)]
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 32 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (Validated n) #:value *n) (reject "not validated" #:http-code 400)))))

(define-checker
  (checkInBounds [n : Integer])
  #:returns [n : Integer ::: (InBounds n)]
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 38 (list (cons 'n *n)) (lambda () (if (and (>= *n 1) (<= *n 1000)) (accept (InBounds n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define-checker
  (checkBoth [n : Integer])
  #:returns [n : Integer ::: ((Validated n) && (InBounds n))]
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 44 (list (cons 'n *n)) (lambda () ((check-and checkValidated checkInBounds) n))))

(define-record Fix1NumResponse
  [result : Integer]
)

(define (tesl-codec-encode-Fix1NumResponse _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'result (tesl-encode-prim-int (raw-value (hash-ref _fields 'result)))
  ))
(register-type-codec! 'Fix1NumResponse tesl-codec-encode-Fix1NumResponse (list ))

(define-record ValueBody
  [value : Integer]
)

(define (tesl-codec-encode-ValueBody _v)
  (error "toJson is forbidden for type ValueBody: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-ValueBody-0 _j)
  (define _f_value (tesl-decode-prim-field _j "value" tesl-decode-prim-int))
  (record-value 'ValueBody (hash 'value _f_value)))
(register-type-codec! 'ValueBody tesl-codec-encode-ValueBody (list tesl-codec-decode-ValueBody-0))

(define-handler
  (fix1SingleCheck [req : ValueBody])
  #:returns Fix1NumResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 60 (list (cons 'req *req)) (lambda () (let/check ([tesl-checked-0 (checkValidated (raw-value req.value))]) (let ([v tesl-checked-0]) (Fix1NumResponse #:result (+ (* (raw-value v) 10) 1)))))))

(define-handler
  (fix1ConjCheck [req : ValueBody])
  #:returns Fix1NumResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 65 (list (cons 'req *req)) (lambda () (let/check ([tesl-checked-1 (checkBoth (raw-value req.value))]) (let ([v tesl-checked-1]) (Fix1NumResponse #:result (+ (raw-value v) 999)))))))

(define-handler
  (fix1InlineConj [req : ValueBody])
  #:returns Fix1NumResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 70 (list (cons 'req *req)) (lambda () (let/check ([tesl-checked-2 ((check-and checkValidated checkInBounds) (raw-value req.value))]) (let ([v tesl-checked-2]) (Fix1NumResponse #:result (* (raw-value v) 2)))))))

(define/pow
  (fix1FnCheck [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 75 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-3 (checkValidated n)]) (let ([v tesl-checked-3]) (+ (raw-value v) 100))))))

(define-handler
  (fix1FnProxy [req : ValueBody])
  #:returns Fix1NumResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 79 (list (cons 'req *req)) (lambda () (Fix1NumResponse #:result (fix1FnCheck (raw-value req.value))))))

(define Fix1Server-sse-routes '())
(define-api Fix1Api
  [fix1SingleCheck :
    "single"
    :> (ReqBody JSON [req : ValueBody])
    :> (Post JSON Fix1NumResponse)
    ]
  [fix1ConjCheck :
    "conj"
    :> (ReqBody JSON [req : ValueBody])
    :> (Post JSON Fix1NumResponse)
    ]
  [fix1InlineConj :
    "inline"
    :> (ReqBody JSON [req : ValueBody])
    :> (Post JSON Fix1NumResponse)
    ]
  [fix1FnProxy :
    "fn"
    :> (ReqBody JSON [req : ValueBody])
    :> (Post JSON Fix1NumResponse)
    ]
)

(define-server Fix1Server
  #:api Fix1Api
  [fix1SingleCheck fix1SingleCheck]
  [fix1ConjCheck fix1ConjCheck]
  [fix1InlineConj fix1InlineConj]
  [fix1FnProxy fix1FnProxy]
)

(module+ test
  (require rackunit)
  (test-case "A1: single check raw-value arithmetic"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "single") #:headers (hash) #:body (hash (string->symbol "value") 5) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'result)) 51)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "A1: single check rejects zero"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "single") #:headers (hash) #:body (hash (string->symbol "value") 0) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "A2: conj check raw-value arithmetic"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "conj") #:headers (hash) #:body (hash (string->symbol "value") 1) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'result)) 1000)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "A2: conj check boundary 1000"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "conj") #:headers (hash) #:body (hash (string->symbol "value") 1000) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'result)) 1999)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "A2: conj check rejects 0"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "conj") #:headers (hash) #:body (hash (string->symbol "value") 0) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "A2: conj check rejects 1001"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "conj") #:headers (hash) #:body (hash (string->symbol "value") 1001) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "A3: inline conj raw-value arithmetic"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "inline") #:headers (hash) #:body (hash (string->symbol "value") 50) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'result)) 100)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "A4: fn body raw-value unwrap"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "fn") #:headers (hash) #:body (hash (string->symbol "value") 7) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'result)) 107)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "A4: fn body check failure is 500"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix1Server 'post (list "fn") #:headers (hash) #:body (hash (string->symbol "value") 0) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 500)
          ))
      ))
  )
)

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

(define-auther
  (simpleSubstAuth [request : HttpRequest])
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 171 (list (cons 'request *request)) (lambda () (let ([tesl-case-4 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 172 (list) (lambda () (reject "no user" #:http-code 401)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 174 (list (cons 'userId userId)) (lambda () (accept (Authenticated userId) #:value *userId))))])))))

(define-auther
  (identityAuth [request : HttpRequest])
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 178 (list (cons 'request *request)) (lambda () (let ([tesl-case-5 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 179 (list) (lambda () (reject "no user" #:http-code 401)))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([user (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 181 (list (cons 'user user)) (lambda () (accept (Authenticated user) #:value *user))))])))))

(define-auther
  (conjSubstAuth [request : HttpRequest])
  #:returns [user : String ::: ((Authenticated user) && (HasValidSession user))]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 186 (list (cons 'request *request)) (lambda () (let ([tesl-case-6 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 187 (list) (lambda () (reject "no user" #:http-code 401)))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 189 (list (cons 'userId userId)) (lambda () (let ([tesl-case-7 (raw-value (tesl_import_Dict_lookup "session" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 190 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 192 (list) (lambda () (accept ((Authenticated userId) && (HasValidSession userId)) #:value *userId)))])))))])))))

(define-checker
  (checkIsAdmin [userId : String])
  #:returns [userId : String ::: (IsAdmin userId)]
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 196 (list (cons 'userId *userId)) (lambda () (if (tesl_import_String_startsWith *userId "admin") (accept (IsAdmin userId) #:value *userId) (reject "not admin" #:http-code 403)))))

(define-auther
  (delegatedConjAuth [request : HttpRequest])
  #:returns [user : String ::: ((IsAdmin user) && (Authenticated user))]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 203 (list (cons 'request *request)) (lambda () (let ([tesl-case-8 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 204 (list) (lambda () (reject "no user" #:http-code 401)))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 206 (list (cons 'userId userId)) (lambda () (let ([tesl-proof-binding-9 (checkIsAdmin userId)]) (let ([admin (forget-proof tesl-proof-binding-9)] [p (detach-all-proof tesl-proof-binding-9)]) (accept (p && (Authenticated admin)) #:value *admin))))))])))))

(define-auther
  (doubleDelegatedAuth [request : HttpRequest])
  #:returns [user : String ::: ((Authenticated user) && (HasValidSession user))]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 212 (list (cons 'request *request)) (lambda () (let ([tesl-case-10 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 213 (list) (lambda () (reject "no user" #:http-code 401)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-10) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 215 (list (cons 'userId userId)) (lambda () (let/check ([tesl-checked-11 (tesl_import_String_requireNonEmpty userId)]) (let ([validId tesl-checked-11]) (accept ((Authenticated validId) && (HasValidSession validId)) #:value *validId))))))])))))

(define-handler
  (whoamiSimple [user : String ::: (Authenticated user)])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 219 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (whoamiIdentity [user : String ::: (Authenticated user)])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 222 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (whoamiConj [user : String ::: ((Authenticated user) && (HasValidSession user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 226 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (whoamiAdmin [user : String ::: ((IsAdmin user) && (Authenticated user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 230 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (whoamiDouble [user : String ::: ((Authenticated user) && (HasValidSession user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 234 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define Fix2MultiArgServer-sse-routes '())
(define-api Fix2MultiArgApi
  [whoamiSimple :
    (Auth [user : String ::: (Authenticated user)] #:via simpleSubstAuth)
    :> "simple"
    :> (Get JSON AuthInfoResponse)
    ]
  [whoamiIdentity :
    (Auth [user : String ::: (Authenticated user)] #:via identityAuth)
    :> "identity"
    :> (Get JSON AuthInfoResponse)
    ]
  [whoamiConj :
    (Auth [user : String ::: ((Authenticated user) && (HasValidSession user))] #:via conjSubstAuth)
    :> "conj"
    :> (Get JSON AuthInfoResponse)
    ]
  [whoamiAdmin :
    (Auth [user : String ::: ((IsAdmin user) && (Authenticated user))] #:via delegatedConjAuth)
    :> "delegated"
    :> (Get JSON AuthInfoResponse)
    ]
  [whoamiDouble :
    (Auth [user : String ::: ((Authenticated user) && (HasValidSession user))] #:via doubleDelegatedAuth)
    :> "double"
    :> (Get JSON AuthInfoResponse)
    ]
)

(define-server Fix2MultiArgServer
  #:api Fix2MultiArgApi
  [whoamiSimple whoamiSimple]
  [whoamiIdentity whoamiIdentity]
  [whoamiConj whoamiConj]
  [whoamiAdmin whoamiAdmin]
  [whoamiDouble whoamiDouble]
)

(module+ test
  (require rackunit)
  (test-case "B1: simple subst passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "simple") #:cookie "user=alice" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "B1: simple no cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "simple") #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "B2: identity (no subst) passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "identity") #:cookie "user=bob" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "bob")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "B3: conj subst passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "conj") #:cookie "user=carol; session=abc" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "carol")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "B3: conj missing session 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "conj") #:cookie "user=carol" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "B4: delegated admin passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "delegated") #:cookie "user=admin_dave" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "admin_dave")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "B4: delegated non-admin 403"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "delegated") #:cookie "user=dave" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 403)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "B5: double delegated passes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "double") #:cookie "user=eve" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "eve")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "B5: double delegated empty string rejected"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix2MultiArgServer 'get (list "double") #:cookie "user=" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(define-checker
  (checkVerified [userId : String])
  #:returns [userId : String ::: (Verified userId)]
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 330 (list (cons 'userId *userId)) (lambda () (if (tesl_import_String_startsWith *userId "v") (accept (Verified userId) #:value *userId) (reject "not verified" #:http-code 403)))))

(define-checker
  (checkActive [input : String])
  #:returns [result : String ::: (Active result)]
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 336 (list (cons 'input *input)) (lambda () (let/check ([tesl-checked-12 (tesl_import_String_requireNonEmpty input)]) (let ([result tesl-checked-12]) (accept (Active result) #:value *result))))))

(define-auther
  (proofVarSingle [request : HttpRequest])
  #:returns [user : String ::: (Verified user)]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 342 (list (cons 'request *request)) (lambda () (let ([tesl-case-13 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 343 (list) (lambda () (reject "no user" #:http-code 401)))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-13) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 345 (list (cons 'userId userId)) (lambda () (let ([tesl-proof-binding-14 (checkVerified userId)]) (let ([checked (forget-proof tesl-proof-binding-14)] [p (detach-all-proof tesl-proof-binding-14)]) (accept p #:value *checked))))))])))))

(define-auther
  (proofVarMixed [request : HttpRequest])
  #:returns [user : String ::: ((Verified user) && (Authenticated user))]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 351 (list (cons 'request *request)) (lambda () (let ([tesl-case-15 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 352 (list) (lambda () (reject "no user" #:http-code 401)))] [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-15) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 354 (list (cons 'userId userId)) (lambda () (let ([tesl-proof-binding-16 (checkVerified userId)]) (let ([checked (forget-proof tesl-proof-binding-16)] [p (detach-all-proof tesl-proof-binding-16)]) (accept (p && (Authenticated checked)) #:value *checked))))))])))))

(define-auther
  (proofVarNested [request : HttpRequest])
  #:returns [user : String ::: ((Verified user) && (Active user))]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 360 (list (cons 'request *request)) (lambda () (let ([tesl-case-17 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 361 (list) (lambda () (reject "no user" #:http-code 401)))] [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-17) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 363 (list (cons 'userId userId)) (lambda () (let/check ([tesl-checked-18 (tesl_import_String_requireNonEmpty userId)]) (let ([validId tesl-checked-18]) (let ([tesl-proof-binding-19 (checkVerified validId)]) (let ([checked (forget-proof tesl-proof-binding-19)] [p (detach-all-proof tesl-proof-binding-19)]) (accept (p && (Active checked)) #:value *checked))))))))])))))

(define-handler
  (whoamiVerified [user : String ::: (Verified user)])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 368 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (whoamiMixed [user : String ::: ((Verified user) && (Authenticated user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 372 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define-handler
  (whoamiNested [user : String ::: ((Verified user) && (Active user))])
  #:returns AuthInfoResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 376 (list (cons 'user *user)) (lambda () (AuthInfoResponse #:userId *user))))

(define Fix3ProofVarServer-sse-routes '())
(define-api Fix3ProofVarApi
  [whoamiVerified :
    (Auth [user : String ::: (Verified user)] #:via proofVarSingle)
    :> "single-pv"
    :> (Get JSON AuthInfoResponse)
    ]
  [whoamiMixed :
    (Auth [user : String ::: ((Verified user) && (Authenticated user))] #:via proofVarMixed)
    :> "mixed-pv"
    :> (Get JSON AuthInfoResponse)
    ]
  [whoamiNested :
    (Auth [user : String ::: ((Verified user) && (Active user))] #:via proofVarNested)
    :> "nested-pv"
    :> (Get JSON AuthInfoResponse)
    ]
)

(define-server Fix3ProofVarServer
  #:api Fix3ProofVarApi
  [whoamiVerified whoamiVerified]
  [whoamiMixed whoamiMixed]
  [whoamiNested whoamiNested]
)

(module+ test
  (require rackunit)
  (test-case "C1: single proof var auth"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix3ProofVarServer 'get (list "single-pv") #:cookie "user=v_alice" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "v_alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "C1: single proof var auth rejected"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix3ProofVarServer 'get (list "single-pv") #:cookie "user=alice" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 403)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "C2: mixed proof var + literal"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix3ProofVarServer 'get (list "mixed-pv") #:cookie "user=v_bob" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "v_bob")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "C2: mixed proof var rejected"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix3ProofVarServer 'get (list "mixed-pv") #:cookie "user=bob" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 403)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "C3: nested proof var chain"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix3ProofVarServer 'get (list "nested-pv") #:cookie "user=v_charlie" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)) "v_charlie")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "C3: nested empty fails"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix3ProofVarServer 'get (list "nested-pv") #:cookie "user=" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 400)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "C3: nested unverified fails"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix3ProofVarServer 'get (list "nested-pv") #:cookie "user=charlie" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 403)
          ))
      ))
  )
)

(define-checker
  (checkBothFacts [n : Integer])
  #:returns [n : Integer ::: ((Validated n) && (InBounds n))]
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 438 (list (cons 'n *n)) (lambda () ((check-and checkValidated checkInBounds) n))))

(define/pow
  (useBothFacts [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 441 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-20 (checkBothFacts n)]) (let ([v tesl-checked-20]) (+ (raw-value v) 1))))))

(define-auther
  (itemCookieAuth [request : HttpRequest])
  #:returns [user : String ::: (ItemAuth user)]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 459 (list (cons 'request *request)) (lambda () (let ([tesl-case-21 (raw-value (tesl_import_Dict_lookup "item-token" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-21) (eq? (adt-value-variant *tesl-case-21) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 460 (list) (lambda () (reject "no item token" #:http-code 401)))] [(and (adt-value? *tesl-case-21) (eq? (adt-value-variant *tesl-case-21) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-21) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 461 (list (cons 'userId userId)) (lambda () (accept (ItemAuth userId) #:value *userId))))])))))

(define-auther
  (userCookieAuth [request : HttpRequest])
  #:returns [user : String ::: (UserAuth user)]
  (thsl-src-control! "tests/critical-review-48-adversarial-deep.tesl" 464 (list (cons 'request *request)) (lambda () (let ([tesl-case-22 (raw-value (tesl_import_Dict_lookup "user-token" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Nothing)) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 465 (list) (lambda () (reject "no user token" #:http-code 401)))] [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-22) 'value)]) (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 466 (list (cons 'userId userId)) (lambda () (accept (UserAuth userId) #:value *userId))))])))))

(define-capture itemIdCapture
  [itemIdCapture : String]
  #:parser string-segment)

(define-capture userIdCapture
  [userIdCapture : String]
  #:parser string-segment)

(define-record ItemResponse
  [itemId : String]
  [fetchedBy : String]
)

(define (tesl-codec-encode-ItemResponse _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'itemId (tesl-encode-prim-string (raw-value (hash-ref _fields 'itemId)))
        'fetchedBy (tesl-encode-prim-string (raw-value (hash-ref _fields 'fetchedBy)))
  ))
(register-type-codec! 'ItemResponse tesl-codec-encode-ItemResponse (list ))

(define-record UserResponse
  [uid : String]
  [fetchedBy : String]
)

(define (tesl-codec-encode-UserResponse _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'uid (tesl-encode-prim-string (raw-value (hash-ref _fields 'uid)))
        'fetchedBy (tesl-encode-prim-string (raw-value (hash-ref _fields 'fetchedBy)))
  ))
(register-type-codec! 'UserResponse tesl-codec-encode-UserResponse (list ))

(define-handler
  (getItem [user : String ::: (ItemAuth user)] [itemId : String])
  #:returns ItemResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 490 (list (cons 'user *user) (cons 'itemId *itemId)) (lambda () (ItemResponse #:itemId *itemId #:fetchedBy *user))))

(define-handler
  (getUser [user : String ::: (UserAuth user)] [uid : String])
  #:returns UserResponse
  (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 493 (list (cons 'user *user) (cons 'uid *uid)) (lambda () (UserResponse #:uid *uid #:fetchedBy *user))))

(define Fix4RoutingCaptureServer-sse-routes '())
(define-api Fix4CaptureApi
  [getItem :
    (Auth [user : String ::: (ItemAuth user)] #:via itemCookieAuth)
    :> "items"
    :> (Capture itemIdCapture [itemId : String])
    :> (Get JSON ItemResponse)
    ]
  [getUser :
    (Auth [user : String ::: (UserAuth user)] #:via userCookieAuth)
    :> "users"
    :> (Capture userIdCapture [uid : String])
    :> (Get JSON UserResponse)
    ]
)

(define-server Fix4RoutingCaptureServer
  #:api Fix4CaptureApi
  [getItem getItem]
  [getUser getUser]
)

(module+ test
  (require rackunit)
  (test-case "D1: items route with item-token"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix4RoutingCaptureServer 'get (list "items" "42") #:cookie "item-token=alice" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'itemId)) "42")
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'fetchedBy)) "alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "D2: users route with user-token"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix4RoutingCaptureServer 'get (list "users" "bob") #:cookie "user-token=charlie" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'uid)) "bob")
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'fetchedBy)) "charlie")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "D3: items route wrong cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix4RoutingCaptureServer 'get (list "items" "42") #:cookie "user-token=alice" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "D4: users route wrong cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix4RoutingCaptureServer 'get (list "users" "bob") #:cookie "item-token=alice" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "D5: items no cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix4RoutingCaptureServer 'get (list "items" "99") #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "D6: users no cookie 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix4RoutingCaptureServer 'get (list "users" "zz") #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'status)) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "D8: both cookies items route"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix4RoutingCaptureServer 'get (list "items" "77") #:cookie "item-token=alice; user-token=bob" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'fetchedBy)) "alice")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "D9: both cookies users route"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request Fix4RoutingCaptureServer 'get (list "users" "xx") #:cookie "item-token=alice; user-token=bob" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'fetchedBy)) "bob")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "C4: conjunction combinator delegation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-adversarial-deep.tesl" 445 (list) (lambda () (useBothFacts 50)))) 51)
    ))
  )

)
