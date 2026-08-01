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
  (only-in tesl/tesl/string [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict Dict [Dict.singleton tesl_import_Dict_singleton] [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/time time)
  (only-in tesl/tesl/crypto Secret)
  (only-in tesl/tesl/jwt jwt [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify] [JWT.renew tesl_import_JWT_renew])
  (only-in tesl/tesl/api-test statusOk responseCookie)
  (only-in tesl/tesl/http HttpRequest cookieCap [Http.setSessionCookie tesl_import_Http_setSessionCookie] [Http.clearSessionCookie tesl_import_Http_clearSessionCookie] [Http.sessionToken tesl_import_Http_sessionToken])
)


(provide SessionServer)

(define Authenticated 'Authenticated)

(define-capability sessions (implies jwt time cookieCap))

(define/pow
  (makeSecret [s : String])
  #:returns Secret
  (thsl-src! "tests/session-cookie-tests.tesl" 64 (list (cons 's *s)) (lambda () (raw-value (Secret *s)))))

(define/pow
  (tenantAKey)
  #:returns Secret
  (thsl-src! "tests/session-cookie-tests.tesl" 67 (list) (lambda () (raw-value (makeSecret "tenant-a-session-key")))))

(define/pow
  (tenantBKey)
  #:returns Secret
  (thsl-src! "tests/session-cookie-tests.tesl" 70 (list) (lambda () (raw-value (makeSecret "tenant-b-session-key")))))

(define-record LoginRequest
  [user : String]
)

(define (tesl-codec-encode-LoginRequest _v)
  (error "toJson is forbidden for type LoginRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-LoginRequest-0 _j)
  (define _f_user (tesl-decode-prim-field _j "user" tesl-decode-prim-string))
  (record-value 'LoginRequest (tesl-hash 'user _f_user)))
(register-type-codec! 'LoginRequest tesl-codec-encode-LoginRequest (list tesl-codec-decode-LoginRequest-0))

(define-record LoginOk
  [success : Boolean]
)

(define (tesl-codec-encode-LoginOk _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'success (tesl-encode-prim-bool (raw-value (hash-ref _fields 'success)))
  ))
(register-type-codec! 'LoginOk tesl-codec-encode-LoginOk (list ))

(define-record WhoAmI
  [userId : String]
)

(define (tesl-codec-encode-WhoAmI _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'userId (tesl-encode-prim-string (raw-value (hash-ref _fields 'userId)))
  ))
(register-type-codec! 'WhoAmI tesl-codec-encode-WhoAmI (list ))

(define/pow
  (subjectOf [claims : (Dict String String)])
  #:returns String
  (thsl-src-control! "tests/session-cookie-tests.tesl" 117 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/session-cookie-tests.tesl" 118 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([subject (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/session-cookie-tests.tesl" 119 (list (cons 'subject subject)) (lambda () *subject)))])))))

(define-auther
  (sessionOwner [request : HttpRequest])
  #:capabilities [sessions]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "tests/session-cookie-tests.tesl" 123 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/session-cookie-tests.tesl" 124 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/session-cookie-tests.tesl" 126 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-2 (tesl_import_JWT_verify token (tenantAKey))]) (let ([claims tesl-checked-2]) (let ([subject (subjectOf claims)]) (accept (Authenticated subject) #:value *subject)))))))])))))

(define-auther
  (slidingSessionOwner [request : HttpRequest])
  #:capabilities [sessions]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "tests/session-cookie-tests.tesl" 139 (list (cons 'request *request)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/session-cookie-tests.tesl" 140 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/session-cookie-tests.tesl" 142 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-4 (tesl_import_JWT_verify token (tenantAKey))]) (let ([claims tesl-checked-4]) (let/check ([tesl-checked-5 (tesl_import_JWT_renew token (tenantAKey))]) (let ([fresh tesl-checked-5]) (let ([_ (raw-value (tesl_import_Http_setSessionCookie fresh))]) (let ([subject (subjectOf claims)]) (accept (Authenticated subject) #:value *subject))))))))))])))))

(define-handler
  (login [body : LoginRequest])
  #:capabilities [sessions]
  #:returns LoginOk
  (let ([token (thsl-src! "tests/session-cookie-tests.tesl" 151 (list (cons 'body *body)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" (tesl-dot/runtime body 'user 'LoginRequest))) (raw-value (tenantAKey))))))]) (let ([_ (thsl-src! "tests/session-cookie-tests.tesl" 152 (list (cons 'token *token) (cons 'body *body)) (lambda () (raw-value (tesl_import_Http_setSessionCookie (raw-value token)))))]) (thsl-src! "tests/session-cookie-tests.tesl" 153 (list (cons '_ *_) (cons 'token *token) (cons 'body *body)) (lambda () (LoginOk #:success #t))))))

(define-handler
  (loginOtherTenant [body : LoginRequest])
  #:capabilities [sessions]
  #:returns LoginOk
  (let ([token (thsl-src! "tests/session-cookie-tests.tesl" 159 (list (cons 'body *body)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" (tesl-dot/runtime body 'user 'LoginRequest))) (raw-value (tenantBKey))))))]) (let ([_ (thsl-src! "tests/session-cookie-tests.tesl" 160 (list (cons 'token *token) (cons 'body *body)) (lambda () (raw-value (tesl_import_Http_setSessionCookie (raw-value token)))))]) (thsl-src! "tests/session-cookie-tests.tesl" 161 (list (cons '_ *_) (cons 'token *token) (cons 'body *body)) (lambda () (LoginOk #:success #t))))))

(define-handler
  (loginThenFail [body : LoginRequest])
  #:capabilities [sessions]
  #:returns LoginOk
  (let ([token (thsl-src! "tests/session-cookie-tests.tesl" 167 (list (cons 'body *body)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" (tesl-dot/runtime body 'user 'LoginRequest))) (raw-value (tenantAKey))))))]) (let ([_ (thsl-src! "tests/session-cookie-tests.tesl" 168 (list (cons 'token *token) (cons 'body *body)) (lambda () (raw-value (tesl_import_Http_setSessionCookie (raw-value token)))))]) (thsl-src! "tests/session-cookie-tests.tesl" 169 (list (cons '_ *_) (cons 'token *token) (cons 'body *body)) (lambda () (reject "second factor required" #:http-code 403))))))

(define-handler
  (whoami [user : String ::: (Authenticated user)])
  #:returns WhoAmI
  (thsl-src! "tests/session-cookie-tests.tesl" 172 (list (cons 'user *user)) (lambda () (WhoAmI #:userId *user))))

(define-handler
  (whoamiSliding [user : String ::: (Authenticated user)])
  #:returns WhoAmI
  (thsl-src! "tests/session-cookie-tests.tesl" 175 (list (cons 'user *user)) (lambda () (WhoAmI #:userId *user))))

(define-handler
  (logout)
  #:capabilities [cookieCap]
  #:returns LoginOk
  (let ([_ (thsl-src! "tests/session-cookie-tests.tesl" 179 (list) (lambda () (raw-value (tesl_import_Http_clearSessionCookie))))]) (thsl-src! "tests/session-cookie-tests.tesl" 180 (list (cons '_ *_)) (lambda () (LoginOk #:success #t)))))

(define-handler
  (ping)
  #:returns LoginOk
  (thsl-src! "tests/session-cookie-tests.tesl" 187 (list) (lambda () (LoginOk #:success #t))))

(define SessionServer-sse-routes '())
(define-api SessionApi
  [login :
    "login"
    :> (ReqBody JSON [body : LoginRequest])
    :> (Post JSON LoginOk)
    ]
  [loginOtherTenant :
    "login-other-tenant"
    :> (ReqBody JSON [body : LoginRequest])
    :> (Post JSON LoginOk)
    ]
  [loginThenFail :
    "login-then-fail"
    :> (ReqBody JSON [body : LoginRequest])
    :> (Post JSON LoginOk)
    ]
  [whoami :
    (Auth [user : String ::: (Authenticated user)] #:via sessionOwner)
    :> "whoami"
    :> (Get JSON WhoAmI)
    ]
  [whoamiSliding :
    (Auth [user : String ::: (Authenticated user)] #:via slidingSessionOwner)
    :> "whoami-sliding"
    :> (Get JSON WhoAmI)
    ]
  [logout :
    "logout"
    :> (Post JSON LoginOk)
    ]
  [ping :
    "ping"
    :> (Get JSON LoginOk)
    ]
)

(define-server SessionServer
  #:api SessionApi
  [login login]
  [loginOtherTenant loginOtherTenant]
  [loginThenFail loginThenFail]
  [whoami whoami]
  [whoamiSliding whoamiSliding]
  [logout logout]
  [ping ping]
)

(module+ test
  (require rackunit)
  (test-case "login emits the fixed Set-Cookie line, with no attribute passed in"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "tests/session-cookie-tests.tesl" 232 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 233 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
              (let ([*tesl-case-6 (raw-value (tesl_import_Dict_lookup "set-cookie" (raw-value (api-test-field-access-ref resp 'headers))))]) (cond
                [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 235 (list (cons 'resp resp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something))
                  (let ([line (hash-ref (adt-value-fields *tesl-case-6) 'value)])
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 240 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "__Host-session=")))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 241 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "Path=/")))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 242 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "HttpOnly")))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 243 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "Secure")))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 244 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "SameSite=Lax")))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 247 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "Max-Age=3600")))))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "responseCookie yields a Cookie-header-ready pair"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "tests/session-cookie-tests.tesl" 251 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list sessions)))))
              (let ([*tesl-case-7 (raw-value (responseCookie (raw-value resp)))]) (cond
                [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 253 (list (cons 'resp resp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-7) 'value)])
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 254 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value pair) "__Host-session=")))))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the session cookie round-trips: login then a protected endpoint"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define loginResp (thsl-src! "tests/session-cookie-tests.tesl" 260 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 261 (list (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref loginResp 'status)))))))
              (let ([*tesl-case-8 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 263 (list (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-8) 'value)])
                    (define me (thsl-src! "tests/session-cookie-tests.tesl" 265 (list (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami") #:cookie session #:headers (tesl-hash) #:capabilities (list sessions)))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 266 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref me 'status)))))))
                    (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 267 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref me 'body) 'userId)))) "alice")
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "no cookie at all is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define me (thsl-src! "tests/session-cookie-tests.tesl" 271 (list) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami") #:headers (tesl-hash) #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 272 (list (cons 'me me)) (lambda () (api-test-field-access-ref me 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a tampered cookie is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define me (thsl-src! "tests/session-cookie-tests.tesl" 277 (list) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami") #:cookie "__Host-session=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImRlYWRiZWVmZGVhZGJlZWYifQ.eyJzdWIiOiJhdHRhY2tlciJ9.not-a-valid-signature" #:headers (tesl-hash) #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 278 (list (cons 'me me)) (lambda () (api-test-field-access-ref me 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "another tenant's key does not verify here"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define other (thsl-src! "tests/session-cookie-tests.tesl" 282 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login-other-tenant") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "mallory") #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 283 (list (cons 'other other)) (lambda () (statusOk (raw-value (api-test-field-access-ref other 'status)))))))
              (let ([*tesl-case-9 (raw-value (responseCookie (raw-value other)))]) (cond
                [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 285 (list (cons 'other other)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-9) 'value)])
                    (define me (thsl-src! "tests/session-cookie-tests.tesl" 287 (list (cons 'other other)) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami") #:cookie session #:headers (tesl-hash) #:capabilities (list sessions)))))
                    (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 288 (list (cons 'me me) (cons 'other other)) (lambda () (api-test-field-access-ref me 'status)))) 401)
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a handler that sets a cookie and then fails emits no Set-Cookie"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "tests/session-cookie-tests.tesl" 294 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login-then-fail") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 295 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 403)
              (let ([*tesl-case-10 (raw-value (responseCookie (raw-value resp)))]) (cond
                [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 297 (list (cons 'resp resp)) (lambda () #t))))
                ]
                [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-10) 'value)])
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 298 (list (cons 'resp resp)) (lambda () #f))))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "logout emits Max-Age=0 for the same cookie"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (cookieCap)
              (define resp (thsl-src! "tests/session-cookie-tests.tesl" 304 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "logout") #:headers (tesl-hash) #:capabilities (list cookieCap)))))
              (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 305 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
              (let ([*tesl-case-11 (raw-value (tesl_import_Dict_lookup "set-cookie" (raw-value (api-test-field-access-ref resp 'headers))))]) (cond
                [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 307 (list (cons 'resp resp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Something))
                  (let ([line (hash-ref (adt-value-fields *tesl-case-11) 'value)])
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 309 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "__Host-session=;")))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 310 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "Max-Age=0")))))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a cookie set by one request does not ride out on the next"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define first (thsl-src! "tests/session-cookie-tests.tesl" 321 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 322 (list (cons 'first first)) (lambda () (statusOk (raw-value (api-test-field-access-ref first 'status)))))))
              (let ([*tesl-case-12 (raw-value (responseCookie (raw-value first)))]) (cond
                [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 326 (list (cons 'first first)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-12) 'value)])
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 327 (list (cons 'first first)) (lambda () #t))))
                  )
                ]
              ))
              (define second (thsl-src! "tests/session-cookie-tests.tesl" 328 (list (cons 'first first)) (lambda () (dispatch-api-test-request SessionServer 'get (list "ping") #:headers (tesl-hash) #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 329 (list (cons 'second second) (cons 'first first)) (lambda () (statusOk (raw-value (api-test-field-access-ref second 'status)))))))
              (let ([*tesl-case-13 (raw-value (responseCookie (raw-value second)))]) (cond
                [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 331 (list (cons 'second second) (cons 'first first)) (lambda () #t))))
                ]
                [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-13) 'value)])
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 332 (list (cons 'second second) (cons 'first first)) (lambda () #f))))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an authenticated request on a sliding route re-issues the cookie"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define loginResp (thsl-src! "tests/session-cookie-tests.tesl" 338 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 339 (list (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref loginResp 'status)))))))
              (let ([*tesl-case-14 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 341 (list (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-14) 'value)])
                    (define me (thsl-src! "tests/session-cookie-tests.tesl" 343 (list (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami-sliding") #:cookie session #:headers (tesl-hash) #:capabilities (list sessions)))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 344 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref me 'status)))))))
                    (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 345 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref me 'body) 'userId)))) "alice")
                    (let ([*tesl-case-15 (raw-value (responseCookie (raw-value me)))]) (cond
                      [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Nothing))
                        (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 349 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () #f))))
                      ]
                      [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Something))
                        (let ([renewed (hash-ref (adt-value-fields *tesl-case-15) 'value)])
                          (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 350 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (tesl_import_String_contains (raw-value renewed) "__Host-session=")))))
                        )
                      ]
                    ))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the renewed cookie is itself a valid session"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define loginResp (thsl-src! "tests/session-cookie-tests.tesl" 356 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list sessions)))))
              (let ([*tesl-case-16 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 358 (list (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-16) 'value)])
                    (define first (thsl-src! "tests/session-cookie-tests.tesl" 360 (list (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami-sliding") #:cookie session #:headers (tesl-hash) #:capabilities (list sessions)))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 361 (list (cons 'first first) (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref first 'status)))))))
                    (let ([*tesl-case-17 (raw-value (responseCookie (raw-value first)))]) (cond
                      [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Nothing))
                        (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 363 (list (cons 'first first) (cons 'loginResp loginResp)) (lambda () #f))))
                      ]
                      [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Something))
                        (let ([renewed (hash-ref (adt-value-fields *tesl-case-17) 'value)])
                          (define second (thsl-src! "tests/session-cookie-tests.tesl" 365 (list (cons 'first first) (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami") #:cookie renewed #:headers (tesl-hash) #:capabilities (list sessions)))))
                          (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 366 (list (cons 'second second) (cons 'first first) (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref second 'status)))))))
                          (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 367 (list (cons 'second second) (cons 'first first) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref second 'body) 'userId)))) "alice")
                        )
                      ]
                    ))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a non-sliding route does NOT re-issue the cookie"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define loginResp (thsl-src! "tests/session-cookie-tests.tesl" 373 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list sessions)))))
              (let ([*tesl-case-18 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-18) (eq? (adt-value-variant *tesl-case-18) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 375 (list (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-18) (eq? (adt-value-variant *tesl-case-18) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-18) 'value)])
                    (define me (thsl-src! "tests/session-cookie-tests.tesl" 377 (list (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami") #:cookie session #:headers (tesl-hash) #:capabilities (list sessions)))))
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 378 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref me 'status)))))))
                    (let ([*tesl-case-19 (raw-value (responseCookie (raw-value me)))]) (cond
                      [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Nothing))
                        (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 380 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () #t))))
                      ]
                      [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Something))
                        (let ([pair (hash-ref (adt-value-fields *tesl-case-19) 'value)])
                          (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 381 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () #f))))
                        )
                      ]
                    ))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "renewal cannot resurrect a cookie the server never signed"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define me (thsl-src! "tests/session-cookie-tests.tesl" 387 (list) (lambda () (dispatch-api-test-request SessionServer 'get (list "whoami-sliding") #:cookie "__Host-session=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImRlYWRiZWVmZGVhZGJlZWYifQ.eyJzdWIiOiJhdHRhY2tlciJ9.not-a-valid-signature" #:headers (tesl-hash) #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 388 (list (cons 'me me)) (lambda () (api-test-field-access-ref me 'status)))) 401)
              (let ([*tesl-case-20 (raw-value (responseCookie (raw-value me)))]) (cond
                [(and (adt-value? *tesl-case-20) (eq? (adt-value-variant *tesl-case-20) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 390 (list (cons 'me me)) (lambda () #t))))
                ]
                [(and (adt-value? *tesl-case-20) (eq? (adt-value-variant *tesl-case-20) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-20) 'value)])
                    (check-true (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 391 (list (cons 'me me)) (lambda () #f))))
                  )
                ]
              ))
            )
          ))
      ))
  )
)

(define-auther
  (leakyAuth [request : HttpRequest])
  #:capabilities [sessions]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "tests/session-cookie-tests.tesl" 405 (list (cons 'request *request)) (lambda () (let ([tesl-case-21 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-21) (eq? (adt-value-variant *tesl-case-21) 'Nothing)) (thsl-src! "tests/session-cookie-tests.tesl" 406 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-21) (eq? (adt-value-variant *tesl-case-21) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-21) 'value)]) (thsl-src! "tests/session-cookie-tests.tesl" 411 (list (cons 'token token)) (lambda () (let ([_ (raw-value (tesl_import_Http_setSessionCookie (raw-value token)))]) (accept Authenticated #:value "nobody")))))])))))

(define-handler
  (leakyProbe [user : String ::: (Authenticated user)])
  #:returns WhoAmI
  (thsl-src! "tests/session-cookie-tests.tesl" 415 (list (cons 'user *user)) (lambda () (WhoAmI #:userId *user))))

(define LeakyServer-sse-routes '())
(define-api LeakyApi
  [leakyProbe :
    (Auth [user : String ::: (Authenticated user)] #:via leakyAuth)
    :> "leaky"
    :> (Get JSON WhoAmI)
    ]
)

(define-server LeakyServer
  #:api LeakyApi
  [leakyProbe leakyProbe]
)

(module+ test
  (require rackunit)
  (test-case "an auth-block exception is a sanitized 500, not a leaked stack trace"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "tests/session-cookie-tests.tesl" 430 (list) (lambda () (dispatch-api-test-request LeakyServer 'get (list "leaky") #:cookie "__Host-session=notavalidjwt" #:headers (tesl-hash) #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 431 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 500)
              (check-equal? (raw-value (thsl-src! "tests/session-cookie-tests.tesl" 432 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'error)))) "Internal server error")
            )
          ))
      ))
  )
)
