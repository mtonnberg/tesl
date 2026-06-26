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


(provide hotPath checkBound checkBound-signature hotPath-signature)

(define Bounded 'Bounded)

(define-checker
  (checkBound [n : Integer])
  #:returns [n : Integer ::: (Bounded n)]
  (if (and (>= *n 0) (<= *n 1000000)) (accept (Bounded n) #:value *n) (reject "out of bounds" #:http-code 400)))

(define/pow
  (hotPath [a : Integer ::: (Bounded a)] [b : Integer ::: (Bounded b)] [c : Integer ::: (Bounded c)])
  #:returns Integer
  (+ (+ *a *b) *c))

(module+ test
  (require rackunit)
  (test-case "hot path sums three bounded values"
  (define one 1)
  (define two 2)
  (define three 3)
  (define tesl_checked_0 (checkBound one))
  (when (check-fail? tesl_checked_0)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl_checked_0)))
  (define a tesl_checked_0)
  (define tesl_checked_1 (checkBound two))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl_checked_1)))
  (define b tesl_checked_1)
  (define tesl_checked_2 (checkBound three))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let c: ~a" (check-fail-message tesl_checked_2)))
  (define c tesl_checked_2)
  (check-equal? (raw-value (hotPath a b c)) 6)
  )

)
