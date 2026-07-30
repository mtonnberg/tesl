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
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict Dict [Dict.singleton tesl_import_Dict_singleton] [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/api-test statusOk responseCookie)
  (only-in tesl/tesl/time time)
  (only-in tesl/tesl/crypto Secret)
  (only-in tesl/tesl/jwt jwt [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/http HttpRequest cookieCap [Http.setSessionCookie tesl_import_Http_setSessionCookie] [Http.clearSessionCookie tesl_import_Http_clearSessionCookie] [Http.sessionToken tesl_import_Http_sessionToken])
)


(provide SessionServer)

(define Authenticated 'Authenticated)

(define-capability sessions (implies jwt time cookieCap))

(define/pow
  (makeSecret [s : String])
  #:returns Secret
  (thsl-src! "example/learn/lesson76-sessions.tesl" 190 (list (cons 's *s)) (lambda () (raw-value (Secret *s)))))

(define/pow
  (sessionsSigningKey)
  #:returns Secret
  (thsl-src! "example/learn/lesson76-sessions.tesl" 193 (list) (lambda () (raw-value (makeSecret "lesson76-demo-key-not-a-real-one")))))

(define-record Credentials
  [user : String]
  [password : String]
)

(define (tesl-codec-encode-Credentials _v)
  (error "toJson is forbidden for type Credentials: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-Credentials-0 _j)
  (define _f_user (tesl-decode-prim-field _j "user" tesl-decode-prim-string))
  (define _f_password (tesl-decode-prim-field _j "password" tesl-decode-prim-string))
  (record-value 'Credentials (tesl-hash 'user _f_user 'password _f_password)))
(register-type-codec! 'Credentials tesl-codec-encode-Credentials (list tesl-codec-decode-Credentials-0))

(define-record SessionResult
  [granted : Boolean]
)

(define (tesl-codec-encode-SessionResult _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'granted (tesl-encode-prim-bool (raw-value (hash-ref _fields 'granted)))
  ))
(register-type-codec! 'SessionResult tesl-codec-encode-SessionResult (list ))

(define-record Profile
  [userId : String]
)

(define (tesl-codec-encode-Profile _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'userId (tesl-encode-prim-string (raw-value (hash-ref _fields 'userId)))
  ))
(register-type-codec! 'Profile tesl-codec-encode-Profile (list ))

(define/pow
  (credentialsAreGood [credentials : Credentials])
  #:returns Boolean
  (thsl-src! "example/learn/lesson76-sessions.tesl" 252 (list (cons 'credentials *credentials)) (lambda () (tesl-ge? (raw-value (tesl_import_String_length (tesl-dot/runtime credentials 'password 'Credentials))) 8))))

(define-handler
  (login [body : Credentials])
  #:capabilities [sessions]
  #:returns SessionResult
  (thsl-src! "example/learn/lesson76-sessions.tesl" 255 (list (cons 'body *body)) (lambda () (if (credentialsAreGood body) (let ([token (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" (raw-value body.user))) (raw-value (sessionsSigningKey))))]) (let ([_ (raw-value (tesl_import_Http_setSessionCookie (raw-value token)))]) (SessionResult #:granted #t))) (reject "invalid credentials" #:http-code 401)))))

(define/pow
  (subjectOf [claims : (Dict String String)])
  #:returns String
  (thsl-src-control! "example/learn/lesson76-sessions.tesl" 276 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson76-sessions.tesl" 277 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([subject (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson76-sessions.tesl" 278 (list (cons 'subject subject)) (lambda () *subject)))])))))

(define-auther
  (sessionOwner [request : HttpRequest])
  #:capabilities [sessions]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "example/learn/lesson76-sessions.tesl" 282 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson76-sessions.tesl" 283 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson76-sessions.tesl" 285 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-2 (tesl_import_JWT_verify token (sessionsSigningKey))]) (let ([claims tesl-checked-2]) (let ([subject (subjectOf claims)]) (accept (Authenticated subject) #:value *subject)))))))])))))

(define-handler
  (whoami [user : String ::: (Authenticated user)])
  #:returns Profile
  (thsl-src! "example/learn/lesson76-sessions.tesl" 290 (list (cons 'user *user)) (lambda () (Profile #:userId *user))))

(define-handler
  (logout)
  #:capabilities [cookieCap]
  #:returns SessionResult
  (let ([_ (thsl-src! "example/learn/lesson76-sessions.tesl" 301 (list) (lambda () (raw-value (tesl_import_Http_clearSessionCookie))))]) (thsl-src! "example/learn/lesson76-sessions.tesl" 302 (list (cons '_ *_)) (lambda () (SessionResult #:granted #t)))))

(define SessionServer-sse-routes '())
(define-api SessionApi
  [login :
    "login"
    :> (ReqBody JSON [body : Credentials])
    :> (Post JSON SessionResult)
    ]
  [whoami :
    (Auth [user : String ::: (Authenticated user)] #:via sessionOwner)
    :> "me"
    :> (Get JSON Profile)
    ]
  [logout :
    "logout"
    :> (Post JSON SessionResult)
    ]
)

(define-server SessionServer
  #:api SessionApi
  [login login]
  [whoami whoami]
  [logout logout]
)

(module+ test
  (require rackunit)
  (test-case "login sets the session cookie, with every attribute fixed"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "example/learn/lesson76-sessions.tesl" 336 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice" (string->symbol "password") "correct-horse") #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 337 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
              (let ([*tesl-case-3 (raw-value (tesl_import_Dict_lookup "set-cookie" (raw-value (api-test-field-access-ref resp 'headers))))]) (cond
                [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing))
                  (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 339 (list (cons 'resp resp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something))
                  (let ([line (hash-ref (adt-value-fields *tesl-case-3) 'value)])
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 341 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "__Host-session=")))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 342 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "Path=/")))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 343 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "HttpOnly")))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 344 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "Secure")))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 345 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "SameSite=Lax")))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 346 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "Max-Age=3600")))))
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
  (test-case "the cookie round-trips into a protected endpoint"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define loginResp (thsl-src! "example/learn/lesson76-sessions.tesl" 350 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice" (string->symbol "password") "correct-horse") #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 351 (list (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref loginResp 'status)))))))
              (let ([*tesl-case-4 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing))
                  (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 353 (list (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-4) 'value)])
                    (define me (thsl-src! "example/learn/lesson76-sessions.tesl" 355 (list (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request SessionServer 'get (list "me") #:cookie session #:headers (tesl-hash) #:capabilities (list sessions)))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 356 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref me 'status)))))))
                    (check-equal? (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 357 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref me 'body) 'userId)))) "alice")
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
  (test-case "no cookie is a 401, not a 500"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define me (thsl-src! "example/learn/lesson76-sessions.tesl" 361 (list) (lambda () (dispatch-api-test-request SessionServer 'get (list "me") #:headers (tesl-hash) #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 362 (list (cons 'me me)) (lambda () (api-test-field-access-ref me 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a rejected login sets no cookie at all"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "example/learn/lesson76-sessions.tesl" 369 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice" (string->symbol "password") "short") #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 370 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 401)
              (let ([*tesl-case-5 (raw-value (responseCookie (raw-value resp)))]) (cond
                [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing))
                  (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 372 (list (cons 'resp resp)) (lambda () #t))))
                ]
                [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-5) 'value)])
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 373 (list (cons 'resp resp)) (lambda () #f))))
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
  (test-case "logout tells the browser to drop the cookie"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (cookieCap)
              (define resp (thsl-src! "example/learn/lesson76-sessions.tesl" 377 (list) (lambda () (dispatch-api-test-request SessionServer 'post (list "logout") #:headers (tesl-hash) #:capabilities (list cookieCap)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 378 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
              (let ([*tesl-case-6 (raw-value (tesl_import_Dict_lookup "set-cookie" (raw-value (api-test-field-access-ref resp 'headers))))]) (cond
                [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing))
                  (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 380 (list (cons 'resp resp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something))
                  (let ([line (hash-ref (adt-value-fields *tesl-case-6) 'value)])
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 382 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "__Host-session=;")))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson76-sessions.tesl" 383 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value line) "Max-Age=0")))))
                  )
                ]
              ))
            )
          ))
      ))
  )
)
