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
)


(provide NotifWorkers DeadNotifWorkers)

(define-capability notifCap (implies queueRead))

(define-capability deadCap (implies queueRead pubsub))

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
  (thsl-src! "example/learn/lesson28-dead-letter-queue.tesl" 90 (list (cons 'job *job)) (lambda () (reject "notification service unavailable" #:http-code 500))))

(define NotifWorkers
  (list (cons NotifQueue notifWorker)))
(register-api-test-workers! (list (list NotifQueue 'SendNotif notifWorker)))

(define/pow
  (handleDeadNotif [job : SendNotif ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [deadCap]
  #:returns SendNotif
  (let ([_ (thsl-src! "example/learn/lesson28-dead-letter-queue.tesl" 105 (list (cons 'job *job)) (lambda () (telemetry-event! "notif.dead" #:attributes (["userId" (raw-value job.userId)]))))]) (thsl-src! "example/learn/lesson28-dead-letter-queue.tesl" 107 (list (cons 'job *job)) (lambda () *job))))

(define DeadNotifWorkers
  (list (cons NotifQueue handleDeadNotif)))
(register-api-test-dead-workers! (list (list NotifQueue 'SendNotif handleDeadNotif)))
