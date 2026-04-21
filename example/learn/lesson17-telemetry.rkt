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
  (begin (telemetry-event! "request.process" #:attributes (["user.id" *userId] ["action.name" *action])) (format "processed ~a for user ~a at ~a" (tesl-display-val *action) (tesl-display-val *userId) (tesl-display-val (raw-value (tesl_import_Time_posixToSeconds (raw-value (nowMillis))))))))

(define/pow
  (processRequestWithSpan [userId : String] [requestCount : Integer])
  #:capabilities [apiTime]
  #:returns String
  (let ([result (format "handled ~a requests" (tesl-display-val *requestCount))]) (begin (telemetry-event! "batch.process" #:attributes (["user.id" *userId] ["count" *requestCount] ["timestamp" (raw-value (tesl_import_Time_posixToSeconds (raw-value (nowMillis))))])) (raw-value result))))

(module+ main
  (init-opentelemetry! #:service-name "my-service" #:endpoint "in-memory" #:console? #t))
