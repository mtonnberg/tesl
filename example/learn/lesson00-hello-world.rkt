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
  (only-in tesl/tesl/prelude Int String)
)


(provide greet add greet-signature add-signature)

(define/pow
  (greet [name : String])
  #:returns String
  (format "Hello, ~a!" (tesl-display-val *name)))

(define/pow
  (add [x : Integer] [y : Integer])
  #:returns Integer
  (+ *x *y))

(module+ test
  (require rackunit)
  (test-case "greet"
  (check-equal? (raw-value (greet "World")) "Hello, World!")
  (check-equal? (raw-value (greet "Tesl")) "Hello, Tesl!")
  )

  (test-case "add"
  (check-equal? (raw-value (add 1 2)) 3)
  (check-equal? (raw-value (add 0 0)) 0)
  (check-equal? (raw-value (add 10 -3)) 7)
  )

)
