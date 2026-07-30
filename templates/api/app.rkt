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
  (only-in tesl/tesl/prelude Bool Int List String)
  (only-in tesl/tesl/http HttpRequest [Http.sessionToken tesl_import_Http_sessionToken])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/time nowMillis PosixMillis time)
  (only-in tesl/tesl/env env envInt envRead requireSecret)
  (only-in tesl/tesl/jwt jwt [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/list [List.isEmpty tesl_import_List_isEmpty])
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/telemetry telemetry initTelemetry)
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/random random)
)


(provide AppDatabase AppServer seedExampleData seedExampleData-signature)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "templates/api/app.tesl" '(156 186))
(define Authenticated 'Authenticated)
(define TitleSafe 'TitleSafe)
(define TodoId 'TodoId)

(define-capability appDbRead (implies dbRead))

(define-capability appDbWrite (implies dbWrite))

(define-capability appReadCookie (implies jwt))

(define-capability appWebService (implies appDbRead appDbWrite appReadCookie time random))

(define-newtype UserId String)

(define-record User
  [id : UserId]
  [role : String]
)

(define-adt Status
  [Open]
  [Done]
)

(define-entity Todo
  #:source (make-hash)
  #:table todos
  #:primary-key id
  [Id id : String]
  [Title title : String]
  [OwnerId ownerId : UserId #:db-type text]
  [Status status : Status]
  [CreatedAt createdAt : PosixMillis]
)

(define-database AppDatabase
  #:backend postgres
  #:database (tesl-env-raw "TESL_POSTGRES_DATABASE")
  #:user (tesl-env-raw "TESL_POSTGRES_USER")
  #:password (tesl-env-raw "TESL_POSTGRES_PASSWORD")
  #:server (tesl-env-raw "TESL_POSTGRES_HOST")
  #:port (tesl-env-int-raw "TESL_POSTGRES_PORT" 5432)
  #:schema app
  #:entities Todo)

(define defaultPort 8086)

(define/pow
  (generateTodoId)
  #:capabilities [random]
  #:returns String
  (thsl-src! "templates/api/app.tesl" 81 (list) (lambda () (generatePrefixedId "todo"))))

(define-auther
  (cookieAuth [request : HttpRequest])
  #:capabilities [appReadCookie envRead]
  #:returns [requestUser : User ::: (Authenticated requestUser)]
  (thsl-src-control! "templates/api/app.tesl" 110 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "templates/api/app.tesl" 111 (list) (lambda () (reject "Missing session cookie" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "templates/api/app.tesl" 113 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-1 (tesl_import_JWT_verify token (raw-value (requireSecret "SESSION_JWT_SECRET")))]) (let ([claims tesl-checked-1]) (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "sub" claims))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "templates/api/app.tesl" 115 (list) (lambda () (reject "Session token has no subject" #:http-code 401)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "templates/api/app.tesl" 116 (list (cons 'userId userId)) (lambda () (accept Authenticated #:value (User #:id (UserId (raw-value userId)) #:role "user")))))])))))))])))))

(define-checker
  (isSafeTitle [title : String])
  #:returns [title : String ::: (TitleSafe title)]
  (thsl-src! "templates/api/app.tesl" 126 (list (cons 'title *title)) (lambda () (if (and (tesl-le? 4 (raw-value (tesl_import_String_length *title))) (tesl-le? (raw-value (tesl_import_String_length *title)) 120)) (accept (TitleSafe title) #:value *title) (reject "Title must be between 4 and 120 characters" #:http-code 400)))))

(define-record NewTodo
  [title : String ::: (TitleSafe title)]
)

(define (tesl-codec-encode-NewTodo _v)
  (error "toJson is forbidden for type NewTodo: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewTodo-0 _j)
  (define _fraw_title (tesl-decode-prim-field _j "title" tesl-decode-prim-string))
  (define _r1_title
    (let ([_r (isSafeTitle _fraw_title)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_title
    (if (check-ok? _r1_title)
        (ensure-named 'title (check-ok-value _r1_title) (check-ok-facts _r1_title) (check-ok-bindings _r1_title) #:subject 'title)
        _r1_title))
  (or (and (check-fail? _f_title) _f_title)
      (record-value 'NewTodo (tesl-hash 'title _f_title))))
(register-type-codec! 'NewTodo tesl-codec-encode-NewTodo (list tesl-codec-decode-NewTodo-0))

(define-checker
  (isTodoId [todoId : String])
  #:returns [todoId : String ::: (TodoId todoId)]
  (thsl-src! "templates/api/app.tesl" 147 (list (cons 'todoId *todoId)) (lambda () (if (tesl-gt? (raw-value (tesl_import_String_length *todoId)) 5) (accept (TodoId todoId) #:value *todoId) (reject "Malformed todo id" #:http-code 400)))))

(define-capture todoIdCapture
  [todoId : String ::: (TodoId todoId)]
  #:parser string-segment #:check isTodoId)

(define/pow
  (seedExampleData)
  #:capabilities [appDbRead appDbWrite time]
  #:returns Integer
  (thsl-src! "templates/api/app.tesl" 156 (list) (lambda () (if (raw-value (tesl_import_List_isEmpty (select-many (from Todo)))) (let ([_ (insert-one! Todo (tesl-hash 'id "todo-1" 'title "Read the Tesl tutorial" 'ownerId (raw-value (UserId "demo")) 'status Open 'createdAt (raw-value (nowMillis))))]) (raw-value 1)) (raw-value 0)))))

(define-handler
  (createTodo [requestUser : User ::: (Authenticated requestUser)] [newTodo : NewTodo])
  #:capabilities [appDbRead appDbWrite time random]
  #:returns (Exists [todoId : String] (? Todo _entity ::: (FromDb (Id == todoId) _entity)))
  (let ([todoId (thsl-src! "templates/api/app.tesl" 166 (list (cons 'requestUser *requestUser) (cons 'newTodo *newTodo)) (lambda () (generateTodoId)))]) (thsl-src! "templates/api/app.tesl" 167 (list (cons 'todoId *todoId) (cons 'requestUser *requestUser) (cons 'newTodo *newTodo)) (lambda () (pack ([todoId]) (insert-one! Todo (tesl-hash 'id todoId 'title (raw-value newTodo.title) 'ownerId (raw-value requestUser.id) 'status Open 'createdAt (raw-value (nowMillis)))))))))

(define-handler
  (getTodo [requestUser : User ::: (Authenticated requestUser)] [todoId : String ::: (TodoId todoId)])
  #:capabilities [appDbRead]
  #:returns (? Todo _entity ::: (FromDb (Id == todoId) _entity))
  (let ([_ (thsl-src! "templates/api/app.tesl" 185 (list (cons 'requestUser *requestUser) (cons 'todoId *todoId)) (lambda () (telemetry-event! "todo.get" #:attributes (["user.id" (raw-value requestUser.id)]))))]) (let ([existing (thsl-src! "templates/api/app.tesl" 186 (list (cons 'requestUser *requestUser) (cons 'todoId *todoId)) (lambda () (let ([tesl_match (select-one (from Todo) (where (==. (entity-field-ref Todo 'id) todoId)))]) (if tesl_match (Something tesl_match) Nothing))) 'existing)]) (thsl-src-control! "templates/api/app.tesl" 187 (list (cons 'existing *existing) (cons 'requestUser *requestUser) (cons 'todoId *todoId)) (lambda () (let ([tesl-case-3 (raw-value existing)]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "templates/api/app.tesl" 189 (list) (lambda () (reject "Todo not found" #:http-code 404)))] [(and (and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([todo (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (not (tesl-equal? (raw-value todo.ownerId) (raw-value requestUser.id))))) (let ([todo (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "templates/api/app.tesl" 191 (list (cons 'todo todo)) (lambda () (reject "Todo not owned by request user" #:http-code 403))))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([todo (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "templates/api/app.tesl" 193 (list (cons 'todo todo)) (lambda () todo)))])))))))

(define AppServer-sse-routes '())
(define-api AppApi
  [createTodo :
    (Auth [requestUser : User ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "todos"
    :> (ReqBody JSON [newTodo : NewTodo])
    :> (Post JSON (Exists [todoId : String] (? Todo _entity ::: (FromDb (Id == todoId) _entity))))
    ]
  [getTodo :
    (Auth [requestUser : User ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "todos"
    :> (Capture todoIdCapture [todoId : String ::: (TodoId todoId)])
    :> (Get JSON (? Todo _entity ::: (FromDb (Id == todoId) _entity)))
    ]
)

(define-server AppServer
  #:api AppApi
  [createTodo createTodo]
  [getTodo getTodo]
)

(module+ main
  (thsl-src! "templates/api/app.tesl" 226 (list) (lambda () (with-capabilities (appWebService envRead) (call-with-database AppDatabase (lambda () (let ([_ (init-opentelemetry! #:service-name "__APP_NAME__" #:endpoint "in-memory" #:console? #t)]) (let ([port (raw-value (envInt "PORT" (raw-value defaultPort)))]) (let ([_ (seedExampleData)]) (serve AppServer #:port port #:capabilities (list appWebService envRead) #:sse-routes AppServer-sse-routes))))))))))

(module+ test
  (require rackunit)
  (test-case "title length boundary"
    (call-with-fresh-memory-db (list AppDatabase) (lambda ()
  (check-true (thsl-src! "templates/api/app.tesl" 217 (list) (lambda () (tesl-ge? (raw-value (tesl_import_String_length "Read the Tesl tutorial")) 4))))
  (check-true (thsl-src! "templates/api/app.tesl" 218 (list) (lambda () (tesl-lt? (raw-value (tesl_import_String_length "abc")) 4))))
    ))
  )

  (test-case "todo id shape"
    (call-with-fresh-memory-db (list AppDatabase) (lambda ()
  (check-true (thsl-src! "templates/api/app.tesl" 222 (list) (lambda () (tesl-gt? (raw-value (tesl_import_String_length "todo-1")) 5))))
  (check-true (thsl-src! "templates/api/app.tesl" 223 (list) (lambda () (tesl-le? (raw-value (tesl_import_String_length "x")) 5))))
    ))
  )

)
