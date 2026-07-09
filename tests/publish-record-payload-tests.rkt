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
  (only-in tesl/tesl/prelude String Unit)
  (only-in tesl/tesl/queue pubsub)
  (only-in tesl/tesl/api-test statusOk isNotEmpty includesWhere subscribe collect)
)


(provide MainServer)

(define-database MainDb
  #:backend memory
  #:schema publish_record_payload
  #:entities )

(define-record Notice
  [message : String]
)

(define (tesl-codec-encode-Notice _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'message (tesl-encode-prim-string (raw-value (hash-ref _fields 'message)))
  ))
(define (tesl-codec-decode-Notice-0 _j)
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'Notice (hash 'message _f_message)))
(register-type-codec! 'Notice tesl-codec-encode-Notice (list tesl-codec-decode-Notice-0))

(define-record SendReq
  [userId : String]
  [message : String]
)

(define (tesl-codec-encode-SendReq _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'userId (tesl-encode-prim-string (raw-value (hash-ref _fields 'userId)))
        'message (tesl-encode-prim-string (raw-value (hash-ref _fields 'message)))
  ))
(define (tesl-codec-decode-SendReq-0 _j)
  (define _f_userId (tesl-decode-prim-field _j "userId" tesl-decode-prim-string))
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'SendReq (hash 'userId _f_userId 'message _f_message)))
(register-type-codec! 'SendReq tesl-codec-encode-SendReq (list tesl-codec-decode-SendReq-0))

(define/pow
  (parseUserId [id : String])
  #:returns String
  (thsl-src! "tests/publish-record-payload-tests.tesl" 65 (list (cons 'id *id)) (lambda () *id)))

(define-capture userIdCapture
  [userIdCapture : String]
  #:parser string-segment #:check parseUserId)

(define-channel Notices)

(define-handler
  (sendNotice [req : SendReq])
  #:capabilities [pubsub]
  #:returns String
  (let ([_ (thsl-src! "tests/publish-record-payload-tests.tesl" 76 (list (cons 'req *req)) (lambda () (publish-event! Notices (format "~a" (raw-value req.userId)) (Notice #:message (raw-value req.message)))))]) (thsl-src! "tests/publish-record-payload-tests.tesl" 77 (list (cons 'req *req)) (lambda () "ok"))))

(define MainServer-sse-routes
  (list (list (list "events" #f) #f Notices 1 (list (cons 1 (sse-key-capture userIdCapture))))))
(define-api MainApi
  [sendNotice :
    "send"
    :> (ReqBody JSON [req : SendReq])
    :> (Post JSON String)
    ]
)

(define-server MainServer
  #:api MainApi
  [sendNotice sendNotice]
)

(module+ test
  (require rackunit)
  (test-case "publish with record payload reaches the subscriber"
    (call-with-fresh-memory-db (list MainDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (pubsub)
              (define stream (subscribe MainServer-sse-routes (list "events" "user-1") #:headers (hash) #:name "/events/user-1"))
              (define resp (dispatch-api-test-request MainServer 'post (list "send") #:headers (hash) #:body (hash (string->symbol "userId") "user-1" (string->symbol "message") "hello-record") #:capabilities (list pubsub)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
              (define events (collect (raw-value stream) #:count 1 #:timeout-ms 1500))
              (check-true (raw-value (isNotEmpty (raw-value events))))
              (check-true (raw-value (includesWhere (hash 'message "hello-record") (raw-value events))))
            )
          ))
      ))
  )
)
