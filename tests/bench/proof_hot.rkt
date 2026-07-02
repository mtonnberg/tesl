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


(provide hotPath checkBound checkBound-signature hotPath-signature)

(define Bounded 'Bounded)

(define-checker
  (checkBound [n : Integer])
  #:returns [n : Integer ::: (Bounded n)]
  (thsl-src! "tests/bench/proof_hot.tesl" 23 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 1000000)) (accept (Bounded n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define/pow
  (hotPath [a : Integer ::: (Bounded a)] [b : Integer ::: (Bounded b)] [c : Integer ::: (Bounded c)])
  #:returns Integer
  (thsl-src! "tests/bench/proof_hot.tesl" 29 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (+ (+ *a *b) *c))))

(module+ test
  (require rackunit)
  (test-case "hot path sums three bounded values"
  (define one (thsl-src! "tests/bench/proof_hot.tesl" 32 (list) (lambda () 1)))
  (define two (thsl-src! "tests/bench/proof_hot.tesl" 33 (list (cons 'one one)) (lambda () 2)))
  (define three (thsl-src! "tests/bench/proof_hot.tesl" 34 (list (cons 'two two) (cons 'one one)) (lambda () 3)))
  (define tesl-checked-0 (checkBound one))
  (when (check-fail? tesl-checked-0)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl-checked-0)))
  (define a tesl-checked-0)
  (define tesl-checked-1 (checkBound two))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl-checked-1)))
  (define b tesl-checked-1)
  (define tesl-checked-2 (checkBound three))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let c: ~a" (check-fail-message tesl-checked-2)))
  (define c tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "tests/bench/proof_hot.tesl" 38 (list (cons 'c c) (cons 'b b) (cons 'a a) (cons 'three three) (cons 'two two) (cons 'one one)) (lambda () (hotPath a b c)))) 6)
  )

)
