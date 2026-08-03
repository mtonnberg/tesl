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
  (only-in tesl/tesl/prelude Bool Int List)
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.length tesl_import_List_length])
)


(provide )

(define AtLeast 'AtLeast)
(define AtMost 'AtMost)
(define InBounds 'InBounds)

(define-checker
  (checkInBounds [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InBounds lo hi n)]
  (thsl-src! "tests/filter-check-partial-tests.tesl" 31 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (tesl-le? *lo *n) (tesl-le? *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define-checker
  (checkAtLeast [lo : Integer] [n : Integer])
  #:returns [n : Integer ::: (AtLeast lo n)]
  (thsl-src! "tests/filter-check-partial-tests.tesl" 37 (list (cons 'lo *lo) (cons 'n *n)) (lambda () (if (tesl-ge? *n *lo) (accept (AtLeast lo n) #:value *n) (reject "too small" #:http-code 400)))))

(define-checker
  (checkAtMost [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (AtMost hi n)]
  (thsl-src! "tests/filter-check-partial-tests.tesl" 43 (list (cons 'hi *hi) (cons 'n *n)) (lambda () (if (tesl-le? *n *hi) (accept (AtMost hi n) #:value *n) (reject "too big" #:http-code 400)))))

(define/pow
  (atMostAll [xs : (List Integer)] [hi : Integer])
  #:returns (List Integer)
  (thsl-src! "tests/filter-check-partial-tests.tesl" 50 (list (cons 'xs *xs) (cons 'hi *hi)) (lambda () (tesl_import_List_filterCheck (raw-value (lambda (tesl-p-0-0) (checkAtMost *hi tesl-p-0-0))) *xs))))

(module+ test
  (require rackunit)
  (test-case "filterCheck with a partially-applied check function"
    (call-with-fresh-memory-db '() (lambda ()
  (define xs (thsl-src! "tests/filter-check-partial-tests.tesl" 53 (list) (lambda () (list 1 50 200 99))))
  (define result (thsl-src! "tests/filter-check-partial-tests.tesl" 54 (list (cons 'xs xs)) (lambda () (tesl_import_List_filterCheck (raw-value (lambda (tesl-p-1-0) (checkInBounds 0 100 tesl-p-1-0))) (raw-value xs)))))
  (check-equal? (raw-value (thsl-src! "tests/filter-check-partial-tests.tesl" 55 (list (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "both halves of a partially-applied check combination run"
    (call-with-fresh-memory-db '() (lambda ()
  (define xs (thsl-src! "tests/filter-check-partial-tests.tesl" 59 (list) (lambda () (list -7 1 50 200 99))))
  (define result (thsl-src! "tests/filter-check-partial-tests.tesl" 60 (list (cons 'xs xs)) (lambda () (tesl_import_List_filterCheck (check-and (lambda (tesl-p-2-0) (checkAtLeast 0 tesl-p-2-0)) (lambda (tesl-p-3-0) (checkAtMost 100 tesl-p-3-0))) (raw-value xs)))))
  (check-equal? (raw-value (thsl-src! "tests/filter-check-partial-tests.tesl" 61 (list (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "ForAll established through a partially-applied check"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/filter-check-partial-tests.tesl" 65 (list) (lambda () (atMostAll (list 1 500 7) 100))))
  (check-equal? (raw-value (thsl-src! "tests/filter-check-partial-tests.tesl" 66 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 2)
    ))
  )

)
