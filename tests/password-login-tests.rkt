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
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/dict Dict [Dict.singleton tesl_import_Dict_singleton] [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/time time)
  (only-in tesl/tesl/crypto Secret PasswordHash [Crypto.hashPassword tesl_import_Crypto_hashPassword] [Crypto.checkPassword tesl_import_Crypto_checkPassword] [Crypto.needsRehash tesl_import_Crypto_needsRehash])
  (only-in tesl/tesl/jwt jwt [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/http HttpRequest cookieCap [Http.setSessionCookie tesl_import_Http_setSessionCookie] [Http.sessionToken tesl_import_Http_sessionToken])
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/api-test statusOk responseCookie)
)


(provide AccountServer)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "tests/password-login-tests.tesl" '(122 131 137))
(define Authenticated 'Authenticated)
(define LongEnough 'LongEnough)

(define-capability sessions (implies jwt time cookieCap))

(define-capability accountWrite (implies dbWrite random))

(define-secret-newtype Password String)

(define/pow
  (makeSecret [s : String])
  #:returns Secret
  (thsl-src! "tests/password-login-tests.tesl" 76 (list (cons 's *s)) (lambda () (raw-value (Secret *s)))))

(define/pow
  (sessionKey)
  #:returns Secret
  (thsl-src! "tests/password-login-tests.tesl" 79 (list) (lambda () (raw-value (makeSecret "password-login-tests-session-key")))))

(define-entity Account
  #:source (make-hash)
  #:table accounts
  #:primary-key id
  [Id id : String]
  [Email email : String]
  [PasswordHash passwordHash : PasswordHash]
)

(define-database Accounts
  #:backend memory
  #:schema accounts
  #:entities Account)

(define/pow
  (strongEnough [candidate : String])
  #:returns Boolean
  (thsl-src! "tests/password-login-tests.tesl" 101 (list (cons 'candidate *candidate)) (lambda () (tesl-ge? (raw-value (tesl_import_String_length *candidate)) 12))))

(define-checker
  (isStrongEnough [s : String])
  #:returns [s : String ::: (LongEnough s)]
  (thsl-src! "tests/password-login-tests.tesl" 109 (list (cons 's *s)) (lambda () (if (strongEnough s) (accept (LongEnough s) #:value *s) (reject "password too short" #:http-code 400)))))

(define/pow
  (passwordHashFor [email : String])
  #:capabilities [dbRead]
  #:returns (Maybe PasswordHash)
  (thsl-src-control! "tests/password-login-tests.tesl" 122 (list (cons 'email *email)) (lambda () (let ([tesl-case-0 (raw-value (let ([tesl_match (select-one (from Account) (where (==. (entity-field-ref Account 'email) email)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/password-login-tests.tesl" 123 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([acct (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/password-login-tests.tesl" 124 (list (cons 'acct acct)) (lambda () (raw-value (raw-value (Something (tesl-dot/runtime acct 'passwordHash 'Account)))))))])))))

(define/pow
  (storedHashNeedsRehash [email : String])
  #:capabilities [dbRead]
  #:returns Boolean
  (thsl-src-control! "tests/password-login-tests.tesl" 131 (list (cons 'email *email)) (lambda () (let ([tesl-case-1 (raw-value (let ([tesl_match (select-one (from Account) (where (==. (entity-field-ref Account 'email) email)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/password-login-tests.tesl" 132 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([acct (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/password-login-tests.tesl" 133 (list (cons 'acct acct)) (lambda () (raw-value (raw-value (tesl_import_Crypto_needsRehash (tesl-dot/runtime acct 'passwordHash 'Account)))))))])))))

(define/pow
  (accountExists [email : String])
  #:capabilities [dbRead]
  #:returns Boolean
  (thsl-src-control! "tests/password-login-tests.tesl" 137 (list (cons 'email *email)) (lambda () (let ([tesl-case-2 (raw-value (let ([tesl_match (select-one (from Account) (where (==. (entity-field-ref Account 'email) email)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/password-login-tests.tesl" 138 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([acct (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/password-login-tests.tesl" 139 (list (cons 'acct acct)) (lambda () (raw-value #t))))])))))

(define-record Credentials
  [email : String]
  [password : Password]
)

(define-record RegisterBody
  [id : String]
  [email : String]
  [password : Password ::: (LongEnough password)]
)

(define (tesl-codec-encode-RegisterBody _v)
  (error "toJson is forbidden for type RegisterBody: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-RegisterBody-0 _j)
  (define _f_id (tesl-decode-prim-field _j "id" tesl-decode-prim-string))
  (define _f_email (tesl-decode-prim-field _j "email" tesl-decode-prim-string))
  (define _fraw_password (tesl-decode-prim-field _j "password" tesl-decode-prim-string))
  (define _r1_password
    (let ([_r (isStrongEnough _fraw_password)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_password
    (if (check-ok? _r1_password)
        (ensure-named 'password (Password (check-ok-value _r1_password)) (check-ok-facts _r1_password) (check-ok-bindings _r1_password) #:subject 'password)
        _r1_password))
  (or (and (check-fail? _f_password) _f_password)
      (record-value 'RegisterBody (tesl-hash 'id _f_id 'email _f_email 'password _f_password))))
(register-type-codec! 'RegisterBody tesl-codec-encode-RegisterBody (list tesl-codec-decode-RegisterBody-0))

(define-record Outcome
  [success : Boolean]
)

(define (tesl-codec-encode-Outcome _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'success (tesl-encode-prim-bool (raw-value (hash-ref _fields 'success)))
  ))
(register-type-codec! 'Outcome tesl-codec-encode-Outcome (list ))

(define-record SecondFactorOutcome
  [pending : Boolean]
)

(define (tesl-codec-encode-SecondFactorOutcome _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'pending (tesl-encode-prim-bool (raw-value (hash-ref _fields 'pending)))
  ))
(register-type-codec! 'SecondFactorOutcome tesl-codec-encode-SecondFactorOutcome (list ))

(define-record Profile
  [user : String]
)

(define (tesl-codec-encode-Profile _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'user (tesl-encode-prim-string (raw-value (hash-ref _fields 'user)))
  ))
(register-type-codec! 'Profile tesl-codec-encode-Profile (list ))

(define/pow
  (subjectOf [claims : (Dict String String)])
  #:returns String
  (thsl-src-control! "tests/password-login-tests.tesl" 208 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/password-login-tests.tesl" 209 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([subject (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/password-login-tests.tesl" 210 (list (cons 'subject subject)) (lambda () *subject)))])))))

(define-auther
  (sessionOwner [request : HttpRequest])
  #:capabilities [sessions]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "tests/password-login-tests.tesl" 214 (list (cons 'request *request)) (lambda () (let ([tesl-case-4 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "tests/password-login-tests.tesl" 215 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tests/password-login-tests.tesl" 217 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-5 (tesl_import_JWT_verify token (sessionKey))]) (let ([claims tesl-checked-5]) (accept Authenticated #:value (subjectOf claims)))))))])))))

(define-handler
  (register [body : RegisterBody])
  #:capabilities [accountWrite]
  #:returns Outcome
  (let ([plaintext (thsl-src! "tests/password-login-tests.tesl" 226 (list (cons 'body *body)) (lambda () (tesl-dot/runtime body 'password 'RegisterBody)))]) (let ([hash (thsl-src! "tests/password-login-tests.tesl" 227 (list (cons 'plaintext *plaintext) (cons 'body *body)) (lambda () (raw-value (tesl_import_Crypto_hashPassword (raw-value plaintext)))))]) (let ([_ (thsl-src! "tests/password-login-tests.tesl" 228 (list (cons 'hash *hash) (cons 'plaintext *plaintext) (cons 'body *body)) (lambda () (insert-one! Account (tesl-hash 'id (tesl-dot/runtime body 'id 'RegisterBody) 'email (tesl-dot/runtime body 'email 'RegisterBody) 'passwordHash hash))))]) (thsl-src! "tests/password-login-tests.tesl" 229 (list (cons '_ *_) (cons 'hash *hash) (cons 'plaintext *plaintext) (cons 'body *body)) (lambda () (Outcome #:success #t)))))))

(define-handler
  (login [body : Credentials])
  #:capabilities [sessions dbRead]
  #:returns Outcome
  (thsl-src! "tests/password-login-tests.tesl" 233 (list (cons 'body *body)) (lambda () (let ([stored (passwordHashFor (tesl-dot/runtime body 'email 'Credentials))]) (let/check ([tesl-checked-6 (tesl_import_Crypto_checkPassword stored (tesl-dot/runtime body 'password 'Credentials))]) (let ([_verified tesl-checked-6]) (let ([token (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" (tesl-dot/runtime body 'email 'Credentials))) (raw-value (sessionKey))))]) (let ([_ (raw-value (tesl_import_Http_setSessionCookie (raw-value token)))]) (Outcome #:success #t)))))))))

(define-handler
  (loginThenFail [body : Credentials])
  #:capabilities [sessions dbRead]
  #:returns SecondFactorOutcome
  (thsl-src! "tests/password-login-tests.tesl" 246 (list (cons 'body *body)) (lambda () (let ([stored (passwordHashFor (tesl-dot/runtime body 'email 'Credentials))]) (let/check ([tesl-checked-7 (tesl_import_Crypto_checkPassword stored (tesl-dot/runtime body 'password 'Credentials))]) (let ([_verified tesl-checked-7]) (let ([token (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" (tesl-dot/runtime body 'email 'Credentials))) (raw-value (sessionKey))))]) (let ([_ (raw-value (tesl_import_Http_setSessionCookie (raw-value token)))]) (reject "second factor required" #:http-code 403)))))))))

(define-handler
  (whoami [user : String ::: (Authenticated user)])
  #:returns Profile
  (thsl-src! "tests/password-login-tests.tesl" 253 (list (cons 'user *user)) (lambda () (Profile #:user *user))))

(define AccountServer-sse-routes '())
(define-api AccountApi
  [register :
    "register"
    :> (ReqBody JSON [body : RegisterBody])
    :> (Post JSON Outcome)
    ]
  [login :
    "login"
    :> (ReqBody JSON [body : Credentials])
    :> (Post JSON Outcome)
    ]
  [loginThenFail :
    "login-then-fail"
    :> (ReqBody JSON [body : Credentials])
    :> (Post JSON SecondFactorOutcome)
    ]
  [whoami :
    (Auth [user : String ::: (Authenticated user)] #:via sessionOwner)
    :> "me"
    :> (Get JSON Profile)
    ]
)

(define-server AccountServer
  #:api AccountApi
  [register register]
  [login login]
  [loginThenFail loginThenFail]
  [whoami whoami]
)

(module+ test
  (require rackunit)
  (test-case "register, log in, and reach a protected endpoint"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define registered (thsl-src! "tests/password-login-tests.tesl" 315 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 316 (list (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref registered 'status)))))))
              (define loginResp (thsl-src! "tests/password-login-tests.tesl" 318 (list (cons 'registered registered)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 319 (list (cons 'loginResp loginResp) (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref loginResp 'status)))))))
              (let ([*tesl-case-8 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 321 (list (cons 'loginResp loginResp) (cons 'registered registered)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-8) 'value)])
                    (define me (thsl-src! "tests/password-login-tests.tesl" 323 (list (cons 'loginResp loginResp) (cons 'registered registered)) (lambda () (dispatch-api-test-request AccountServer 'get (list "me") #:cookie session #:headers (tesl-hash) #:capabilities (list accountWrite dbRead sessions)))))
                    (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 324 (list (cons 'me me) (cons 'loginResp loginResp) (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref me 'status)))))))
                    (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 325 (list (cons 'me me) (cons 'loginResp loginResp) (cons 'registered registered)) (lambda () (api-test-field-access-ref (api-test-field-access-ref me 'body) 'user)))) "alice@example.com")
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
  (test-case "the session names the user who actually logged in"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define a (thsl-src! "tests/password-login-tests.tesl" 329 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 330 (list (cons 'a a)) (lambda () (statusOk (raw-value (api-test-field-access-ref a 'status)))))))
              (define b (thsl-src! "tests/password-login-tests.tesl" 331 (list (cons 'a a)) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-2" (string->symbol "email") "bob@example.com" (string->symbol "password") "brevity-is-the-soul") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 332 (list (cons 'b b) (cons 'a a)) (lambda () (statusOk (raw-value (api-test-field-access-ref b 'status)))))))
              (define loginResp (thsl-src! "tests/password-login-tests.tesl" 334 (list (cons 'b b) (cons 'a a)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "bob@example.com" (string->symbol "password") "brevity-is-the-soul") #:capabilities (list accountWrite dbRead sessions)))))
              (let ([*tesl-case-9 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 336 (list (cons 'loginResp loginResp) (cons 'b b) (cons 'a a)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-9) 'value)])
                    (define me (thsl-src! "tests/password-login-tests.tesl" 338 (list (cons 'loginResp loginResp) (cons 'b b) (cons 'a a)) (lambda () (dispatch-api-test-request AccountServer 'get (list "me") #:cookie session #:headers (tesl-hash) #:capabilities (list accountWrite dbRead sessions)))))
                    (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 339 (list (cons 'me me) (cons 'loginResp loginResp) (cons 'b b) (cons 'a a)) (lambda () (api-test-field-access-ref (api-test-field-access-ref me 'body) 'user)))) "bob@example.com")
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
  (test-case "a wrong password is a 401 and mints no cookie"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define registered (thsl-src! "tests/password-login-tests.tesl" 347 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 348 (list (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref registered 'status)))))))
              (define loginResp (thsl-src! "tests/password-login-tests.tesl" 350 (list (cons 'registered registered)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-batteryX") #:capabilities (list accountWrite dbRead sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 351 (list (cons 'loginResp loginResp) (cons 'registered registered)) (lambda () (api-test-field-access-ref loginResp 'status)))) 401)
              (let ([*tesl-case-10 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-10) 'value)])
                    (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 353 (list (cons 'loginResp loginResp) (cons 'registered registered)) (lambda () #f))))
                  )
                ]
                [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 354 (list (cons 'loginResp loginResp) (cons 'registered registered)) (lambda () #t))))
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an unknown account is refused exactly like a wrong password"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define registered (thsl-src! "tests/password-login-tests.tesl" 358 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 359 (list (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref registered 'status)))))))
              (define wrongPassword (thsl-src! "tests/password-login-tests.tesl" 364 (list (cons 'registered registered)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "alice@example.com" (string->symbol "password") "not-her-password") #:capabilities (list accountWrite dbRead sessions)))))
              (define noSuchUser (thsl-src! "tests/password-login-tests.tesl" 365 (list (cons 'wrongPassword wrongPassword) (cons 'registered registered)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "nobody@example.com" (string->symbol "password") "not-her-password") #:capabilities (list accountWrite dbRead sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 366 (list (cons 'noSuchUser noSuchUser) (cons 'wrongPassword wrongPassword) (cons 'registered registered)) (lambda () (api-test-field-access-ref wrongPassword 'status)))) 401)
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 367 (list (cons 'noSuchUser noSuchUser) (cons 'wrongPassword wrongPassword) (cons 'registered registered)) (lambda () (api-test-field-access-ref noSuchUser 'status)))) 401)
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 368 (list (cons 'noSuchUser noSuchUser) (cons 'wrongPassword wrongPassword) (cons 'registered registered)) (lambda () (api-test-field-access-ref (api-test-field-access-ref wrongPassword 'body) 'error)))) (api-test-field-access-ref (api-test-field-access-ref noSuchUser 'body) 'error))
              (let ([*tesl-case-11 (raw-value (responseCookie (raw-value noSuchUser)))]) (cond
                [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-11) 'value)])
                    (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 370 (list (cons 'noSuchUser noSuchUser) (cons 'wrongPassword wrongPassword) (cons 'registered registered)) (lambda () #f))))
                  )
                ]
                [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 371 (list (cons 'noSuchUser noSuchUser) (cons 'wrongPassword wrongPassword) (cons 'registered registered)) (lambda () #t))))
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "one account's password does not log in as another"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define a (thsl-src! "tests/password-login-tests.tesl" 375 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 376 (list (cons 'a a)) (lambda () (statusOk (raw-value (api-test-field-access-ref a 'status)))))))
              (define b (thsl-src! "tests/password-login-tests.tesl" 377 (list (cons 'a a)) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-2" (string->symbol "email") "bob@example.com" (string->symbol "password") "brevity-is-the-soul") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 378 (list (cons 'b b) (cons 'a a)) (lambda () (statusOk (raw-value (api-test-field-access-ref b 'status)))))))
              (define crossed (thsl-src! "tests/password-login-tests.tesl" 382 (list (cons 'b b) (cons 'a a)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "bob@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 383 (list (cons 'crossed crossed) (cons 'b b) (cons 'a a)) (lambda () (api-test-field-access-ref crossed 'status)))) 401)
              (let ([*tesl-case-12 (raw-value (responseCookie (raw-value crossed)))]) (cond
                [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-12) 'value)])
                    (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 385 (list (cons 'crossed crossed) (cons 'b b) (cons 'a a)) (lambda () #f))))
                  )
                ]
                [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 386 (list (cons 'crossed crossed) (cons 'b b) (cons 'a a)) (lambda () #t))))
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an empty password is a 401, not an accident"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define registered (thsl-src! "tests/password-login-tests.tesl" 390 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 391 (list (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref registered 'status)))))))
              (define empty (thsl-src! "tests/password-login-tests.tesl" 392 (list (cons 'registered registered)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "alice@example.com" (string->symbol "password") "") #:capabilities (list accountWrite dbRead sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 393 (list (cons 'empty empty) (cons 'registered registered)) (lambda () (api-test-field-access-ref empty 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the declared policy refuses a weak password at registration"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define weak (thsl-src! "tests/password-login-tests.tesl" 399 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "short") #:capabilities (list accountWrite dbRead sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 400 (list (cons 'weak weak)) (lambda () (api-test-field-access-ref weak 'status)))) 400)
              (define attempt (thsl-src! "tests/password-login-tests.tesl" 403 (list (cons 'weak weak)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "alice@example.com" (string->symbol "password") "short") #:capabilities (list accountWrite dbRead sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 404 (list (cons 'attempt attempt) (cons 'weak weak)) (lambda () (api-test-field-access-ref attempt 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "no session cookie is a 401 on the protected endpoint"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions dbRead)
              (define me (thsl-src! "tests/password-login-tests.tesl" 408 (list) (lambda () (dispatch-api-test-request AccountServer 'get (list "me") #:headers (tesl-hash) #:capabilities (list sessions dbRead)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 409 (list (cons 'me me)) (lambda () (api-test-field-access-ref me 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a verified login that then fails leaves no session"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define registered (thsl-src! "tests/password-login-tests.tesl" 413 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 414 (list (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref registered 'status)))))))
              (define resp (thsl-src! "tests/password-login-tests.tesl" 419 (list (cons 'registered registered)) (lambda () (dispatch-api-test-request AccountServer 'post (list "login-then-fail") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 420 (list (cons 'resp resp) (cons 'registered registered)) (lambda () (api-test-field-access-ref resp 'status)))) 403)
              (let ([*tesl-case-13 (raw-value (responseCookie (raw-value resp)))]) (cond
                [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-13) 'value)])
                    (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 422 (list (cons 'resp resp) (cons 'registered registered)) (lambda () #f))))
                  )
                ]
                [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 423 (list (cons 'resp resp) (cons 'registered registered)) (lambda () #t))))
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a tampered session cookie does not authenticate"
    (call-with-fresh-memory-db (list Accounts)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (accountWrite dbRead sessions)
              (define registered (thsl-src! "tests/password-login-tests.tesl" 427 (list) (lambda () (dispatch-api-test-request AccountServer 'post (list "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "id") "acct-1" (string->symbol "email") "alice@example.com" (string->symbol "password") "correct-horse-battery") #:capabilities (list accountWrite dbRead sessions)))))
              (check-true (raw-value (thsl-src! "tests/password-login-tests.tesl" 428 (list (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref registered 'status)))))))
              (define me (thsl-src! "tests/password-login-tests.tesl" 432 (list (cons 'registered registered)) (lambda () (dispatch-api-test-request AccountServer 'get (list "me") #:cookie "__Host-session=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImRlYWRiZWVmZGVhZGJlZWYifQ.eyJzdWIiOiJhZG1pbiJ9.not-a-valid-signature" #:headers (tesl-hash) #:capabilities (list accountWrite dbRead sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 433 (list (cons 'me me) (cons 'registered registered)) (lambda () (api-test-field-access-ref me 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a fresh Argon2id hash does not ask to be rehashed"
    (call-with-fresh-memory-db (list Accounts) (lambda ()
    (with-capabilities (dbRead dbWrite random)
    (define plaintext (thsl-src! "tests/password-login-tests.tesl" 287 (list) (lambda () (raw-value (Password "correct-horse-battery")))))
    (define hash (thsl-src! "tests/password-login-tests.tesl" 288 (list (cons 'plaintext plaintext)) (lambda () (raw-value (tesl_import_Crypto_hashPassword (raw-value plaintext))))))
    (insert-one! Account (tesl-hash 'id "acct-1" 'email "alice@example.com" 'passwordHash hash))
    (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 290 (list (cons 'hash hash) (cons 'plaintext plaintext)) (lambda () (accountExists "alice@example.com")))) #t)
    (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 294 (list (cons 'hash hash) (cons 'plaintext plaintext)) (lambda () (storedHashNeedsRehash "alice@example.com")))) #f)
    )
    ))
  )

  (test-case "the same password hashes to two different values"
    (call-with-fresh-memory-db (list Accounts) (lambda ()
    (with-capabilities (random)
    (define plaintext (thsl-src! "tests/password-login-tests.tesl" 303 (list) (lambda () (raw-value (Password "correct-horse-battery")))))
    (define first (thsl-src! "tests/password-login-tests.tesl" 304 (list (cons 'plaintext plaintext)) (lambda () (raw-value (tesl_import_Crypto_hashPassword (raw-value plaintext))))))
    (define second (thsl-src! "tests/password-login-tests.tesl" 305 (list (cons 'first first) (cons 'plaintext plaintext)) (lambda () (raw-value (tesl_import_Crypto_hashPassword (raw-value plaintext))))))
    (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 306 (list (cons 'second second) (cons 'first first) (cons 'plaintext plaintext)) (lambda () (raw-value (tesl_import_Crypto_needsRehash (raw-value first)))))) #f)
    (check-equal? (raw-value (thsl-src! "tests/password-login-tests.tesl" 307 (list (cons 'second second) (cons 'first first) (cons 'plaintext plaintext)) (lambda () (raw-value (tesl_import_Crypto_needsRehash (raw-value second)))))) #f)
    )
    ))
  )

)
