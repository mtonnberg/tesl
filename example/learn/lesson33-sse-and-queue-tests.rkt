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
  (only-in tesl/tesl/queue FromQueue queueRead queueWrite pubsub)
  (only-in tesl/tesl/api-test statusOk isNotEmpty includesWhere subscribe collect JobResult JobOk JobFailed processNextJob pendingJobCount expectJobOk)
)


(provide Lesson33Server)

(define-database Lesson33Database
  #:backend postgres
  #:database "demo"
  #:user "demo"
  #:password "demo"
  #:server "localhost"
  #:port 5432
  #:schema lesson33
  #:entities )

(define-record NotifyJob
  [userId : String]
  [message : String]
)

(define-record SendNoticeRequest
  [userId : String]
  [message : String]
)

(define (tesl-codec-encode-SendNoticeRequest _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'userId (tesl-encode-prim-string (raw-value (hash-ref _fields 'userId)))
        'message (tesl-encode-prim-string (raw-value (hash-ref _fields 'message)))
  ))
(define (tesl-codec-decode-SendNoticeRequest-0 _j)
  (define _f_userId (tesl-decode-prim-field _j "userId" tesl-decode-prim-string))
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'SendNoticeRequest (tesl-hash 'userId _f_userId 'message _f_message)))
(register-type-codec! 'SendNoticeRequest tesl-codec-encode-SendNoticeRequest (list tesl-codec-decode-SendNoticeRequest-0))

(define-adt NoticeEvent
  [NoticeSent [message : String]]
)

(define/pow
  (parseUserId [id : String])
  #:returns String
  (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 85 (list (cons 'id *id)) (lambda () *id)))

(define-capture userIdCapture
  [userIdCapture : String]
  #:parser string-segment #:check parseUserId)

(define-queue Lesson33Queue
  #:database Lesson33Database
  #:job-types (NotifyJob)
  #:max-attempts 2
  #:backoff linear
  #:initial-delay 1)

(define-channel Lesson33Events)

(define/pow
  (handleNotice [job : NotifyJob ::: (FromQueue (Id == jobId) job)])
  #:capabilities [queueRead pubsub]
  #:returns NotifyJob
  (let ([_ (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 106 (list (cons 'job *job)) (lambda () (publish-event! Lesson33Events (format "~a" (raw-value job.userId)) (NoticeSent (raw-value job.message)))))]) (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 107 (list (cons 'job *job)) (lambda () *job))))

(define-handler
  (sendNotice [req : SendNoticeRequest])
  #:capabilities [queueWrite]
  #:returns String
  (let ([_ (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 111 (list (cons 'req *req)) (lambda () (enqueue! Lesson33Queue (NotifyJob #:userId (raw-value req.userId) #:message (raw-value req.message)))))]) (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 112 (list (cons 'req *req)) (lambda () "queued"))))

(define Lesson33Server-sse-routes
  (list (list (list "events" #f) #f Lesson33Events 1 (list (cons 1 (sse-key-capture userIdCapture))))))
(define-api Lesson33Api
  [sendNotice :
    "send"
    :> (ReqBody JSON [req : SendNoticeRequest])
    :> (Post JSON String)
    ]
)

(define-server Lesson33Server
  #:api Lesson33Api
  [sendNotice sendNotice]
)

(module+ test
  (require rackunit)
  (test-case "subscribe collect and process queue"
    (call-with-fresh-memory-db (list Lesson33Database)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (queueRead queueWrite pubsub)
              (define stream (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 129 (list) (lambda () (subscribe Lesson33Server-sse-routes (list "events" "user-1") #:headers (tesl-hash) #:name "/events/user-1"))))
              (define resp (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 130 (list (cons 'stream stream)) (lambda () (dispatch-api-test-request Lesson33Server 'post (list "send") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "userId") "user-1" (string->symbol "message") "Hello from lesson33") #:capabilities (list queueRead queueWrite pubsub)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 131 (list (cons 'resp resp) (cons 'stream stream)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 133 (list (cons 'resp resp) (cons 'stream stream)) (lambda () (pendingJobCount Lesson33Queue)))) 1)
              (define result (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 135 (list (cons 'resp resp) (cons 'stream stream)) (lambda () (processNextJob Lesson33Queue))))
              (define job (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 136 (list (cons 'result result) (cons 'resp resp) (cons 'stream stream)) (lambda () (expectJobOk (raw-value result)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 137 (list (cons 'job job) (cons 'result result) (cons 'resp resp) (cons 'stream stream)) (lambda () (api-test-field-access-ref job 'userId)))) "user-1")
              (check-equal? (raw-value (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 138 (list (cons 'job job) (cons 'result result) (cons 'resp resp) (cons 'stream stream)) (lambda () (pendingJobCount Lesson33Queue)))) 0)
              (define events (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 140 (list (cons 'job job) (cons 'result result) (cons 'resp resp) (cons 'stream stream)) (lambda () (collect (raw-value stream) #:count 1 #:timeout-ms 1500))))
              (check-true (raw-value (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 141 (list (cons 'events events) (cons 'job job) (cons 'result result) (cons 'resp resp) (cons 'stream stream)) (lambda () (isNotEmpty (raw-value events))))))
              (check-true (raw-value (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 142 (list (cons 'events events) (cons 'job job) (cons 'result result) (cons 'resp resp) (cons 'stream stream)) (lambda () (includesWhere (tesl-hash 'tag "NoticeSent" 'fields (tesl-hash 'message "Hello from lesson33")) (raw-value events))))))
            )
          ))
      ))
  )
)

(define Lesson33QueueWorkers
  (list (cons Lesson33Queue handleNotice)))
(register-api-test-workers! (list (list Lesson33Queue 'NotifyJob handleNotice)))
