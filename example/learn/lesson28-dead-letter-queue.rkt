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
  (only-in tesl/tesl/queue FromQueue FromDeadQueue queueRead pubsub)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide NotifQueue)

(define-capability notifCap (implies queueRead))

(define-capability deadCap (implies queueRead pubsub))

(define-capability appService (implies queueRead))

(define-record SendNotif
  [userId : String]
  [message : String]
)

(define-database FakeDb
  #:backend postgres
  #:database "notif_db"
  #:user "notif"
  #:password ""
  #:server "localhost"
  #:port 5432
  #:schema notifications
  #:entities )

(define-queue NotifQueue
  #:database FakeDb
  #:job-types (SendNotif)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 30)

(define/pow
  (notifWorker [job : SendNotif ::: (FromQueue (Id == jobId) job)])
  #:capabilities [notifCap]
  #:returns SendNotif
  (thsl-src! "example/learn/lesson28-dead-letter-queue.tesl" 104 (list (cons 'job *job)) (lambda () (reject "notification service unavailable" #:http-code 500))))

(define/pow
  (handleDeadNotif [job : SendNotif ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [deadCap]
  #:returns SendNotif
  (let ([_ (thsl-src! "example/learn/lesson28-dead-letter-queue.tesl" 115 (list (cons 'job *job)) (lambda () (telemetry-event! "notif.dead" #:attributes (["userId" (raw-value job.userId)]))))]) (thsl-src! "example/learn/lesson28-dead-letter-queue.tesl" 117 (list (cons 'job *job)) (lambda () *job))))

(define-handler
  (appRoot)
  #:returns String
  (thsl-src! "example/learn/lesson28-dead-letter-queue.tesl" 126 (list) (lambda () "ok")))

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
  (thsl-src! "example/learn/lesson28-dead-letter-queue.tesl" 141 (list) (lambda () (with-capabilities (appService notifCap deadCap) (call-with-database FakeDb (lambda () (begin (start-workers! NotifQueueWorkers (list notifCap deadCap)) (begin (start-dead-workers! NotifQueueDeadWorkers (list notifCap deadCap)) (serve AppServer #:port 8086 #:capabilities (list appService notifCap deadCap) #:sse-routes AppServer-sse-routes)))))))))

(define NotifQueueWorkers
  (list (cons NotifQueue notifWorker)))
(register-api-test-workers! (list (list NotifQueue 'SendNotif notifWorker)))

(define NotifQueueDeadWorkers
  (list (cons NotifQueue handleDeadNotif)))
(register-api-test-dead-workers! (list (list NotifQueue 'SendNotif handleDeadNotif)))
