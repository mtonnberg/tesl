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
  (only-in tesl/tesl/prelude Bool Int List String)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/time PosixMillis nowMillis time addMs subtractMs)
  (only-in tesl/tesl/list [List.length tesl_import_List_length])
)


(provide )

(define-entity Ev
  #:source (make-hash)
  #:table ev_range
  #:primary-key id
  [Id id : String]
  [At at : PosixMillis]
)

(define/pow
  (inWindow [lo : PosixMillis] [hi : PosixMillis])
  #:capabilities [dbRead]
  #:returns Integer
  (let ([hits (thsl-src! "tests/sql-newtype-range-tests.tesl" 19 (list (cons 'lo *lo) (cons 'hi *hi)) (lambda () (select-many (from Ev) (where (>=. (entity-field-ref Ev 'at) lo)) (where (<=. (entity-field-ref Ev 'at) hi)))))]) (thsl-src! "tests/sql-newtype-range-tests.tesl" 20 (list (cons 'hits *hits) (cons 'lo *lo) (cons 'hi *hi)) (lambda () (raw-value (tesl_import_List_length (raw-value hits)))))))

(module+ test
  (require rackunit)
  (test-case "PosixMillis range in select-where works (was a runtime trap, #28)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite time)
    (define now (thsl-src! "tests/sql-newtype-range-tests.tesl" 23 (list) (lambda () (raw-value (nowMillis)))))
    (define tesl-ignored-0 (thsl-src! "tests/sql-newtype-range-tests.tesl" 24 (list (cons 'now now)) (lambda () (insert-one! Ev (hash 'id "a" 'at now)))))
    (define lo (thsl-src! "tests/sql-newtype-range-tests.tesl" 25 (list (cons 'now now)) (lambda () (subtractMs (raw-value now) 1000))))
    (define hi (thsl-src! "tests/sql-newtype-range-tests.tesl" 26 (list (cons 'lo lo) (cons 'now now)) (lambda () (addMs (raw-value now) 1000))))
    (check-equal? (raw-value (thsl-src! "tests/sql-newtype-range-tests.tesl" 27 (list (cons 'hi hi) (cons 'lo lo) (cons 'now now)) (lambda () (inWindow lo hi)))) 1)
    )
    ))
  )

  (test-case "PosixMillis range excludes out-of-window rows (#28)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite time)
    (define now (thsl-src! "tests/sql-newtype-range-tests.tesl" 31 (list) (lambda () (raw-value (nowMillis)))))
    (define tesl-ignored-1 (thsl-src! "tests/sql-newtype-range-tests.tesl" 32 (list (cons 'now now)) (lambda () (insert-one! Ev (hash 'id "b" 'at now)))))
    (define lo (thsl-src! "tests/sql-newtype-range-tests.tesl" 33 (list (cons 'now now)) (lambda () (addMs (raw-value now) 5000))))
    (define hi (thsl-src! "tests/sql-newtype-range-tests.tesl" 34 (list (cons 'lo lo) (cons 'now now)) (lambda () (addMs (raw-value now) 9000))))
    (check-equal? (raw-value (thsl-src! "tests/sql-newtype-range-tests.tesl" 35 (list (cons 'hi hi) (cons 'lo lo) (cons 'now now)) (lambda () (inWindow lo hi)))) 0)
    )
    ))
  )

)
