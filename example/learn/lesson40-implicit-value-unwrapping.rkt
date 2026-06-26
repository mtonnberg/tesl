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
  (only-in tesl/tesl/prelude Int Bool String)
)


(provide double isAdult greet absVal classify double-signature isAdult-signature greet-signature absVal-signature classify-signature)

(define/pow
  (double [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 25 (list (cons 'n *n)) (lambda () (+ *n *n))))

(define/pow
  (add [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 28 (list (cons 'x *x) (cons 'y *y)) (lambda () (+ *x *y))))

(define/pow
  (multiply [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 31 (list (cons 'x *x) (cons 'y *y)) (lambda () (* *x *y))))

(define/pow
  (isAdult [age : Integer])
  #:returns Boolean
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 34 (list (cons 'age *age)) (lambda () (>= *age 18))))

(define/pow
  (isEqual [x : Integer] [y : Integer])
  #:returns Boolean
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 37 (list (cons 'x *x) (cons 'y *y)) (lambda () (equal? *x *y))))

(define/pow
  (greet [name : String])
  #:returns String
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 40 (list (cons 'name *name)) (lambda () (format "Hello, ~a!" (tesl-display-val *name)))))

(define/pow
  (describe [x : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 43 (list (cons 'x *x)) (lambda () (format "The value is ~a" (tesl-display-val *x)))))

(define/pow
  (absVal [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 46 (list (cons 'n *n)) (lambda () (if (>= *n 0) *n (raw-value (- *n))))))

(define/pow
  (negate [b : Boolean])
  #:returns Boolean
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 52 (list (cons 'b *b)) (lambda () (raw-value (not b)))))

(define/pow
  (classify [flag : Boolean] [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 55 (list (cons 'flag *flag) (cons 'a *a) (cons 'b *b)) (lambda () (if *flag *a *b))))

(module+ test
  (require rackunit)
  (test-case "double uses implicit unwrapping"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 61 (list) (lambda () (double 5)))) 10)
  )

  (test-case "add uses implicit unwrapping"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 65 (list) (lambda () (add 3 4)))) 7)
  )

  (test-case "multiply uses implicit unwrapping"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 69 (list) (lambda () (multiply 6 7)))) 42)
  )

  (test-case "isAdult comparison"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 73 (list) (lambda () (isAdult 18)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 74 (list) (lambda () (isAdult 17)))) #f)
  )

  (test-case "isEqual comparison"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 78 (list) (lambda () (isEqual 3 3)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 79 (list) (lambda () (isEqual 3 4)))) #f)
  )

  (test-case "greet string interpolation"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 83 (list) (lambda () (greet "Alice")))) "Hello, Alice!")
  )

  (test-case "describe string interpolation"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 87 (list) (lambda () (describe 42)))) "The value is 42")
  )

  (test-case "absVal unary negation"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 91 (list) (lambda () (absVal 5)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 92 (list) (lambda () (absVal -3)))) 3)
  )

  (test-case "negate bool"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 96 (list) (lambda () (negate #f)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 97 (list) (lambda () (negate #t)))) #f)
  )

  (test-case "classify if-condition"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 101 (list) (lambda () (classify #t 10 20)))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson40-implicit-value-unwrapping.tesl" 102 (list) (lambda () (classify #f 10 20)))) 20)
  )

)
