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
  (only-in tesl/tesl/prelude Int)
)


(provide factorial fibonacci clamp factorial-signature fibonacci-signature clamp-signature)

(define/pow
  (factorial [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson14-test-blocks.tesl" 42 (list (cons 'n *n)) (lambda () (if (<= *n 0) (raw-value 1) (raw-value (* *n (raw-value (factorial (- *n 1)))))))))

(define/pow
  (fibonacci [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson14-test-blocks.tesl" 54 (list (cons 'n *n)) (lambda () (if (<= *n 1) *n (raw-value (+ (raw-value (fibonacci (- *n 1))) (raw-value (fibonacci (- *n 2)))))))))

(define/pow
  (clamp [lo : Integer] [hi : Integer] [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson14-test-blocks.tesl" 60 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (< *n *lo) *lo (if (> *n *hi) *hi *n)))))

(module+ test
  (require rackunit)
  (test-case "factorial"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 75 (list) (lambda () (factorial 0)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 76 (list) (lambda () (factorial 1)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 77 (list) (lambda () (factorial 2)))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 78 (list) (lambda () (factorial 5)))) 120)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 79 (list) (lambda () (factorial 10)))) 3628800)
    ))
  )

  (test-case "fibonacci"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 83 (list) (lambda () (fibonacci 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 84 (list) (lambda () (fibonacci 1)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 85 (list) (lambda () (fibonacci 2)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 86 (list) (lambda () (fibonacci 5)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 87 (list) (lambda () (fibonacci 10)))) 55)
    ))
  )

  (test-case "clamp: in range returns n"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 91 (list) (lambda () (clamp 0 10 5)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 92 (list) (lambda () (clamp 0 10 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 93 (list) (lambda () (clamp 0 10 10)))) 10)
    ))
  )

  (test-case "clamp: below lo returns lo"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 97 (list) (lambda () (clamp 0 10 -5)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 98 (list) (lambda () (clamp 5 15 3)))) 5)
    ))
  )

  (test-case "clamp: above hi returns hi"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 102 (list) (lambda () (clamp 0 10 20)))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 103 (list) (lambda () (clamp 5 15 99)))) 15)
    ))
  )

  (test-case "clamp: mixed"
    (call-with-fresh-memory-db '() (lambda ()
  (define lo (thsl-src! "example/learn/lesson14-test-blocks.tesl" 107 (list) (lambda () 3)))
  (define hi (thsl-src! "example/learn/lesson14-test-blocks.tesl" 108 (list (cons 'lo lo)) (lambda () 7)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 109 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (clamp lo hi 3)))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 110 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (clamp lo hi 7)))) 7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 111 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (clamp lo hi 5)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 112 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (clamp lo hi 0)))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 113 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (clamp lo hi 9)))) 7)
    ))
  )

  (test-case "clamp properties"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: result is always in range
  (for ([tesl-prop-i (in-range 200)])
    (let ([lo (- (random 2000001) 1000000)] [hi (- (random 2000001) 1000000)] [n (- (random 2000001) 1000000)])
      (when (<= (raw-value lo) (raw-value hi)) (check-true (and (>= (raw-value (clamp lo hi n)) (raw-value lo)) (<= (raw-value (clamp lo hi n)) (raw-value hi))) "result is always in range"))
    ))
  ; property: idempotent: clamping twice is same as once
  (for ([tesl-prop-i (in-range 200)])
    (let ([lo (- (random 2000001) 1000000)] [hi (- (random 2000001) 1000000)] [n (- (random 2000001) 1000000)])
      (when (<= (raw-value lo) (raw-value hi)) (check-true (tesl-equal? (raw-value (clamp lo hi (clamp lo hi n))) (raw-value (clamp lo hi n))) "idempotent: clamping twice is same as once"))
    ))
  ; property: clamp lo lo n == lo for any n
  (for ([tesl-prop-i (in-range 200)])
    (let ([lo (- (random 2000001) 1000000)] [n (- (random 2000001) 1000000)])
      (check-true (tesl-equal? (raw-value (clamp lo lo n)) (raw-value lo)) "clamp lo lo n == lo for any n")
    ))
    ))
  )

  (test-case "factorial growth"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: factorial(n) > 0 for n >= 0
  (for ([tesl-prop-i (in-range 20)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (< (raw-value n) 10)) (check-true (> (raw-value (factorial n)) 0) "factorial(n) > 0 for n >= 0"))
    ))
    ))
  )

  (test-case "doctest: factorial"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 1 (list) (lambda () (factorial 0)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 1 (list) (lambda () (factorial 1)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 1 (list) (lambda () (factorial 5)))) 120)
    ))
  )

  (test-case "doctest: fibonacci"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 1 (list) (lambda () (fibonacci 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 1 (list) (lambda () (fibonacci 1)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson14-test-blocks.tesl" 1 (list) (lambda () (fibonacci 10)))) 55)
    ))
  )

)
