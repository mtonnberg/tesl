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
  (only-in tesl/tesl/api-test statusOk statusClientError)
)


(provide SearchServer)

(define QueryAuthed 'QueryAuthed)

(define-auther
  (queryAuth [req : HttpRequest])
  #:returns [q : String ::: (QueryAuthed q)]
  (thsl-src-control! "tests/query-parameters-tests.tesl" 14 (list (cons 'req *req)) (lambda () (let ([tesl_case_0 (raw-value (tesl_import_Dict_lookup "q" (raw-value req.queryParameters)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (thsl-src! "tests/query-parameters-tests.tesl" 15 (list) (lambda () (reject "missing q query parameter" #:http-code 400)))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (thsl-src! "tests/query-parameters-tests.tesl" 16 (list (cons 'v v)) (lambda () (accept (QueryAuthed v) #:value *v))))])))))

(define SearchServer-sse-routes '())
(define-api SearchApi
  [search :
    (Auth [q : String ::: (QueryAuthed q)] #:via queryAuth)
    :> "search"
    :> (Get JSON String)
    ]
)

(define-handler
  (search [q : String ::: (QueryAuthed q)])
  #:returns String
  (thsl-src! "tests/query-parameters-tests.tesl" 24 (list (cons 'q *q)) (lambda () q)))

(define-server SearchServer
  #:api SearchApi
  [search search]
)

(module+ test
  (require rackunit)
  (test-case "query parameter q is read"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "q=hello" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref resp 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref resp 'body)) "hello")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "url-encoded query value is decoded (%20 -> space)"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "q=hello%20world" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'body)) "hello world")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "repeated key: last wins"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "q=first&q=second" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'body)) "second")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "extra distinct params do not interfere"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "other=beta&q=alpha" #:headers (hash) #:capabilities '()))
            (check-equal? (raw-value (api-test-field-access-ref resp 'body)) "alpha")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "missing query parameter \226\134\146 client error"
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

(module+ test
  (require rackunit)
  (test-case "different key present, q absent \226\134\146 client error"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (dispatch-api-test-request SearchServer 'get (list "search") #:query "notq=x" #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))
          ))
      ))
  )
)
