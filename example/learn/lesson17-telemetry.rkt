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
  (only-in tesl/tesl/prelude Bool Int String Unit)
  (only-in tesl/tesl/time nowMillis time [Time.posixToSeconds tesl_import_Time_posixToSeconds])
  (only-in tesl/tesl/telemetry initTelemetry)
)


(provide processRequest processRequestWithSpan processRequest-signature processRequestWithSpan-signature)

(define-capability apiTime (implies time))

(define/pow
  (processRequest [userId : String] [action : String])
  #:capabilities [apiTime]
  #:returns String
  (let ([_ (thsl-src! "example/learn/lesson17-telemetry.tesl" 54 (list (cons 'userId *userId) (cons 'action *action)) (lambda () (telemetry-event! "request.process" #:attributes (["user.id" *userId] ["action.name" *action]))))]) (thsl-src! "example/learn/lesson17-telemetry.tesl" 55 (list (cons 'userId *userId) (cons 'action *action)) (lambda () (format "processed ~a for user ~a at ~a" (tesl-display-val *action) (tesl-display-val *userId) (tesl-display-val (raw-value (tesl_import_Time_posixToSeconds (raw-value (nowMillis))))))))))

(define/pow
  (processRequestWithSpan [userId : String] [requestCount : Integer])
  #:capabilities [apiTime]
  #:returns String
  (let ([result (thsl-src! "example/learn/lesson17-telemetry.tesl" 58 (list (cons 'userId *userId) (cons 'requestCount *requestCount)) (lambda () (format "handled ~a requests" (tesl-display-val *requestCount))))]) (let ([_ (thsl-src! "example/learn/lesson17-telemetry.tesl" 59 (list (cons 'result *result) (cons 'userId *userId) (cons 'requestCount *requestCount)) (lambda () (telemetry-event! "batch.process" #:attributes (["user.id" *userId] ["count" *requestCount] ["timestamp" (raw-value (tesl_import_Time_posixToSeconds (raw-value (nowMillis))))]))))]) (thsl-src! "example/learn/lesson17-telemetry.tesl" 60 (list (cons 'result *result) (cons 'userId *userId) (cons 'requestCount *requestCount)) (lambda () (raw-value result))))))

(define-handler
  (healthCheck)
  #:returns String
  (let ([_ (thsl-src! "example/learn/lesson17-telemetry.tesl" 69 (list) (lambda () (telemetry-event! "health.check" #:attributes (["status" "ok"]))))]) (thsl-src! "example/learn/lesson17-telemetry.tesl" 70 (list) (lambda () "ok"))))

(define HealthServer-sse-routes '())
(define-api HealthApi
  [endpoint_0 :
    "health"
    :> (Get JSON String)
    ]
)

(define-server HealthServer
  #:api HealthApi
  [endpoint_0 healthCheck]
)

(define-database TelemetryDb
  #:backend memory
  #:entities )

(module+ main
  (thsl-src! "example/learn/lesson17-telemetry.tesl" 84 (list) (lambda () (with-capabilities () (call-with-database TelemetryDb (lambda () (let ([_ (init-opentelemetry! #:service-name "lesson17-telemetry" #:endpoint "in-memory" #:console? #t)]) (serve HealthServer #:port 8086 #:capabilities (list) #:sse-routes HealthServer-sse-routes))))))))
