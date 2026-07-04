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
  (thsl-src! "example/learn/lesson00-hello-world.tesl" 26 (list (cons 'name *name)) (lambda () (format "Hello, ~a!" (tesl-display-val *name)))))

(define/pow
  (add [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson00-hello-world.tesl" 29 (list (cons 'x *x) (cons 'y *y)) (lambda () (+ *x *y))))

(module+ test
  (require rackunit)
  (test-case "greet"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 32 (list) (lambda () (greet "World")))) "Hello, World!")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 33 (list) (lambda () (greet "Tesl")))) "Hello, Tesl!")
    ))
  )

  (test-case "add"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 37 (list) (lambda () (add 1 2)))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 38 (list) (lambda () (add 0 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson00-hello-world.tesl" 39 (list) (lambda () (add 10 -3)))) 7)
    ))
  )

)
