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
  tesl/tesl/cache
  tesl/tesl/email
  (only-in tesl/tesl/prelude Bool String Fact)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith] [String.dropPrefix tesl_import_String_dropPrefix] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/time nowMillis PosixMillis time)
  (only-in tesl/tesl/env env envInt)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/api-test statusOk statusClientError)
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/uuid [UUID.validate tesl_import_UUID_validate] IsUuid)
  (only-in tesl/tesl/jwt jwt JwtToken JwtSecret [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/http-client httpClient HttpResponse [HttpClient.post tesl_import_HttpClient_post])
)


(provide UserServer)

(define Authenticated 'Authenticated)
(define ValidEmail 'ValidEmail)
(define ValidPassword 'ValidPassword)
(define ValidUsername 'ValidUsername)

(define-capability userDbRead (implies dbRead))

(define-capability userDbWrite (implies dbWrite))

(define-capability userTime (implies time))

(define-capability userRandom (implies random))

(define-capability userJwt (implies jwt))

(define-capability userHttp (implies httpClient))

(define-entity User
  #:source (make-hash)
  #:table users
  #:primary-key id
  [Id id : String #:db-type text]
  [Username username : String #:db-type text]
  [EmailAddress emailAddress : String #:db-type text]
  [PasswordHash passwordHash : String #:db-type text]
  [Bio bio : String #:db-type text]
  [AvatarUrl avatarUrl : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
)

(define-database UserDatabase
  #:backend postgres
  #:database (tesl-env-raw "USER_DB_NAME")
  #:user (tesl-env-raw "USER_DB_USER")
  #:password (tesl-env-raw "USER_DB_PASSWORD")
  #:server (tesl-env-raw "USER_DB_HOST")
  #:port (tesl-env-int-raw "USER_DB_PORT" 5432)
  #:schema user_service
  #:entities User)

(define-capability cache_UserProfileCache)
(define-cache UserProfileCache #:database UserDatabase #:default-ttl 3600)

(define-email UserServiceMail #:database UserDatabase #:smtp-host (tesl-env-raw "SMTP_HOST") #:smtp-port 587 #:smtp-username (tesl-env-raw "SMTP_USER") #:smtp-password (tesl-env-raw "SMTP_PASS") #:smtp-tls #t)

(define-checker
  (checkEmail [s : String])
  #:returns [s : String ::: (ValidEmail s)]
  (thsl-src! "example/user-service-api.tesl" 177 (list (cons 's *s)) (lambda () (if (and (raw-value (tesl_import_String_contains *s "@")) (>= (raw-value (tesl_import_String_length *s)) 5)) (accept (ValidEmail s) #:value *s) (reject "Invalid email address" #:http-code 400)))))

(define-checker
  (checkUsername [s : String])
  #:returns [s : String ::: (ValidUsername s)]
  (thsl-src! "example/user-service-api.tesl" 185 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 2) (<= (raw-value (tesl_import_String_length *s)) 40)) (accept (ValidUsername s) #:value *s) (reject "Username must be 2-40 characters" #:http-code 400)))))

(define-checker
  (checkPassword [s : String])
  #:returns [s : String ::: (ValidPassword s)]
  (thsl-src! "example/user-service-api.tesl" 193 (list (cons 's *s)) (lambda () (if (>= (raw-value (tesl_import_String_length *s)) 8) (accept (ValidPassword s) #:value *s) (reject "Password must be at least 8 characters" #:http-code 400)))))

(define-record RegisterRequest
  [username : String ::: (ValidUsername username)]
  [emailAddr : String ::: (ValidEmail emailAddr)]
  [password : String ::: (ValidPassword password)]
)

(define (tesl-codec-encode-RegisterRequest _v)
  (error "toJson is forbidden for type RegisterRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-RegisterRequest-0 _j)
  (define _fraw_username (tesl-decode-prim-field _j "username" tesl-decode-prim-string))
  (define _r1_username
    (let ([_r (checkUsername _fraw_username)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_username
    (if (check-ok? _r1_username)
        (ensure-named 'username (check-ok-value _r1_username) (check-ok-facts _r1_username) (check-ok-bindings _r1_username) #:subject 'username)
        _r1_username))
  (define _fraw_emailAddr (tesl-decode-prim-field _j "email" tesl-decode-prim-string))
  (define _r1_emailAddr
    (let ([_r (checkEmail _fraw_emailAddr)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_emailAddr
    (if (check-ok? _r1_emailAddr)
        (ensure-named 'emailAddr (check-ok-value _r1_emailAddr) (check-ok-facts _r1_emailAddr) (check-ok-bindings _r1_emailAddr) #:subject 'emailAddr)
        _r1_emailAddr))
  (define _fraw_password (tesl-decode-prim-field _j "password" tesl-decode-prim-string))
  (define _r1_password
    (let ([_r (checkPassword _fraw_password)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_password
    (if (check-ok? _r1_password)
        (ensure-named 'password (check-ok-value _r1_password) (check-ok-facts _r1_password) (check-ok-bindings _r1_password) #:subject 'password)
        _r1_password))
  (or (and (check-fail? _f_username) _f_username) (and (check-fail? _f_emailAddr) _f_emailAddr) (and (check-fail? _f_password) _f_password)
      (record-value 'RegisterRequest (hash 'username _f_username 'emailAddr _f_emailAddr 'password _f_password))))
(register-type-codec! 'RegisterRequest tesl-codec-encode-RegisterRequest (list tesl-codec-decode-RegisterRequest-0))

(define-record LoginRequest
  [emailAddr : String ::: (ValidEmail emailAddr)]
  [password : String]
)

(define (tesl-codec-encode-LoginRequest _v)
  (error "toJson is forbidden for type LoginRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-LoginRequest-0 _j)
  (define _fraw_emailAddr (tesl-decode-prim-field _j "email" tesl-decode-prim-string))
  (define _r1_emailAddr
    (let ([_r (checkEmail _fraw_emailAddr)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_emailAddr
    (if (check-ok? _r1_emailAddr)
        (ensure-named 'emailAddr (check-ok-value _r1_emailAddr) (check-ok-facts _r1_emailAddr) (check-ok-bindings _r1_emailAddr) #:subject 'emailAddr)
        _r1_emailAddr))
  (define _f_password (tesl-decode-prim-field _j "password" tesl-decode-prim-string))
  (or (and (check-fail? _f_emailAddr) _f_emailAddr)
      (record-value 'LoginRequest (hash 'emailAddr _f_emailAddr 'password _f_password))))
(register-type-codec! 'LoginRequest tesl-codec-encode-LoginRequest (list tesl-codec-decode-LoginRequest-0))

(define-record UpdateProfileRequest
  [bio : String]
)

(define (tesl-codec-encode-UpdateProfileRequest _v)
  (error "toJson is forbidden for type UpdateProfileRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-UpdateProfileRequest-0 _j)
  (define _f_bio (tesl-decode-prim-field _j "bio" tesl-decode-prim-string))
  (record-value 'UpdateProfileRequest (hash 'bio _f_bio)))
(register-type-codec! 'UpdateProfileRequest tesl-codec-encode-UpdateProfileRequest (list tesl-codec-decode-UpdateProfileRequest-0))

(define-record ForgotPasswordRequest
  [emailAddr : String ::: (ValidEmail emailAddr)]
)

(define (tesl-codec-encode-ForgotPasswordRequest _v)
  (error "toJson is forbidden for type ForgotPasswordRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-ForgotPasswordRequest-0 _j)
  (define _fraw_emailAddr (tesl-decode-prim-field _j "email" tesl-decode-prim-string))
  (define _r1_emailAddr
    (let ([_r (checkEmail _fraw_emailAddr)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_emailAddr
    (if (check-ok? _r1_emailAddr)
        (ensure-named 'emailAddr (check-ok-value _r1_emailAddr) (check-ok-facts _r1_emailAddr) (check-ok-bindings _r1_emailAddr) #:subject 'emailAddr)
        _r1_emailAddr))
  (or (and (check-fail? _f_emailAddr) _f_emailAddr)
      (record-value 'ForgotPasswordRequest (hash 'emailAddr _f_emailAddr))))
(register-type-codec! 'ForgotPasswordRequest tesl-codec-encode-ForgotPasswordRequest (list tesl-codec-decode-ForgotPasswordRequest-0))

(define-record AuthResponse
  [token : String]
  [userId : String]
)

(define (tesl-codec-encode-AuthResponse _v)
  (error "toJson is forbidden for type AuthResponse: this type cannot be JSON-encoded"))
(register-type-codec! 'AuthResponse tesl-codec-encode-AuthResponse (list ))

(define jwtSigningSecret (raw-value (JwtSecret "dev-secret-change-in-production")))

(define/pow
  (makeToken [userId : String])
  #:capabilities [userJwt]
  #:returns JwtToken
  (thsl-src! "example/user-service-api.tesl" 301 (list (cons 'userId *userId)) (lambda () (raw-value (tesl_import_JWT_sign *userId (raw-value jwtSigningSecret))))))

(define-auther
  (jwtAuth [request : HttpRequest])
  #:capabilities [userJwt]
  #:returns [userId : String ::: (Authenticated userId)]
  (thsl-src-control! "example/user-service-api.tesl" 306 (list (cons 'request *request)) (lambda () (let ([tesl_case_0 (raw-value (tesl_import_Dict_lookup "authorization" (raw-value request.headers)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (thsl-src! "example/user-service-api.tesl" 308 (list) (lambda () (reject "Missing Authorization header" #:http-code 401)))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([rawHeader (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (thsl-src! "example/user-service-api.tesl" 310 (list (cons 'rawHeader rawHeader)) (lambda () (if (tesl_import_String_startsWith (raw-value rawHeader) "Bearer ") (let ([tokenStr (raw-value (tesl_import_String_dropPrefix (raw-value rawHeader) "Bearer "))]) (let ([verifiedUserId (raw-value (tesl_import_JWT_verify (JwtToken tokenStr) (raw-value jwtSigningSecret)))]) (accept (Authenticated verifiedUserId) #:value *verifiedUserId))) (reject "Authorization header must start with 'Bearer '" #:http-code 401)))))])))))

(define/pow
  (notifyWebhook [userId : String])
  #:capabilities [userHttp]
  #:returns HttpResponse
  (let ([webhookUrl (thsl-src! "example/user-service-api.tesl" 329 (list (cons 'userId *userId)) (lambda () "https://example.com/webhooks/profile"))]) (let ([payload (thsl-src! "example/user-service-api.tesl" 330 (list (cons 'webhookUrl *webhookUrl) (cons 'userId *userId)) (lambda () (string-append "profile_updated:" *userId)))]) (let ([headers (thsl-src! "example/user-service-api.tesl" 331 (list (cons 'payload *payload) (cons 'webhookUrl *webhookUrl) (cons 'userId *userId)) (lambda () (list (Tuple2 "Content-Type" "application/json"))))]) (thsl-src! "example/user-service-api.tesl" 332 (list (cons 'headers *headers) (cons 'payload *payload) (cons 'webhookUrl *webhookUrl) (cons 'userId *userId)) (lambda () (raw-value (tesl_import_HttpClient_post (raw-value webhookUrl) (raw-value headers) (raw-value payload)))))))))

(define-handler
  (register [body : RegisterRequest])
  #:capabilities [userDbRead userDbWrite userTime userRandom userJwt email]
  #:returns AuthResponse
  (let ([existing (thsl-src! "example/user-service-api.tesl" 352 (list (cons 'body *body)) (lambda () (let ([tesl_match (select-one (from User) (where (==. (entity-field-ref User 'emailAddress) (raw-value body.emailAddr))))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/user-service-api.tesl" 353 (list (cons 'existing *existing) (cons 'body *body)) (lambda () (let ([tesl_case_1 (raw-value existing)]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (thsl-src! "example/user-service-api.tesl" 355 (list) (lambda () (reject "Email is already registered" #:http-code 409)))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (thsl-src! "example/user-service-api.tesl" 359 (list) (lambda () (let ([userId (generatePrefixedId "user")]) (let ([passwordHash (string-append "hash:" (raw-value body.password))]) (let ([token (makeToken userId)]) (let ([userEmail (raw-value body.emailAddr)]) (let ([displayName (raw-value body.username)]) (let ([_ (insert-one! User (hash 'id userId 'username displayName 'emailAddress userEmail 'passwordHash passwordHash 'bio "" 'avatarUrl "" 'createdAt (raw-value (nowMillis))))]) (begin (send-email! UserServiceMail #:to userEmail #:subject "Welcome to UserService!" #:body (raw-value (TextBody (raw-value displayName)))) (AuthResponse #:token (raw-value token.value) #:userId *userId))))))))))]))))))

(define-handler
  (login [body : LoginRequest])
  #:capabilities [userDbRead userJwt]
  #:returns AuthResponse
  (let ([found (thsl-src! "example/user-service-api.tesl" 376 (list (cons 'body *body)) (lambda () (let ([tesl_match (select-one (from User) (where (==. (entity-field-ref User 'emailAddress) (raw-value body.emailAddr))))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/user-service-api.tesl" 377 (list (cons 'found *found) (cons 'body *body)) (lambda () (let ([tesl_case_2 (raw-value found)]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (thsl-src! "example/user-service-api.tesl" 379 (list) (lambda () (reject "Invalid email or password" #:http-code 401)))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([user (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (thsl-src! "example/user-service-api.tesl" 382 (list (cons 'user user)) (lambda () (let ([expectedHash (string-append "hash:" (raw-value body.password))]) (if (equal? (raw-value user.passwordHash) (raw-value expectedHash)) (let ([token (makeToken (raw-value user.id))]) (AuthResponse #:token (raw-value token.value) #:userId (raw-value user.id))) (reject "Invalid email or password" #:http-code 401))))))]))))))

(define-handler
  (getProfile [userId : String ::: (Authenticated userId)])
  #:capabilities [userDbRead cache_UserProfileCache]
  #:returns User
  (let ([cacheKey (thsl-src! "example/user-service-api.tesl" 400 (list (cons 'userId *userId)) (lambda () (string-append "profile_" *userId)))]) (thsl-src-control! "example/user-service-api.tesl" 402 (list (cons 'cacheKey *cacheKey) (cons 'userId *userId)) (lambda () (let ([tesl_case_3 (raw-value (cache-get! UserProfileCache cacheKey))]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Something)) (let ([user (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (thsl-src! "example/user-service-api.tesl" 405 (list (cons 'user user)) (lambda () *user)))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Nothing)) (thsl-src! "example/user-service-api.tesl" 408 (list) (lambda () (let ([found (let ([tesl_match (select-one (from User) (where (==. (entity-field-ref User 'id) userId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_4 (raw-value found)]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Nothing)) (thsl-src! "example/user-service-api.tesl" 411 (list) (lambda () (reject "User not found" #:http-code 404)))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Something)) (let ([user (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (thsl-src! "example/user-service-api.tesl" 413 (list (cons 'user user)) (lambda () (begin (cache-set! UserProfileCache cacheKey *user) *user))))])))))]))))))

(define-handler
  (updateProfile [userId : String ::: (Authenticated userId)] [body : UpdateProfileRequest])
  #:capabilities [userDbRead userDbWrite cache_UserProfileCache userHttp]
  #:returns User
  (let ([found (thsl-src! "example/user-service-api.tesl" 430 (list (cons 'userId *userId) (cons 'body *body)) (lambda () (let ([tesl_match (select-one (from User) (where (==. (entity-field-ref User 'id) userId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/user-service-api.tesl" 431 (list (cons 'found *found) (cons 'userId *userId) (cons 'body *body)) (lambda () (let ([tesl_case_5 (raw-value found)]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Nothing)) (thsl-src! "example/user-service-api.tesl" 433 (list) (lambda () (reject "User not found" #:http-code 404)))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Something)) (thsl-src! "example/user-service-api.tesl" 438 (list) (lambda () (let ([cacheKey (string-append "profile_" *userId)]) (begin (cache-delete! UserProfileCache cacheKey) (let ([_ (notifyWebhook userId)]) (car (update-many! (from User) (hash (entity-field-ref User 'bio) (raw-value body.bio)) (where (==. (entity-field-ref User 'id) userId)))))))))]))))))

(define-handler
  (forgotPassword [body : ForgotPasswordRequest])
  #:capabilities [userDbRead email]
  #:returns String
  (let ([found (thsl-src! "example/user-service-api.tesl" 458 (list (cons 'body *body)) (lambda () (let ([tesl_match (select-one (from User) (where (==. (entity-field-ref User 'emailAddress) (raw-value body.emailAddr))))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/user-service-api.tesl" 459 (list (cons 'found *found) (cons 'body *body)) (lambda () (let ([tesl_case_6 (raw-value found)]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Nothing)) (thsl-src! "example/user-service-api.tesl" 462 (list) (lambda () "If that email is registered, a reset link has been sent."))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Something)) (let ([user (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (thsl-src! "example/user-service-api.tesl" 465 (list (cons 'user user)) (lambda () (let ([resetAddr (raw-value body.emailAddr)]) (begin (send-email! UserServiceMail #:to resetAddr #:subject "Reset your UserService password" #:body (raw-value (TextBody (raw-value user.id)))) "If that email is registered, a reset link has been sent.")))))]))))))

(define UserServer-sse-routes '())
(define-api UserApi
  [register :
    "register"
    :> (ReqBody JSON [body : RegisterRequest])
    :> (Post JSON AuthResponse)
    ]
  [login :
    "login"
    :> (ReqBody JSON [body : LoginRequest])
    :> (Post JSON AuthResponse)
    ]
  [getProfile :
    (Auth [userId : String ::: (Authenticated userId)] #:via jwtAuth)
    :> "me"
    :> (Get JSON User)
    ]
  [updateProfile :
    (Auth [userId : String ::: (Authenticated userId)] #:via jwtAuth)
    :> "me"
    :> (ReqBody JSON [body : UpdateProfileRequest])
    :> (Put JSON User)
    ]
  [forgotPassword :
    "forgot-password"
    :> (ReqBody JSON [body : ForgotPasswordRequest])
    :> (Post JSON String)
    ]
)

(define-server UserServer
  #:api UserApi
  [register register]
  [login login]
  [getProfile getProfile]
  [updateProfile updateProfile]
  [forgotPassword forgotPassword]
)

(module+ test
  (require rackunit)
  (test-case "POST /register succeeds with valid body"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'post (list "register") #:headers (hash) #:body (hash (string->symbol "username") "alice" (string->symbol "email") "alice@example.com" (string->symbol "password") "securepass") #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "POST /login succeeds with valid body"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'post (list "login") #:headers (hash) #:body (hash (string->symbol "email") "alice@example.com" (string->symbol "password") "securepass") #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "POST /forgot-password succeeds with valid body"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'post (list "forgot-password") #:headers (hash) #:body (hash (string->symbol "email") "alice@example.com") #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "GET /me returns 401 without Authorization header"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'get (list "me") #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "PUT /me returns 401 without Authorization header"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'put (list "me") #:headers (hash) #:body (hash (string->symbol "bio") "Hello world") #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "POST /register with invalid email returns 400"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'post (list "register") #:headers (hash) #:body (hash (string->symbol "username") "bob" (string->symbol "email") "not-an-email" (string->symbol "password") "securepass") #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "POST /register with short password returns 400"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'post (list "register") #:headers (hash) #:body (hash (string->symbol "username") "bob" (string->symbol "email") "bob@example.com" (string->symbol "password") "short") #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "POST /register with short username returns 400"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'post (list "register") #:headers (hash) #:body (hash (string->symbol "username") "x" (string->symbol "email") "x@example.com" (string->symbol "password") "securepass") #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "POST /login with missing password field returns 400"
    (call-with-fresh-memory-db (list UserDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request UserServer 'post (list "login") #:headers (hash) #:body (hash (string->symbol "email") "alice@example.com") #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value resp))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "UUID.validate accepts a valid v4 UUID"
  (define v4 (thsl-src! "example/user-service-api.tesl" 519 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (check-equal? (raw-value (thsl-src! "example/user-service-api.tesl" 520 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_UUID_validate (raw-value v4)))))) v4)
  )

  (test-case "UUID.validate accepts a valid v7 UUID"
  (define v7 (thsl-src! "example/user-service-api.tesl" 524 (list) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (check-equal? (raw-value (thsl-src! "example/user-service-api.tesl" 525 (list (cons 'v7 v7)) (lambda () (raw-value (tesl_import_UUID_validate (raw-value v7)))))) v7)
  )

  (test-case "UUID.validate accepts a v4 UUID"
  (define v4 (thsl-src! "example/user-service-api.tesl" 530 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (define result (thsl-src! "example/user-service-api.tesl" 531 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_UUID_validate (raw-value v4))))))
  (check-equal? (raw-value (thsl-src! "example/user-service-api.tesl" 532 (list (cons 'result result) (cons 'v4 v4)) (lambda () result))) v4)
  )

  (test-case "UUID.validate accepts a v7 UUID"
  (define v7 (thsl-src! "example/user-service-api.tesl" 536 (list) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (define result (thsl-src! "example/user-service-api.tesl" 537 (list (cons 'v7 v7)) (lambda () (raw-value (tesl_import_UUID_validate (raw-value v7))))))
  (check-equal? (raw-value (thsl-src! "example/user-service-api.tesl" 538 (list (cons 'result result) (cons 'v7 v7)) (lambda () result))) v7)
  )

  (test-case "JwtToken.value retrieves the inner string"
  (define raw (thsl-src! "example/user-service-api.tesl" 543 (list) (lambda () "eyJhbGciOiJIUzI1NiJ9.payload.sig")))
  (define token (thsl-src! "example/user-service-api.tesl" 544 (list (cons 'raw raw)) (lambda () (raw-value (JwtToken (raw-value raw))))))
  (check-equal? (thsl-src! "example/user-service-api.tesl" 545 (list (cons 'token token) (cons 'raw raw)) (lambda () (raw-value (tesl-dot/runtime token 'value)))) raw)
  )

  (test-case "JwtSecret.value retrieves the inner key"
  (define key (thsl-src! "example/user-service-api.tesl" 549 (list) (lambda () "my-signing-key")))
  (define secret (thsl-src! "example/user-service-api.tesl" 550 (list (cons 'key key)) (lambda () (raw-value (JwtSecret (raw-value key))))))
  (check-equal? (thsl-src! "example/user-service-api.tesl" 551 (list (cons 'secret secret) (cons 'key key)) (lambda () (raw-value (tesl-dot/runtime secret 'value)))) key)
  )

  (test-case "JwtToken wrapping preserves the string"
  (define t1 (thsl-src! "example/user-service-api.tesl" 557 (list) (lambda () (raw-value (JwtToken "a.b.c")))))
  (define t2 (thsl-src! "example/user-service-api.tesl" 558 (list (cons 't1 t1)) (lambda () (raw-value (JwtToken "x.y.z")))))
  (check-not-equal? (thsl-src! "example/user-service-api.tesl" 559 (list (cons 't2 t2) (cons 't1 t1)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
  )

  (test-case "checkEmail accepts a valid email address"
  (define addr (thsl-src! "example/user-service-api.tesl" 564 (list) (lambda () "alice@example.com")))
  (define tesl_checked_7 (checkEmail addr))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl_checked_7)))
  (define result tesl_checked_7)
  (check-equal? (raw-value (thsl-src! "example/user-service-api.tesl" 566 (list (cons 'result result) (cons 'addr addr)) (lambda () result))) addr)
  )

  (test-case "checkUsername accepts a 2-character username"
  (define name (thsl-src! "example/user-service-api.tesl" 570 (list) (lambda () "al")))
  (define tesl_checked_8 (checkUsername name))
  (when (check-fail? tesl_checked_8)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl_checked_8)))
  (define result tesl_checked_8)
  (check-equal? (raw-value (thsl-src! "example/user-service-api.tesl" 572 (list (cons 'result result) (cons 'name name)) (lambda () result))) name)
  )

  (test-case "checkPassword accepts an 8-character password"
  (define pwd (thsl-src! "example/user-service-api.tesl" 576 (list) (lambda () "secure42")))
  (define tesl_checked_9 (checkPassword pwd))
  (when (check-fail? tesl_checked_9)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl_checked_9)))
  (define result tesl_checked_9)
  (check-equal? (raw-value (thsl-src! "example/user-service-api.tesl" 578 (list (cons 'result result) (cons 'pwd pwd)) (lambda () result))) pwd)
  )

)
