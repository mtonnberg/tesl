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
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/telemetry initTelemetry telemetry counter histogram gauge)
)


(provide recordSignup recordSignup-signature)

(define/pow
  (recordSignup [plan : String])
  #:returns String
  (let ([_ (thsl-src! "example/learn/lesson73-metrics.tesl" 71 (list (cons 'plan *plan)) (lambda () (raw-value (counter "signup.completed" 1 (list (Tuple2 "plan" plan))))))]) (thsl-src! "example/learn/lesson73-metrics.tesl" 72 (list (cons '_ *_) (cons 'plan *plan)) (lambda () (format "welcome to ~a" (tesl-display-val *plan))))))

(define-handler
  (runBatch)
  #:returns String
  (let ([_ (thsl-src! "example/learn/lesson73-metrics.tesl" 77 (list) (lambda () (raw-value (histogram "batch.item.duration" 0.125 (list (Tuple2 "kind" "resize"))))))]) (let ([_ (thsl-src! "example/learn/lesson73-metrics.tesl" 78 (list (cons '_ *_)) (lambda () (raw-value (gauge "batch.backlog" 42. (list)))))]) (let ([_ (thsl-src! "example/learn/lesson73-metrics.tesl" 79 (list (cons '_ *_) (cons '_ *_)) (lambda () (telemetry-event! "batch.finished" #:attributes (["items" 1]))))]) (thsl-src! "example/learn/lesson73-metrics.tesl" 80 (list (cons '_ *_) (cons '_ *_)) (lambda () (recordSignup "pro")))))))

(define MetricsServer-sse-routes '())
(define-api MetricsApi
  [endpoint_0 :
    "run"
    :> (Get JSON String)
    ]
)

(define-server MetricsServer
  #:api MetricsApi
  [endpoint_0 runBatch]
)

(define-database MetricsDb
  #:backend memory
  #:entities )

(module+ main
  (thsl-src! "example/learn/lesson73-metrics.tesl" 95 (list) (lambda () (with-capabilities () (call-with-database MetricsDb (lambda () (let ([_ (init-opentelemetry! #:service-name "lesson73-metrics" #:endpoint "in-memory" #:console? #f #:metrics? #t #:metrics-interval-ms 30000)]) (serve MetricsServer #:port 8087 #:capabilities (list) #:sse-routes MetricsServer-sse-routes))))))))

(module+ test
  (require rackunit)
  (test-case "an endpoint that records a histogram and a gauge still responds"
    (call-with-fresh-memory-db (list MetricsDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "example/learn/lesson73-metrics.tesl" 120 (list) (lambda () (dispatch-api-test-request MetricsServer 'get (list "run") #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "example/learn/lesson73-metrics.tesl" 121 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "example/learn/lesson73-metrics.tesl" 122 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "welcome to pro")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a counter records without disturbing the function's result"
    (call-with-fresh-memory-db (list MetricsDb) (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson73-metrics.tesl" 115 (list) (lambda () (recordSignup "pro")))) "welcome to pro")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson73-metrics.tesl" 116 (list) (lambda () (recordSignup "free")))) "welcome to free")
    ))
  )

)
