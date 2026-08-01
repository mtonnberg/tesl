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
  (only-in tesl/tesl/http-client httpClient HttpResponse [HttpClient.get tesl_import_HttpClient_get])
  (only-in tesl/tesl/api-test statusOk stubHttp httpCalled httpCallCount)
)


(provide TracePropServer)

(define-capability billingClient (implies httpClient))

(define/pow
  (callBilling)
  #:capabilities [billingClient]
  #:returns HttpResponse
  (thsl-src! "tests/trace-propagation-tests.tesl" 32 (list) (lambda () (raw-value (tesl_import_HttpClient_get "https://billing.internal/invoice/42" (list))))))

(define-handler
  (chargeNote)
  #:capabilities [billingClient]
  #:returns String
  (let ([resp (thsl-src! "tests/trace-propagation-tests.tesl" 35 (list) (lambda () (callBilling)))]) (thsl-src! "tests/trace-propagation-tests.tesl" 36 (list (cons 'resp *resp)) (lambda () (if (tesl-equal? (raw-value (raw-value resp.status)) 200) "charged" "declined")))))

(define TracePropServer-sse-routes '())
(define-api TracePropApi
  [endpoint_0 :
    "charge"
    :> (Post JSON String)
    ]
)

(define-server TracePropServer
  #:api TracePropApi
  [endpoint_0 chargeNote]
)

(define-database TracePropDb
  #:backend memory
  #:entities )

(module+ test
  (require rackunit)
  (test-case "TP-01: a well-formed inbound traceparent leaves the response unchanged"
    (call-with-fresh-memory-db (list TracePropDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (billingClient)
              (thsl-src! "tests/trace-propagation-tests.tesl" 57 (list) (lambda () (stubHttp "GET" "https://billing.internal/*" 200 "billed")))
              (define r (thsl-src! "tests/trace-propagation-tests.tesl" 58 (list) (lambda () (dispatch-api-test-request TracePropServer 'post (list "charge") #:headers (tesl-hash (string->symbol "traceparent") "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01") #:capabilities (list billingClient)))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 59 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 60 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "charged")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TP-02: no inbound traceparent behaves identically"
    (call-with-fresh-memory-db (list TracePropDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (billingClient)
              (thsl-src! "tests/trace-propagation-tests.tesl" 64 (list) (lambda () (stubHttp "GET" "https://billing.internal/*" 200 "billed")))
              (define r (thsl-src! "tests/trace-propagation-tests.tesl" 65 (list) (lambda () (dispatch-api-test-request TracePropServer 'post (list "charge") #:headers (tesl-hash) #:capabilities (list billingClient)))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 66 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 67 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "charged")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TP-03: a MALFORMED traceparent is not an error \226\128\148 a fresh trace starts"
    (call-with-fresh-memory-db (list TracePropDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (billingClient)
              (thsl-src! "tests/trace-propagation-tests.tesl" 71 (list) (lambda () (stubHttp "GET" "https://billing.internal/*" 200 "billed")))
              (define r (thsl-src! "tests/trace-propagation-tests.tesl" 72 (list) (lambda () (dispatch-api-test-request TracePropServer 'post (list "charge") #:headers (tesl-hash (string->symbol "traceparent") "total-nonsense") #:capabilities (list billingClient)))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 73 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 74 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "charged")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TP-04: a hostile traceparent (all-zero ids, CRLF, absurd length) is inert"
    (call-with-fresh-memory-db (list TracePropDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (billingClient)
              (thsl-src! "tests/trace-propagation-tests.tesl" 78 (list) (lambda () (stubHttp "GET" "https://billing.internal/*" 200 "billed")))
              (define zeros (thsl-src! "tests/trace-propagation-tests.tesl" 79 (list) (lambda () (dispatch-api-test-request TracePropServer 'post (list "charge") #:headers (tesl-hash (string->symbol "traceparent") "00-00000000000000000000000000000000-0000000000000000-01") #:capabilities (list billingClient)))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 80 (list (cons 'zeros zeros)) (lambda () (statusOk (raw-value (api-test-field-access-ref zeros 'status)))))))
              (define crlf (thsl-src! "tests/trace-propagation-tests.tesl" 81 (list (cons 'zeros zeros)) (lambda () (dispatch-api-test-request TracePropServer 'post (list "charge") #:headers (tesl-hash (string->symbol "traceparent") "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\nX-Injected: 1") #:capabilities (list billingClient)))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 82 (list (cons 'crlf crlf) (cons 'zeros zeros)) (lambda () (statusOk (raw-value (api-test-field-access-ref crlf 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 83 (list (cons 'crlf crlf) (cons 'zeros zeros)) (lambda () (api-test-field-access-ref crlf 'body)))) "charged")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TP-05: an inbound tracestate rides along without disturbing anything"
    (call-with-fresh-memory-db (list TracePropDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (billingClient)
              (thsl-src! "tests/trace-propagation-tests.tesl" 87 (list) (lambda () (stubHttp "GET" "https://billing.internal/*" 200 "billed")))
              (define r (thsl-src! "tests/trace-propagation-tests.tesl" 88 (list) (lambda () (dispatch-api-test-request TracePropServer 'post (list "charge") #:headers (tesl-hash (string->symbol "traceparent") "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" (string->symbol "tracestate") "congo=t61rcWkgMzE") #:capabilities (list billingClient)))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 92 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 93 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "charged")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TP-06: the injected header does not change stub matching or the call count"
    (call-with-fresh-memory-db (list TracePropDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (billingClient)
              (thsl-src! "tests/trace-propagation-tests.tesl" 99 (list) (lambda () (stubHttp "GET" "https://billing.internal/invoice/42" 200 "billed")))
              (define r (thsl-src! "tests/trace-propagation-tests.tesl" 100 (list) (lambda () (dispatch-api-test-request TracePropServer 'post (list "charge") #:headers (tesl-hash (string->symbol "traceparent") "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01") #:capabilities (list billingClient)))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 101 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 102 (list (cons 'r r)) (lambda () (httpCalled "GET" "https://billing.internal/invoice/42")))))
              (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 105 (list (cons 'r r)) (lambda () (httpCallCount "GET" "https://billing.internal/invoice/42")))) 1)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TP-07: an outbound failure still surfaces as itself, not as a trace error"
    (call-with-fresh-memory-db (list TracePropDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (billingClient)
              (thsl-src! "tests/trace-propagation-tests.tesl" 109 (list) (lambda () (stubHttp "GET" "https://billing.internal/*" 503 "unavailable")))
              (define r (thsl-src! "tests/trace-propagation-tests.tesl" 110 (list) (lambda () (dispatch-api-test-request TracePropServer 'post (list "charge") #:headers (tesl-hash (string->symbol "traceparent") "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01") #:capabilities (list billingClient)))))
              (check-true (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 111 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 112 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "declined")
              (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 113 (list (cons 'r r)) (lambda () (httpCallCount "GET" "https://billing.internal/invoice/42")))) 1)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TP-08: an outbound call from a plain test (no request, no trace) works"
    (call-with-fresh-memory-db (list TracePropDb) (lambda ()
    (with-capabilities (billingClient)
    (raw-value (stubHttp "GET" "https://billing.internal/invoice/42" 200 "billed"))
    (define r (thsl-src! "tests/trace-propagation-tests.tesl" 120 (list) (lambda () (callBilling))))
    (check-equal? (thsl-src! "tests/trace-propagation-tests.tesl" 121 (list (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r 'status)))) 200)
    (check-equal? (raw-value (thsl-src! "tests/trace-propagation-tests.tesl" 122 (list (cons 'r r)) (lambda () (raw-value (httpCallCount "GET" "https://billing.internal/invoice/42"))))) 1)
    )
    ))
  )

)
