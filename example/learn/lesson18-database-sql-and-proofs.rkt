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
  (only-in tesl/tesl/prelude Bool List String Unit)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/time nowMillis time PosixMillis)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/telemetry initTelemetry)
  (only-in tesl/tesl/id generatePrefixedId)
)


(provide NoteDatabase NoteServer)

(define Authenticated 'Authenticated)
(define ValidNoteId 'ValidNoteId)
(define ValidNoteTitle 'ValidNoteTitle)

(define-capability noteDbRead (implies dbRead))

(define-capability noteDbWrite (implies dbWrite))

(define-capability noteTime (implies time))

(define-capability noteReadCookie)

(define-capability noteService (implies noteDbRead noteDbWrite noteTime noteReadCookie random))

(define-newtype NoteId String)

(define-entity Note
  #:source (make-hash)
  #:table notes
  #:primary-key id
  [Id id : NoteId #:db-type text]
  [Title title : String #:db-type text]
  [Content content : String #:db-type text]
  [AuthorId authorId : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
)

(define-database NoteDatabase
  #:backend postgres
  #:database (tesl-env-raw "NOTES_DB_NAME")
  #:user (tesl-env-raw "NOTES_DB_USER")
  #:password (tesl-env-raw "NOTES_DB_PASSWORD")
  #:server (tesl-env-raw "NOTES_DB_HOST")
  #:port (tesl-env-int-raw "NOTES_DB_PORT" 5432)
  #:schema notes_app
  #:entities Note)

(define-checker
  (checkNoteTitle [s : String])
  #:returns [s : String ::: (ValidNoteTitle s)]
  (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 110 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 1) (<= (raw-value (tesl_import_String_length *s)) 200)) (accept (ValidNoteTitle s) #:value *s) (reject "title must be 1-200 characters" #:http-code 400)))))

(define-record NewNote
  [title : String ::: (ValidNoteTitle title)]
  [content : String]
)

(define (tesl-codec-encode-NewNote _v)
  (error "toJson is forbidden for type NewNote: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewNote-0 _j)
  (define _fraw_title (tesl-decode-prim-field _j "title" tesl-decode-prim-string))
  (define _r1_title
    (let ([_r (checkNoteTitle _fraw_title)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_title
    (if (check-ok? _r1_title)
        (ensure-named 'title (check-ok-value _r1_title) (check-ok-facts _r1_title) (check-ok-bindings _r1_title) #:subject 'title)
        _r1_title))
  (define _f_content (tesl-decode-prim-field _j "content" tesl-decode-prim-string))
  (or (and (check-fail? _f_title) _f_title)
      (record-value 'NewNote (hash 'title _f_title 'content _f_content))))
(register-type-codec! 'NewNote tesl-codec-encode-NewNote (list tesl-codec-decode-NewNote-0))

(define-checker
  (checkNoteId [s : String])
  #:returns [s : String ::: (ValidNoteId s)]
  (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 133 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 5) (accept (ValidNoteId s) #:value *s) (reject "invalid note id" #:http-code 400)))))

(define-capture noteIdCapture
  [noteId : String ::: (ValidNoteId noteId)]
  #:parser string-segment #:check checkNoteId)

(define-auther
  (cookieAuth [request : HttpRequest])
  #:capabilities [noteReadCookie]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "example/learn/lesson18-database-sql-and-proofs.tesl" 145 (list (cons 'request *request)) (lambda () (let ([tesl_case_0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 146 (list) (lambda () (reject "not logged in" #:http-code 401)))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 147 (list (cons 'userId userId)) (lambda () (accept (Authenticated userId) #:value *userId))))])))))

(define-handler
  (getNote [user : String ::: (Authenticated user)] [noteId : String ::: (ValidNoteId noteId)])
  #:capabilities [noteDbRead]
  #:returns (? Note _entity ::: (FromDb (Id == noteId) _entity))
  (let ([existing (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 158 (list (cons 'user *user) (cons 'noteId *noteId)) (lambda () (let ([tesl_match (select-one (from Note) (where (==. (entity-field-ref Note 'id) noteId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/learn/lesson18-database-sql-and-proofs.tesl" 159 (list (cons 'existing *existing) (cons 'user *user) (cons 'noteId *noteId)) (lambda () (let ([tesl_case_1 (raw-value existing)]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 160 (list) (lambda () (reject "note not found" #:http-code 404)))] [(and (and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([note (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (not (equal? (raw-value note.authorId) *user)))) (let ([note (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 161 (list (cons 'note note)) (lambda () (reject "not your note" #:http-code 403))))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([note (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 162 (list (cons 'note note)) (lambda () note)))]))))))

(define-handler
  (listNotes [user : String ::: (Authenticated user)])
  #:capabilities [noteDbRead]
  #:returns (List Note)
  (let ([_ (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 167 (list (cons 'user *user)) (lambda () (telemetry-event! "notes.list" #:attributes (["user.id" *user]))))]) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 168 (list (cons 'user *user)) (lambda () (select-many (from Note) (where (==. (entity-field-ref Note 'authorId) user)))))))

(define-handler
  (createNote [user : String ::: (Authenticated user)] [body : NewNote])
  #:capabilities [noteDbRead noteDbWrite noteTime random]
  #:returns (Exists [noteId : String] (? Note _entity ::: (FromDb (Id == noteId) _entity)))
  (let ([noteId (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 177 (list (cons 'user *user) (cons 'body *body)) (lambda () (generatePrefixedId "note")))]) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 178 (list (cons 'noteId *noteId) (cons 'user *user) (cons 'body *body)) (lambda () (pack ([noteId]) (insert-one! Note (hash 'id noteId 'title (raw-value body.title) 'content (raw-value body.content) 'authorId user 'createdAt (raw-value (nowMillis)))))))))

(define-handler
  (updateNoteTitle [user : String ::: (Authenticated user)] [noteId : String ::: (ValidNoteId noteId)] [body : NewNote])
  #:capabilities [noteDbRead noteDbWrite]
  #:returns (? Note _entity ::: (FromDb (Id == noteId) _entity))
  (let ([existing (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 191 (list (cons 'user *user) (cons 'noteId *noteId) (cons 'body *body)) (lambda () (let ([tesl_match (select-one (from Note) (where (==. (entity-field-ref Note 'id) noteId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/learn/lesson18-database-sql-and-proofs.tesl" 192 (list (cons 'existing *existing) (cons 'user *user) (cons 'noteId *noteId) (cons 'body *body)) (lambda () (let ([tesl_case_2 (raw-value existing)]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 193 (list) (lambda () (reject "note not found" #:http-code 404)))] [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([note (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (not (equal? (raw-value note.authorId) *user)))) (let ([note (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 194 (list (cons 'note note)) (lambda () (reject "not your note" #:http-code 403))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 196 (list) (lambda () (car (update-many! (from Note) (hash (entity-field-ref Note 'title) (raw-value body.title)) (where (==. (entity-field-ref Note 'id) noteId))))))]))))))

(define NoteServer-sse-routes '())
(define-api NoteApi
  [getNote :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "notes"
    :> (Capture noteIdCapture [noteId : String ::: (ValidNoteId noteId)])
    :> (Get JSON (? Note _entity ::: (FromDb (Id == noteId) _entity)))
    ]
  [listNotes :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "notes"
    :> (Get JSON (List Note))
    ]
  [createNote :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "notes"
    :> (ReqBody JSON [body : NewNote])
    :> (Post JSON (Exists [noteId : String] (? Note _entity ::: (FromDb (Id == noteId) _entity))))
    ]
  [updateNoteTitle :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "notes"
    :> (Capture noteIdCapture [noteId : String ::: (ValidNoteId noteId)])
    :> (ReqBody JSON [body : NewNote])
    :> (Put JSON (? Note _entity ::: (FromDb (Id == noteId) _entity)))
    ]
)

(define defaultNotePort 8090)

(define-server NoteServer
  #:api NoteApi
  [getNote getNote]
  [listNotes listNotes]
  [createNote createNote]
  [updateNoteTitle updateNoteTitle]
)

(module+ main
  (let ([_ (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 238 (list) (lambda () (init-opentelemetry! #:service-name "notes-api" #:endpoint "in-memory" #:console? #t)))])
  (thsl-src! "example/learn/lesson18-database-sql-and-proofs.tesl" 239 (list) (lambda () (call-with-database NoteDatabase (lambda () (with-capabilities (noteService) (serve NoteServer #:port defaultNotePort #:capabilities (list noteService) #:sse-routes NoteServer-sse-routes))))))))
