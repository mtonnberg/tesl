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
  (only-in tesl/tesl/prelude Bool String List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.member tesl_import_List_member] [List.head tesl_import_List_head] [List.last tesl_import_List_last] [List.length tesl_import_List_length] [List.map tesl_import_List_map])
  (only-in tesl/tesl/string [String.startsWith tesl_import_String_startsWith] [String.toLower tesl_import_String_toLower] [String.length tesl_import_String_length] [String.slice tesl_import_String_slice] [String.split tesl_import_String_split] [String.contains tesl_import_String_contains] [String.join tesl_import_String_join] [String.isEmpty tesl_import_String_isEmpty] [String.fromInt tesl_import_String_fromInt])
  (only-in tesl/tesl/dict Dict [Dict.singleton tesl_import_Dict_singleton] [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/time time)
  (only-in tesl/tesl/crypto Secret [Crypto.fingerprint tesl_import_Crypto_fingerprint] [Crypto.signWith tesl_import_Crypto_signWith] [Crypto.checkSignature tesl_import_Crypto_checkSignature] [Crypto.signatureHex tesl_import_Crypto_signatureHex] [Crypto.signatureFromHex tesl_import_Crypto_signatureFromHex])
  (only-in tesl/tesl/jwt jwt [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/http HttpRequest cookieCap [Http.setSessionCookie tesl_import_Http_setSessionCookie] [Http.sessionToken tesl_import_Http_sessionToken])
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/api-test statusOk responseCookie)
)


(provide MachineServer)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "tests/machine-login-tests.tesl" '(1 284 298 324 369 516))
(define HumanSession 'HumanSession)
(define MachineCaller 'MachineCaller)
(define MayUse 'MayUse)

(define-capability sessions (implies jwt time cookieCap))

(define/pow
  (makeSecret [s : String])
  #:returns Secret
  (thsl-src! "tests/machine-login-tests.tesl" 108 (list (cons 's *s)) (lambda () (raw-value (Secret *s)))))

(define/pow
  (sessionKey)
  #:returns Secret
  (thsl-src! "tests/machine-login-tests.tesl" 111 (list) (lambda () (raw-value (makeSecret "machine-login-tests-session-key")))))

(define/pow
  (machineKey)
  #:returns Secret
  (thsl-src! "tests/machine-login-tests.tesl" 116 (list) (lambda () (raw-value (makeSecret "machine-login-tests-token-key")))))

(define/pow
  (attackerKey)
  #:returns Secret
  (thsl-src! "tests/machine-login-tests.tesl" 120 (list) (lambda () (raw-value (makeSecret "machine-login-tests-attacker-key")))))

(define-adt Scope
  [ReadWidgets]
  [WriteWidgets]
)

(define-record Caller
  [install : String]
  [orgId : String]
  [granted : (List Scope)]
)

(define-checker
  (mayReadWidgets [c : Caller])
  #:returns [c : Caller ::: (MayUse c ReadWidgets)]
  (thsl-src! "tests/machine-login-tests.tesl" 146 (list (cons 'c *c)) (lambda () (if (raw-value (tesl_import_List_member ReadWidgets (tesl-dot/runtime c 'granted 'Caller))) (accept (MayUse c ReadWidgets) #:value *c) (reject "missing scope widgets:read" #:http-code 403)))))

(define-checker
  (mayWriteWidgets [c : Caller])
  #:returns [c : Caller ::: (MayUse c WriteWidgets)]
  (thsl-src! "tests/machine-login-tests.tesl" 152 (list (cons 'c *c)) (lambda () (if (raw-value (tesl_import_List_member WriteWidgets (tesl-dot/runtime c 'granted 'Caller))) (accept (MayUse c WriteWidgets) #:value *c) (reject "missing scope widgets:write" #:http-code 403)))))

(define-entity Installation
  #:source (make-hash)
  #:table installations
  #:primary-key id
  [Id id : String]
  [OrgId orgId : String]
  [TokenFingerprint tokenFingerprint : String]
  [Scopes scopes : String]
  [Revoked revoked : Boolean]
)

(define-entity Widget
  #:source (make-hash)
  #:table widgets
  #:primary-key id
  [Id id : String]
  [OrgId orgId : String]
  [Name name : String]
)

(define-database MarketplaceDb
  #:backend memory
  #:schema marketplace
  #:entities Installation Widget)

(define/pow
  (tokenAlphaWrite)
  #:returns String
  (thsl-src! "tests/machine-login-tests.tesl" 191 (list) (lambda () "insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j")))

(define/pow
  (tokenAlphaReadOnly)
  #:returns String
  (thsl-src! "tests/machine-login-tests.tesl" 194 (list) (lambda () "instd-7Hj2k9LmN4pQ6rS8tU0vW2xY5zA1bC3d")))

(define/pow
  (tokenBetaWrite)
  #:returns String
  (thsl-src! "tests/machine-login-tests.tesl" 197 (list) (lambda () "instb-2Bd5f8HkM1nP4qR7sT9uV3wX6yZ0aC8e")))

(define/pow
  (tokenRevoked)
  #:returns String
  (thsl-src! "tests/machine-login-tests.tesl" 200 (list) (lambda () "instc-9Zx6c3VbN8mK5jH2gF7dS4aQ1wE0rT6y")))

(define/pow
  (seedFixtures)
  #:capabilities [dbWrite]
  #:returns Boolean
  (let ([installs (thsl-src! "tests/machine-login-tests.tesl" 210 (list) (lambda () (list (tesl-hash 'id "install-a" 'orgId "org-alpha" 'tokenFingerprint (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenAlphaWrite)))) 'scopes "read,write" 'revoked #f) (tesl-hash 'id "install-b" 'orgId "org-beta" 'tokenFingerprint (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenBetaWrite)))) 'scopes "read,write" 'revoked #f) (tesl-hash 'id "install-c" 'orgId "org-alpha" 'tokenFingerprint (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenRevoked)))) 'scopes "read,write" 'revoked #t) (tesl-hash 'id "install-d" 'orgId "org-alpha" 'tokenFingerprint (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenAlphaReadOnly)))) 'scopes "read" 'revoked #f))))]) (let ([widgets (thsl-src! "tests/machine-login-tests.tesl" 240 (list (cons 'installs *installs)) (lambda () (list (tesl-hash 'id "widget-1" 'orgId "org-alpha" 'name "alpha-one") (tesl-hash 'id "widget-2" 'orgId "org-alpha" 'name "alpha-two") (tesl-hash 'id "widget-3" 'orgId "org-beta" 'name "beta-one"))))]) (let ([_ (thsl-src! "tests/machine-login-tests.tesl" 245 (list (cons 'widgets *widgets) (cons 'installs *installs)) (lambda () (insert-many! (from Installation) installs)))]) (let ([_ (thsl-src! "tests/machine-login-tests.tesl" 246 (list (cons '_ *_) (cons 'widgets *widgets) (cons 'installs *installs)) (lambda () (insert-many! (from Widget) widgets)))]) (thsl-src! "tests/machine-login-tests.tesl" 247 (list (cons '_ *_) (cons '_ *_) (cons 'widgets *widgets) (cons 'installs *installs)) (lambda () #t)))))))

(define/pow
  (bearerCredential [request : HttpRequest])
  #:returns (Maybe String)
  (thsl-src-control! "tests/machine-login-tests.tesl" 259 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "authorization" (raw-value request.headers)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 260 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([raw (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 262 (list (cons 'raw raw)) (lambda () (if (tesl_import_String_startsWith (raw-value (tesl_import_String_toLower *raw)) "bearer ") (let ([token (raw-value (tesl_import_String_slice *raw 7 (raw-value (tesl_import_String_length *raw))))]) (if (tesl_import_String_isEmpty (raw-value token)) (raw-value Nothing) (raw-value (raw-value (Something (raw-value token)))))) (raw-value Nothing)))))])))))

(define/pow
  (scopesOf [stored : String])
  #:returns (List Scope)
  (thsl-src! "tests/machine-login-tests.tesl" 272 (list (cons 'stored *stored)) (lambda () (if (tesl_import_String_contains *stored "write") (raw-value (list ReadWidgets WriteWidgets)) (raw-value (list ReadWidgets))))))

(define/pow
  (callerOf [inst : Installation])
  #:returns Caller
  (thsl-src! "tests/machine-login-tests.tesl" 278 (list (cons 'inst *inst)) (lambda () (Caller #:install (tesl-dot/runtime inst 'id 'Installation) #:orgId (tesl-dot/runtime inst 'orgId 'Installation) #:granted (scopesOf (tesl-dot/runtime inst 'scopes 'Installation))))))

(define/pow
  (installationByStored [stored : String])
  #:capabilities [dbRead]
  #:returns String
  (thsl-src-control! "tests/machine-login-tests.tesl" 284 (list (cons 'stored *stored)) (lambda () (let ([tesl-case-1 (raw-value (let ([tesl_match (select-one (from Installation) (where (==. (entity-field-ref Installation 'tokenFingerprint) stored)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 285 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 286 (list (cons 'inst inst)) (lambda () (raw-value (tesl-dot/runtime inst 'id 'Installation)))))])))))

(define/pow
  (installationForVerifiedTag [claimedId : String] [tag : String])
  #:capabilities [dbRead]
  #:returns String
  (thsl-src! "tests/machine-login-tests.tesl" 297 (list (cons 'claimedId *claimedId) (cons 'tag *tag)) (lambda () (let/check ([tesl-checked-2 (tesl_import_Crypto_checkSignature (machineKey) (raw-value (tesl_import_Crypto_signatureFromHex *tag)) claimedId)]) (let ([verifiedId tesl-checked-2]) (let ([tesl-case-3 (raw-value (let ([tesl_match (select-one (from Installation) (where (==. (entity-field-ref Installation 'id) verifiedId)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 299 (list) (lambda () (raw-value "no-row")))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 300 (list (cons 'inst inst)) (lambda () (raw-value (tesl-dot/runtime inst 'orgId 'Installation)))))])))))))

(define/pow
  (revokeInstallation [installId : String])
  #:capabilities [dbWrite]
  #:returns Boolean
  (let ([_ (thsl-src! "tests/machine-login-tests.tesl" 306 (list (cons 'installId *installId)) (lambda () (void (update-many! (from Installation) (tesl-hash (entity-field-ref Installation 'revoked) #t) (where (==. (entity-field-ref Installation 'id) installId))))))]) (thsl-src! "tests/machine-login-tests.tesl" 309 (list (cons '_ *_) (cons 'installId *installId)) (lambda () #t))))

(define-auther
  (machineAuth [request : HttpRequest])
  #:capabilities [dbRead]
  #:returns [c : Caller ::: (MachineCaller c)]
  (thsl-src-control! "tests/machine-login-tests.tesl" 320 (list (cons 'request *request)) (lambda () (let ([tesl-case-4 (raw-value (bearerCredential request))]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 321 (list) (lambda () (reject "no bearer credential" #:http-code 401)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 323 (list (cons 'token token)) (lambda () (let ([presented (raw-value (tesl_import_Crypto_fingerprint (raw-value token)))]) (let ([tesl-case-5 (raw-value (let ([tesl_match (select-one (from Installation) (where (==. (entity-field-ref Installation 'tokenFingerprint) presented)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 325 (list) (lambda () (reject "unknown credential" #:http-code 401)))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 327 (list (cons 'inst inst)) (lambda () (if (tesl-dot/runtime inst 'revoked 'Installation) (reject "unknown credential" #:http-code 401) (let ([c (callerOf inst)]) (accept (MachineCaller c) #:value *c))))))]))))))])))))

(define/pow
  (hmacTokenFor [key : Secret] [installId : String])
  #:returns String
  (thsl-src! "tests/machine-login-tests.tesl" 341 (list (cons 'key *key) (cons 'installId *installId)) (lambda () (string-append (string-append *installId ".") (raw-value (tesl_import_Crypto_signatureHex (raw-value (tesl_import_Crypto_signWith *key *installId))))))))

(define/pow
  (tokenInstallPart [token : String])
  #:returns (Maybe String)
  (thsl-src! "tests/machine-login-tests.tesl" 344 (list (cons 'token *token)) (lambda () (if (tesl-equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_String_split *token ".")))) 2) (raw-value (raw-value (tesl_import_List_head (raw-value (tesl_import_String_split *token "."))))) (raw-value Nothing)))))

(define/pow
  (tokenTagPart [token : String])
  #:returns (Maybe String)
  (thsl-src! "tests/machine-login-tests.tesl" 350 (list (cons 'token *token)) (lambda () (if (tesl-equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_String_split *token ".")))) 2) (raw-value (raw-value (tesl_import_List_last (raw-value (tesl_import_String_split *token "."))))) (raw-value Nothing)))))

(define-auther
  (hmacMachineAuth [request : HttpRequest])
  #:capabilities [dbRead]
  #:returns [c : Caller ::: (MachineCaller c)]
  (thsl-src-control! "tests/machine-login-tests.tesl" 357 (list (cons 'request *request)) (lambda () (let ([tesl-case-6 (raw-value (bearerCredential request))]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 358 (list) (lambda () (reject "no bearer credential" #:http-code 401)))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 360 (list (cons 'token token)) (lambda () (let ([tesl-case-7 (raw-value (tokenInstallPart token))]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 361 (list) (lambda () (reject "malformed credential" #:http-code 401)))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something)) (let ([claimedId (hash-ref (adt-value-fields *tesl-case-7) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 363 (list (cons 'claimedId claimedId)) (lambda () (let ([tesl-case-8 (raw-value (tokenTagPart token))]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 364 (list) (lambda () (reject "malformed credential" #:http-code 401)))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something)) (let ([tag (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 368 (list (cons 'tag tag)) (lambda () (let/check ([tesl-checked-9 (tesl_import_Crypto_checkSignature (machineKey) (raw-value (tesl_import_Crypto_signatureFromHex (raw-value tag))) claimedId)]) (let ([verifiedId tesl-checked-9]) (let ([tesl-case-10 (raw-value (let ([tesl_match (select-one (from Installation) (where (==. (entity-field-ref Installation 'id) verifiedId)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 370 (list) (lambda () (reject "unknown credential" #:http-code 401)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Something)) (let ([inst (hash-ref (adt-value-fields *tesl-case-10) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 372 (list (cons 'inst inst)) (lambda () (if (tesl-dot/runtime inst 'revoked 'Installation) (reject "unknown credential" #:http-code 401) (let ([c (callerOf inst)]) (accept (MachineCaller c) #:value *c))))))])))))))])))))])))))])))))

(define/pow
  (subjectOf [claims : (Dict String String)])
  #:returns String
  (thsl-src-control! "tests/machine-login-tests.tesl" 387 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-11 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 388 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Something)) (let ([subject (hash-ref (adt-value-fields *tesl-case-11) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 389 (list (cons 'subject subject)) (lambda () *subject)))])))))

(define-auther
  (sessionOwner [request : HttpRequest])
  #:capabilities [sessions]
  #:returns [user : String ::: (HumanSession user)]
  (thsl-src-control! "tests/machine-login-tests.tesl" 393 (list (cons 'request *request)) (lambda () (let ([tesl-case-12 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing)) (thsl-src! "tests/machine-login-tests.tesl" 394 (list) (lambda () (reject "no session" #:http-code 401)))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (thsl-src! "tests/machine-login-tests.tesl" 396 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-13 (tesl_import_JWT_verify token (sessionKey))]) (let ([claims tesl-checked-13]) (accept HumanSession #:value (subjectOf claims)))))))])))))

(define-record Who
  [install : String]
  [orgId : String]
)

(define (tesl-codec-encode-Who _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'install (tesl-encode-prim-string (raw-value (hash-ref _fields 'install)))
        'orgId (tesl-encode-prim-string (raw-value (hash-ref _fields 'orgId)))
  ))
(register-type-codec! 'Who tesl-codec-encode-Who (list ))

(define-record HmacWho
  [install : String]
  [orgId : String]
)

(define (tesl-codec-encode-HmacWho _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'install (tesl-encode-prim-string (raw-value (hash-ref _fields 'install)))
        'orgId (tesl-encode-prim-string (raw-value (hash-ref _fields 'orgId)))
  ))
(register-type-codec! 'HmacWho tesl-codec-encode-HmacWho (list ))

(define-record WidgetList
  [orgId : String]
  [names : String]
  [count : String]
)

(define (tesl-codec-encode-WidgetList _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'orgId (tesl-encode-prim-string (raw-value (hash-ref _fields 'orgId)))
        'names (tesl-encode-prim-string (raw-value (hash-ref _fields 'names)))
        'count (tesl-encode-prim-string (raw-value (hash-ref _fields 'count)))
  ))
(register-type-codec! 'WidgetList tesl-codec-encode-WidgetList (list ))

(define-record NewWidget
  [id : String]
  [name : String]
)

(define (tesl-codec-encode-NewWidget _v)
  (error "toJson is forbidden for type NewWidget: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewWidget-0 _j)
  (define _f_id (tesl-decode-prim-field _j "id" tesl-decode-prim-string))
  (define _f_name (tesl-decode-prim-field _j "name" tesl-decode-prim-string))
  (record-value 'NewWidget (tesl-hash 'id _f_id 'name _f_name)))
(register-type-codec! 'NewWidget tesl-codec-encode-NewWidget (list tesl-codec-decode-NewWidget-0))

(define-record Created
  [id : String]
  [orgId : String]
)

(define (tesl-codec-encode-Created _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'id (tesl-encode-prim-string (raw-value (hash-ref _fields 'id)))
        'orgId (tesl-encode-prim-string (raw-value (hash-ref _fields 'orgId)))
  ))
(register-type-codec! 'Created tesl-codec-encode-Created (list ))

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

(define-record HumanWho
  [user : String]
)

(define (tesl-codec-encode-HumanWho _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'user (tesl-encode-prim-string (raw-value (hash-ref _fields 'user)))
  ))
(register-type-codec! 'HumanWho tesl-codec-encode-HumanWho (list ))

(define/pow
  (listWidgetsCore [c : Caller ::: (MayUse c ReadWidgets)])
  #:capabilities [dbRead]
  #:returns WidgetList
  (let ([rows (thsl-src! "" 1 (list (cons 'c *c)) (lambda () (select-many (from Widget) (where (==. (entity-field-ref Widget 'orgId) (tesl-dot/runtime c 'orgId 'Caller))) (order-by (entity-field-ref Widget 'name) 'asc))) 'rows)]) (let ([names (thsl-src! "tests/machine-login-tests.tesl" 519 (list (cons 'rows *rows) (cons 'c *c)) (lambda () (tesl_import_List_map widgetName (raw-value rows))))]) (thsl-src! "tests/machine-login-tests.tesl" 520 (list (cons 'names *names) (cons 'rows *rows) (cons 'c *c)) (lambda () (WidgetList #:orgId (tesl-dot/runtime c 'orgId 'Caller) #:names (tesl_import_String_join (raw-value names) ",") #:count (tesl_import_String_fromInt (raw-value (tesl_import_List_length (raw-value rows))))))))))

(define/pow
  (widgetName [w : Widget])
  #:returns String
  (thsl-src! "tests/machine-login-tests.tesl" 523 (list (cons 'w *w)) (lambda () (tesl-dot/runtime w 'name 'Widget))))

(define/pow
  (createWidgetCore [c : Caller ::: (MayUse c WriteWidgets)] [id : String] [name : String])
  #:capabilities [dbWrite]
  #:returns Created
  (let ([_ (thsl-src! "tests/machine-login-tests.tesl" 527 (list (cons 'c *c) (cons 'id *id) (cons 'name *name)) (lambda () (insert-one! Widget (tesl-hash 'id id 'orgId (tesl-dot/runtime c 'orgId 'Caller) 'name name))))]) (thsl-src! "tests/machine-login-tests.tesl" 528 (list (cons '_ *_) (cons 'c *c) (cons 'id *id) (cons 'name *name)) (lambda () (Created #:id *id #:orgId (tesl-dot/runtime c 'orgId 'Caller))))))

(define-handler
  (machineWhoami [c : Caller ::: (MachineCaller c)])
  #:returns Who
  (thsl-src! "tests/machine-login-tests.tesl" 533 (list (cons 'c *c)) (lambda () (Who #:install (tesl-dot/runtime c 'install 'Caller) #:orgId (tesl-dot/runtime c 'orgId 'Caller)))))

(define-handler
  (hmacWhoami [c : Caller ::: (MachineCaller c)])
  #:returns HmacWho
  (thsl-src! "tests/machine-login-tests.tesl" 538 (list (cons 'c *c)) (lambda () (HmacWho #:install (tesl-dot/runtime c 'install 'Caller) #:orgId (tesl-dot/runtime c 'orgId 'Caller)))))

(define-handler
  (listWidgets [c : Caller ::: (MachineCaller c)])
  #:capabilities [dbRead]
  #:returns WidgetList
  (thsl-src! "tests/machine-login-tests.tesl" 542 (list (cons 'c *c)) (lambda () (let/check ([tesl-checked-14 (mayReadWidgets c)]) (let ([reader tesl-checked-14]) (listWidgetsCore reader))))))

(define-handler
  (createWidget [c : Caller ::: (MachineCaller c)] [body : NewWidget])
  #:capabilities [dbWrite]
  #:returns Created
  (thsl-src! "tests/machine-login-tests.tesl" 547 (list (cons 'c *c) (cons 'body *body)) (lambda () (let/check ([tesl-checked-15 (mayWriteWidgets c)]) (let ([writer tesl-checked-15]) (createWidgetCore writer (tesl-dot/runtime body 'id 'NewWidget) (tesl-dot/runtime body 'name 'NewWidget)))))))

(define-handler
  (login [body : LoginRequest])
  #:capabilities [sessions]
  #:returns LoginOk
  (let ([token (thsl-src! "tests/machine-login-tests.tesl" 552 (list (cons 'body *body)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" (tesl-dot/runtime body 'user 'LoginRequest))) (raw-value (sessionKey))))))]) (let ([_ (thsl-src! "tests/machine-login-tests.tesl" 553 (list (cons 'token *token) (cons 'body *body)) (lambda () (raw-value (tesl_import_Http_setSessionCookie (raw-value token)))))]) (thsl-src! "tests/machine-login-tests.tesl" 554 (list (cons '_ *_) (cons 'token *token) (cons 'body *body)) (lambda () (LoginOk #:success #t))))))

(define-handler
  (humanWhoami [user : String ::: (HumanSession user)])
  #:returns HumanWho
  (thsl-src! "tests/machine-login-tests.tesl" 557 (list (cons 'user *user)) (lambda () (HumanWho #:user *user))))

(define MachineServer-sse-routes '())
(define-api MachineApi
  [machineWhoami :
    (Auth [c : Caller ::: (MachineCaller c)] #:via machineAuth)
    :> "machine"
    :> "whoami"
    :> (Get JSON Who)
    ]
  [hmacWhoami :
    (Auth [c : Caller ::: (MachineCaller c)] #:via hmacMachineAuth)
    :> "hmac"
    :> "whoami"
    :> (Get JSON HmacWho)
    ]
  [listWidgets :
    (Auth [c : Caller ::: (MachineCaller c)] #:via machineAuth)
    :> "machine"
    :> "widgets"
    :> (Get JSON WidgetList)
    ]
  [createWidget :
    (Auth [c : Caller ::: (MachineCaller c)] #:via machineAuth)
    :> "machine"
    :> "widgets"
    :> (ReqBody JSON [body : NewWidget])
    :> (Post JSON Created)
    ]
  [login :
    "login"
    :> (ReqBody JSON [body : LoginRequest])
    :> (Post JSON LoginOk)
    ]
  [humanWhoami :
    (Auth [user : String ::: (HumanSession user)] #:via sessionOwner)
    :> "session"
    :> "whoami"
    :> (Get JSON HumanWho)
    ]
)

(define-server MachineServer
  #:api MachineApi
  [machineWhoami machineWhoami]
  [hmacWhoami hmacWhoami]
  [listWidgets listWidgets]
  [createWidget createWidget]
  [login login]
  [humanWhoami humanWhoami]
)

(module+ test
  (require rackunit)
  (test-case "a valid machine token authenticates and names its own installation"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 676 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 677 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 678 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'install)))) "install-a")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 679 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'orgId)))) "org-alpha")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the Bearer scheme is matched case-insensitively"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define lower (thsl-src! "tests/machine-login-tests.tesl" 689 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 690 (list (cons 'lower lower)) (lambda () (statusOk (raw-value (api-test-field-access-ref lower 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 691 (list (cons 'lower lower)) (lambda () (api-test-field-access-ref (api-test-field-access-ref lower 'body) 'install)))) "install-a")
              (define shouty (thsl-src! "tests/machine-login-tests.tesl" 692 (list (cons 'lower lower)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "BEARER insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 693 (list (cons 'shouty shouty) (cons 'lower lower)) (lambda () (statusOk (raw-value (api-test-field-access-ref shouty 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 694 (list (cons 'shouty shouty) (cons 'lower lower)) (lambda () (api-test-field-access-ref (api-test-field-access-ref shouty 'body) 'install)))) "install-a")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a second installation authenticates as ITSELF, not as the first"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define a (thsl-src! "tests/machine-login-tests.tesl" 704 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 705 (list (cons 'a a)) (lambda () (api-test-field-access-ref (api-test-field-access-ref a 'body) 'install)))) "install-a")
              (define b (thsl-src! "tests/machine-login-tests.tesl" 706 (list (cons 'a a)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer instb-2Bd5f8HkM1nP4qR7sT9uV3wX6yZ0aC8e") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 707 (list (cons 'b b) (cons 'a a)) (lambda () (api-test-field-access-ref (api-test-field-access-ref b 'body) 'install)))) "install-b")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 708 (list (cons 'b b) (cons 'a a)) (lambda () (api-test-field-access-ref (api-test-field-access-ref b 'body) 'orgId)))) "org-beta")
              (define a2 (thsl-src! "tests/machine-login-tests.tesl" 710 (list (cons 'b b) (cons 'a a)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 711 (list (cons 'a2 a2) (cons 'b b) (cons 'a a)) (lambda () (api-test-field-access-ref (api-test-field-access-ref a2 'body) 'install)))) "install-a")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "no Authorization header is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 723 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 724 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an empty Authorization header is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 732 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 733 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a bare token with no scheme is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 743 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 744 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "another auth scheme carrying a valid token is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define basic (thsl-src! "tests/machine-login-tests.tesl" 752 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Basic insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 753 (list (cons 'basic basic)) (lambda () (api-test-field-access-ref basic 'status)))) 401)
              (define token (thsl-src! "tests/machine-login-tests.tesl" 754 (list (cons 'basic basic)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Token insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 755 (list (cons 'token token) (cons 'basic basic)) (lambda () (api-test-field-access-ref token 'status)))) 401)
              (define glued (thsl-src! "tests/machine-login-tests.tesl" 757 (list (cons 'token token) (cons 'basic basic)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearerinsta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 758 (list (cons 'glued glued) (cons 'token token) (cons 'basic basic)) (lambda () (api-test-field-access-ref glued 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "Bearer with an empty token is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 766 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer ") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 767 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
              (define justScheme (thsl-src! "tests/machine-login-tests.tesl" 768 (list (cons 'r r)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 769 (list (cons 'justScheme justScheme) (cons 'r r)) (lambda () (api-test-field-access-ref justScheme 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an unknown but well-formed token is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 777 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer instx-0000000000000000000000000000000000") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 778 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a token that differs in one character is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 788 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5k") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 789 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a strict prefix of a valid token is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 797 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3y") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 798 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
              (define oneChar (thsl-src! "tests/machine-login-tests.tesl" 799 (list (cons 'r r)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer i") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 800 (list (cons 'oneChar oneChar) (cons 'r r)) (lambda () (api-test-field-access-ref oneChar 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a valid token with trailing junk is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define space (thsl-src! "tests/machine-login-tests.tesl" 810 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j ") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 811 (list (cons 'space space)) (lambda () (api-test-field-access-ref space 'status)))) 401)
              (define extra (thsl-src! "tests/machine-login-tests.tesl" 812 (list (cons 'space space)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j extra") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 813 (list (cons 'extra extra) (cons 'space space)) (lambda () (api-test-field-access-ref extra 'status)))) 401)
              (define doubleSpace (thsl-src! "tests/machine-login-tests.tesl" 814 (list (cons 'extra extra) (cons 'space space)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer  insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 815 (list (cons 'doubleSpace doubleSpace) (cons 'extra extra) (cons 'space space)) (lambda () (api-test-field-access-ref doubleSpace 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a revoked installation is refused even with the right token"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 826 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer instc-9Zx6c3VbN8mK5jH2gF7dS4aQ1wE0rT6y") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 827 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "revoking mid-flight takes effect on the next request"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define before (thsl-src! "tests/machine-login-tests.tesl" 836 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 837 (list (cons 'before before)) (lambda () (statusOk (raw-value (api-test-field-access-ref before 'status)))))))
              (define tesl-ignored-16 (thsl-src! "tests/machine-login-tests.tesl" 839 (list (cons 'before before)) (lambda () (revokeInstallation "install-a"))))
              (define after (thsl-src! "tests/machine-login-tests.tesl" 843 (list (cons 'before before)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 844 (list (cons 'after after) (cons 'before before)) (lambda () (api-test-field-access-ref after 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a refused credential leaves no trace on the next good request"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define bad (thsl-src! "tests/machine-login-tests.tesl" 852 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer instx-0000000000000000000000000000000000") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 853 (list (cons 'bad bad)) (lambda () (api-test-field-access-ref bad 'status)))) 401)
              (define good (thsl-src! "tests/machine-login-tests.tesl" 854 (list (cons 'bad bad)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 855 (list (cons 'good good) (cons 'bad bad)) (lambda () (statusOk (raw-value (api-test-field-access-ref good 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 856 (list (cons 'good good) (cons 'bad bad)) (lambda () (api-test-field-access-ref (api-test-field-access-ref good 'body) 'install)))) "install-a")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "each installation sees only its own org's rows"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define alpha (thsl-src! "tests/machine-login-tests.tesl" 868 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 869 (list (cons 'alpha alpha)) (lambda () (statusOk (raw-value (api-test-field-access-ref alpha 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 870 (list (cons 'alpha alpha)) (lambda () (api-test-field-access-ref (api-test-field-access-ref alpha 'body) 'orgId)))) "org-alpha")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 871 (list (cons 'alpha alpha)) (lambda () (api-test-field-access-ref (api-test-field-access-ref alpha 'body) 'count)))) "2")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 872 (list (cons 'alpha alpha)) (lambda () (api-test-field-access-ref (api-test-field-access-ref alpha 'body) 'names)))) "alpha-one,alpha-two")
              (define beta (thsl-src! "tests/machine-login-tests.tesl" 874 (list (cons 'alpha alpha)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer instb-2Bd5f8HkM1nP4qR7sT9uV3wX6yZ0aC8e") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 875 (list (cons 'beta beta) (cons 'alpha alpha)) (lambda () (statusOk (raw-value (api-test-field-access-ref beta 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 876 (list (cons 'beta beta) (cons 'alpha alpha)) (lambda () (api-test-field-access-ref (api-test-field-access-ref beta 'body) 'orgId)))) "org-beta")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 877 (list (cons 'beta beta) (cons 'alpha alpha)) (lambda () (api-test-field-access-ref (api-test-field-access-ref beta 'body) 'count)))) "1")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 878 (list (cons 'beta beta) (cons 'alpha alpha)) (lambda () (api-test-field-access-ref (api-test-field-access-ref beta 'body) 'names)))) "beta-one")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a query parameter cannot re-point a machine caller at another org"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 888 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "widgets") #:query "orgId=org-beta" #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 889 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 890 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'orgId)))) "org-alpha")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 891 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'count)))) "2")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a write lands in the caller's own org and is invisible to the other"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define created (thsl-src! "tests/machine-login-tests.tesl" 899 (list) (lambda () (dispatch-api-test-request MachineServer 'post (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:body (tesl-hash (string->symbol "id") "widget-new" (string->symbol "name") "alpha-three") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 900 (list (cons 'created created)) (lambda () (statusOk (raw-value (api-test-field-access-ref created 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 901 (list (cons 'created created)) (lambda () (api-test-field-access-ref (api-test-field-access-ref created 'body) 'orgId)))) "org-alpha")
              (define alpha (thsl-src! "tests/machine-login-tests.tesl" 904 (list (cons 'created created)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 905 (list (cons 'alpha alpha) (cons 'created created)) (lambda () (api-test-field-access-ref (api-test-field-access-ref alpha 'body) 'count)))) "3")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 906 (list (cons 'alpha alpha) (cons 'created created)) (lambda () (tesl_import_String_contains (raw-value (api-test-field-access-ref (api-test-field-access-ref alpha 'body) 'names)) "alpha-three")))) #t)
              (define beta (thsl-src! "tests/machine-login-tests.tesl" 909 (list (cons 'alpha alpha) (cons 'created created)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer instb-2Bd5f8HkM1nP4qR7sT9uV3wX6yZ0aC8e") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 910 (list (cons 'beta beta) (cons 'alpha alpha) (cons 'created created)) (lambda () (api-test-field-access-ref (api-test-field-access-ref beta 'body) 'count)))) "1")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 911 (list (cons 'beta beta) (cons 'alpha alpha) (cons 'created created)) (lambda () (tesl_import_String_contains (raw-value (api-test-field-access-ref (api-test-field-access-ref beta 'body) 'names)) "alpha-three")))) #f)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a read-only installation may read"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 923 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer instd-7Hj2k9LmN4pQ6rS8tU0vW2xY5zA1bC3d") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 924 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 925 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'orgId)))) "org-alpha")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 926 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'count)))) "2")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a read-only installation is 403 on a write, not 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 936 (list) (lambda () (dispatch-api-test-request MachineServer 'post (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer instd-7Hj2k9LmN4pQ6rS8tU0vW2xY5zA1bC3d") #:body (tesl-hash (string->symbol "id") "widget-nope" (string->symbol "name") "should-not-exist") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 937 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 403)
              (define after (thsl-src! "tests/machine-login-tests.tesl" 941 (list (cons 'r r)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer instd-7Hj2k9LmN4pQ6rS8tU0vW2xY5zA1bC3d") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 942 (list (cons 'after after) (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref after 'body) 'count)))) "2")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 943 (list (cons 'after after) (cons 'r r)) (lambda () (tesl_import_String_contains (raw-value (api-test-field-access-ref (api-test-field-access-ref after 'body) 'names)) "should-not-exist")))) #f)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a read+write installation in the SAME org may write"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 953 (list) (lambda () (dispatch-api-test-request MachineServer 'post (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:body (tesl-hash (string->symbol "id") "widget-ok" (string->symbol "name") "alpha-four") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 954 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 955 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'orgId)))) "org-alpha")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a revoked credential is refused before any scope is consulted"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 965 (list) (lambda () (dispatch-api-test-request MachineServer 'post (list "machine" "widgets") #:headers (tesl-hash (string->symbol "authorization") "Bearer instc-9Zx6c3VbN8mK5jH2gF7dS4aQ1wE0rT6y") #:body (tesl-hash (string->symbol "id") "widget-revoked" (string->symbol "name") "no") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 966 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an HMAC-bound token authenticates the id it was signed for"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define token (thsl-src! "tests/machine-login-tests.tesl" 978 (list) (lambda () (hmacTokenFor (machineKey) "install-a"))))
              (define r (thsl-src! "tests/machine-login-tests.tesl" 979 (list (cons 'token token)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") (string-append "Bearer " (raw-value token))) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 980 (list (cons 'r r) (cons 'token token)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 981 (list (cons 'r r) (cons 'token token)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'install)))) "install-a")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 982 (list (cons 'r r) (cons 'token token)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'orgId)))) "org-alpha")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an HMAC-bound token for the other installation authenticates as THAT one"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define token (thsl-src! "tests/machine-login-tests.tesl" 990 (list) (lambda () (hmacTokenFor (machineKey) "install-b"))))
              (define r (thsl-src! "tests/machine-login-tests.tesl" 991 (list (cons 'token token)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") (string-append "Bearer " (raw-value token))) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 992 (list (cons 'r r) (cons 'token token)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 993 (list (cons 'r r) (cons 'token token)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'install)))) "install-b")
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 994 (list (cons 'r r) (cons 'token token)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'orgId)))) "org-beta")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a tag minted for one installation cannot be presented with another id"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define mine (thsl-src! "tests/machine-login-tests.tesl" 1007 (list) (lambda () (hmacTokenFor (machineKey) "install-b"))))
              (let ([*tesl-case-17 (raw-value (tokenTagPart (raw-value mine)))]) (cond
                [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1009 (list (cons 'mine mine)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Something))
                  (let ([myTag (hash-ref (adt-value-fields *tesl-case-17) 'value)])
                    (define forged (thsl-src! "tests/machine-login-tests.tesl" 1011 (list (cons 'mine mine)) (lambda () (string-append (api-test-string-fragment "install-a.") (api-test-string-fragment myTag)))))
                    (define r (thsl-src! "tests/machine-login-tests.tesl" 1012 (list (cons 'forged forged) (cons 'mine mine)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") (string-append "Bearer " (raw-value forged))) #:capabilities (list dbRead dbWrite)))))
                    (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1013 (list (cons 'r r) (cons 'forged forged) (cons 'mine mine)) (lambda () (api-test-field-access-ref r 'status)))) 401)
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
  (test-case "a tag signed with another key is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define forged (thsl-src! "tests/machine-login-tests.tesl" 1021 (list) (lambda () (hmacTokenFor (attackerKey) "install-a"))))
              (define r (thsl-src! "tests/machine-login-tests.tesl" 1022 (list (cons 'forged forged)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") (string-append "Bearer " (raw-value forged))) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1023 (list (cons 'r r) (cons 'forged forged)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a tampered tag is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define good (thsl-src! "tests/machine-login-tests.tesl" 1031 (list) (lambda () (hmacTokenFor (machineKey) "install-a"))))
              (let ([*tesl-case-18 (raw-value (tokenTagPart (raw-value good)))]) (cond
                [(and (adt-value? *tesl-case-18) (eq? (adt-value-variant *tesl-case-18) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1033 (list (cons 'good good)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-18) (eq? (adt-value-variant *tesl-case-18) 'Something))
                  (let ([tag (hash-ref (adt-value-fields *tesl-case-18) 'value)])
                    (define broken (thsl-src! "tests/machine-login-tests.tesl" 1036 (list (cons 'good good)) (lambda () (string-append (api-test-string-fragment (string-append (api-test-string-fragment "install-a.") (api-test-string-fragment (tesl_import_String_slice (raw-value tag) 0 63)))) (api-test-string-fragment "0")))))
                    (define r (thsl-src! "tests/machine-login-tests.tesl" 1037 (list (cons 'broken broken) (cons 'good good)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") (string-append "Bearer " (raw-value broken))) #:capabilities (list dbRead dbWrite)))))
                    (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1038 (list (cons 'r r) (cons 'broken broken) (cons 'good good)) (lambda () (api-test-field-access-ref r 'status)))) 401)
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
  (test-case "a non-hex tag is a 401, not a crash"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 1048 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer install-a.not-hex-at-all") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1049 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
              (define empty (thsl-src! "tests/machine-login-tests.tesl" 1050 (list (cons 'r r)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer install-a.") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1051 (list (cons 'empty empty) (cons 'r r)) (lambda () (api-test-field-access-ref empty 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a shapeless HMAC token is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define noDot (thsl-src! "tests/machine-login-tests.tesl" 1059 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer install-a") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1060 (list (cons 'noDot noDot)) (lambda () (api-test-field-access-ref noDot 'status)))) 401)
              (define twoDots (thsl-src! "tests/machine-login-tests.tesl" 1061 (list (cons 'noDot noDot)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer install-a.tag.extra") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1062 (list (cons 'twoDots twoDots) (cons 'noDot noDot)) (lambda () (api-test-field-access-ref twoDots 'status)))) 401)
              (define onlyDot (thsl-src! "tests/machine-login-tests.tesl" 1063 (list (cons 'twoDots twoDots) (cons 'noDot noDot)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer .") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1064 (list (cons 'onlyDot onlyDot) (cons 'twoDots twoDots) (cons 'noDot noDot)) (lambda () (api-test-field-access-ref onlyDot 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a validly signed id for a nonexistent installation is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define token (thsl-src! "tests/machine-login-tests.tesl" 1074 (list) (lambda () (hmacTokenFor (machineKey) "install-zzz"))))
              (define r (thsl-src! "tests/machine-login-tests.tesl" 1075 (list (cons 'token token)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") (string-append "Bearer " (raw-value token))) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1076 (list (cons 'r r) (cons 'token token)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a validly signed id for a REVOKED installation is a 401"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define token (thsl-src! "tests/machine-login-tests.tesl" 1084 (list) (lambda () (hmacTokenFor (machineKey) "install-c"))))
              (define r (thsl-src! "tests/machine-login-tests.tesl" 1085 (list (cons 'token token)) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") (string-append "Bearer " (raw-value token))) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1086 (list (cons 'r r) (cons 'token token)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the two flavours do not accept each other's tokens"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define storedOnHmac (thsl-src! "tests/machine-login-tests.tesl" 1096 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "hmac" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1097 (list (cons 'storedOnHmac storedOnHmac)) (lambda () (api-test-field-access-ref storedOnHmac 'status)))) 401)
              (define hmacOnStored (thsl-src! "tests/machine-login-tests.tesl" 1098 (list (cons 'storedOnHmac storedOnHmac)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") (string-append "Bearer " (raw-value (hmacTokenFor (machineKey) "install-a")))) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1099 (list (cons 'hmacOnStored hmacOnStored) (cons 'storedOnHmac storedOnHmac)) (lambda () (api-test-field-access-ref hmacOnStored 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a human session does not authenticate a machine route"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite sessions)
              (let ([_ (seedFixtures)]) _)
              (define loginResp (thsl-src! "tests/machine-login-tests.tesl" 1111 (list) (lambda () (dispatch-api-test-request MachineServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list dbRead dbWrite sessions)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1112 (list (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref loginResp 'status)))))))
              (let ([*tesl-case-19 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1114 (list (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-19) 'value)])
                    (define r (thsl-src! "tests/machine-login-tests.tesl" 1118 (list (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:cookie session #:headers (tesl-hash) #:capabilities (list dbRead dbWrite sessions)))))
                    (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1119 (list (cons 'r r) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref r 'status)))) 401)
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
  (test-case "a machine token does not authenticate a session route"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite sessions)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 1127 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "session" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite sessions)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1128 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a valid session cookie cannot rescue a bad bearer token"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite sessions)
              (let ([_ (seedFixtures)]) _)
              (define loginResp (thsl-src! "tests/machine-login-tests.tesl" 1136 (list) (lambda () (dispatch-api-test-request MachineServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list dbRead dbWrite sessions)))))
              (let ([*tesl-case-20 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-20) (eq? (adt-value-variant *tesl-case-20) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1138 (list (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-20) (eq? (adt-value-variant *tesl-case-20) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-20) 'value)])
                    (define r (thsl-src! "tests/machine-login-tests.tesl" 1142 (list (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:cookie session #:headers (tesl-hash (string->symbol "authorization") "Bearer instx-0000000000000000000000000000000000") #:capabilities (list dbRead dbWrite sessions)))))
                    (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1143 (list (cons 'r r) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref r 'status)))) 401)
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
  (test-case "a bogus cookie does not disturb a valid machine token"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite sessions)
              (let ([_ (seedFixtures)]) _)
              (define r (thsl-src! "tests/machine-login-tests.tesl" 1151 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:cookie "__Host-session=not-a-jwt" #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite sessions)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1152 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1153 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'install)))) "install-a")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a machine request mints no session cookie"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (let ([_ (seedFixtures)]) _)
              (define accepted (thsl-src! "tests/machine-login-tests.tesl" 1164 (list) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer insta-4Zq7v1oXk2pR9sT0uW3yB6cD8eF1gH5j") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1165 (list (cons 'accepted accepted)) (lambda () (statusOk (raw-value (api-test-field-access-ref accepted 'status)))))))
              (let ([*tesl-case-21 (raw-value (responseCookie (raw-value accepted)))]) (cond
                [(and (adt-value? *tesl-case-21) (eq? (adt-value-variant *tesl-case-21) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-21) 'value)])
                    (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1167 (list (cons 'accepted accepted)) (lambda () #f))))
                  )
                ]
                [(and (adt-value? *tesl-case-21) (eq? (adt-value-variant *tesl-case-21) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1168 (list (cons 'accepted accepted)) (lambda () #t))))
                ]
              ))
              (define refused (thsl-src! "tests/machine-login-tests.tesl" 1170 (list (cons 'accepted accepted)) (lambda () (dispatch-api-test-request MachineServer 'get (list "machine" "whoami") #:headers (tesl-hash (string->symbol "authorization") "Bearer instx-0000000000000000000000000000000000") #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1171 (list (cons 'refused refused) (cons 'accepted accepted)) (lambda () (api-test-field-access-ref refused 'status)))) 401)
              (let ([*tesl-case-22 (raw-value (responseCookie (raw-value refused)))]) (cond
                [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Something))
                  (let ([pair (hash-ref (adt-value-fields *tesl-case-22) 'value)])
                    (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1173 (list (cons 'refused refused) (cons 'accepted accepted)) (lambda () #f))))
                  )
                ]
                [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1174 (list (cons 'refused refused) (cons 'accepted accepted)) (lambda () #t))))
                ]
              ))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the session half of the same server still works"
    (call-with-fresh-memory-db (list MarketplaceDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite sessions)
              (let ([_ (seedFixtures)]) _)
              (define loginResp (thsl-src! "tests/machine-login-tests.tesl" 1185 (list) (lambda () (dispatch-api-test-request MachineServer 'post (list "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "user") "alice") #:capabilities (list dbRead dbWrite sessions)))))
              (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1186 (list (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref loginResp 'status)))))))
              (let ([*tesl-case-23 (raw-value (responseCookie (raw-value loginResp)))]) (cond
                [(and (adt-value? *tesl-case-23) (eq? (adt-value-variant *tesl-case-23) 'Nothing))
                  (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1188 (list (cons 'loginResp loginResp)) (lambda () #f))))
                ]
                [(and (adt-value? *tesl-case-23) (eq? (adt-value-variant *tesl-case-23) 'Something))
                  (let ([session (hash-ref (adt-value-fields *tesl-case-23) 'value)])
                    (define me (thsl-src! "tests/machine-login-tests.tesl" 1190 (list (cons 'loginResp loginResp)) (lambda () (dispatch-api-test-request MachineServer 'get (list "session" "whoami") #:cookie session #:headers (tesl-hash) #:capabilities (list dbRead dbWrite sessions)))))
                    (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1191 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref me 'status)))))))
                    (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 1192 (list (cons 'me me) (cons 'loginResp loginResp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref me 'body) 'user)))) "alice")
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
  (test-case "the store keeps a digest, never the token"
    (call-with-fresh-memory-db (list MarketplaceDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-24 (thsl-src! "tests/machine-login-tests.tesl" 612 (list) (lambda () (seedFixtures))))
    (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 616 (list) (lambda () (installationByStored (tokenAlphaWrite))))) "")
    (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 619 (list) (lambda () (installationByStored (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenAlphaWrite)))))))) "install-a")
    )
    ))
  )

  (test-case "a check-bound value works as a SQL operand"
    (call-with-fresh-memory-db (list MarketplaceDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-25 (thsl-src! "tests/machine-login-tests.tesl" 623 (list) (lambda () (seedFixtures))))
    (let ([*tesl-case-26 (raw-value 
      (tokenTagPart (hmacTokenFor (machineKey) "install-a")))]) (cond
      [(and (adt-value? *tesl-case-26) (eq? (adt-value-variant *tesl-case-26) 'Nothing))
        (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 625 (list) (lambda () #f))))
      ]
      [(and (adt-value? *tesl-case-26) (eq? (adt-value-variant *tesl-case-26) 'Something))
        (let ([tag (hash-ref (adt-value-fields *tesl-case-26) 'value)])
          (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 629 (list) (lambda () (installationForVerifiedTag "install-a" tag)))) "org-alpha")
          (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/machine-login-tests.tesl" 633 (list) (lambda ()
                                  (installationForVerifiedTag "install-a" "00000000000000000000000000000000000000000000000000000000000000ff"))))])
            (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                        "expected failure: installationForVerifiedTag \"install-a\" \"00000000000000000000000000000000000000000000000000000000000000ff\""))
        )
      ]
    ))
    )
    ))
  )

  (test-case "fingerprint is deterministic and separates tokens"
    (call-with-fresh-memory-db (list MarketplaceDb) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 637 (list) (lambda () (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenAlphaWrite))))))) (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenAlphaWrite)))))
  (check-not-equal? (thsl-src! "tests/machine-login-tests.tesl" 638 (list) (lambda () (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenAlphaWrite)))))) (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenBetaWrite)))))
  (check-not-equal? (thsl-src! "tests/machine-login-tests.tesl" 641 (list) (lambda () (raw-value (tesl_import_Crypto_fingerprint (raw-value (tokenAlphaWrite)))))) (raw-value (tesl_import_Crypto_fingerprint (string-append (raw-value (tokenAlphaWrite)) "x"))))
    ))
  )

  (test-case "scopesOf grants write only when the stored scope says so"
    (call-with-fresh-memory-db (list MarketplaceDb) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 645 (list) (lambda () (raw-value (tesl_import_List_member WriteWidgets (raw-value (scopesOf "read,write"))))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 646 (list) (lambda () (raw-value (tesl_import_List_member WriteWidgets (raw-value (scopesOf "read"))))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 647 (list) (lambda () (raw-value (tesl_import_List_member ReadWidgets (raw-value (scopesOf "read"))))))) #t)
    ))
  )

  (test-case "an HMAC-bound token is exactly <installId>.<hex-tag>"
    (call-with-fresh-memory-db (list MarketplaceDb) (lambda ()
  (define token (thsl-src! "tests/machine-login-tests.tesl" 651 (list) (lambda () (hmacTokenFor (machineKey) "install-a"))))
  (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 652 (list (cons 'token token)) (lambda () (tokenInstallPart token)))) (raw-value (Something "install-a")))
  (let ([*tesl-case-27 (raw-value 
    (tokenTagPart token))]) (cond
    [(and (adt-value? *tesl-case-27) (eq? (adt-value-variant *tesl-case-27) 'Nothing))
      (check-true (raw-value (thsl-src! "tests/machine-login-tests.tesl" 654 (list) (lambda () #f))))
    ]
    [(and (adt-value? *tesl-case-27) (eq? (adt-value-variant *tesl-case-27) 'Something))
      (let ([tag (hash-ref (adt-value-fields *tesl-case-27) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 655 (list) (lambda () (tesl_import_String_length (raw-value tag))))) 64)
      )
    ]
  ))
  (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 657 (list (cons 'token token)) (lambda () (tokenInstallPart "install-a")))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/machine-login-tests.tesl" 658 (list (cons 'token token)) (lambda () (tokenInstallPart "install-a.tag.extra")))) Nothing)
    ))
  )

  (test-case "the same id under two keys yields two different tags"
    (call-with-fresh-memory-db (list MarketplaceDb) (lambda ()
  (define good (thsl-src! "tests/machine-login-tests.tesl" 662 (list) (lambda () (hmacTokenFor (machineKey) "install-a"))))
  (define forged (thsl-src! "tests/machine-login-tests.tesl" 663 (list (cons 'good good)) (lambda () (hmacTokenFor (attackerKey) "install-a"))))
  (check-not-equal? (thsl-src! "tests/machine-login-tests.tesl" 664 (list (cons 'forged forged) (cons 'good good)) (lambda () good)) forged)
    ))
  )

)
