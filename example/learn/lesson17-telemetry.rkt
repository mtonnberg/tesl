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
  (thsl-src! "example/learn/lesson17-telemetry.tesl" 52 (list (cons 'userId *userId) (cons 'action *action)) (lambda () (begin (telemetry-event! "request.process" #:attributes (["user.id" *userId] ["action.name" *action])) (format "processed ~a for user ~a at ~a" (tesl-display-val *action) (tesl-display-val *userId) (tesl-display-val (raw-value (tesl_import_Time_posixToSeconds (raw-value (nowMillis))))))))))

(define/pow
  (processRequestWithSpan [userId : String] [requestCount : Integer])
  #:capabilities [apiTime]
  #:returns String
  (thsl-src! "example/learn/lesson17-telemetry.tesl" 56 (list (cons 'userId *userId) (cons 'requestCount *requestCount)) (lambda () (let ([result (format "handled ~a requests" (tesl-display-val *requestCount))]) (begin (telemetry-event! "batch.process" #:attributes (["user.id" *userId] ["count" *requestCount] ["timestamp" (raw-value (tesl_import_Time_posixToSeconds (raw-value (nowMillis))))])) (raw-value result))))))

(define/pow
  (foo)
  #:returns String
  (let ([x (thsl-src! "example/learn/lesson17-telemetry.tesl" 61 (list) (lambda () "my-service"))]) (let ([y (thsl-src! "example/learn/lesson17-telemetry.tesl" 62 (list (cons 'x *x)) (lambda () 1))]) (thsl-src! "example/learn/lesson17-telemetry.tesl" 63 (list (cons 'y *y) (cons 'x *x)) (lambda () (raw-value x))))))

(module+ main
  (let ([x (thsl-src! "example/learn/lesson17-telemetry.tesl" 66 (list) (lambda () (foo)))])
  (thsl-src! "example/learn/lesson17-telemetry.tesl" 70 (list) (lambda () (init-opentelemetry! #:service-name x #:endpoint "in-memory" #:console? #t)))))
