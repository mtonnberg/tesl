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
  (only-in tesl/tesl/prelude Int String)
)


(provide greet add greet-signature add-signature)

(define/pow
  (greet [name : String])
  #:returns String
  (thsl-src! "example/learn/lesson00-hello-world.tesl" 24 (list (cons 'name *name)) (lambda () (format "Hello, ~a!" (tesl-display-val *name)))))

(define/pow
  (add [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson00-hello-world.tesl" 27 (list (cons 'x *x) (cons 'y *y)) (lambda () (+ *x *y))))

(module+ test
  (require rackunit)
  (test-case "greet"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 30 (list) (lambda () (greet "World")))) "Hello, World!")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 31 (list) (lambda () (greet "Tesl")))) "Hello, Tesl!")
  )

  (test-case "add"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 35 (list) (lambda () (add 1 2)))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 36 (list) (lambda () (add 0 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 37 (list) (lambda () (add 10 -3)))) 7)
  )

)
