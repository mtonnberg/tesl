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
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/api-test statusOk isNull)
)


(provide Lesson32Server)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/learn/lesson32-api-tests.tesl" '(63))
(define-record EchoRequest
  [message : String]
)

(define (tesl-codec-encode-EchoRequest _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'message (tesl-encode-prim-string (raw-value (hash-ref _fields 'message)))
  ))
(define (tesl-codec-decode-EchoRequest-0 _j)
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'EchoRequest (tesl-hash 'message _f_message)))
(register-type-codec! 'EchoRequest tesl-codec-encode-EchoRequest (list tesl-codec-decode-EchoRequest-0))

(define-entity Note
  #:source (make-hash)
  #:table notes
  #:primary-key id
  [Id id : String]
  [Title title : String]
)

(define-database Lesson32Database
  #:backend postgres
  #:database "lesson32"
  #:user "lesson32"
  #:password "lesson32"
  #:server "localhost"
  #:port 5432
  #:schema lesson32
  #:entities Note)

(define-handler
  (echo [req : EchoRequest])
  #:returns EchoRequest
  (thsl-src! "example/learn/lesson32-api-tests.tesl" 59 (list (cons 'req *req)) (lambda () req)))

(define-handler
  (getSeededNote)
  #:capabilities [dbRead]
  #:returns Note
  (let ([found (thsl-src! "example/learn/lesson32-api-tests.tesl" 63 (list) (lambda () (let ([tesl_match (select-one (from Note) (where (==. (entity-field-ref Note 'id) "note-1")))]) (if tesl_match (Something tesl_match) Nothing))) 'found)]) (thsl-src-control! "example/learn/lesson32-api-tests.tesl" 64 (list (cons 'found *found)) (lambda () (let ([tesl-case-0 (raw-value found)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson32-api-tests.tesl" 66 (list) (lambda () (reject "note not found" #:http-code 404)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson32-api-tests.tesl" 68 (list (cons 'n n)) (lambda () *n)))]))))))

(define Lesson32Server-sse-routes '())
(define-api Lesson32Api
  [echo :
    "echo"
    :> (ReqBody JSON [req : EchoRequest])
    :> (Post JSON EchoRequest)
    ]
  [getSeededNote :
    "seeded-note"
    :> (Get JSON Note)
    ]
)

(define-server Lesson32Server
  #:api Lesson32Api
  [echo echo]
  [getSeededNote getSeededNote]
)

(module+ test
  (require rackunit)
  (test-case "raw JSON body and dynamic response fields"
    (call-with-fresh-memory-db (list Lesson32Database)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define echoResp (thsl-src! "example/learn/lesson32-api-tests.tesl" 85 (list) (lambda () (dispatch-api-test-request Lesson32Server 'post (list "echo") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "message") "hello from api-test") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "example/learn/lesson32-api-tests.tesl" 86 (list (cons 'echoResp echoResp)) (lambda () (statusOk (raw-value (api-test-field-access-ref echoResp 'status)))))))
            (check-equal? (raw-value (thsl-src! "example/learn/lesson32-api-tests.tesl" 87 (list (cons 'echoResp echoResp)) (lambda () (api-test-field-access-ref (api-test-field-access-ref echoResp 'body) 'message)))) "hello from api-test")
            (check-true (raw-value (thsl-src! "example/learn/lesson32-api-tests.tesl" 88 (list (cons 'echoResp echoResp)) (lambda () (isNull (raw-value (api-test-field-access-ref (api-test-field-access-ref echoResp 'body) 'missing)))))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "seed prepares fresh in-memory state"
    (call-with-fresh-memory-db (list Lesson32Database)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (insert-one! Note (tesl-hash 'id "note-1" 'title "Seeded from setup"))
              (define seeded (thsl-src! "example/learn/lesson32-api-tests.tesl" 96 (list) (lambda () (dispatch-api-test-request Lesson32Server 'get (list "seeded-note") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson32-api-tests.tesl" 97 (list (cons 'seeded seeded)) (lambda () (statusOk (raw-value (api-test-field-access-ref seeded 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson32-api-tests.tesl" 98 (list (cons 'seeded seeded)) (lambda () (api-test-field-access-ref (api-test-field-access-ref seeded 'body) 'title)))) "Seeded from setup")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "state is isolated between blocks"
    (call-with-fresh-memory-db (list Lesson32Database)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead)
              (define seeded (thsl-src! "example/learn/lesson32-api-tests.tesl" 102 (list) (lambda () (dispatch-api-test-request Lesson32Server 'get (list "seeded-note") #:headers (tesl-hash) #:capabilities (list dbRead)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson32-api-tests.tesl" 103 (list (cons 'seeded seeded)) (lambda () (api-test-field-access-ref seeded 'status)))) 404)
            )
          ))
      ))
  )
)
