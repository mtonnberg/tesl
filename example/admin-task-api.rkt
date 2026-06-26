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
  (hash 'id (tesl-codec-encode-field (raw-value (hash-ref _fields 'id)) tesl-json-int-codec)
        'title (tesl-codec-encode-field (raw-value (hash-ref _fields 'title)) tesl-json-string-codec)
        'ownerId (tesl-codec-encode-field (raw-value (hash-ref _fields 'ownerId)) tesl-json-string-codec)
  ))
(register-type-codec! 'AdminTask tesl-codec-encode-AdminTask (list ))

(define defaultExamplePort 8088)

(define-checker
  (isPositive [taskId : Integer])
  #:returns [taskId : Integer ::: (Positive taskId)]
  (thsl-src! "example/admin-task-api.tesl" 37 (list (cons 'taskId *taskId)) (lambda () (if (> *taskId 0) (accept (Positive taskId) #:value *taskId) (reject "Task id must be positive" #:http-code 400)))))

(define-auther
  (cookieUserAuth [request : HttpRequest])
  #:capabilities [readTaskCookie]
  #:returns [requestUser : AdminUser ::: (Authenticated requestUser)]
  (thsl-src! "example/admin-task-api.tesl" 46 (list (cons 'request *request)) (lambda () (let ([tesl_case_0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (reject "Missing user cookie" #:http-code 401)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (let ([tesl_case_1 (raw-value (tesl_import_Dict_lookup "role" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([role (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (accept Authenticated #:value (AdminUser #:id *userId #:role *role)))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (accept Authenticated #:value (AdminUser #:id *userId #:role "user"))])))])))))

(define-capture positiveTaskCapture
  [taskId : Integer ::: (Positive taskId)]
  #:parser integer-segment #:check isPositive)

(define-handler
  (getAdminTask [requestUser : AdminUser ::: (Authenticated requestUser)] [taskId : Integer ::: (Positive taskId)])
  #:returns AdminTask
  (thsl-src! "example/admin-task-api.tesl" 56 (list (cons 'requestUser *requestUser) (cons 'taskId *taskId)) (lambda () (if (equal? (raw-value requestUser.role) "admin") (begin (telemetry-event! "task.fetch.admin" #:attributes (["user.id" (raw-value requestUser.id)] ["task.id" *taskId])) (if (equal? *taskId 2) (AdminTask #:id *taskId #:title "Review audit log" #:ownerId "anna") (reject "Task not found" #:http-code 404))) (reject "Admin role required" #:http-code 403)))))

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
  (let ([_ (thsl-src! "example/admin-task-api.tesl" 77 (list) (lambda () (init-opentelemetry! #:service-name "admin-task-api" #:endpoint "in-memory" #:console? #t)))])
  (thsl-src! "example/admin-task-api.tesl" 78 (list) (lambda () (serve AdminTaskServer #:port defaultExamplePort #:capabilities (list readTaskCookie) #:sse-routes AdminTaskServer-sse-routes)))))
