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
  (only-in tesl/tesl/prelude String)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/time nowMillis time PosixMillis [Time.secondsToPosix tesl_import_Time_secondsToPosix])
)


(provide NotesServer)

(define Authenticated 'Authenticated)
(define SafeContent 'SafeContent)
(define SafeTitle 'SafeTitle)

(define-capability noteDbRead (implies dbRead))

(define-capability noteDbWrite (implies dbWrite))

(define-capability noteAuth)

(define-newtype NoteId String)

(define-checker
  (checkSafeContent [s : String])
  #:returns [s : String ::: (SafeContent s)]
  (thsl-src! "example/learn/lesson16-complete-notes-api.tesl" 45 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 1) (<= (raw-value (tesl_import_String_length *s)) 2000)) (accept (SafeContent s) #:value *s) (reject "note content must be 1-2000 characters" #:http-code 400)))))

(define-checker
  (checkSafeTitle [s : String])
  #:returns [s : String ::: (SafeTitle s)]
  (thsl-src! "example/learn/lesson16-complete-notes-api.tesl" 54 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 1) (<= (raw-value (tesl_import_String_length *s)) 200)) (accept (SafeTitle s) #:value *s) (reject "title must be 1-200 characters" #:http-code 400)))))

(define-record NewNote
  [title : String ::: (SafeTitle title)]
  [content : String ::: (SafeContent content)]
)

(define (tesl-codec-encode-NewNote _v)
  (error "toJson is forbidden for type NewNote: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewNote-0 _j)
  (define _fraw_title (tesl-decode-prim-field _j "title" tesl-decode-prim-string))
  (define _r1_title
    (let ([_r (checkSafeTitle _fraw_title)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_title
    (if (check-ok? _r1_title)
        (ensure-named 'title (check-ok-value _r1_title) (check-ok-facts _r1_title) (check-ok-bindings _r1_title) #:subject 'title)
        _r1_title))
  (define _fraw_content (tesl-decode-prim-field _j "content" tesl-decode-prim-string))
  (define _r1_content
    (let ([_r (checkSafeContent _fraw_content)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_content
    (if (check-ok? _r1_content)
        (ensure-named 'content (check-ok-value _r1_content) (check-ok-facts _r1_content) (check-ok-bindings _r1_content) #:subject 'content)
        _r1_content))
  (or (and (check-fail? _f_title) _f_title) (and (check-fail? _f_content) _f_content)
      (record-value 'NewNote (hash 'title _f_title 'content _f_content))))
(register-type-codec! 'NewNote tesl-codec-encode-NewNote (list tesl-codec-decode-NewNote-0))

(define-record Note
  [id : NoteId]
  [title : String]
  [content : String]
  [authorId : String]
  [createdAt : PosixMillis]
)

(define (tesl-codec-encode-Note _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'id (tesl-encode-prim-string (raw-value (hash-ref _fields 'id)))
        'title (tesl-encode-prim-string (raw-value (hash-ref _fields 'title)))
        'content (tesl-encode-prim-string (raw-value (hash-ref _fields 'content)))
        'authorId (tesl-encode-prim-string (raw-value (hash-ref _fields 'authorId)))
        'createdAt (tesl-encode-prim-posix-millis (raw-value (hash-ref _fields 'createdAt)))
  ))
(register-type-codec! 'Note tesl-codec-encode-Note (list ))

(define-auther
  (userAuth [request : HttpRequest])
  #:capabilities [noteAuth]
  #:returns (? String _entity ::: (Authenticated _entity))
  (thsl-src-control! "example/learn/lesson16-complete-notes-api.tesl" 106 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson16-complete-notes-api.tesl" 107 (list) (lambda () (reject "authentication required" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson16-complete-notes-api.tesl" 109 (list (cons 'userId userId)) (lambda () (if (> (raw-value (tesl_import_String_length (raw-value userId))) 0) (accept (Authenticated userId) #:value *userId) (reject "invalid user session" #:http-code 401)))))])))))

(define-capture noteIdCapture
  [noteId : String]
  #:parser string-segment)

(define-handler
  (createNote [user : String ::: (Authenticated user)] [body : NewNote])
  #:capabilities [noteDbWrite time]
  #:returns Note
  (let ([noteId (thsl-src! "example/learn/lesson16-complete-notes-api.tesl" 130 (list (cons 'user *user) (cons 'body *body)) (lambda () (raw-value (NoteId "note-1"))))]) (thsl-src! "example/learn/lesson16-complete-notes-api.tesl" 131 (list (cons 'noteId *noteId) (cons 'user *user) (cons 'body *body)) (lambda () (Note #:id *noteId #:title (raw-value body.title) #:content (raw-value body.content) #:authorId *user #:createdAt (raw-value (nowMillis)))))))

(define-handler
  (getNote [user : String ::: (Authenticated user)] [noteId : String])
  #:capabilities [noteDbRead]
  #:returns (Maybe Note)
  (thsl-src! "example/learn/lesson16-complete-notes-api.tesl" 138 (list (cons 'user *user) (cons 'noteId *noteId)) (lambda () (raw-value (Something (Note #:id (NoteId "note-1") #:title "example note" #:content "hello world" #:authorId *user #:createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))))))

(define NotesServer-sse-routes '())
(define-api NotesApi
  [createNote :
    (Auth [user : String ::: (Authenticated user)] #:via userAuth)
    :> "notes"
    :> (ReqBody JSON [body : NewNote])
    :> (Post JSON Note)
    ]
  [getNote :
    (Auth [user : String ::: (Authenticated user)] #:via userAuth)
    :> "notes"
    :> (Capture noteIdCapture [noteId : String])
    :> (Get JSON (Maybe Note))
    ]
)

(define-server NotesServer
  #:api NotesApi
  [createNote createNote]
  [getNote getNote]
)
