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
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/api-test statusOk statusClientError)
)


(provide SearchServer)

(define ValidSearch 'ValidSearch)

(define-record SearchParams
  [q : String]
  [order : String]
)

(define-auther
  (parseSearch [req : HttpRequest])
  #:returns [params : SearchParams ::: (ValidSearch params)]
  (thsl-src-control! "example/learn/lesson66-query-parameters.tesl" 50 (list (cons 'req *req)) (lambda () (let ([tesl_case_0 (raw-value (tesl_import_Dict_lookup "q" (raw-value req.queryParameters)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (thsl-src! "example/learn/lesson66-query-parameters.tesl" 51 (list) (lambda () (reject "missing required query parameter: q" #:http-code 400)))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([q (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (thsl-src! "example/learn/lesson66-query-parameters.tesl" 53 (list (cons 'q q)) (lambda () (let ([tesl_case_1 (raw-value (tesl_import_Dict_lookup "order" (raw-value req.queryParameters)))]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (thsl-src! "example/learn/lesson66-query-parameters.tesl" 54 (list) (lambda () (accept ValidSearch #:value (SearchParams #:q *q #:order "asc"))))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([o (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (thsl-src! "example/learn/lesson66-query-parameters.tesl" 55 (list (cons 'o o)) (lambda () (accept ValidSearch #:value (SearchParams #:q *q #:order *o)))))])))))])))))

(define SearchServer-sse-routes '())
(define-api SearchApi
  [search :
    (Auth [params : SearchParams ::: (ValidSearch params)] #:via parseSearch)
    :> "search"
    :> (Get JSON String)
    ]
)

(define-handler
  (search [params : SearchParams ::: (ValidSearch params)])
  #:returns String
  (thsl-src! "example/learn/lesson66-query-parameters.tesl" 65 (list (cons 'params *params)) (lambda () (string-append (string-append (string-append (raw-value params.q) " (order=") (raw-value params.order)) ")"))))

(define-server SearchServer
  #:api SearchApi
  [search search]
)

(module+ test
  (require rackunit)
  (test-case "reads a required query parameter (optional defaults)"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "q=widgets" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref resp 'body)) "widgets (order=asc)")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "url-encoded values are decoded (%20 -> space)"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "q=red%20widgets" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'body)) "red widgets (order=asc)")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an optional parameter overrides its default"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "q=widgets&order=desc" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'body)) "widgets (order=desc)")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "repeated keys are last-wins"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "q=first&q=second" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'body)) "second (order=asc)")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a missing required parameter is rejected"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))
          ))
      ))
  )
)
