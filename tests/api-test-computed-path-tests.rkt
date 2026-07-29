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
  (only-in tesl/tesl/queue pubsub)
  (only-in tesl/tesl/api-test statusOk statusClientError subscribe collect isNotEmpty includesWhere)
)


(provide PathServer)

(define ValidQuery 'ValidQuery)

(define-database PathDb
  #:backend memory
  #:schema api_test_computed_path
  #:entities )

(define-record Created
  [id : String]
)

(define-record Notice
  [message : String]
)

(define (tesl-codec-encode-Notice _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'message (tesl-encode-prim-string (raw-value (hash-ref _fields 'message)))
  ))
(define (tesl-codec-decode-Notice-0 _j)
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'Notice (hash 'message _f_message)))
(register-type-codec! 'Notice tesl-codec-encode-Notice (list tesl-codec-decode-Notice-0))

(define-channel Notices)

(define-auther
  (parseQuery [req : HttpRequest])
  #:returns [q : String ::: (ValidQuery q)]
  (thsl-src-control! "tests/api-test-computed-path-tests.tesl" 71 (list (cons 'req *req)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "q" (raw-value req.queryParameters)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/api-test-computed-path-tests.tesl" 72 (list) (lambda () (reject "missing required query parameter: q" #:http-code 400)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([found (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/api-test-computed-path-tests.tesl" 73 (list (cons 'found found)) (lambda () (accept (ValidQuery found) #:value *found))))])))))

(define-capture idCapture
  [id : String]
  #:parser string-segment)

(define-handler
  (getThing [id : String])
  #:returns String
  (thsl-src! "tests/api-test-computed-path-tests.tesl" 78 (list (cons 'id *id)) (lambda () (string-append "thing-" *id))))

(define-handler
  (createThing)
  #:returns Created
  (thsl-src! "tests/api-test-computed-path-tests.tesl" 81 (list) (lambda () (Created #:id "generated-1"))))

(define-handler
  (search [q : String ::: (ValidQuery q)])
  #:returns String
  (thsl-src! "tests/api-test-computed-path-tests.tesl" 84 (list (cons 'q *q)) (lambda () (string-append "found-" *q))))

(define-handler
  (notify [topic : String])
  #:capabilities [pubsub]
  #:returns String
  (let ([_ (thsl-src! "tests/api-test-computed-path-tests.tesl" 88 (list (cons 'topic *topic)) (lambda () (publish-event! Notices (format "~a" *topic) (Notice #:message (string-append "notice-" *topic)))))]) (thsl-src! "tests/api-test-computed-path-tests.tesl" 89 (list (cons 'topic *topic)) (lambda () "ok"))))

(define PathServer-sse-routes
  (list (list (list "events" #f) #f Notices 1 (list (cons 1 (sse-key-capture idCapture))))))
(define-api PathApi
  [getThing :
    "things"
    :> (Capture idCapture [id : String])
    :> (Get JSON String)
    ]
  [createThing :
    "things"
    :> (Post JSON Created)
    ]
  [search :
    (Auth [q : String ::: (ValidQuery q)] #:via parseQuery)
    :> "search"
    :> (Get JSON String)
    ]
  [notify :
    "notify"
    :> (Capture idCapture [id : String])
    :> (Post JSON String)
    ]
)

(define-server PathServer
  #:api PathApi
  [getThing getThing]
  [createThing createThing]
  [search search]
  [notify notify]
)

(module+ test
  (require rackunit)
  (test-case "a literal path routes"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 122 (list) (lambda () (dispatch-api-test-request PathServer 'get (list "things" "7") #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 123 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 124 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "thing-7")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a let-bound path routes like the literal"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define p (thsl-src! "tests/api-test-computed-path-tests.tesl" 130 (list) (lambda () "/things/7")))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 131 (list (cons 'p p)) (lambda () (dispatch-api-test-request PathServer 'get p #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 132 (list (cons 'r r) (cons 'p p)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 133 (list (cons 'r r) (cons 'p p)) (lambda () (api-test-field-access-ref r 'body)))) "thing-7")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a concatenated path routes"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define id (thsl-src! "tests/api-test-computed-path-tests.tesl" 137 (list) (lambda () "42")))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 138 (list (cons 'id id)) (lambda () (dispatch-api-test-request PathServer 'get (string-append (api-test-string-fragment "/things/") (api-test-string-fragment id)) #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 139 (list (cons 'r r) (cons 'id id)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 140 (list (cons 'r r) (cons 'id id)) (lambda () (api-test-field-access-ref r 'body)))) "thing-42")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an interpolated path routes"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define id (thsl-src! "tests/api-test-computed-path-tests.tesl" 144 (list) (lambda () "9")))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 145 (list (cons 'id id)) (lambda () (dispatch-api-test-request PathServer 'get (format "/things/~a" (tesl-display-val id)) #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 146 (list (cons 'r r) (cons 'id id)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 147 (list (cons 'r r) (cons 'id id)) (lambda () (api-test-field-access-ref r 'body)))) "thing-9")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a path built from a previous response's body routes"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define created (thsl-src! "tests/api-test-computed-path-tests.tesl" 153 (list) (lambda () (dispatch-api-test-request PathServer 'post (list "things") #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 154 (list (cons 'created created)) (lambda () (statusOk (raw-value (api-test-field-access-ref created 'status)))))))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 155 (list (cons 'created created)) (lambda () (dispatch-api-test-request PathServer 'get (string-append (api-test-string-fragment "/things/") (api-test-string-fragment (api-test-field-access-ref (api-test-field-access-ref created 'body) 'id))) #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 156 (list (cons 'r r) (cons 'created created)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 157 (list (cons 'r r) (cons 'created created)) (lambda () (api-test-field-access-ref r 'body)))) "thing-generated-1")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a path built from a let-bound response field routes"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define created (thsl-src! "tests/api-test-computed-path-tests.tesl" 163 (list) (lambda () (dispatch-api-test-request PathServer 'post (list "things") #:headers (hash) #:capabilities '()))))
            (define id (thsl-src! "tests/api-test-computed-path-tests.tesl" 164 (list (cons 'created created)) (lambda () (api-test-field-access-ref (api-test-field-access-ref created 'body) 'id))))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 165 (list (cons 'id id) (cons 'created created)) (lambda () (dispatch-api-test-request PathServer 'get (string-append (api-test-string-fragment "/things/") (api-test-string-fragment id)) #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 166 (list (cons 'r r) (cons 'id id) (cons 'created created)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 167 (list (cons 'r r) (cons 'id id) (cons 'created created)) (lambda () (api-test-field-access-ref r 'body)))) "thing-generated-1")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a literal path keeps its query string"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 173 (list) (lambda () (dispatch-api-test-request PathServer 'get (list "search") #:query "q=widgets" #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 174 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 175 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'body)))) "found-widgets")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a computed path keeps its query string"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define p (thsl-src! "tests/api-test-computed-path-tests.tesl" 179 (list) (lambda () "/search?q=widgets")))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 180 (list (cons 'p p)) (lambda () (dispatch-api-test-request PathServer 'get p #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 181 (list (cons 'r r) (cons 'p p)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 182 (list (cons 'r r) (cons 'p p)) (lambda () (api-test-field-access-ref r 'body)))) "found-widgets")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a concatenated query string is parsed"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define term (thsl-src! "tests/api-test-computed-path-tests.tesl" 186 (list) (lambda () "gadgets")))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 187 (list (cons 'term term)) (lambda () (dispatch-api-test-request PathServer 'get (string-append (api-test-string-fragment "/search?q=") (api-test-string-fragment term)) #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 188 (list (cons 'r r) (cons 'term term)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 189 (list (cons 'r r) (cons 'term term)) (lambda () (api-test-field-access-ref r 'body)))) "found-gadgets")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a computed path with no query still reaches the 400"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define p (thsl-src! "tests/api-test-computed-path-tests.tesl" 193 (list) (lambda () "/search")))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 194 (list (cons 'p p)) (lambda () (dispatch-api-test-request PathServer 'get p #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 195 (list (cons 'r r) (cons 'p p)) (lambda () (statusClientError (raw-value (api-test-field-access-ref r 'status)))))))
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a computed path that matches no route 404s"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define p (thsl-src! "tests/api-test-computed-path-tests.tesl" 201 (list) (lambda () "/nope/nowhere")))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 202 (list (cons 'p p)) (lambda () (dispatch-api-test-request PathServer 'get p #:headers (hash) #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 203 (list (cons 'r r) (cons 'p p)) (lambda () (api-test-field-access-ref r 'status)))) 404)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a computed path tolerates a trailing slash"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define p (thsl-src! "tests/api-test-computed-path-tests.tesl" 209 (list) (lambda () "/things/7/")))
            (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 210 (list (cons 'p p)) (lambda () (dispatch-api-test-request PathServer 'get p #:headers (hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 211 (list (cons 'r r) (cons 'p p)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 212 (list (cons 'r r) (cons 'p p)) (lambda () (api-test-field-access-ref r 'body)))) "thing-7")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a literal subscribe path streams"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (pubsub)
              (define stream (thsl-src! "tests/api-test-computed-path-tests.tesl" 218 (list) (lambda () (subscribe PathServer-sse-routes (list "events" "topic-1") #:headers (hash) #:name "/events/topic-1"))))
              (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 219 (list (cons 'stream stream)) (lambda () (dispatch-api-test-request PathServer 'post (list "notify" "topic-1") #:headers (hash) #:capabilities (list pubsub)))))
              (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 220 (list (cons 'r r) (cons 'stream stream)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (define events (thsl-src! "tests/api-test-computed-path-tests.tesl" 221 (list (cons 'r r) (cons 'stream stream)) (lambda () (collect (raw-value stream) #:count 1 #:timeout-ms 1500))))
              (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 222 (list (cons 'events events) (cons 'r r) (cons 'stream stream)) (lambda () (isNotEmpty (raw-value events))))))
              (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 223 (list (cons 'events events) (cons 'r r) (cons 'stream stream)) (lambda () (includesWhere (hash 'message "notice-topic-1") (raw-value events))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a computed subscribe path streams like the literal"
    (call-with-fresh-memory-db (list PathDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (pubsub)
              (define topic (thsl-src! "tests/api-test-computed-path-tests.tesl" 227 (list) (lambda () "topic-2")))
              (define stream (thsl-src! "tests/api-test-computed-path-tests.tesl" 228 (list (cons 'topic topic)) (lambda () (subscribe PathServer-sse-routes (string-append (api-test-string-fragment "/events/") (api-test-string-fragment topic)) #:headers (hash) #:name ""))))
              (define r (thsl-src! "tests/api-test-computed-path-tests.tesl" 229 (list (cons 'stream stream) (cons 'topic topic)) (lambda () (dispatch-api-test-request PathServer 'post (string-append (api-test-string-fragment "/notify/") (api-test-string-fragment topic)) #:headers (hash) #:capabilities (list pubsub)))))
              (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 230 (list (cons 'r r) (cons 'stream stream) (cons 'topic topic)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
              (define events (thsl-src! "tests/api-test-computed-path-tests.tesl" 231 (list (cons 'r r) (cons 'stream stream) (cons 'topic topic)) (lambda () (collect (raw-value stream) #:count 1 #:timeout-ms 1500))))
              (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 232 (list (cons 'events events) (cons 'r r) (cons 'stream stream) (cons 'topic topic)) (lambda () (isNotEmpty (raw-value events))))))
              (check-true (raw-value (thsl-src! "tests/api-test-computed-path-tests.tesl" 233 (list (cons 'events events) (cons 'r r) (cons 'stream stream) (cons 'topic topic)) (lambda () (includesWhere (hash 'message "notice-topic-2") (raw-value events))))))
            )
          ))
      ))
  )
)
