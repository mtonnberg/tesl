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
  (only-in tesl/tesl/prelude String Unit)
  (only-in tesl/tesl/queue FromQueue FromDeadQueue queueRead queueWrite)
)


(provide EmailWorkers DeadEmailWorkers ConcurrencyServer)

(define-capability emailCap (implies queueRead))

(define-capability enqueueEmail (implies queueWrite))

(define-capability deadEmailCap (implies queueRead))

(define-capability fullService (implies emailCap enqueueEmail))

(define-record EmailJob
  [recipientId : String]
  [subject : String]
  [body : String]
)

(define-queue EmailQueue
  #:database EmailDatabase
  #:job-types (EmailJob)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 10)

(define-database EmailDatabase
  #:backend postgres
  #:database (tesl-env-raw "LESSON31_DB")
  #:user (tesl-env-raw "TESL_POSTGRES_USER")
  #:password (tesl-env-raw "TESL_POSTGRES_PASSWORD")
  #:server (tesl-env-raw "TESL_POSTGRES_HOST")
  #:port (tesl-env-int-raw "TESL_POSTGRES_PORT" 5432)
  #:socket (tesl-env-raw "TESL_POSTGRES_SOCKET")
  #:schema lesson31
  #:entities )

(define/pow
  (processEmail [job : EmailJob ::: (FromQueue (Id == jobId) job)])
  #:capabilities [emailCap]
  #:returns EmailJob
  (begin (telemetry-event! "email.sent" #:attributes (["recipient" (raw-value job.recipientId)] ["subject" (raw-value job.subject)])) *job))

(define EmailWorkers
  (list (cons EmailQueue processEmail)))
(register-api-test-workers! (list (list EmailQueue 'EmailJob processEmail)))

(define/pow
  (handleDeadEmail [job : EmailJob ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [deadEmailCap]
  #:returns EmailJob
  (begin (telemetry-event! "email.dead" #:attributes (["recipient" (raw-value job.recipientId)] ["subject" (raw-value job.subject)])) *job))

(define DeadEmailWorkers
  (list (cons EmailQueue handleDeadEmail)))
(register-api-test-dead-workers! (list (list EmailQueue 'EmailJob handleDeadEmail)))

(define-handler
  (sendWelcomeEmail)
  #:capabilities [enqueueEmail]
  #:returns String
  (begin (enqueue! EmailQueue (EmailJob #:recipientId "user-123" #:subject "Welcome!" #:body "Thanks for signing up.")) "queued"))

(define ConcurrencyServer-sse-routes '())
(define-api ConcurrencyApi
  [sendWelcomeEmail :
    "send-welcome"
    :> (Post JSON String)
    ]
)

(define-server ConcurrencyServer
  #:api ConcurrencyApi
  [sendWelcomeEmail sendWelcomeEmail]
)

(module+ main
  (let ([port 8090]) (call-with-database EmailDatabase (lambda () (with-capabilities (fullService) (begin (start-workers! EmailWorkers (list emailCap) #:concurrency 4) (begin (start-dead-workers! DeadEmailWorkers (list deadEmailCap)) (serve ConcurrencyServer #:port port #:capabilities (list enqueueEmail) #:sse-routes ConcurrencyServer-sse-routes))))))))
