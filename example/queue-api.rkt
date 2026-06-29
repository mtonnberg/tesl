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
  (only-in tesl/tesl/prelude Bool List String Fact)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/queue deadJobs requeue DeadJob FromDeadQueue queueRead queueWrite pubsub)
  (only-in tesl/tesl/telemetry initTelemetry)
)


(provide EmailQueue UserEvents)

(define-capability emailWrite (implies queueWrite))

(define-capability appService (implies dbRead dbWrite emailWrite pubsub))

(define-database MainDatabase
  #:backend postgres
  #:database "app_db"
  #:user "app"
  #:password ""
  #:server "localhost"
  #:port 5432
  #:schema app
  #:entities )

(define-record SendEmail
  [to : String]
  [subject : String]
  [body : String]
)

(define-adt UserEvent
  [ProfileUpdated [bio : String]]
  [AccountDeleted]
)

(define-queue EmailQueue
  #:database MainDatabase
  #:job-types (SendEmail)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 60)

(define-channel UserEvents)

(define/pow
  (sendEmailWorker [job : SendEmail ::: (FromQueue (Id == jobId) job)])
  #:capabilities [queueRead]
  #:returns SendEmail
  (thsl-src! "example/queue-api.tesl" 76 (list (cons 'job *job)) (lambda () *job)))

(define/pow
  (listDeadEmails [q : EmailQueue])
  #:capabilities [queueRead]
  #:returns (List DeadJob)
  (thsl-src! "example/queue-api.tesl" 82 (list (cons 'q *q)) (lambda () (raw-value (deadJobs *q)))))

(define/pow
  (replayEmail [job : DeadJob ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [queueWrite]
  #:returns Boolean
  (thsl-src! "example/queue-api.tesl" 89 (list (cons 'job *job)) (lambda () (raw-value (requeue *job)))))

(define-handler
  (appRoot)
  #:returns String
  (thsl-src! "example/queue-api.tesl" 93 (list) (lambda () "ok")))

(define AppServer-sse-routes '())
(define-api AppApi
  [endpoint_0 :
    "health"
    :> (Get JSON String)
    ]
)

(define-server AppServer
  #:api AppApi
  [endpoint_0 appRoot]
)

(module+ main
  (thsl-src! "example/queue-api.tesl" 103 (list) (lambda () (with-capabilities (appService queueRead) (call-with-database MainDatabase (lambda () (let ([_ (init-opentelemetry! #:service-name "queue-api" #:endpoint "in-memory" #:console? #f)]) (begin (start-workers! EmailQueueWorkers (list queueRead)) (serve AppServer #:port 8086 #:capabilities (list appService queueRead) #:sse-routes AppServer-sse-routes)))))))))

(define EmailQueueWorkers
  (list (cons EmailQueue sendEmailWorker)))
(register-api-test-workers! (list (list EmailQueue 'SendEmail sendEmailWorker)))
