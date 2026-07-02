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
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide )

(define-entity Order
  #:source (make-hash)
  #:table orders
  #:primary-key id
  [Id id : String]
  [Status status : String]
)

(define-database OrderDb
  #:backend memory
  #:schema orders
  #:entities Order)

(define/pow
  (statusOf [orderId : String])
  #:capabilities [dbRead]
  #:returns String
  (thsl-src-control! "tests/db-write-test-body-tests.tesl" 34 (list (cons 'orderId *orderId)) (lambda () (let ([tesl-case-0 (raw-value (let ([tesl_match (select-one (from Order) (where (==. (entity-field-ref Order 'id) orderId)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([o (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/db-write-test-body-tests.tesl" 35 (list (cons 'o o)) (lambda () (raw-value (raw-value o.status)))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/db-write-test-body-tests.tesl" 36 (list) (lambda () (raw-value "no such order")))])))))

(module+ test
  (require rackunit)
  (test-case "insertMany works in a test body with a `seed`-named local"
    (with-capabilities (dbRead dbWrite)
    (define seed (thsl-src! "tests/db-write-test-body-tests.tesl" 39 (list) (lambda () (list (hash 'id "o1" 'status "new")))))
    (insert-many! (from Order) seed)
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 41 (list (cons 'seed seed)) (lambda () (statusOf "o1")))) "new")
    )
  )

  (test-case "multi-line update runs in a test body"
    (with-capabilities (dbRead dbWrite)
    (define rows (thsl-src! "tests/db-write-test-body-tests.tesl" 45 (list) (lambda () (list (hash 'id "o3" 'status "new")))))
    (insert-many! (from Order) rows)
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 47 (list (cons 'rows rows)) (lambda () (statusOf "o3")))) "new")
    (void (update-many! (from Order) (hash (entity-field-ref Order 'status) "shipped") (where (==. (entity-field-ref Order 'id) "o3"))))
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 51 (list (cons 'rows rows)) (lambda () (statusOf "o3")))) "shipped")
    )
  )

  (test-case "single-line delete runs in a test body"
    (with-capabilities (dbRead dbWrite)
    (define rows (thsl-src! "tests/db-write-test-body-tests.tesl" 55 (list) (lambda () (list (hash 'id "o4" 'status "new")))))
    (insert-many! (from Order) rows)
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 57 (list (cons 'rows rows)) (lambda () (statusOf "o4")))) "new")
    (delete-many! (from Order) (where (==. (entity-field-ref Order 'id) "o4")))
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 59 (list (cons 'rows rows)) (lambda () (statusOf "o4")))) "no such order")
    )
  )

  (test-case "multi-line delete runs in a test body"
    (with-capabilities (dbRead dbWrite)
    (define rows (thsl-src! "tests/db-write-test-body-tests.tesl" 67 (list) (lambda () (list (hash 'id "o5" 'status "new")))))
    (insert-many! (from Order) rows)
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 69 (list (cons 'rows rows)) (lambda () (statusOf "o5")))) "new")
    (delete-many! (from Order) (where (==. (entity-field-ref Order 'id) "o5")))
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 72 (list (cons 'rows rows)) (lambda () (statusOf "o5")))) "no such order")
    )
  )

  (test-case "multi-line delete with a compound predicate removes only the match"
    (with-capabilities (dbRead dbWrite)
    (define rows (thsl-src! "tests/db-write-test-body-tests.tesl" 76 (list) (lambda () (list (hash 'id "keep" 'status "us") (hash 'id "drop" 'status "eu")))))
    (insert-many! (from Order) rows)
    (delete-many! (from Order) (where (==. (entity-field-ref Order 'id) "drop")) (where (==. (entity-field-ref Order 'status) "eu")))
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 80 (list (cons 'rows rows)) (lambda () (statusOf "drop")))) "no such order")
    (check-equal? (raw-value (thsl-src! "tests/db-write-test-body-tests.tesl" 81 (list (cons 'rows rows)) (lambda () (statusOf "keep")))) "us")
    )
  )

)
