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
)


(provide TemplateServer)

(define-handler
  (emptyObject)
  #:returns String
  (thsl-src! "tests/api-test-template-tests.tesl" 40 (list) (lambda () "{}")))

(define-handler
  (jsonObject)
  #:returns String
  (thsl-src! "tests/api-test-template-tests.tesl" 43 (list) (lambda () "{\"id\": 1}")))

(define-handler
  (unbalancedQuote)
  #:returns String
  (thsl-src! "tests/api-test-template-tests.tesl" 46 (list) (lambda () "{\"}")))

(define-handler
  (unclosedBrace)
  #:returns String
  (thsl-src! "tests/api-test-template-tests.tesl" 49 (list) (lambda () "a { b")))

(define-handler
  (nestedBraces)
  #:returns String
  (thsl-src! "tests/api-test-template-tests.tesl" 52 (list) (lambda () "{\"a\": {\"b\": 2}}")))

(define-capture idCapture
  [id : String]
  #:parser string-segment)

(define-handler
  (echoThing [id : String])
  #:returns String
  (thsl-src! "tests/api-test-template-tests.tesl" 57 (list (cons 'id *id)) (lambda () (string-append "thing-" *id))))

(define TemplateServer-sse-routes '())
(define-api TemplateApi
  [endpoint_0 :
    "empty"
    :> (Get JSON String)
    ]
  [endpoint_1 :
    "json"
    :> (Get JSON String)
    ]
  [endpoint_2 :
    "quote"
    :> (Get JSON String)
    ]
  [endpoint_3 :
    "unclosed"
    :> (Get JSON String)
    ]
  [endpoint_4 :
    "nested"
    :> (Get JSON String)
    ]
  [endpoint_5 :
    "things"
    :> (Capture idCapture [id : String])
    :> (Get JSON String)
    ]
)

(define-server TemplateServer
  #:api TemplateApi
  [endpoint_0 emptyObject]
  [endpoint_1 jsonObject]
  [endpoint_2 unbalancedQuote]
  [endpoint_3 unclosedBrace]
  [endpoint_4 nestedBraces]
  [endpoint_5 echoThing]
)

(define-database TemplateDb
  #:backend memory
  #:entities )

(module+ test
  (require rackunit)
  (test-case "TPL-01: an empty pair of braces is the literal `{}`"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 92 (list) (lambda () (dispatch-api-test-request TemplateServer 'get (list "empty") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 93 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 94 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "{}")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-02: a JSON object literal survives whole, not truncated to its first token"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 98 (list) (lambda () (dispatch-api-test-request TemplateServer 'get (list "json") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 99 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 100 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "{\"id\": 1}")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-03: an unbalanced quote inside braces compiles and compares as text"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 104 (list) (lambda () (dispatch-api-test-request TemplateServer 'get (list "quote") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 105 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 106 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "{\"}")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-04: an unclosed brace is text"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 110 (list) (lambda () (dispatch-api-test-request TemplateServer 'get (list "unclosed") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 111 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 112 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) (string-append "a " "{ b"))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-05: nested braces survive whole"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 116 (list) (lambda () (dispatch-api-test-request TemplateServer 'get (list "nested") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 117 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 118 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) (string-append "{\"a\": {\"b\": 2}" "}"))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-06: braces mixed with surrounding text keep both parts"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 122 (list) (lambda () (dispatch-api-test-request TemplateServer 'get (list "empty") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 123 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 124 (list (cons 'r r)) (lambda () (string-append (api-test-string-fragment "payload: ") (api-test-string-fragment (api-test-field-access-ref r 'body)))))) (string-append "payload: " "{}"))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-07: a bare-brace slot in a PATH still interpolates"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define id (thsl-src! "tests/api-test-template-tests.tesl" 130 (list) (lambda () "9")))
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 131 (list (cons 'id id)) (lambda () (dispatch-api-test-request TemplateServer 'get (list "things" (api-test-path-fragment (raw-value id))) #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 132 (list (cons 'r r) (cons 'id id)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 133 (list (cons 'r r) (cons 'id id)) (lambda () (api-test-field-access-ref r 'body)))) "thing-9")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-08: a bare-brace slot in an expected STRING still interpolates"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define id (thsl-src! "tests/api-test-template-tests.tesl" 137 (list) (lambda () "9")))
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 138 (list (cons 'id id)) (lambda () (dispatch-api-test-request TemplateServer 'get (list "things" (api-test-path-fragment (raw-value id))) #:headers (tesl-hash) #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 139 (list (cons 'r r) (cons 'id id)) (lambda () (api-test-field-access-ref r 'body)))) (string-append "thing-" (api-test-string-fragment (raw-value id))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-09: a dotted slot (a field of an earlier response) still interpolates"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define first (thsl-src! "tests/api-test-template-tests.tesl" 143 (list) (lambda () (dispatch-api-test-request TemplateServer 'get (list "things" "7") #:headers (tesl-hash) #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 144 (list (cons 'first first)) (lambda () (api-test-field-access-ref first 'body)))) "thing-7")
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 145 (list (cons 'first first)) (lambda () (dispatch-api-test-request TemplateServer 'get (list "things" (api-test-path-fragment (raw-value (api-test-field-access-ref first 'body)))) #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 146 (list (cons 'r r) (cons 'first first)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 147 (list (cons 'r r) (cons 'first first)) (lambda () (api-test-field-access-ref r 'body)))) "thing-thing-7")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "TPL-10: Tesl's own dollar-brace interpolation is unaffected"
    (call-with-fresh-memory-db (list TemplateDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define id (thsl-src! "tests/api-test-template-tests.tesl" 151 (list) (lambda () "5")))
            (define r (thsl-src! "tests/api-test-template-tests.tesl" 152 (list (cons 'id id)) (lambda () (dispatch-api-test-request TemplateServer 'get (format "/things/~a" (tesl-display-val id)) #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 153 (list (cons 'r r) (cons 'id id)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-template-tests.tesl" 154 (list (cons 'r r) (cons 'id id)) (lambda () (api-test-field-access-ref r 'body)))) "thing-5")
          ))
      ))
  )
)
