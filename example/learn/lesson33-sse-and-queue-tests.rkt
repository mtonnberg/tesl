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
  #:socket ""
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
  (hash 'userId (tesl-encode-prim-string (raw-value (hash-ref _fields 'userId)))
        'message (tesl-encode-prim-string (raw-value (hash-ref _fields 'message)))
  ))
(define (tesl-codec-decode-SendNoticeRequest-0 _j)
  (define _f_userId (tesl-decode-prim-field _j "userId" tesl-decode-prim-string))
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'SendNoticeRequest (hash 'userId _f_userId 'message _f_message)))
(register-type-codec! 'SendNoticeRequest tesl-codec-encode-SendNoticeRequest (list tesl-codec-decode-SendNoticeRequest-0))

(define-adt NoticeEvent
  [NoticeSent [message : String]]
)

(define/pow
  (parseUserId [id : String])
  #:returns String
  (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 65 (list (cons 'id *id)) (lambda () *id)))

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
  (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 86 (list (cons 'job *job)) (lambda () (begin (publish-event! Lesson33Events (format "~a" (raw-value job.userId)) (NoticeSent (raw-value job.message))) *job))))

(define Lesson33Workers
  (list (cons Lesson33Queue handleNotice)))
(register-api-test-workers! (list (list Lesson33Queue 'NotifyJob handleNotice)))

(define-handler
  (sendNotice [req : SendNoticeRequest])
  #:capabilities [queueWrite]
  #:returns String
  (thsl-src! "example/learn/lesson33-sse-and-queue-tests.tesl" 95 (list (cons 'req *req)) (lambda () (begin (enqueue! Lesson33Queue (NotifyJob #:userId (raw-value req.userId) #:message (raw-value req.message))) "queued"))))

(define Lesson33Server-sse-routes
  (list (list (list "events") #f Lesson33Events)))
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
              (define stream (subscribe Lesson33Server-sse-routes (list "events" "user-1") #:headers (hash) #:name "/events/user-1"))
              (define resp (dispatch-api-test-request Lesson33Server 'post (list "send") #:headers (hash) #:body (hash (string->symbol "userId") "user-1" (string->symbol "message") "Hello from lesson33") #:capabilities (list queueRead queueWrite pubsub)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
              (check-equal? (raw-value (pendingJobCount Lesson33Queue)) 1)
              (define result (processNextJob Lesson33Queue))
              (define job (expectJobOk (raw-value result)))
              (check-equal? (raw-value (api-test-field-access-ref job 'userId)) "user-1")
              (check-equal? (raw-value (pendingJobCount Lesson33Queue)) 0)
              (define events (collect (raw-value stream) #:count 1 #:timeout-ms 1500))
              (check-true (raw-value (isNotEmpty (raw-value events))))
              (check-true (raw-value (includesWhere (hash 'tag "NoticeSent" 'fields (hash 'message "Hello from lesson33")) (raw-value events))))
            )
          ))
      ))
  )
)
