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
  (only-in tesl/tesl/prelude Int Bool String)
)


(provide double isAdult greet absVal classify double-signature isAdult-signature greet-signature absVal-signature classify-signature)

(define/pow
  (double [n : Integer])
  #:returns Integer
  (+ *n *n))

(define/pow
  (add [x : Integer] [y : Integer])
  #:returns Integer
  (+ *x *y))

(define/pow
  (multiply [x : Integer] [y : Integer])
  #:returns Integer
  (* *x *y))

(define/pow
  (isAdult [age : Integer])
  #:returns Boolean
  (>= *age 18))

(define/pow
  (isEqual [x : Integer] [y : Integer])
  #:returns Boolean
  (equal? *x *y))

(define/pow
  (greet [name : String])
  #:returns String
  (format "Hello, ~a!" (tesl-display-val *name)))

(define/pow
  (describe [x : Integer])
  #:returns String
  (format "The value is ~a" (tesl-display-val *x)))

(define/pow
  (absVal [n : Integer])
  #:returns Integer
  (if (>= *n 0) *n (raw-value (- *n))))

(define/pow
  (negate [b : Boolean])
  #:returns Boolean
  (raw-value (not b)))

(define/pow
  (classify [flag : Boolean] [a : Integer] [b : Integer])
  #:returns Integer
  (if *flag *a *b))

(module+ test
  (require rackunit)
  (test-case "double uses implicit unwrapping"
  (check-equal? (raw-value (double 5)) 10)
  )

  (test-case "add uses implicit unwrapping"
  (check-equal? (raw-value (add 3 4)) 7)
  )

  (test-case "multiply uses implicit unwrapping"
  (check-equal? (raw-value (multiply 6 7)) 42)
  )

  (test-case "isAdult comparison"
  (check-equal? (raw-value (isAdult 18)) #t)
  (check-equal? (raw-value (isAdult 17)) #f)
  )

  (test-case "isEqual comparison"
  (check-equal? (raw-value (isEqual 3 3)) #t)
  (check-equal? (raw-value (isEqual 3 4)) #f)
  )

  (test-case "greet string interpolation"
  (check-equal? (raw-value (greet "Alice")) "Hello, Alice!")
  )

  (test-case "describe string interpolation"
  (check-equal? (raw-value (describe 42)) "The value is 42")
  )

  (test-case "absVal unary negation"
  (check-equal? (raw-value (absVal 5)) 5)
  (check-equal? (raw-value (absVal -3)) 3)
  )

  (test-case "negate bool"
  (check-equal? (raw-value (negate #f)) #t)
  (check-equal? (raw-value (negate #t)) #f)
  )

  (test-case "classify if-condition"
  (check-equal? (raw-value (classify #t 10 20)) 10)
  (check-equal? (raw-value (classify #f 10 20)) 20)
  )

)
