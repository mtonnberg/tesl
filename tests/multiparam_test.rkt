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
  (only-in tesl/tesl/prelude Bool Int String Fact)
)


(provide checkInBounds requiresInBounds checkInBounds-signature requiresInBounds-signature)

(define InBounds 'InBounds)

(define-checker
  (checkInBounds [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InBounds lo hi n)]
  (thsl-src! "tests/multiparam_test.tesl" 9 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (>= *n *lo) (<= *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define/pow
  (requiresInBounds [lo : Integer] [hi : Integer] [n : Integer ::: (InBounds lo hi n)])
  #:returns String
  (thsl-src! "tests/multiparam_test.tesl" 15 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (format "~a is in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))))

(module+ test
  (require rackunit)
  (test-case "full round-trip: check then require"
    (call-with-fresh-memory-db '() (lambda ()
  (define lo (thsl-src! "tests/multiparam_test.tesl" 18 (list) (lambda () 1)))
  (define hi (thsl-src! "tests/multiparam_test.tesl" 19 (list (cons 'lo lo)) (lambda () 10)))
  (define n (thsl-src! "tests/multiparam_test.tesl" 20 (list (cons 'hi hi) (cons 'lo lo)) (lambda () 5)))
  (define tesl-checked-0 (checkInBounds lo hi n))
  (when (check-fail? tesl-checked-0)
    (raise-user-error 'tesl-test "unexpected failure in let x: ~a" (check-fail-message tesl-checked-0)))
  (define x tesl-checked-0)
  (check-equal? (raw-value (thsl-src! "tests/multiparam_test.tesl" 22 (list (cons 'x x) (cons 'n n) (cons 'hi hi) (cons 'lo lo)) (lambda () (requiresInBounds lo hi x)))) "5 is in [1, 10]")
    ))
  )

)
