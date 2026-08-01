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
  (prefix-in __tjwt_ (only-in tesl/tesl/jwt current-session-policy standard-session short-session sso-session-cookie-value current-session-revoked-hook current-previous-session-key))
  (prefix-in __ttime_ (only-in tesl/tesl/time Time.secondsToPosix))
  (prefix-in __tenv_ (only-in tesl/tesl/env requireSecret))
  (prefix-in __tcrypto_ (only-in tesl/tesl/crypto secret->bytes))
  (only-in tesl/tesl/prelude String Bool)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict Dict [Dict.lookup tesl_import_Dict_lookup] [Dict.singleton tesl_import_Dict_singleton])
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.contains tesl_import_String_contains] [String.indexOf tesl_import_String_indexOf] [String.slice tesl_import_String_slice])
  (only-in tesl/tesl/sso [Sso.defaults tesl_import_Sso_defaults] [Sso.oidc tesl_import_Sso_oidc] [Sso.subject tesl_import_Sso_subject])
  (only-in tesl/tesl/api-test statusOk responseCookie stubHttp httpCalled)
  (only-in tesl/tesl/http-client httpClient)
  (only-in tesl/tesl/time time PosixMillis)
  (only-in tesl/tesl/env envRead requireSecret)
  (only-in tesl/tesl/crypto Secret)
  (only-in tesl/tesl/jwt jwt [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/http HttpRequest [Http.sessionToken tesl_import_Http_sessionToken])
)


(provide )

(define Authenticated 'Authenticated)

(define/pow
  (extractQueryValue [url : String] [key : String])
  #:returns String
  (let ([marker (thsl-src! "example/learn/lesson80-testing-sso.tesl" 71 (list (cons 'url *url) (cons 'key *key)) (lambda () (string-append *key "=")))]) (thsl-src-control! "example/learn/lesson80-testing-sso.tesl" 72 (list (cons 'marker *marker) (cons 'url *url) (cons 'key *key)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_String_indexOf *url (raw-value marker)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 73 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([markerIdx (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 75 (list (cons 'markerIdx markerIdx)) (lambda () (let ([start (+ *markerIdx (raw-value (tesl_import_String_length (raw-value marker))))]) (let ([rest (raw-value (tesl_import_String_slice *url (raw-value start) (raw-value (tesl_import_String_length *url))))]) (let ([tesl-case-1 (raw-value (tesl_import_String_indexOf (raw-value rest) "&"))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 78 (list) (lambda () (raw-value rest)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([ampIdx (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 79 (list (cons 'ampIdx ampIdx)) (lambda () (raw-value (raw-value (tesl_import_String_slice (raw-value rest) 0 *ampIdx))))))])))))))]))))))

(define-record User
  [id : String]
)

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

(define-capability sessions (implies jwt time envRead))

(define/pow
  (sessionKey)
  #:capabilities [envRead]
  #:returns Secret
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 113 (list) (lambda () (raw-value (requireSecret "LESSON80_SESSION_KEY")))))

(define/pow
  (secretFromRaw [raw : String])
  #:returns Secret
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 119 (list (cons 'raw *raw)) (lambda () (raw-value (Secret *raw)))))

(define/pow
  (demoClientSecret)
  #:returns Secret
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 121 (list) (lambda () (raw-value (secretFromRaw "lesson80-demo-client-secret-not-for-production")))))

(define/pow
  (githubConn)
  #:returns SsoConnection
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 125 (list) (lambda () (raw-value (tesl_import_Sso_defaults "github" "demo-github-client-id" (raw-value (demoClientSecret)))))))

(define/pow
  (idpConn)
  #:returns SsoConnection
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 133 (list) (lambda () (raw-value (tesl_import_Sso_oidc "https://idp.example.test" "demo-idp-client-id" (raw-value (demoClientSecret)))))))

(define/pow
  (linkUser [identity : SsoIdentity])
  #:returns String
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 136 (list (cons 'identity *identity)) (lambda () (raw-value (tesl_import_Sso_subject *identity)))))

(define/pow
  (revoked [_subject : String] [_issuedAt : PosixMillis])
  #:returns Boolean
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 139 (list (cons '_subject *_subject) (cons '_issuedAt *_issuedAt)) (lambda () #f)))

(define/pow
  (subjectOf [claims : (Dict String String)])
  #:returns String
  (thsl-src-control! "example/learn/lesson80-testing-sso.tesl" 142 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 143 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([subject (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 144 (list (cons 'subject subject)) (lambda () *subject)))])))))

(define-auther
  (sessionOwner [request : HttpRequest])
  #:capabilities [sessions]
  #:returns [user : User ::: (Authenticated user)]
  (thsl-src-control! "example/learn/lesson80-testing-sso.tesl" 148 (list (cons 'request *request)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 149 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 151 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-4 (tesl_import_JWT_verify token (sessionKey))]) (let ([claims tesl-checked-4]) (let ([subject (subjectOf claims)]) (accept Authenticated #:value (User #:id *subject))))))))])))))

(define-handler
  (me [user : User ::: (Authenticated user)])
  #:returns Profile
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 156 (list (cons 'user *user)) (lambda () (Profile #:userId (tesl-dot/runtime user 'id 'User)))))

(define AppServer-sse-routes '())
(define-api AppApi
  [endpoint_0 :
    (Auth [user : User ::: (Authenticated user)] #:via sessionOwner)
    :> "me"
    :> (Get JSON Profile)
    ]
)

(define-server AppServer
  #:api AppApi
  [endpoint_0 me]
)
(void (__tjwt_current-session-revoked-hook (lambda (subj iat) (revoked subj (__ttime_Time.secondsToPosix iat)))))
(register-listen-address! "AppServer" "127.0.0.1")
(void (current-public-origin "https://app.example.com"))
(register-sso-routes! "AppServer" (list (make-sso-route #:segment "github" #:connection (lambda () (githubConn)) #:on-identity linkUser #:mint-session (lambda (subj) (__tjwt_sso-session-cookie-value (__tenv_requireSecret "LESSON80_SESSION_KEY") subj)) #:session-key-bytes (lambda () (__tcrypto_secret->bytes (__tenv_requireSecret "LESSON80_SESSION_KEY"))) #:public-origin "https://app.example.com" #:after-login "/me") (make-sso-route #:segment "idp" #:connection (lambda () (idpConn)) #:on-identity linkUser #:mint-session (lambda (subj) (__tjwt_sso-session-cookie-value (__tenv_requireSecret "LESSON80_SESSION_KEY") subj)) #:session-key-bytes (lambda () (__tcrypto_secret->bytes (__tenv_requireSecret "LESSON80_SESSION_KEY"))) #:public-origin "https://app.example.com" #:after-login "/me")))

(define-database AppDb
  #:backend memory
  #:entities )

(module+ main
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 181 (list) (lambda () (with-capabilities (sessions httpClient) (call-with-database AppDb (lambda () (serve AppServer #:port 8080 #:capabilities (list sessions httpClient) #:sse-routes AppServer-sse-routes)))))))

(define/pow
  (mintSession [user : String])
  #:capabilities [sessions]
  #:returns String
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 195 (list (cons 'user *user)) (lambda () (tesl-dot/runtime (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" *user)) (raw-value (sessionKey)))) 'value))))

(define/pow
  (onHost)
  #:returns (Dict String String)
  (thsl-src! "example/learn/lesson80-testing-sso.tesl" 203 (list) (lambda () (raw-value (tesl_import_Dict_singleton "Host" "app.example.com")))))

(module+ test
  (require rackunit)
  (test-case "no session cookie is a 401, not a 500"
    (call-with-fresh-memory-db (list AppDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "example/learn/lesson80-testing-sso.tesl" 208 (list) (lambda () (dispatch-api-test-request AppServer 'get (list "me") #:headers (onHost) #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 209 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a session minted with the app's own key reaches the protected route"
    (call-with-fresh-memory-db (list AppDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "example/learn/lesson80-testing-sso.tesl" 213 (list) (lambda () (dispatch-api-test-request AppServer 'get (list "me") #:cookie (tesl-hash '__Host-session (mintSession "u-42")) #:headers (onHost) #:capabilities (list sessions)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 214 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 215 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref resp 'body) 'userId)))) "u-42")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "GitHub login redirects straight to GitHub \226\128\148 no network call needed"
    (call-with-fresh-memory-db (list AppDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (sessions)
              (define resp (thsl-src! "example/learn/lesson80-testing-sso.tesl" 221 (list) (lambda () (dispatch-api-test-request AppServer 'get (list "auth" "github" "login") #:headers (onHost) #:capabilities (list sessions)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 222 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 303)
              (let ([*tesl-case-5 (raw-value (tesl_import_Dict_lookup "location" (raw-value (api-test-field-access-ref resp 'headers))))]) (cond
                [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing))
                  (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 224 (list (cons 'resp resp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something))
                  (let ([location (hash-ref (adt-value-fields *tesl-case-5) 'value)])
                    (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 226 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value location) "https://github.com/login/oauth/authorize")))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 227 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value location) "code_challenge_method=S256")))))
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
  (test-case "a generic OIDC issuer is discovered, then redirected to"
    (call-with-fresh-memory-db (list AppDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (httpClient sessions)
              (thsl-src! "example/learn/lesson80-testing-sso.tesl" 231 (list) (lambda () (stubHttp "GET" "https://idp.example.test/.well-known/openid-configuration" 200 "{\"issuer\": \"https://idp.example.test\", \"authorization_endpoint\": \"https://idp.example.test/authorize\", \"token_endpoint\": \"https://idp.example.test/token\", \"jwks_uri\": \"https://idp.example.test/jwks\", \"code_challenge_methods_supported\": [\"S256\"]}")))
              (define resp (thsl-src! "example/learn/lesson80-testing-sso.tesl" 234 (list) (lambda () (dispatch-api-test-request AppServer 'get (list "auth" "idp" "login") #:headers (onHost) #:capabilities (list httpClient sessions)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 235 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'status)))) 303)
              (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 236 (list (cons 'resp resp)) (lambda () (httpCalled "GET" "https://idp.example.test/.well-known/openid-configuration")))))
              (let ([*tesl-case-6 (raw-value (tesl_import_Dict_lookup "location" (raw-value (api-test-field-access-ref resp 'headers))))]) (cond
                [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing))
                  (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 238 (list (cons 'resp resp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something))
                  (let ([location (hash-ref (adt-value-fields *tesl-case-6) 'value)])
                    (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 240 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value location) "https://idp.example.test/authorize")))))
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
  (test-case "GitHub login all the way through: redirect, code exchange, real session"
    (call-with-fresh-memory-db (list AppDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (httpClient sessions)
              (define loginResp (thsl-src! "example/learn/lesson80-testing-sso.tesl" 246 (list) (lambda () (dispatch-api-test-request AppServer 'get (list "auth" "github" "login") #:headers (onHost) #:capabilities (list httpClient sessions)))))
              (define location (thsl-src! "example/learn/lesson80-testing-sso.tesl" 247 (list (cons 'loginResp loginResp)) (lambda () (let ([*tesl-case-7 (raw-value (tesl_import_Dict_lookup "location" (raw-value (api-test-field-access-ref loginResp 'headers))))]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing)) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 248 (list) (lambda () ""))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something)) (let ([loc (hash-ref (adt-value-fields *tesl-case-7) 'value)]) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 249 (list (cons 'loc loc)) (lambda () loc)))])))))
              (define state (thsl-src! "example/learn/lesson80-testing-sso.tesl" 250 (list (cons 'location location) (cons 'loginResp loginResp)) (lambda () (extractQueryValue (raw-value location) "state"))))
              (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 251 (list (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value state))) 0)))))
              (define oauthCookie (thsl-src! "example/learn/lesson80-testing-sso.tesl" 253 (list (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (let ([*tesl-case-8 (raw-value (responseCookie (raw-value loginResp)))]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing)) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 254 (list) (lambda () ""))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something)) (let ([pair (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "example/learn/lesson80-testing-sso.tesl" 255 (list (cons 'pair pair)) (lambda () pair)))])))))
              (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 256 (list (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (tesl_import_String_contains (raw-value oauthCookie) "__Host-oauth=")))))
              (thsl-src! "example/learn/lesson80-testing-sso.tesl" 258 (list (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (stubHttp "POST" "https://github.com/login/oauth/access_token" 200 "{\"access_token\": \"gh-test-token-1\"}")))
              (thsl-src! "example/learn/lesson80-testing-sso.tesl" 260 (list (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (stubHttp "GET" "https://api.github.com/user" 200 "{\"id\": 12345, \"name\": \"Ada Lovelace\"}")))
              (thsl-src! "example/learn/lesson80-testing-sso.tesl" 262 (list (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (stubHttp "GET" "https://api.github.com/user/emails" 200 (string-append "[" "{\"email\": \"ada@example.com\", \"primary\": true, \"verified\": true}" "]"))))
              (define callbackPath (thsl-src! "example/learn/lesson80-testing-sso.tesl" 265 (list (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (string-append (api-test-string-fragment "/auth/github/callback?code=test-code-1&state=") (api-test-string-fragment state)))))
              (define cb (thsl-src! "example/learn/lesson80-testing-sso.tesl" 266 (list (cons 'callbackPath callbackPath) (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request AppServer 'get callbackPath #:cookie oauthCookie #:headers (onHost) #:capabilities (list httpClient sessions)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 267 (list (cons 'cb cb) (cons 'callbackPath callbackPath) (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref cb 'status)))) 303)
              (let ([*tesl-case-9 (raw-value (responseCookie (raw-value cb)))]) (cond
                [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing))
                  (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 270 (list (cons 'cb cb) (cons 'callbackPath callbackPath) (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something))
                  (let ([sessionCookie (hash-ref (adt-value-fields *tesl-case-9) 'value)])
                    (define profileResp (thsl-src! "example/learn/lesson80-testing-sso.tesl" 272 (list (cons 'cb cb) (cons 'callbackPath callbackPath) (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request AppServer 'get (list "me") #:cookie sessionCookie #:headers (onHost) #:capabilities (list httpClient sessions)))))
                    (check-true (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 273 (list (cons 'profileResp profileResp) (cons 'cb cb) (cons 'callbackPath callbackPath) (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref profileResp 'status)))))))
                    (check-equal? (raw-value (thsl-src! "example/learn/lesson80-testing-sso.tesl" 274 (list (cons 'profileResp profileResp) (cons 'cb cb) (cons 'callbackPath callbackPath) (cons 'oauthCookie oauthCookie) (cons 'state state) (cons 'location location) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref profileResp 'body) 'userId)))) "12345")
                  )
                ]
              ))
            )
          ))
      ))
  )
)
