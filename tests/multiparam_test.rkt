#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
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
  (if (and (>= *n *lo) (<= *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))

(define/pow
  (requiresInBounds [lo : Integer] [hi : Integer] [n : Integer ::: (InBounds lo hi n)])
  #:returns String
  (format "~a is in [~a, ~a]" (raw-value *n) (raw-value *lo) (raw-value *hi)))

(module+ test
  (require rackunit)
  (test-case "full round-trip: check then require"
  (define lo 1)
  (define hi 10)
  (define n 5)
  (define x (checkInBounds lo hi n))
  (check-equal? (raw-value (requiresInBounds lo hi x)) "5 is in [1, 10]")
  )

)
