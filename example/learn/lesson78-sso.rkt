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
  (only-in tesl/tesl/dict Dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/sso [Sso.defaults tesl_import_Sso_defaults] [Sso.subject tesl_import_Sso_subject])
  (only-in tesl/tesl/env envRead requireEnv requireSecret)
  (only-in tesl/tesl/http-client httpClient)
  (only-in tesl/tesl/db dbRead)
  (only-in tesl/tesl/time time PosixMillis)
  (only-in tesl/tesl/crypto Secret)
  (only-in tesl/tesl/jwt jwt [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/http HttpRequest [Http.sessionToken tesl_import_Http_sessionToken])
)


(provide )

(define Authenticated 'Authenticated)

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
  (thsl-src! "example/learn/lesson78-sso.tesl" 72 (list) (lambda () (raw-value (requireSecret "SESSION_KEY")))))

(define/pow
  (githubConn)
  #:capabilities [envRead]
  #:returns SsoConnection
  (thsl-src! "example/learn/lesson78-sso.tesl" 82 (list) (lambda () (raw-value (tesl_import_Sso_defaults "github" (raw-value (requireEnv "GH_CLIENT_ID")) (raw-value (requireSecret "GH_CLIENT_SECRET")))))))

(define/pow
  (linkUser [identity : SsoIdentity])
  #:returns String
  (thsl-src! "example/learn/lesson78-sso.tesl" 94 (list (cons 'identity *identity)) (lambda () (raw-value (tesl_import_Sso_subject *identity)))))

(define/pow
  (revoked [_subject : String] [_issuedAt : PosixMillis])
  #:capabilities [dbRead]
  #:returns Boolean
  (thsl-src! "example/learn/lesson78-sso.tesl" 103 (list (cons '_subject *_subject) (cons '_issuedAt *_issuedAt)) (lambda () #f)))

(define/pow
  (subjectOf [claims : (Dict String String)])
  #:returns String
  (thsl-src-control! "example/learn/lesson78-sso.tesl" 113 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson78-sso.tesl" 114 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([subject (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson78-sso.tesl" 115 (list (cons 'subject subject)) (lambda () *subject)))])))))

(define-auther
  (sessionOwner [request : HttpRequest])
  #:capabilities [sessions]
  #:returns [user : User ::: (Authenticated user)]
  (thsl-src-control! "example/learn/lesson78-sso.tesl" 119 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson78-sso.tesl" 120 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson78-sso.tesl" 122 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-2 (tesl_import_JWT_verify token (sessionKey))]) (let ([claims tesl-checked-2]) (let ([subject (subjectOf claims)]) (accept Authenticated #:value (User #:id *subject))))))))])))))

(define-handler
  (me [user : User ::: (Authenticated user)])
  #:returns Profile
  (thsl-src! "example/learn/lesson78-sso.tesl" 129 (list (cons 'user *user)) (lambda () (Profile #:userId (tesl-dot/runtime user 'id 'User)))))

(define AppServer-sse-routes '())
(define-api AppApi
  [me :
    (Auth [user : User ::: (Authenticated user)] #:via sessionOwner)
    :> "me"
    :> (Get JSON Profile)
    ]
)

(define-server AppServer
  #:api AppApi
  [me me]
)
(void (__tjwt_current-session-policy __tjwt_short-session))
(void (__tjwt_current-session-revoked-hook (lambda (subj iat) (revoked subj (__ttime_Time.secondsToPosix iat)))))
(register-listen-address! "AppServer" "127.0.0.1")
(void (current-public-origin "https://app.example.com"))
(register-sso-routes! "AppServer" (list (make-sso-route #:segment "github" #:connection (lambda () (githubConn)) #:on-identity linkUser #:mint-session (lambda (subj) (__tjwt_sso-session-cookie-value (__tenv_requireSecret "SESSION_KEY") subj)) #:session-key-bytes (lambda () (__tcrypto_secret->bytes (__tenv_requireSecret "SESSION_KEY"))) #:public-origin "https://app.example.com" #:after-login "/me")))

(define-database AppDb
  #:backend memory
  #:entities )

(module+ main
  (thsl-src! "example/learn/lesson78-sso.tesl" 167 (list) (lambda () (with-capabilities (sessions dbRead httpClient) (call-with-database AppDb (lambda () (serve AppServer #:port 8080 #:capabilities (list sessions dbRead httpClient) #:sse-routes AppServer-sse-routes)))))))
