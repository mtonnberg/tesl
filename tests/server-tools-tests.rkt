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
  (only-in tesl/tesl/prelude Int String Bool List)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat] [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith])
  (only-in tesl/tesl/list [List.length tesl_import_List_length])
  (only-in tesl/tesl/agent aiProvider Agent Tool mockToolProvider toolUseStep textStep askWith replyText replyToolCalls)
)


(provide NotesServer User Authenticated Admin plainTools adminTools mkUser mkAdmin mkUser-signature mkAdmin-signature plainTools-signature adminTools-signature)

(define Admin 'Admin)
(define Authenticated 'Authenticated)
(define NoteId 'NoteId)
(define TextSafe 'TextSafe)

(define-capability notesBot (implies aiProvider))

(define-record User
  [id : String]
  [role : String]
)

(define-auther
  (cookieAuth [request : HttpRequest])
  #:returns [u : User ::: (Authenticated u)]
  (thsl-src-control! "tests/server-tools-tests.tesl" 56 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/server-tools-tests.tesl" 57 (list (cons 'userId userId)) (lambda () (accept Authenticated #:value (User #:id *userId #:role "user")))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/server-tools-tests.tesl" 58 (list) (lambda () (reject "Missing user cookie" #:http-code 401)))])))))

(define-auther
  (adminAuth [request : HttpRequest])
  #:returns [u : User ::: ((Authenticated u) && (Admin u))]
  (thsl-src-control! "tests/server-tools-tests.tesl" 61 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "admin" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/server-tools-tests.tesl" 62 (list (cons 'userId userId)) (lambda () (accept (Authenticated && Admin) #:value (User #:id *userId #:role "admin")))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/server-tools-tests.tesl" 63 (list) (lambda () (reject "Missing admin cookie" #:http-code 401)))])))))

(define-checker
  (isNoteId [noteId : String])
  #:returns [noteId : String ::: (NoteId noteId)]
  (thsl-src! "tests/server-tools-tests.tesl" 66 (list (cons 'noteId *noteId)) (lambda () (if (tesl_import_String_startsWith *noteId "note-") (accept (NoteId noteId) #:value *noteId) (reject "Malformed note id" #:http-code 400)))))

(define-capture noteIdCapture
  [noteId : String ::: (NoteId noteId)]
  #:parser string-segment #:check isNoteId)

(define-checker
  (isSafeText [text : String])
  #:returns [text : String ::: (TextSafe text)]
  (thsl-src! "tests/server-tools-tests.tesl" 74 (list (cons 'text *text)) (lambda () (if (<= (raw-value (tesl_import_String_length *text)) 20) (accept (TextSafe text) #:value *text) (reject "Text too long" #:http-code 400)))))

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
  (thsl-src! "tests/server-tools-tests.tesl" 94 (list (cons 'u *u)) (lambda () (raw-value (tesl_import_String_concat "hello " (raw-value u.id))))))

(define-handler
  (createNote [u : User ::: (Authenticated u)] [note : NewNote])
  #:returns String
  (thsl-src! "tests/server-tools-tests.tesl" 98 (list (cons 'u *u) (cons 'note *note)) (lambda () (raw-value (tesl_import_String_concat (raw-value (tesl_import_String_concat (raw-value u.id) ":")) (raw-value note.text))))))

(define-handler
  (getNote [u : User ::: (Authenticated u)] [noteId : String ::: (NoteId noteId)])
  #:returns String
  (thsl-src! "tests/server-tools-tests.tesl" 102 (list (cons 'u *u) (cons 'noteId *noteId)) (lambda () (raw-value (tesl_import_String_concat "note " *noteId)))))

(define-handler
  (guarded [u : User ::: (Authenticated u)])
  #:returns String
  (thsl-src! "tests/server-tools-tests.tesl" 106 (list (cons 'u *u)) (lambda () (if (tesl-equal? (raw-value u.id) "blocked") (reject "blocked user" #:http-code 403) "ok"))))

(define-handler
  (adminWipe [u : User ::: ((Authenticated u) && (Admin u))])
  #:returns String
  (thsl-src! "tests/server-tools-tests.tesl" 113 (list (cons 'u *u)) (lambda () "wiped")))

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
  [getNote :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "notes"
    :> (Capture noteIdCapture [noteId : String ::: (NoteId noteId)])
    :> (Get JSON String)
    ]
  [guarded :
    (Auth [u : User ::: (Authenticated u)] #:via cookieAuth)
    :> "guarded"
    :> (Get JSON String)
    ]
  [adminWipe :
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
  [getNote getNote]
  [guarded guarded]
  [adminWipe adminWipe]
)

(define-checker
  (mkUser [u : User])
  #:returns [u : User ::: (Authenticated u)]
  (thsl-src! "tests/server-tools-tests.tesl" 150 (list (cons 'u *u)) (lambda () (accept (Authenticated u) #:value *u))))

(define-checker
  (mkAdmin [u : User])
  #:returns [u : User ::: ((Authenticated u) && (Admin u))]
  (thsl-src! "tests/server-tools-tests.tesl" 153 (list (cons 'u *u)) (lambda () (accept ((Authenticated u) && (Admin u)) #:value *u))))

(define/pow
  (plainTools [u : User ::: (Authenticated u)])
  #:returns (List Tool)
  (thsl-src! "tests/server-tools-tests.tesl" 156 (list (cons 'u *u)) (lambda () (raw-value (__tst_server-tools NotesServer u (list (list "greet" "Greet the authenticated user by id." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "createNote" "Store a validated note for the authenticated user." "{\"type\":\"object\",\"properties\":{\"note\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},\"required\":[\"note\"]}") (list "getNote" "Read one note by its id." "{\"type\":\"object\",\"properties\":{\"noteId\":{\"type\":\"string\"}},\"required\":[\"noteId\"]}") (list "guarded" "Do something only unblocked users may do." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(define/pow
  (adminTools [u : User ::: ((Authenticated u) && (Admin u))])
  #:returns (List Tool)
  (thsl-src! "tests/server-tools-tests.tesl" 159 (list (cons 'u *u)) (lambda () (raw-value (__tst_server-tools NotesServer u (list (list "greet" "Greet the authenticated user by id." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "createNote" "Store a validated note for the authenticated user." "{\"type\":\"object\",\"properties\":{\"note\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},\"required\":[\"note\"]}") (list "getNote" "Read one note by its id." "{\"type\":\"object\",\"properties\":{\"noteId\":{\"type\":\"string\"}},\"required\":[\"noteId\"]}") (list "guarded" "Do something only unblocked users may do." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "adminWipe" "Wipe everything. Admin only." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(define/pow
  (plainAgent [u : User ::: (Authenticated u)])
  #:returns Agent
  (thsl-src! "tests/server-tools-tests.tesl" 162 (list (cons 'u *u)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list))) (raw-value "You manage the user's notes with the provided tools.") (raw-value 256)) (__tst_server-tools NotesServer u (list (list "greet" "Greet the authenticated user by id." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "createNote" "Store a validated note for the authenticated user." "{\"type\":\"object\",\"properties\":{\"note\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},\"required\":[\"note\"]}") (list "getNote" "Read one note by its id." "{\"type\":\"object\",\"properties\":{\"noteId\":{\"type\":\"string\"}},\"required\":[\"noteId\"]}") (list "guarded" "Do something only unblocked users may do." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(define/pow
  (adminAgent [u : User ::: ((Authenticated u) && (Admin u))])
  #:returns Agent
  (thsl-src! "tests/server-tools-tests.tesl" 170 (list (cons 'u *u)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list))) (raw-value "You administer the notes service.") (raw-value 256)) (__tst_server-tools NotesServer u (list (list "greet" "Greet the authenticated user by id." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "createNote" "Store a validated note for the authenticated user." "{\"type\":\"object\",\"properties\":{\"note\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},\"required\":[\"note\"]}") (list "getNote" "Read one note by its id." "{\"type\":\"object\",\"properties\":{\"noteId\":{\"type\":\"string\"}},\"required\":[\"noteId\"]}") (list "guarded" "Do something only unblocked users may do." "{\"type\":\"object\",\"properties\":{},\"required\":[]}") (list "adminWipe" "Wipe everything. Admin only." "{\"type\":\"object\",\"properties\":{},\"required\":[]}")))))))

(module+ test
  (require rackunit)
  (test-case "plain user gets only the Authenticated endpoints as tools"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawUser (thsl-src! "tests/server-tools-tests.tesl" 180 (list) (lambda () (User #:id "alice" #:role "user"))))
  (define tesl-checked-2 (mkUser rawUser))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-2)))
  (define user tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 182 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (tesl_import_List_length (raw-value (plainTools user))))))) 4)
    ))
  )

  (test-case "admin user additionally gets the admin-gated endpoint"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawAdmin (thsl-src! "tests/server-tools-tests.tesl" 188 (list) (lambda () (User #:id "root" #:role "admin"))))
  (define tesl-checked-3 (mkAdmin rawAdmin))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let admin: ~a" (check-fail-message tesl-checked-3)))
  (define admin tesl-checked-3)
  (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 190 (list (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (tesl_import_List_length (raw-value (adminTools admin))))))) 5)
    ))
  )

  (test-case "endpoint tool dispatches the handler on the user's behalf"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesBot)
    (define rawUser (thsl-src! "tests/server-tools-tests.tesl" 197 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-4 (mkUser rawUser))
    (when (check-fail? tesl-checked-4)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-4)))
    (define user tesl-checked-4)
    (define call (thsl-src! "tests/server-tools-tests.tesl" 199 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "greet" "call_1" "{}")))))
    (define final (thsl-src! "tests/server-tools-tests.tesl" 200 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "Greeted you.")))))
    (define reply (thsl-src! "tests/server-tools-tests.tesl" 201 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (plainAgent user)) "greet me" (raw-value (mockToolProvider (list call final))))))))
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 202 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "Greeted you.")
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 203 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "body endpoint tool decodes the model's body argument"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesBot)
    (define rawUser (thsl-src! "tests/server-tools-tests.tesl" 209 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-5 (mkUser rawUser))
    (when (check-fail? tesl-checked-5)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-5)))
    (define user tesl-checked-5)
    (define call (thsl-src! "tests/server-tools-tests.tesl" 211 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "createNote" "call_1" "{\"note\":{\"text\":\"buy milk\"}}")))))
    (define final (thsl-src! "tests/server-tools-tests.tesl" 212 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "Saved your note.")))))
    (define reply (thsl-src! "tests/server-tools-tests.tesl" 213 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (plainAgent user)) "note: buy milk" (raw-value (mockToolProvider (list call final))))))))
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 214 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "Saved your note.")
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 215 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "capture endpoint tool validates the capture argument"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesBot)
    (define rawUser (thsl-src! "tests/server-tools-tests.tesl" 221 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-6 (mkUser rawUser))
    (when (check-fail? tesl-checked-6)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-6)))
    (define user tesl-checked-6)
    (define call (thsl-src! "tests/server-tools-tests.tesl" 223 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "getNote" "call_1" "{\"noteId\":\"note-7\"}")))))
    (define final (thsl-src! "tests/server-tools-tests.tesl" 224 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "Found it.")))))
    (define reply (thsl-src! "tests/server-tools-tests.tesl" 225 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (plainAgent user)) "show note-7" (raw-value (mockToolProvider (list call final))))))))
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 226 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "Found it.")
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 227 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "invalid body argument is rejected as is_error and the loop continues"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesBot)
    (define rawUser (thsl-src! "tests/server-tools-tests.tesl" 233 (list) (lambda () (User #:id "alice" #:role "user"))))
    (define tesl-checked-7 (mkUser rawUser))
    (when (check-fail? tesl-checked-7)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-7)))
    (define user tesl-checked-7)
    (define call (thsl-src! "tests/server-tools-tests.tesl" 235 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "createNote" "call_1" "{\"note\":{\"text\":\"aaaaaaaaaaaaaaaaaaaaa\"}}")))))
    (define final (thsl-src! "tests/server-tools-tests.tesl" 236 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "That note is too long.")))))
    (define reply (thsl-src! "tests/server-tools-tests.tesl" 237 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (plainAgent user)) "note" (raw-value (mockToolProvider (list call final))))))))
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 238 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "That note is too long.")
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 239 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "handler fail becomes an is_error tool_result, not an exception"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesBot)
    (define rawUser (thsl-src! "tests/server-tools-tests.tesl" 245 (list) (lambda () (User #:id "blocked" #:role "user"))))
    (define tesl-checked-8 (mkUser rawUser))
    (when (check-fail? tesl-checked-8)
      (raise-user-error 'tesl-test "unexpected failure in let user: ~a" (check-fail-message tesl-checked-8)))
    (define user tesl-checked-8)
    (define call (thsl-src! "tests/server-tools-tests.tesl" 247 (list (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (toolUseStep "guarded" "call_1" "{}")))))
    (define final (thsl-src! "tests/server-tools-tests.tesl" 248 (list (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (textStep "You are not allowed to do that.")))))
    (define reply (thsl-src! "tests/server-tools-tests.tesl" 249 (list (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (askWith (raw-value (plainAgent user)) "do it" (raw-value (mockToolProvider (list call final))))))))
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 250 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyText (raw-value reply)))))) "You are not allowed to do that.")
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 251 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'user user) (cons 'rawUser rawUser)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "admin tool dispatches for an admin-proved user"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (notesBot)
    (define rawAdmin (thsl-src! "tests/server-tools-tests.tesl" 256 (list) (lambda () (User #:id "root" #:role "admin"))))
    (define tesl-checked-9 (mkAdmin rawAdmin))
    (when (check-fail? tesl-checked-9)
      (raise-user-error 'tesl-test "unexpected failure in let admin: ~a" (check-fail-message tesl-checked-9)))
    (define admin tesl-checked-9)
    (define call (thsl-src! "tests/server-tools-tests.tesl" 258 (list (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (toolUseStep "adminWipe" "call_1" "{}")))))
    (define final (thsl-src! "tests/server-tools-tests.tesl" 259 (list (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (textStep "Wiped.")))))
    (define reply (thsl-src! "tests/server-tools-tests.tesl" 260 (list (cons 'final final) (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (askWith (raw-value (adminAgent admin)) "wipe it all" (raw-value (mockToolProvider (list call final))))))))
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 261 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (replyText (raw-value reply)))))) "Wiped.")
    (check-equal? (raw-value (thsl-src! "tests/server-tools-tests.tesl" 262 (list (cons 'reply reply) (cons 'final final) (cons 'call call) (cons 'admin admin) (cons 'rawAdmin rawAdmin)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

)
