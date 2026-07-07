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
  (prefix-in __tart_ (only-in tesl/tesl/agent defineAgent withTools tool anthropic openai mistral local tesl-agent-decode-args))
  (prefix-in __tst_ (only-in tesl/tesl/server-tools server-tools))
  (only-in tesl/tesl/prelude String List)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat])
  (only-in tesl/tesl/list [List.length tesl_import_List_length])
  (only-in tesl/tesl/agent aiProvider Agent Tool mockToolProvider toolUseStep textStep askWith replyText replyToolCalls)
)


(provide UserFacingServer AgentFacingServer User Authenticated userFacingTools agentFacingTools mkUser mkUser-signature userFacingTools-signature agentFacingTools-signature)

(define Authenticated 'Authenticated)

(define-capability supportAi (implies aiProvider))

(define-record User
  [id : String]
)

(define-auther
  (cookieAuth [request : HttpRequest])
  #:returns [u : User ::: (Authenticated u)]
  (thsl-src-control! "tests/two-api-server-tools-tests.tesl" 55 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/two-api-server-tools-tests.tesl" 56 (list (cons 'userId userId)) (lambda () (accept Authenticated #:value (User #:id *userId)))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/two-api-server-tools-tests.tesl" 57 (list) (lambda () (reject "Missing user cookie" #:http-code 401)))])))))

(define-handler
  (greet [u : User ::: (Authenticated u)])
  #:returns String
  (thsl-src! "tests/two-api-server-tools-tests.tesl" 63 (list (cons 'u *u)) (lambda () (raw-value (tesl_import_String_concat "hello " (raw-value u.id))))))

(define-handler
  (accountSummary [u : User ::: (Authenticated u)])
  #:returns String
  (thsl-src! "tests/two-api-server-tools-tests.tesl" 67 (list (cons 'u *u)) (lambda () (raw-value (tesl_import_String_concat "summary for " (raw-value u.id))))))

(define-handler
  (deleteAccount [u : User ::: (Authenticated u)])
  #:returns String
  (thsl-src! "tests/two-api-server-tools-tests.tesl" 71 (list (cons 'u *u)) (lambda () (raw-value (tesl_import_String_concat "deleted " (raw-value u.id))))))

(define UserFacingServer-sse-routes '())
(define-api UserFacingApi
  [greet :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "greet"
    :> (Get JSON String)
    ]
  [accountSummary :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "account"
    :> (Get JSON String)
    ]
  [deleteAccount :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "account"
    :> "delete"
    :> (Post JSON String)
    ]
)

(define AgentFacingServer-sse-routes '())
(define-api AgentFacingApi
  [greet :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "greet"
    :> (Get JSON String)
    ]
  [accountSummary :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "account"
    :> (Get JSON String)
    ]
)

(define-server UserFacingServer
  #:api UserFacingApi
  [greet greet]
  [accountSummary accountSummary]
  [deleteAccount deleteAccount]
)

(define-server AgentFacingServer
  #:api AgentFacingApi
  [greet greet]
  [accountSummary accountSummary]
)

(define-checker
  (mkUser [u : User])
  #:returns [u : User ::: (Authenticated u)]
  (thsl-src! "tests/two-api-server-tools-tests.tesl" 111 (list (cons 'u *u)) (lambda () (accept (Authenticated u) #:value *u))))

(define/pow
  (userFacingTools [u : User ::: (Authenticated u)])
  #:returns (List Tool)
  (thsl-src! "tests/two-api-server-tools-tests.tesl" 114 (list (cons 'u *u)) (lambda () (raw-value (__tst_server-tools UserFacingServer u (list (list "greet" "Greet the authenticated user." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "accountSummary" "Summarize the user's account." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "deleteAccount" "Delete the user's account \226\128\148 deliberately NOT exposed to the agent." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(define/pow
  (agentFacingTools [u : User ::: (Authenticated u)])
  #:returns (List Tool)
  (thsl-src! "tests/two-api-server-tools-tests.tesl" 117 (list (cons 'u *u)) (lambda () (raw-value (__tst_server-tools AgentFacingServer u (list (list "greet" "Greet the authenticated user." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "accountSummary" "Summarize the user's account." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(define/pow
  (supportAgent [u : User ::: (Authenticated u)])
  #:returns Agent
  (thsl-src! "tests/two-api-server-tools-tests.tesl" 120 (list (cons 'u *u)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list))) (raw-value "You help the user with their account using the provided tools.") (raw-value 256)) (__tst_server-tools AgentFacingServer u (list (list "greet" "Greet the authenticated user." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "accountSummary" "Summarize the user's account." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(module+ test
  (require rackunit)
  (test-case "agent-facing server exposes only its curated endpoint subset"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawUser (thsl-src! "tests/two-api-server-tools-tests.tesl" 130 (list) (lambda () (User #:id "alice"))))
  (define tesl-checked-1 (mkUser rawUser))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-1)))
  (define user tesl-checked-1)
  (check-equal? (raw-value (thsl-src! "tests/two-api-server-tools-tests.tesl" 132 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (tesl_import_List_length (raw-value (agentFacingTools user))))))) 2)
    ))
  )

  (test-case "user-facing server still derives its full endpoint set"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawUser (thsl-src! "tests/two-api-server-tools-tests.tesl" 138 (list) (lambda () (User #:id "alice"))))
  (define tesl-checked-2 (mkUser rawUser))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-2)))
  (define user tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "tests/two-api-server-tools-tests.tesl" 140 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (tesl_import_List_length (raw-value (userFacingTools user))))))) 3)
    ))
  )

  (test-case "agent-facing tool dispatches the shared handler"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportAi)
    (define rawUser (thsl-src! "tests/two-api-server-tools-tests.tesl" 146 (list) (lambda () (User #:id "alice"))))
    (define tesl-checked-3 (mkUser rawUser))
    (when (check-fail? tesl-checked-3)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-3)))
    (define user tesl-checked-3)
    (define call (thsl-src! "tests/two-api-server-tools-tests.tesl" 148 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "greet" "call_1" "{}")))))
    (define final (thsl-src! "tests/two-api-server-tools-tests.tesl" 149 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "Greeted.")))))
    (define reply (thsl-src! "tests/two-api-server-tools-tests.tesl" 150 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (supportAgent user)) "greet me" (raw-value (mockToolProvider (list call final))))))))
    (check-equal? (raw-value (thsl-src! "tests/two-api-server-tools-tests.tesl" 151 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "Greeted.")
    (check-equal? (raw-value (thsl-src! "tests/two-api-server-tools-tests.tesl" 152 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "excluded endpoint is unknown to the agent and dispatch is refused"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportAi)
    (define rawUser (thsl-src! "tests/two-api-server-tools-tests.tesl" 159 (list) (lambda () (User #:id "alice"))))
    (define tesl-checked-4 (mkUser rawUser))
    (when (check-fail? tesl-checked-4)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-4)))
    (define user tesl-checked-4)
    (define call (thsl-src! "tests/two-api-server-tools-tests.tesl" 161 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "deleteAccount" "call_1" "{}")))))
    (define final (thsl-src! "tests/two-api-server-tools-tests.tesl" 162 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "I cannot do that.")))))
    (define reply (thsl-src! "tests/two-api-server-tools-tests.tesl" 163 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (supportAgent user)) "delete my account" (raw-value (mockToolProvider (list call final))))))))
    (check-equal? (raw-value (thsl-src! "tests/two-api-server-tools-tests.tesl" 164 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "I cannot do that.")
    (check-equal? (raw-value (thsl-src! "tests/two-api-server-tools-tests.tesl" 165 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

)
