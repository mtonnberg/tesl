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
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/telemetry telemetry initTelemetry)
)


(provide AdminTaskServer)

(define Authenticated 'Authenticated)
(define Positive 'Positive)

(define-capability readTaskCookie)

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
  (hash 'id (tesl-encode-prim-int (raw-value (hash-ref _fields 'id)))
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
  (thsl-src! "example/admin-task-api.tesl" 44 (list (cons 'taskId *taskId)) (lambda () (if (> *taskId 0) (accept (Positive taskId) #:value *taskId) (reject "Task id must be positive" #:http-code 400)))))

(define-auther
  (cookieUserAuth [request : HttpRequest])
  #:capabilities [readTaskCookie]
  #:returns [requestUser : AdminUser ::: (Authenticated requestUser)]
  (thsl-src-control! "example/admin-task-api.tesl" 53 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/admin-task-api.tesl" 54 (list) (lambda () (reject "Missing user cookie" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/admin-task-api.tesl" 56 (list (cons 'userId userId)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "role" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([role (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/admin-task-api.tesl" 57 (list (cons 'role role)) (lambda () (accept Authenticated #:value (AdminUser #:id *userId #:role *role)))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/admin-task-api.tesl" 58 (list) (lambda () (accept Authenticated #:value (AdminUser #:id *userId #:role "user"))))])))))])))))

(define-capture positiveTaskCapture
  [taskId : Integer ::: (Positive taskId)]
  #:parser integer-segment #:check isPositive)

(define-handler
  (getAdminTask [requestUser : AdminUser ::: (Authenticated requestUser)] [taskId : Integer ::: (Positive taskId)])
  #:returns AdminTask
  (thsl-src! "example/admin-task-api.tesl" 63 (list (cons 'requestUser *requestUser) (cons 'taskId *taskId)) (lambda () (if (equal? (raw-value requestUser.role) "admin") (begin (telemetry-event! "task.fetch.admin" #:attributes (["user.id" (raw-value requestUser.id)] ["task.id" *taskId])) (if (equal? *taskId 2) (AdminTask #:id *taskId #:title "Review audit log" #:ownerId "anna") (reject "Task not found" #:http-code 404))) (reject "Admin role required" #:http-code 403)))))

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
  (thsl-src! "example/admin-task-api.tesl" 83 (list) (lambda () (with-capabilities (readTaskCookie) (call-with-database AdminTaskDatabase (lambda () (let ([_ (init-opentelemetry! #:service-name "admin-task-api" #:endpoint "in-memory" #:console? #t)]) (serve AdminTaskServer #:port defaultExamplePort #:capabilities (list readTaskCookie) #:sse-routes AdminTaskServer-sse-routes))))))))
