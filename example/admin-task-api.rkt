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
  (only-in tesl/tesl/prelude Bool Int String Unit)
  (only-in tesl/tesl/http HttpRequest [Http.sessionToken tesl_import_Http_sessionToken])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/telemetry telemetry initTelemetry)
  (only-in tesl/tesl/env requireSecret envRead)
  (only-in tesl/tesl/jwt jwt [JWT.verify tesl_import_JWT_verify])
)


(provide AdminTaskServer)

(define Authenticated 'Authenticated)
(define Positive 'Positive)

(define-capability readTaskCookie (implies jwt envRead))

(define-record AdminUser
  [id : String]
  [role : String]
)

(define-record AdminTask
  [id : Integer]
  [title : String]
  [ownerId : String]
)

(define (tesl-codec-encode-AdminTask _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'id (tesl-encode-prim-int (raw-value (hash-ref _fields 'id)))
        'title (tesl-encode-prim-string (raw-value (hash-ref _fields 'title)))
        'ownerId (tesl-encode-prim-string (raw-value (hash-ref _fields 'ownerId)))
  ))
(register-type-codec! 'AdminTask tesl-codec-encode-AdminTask (list ))

(define-database AdminTaskDatabase
  #:backend memory
  #:entities )

(define defaultExamplePort 8088)

(define-checker
  (isPositive [taskId : Integer])
  #:returns [taskId : Integer ::: (Positive taskId)]
  (thsl-src! "example/admin-task-api.tesl" 48 (list (cons 'taskId *taskId)) (lambda () (if (tesl-gt? *taskId 0) (accept (Positive taskId) #:value *taskId) (reject "Task id must be positive" #:http-code 400)))))

(define-auther
  (cookieUserAuth [request : HttpRequest])
  #:capabilities [readTaskCookie]
  #:returns [requestUser : AdminUser ::: (Authenticated requestUser)]
  (thsl-src-control! "example/admin-task-api.tesl" 70 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Http_sessionToken *request))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/admin-task-api.tesl" 71 (list) (lambda () (reject "Missing session cookie" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([token (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/admin-task-api.tesl" 73 (list (cons 'token token)) (lambda () (let/check ([tesl-checked-1 (tesl_import_JWT_verify token (raw-value (requireSecret "SESSION_JWT_SECRET")))]) (let ([claims tesl-checked-1]) (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "sub" claims))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/admin-task-api.tesl" 75 (list) (lambda () (reject "Session token has no subject" #:http-code 401)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/admin-task-api.tesl" 77 (list (cons 'userId userId)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_Dict_lookup "role" claims))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([role (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/admin-task-api.tesl" 78 (list (cons 'role role)) (lambda () (accept Authenticated #:value (AdminUser #:id *userId #:role *role)))))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/admin-task-api.tesl" 79 (list) (lambda () (accept Authenticated #:value (AdminUser #:id *userId #:role "user"))))])))))])))))))])))))

(define-capture positiveTaskCapture
  [taskId : Integer ::: (Positive taskId)]
  #:parser integer-segment #:check isPositive)

(define-handler
  (getAdminTask [requestUser : AdminUser ::: (Authenticated requestUser)] [taskId : Integer ::: (Positive taskId)])
  #:returns AdminTask
  (thsl-src! "example/admin-task-api.tesl" 84 (list (cons 'requestUser *requestUser) (cons 'taskId *taskId)) (lambda () (if (tesl-equal? (raw-value (tesl-dot/runtime requestUser 'role 'AdminUser)) "admin") (begin (telemetry-event! "task.fetch.admin" #:attributes (["user.id" (tesl-dot/runtime requestUser 'id 'AdminUser)] ["task.id" *taskId])) (if (tesl-equal? *taskId 2) (AdminTask #:id *taskId #:title "Review audit log" #:ownerId "anna") (reject "Task not found" #:http-code 404))) (reject "Admin role required" #:http-code 403)))))

(define AdminTaskServer-sse-routes '())
(define-api AdminTaskApi
  [getAdminTask :
    (Auth [requestUser : AdminUser ::: (Authenticated requestUser)] #:via cookieUserAuth)
    :> "tasks"
    :> "admin"
    :> (Capture positiveTaskCapture [taskId : Integer ::: (Positive taskId)])
    :> (Get JSON AdminTask)
    ]
)

(define-server AdminTaskServer
  #:api AdminTaskApi
  [getAdminTask getAdminTask]
)

(module+ main
  (thsl-src! "example/admin-task-api.tesl" 104 (list) (lambda () (with-capabilities (readTaskCookie) (call-with-database AdminTaskDatabase (lambda () (let ([_ (init-opentelemetry! #:service-name "admin-task-api" #:endpoint "in-memory" #:console? #t)]) (serve AdminTaskServer #:port defaultExamplePort #:capabilities (list readTaskCookie) #:sse-routes AdminTaskServer-sse-routes))))))))
