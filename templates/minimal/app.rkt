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
  (only-in tesl/tesl/prelude Bool Int String)
  (only-in tesl/tesl/http HttpRequest [Http.sessionToken tesl_import_Http_sessionToken])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/telemetry telemetry initTelemetry)
  (only-in tesl/tesl/env envInt envRead requireSecret)
  (only-in tesl/tesl/jwt jwt [JWT.verify tesl_import_JWT_verify])
)


(provide AppServer)

(define Authenticated 'Authenticated)
(define Positive 'Positive)

(define-capability readSessionCookie (implies jwt))

(define-record SessionUser
  [id : String]
  [role : String]
)

(define defaultPort 8088)

(define-database AppDatabase
  #:backend memory
  #:entities )

(define-checker
  (isPositive [taskId : Integer])
  #:returns [taskId : Integer ::: (Positive taskId)]
  (thsl-src! "templates/minimal/app.tesl" 49 (list (cons 'taskId *taskId)) (lambda () (if (tesl-gt? *taskId 0) (accept (Positive taskId) #:value *taskId) (reject "Task id must be positive" #:http-code 400)))))

(define-auther
  (cookieAuth [request : HttpRequest])
  #:capabilities [readSessionCookie envRead]
  #:returns [requestUser : SessionUser ::: (Authenticated requestUser)]
  (thsl-src-control! "templates/minimal/app.tesl" 81 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "templates/minimal/app.tesl" 82 (list) (lambda () (reject "Missing session cookie" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "templates/minimal/app.tesl" 84 (list (cons 'token token)) (lambda () (let ([claims (raw-value (tesl_import_JWT_verify (raw-value token) (raw-value (requireSecret "SESSION_JWT_SECRET"))))]) (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "sub" (raw-value claims)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "templates/minimal/app.tesl" 86 (list) (lambda () (reject "Session token has no subject" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "templates/minimal/app.tesl" 88 (list (cons 'userId userId)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "role" (raw-value claims)))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([role (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "templates/minimal/app.tesl" 89 (list (cons 'role role)) (lambda () (accept Authenticated #:value (SessionUser #:id *userId #:role *role)))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "templates/minimal/app.tesl" 90 (list) (lambda () (accept Authenticated #:value (SessionUser #:id *userId #:role "user"))))])))))]))))))])))))

(define-capture positiveTaskCapture
  [taskId : Integer ::: (Positive taskId)]
  #:parser integer-segment #:check isPositive)

(define-handler
  (getTask [requestUser : SessionUser ::: (Authenticated requestUser)] [taskId : Integer ::: (Positive taskId)])
  #:returns (? Integer _entity ::: (Positive _entity))
  (let ([_ (thsl-src! "templates/minimal/app.tesl" 104 (list (cons 'requestUser *requestUser) (cons 'taskId *taskId)) (lambda () (telemetry-event! "task.fetch" #:attributes (["user.id" (raw-value requestUser.id)] ["task.id" *taskId]))))]) (thsl-src! "templates/minimal/app.tesl" 107 (list (cons 'requestUser *requestUser) (cons 'taskId *taskId)) (lambda () taskId))))

(define AppServer-sse-routes '())
(define-api AppApi
  [getTask :
    (Auth [requestUser : SessionUser ::: (Authenticated requestUser)] #:via cookieAuth)
    :> "tasks"
    :> (Capture positiveTaskCapture [taskId : Integer ::: (Positive taskId)])
    :> (Get JSON (? Integer _entity ::: (Positive _entity)))
    ]
)

(define-server AppServer
  #:api AppApi
  [getTask getTask]
)

(module+ main
  (thsl-src! "templates/minimal/app.tesl" 120 (list) (lambda () (with-capabilities (readSessionCookie envRead) (call-with-database AppDatabase (lambda () (let ([_ (init-opentelemetry! #:service-name "__APP_NAME__" #:endpoint "in-memory" #:console? #t)]) (let ([port (raw-value (envInt "PORT" (raw-value defaultPort)))]) (serve AppServer #:port port #:capabilities (list readSessionCookie envRead) #:sse-routes AppServer-sse-routes)))))))))
