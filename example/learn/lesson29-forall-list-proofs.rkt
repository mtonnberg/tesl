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
  (only-in tesl/tesl/prelude Int List String)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/id generatePrefixedId)
)


(provide NoteServer)

(define Authenticated 'Authenticated)
(define IsActive 'IsActive)
(define IsPinned 'IsPinned)
(define ValidNoteId 'ValidNoteId)
(define ValidTitle 'ValidTitle)

(define-capability noteDbRead (implies dbRead))

(define-capability noteDbWrite (implies dbWrite))

(define-capability noteReadCookie)

(define-capability noteService (implies noteDbRead noteDbWrite noteReadCookie random))

(define-entity Note
  #:source (make-hash)
  #:table notes
  #:primary-key id
  [Id id : String #:db-type text]
  [Title title : String #:db-type text]
  [Content content : String #:db-type text]
  [AuthorId authorId : String #:db-type text]
  [Active active : String #:db-type text]
  [Pinned pinned : String #:db-type text]
)

(define-database NoteDatabase
  #:backend postgres
  #:database (tesl-env-raw "NOTES_DB_NAME")
  #:user (tesl-env-raw "NOTES_DB_USER")
  #:password (tesl-env-raw "NOTES_DB_PASSWORD")
  #:server (tesl-env-raw "NOTES_DB_HOST")
  #:port 5432
  #:schema notes_lesson29
  #:entities Note)

(define-checker
  (checkTitle [s : String])
  #:returns [s : String ::: (ValidTitle s)]
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 141 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 1) (<= (raw-value (tesl_import_String_length *s)) 200)) (accept (ValidTitle s) #:value *s) (reject "title must be 1-200 characters" #:http-code 400)))))

(define-record NewNote
  [title : String ::: (ValidTitle title)]
  [content : String]
)

(define (tesl-codec-encode-NewNote _v)
  (error "toJson is forbidden for type NewNote: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewNote-0 _j)
  (define _fraw_title (tesl-decode-prim-field _j "title" tesl-decode-prim-string))
  (define _r1_title
    (let ([_r (checkTitle _fraw_title)])
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
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 164 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 5) (accept (ValidNoteId s) #:value *s) (reject "invalid note id" #:http-code 400)))))

(define-capture noteIdCapture
  [noteId : String ::: (ValidNoteId noteId)]
  #:parser string-segment #:check checkNoteId)

(define-checker
  (checkActive [note : Note])
  #:returns [note : Note ::: (IsActive note)]
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 176 (list (cons 'note *note)) (lambda () (if (equal? (raw-value note.active) "yes") (accept (IsActive note) #:value *note) (reject "note is not active" #:http-code 422)))))

(define-checker
  (checkPinned [note : Note])
  #:returns [note : Note ::: (IsPinned note)]
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 184 (list (cons 'note *note)) (lambda () (if (equal? (raw-value note.pinned) "yes") (accept (IsPinned note) #:value *note) (reject "note is not pinned" #:http-code 422)))))

(define-auther
  (cookieAuth [request : HttpRequest])
  #:capabilities [noteReadCookie]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "example/learn/lesson29-forall-list-proofs.tesl" 195 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 196 (list) (lambda () (reject "not logged in" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 197 (list (cons 'userId userId)) (lambda () (accept (Authenticated userId) #:value *userId))))])))))

(define-handler
  (listNotes [user : String ::: (Authenticated user)])
  #:capabilities [noteDbRead]
  #:returns (List Note)
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 204 (list (cons 'user *user)) (lambda () (select-many (from Note) (where (==. (entity-field-ref Note 'authorId) user))))))

(define-handler
  (listActiveNotes [user : String ::: (Authenticated user)])
  #:capabilities [noteDbRead]
  #:returns (List Note)
  (let ([allNotes (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 211 (list (cons 'user *user)) (lambda () (select-many (from Note) (where (==. (entity-field-ref Note 'authorId) user)))))]) (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 212 (list (cons 'allNotes *allNotes) (cons 'user *user)) (lambda () (tesl_import_List_filterCheck checkActive (raw-value allNotes))))))

(define-handler
  (listActivePinnedNotes [user : String ::: (Authenticated user)])
  #:capabilities [noteDbRead]
  #:returns (List Note)
  (let ([allNotes (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 222 (list (cons 'user *user)) (lambda () (select-many (from Note) (where (==. (entity-field-ref Note 'authorId) user)))))]) (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 223 (list (cons 'allNotes *allNotes) (cons 'user *user)) (lambda () (tesl_import_List_filterCheck (check-and checkActive checkPinned) (raw-value allNotes))))))

(define/pow
  (filterActivePinned [notes : (List Note)])
  #:returns (List Note)
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 233 (list (cons 'notes *notes)) (lambda () (tesl_import_List_filterCheck (check-and checkActive checkPinned) *notes))))

(define/pow
  (verifyAllActive [notes : (List Note)])
  #:returns (Maybe (List Note))
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 245 (list (cons 'notes *notes)) (lambda () (tesl_import_List_allCheck checkActive *notes))))

(define/pow
  (verifyAllActivePinned [notes : (List Note)])
  #:returns (Maybe (List Note))
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 254 (list (cons 'notes *notes)) (lambda () (tesl_import_List_allCheck (check-and checkActive checkPinned) *notes))))

(define/pow
  (countActivePinned [notes : (List Note)])
  #:returns Integer
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 262 (list (cons 'notes *notes)) (lambda () (raw-value (tesl_import_List_length *notes)))))

(define/pow
  (applyCombined [note : Note])
  #:returns (? Note _entity ::: ((IsActive _entity) && (IsPinned _entity)))
  (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 280 (list (cons 'note *note)) (lambda () ((check-and checkActive checkPinned) note))))

(define-handler
  (createNote [user : String ::: (Authenticated user)] [body : NewNote])
  #:capabilities [noteDbRead noteDbWrite random]
  #:returns (Exists [noteId : String] (? Note _entity ::: (FromDb (Id == noteId) _entity)))
  (let ([noteId (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 288 (list (cons 'user *user) (cons 'body *body)) (lambda () (generatePrefixedId "note")))]) (thsl-src! "example/learn/lesson29-forall-list-proofs.tesl" 289 (list (cons 'noteId *noteId) (cons 'user *user) (cons 'body *body)) (lambda () (pack ([noteId]) (insert-one! Note (hash 'id noteId 'title (raw-value body.title) 'content (raw-value body.content) 'authorId user 'active "yes" 'pinned "no")))))))

(define NoteServer-sse-routes '())
(define-api NoteApi
  [listNotes :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "notes"
    :> (Get JSON (List Note))
    ]
  [listActiveNotes :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "notes"
    :> "active"
    :> (Get JSON (List Note))
    ]
  [listActivePinnedNotes :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "notes"
    :> "active-pinned"
    :> (Get JSON (List Note))
    ]
  [createNote :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "notes"
    :> (ReqBody JSON [body : NewNote])
    :> (Post JSON (Exists [noteId : String] (? Note _entity ::: (FromDb (Id == noteId) _entity))))
    ]
)

(define-server NoteServer
  #:api NoteApi
  [listNotes listNotes]
  [listActiveNotes listActiveNotes]
  [listActivePinnedNotes listActivePinnedNotes]
  [createNote createNote]
)
