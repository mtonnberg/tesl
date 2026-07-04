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
  (only-in tesl/tesl/list [List.isEmpty tesl_import_List_isEmpty])
)


(provide double negate isEmpty greetAge clamp double-signature negate-signature isEmpty-signature clamp-signature greetAge-signature)

(define/pow
  (double [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 36 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (negate [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 43 (list (cons 'n *n)) (lambda () (- 0 *n))))

(define/pow
  (isEmpty [xs : (List a)])
  #:returns Boolean
  (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 46 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_isEmpty *xs)))))

(define/pow
  (clamp [lo : Integer] [hi : Integer] [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 56 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (< *n *lo) *lo (if (> *n *hi) *hi *n)))))

(define/pow
  (greetAge [name : String] [age : Integer])
  #:returns String
  (let ([greeting (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 65 (list (cons 'name *name) (cons 'age *age)) (lambda () (format "Hello, ~a!" (tesl-display-val *name))))]) (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 66 (list (cons 'greeting *greeting) (cons 'name *name) (cons 'age *age)) (lambda () (if (>= *age 18) (raw-value (format "~a You are an adult." (tesl-display-val *greeting))) (raw-value (format "~a You are a minor." (tesl-display-val *greeting))))))))

(module+ test
  (require rackunit)
  (test-case "double"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 72 (list) (lambda () (double 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 73 (list) (lambda () (double 5)))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 74 (list) (lambda () (double -2)))) -4)
    ))
  )

  (test-case "negate"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 78 (list) (lambda () (negate 5)))) -5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 79 (list) (lambda () (negate 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 80 (list) (lambda () (negate -3)))) 3)
    ))
  )

  (test-case "clamp"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 84 (list) (lambda () (clamp 0 10 5)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 85 (list) (lambda () (clamp 0 10 -3)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 86 (list) (lambda () (clamp 0 10 99)))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 87 (list) (lambda () (clamp 0 10 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 88 (list) (lambda () (clamp 0 10 10)))) 10)
    ))
  )

  (test-case "greetAge"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 92 (list) (lambda () (greetAge "Alice" 20)))) "Hello, Alice! You are an adult.")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 93 (list) (lambda () (greetAge "Bob" 17)))) "Hello, Bob! You are a minor.")
    ))
  )

  (test-case "clamp is bounded"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: result is always in range
  (for ([tesl-prop-i (in-range 200)])
    (let ([lo (- (random 2000001) 1000000)] [hi (- (random 2000001) 1000000)] [n (- (random 2000001) 1000000)])
      (when (<= (raw-value lo) (raw-value hi)) (check-true (and (>= (raw-value (clamp lo hi n)) (raw-value lo)) (<= (raw-value (clamp lo hi n)) (raw-value hi))) "result is always in range"))
    ))
    ))
  )

  (test-case "doctest: double"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 1 (list) (lambda () (double 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 1 (list) (lambda () (double 5)))) 10)
    ))
  )

  (test-case "doctest: negate"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 1 (list) (lambda () (negate 3)))) -3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 1 (list) (lambda () (negate 0)))) 0)
    ))
  )

  (test-case "doctest: clamp"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 1 (list) (lambda () (clamp 0 10 5)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 1 (list) (lambda () (clamp 0 10 -3)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson01-basic-types-and-functions.tesl" 1 (list) (lambda () (clamp 0 10 99)))) 10)
    ))
  )

)
