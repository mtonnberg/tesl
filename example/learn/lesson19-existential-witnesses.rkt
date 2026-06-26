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
  (only-in tesl/tesl/prelude Int Fact String)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/time nowMillis time [Time.posixToSeconds tesl_import_Time_posixToSeconds])
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/id generatePrefixedId)
)


(provide generateToken IsTokenId Authenticated IsCreatedSession checkSessionCreated SessionServer generateToken-signature checkSessionCreated-signature)

(define Authenticated 'Authenticated)
(define IsCreatedSession 'IsCreatedSession)
(define IsTokenId 'IsTokenId)

(define-newtype TokenId String)

(define-checker
  (checkTokenId [s : String])
  #:returns [s : String ::: (IsTokenId s)]
  (thsl-src! "example/learn/lesson19-existential-witnesses.tesl" 66 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 8) (accept (IsTokenId s) #:value *s) (reject "invalid token id" #:http-code 400)))))

(define-newtype Token String)

(define-capability sessionCapability (implies time random))

(define/pow
  (generateToken)
  #:capabilities [sessionCapability]
  #:returns (Exists [tokenId : String] [tokenId : String ::: (IsTokenId tokenId)])
  (thsl-src! "example/learn/lesson19-existential-witnesses.tesl" 84 (list) (lambda () (let ([tokenId (generatePrefixedId "tok")]) (let/check ([tesl_checked_0 (checkTokenId tokenId)]) (let ([validated tesl_checked_0]) (pack ([tokenId]) validated)))))))

(define/pow
  (shouldWork_OnlyMeansAnyStringWithAProofThatSomethingIsATokenId)
  #:capabilities [sessionCapability]
  #:returns (Exists [tokenId : String] [_entity : String ::: (IsTokenId tokenId)])
  (let ([tokenId (thsl-src! "example/learn/lesson19-existential-witnesses.tesl" 93 (list) (lambda () (generatePrefixedId "tok")))]) (thsl-src! "example/learn/lesson19-existential-witnesses.tesl" 94 (list (cons 'tokenId *tokenId)) (lambda () (pack ([tokenId]) "anyrandomString")))))

(define-record Session
  [id : String]
  [userId : String]
  [createdAt : Integer]
)

(define (tesl-codec-encode-Session _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'id (tesl-encode-prim-string (raw-value (hash-ref _fields 'id)))
        'userId (tesl-encode-prim-string (raw-value (hash-ref _fields 'userId)))
        'createdAt (tesl-encode-prim-int (raw-value (hash-ref _fields 'createdAt)))
  ))
(register-type-codec! 'Session tesl-codec-encode-Session (list ))

(define-auther
  (cookieAuth [request : HttpRequest])
  #:returns (? String _entity ::: (Authenticated _entity))
  (thsl-src! "example/learn/lesson19-existential-witnesses.tesl" 132 (list (cons 'request *request)) (lambda () (let ([tesl_case_1 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (reject "not logged in" #:http-code 401)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (accept (Authenticated userId) #:value *userId))])))))

(define-checker
  (checkSessionCreated [session : Session] [sessionId : String] [user : String ::: (Authenticated user)])
  #:returns [session : Session ::: (IsCreatedSession (Id == sessionId) user)]
  (thsl-src! "example/learn/lesson19-existential-witnesses.tesl" 144 (list (cons 'session *session) (cons 'sessionId *sessionId) (cons 'user *user)) (lambda () (if (equal? (raw-value session.id) *sessionId) (accept (IsCreatedSession (Id == sessionId) user) #:value *session) (reject "session id does not match the witness" #:http-code 500)))))

(define-handler
  (createSession [user : String ::: (Authenticated user)])
  #:capabilities [sessionCapability]
  #:returns (Exists [sessionId : String] [session : Session ::: (IsCreatedSession (Id == sessionId) user)])
  (thsl-src! "example/learn/lesson19-existential-witnesses.tesl" 153 (list (cons 'user *user)) (lambda () (let ([sessionId (generatePrefixedId "session")]) (let ([session (Session #:id *sessionId #:userId *user #:createdAt (raw-value (tesl_import_Time_posixToSeconds (raw-value (nowMillis)))))]) (let/check ([tesl_checked_2 (checkSessionCreated session sessionId user)]) (let ([verifiedSession tesl_checked_2]) (pack ([sessionId]) verifiedSession))))))))

(define SessionServer-sse-routes '())
(define-api SessionApi
  [createSession :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "sessions"
    :> (Post JSON (Exists [sessionId : String] [session : Session ::: (IsCreatedSession (Id == sessionId) user)]))
    ]
)

(define-server SessionServer
  #:api SessionApi
  [createSession createSession]
)
