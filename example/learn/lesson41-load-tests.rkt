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
  (only-in tesl/tesl/prelude Int String List)
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide Lesson41Server)

(define-record Greeting
  [name : String]
  [message : String]
)

(define (tesl-codec-encode-Greeting _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'name (tesl-encode-prim-string (raw-value (hash-ref _fields 'name)))
        'message (tesl-encode-prim-string (raw-value (hash-ref _fields 'message)))
  ))
(define (tesl-codec-decode-Greeting-0 _j)
  (define _f_name (tesl-decode-prim-field _j "name" tesl-decode-prim-string))
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'Greeting (hash 'name _f_name 'message _f_message)))
(register-type-codec! 'Greeting tesl-codec-encode-Greeting (list tesl-codec-decode-Greeting-0))

(define-entity Book
  #:source (make-hash)
  #:table books
  #:primary-key id
  [Id id : String]
  [Title title : String]
  [Pages pages : Integer]
)

(define-database Lesson41Database
  #:backend postgres
  #:database "lesson41"
  #:user "lesson41"
  #:password "lesson41"
  #:server "localhost"
  #:port 5432
  #:schema lesson41
  #:entities Book)

(define-handler
  (greet [g : Greeting])
  #:returns Greeting
  (thsl-src! "example/learn/lesson41-load-tests.tesl" 60 (list (cons 'g *g)) (lambda () (Greeting #:name (raw-value g.name) #:message (format "Hello, ~a!" (tesl-display-val (raw-value g.name)))))))

(define-handler
  (listBooks)
  #:capabilities [dbRead]
  #:returns (List Book)
  (thsl-src! "example/learn/lesson41-load-tests.tesl" 64 (list) (lambda () (select-many (from Book)))))

(define Lesson41Server-sse-routes '())
(define-api Lesson41Api
  [greet :
    "greet"
    :> (ReqBody JSON [g : Greeting])
    :> (Post JSON Greeting)
    ]
  [listBooks :
    "books"
    :> (Get JSON (List Book))
    ]
)

(define-server Lesson41Server
  #:api Lesson41Api
  [greet greet]
  [listBooks listBooks]
)

(module+ test
  (require rackunit tesl/dsl/load-test)
  (test-case "greet throughput"
    (call-with-fresh-memory-db (list Lesson41Database)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (run-load-test Lesson41Server 50 2
              (lambda ()
                (dispatch-api-test-request Lesson41Server 'post (list "greet") #:headers (hash) #:body (hash (string->symbol "name") "bench" (string->symbol "message") "") #:capabilities '())
              )
              #:assertions (list (load-test-assert 'p99 '< 500) (load-test-assert 'error-rate '< 0.05))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit tesl/dsl/load-test)
  (test-case "list books with seeded data"
    (call-with-fresh-memory-db (list Lesson41Database)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (insert-one! Book (hash 'id "book-1" 'title "The Art of Tesl" 'pages 320))
              (insert-one! Book (hash 'id "book-2" 'title "Proofs in Practice" 'pages 210))
              (run-load-test Lesson41Server 30 2
                (lambda ()
                  (dispatch-api-test-request Lesson41Server 'get (list "books") #:headers (hash) #:capabilities (list dbRead dbWrite))
                )
                #:assertions (list (load-test-assert 'p95 '< 500) (load-test-assert 'error-rate '< 0.05))
              )
            )
          ))
      ))
  )
)
