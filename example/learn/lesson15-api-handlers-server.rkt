#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool Int String)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
)


(provide TaskServer)

(define Authenticated 'Authenticated)
(define ValidPriority 'ValidPriority)

(define-capability taskDbRead (implies dbRead))

(define-capability taskDbWrite (implies dbWrite))

(define-record NewTask
  [title : String]
  [priority : Integer]
)

(define-record Task
  [id : String]
  [title : String]
  [priority : Integer]
  [done : Boolean]
)

(define (tesl-codec-encode-NewTask _v)
  (error "toJson is forbidden for type NewTask: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewTask-0 _j)
  (define _f_title (tesl-codec-decode-field _j "title" tesl-json-string-codec))
  (define _f_priority (tesl-codec-decode-field _j "priority" tesl-json-int-codec))
  (record-value 'NewTask (hash 'title _f_title 'priority _f_priority)))
(register-type-codec! 'NewTask tesl-codec-encode-NewTask (list tesl-codec-decode-NewTask-0))

(define (tesl-codec-encode-Task _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'id (tesl-codec-encode-field (raw-value (hash-ref _fields 'id)) tesl-json-string-codec)
        'title (tesl-codec-encode-field (raw-value (hash-ref _fields 'title)) tesl-json-string-codec)
        'priority (tesl-codec-encode-field (raw-value (hash-ref _fields 'priority)) tesl-json-int-codec)
        'done (tesl-codec-encode-field (raw-value (hash-ref _fields 'done)) tesl-json-bool-codec)
  ))
(register-type-codec! 'Task tesl-codec-encode-Task (list ))

(define-checker
  (validatePriority [p : Integer])
  #:returns [p : Integer ::: (ValidPriority p)]
  (if (and (>= *p 1) (<= *p 5)) (accept (ValidPriority p) #:value *p) (reject "priority must be 1-5" #:http-code 400)))

(define-auther
  (cookieAuth [request : HttpRequest])
  #:returns [user : String ::: (Authenticated user)]
  (let ([tesl_case_0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (reject "not authenticated" #:http-code 401)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (accept (Authenticated userId) #:value *userId))])))

(define-capture taskIdCapture
  [id : String]
  #:parser string-segment)

(define-handler
  (createTask [user : String ::: (Authenticated user)] [body : NewTask])
  #:capabilities [taskDbWrite]
  #:returns Task
  (Task #:id "task-1" #:title (raw-value body.title) #:priority (raw-value body.priority) #:done #f))

(define-handler
  (getTask [user : String ::: (Authenticated user)] [id : String])
  #:capabilities [taskDbRead]
  #:returns (Maybe Task)
  (raw-value (Something (Task #:id *id #:title "example task" #:priority 3 #:done #f))))

(define TaskServer-sse-routes '())
(define-api TaskApi
  [createTask :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "tasks"
    :> (ReqBody JSON [body : NewTask])
    :> (Post JSON Task)
    ]
  [getTask :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "tasks"
    :> (Capture taskIdCapture [id : String])
    :> (Get JSON (Maybe Task))
    ]
)

(define-server TaskServer
  #:api TaskApi
  [createTask createTask]
  [getTask getTask]
)
