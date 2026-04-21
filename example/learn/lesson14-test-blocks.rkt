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
  (only-in tesl/tesl/prelude Int)
)


(provide factorial fibonacci clamp factorial-signature fibonacci-signature clamp-signature)

(define/pow
  (factorial [n : Integer])
  #:returns Integer
  (if (<= *n 0) (raw-value 1) (raw-value (* *n (raw-value (factorial (- *n 1)))))))

(define/pow
  (fibonacci [n : Integer])
  #:returns Integer
  (if (<= *n 1) *n (raw-value (+ (raw-value (fibonacci (- *n 1))) (raw-value (fibonacci (- *n 2)))))))

(define/pow
  (clamp [lo : Integer] [hi : Integer] [n : Integer])
  #:returns Integer
  (if (< *n *lo) *lo (if (> *n *hi) *hi *n)))

(module+ test
  (require rackunit)
  (test-case "factorial"
  (check-equal? (raw-value (factorial 0)) 1)
  (check-equal? (raw-value (factorial 1)) 1)
  (check-equal? (raw-value (factorial 2)) 2)
  (check-equal? (raw-value (factorial 5)) 120)
  (check-equal? (raw-value (factorial 10)) 3628800)
  )

  (test-case "fibonacci"
  (check-equal? (raw-value (fibonacci 0)) 0)
  (check-equal? (raw-value (fibonacci 1)) 1)
  (check-equal? (raw-value (fibonacci 2)) 1)
  (check-equal? (raw-value (fibonacci 5)) 5)
  (check-equal? (raw-value (fibonacci 10)) 55)
  )

  (test-case "clamp: in range returns n"
  (check-equal? (raw-value (clamp 0 10 5)) 5)
  (check-equal? (raw-value (clamp 0 10 0)) 0)
  (check-equal? (raw-value (clamp 0 10 10)) 10)
  )

  (test-case "clamp: below lo returns lo"
  (check-equal? (raw-value (clamp 0 10 -5)) 0)
  (check-equal? (raw-value (clamp 5 15 3)) 5)
  )

  (test-case "clamp: above hi returns hi"
  (check-equal? (raw-value (clamp 0 10 20)) 10)
  (check-equal? (raw-value (clamp 5 15 99)) 15)
  )

  (test-case "clamp: mixed"
  (define lo 3)
  (define hi 7)
  (check-equal? (raw-value (clamp lo hi 3)) 3)
  (check-equal? (raw-value (clamp lo hi 7)) 7)
  (check-equal? (raw-value (clamp lo hi 5)) 5)
  (check-equal? (raw-value (clamp lo hi 0)) 3)
  (check-equal? (raw-value (clamp lo hi 9)) 7)
  )

  (test-case "clamp properties"
  ; property: result is always in range
  (for ([tesl-prop-i (in-range 200)])
    (let ([lo (- (random 2000001) 1000000)] [hi (- (random 2000001) 1000000)] [n (- (random 2000001) 1000000)])
      (when (<= (raw-value lo) (raw-value hi)) (check-true (and (>= (raw-value (clamp lo hi n)) (raw-value lo)) (<= (raw-value (clamp lo hi n)) (raw-value hi))) "result is always in range"))
    ))
  ; property: idempotent: clamping twice is same as once
  (for ([tesl-prop-i (in-range 200)])
    (let ([lo (- (random 2000001) 1000000)] [hi (- (random 2000001) 1000000)] [n (- (random 2000001) 1000000)])
      (when (<= (raw-value lo) (raw-value hi)) (check-true (equal? (raw-value (clamp lo hi (clamp lo hi n))) (raw-value (clamp lo hi n))) "idempotent: clamping twice is same as once"))
    ))
  ; property: clamp lo lo n == lo for any n
  (for ([tesl-prop-i (in-range 200)])
    (let ([lo (- (random 2000001) 1000000)] [n (- (random 2000001) 1000000)])
      (check-true (equal? (raw-value (clamp lo lo n)) (raw-value lo)) "clamp lo lo n == lo for any n")
    ))
  )

  (test-case "factorial growth"
  ; property: factorial(n) > 0 for n >= 0
  (for ([tesl-prop-i (in-range 20)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (< (raw-value n) 10)) (check-true (> (raw-value (factorial n)) 0) "factorial(n) > 0 for n >= 0"))
    ))
  )

  (test-case "doctest: factorial"
  (check-equal? (raw-value (factorial 0)) 1)
  (check-equal? (raw-value (factorial 1)) 1)
  (check-equal? (raw-value (factorial 5)) 120)
  )

  (test-case "doctest: fibonacci"
  (check-equal? (raw-value (fibonacci 0)) 0)
  (check-equal? (raw-value (fibonacci 1)) 1)
  (check-equal? (raw-value (fibonacci 10)) 55)
  )

)
