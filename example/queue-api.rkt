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
  (only-in tesl/tesl/prelude Bool List String Fact)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/queue deadJobs requeue DeadJob FromDeadQueue queueRead queueWrite pubsub)
  (only-in tesl/tesl/telemetry initTelemetry)
)


(provide EmailQueue UserEvents EmailWorkers)

(define-capability emailWrite (implies queueWrite))

(define-capability appService (implies dbRead dbWrite emailWrite pubsub))

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
  *job)

(define EmailWorkers
  (list (cons EmailQueue sendEmailWorker)))
(register-api-test-workers! (list (list EmailQueue 'SendEmail sendEmailWorker)))

(define/pow
  (listDeadEmails [q : EmailQueue])
  #:capabilities [queueRead]
  #:returns (List DeadJob)
  (raw-value (deadJobs *q)))

(define/pow
  (replayEmail [job : DeadJob ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [queueWrite]
  #:returns Boolean
  (raw-value (requeue *job)))

(module+ main
  (init-opentelemetry! #:service-name "queue-api" #:endpoint "in-memory" #:console? #f))
