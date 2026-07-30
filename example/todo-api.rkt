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
  (only-in tesl/tesl/prelude Bool Int List Fact String Unit)
  (only-in tesl/tesl/http HttpRequest [Http.sessionToken tesl_import_Http_sessionToken])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/time nowMillis PosixMillis time)
  (only-in tesl/tesl/env env envInt envRead requireSecret)
  (only-in tesl/tesl/jwt jwt [JWT.verify tesl_import_JWT_verify])
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/int [Int.parse tesl_import_Int_parse])
  (only-in tesl/tesl/list [List.isEmpty tesl_import_List_isEmpty] [List.filterCheck tesl_import_List_filterCheck])
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/telemetry telemetry initTelemetry)
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/random random)
)


(provide TodoDatabase TodoServer resolveExamplePort seedExampleData resolveExamplePort-signature seedExampleData-signature)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/todo-api.tesl" '(192 225 232 238 250))
(define Authenticated 'Authenticated)
(define ContainsAnA 'ContainsAnA)
(define IsOpen 'IsOpen)
(define LengthLessThan30 'LengthLessThan30)
(define TitleSafe 'TitleSafe)
(define TodoId 'TodoId)
(define ValidPort 'ValidPort)

(define-capability todoDbRead (implies dbRead))

(define-capability todoDbWrite (implies dbWrite))

(define-capability todoReadHttpCookie (implies jwt envRead))

(define-capability todoWebService (implies todoDbRead todoDbWrite todoReadHttpCookie time random envRead))

(define-newtype UserId String)

(define-record User
  [id : UserId]
  [role : String]
)

(define-adt Status
  [Open]
  [Done]
)

(define-adt Status2
  [Opened [value : Integer]]
  [Finished [value : String]]
)

(define/pow
  (dostuff [x : Status2])
  #:returns Integer
  (thsl-src-control! "example/todo-api.tesl" 57 (list (cons 'x *x)) (lambda () (let ([tesl-case-0 *x]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Opened)) (let ([s (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/todo-api.tesl" 58 (list (cons 's s)) (lambda () *s)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Finished)) (thsl-src! "example/todo-api.tesl" 59 (list) (lambda () (raw-value 3)))])))))

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

(define-database TodoDatabase
  #:backend postgres
  #:database (tesl-env-raw "TESL_POSTGRES_DATABASE")
  #:user (tesl-env-raw "TESL_POSTGRES_USER")
  #:password (tesl-env-raw "TESL_POSTGRES_PASSWORD")
  #:server (tesl-env-raw "TESL_POSTGRES_HOST")
  #:port (tesl-env-int-raw "TESL_POSTGRES_PORT" 5432)
  #:schema todo_api
  #:entities Todo)

(define defaultExamplePort 8086)

(define/pow
  (generateTodoId)
  #:capabilities [random]
  #:returns String
  (thsl-src! "example/todo-api.tesl" 87 (list) (lambda () (generatePrefixedId "todo"))))

(define-checker
  (isValidPort [port : Integer])
  #:returns [port : Integer ::: (ValidPort port)]
  (thsl-src! "example/todo-api.tesl" 92 (list (cons 'port *port)) (lambda () (if (and (tesl-le? 1 *port) (tesl-le? *port 65535)) (accept (ValidPort port) #:value *port) (reject "Port must be between 1 and 65535" #:http-code 400)))))

(define-trusted
  (validPort [port : Integer])
  #:returns (Maybe (Fact (ValidPort port)))
  (thsl-src! "example/todo-api.tesl" 98 (list (cons 'port *port)) (lambda () (if (and (tesl-le? 1 *port) (tesl-le? *port 65535)) (Something (trusted-proof (ValidPort port))) Nothing))))

(define/pow
  (parsePortString [rawPort : String] [source : String])
  #:returns (? Integer _entity ::: (ValidPort _entity))
  (thsl-src-control! "example/todo-api.tesl" 104 (list (cons 'rawPort *rawPort) (cons 'source *source)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Int_parse *rawPort))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([parsedPort (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/todo-api.tesl" 105 (list (cons 'parsedPort parsedPort)) (lambda () (isValidPort parsedPort))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/todo-api.tesl" 106 (list) (lambda () (reject (format "invalid ~a port value ~a; expected an integer between 1 and 65535" (tesl-display-val *source) (tesl-display-val *rawPort)) #:http-code 400)))])))))

(define/pow
  (resolveExamplePort [teslPort : (Maybe String)] [portEnv : (Maybe String)])
  #:returns Integer
  (thsl-src-control! "example/todo-api.tesl" 109 (list (cons 'teslPort *teslPort) (cons 'portEnv *portEnv)) (lambda () (let ([tesl-case-2 *teslPort]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([port (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/todo-api.tesl" 110 (list (cons 'port port)) (lambda () (raw-value (parsePortString *port "TESL_TODO_API_PORT")))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/todo-api.tesl" 112 (list) (lambda () (let ([tesl-case-3 *portEnv]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([port (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/todo-api.tesl" 113 (list (cons 'port port)) (lambda () (raw-value (parsePortString *port "PORT")))))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/todo-api.tesl" 114 (list) (lambda () (raw-value defaultExamplePort)))]))))])))))

(define-auther
  (cookieAuth [request : HttpRequest])
  #:capabilities [todoReadHttpCookie]
  #:returns [requestUser : User ::: (Authenticated requestUser)]
  (thsl-src-control! "example/todo-api.tesl" 128 (list (cons 'request *request)) (lambda () (let ([tesl-case-4 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "example/todo-api.tesl" 129 (list) (lambda () (reject "Missing session cookie" #:http-code 401)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/todo-api.tesl" 131 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-5 (tesl_import_JWT_verify token (raw-value (requireSecret "SESSION_JWT_SECRET")))]) (let ([claims tesl-checked-5]) (let ([tesl-case-6 (raw-value (tesl_import_Dict_lookup "sub" claims))]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing)) (thsl-src! "example/todo-api.tesl" 133 (list) (lambda () (reject "Session token has no subject" #:http-code 401)))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "example/todo-api.tesl" 134 (list (cons 'userId userId)) (lambda () (accept Authenticated #:value (User #:id (UserId (raw-value userId)) #:role "user")))))])))))))])))))

(define-checker
  (isSafeTitle [title : String])
  #:returns [title : String ::: (TitleSafe title)]
  (thsl-src! "example/todo-api.tesl" 139 (list (cons 'title *title)) (lambda () (if (and (tesl-le? 4 (raw-value (tesl_import_String_length *title))) (tesl-le? (raw-value (tesl_import_String_length *title)) 120)) (accept (TitleSafe title) #:value *title) (reject "Title must be between 3 and 120 characters" #:http-code 400)))))

(define-checker
  (lengthLessThan30 [title : String])
  #:returns [title : String ::: (LengthLessThan30 title)]
  (thsl-src! "example/todo-api.tesl" 147 (list (cons 'title *title)) (lambda () (if (tesl-lt? (raw-value (tesl_import_String_length *title)) 30) (accept (LengthLessThan30 title) #:value *title) (reject "Title must be be less than 30 characters" #:http-code 400)))))

(define-checker
  (containsAnA [title : String])
  #:returns [title : String ::: (ContainsAnA title)]
  (thsl-src! "example/todo-api.tesl" 155 (list (cons 'title *title)) (lambda () (if (tesl_import_String_contains *title "a") (accept (ContainsAnA title) #:value *title) (reject "Title must contain an a." #:http-code 400)))))

(define-record NewTodo
  [title : String ::: ((TitleSafe title) && ((LengthLessThan30 title) && (ContainsAnA title)))]
)

(define (tesl-codec-encode-NewTodo _v)
  (error "toJson is forbidden for type NewTodo: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewTodo-0 _j)
  (define _fraw_title (tesl-decode-prim-field _j "title" tesl-decode-prim-string))
  (define _r1_title
    (let ([_r ((check-and isSafeTitle (check-and lengthLessThan30 containsAnA)) _fraw_title)])
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
  (thsl-src! "example/todo-api.tesl" 176 (list (cons 'todoId *todoId)) (lambda () (if (and (raw-value (tesl_import_String_startsWith *todoId "todo-")) (tesl-gt? (raw-value (tesl_import_String_length *todoId)) 5)) (accept (TodoId todoId) #:value *todoId) (reject "Malformed todo id" #:http-code 400)))))

(define-capture todoIdCapture
  [todoId : String ::: (TodoId todoId)]
  #:parser string-segment #:check isTodoId)

(define-checker
  (checkOpen [todo : Todo])
  #:returns [todo : Todo ::: (IsOpen todo)]
  (thsl-src-control! "example/todo-api.tesl" 186 (list (cons 'todo *todo)) (lambda () (let ([tesl-case-7 (tesl-dot/runtime todo 'status 'Todo)]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Open)) (thsl-src! "example/todo-api.tesl" 187 (list) (lambda () (accept (IsOpen todo) #:value *todo)))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Done)) (thsl-src! "example/todo-api.tesl" 188 (list) (lambda () (reject "todo is already completed" #:http-code 422)))])))))

(define/pow
  (seedExampleData)
  #:capabilities [todoDbRead todoDbWrite time]
  #:returns Integer
  (thsl-src! "example/todo-api.tesl" 192 (list) (lambda () (if (raw-value (tesl_import_List_isEmpty (select-many (from Todo)))) (let ([_ (insert-one! Todo (tesl-hash 'id "todo-1" 'title "Review the SQL layer" 'ownerId (raw-value (UserId "mikael")) 'status Open 'createdAt (raw-value (nowMillis))))]) (let ([_ (insert-one! Todo (tesl-hash 'id "todo-2" 'title "Sketch more DSL examples" 'ownerId (raw-value (UserId "anna")) 'status Open 'createdAt (raw-value (nowMillis))))]) (raw-value 2))) (raw-value 0)))))

(define-handler
  (listTest [requestUser : User ::: (Authenticated requestUser)] [newTodos : (List String)])
  #:capabilities [todoDbRead todoDbWrite time random]
  #:returns String
  (thsl-src! "example/todo-api.tesl" 205 (list (cons 'requestUser *requestUser) (cons 'newTodos *newTodos)) (lambda () "hej")))

(define-handler
  (createTodo [requestUser : User ::: (Authenticated requestUser)] [newTodo : NewTodo])
  #:capabilities [todoDbRead todoDbWrite time random]
  #:returns (Exists [todoId : String] (? Todo _entity ::: (FromDb (Id == todoId) _entity)))
  (let ([todoId (thsl-src! "example/todo-api.tesl" 211 (list (cons 'requestUser *requestUser) (cons 'newTodo *newTodo)) (lambda () (generateTodoId)))]) (thsl-src! "example/todo-api.tesl" 212 (list (cons 'todoId *todoId) (cons 'requestUser *requestUser) (cons 'newTodo *newTodo)) (lambda () (pack ([todoId]) (insert-one! Todo (tesl-hash 'id todoId 'title (raw-value newTodo.title) 'ownerId (raw-value requestUser.id) 'status Open 'createdAt (raw-value (nowMillis)))))))))

(define-handler
  (listMyTodos [requestUser : User ::: (Authenticated requestUser)])
  #:capabilities [todoDbRead]
  #:returns (List Todo)
  (let ([_ (thsl-src! "example/todo-api.tesl" 224 (list (cons 'requestUser *requestUser)) (lambda () (telemetry-event! "todo.list" #:attributes (["user.id" (raw-value requestUser.id)]))))]) (thsl-src! "example/todo-api.tesl" 225 (list (cons 'requestUser *requestUser)) (lambda () (select-many (from Todo) (where (==. (entity-field-ref Todo 'ownerId) (raw-value requestUser.id))))))))

(define-handler
  (listOpenTodos [requestUser : User ::: (Authenticated requestUser)])
  #:capabilities [todoDbRead]
  #:returns (List Todo)
  (let ([myTodos (thsl-src! "example/todo-api.tesl" 232 (list (cons 'requestUser *requestUser)) (lambda () (select-many (from Todo) (where (==. (entity-field-ref Todo 'ownerId) (raw-value requestUser.id))))) 'myTodos)]) (thsl-src! "example/todo-api.tesl" 233 (list (cons 'myTodos *myTodos) (cons 'requestUser *requestUser)) (lambda () (tesl_import_List_filterCheck checkOpen (raw-value myTodos))))))

(define-handler
  (getTodo [requestUser : User ::: (Authenticated requestUser)] [todoId : String ::: (TodoId todoId)])
  #:capabilities [todoDbRead]
  #:returns (? Todo _entity ::: (FromDb (Id == todoId) _entity))
  (let ([existing (thsl-src! "example/todo-api.tesl" 238 (list (cons 'requestUser *requestUser) (cons 'todoId *todoId)) (lambda () (let ([tesl_match (select-one (from Todo) (where (==. (entity-field-ref Todo 'id) todoId)))]) (if tesl_match (Something tesl_match) Nothing))) 'existing)]) (thsl-src-control! "example/todo-api.tesl" 239 (list (cons 'existing *existing) (cons 'requestUser *requestUser) (cons 'todoId *todoId)) (lambda () (let ([tesl-case-8 (raw-value existing)]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing)) (thsl-src! "example/todo-api.tesl" 241 (list) (lambda () (reject "Todo not found" #:http-code 404)))] [(and (and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something)) (let ([todo (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (not (tesl-equal? (raw-value todo.ownerId) (raw-value requestUser.id))))) (let ([todo (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "example/todo-api.tesl" 243 (list (cons 'todo todo)) (lambda () (reject "Todo not owned by request user" #:http-code 403))))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something)) (let ([todo (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "example/todo-api.tesl" 245 (list (cons 'todo todo)) (lambda () todo)))]))))))

(define-handler
  (completeTodo [requestUser : User ::: (Authenticated requestUser)] [todoId : String ::: (TodoId todoId)])
  #:capabilities [todoDbRead todoDbWrite]
  #:returns (? Todo _entity ::: (FromDb (Id == todoId) _entity))
  (let ([existing (thsl-src! "example/todo-api.tesl" 250 (list (cons 'requestUser *requestUser) (cons 'todoId *todoId)) (lambda () (let ([tesl_match (select-one (from Todo) (where (==. (entity-field-ref Todo 'id) todoId)))]) (if tesl_match (Something tesl_match) Nothing))) 'existing)]) (thsl-src-control! "example/todo-api.tesl" 251 (list (cons 'existing *existing) (cons 'requestUser *requestUser) (cons 'todoId *todoId)) (lambda () (let ([tesl-case-9 (raw-value existing)]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing)) (thsl-src! "example/todo-api.tesl" 253 (list) (lambda () (reject "Todo not found" #:http-code 404)))] [(and (and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something)) (let ([todo (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (not (tesl-equal? (raw-value todo.ownerId) (raw-value requestUser.id))))) (let ([todo (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (thsl-src! "example/todo-api.tesl" 255 (list (cons 'todo todo)) (lambda () (reject "Todo not owned by request user" #:http-code 403))))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something)) (thsl-src! "example/todo-api.tesl" 257 (list) (lambda () (car (update-many! (from Todo) (tesl-hash (entity-field-ref Todo 'status) Done) (where (==. (entity-field-ref Todo 'id) todoId))))))]))))))

(define TodoServer-sse-routes '())
(define-api TodoApi
  [listTest :
    (Auth [requestUser : User ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "list-test"
    :> (ReqBody JSON [newTodos : (List String)])
    :> (Post JSON String)
    ]
  [createTodo :
    (Auth [requestUser : User ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "todos"
    :> (ReqBody JSON [newTodo : NewTodo])
    :> (Post JSON (Exists [todoId : String] (? Todo _entity ::: (FromDb (Id == todoId) _entity))))
    ]
  [listMyTodos :
    (Auth [requestUser : User ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "todos"
    :> "mine"
    :> (Get JSON (List Todo))
    ]
  [listOpenTodos :
    (Auth [requestUser : User ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "todos"
    :> "mine"
    :> "open"
    :> (Get JSON (List Todo))
    ]
  [getTodo :
    (Auth [requestUser : User ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "todos"
    :> (Capture todoIdCapture [todoId : String ::: (TodoId todoId)])
    :> (Get JSON (? Todo _entity ::: (FromDb (Id == todoId) _entity)))
    ]
  [completeTodo :
    (Auth [requestUser : User ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "todos"
    :> (Capture todoIdCapture [todoId : String ::: (TodoId todoId)])
    :> "complete"
    :> (Put JSON (? Todo _entity ::: (FromDb (Id == todoId) _entity)))
    ]
)

(define-server TodoServer
  #:api TodoApi
  [listTest listTest]
  [createTodo createTodo]
  [listMyTodos listMyTodos]
  [listOpenTodos listOpenTodos]
  [getTodo getTodo]
  [completeTodo completeTodo]
)

(module+ main
  (thsl-src! "example/todo-api.tesl" 301 (list) (lambda () (with-capabilities (todoWebService) (call-with-database TodoDatabase (lambda () (let ([_ (init-opentelemetry! #:service-name "todo-api" #:endpoint "in-memory" #:console? #t)]) (let ([port (resolveExamplePort (raw-value (env "TESL_TODO_API_PORT")) (raw-value (env "PORT")))]) (let ([_ (seedExampleData)]) (serve TodoServer #:port port #:capabilities (list todoWebService) #:sse-routes TodoServer-sse-routes))))))))))
