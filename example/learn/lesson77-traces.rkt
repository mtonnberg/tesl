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
  (only-in tesl/tesl/prelude Bool String)
  (only-in tesl/tesl/api-test statusOk)
  (only-in tesl/tesl/float Float)
  (only-in tesl/tesl/telemetry initTelemetry telemetry)
)


(provide describeTrace describeTrace-signature)

(define/pow
  (describeTrace [note : String])
  #:returns String
  (let ([_ (thsl-src! "example/learn/lesson77-traces.tesl" 103 (list (cons 'note *note)) (lambda () (telemetry-event! "note described" #:attributes (["note" *note]))))]) (thsl-src! "example/learn/lesson77-traces.tesl" 104 (list (cons 'note *note)) (lambda () (format "described ~a" (tesl-display-val *note))))))

(define-handler
  (getNote)
  #:returns String
  (thsl-src! "example/learn/lesson77-traces.tesl" 107 (list) (lambda () (describeTrace "n-1"))))

(define TracesServer-sse-routes '())
(define-api TracesApi
  [endpoint_0 :
    "note"
    :> (Get JSON String)
    ]
)

(define-server TracesServer
  #:api TracesApi
  [endpoint_0 getNote]
)

(define-database TracesDb
  #:backend memory
  #:entities )

(module+ main
  (thsl-src! "example/learn/lesson77-traces.tesl" 122 (list) (lambda () (with-capabilities () (call-with-database TracesDb (lambda () (let ([_ (init-opentelemetry! #:service-name "lesson77-traces" #:endpoint "in-memory" #:console? #f #:metrics? #t #:traces? #t #:trace-ratio 1.)]) (serve TracesServer #:port 8091 #:capabilities (list) #:sse-routes TracesServer-sse-routes))))))))

(module+ test
  (require rackunit)
  (test-case "a traced endpoint responds normally"
    (call-with-fresh-memory-db (list TracesDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "example/learn/lesson77-traces.tesl" 144 (list) (lambda () (dispatch-api-test-request TracesServer 'get (list "note") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "example/learn/lesson77-traces.tesl" 145 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "example/learn/lesson77-traces.tesl" 146 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "described n-1")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "tracing never changes a function's result"
    (call-with-fresh-memory-db (list TracesDb) (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson77-traces.tesl" 140 (list) (lambda () (describeTrace "n-1")))) "described n-1")
    ))
  )

)
