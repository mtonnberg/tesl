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
  (only-in tesl/tesl/prelude Int String List)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat] [String.length tesl_import_String_length])
  (only-in tesl/tesl/list [List.append tesl_import_List_append] [List.length tesl_import_List_length])
  (only-in tesl/tesl/agent aiProvider Agent mockToolProvider toolUseStep textStep askWith replyText replyToolCalls)
)


(provide NotesServer User Authenticated Admin)

(define Admin 'Admin)
(define Authenticated 'Authenticated)
(define TextSafe 'TextSafe)

(define-capability notesAi (implies aiProvider))

(define-record User
  [id : String]
  [role : String]
)

(define-auther
  (cookieAuth [request : HttpRequest])
  #:returns [u : User ::: (Authenticated u)]
  (thsl-src-control! "example/learn/lesson68-server-endpoints-as-tools.tesl" 104 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 105 (list (cons 'userId userId)) (lambda () (accept Authenticated #:value (User #:id *userId #:role "user")))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 106 (list) (lambda () (reject "Missing user cookie" #:http-code 401)))])))))

(define-auther
  (adminAuth [request : HttpRequest])
  #:returns [u : User ::: ((Authenticated u) && (Admin u))]
  (thsl-src-control! "example/learn/lesson68-server-endpoints-as-tools.tesl" 109 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "admin" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 110 (list (cons 'userId userId)) (lambda () (accept (Authenticated && Admin) #:value (User #:id *userId #:role "admin")))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 111 (list) (lambda () (reject "Missing admin cookie" #:http-code 401)))])))))

(define-checker
  (isSafeText [text : String])
  #:returns [text : String ::: (TextSafe text)]
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 114 (list (cons 'text *text)) (lambda () (if (<= (raw-value (tesl_import_String_length *text)) 80) (accept (TextSafe text) #:value *text) (reject "Text too long" #:http-code 400)))))

(define-record NewNote
  [text : String ::: (TextSafe text)]
)

(define (tesl-codec-encode-NewNote _v)
  (error "toJson is forbidden for type NewNote: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewNote-0 _j)
  (define _fraw_text (tesl-decode-prim-field _j "text" tesl-decode-prim-string))
  (define _r1_text
    (let ([_r (isSafeText _fraw_text)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_text
    (if (check-ok? _r1_text)
        (ensure-named 'text (check-ok-value _r1_text) (check-ok-facts _r1_text) (check-ok-bindings _r1_text) #:subject 'text)
        _r1_text))
  (or (and (check-fail? _f_text) _f_text)
      (record-value 'NewNote (hash 'text _f_text))))
(register-type-codec! 'NewNote tesl-codec-encode-NewNote (list tesl-codec-decode-NewNote-0))

(define-handler
  (greet [u : User ::: (Authenticated u)])
  #:returns String
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 140 (list (cons 'u *u)) (lambda () (raw-value (tesl_import_String_concat "hello " (raw-value u.id))))))

(define-handler
  (createNote [u : User ::: (Authenticated u)] [note : NewNote])
  #:returns String
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 144 (list (cons 'u *u) (cons 'note *note)) (lambda () (raw-value (tesl_import_String_concat (raw-value (tesl_import_String_concat (raw-value u.id) " noted: ")) (raw-value note.text))))))

(define-handler
  (wipeNotes [u : User ::: ((Authenticated u) && (Admin u))])
  #:returns String
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 148 (list (cons 'u *u)) (lambda () "all notes wiped")))

(define NotesServer-sse-routes '())
(define-api NotesApi
  [greet :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "greet"
    :> (Get JSON String)
    ]
  [createNote :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "notes"
    :> (ReqBody JSON [note : NewNote])
    :> (Post JSON String)
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
  [greet greet]
  [createNote createNote]
  [wipeNotes wipeNotes]
)

(define/pow
  (summarize [text : String])
  #:returns String
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 181 (list (cons 'text *text)) (lambda () (raw-value (tesl_import_String_concat "summary: " *text)))))

(define/pow
  (assistantFor [u : User ::: (Authenticated u)])
  #:returns Agent
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 184 (list (cons 'u *u)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list))) (raw-value "You manage the user's notes with the provided tools.") (raw-value 256)) (tesl_import_List_append (__tst_server-tools NotesServer u (list (list "greet" "Greet the authenticated user by id." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "createNote" "Store a note for the authenticated user." "{\"type\":\"object\",\"properties\":{\"note\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},\"required\":[\"note\"]}"))) (list (__tart_tool "summarize" "Summarize a note text in a fixed style (agent-only helper, not an endpoint)." "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "text" 'string)))) (lambda (_decoded) (apply summarize _decoded)))))))))

(define/pow
  (adminAssistantFor [u : User ::: ((Authenticated u) && (Admin u))])
  #:returns Agent
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 194 (list (cons 'u *u)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list))) (raw-value "You administer the notes service.") (raw-value 256)) (tesl_import_List_append (__tst_server-tools NotesServer u (list (list "greet" "Greet the authenticated user by id." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "createNote" "Store a note for the authenticated user." "{\"type\":\"object\",\"properties\":{\"note\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},\"required\":[\"note\"]}") (list "wipeNotes" "Delete ALL notes in the service. Admin only." "{\"type\":\"object\",\"properties\":{},\"required\":[]}"))) (list (__tart_tool "summarize" "Summarize a note text in a fixed style (agent-only helper, not an endpoint)." "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "text" 'string)))) (lambda (_decoded) (apply summarize _decoded)))))))))

(define-checker
  (mkUser [u : User])
  #:returns [u : User ::: (Authenticated u)]
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 204 (list (cons 'u *u)) (lambda () (accept (Authenticated u) #:value *u))))

(define-checker
  (mkAdmin [u : User])
  #:returns [u : User ::: ((Authenticated u) && (Admin u))]
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 207 (list (cons 'u *u)) (lambda () (accept ((Authenticated u) && (Admin u)) #:value *u))))

(define/pow
  (userToolCount [u : User ::: (Authenticated u)])
  #:returns Integer
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 210 (list (cons 'u *u)) (lambda () (raw-value (tesl_import_List_length (raw-value (tesl_import_List_append (__tst_server-tools NotesServer u (list (list "greet" "Greet the authenticated user by id." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "createNote" "Store a note for the authenticated user." "{\"type\":\"object\",\"properties\":{\"note\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},\"required\":[\"note\"]}"))) (list (__tart_tool "summarize" "Summarize a note text in a fixed style (agent-only helper, not an endpoint)." "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "text" 'string)))) (lambda (_decoded) (apply summarize _decoded)))))))))))

(define/pow
  (adminToolCount [u : User ::: ((Authenticated u) && (Admin u))])
  #:returns Integer
  (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 213 (list (cons 'u *u)) (lambda () (raw-value (tesl_import_List_length (raw-value (tesl_import_List_append (__tst_server-tools NotesServer u (list (list "greet" "Greet the authenticated user by id." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "createNote" "Store a note for the authenticated user." "{\"type\":\"object\",\"properties\":{\"note\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},\"required\":[\"note\"]}") (list "wipeNotes" "Delete ALL notes in the service. Admin only." "{\"type\":\"object\",\"properties\":{},\"required\":[]}"))) (list (__tart_tool "summarize" "Summarize a note text in a fixed style (agent-only helper, not an endpoint)." "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "text" 'string)))) (lambda (_decoded) (apply summarize _decoded)))))))))))

(module+ test
  (require rackunit)
  (test-case "plain user: server tools + custom tools, no admin endpoint"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawUser (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 222 (list) (lambda () (User #:id "alice" #:role "user"))))
  (define tesl-checked-2 (mkUser rawUser))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-2)))
  (define user tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 224 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (userToolCount user)))) 3)
    ))
  )

  (test-case "admin user: the admin endpoint joins the tool list"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawAdmin (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 229 (list) (lambda () (User #:id "root" #:role "admin"))))
  (define tesl-checked-3 (mkAdmin rawAdmin))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let admin: ~a" (check-fail-message tesl-checked-3)))
  (define admin tesl-checked-3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 231 (list (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (adminToolCount admin)))) 4)
    ))
  )

  (test-case "an endpoint tool dispatches the handler on the user's behalf"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesAi)
    (define rawUser (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 237 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-4 (mkUser rawUser))
    (when (check-fail? tesl-checked-4)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-4)))
    (define user tesl-checked-4)
    (define call (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 239 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "createNote" "c1" "{\"note\":{\"text\":\"buy milk\"}}")))))
    (define final (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 240 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "Saved your note.")))))
    (define mock (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 241 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 242 (list (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (assistantFor user)) "note: buy milk" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 243 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "Saved your note.")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 244 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "a custom asTool tool works alongside the endpoint tools"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesAi)
    (define rawUser (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 249 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-5 (mkUser rawUser))
    (when (check-fail? tesl-checked-5)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-5)))
    (define user tesl-checked-5)
    (define call (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 251 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "summarize" "c1" "{\"text\":\"buy milk\"}")))))
    (define final (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 252 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "Here is the summary.")))))
    (define mock (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 253 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 254 (list (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (assistantFor user)) "summarize my note" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 255 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "Here is the summary.")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 256 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "endpoint validation applies to tool arguments too"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesAi)
    (define rawUser (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 262 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-6 (mkUser rawUser))
    (when (check-fail? tesl-checked-6)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-6)))
    (define user tesl-checked-6)
    (define call (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 264 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "createNote" "c1" "{\"note\":{\"text\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}")))))
    (define final (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 265 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "That note is too long.")))))
    (define mock (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 266 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 267 (list (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (assistantFor user)) "note" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 268 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "That note is too long.")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 269 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "the admin endpoint tool dispatches for an admin-proved user"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesAi)
    (define rawAdmin (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 274 (list) (lambda () (User #:id "root" #:role "admin"))))
    (define tesl-checked-7 (mkAdmin rawAdmin))
    (when (check-fail? tesl-checked-7)
      (raise-user-error 'tesl-test "unexpected failure in let admin: ~a" (check-fail-message tesl-checked-7)))
    (define admin tesl-checked-7)
    (define call (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 276 (list (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (toolUseStep "wipeNotes" "c1" "{}")))))
    (define final (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 277 (list (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (textStep "Wiped.")))))
    (define mock (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 278 (list (cons 'final final) (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 279 (list (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (askWith (raw-value (adminAssistantFor admin)) "wipe everything" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 280 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (replyText (raw-value reply)))))) "Wiped.")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson68-server-endpoints-as-tools.tesl" 281 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

)
