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
  (prefix-in __tht_ (only-in tesl/tesl/human-actions human-actions))
  (only-in tesl/tesl/prelude Int String List)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat])
  (only-in tesl/tesl/list [List.append tesl_import_List_append] [List.length tesl_import_List_length])
  (only-in tesl/tesl/agent aiProvider Agent Tool mockToolProvider toolUseStep textStep newConversation converse turnReply turnConversation askWith replyText replyToolCalls)
)


(provide NotesServer User Authenticated Admin)

(define Admin 'Admin)
(define Authenticated 'Authenticated)

(define-capability notesAi (implies aiProvider))

(define-record User
  [id : String]
  [role : String]
)

(define-auther
  (cookieAuth [request : HttpRequest])
  #:returns [u : User ::: (Authenticated u)]
  (thsl-src-control! "example/learn/lesson69-agent-human-handoff.tesl" 86 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 87 (list (cons 'userId userId)) (lambda () (accept Authenticated #:value (User #:id *userId #:role "user")))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 88 (list) (lambda () (reject "Missing user cookie" #:http-code 401)))])))))

(define-auther
  (adminAuth [request : HttpRequest])
  #:returns [u : User ::: ((Authenticated u) && (Admin u))]
  (thsl-src-control! "example/learn/lesson69-agent-human-handoff.tesl" 91 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "admin" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 92 (list (cons 'userId userId)) (lambda () (accept (Authenticated && Admin) #:value (User #:id *userId #:role "admin")))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 93 (list) (lambda () (reject "Missing admin cookie" #:http-code 401)))])))))

(define-handler
  (listNotes [u : User ::: (Authenticated u)])
  #:returns String
  (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 97 (list (cons 'u *u)) (lambda () (raw-value (tesl_import_String_concat (raw-value u.id) "'s notes: milk, eggs")))))

(define-handler
  (wipeNotes [u : User ::: ((Authenticated u) && (Admin u))])
  #:returns String
  (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 102 (list (cons 'u *u)) (lambda () "all notes wiped")))

(define NotesServer-sse-routes '())
(define-api NotesApi
  [listNotes :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "notes"
    :> (Get JSON String)
    ]
  [wipeNotes :
    (Auth [u : User ::: ((Authenticated u) && (Admin u))] #:via adminAuth)
    :> "admin"
    :> "wipe"
    :> (Post JSON String)
    ]
)

(define-server NotesServer
  #:api NotesApi
  [listNotes listNotes]
  [wipeNotes wipeNotes]
)

(define-checker
  (mkUser [u : User])
  #:returns [u : User ::: (Authenticated u)]
  (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 121 (list (cons 'u *u)) (lambda () (accept (Authenticated u) #:value *u))))

(define/pow
  (assistantFor [u : User ::: (Authenticated u)])
  #:returns Agent
  (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 126 (list (cons 'u *u)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list (raw-value (toolUseStep "wipeNotes" "call_1" "{}")) (raw-value (textStep "That needs an admin \u2014 I've put a Wipe button in front of you.")) (raw-value (textStep "Done \u2014 your notes were wiped."))))) (raw-value "Manage the user's notes. Admin-only actions must be asked of the human.") (raw-value 256)) (tesl_import_List_append (__tst_server-tools NotesServer u (list (list "listNotes" "Read the authenticated user's notes.  The agent MAY do this for them." "{\"type\":\"object\",\"properties\":{},\"required\":[]}"))) (__tht_human-actions "NotesServer" (list (list "wipeNotes" "Delete ALL notes.  Admin only \226\128\148 we do NOT trust the agent to do this autonomously, even for an admin user; a human confirms it in the browser." "{\"type\":\"object\",\"properties\":{},\"required\":[]}"))))))))

(define/pow
  (agentRunnable [u : User ::: (Authenticated u)])
  #:returns (List Tool)
  (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 142 (list (cons 'u *u)) (lambda () (raw-value (__tst_server-tools NotesServer u (list (list "listNotes" "Read the authenticated user's notes.  The agent MAY do this for them." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(define/pow
  (humanOnly [u : User ::: (Authenticated u)])
  #:returns (List Tool)
  (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 145 (list (cons 'u *u)) (lambda () (raw-value (__tht_human-actions "NotesServer" (list (list "wipeNotes" "Delete ALL notes.  Admin only \226\128\148 we do NOT trust the agent to do this autonomously, even for an admin user; a human confirms it in the browser." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(module+ test
  (require rackunit)
  (test-case "serverTools and humanActions partition the endpoints"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 154 (list) (lambda () (User #:id "alice" #:role "user"))))
  (define tesl-checked-2 (mkUser raw))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-2)))
  (define user tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 156 (list (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (tesl_import_List_length (raw-value (agentRunnable user))))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 157 (list (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (tesl_import_List_length (raw-value (humanOnly user))))))) 1)
    ))
  )

  (test-case "turn 1: the agent requests the held-back action, inertly"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesAi)
    (define raw (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 164 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-3 (mkUser raw))
    (when (check-fail? tesl-checked-3)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-3)))
    (define user tesl-checked-3)
    (define conv0 (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 166 (list (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (newConversation (raw-value (assistantFor user)))))))
    (define turn1 (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 167 (list (cons 'conv0 conv0) (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (converse (raw-value conv0) "Please wipe all my notes")))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 168 (list (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn1)))))))) "That needs an admin \u2014 I've put a Wipe button in front of you.")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 169 (list (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (replyToolCalls (raw-value (turnReply (raw-value turn1)))))))) 1)
    )
    ))
  )

  (test-case "turn 2: the human's completed action resumes the conversation"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesAi)
    (define raw (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 177 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-4 (mkUser raw))
    (when (check-fail? tesl-checked-4)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-4)))
    (define user tesl-checked-4)
    (define conv0 (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 179 (list (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (newConversation (raw-value (assistantFor user)))))))
    (define turn1 (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 180 (list (cons 'conv0 conv0) (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (converse (raw-value conv0) "Please wipe all my notes")))))
    (define conv1 (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 181 (list (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (turnConversation (raw-value turn1))))))
    (define turn2 (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 183 (list (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (converse (raw-value conv1) "[human completed wipeNotes (handle call_1): all notes wiped]")))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson69-agent-human-handoff.tesl" 184 (list (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'user user) (cons 'raw raw)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn2)))))))) "Done \u2014 your notes were wiped.")
    )
    ))
  )

)
