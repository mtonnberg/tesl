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
  (hash 'message (tesl-encode-prim-string (raw-value (hash-ref _fields 'message)))
  ))
(define (tesl-codec-decode-EchoRequest-0 _j)
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'EchoRequest (hash 'message _f_message)))
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
  #:socket ""
  #:schema lesson32
  #:entities Note)

(define-handler
  (echo [req : EchoRequest])
  #:returns EchoRequest
  (thsl-src! "example/learn/lesson32-api-tests.tesl" 49 (list (cons 'req *req)) (lambda () req)))

(define-handler
  (getSeededNote)
  #:capabilities [dbRead]
  #:returns Note
  (let ([found (thsl-src! "example/learn/lesson32-api-tests.tesl" 53 (list) (lambda () (let ([tesl_match (select-one (from Note) (where (==. (entity-field-ref Note 'id) "note-1")))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src! "example/learn/lesson32-api-tests.tesl" 54 (list (cons 'found *found)) (lambda () (let ([tesl_case_0 (raw-value found)]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (thsl-src! "example/learn/lesson32-api-tests.tesl" 56 (list) (lambda () (reject "note not found" #:http-code 404)))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (thsl-src! "example/learn/lesson32-api-tests.tesl" 58 (list (cons 'n n)) (lambda () *n)))]))))))

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
            (define echoResp (dispatch-api-test-request Lesson32Server 'post (list "echo") #:headers (hash) #:body (hash (string->symbol "message") "hello from api-test") #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref echoResp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref echoResp 'body) 'message)) "hello from api-test")
            (check-true (raw-value (isNull (raw-value (api-test-field-access-ref (api-test-field-access-ref echoResp 'body) 'missing)))))
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
              (insert-one! Note (hash 'id "note-1" 'title "Seeded from setup"))
              (define seeded (dispatch-api-test-request Lesson32Server 'get (list "seeded-note") #:headers (hash) #:capabilities (list dbRead dbWrite)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref seeded 'status)))))
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref seeded 'body) 'title)) "Seeded from setup")
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
              (define seeded (dispatch-api-test-request Lesson32Server 'get (list "seeded-note") #:headers (hash) #:capabilities (list dbRead)))
              (check-equal? (raw-value (api-test-field-access-ref seeded 'status)) 404)
            )
          ))
      ))
  )
)
