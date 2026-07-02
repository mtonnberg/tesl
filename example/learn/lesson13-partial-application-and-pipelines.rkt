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


(provide add double triple increment decrement pipeline add-signature double-signature triple-signature increment-signature decrement-signature pipeline-signature)

(define/pow
  (add [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 30 (list (cons 'x *x) (cons 'y *y)) (lambda () (+ *x *y))))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 33 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (triple [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 36 (list (cons 'n *n)) (lambda () (* *n 3))))

(define/pow
  (increment [n : Integer])
  #:returns Integer
  (let ([addOne (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 41 (list (cons 'n *n)) (lambda () (lambda (tesl-p-0-0) (add 1 tesl-p-0-0))))]) (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 42 (list (cons 'addOne *addOne) (cons 'n *n)) (lambda () (raw-value (addOne n))))))

(define/pow
  (decrement [n : Integer])
  #:returns Integer
  (let ([subOne (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 45 (list (cons 'n *n)) (lambda () (lambda (tesl-p-1-0) (add -1 tesl-p-1-0))))]) (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 46 (list (cons 'subOne *subOne) (cons 'n *n)) (lambda () (raw-value (subOne n))))))

(define/pow
  (pipeline [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 51 (list (cons 'n *n)) (lambda () (raw-value (double (double n))))))

(define/pow
  (pipeline2 [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 57 (list (cons 'n *n)) (lambda () (raw-value (triple (double n))))))

(module+ test
  (require rackunit)
  (test-case "add"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 114 (list) (lambda () (add 3 7)))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 115 (list) (lambda () (add 0 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 116 (list) (lambda () (add -5 5)))) 0)
  )

  (test-case "double and triple"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 120 (list) (lambda () (double 5)))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 121 (list) (lambda () (double 0)))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 122 (list) (lambda () (triple 3)))) 9)
  )

  (test-case "increment and decrement"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 126 (list) (lambda () (increment 4)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 127 (list) (lambda () (increment 0)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 128 (list) (lambda () (decrement 5)))) 4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 129 (list) (lambda () (decrement 0)))) -1)
  )

  (test-case "pipeline"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 133 (list) (lambda () (pipeline 3)))) 12)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 134 (list) (lambda () (pipeline 1)))) 4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 135 (list) (lambda () (pipeline 0)))) 0)
  )

  (test-case "pipeline2"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 139 (list) (lambda () (pipeline2 2)))) 12)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson13-partial-application-and-pipelines.tesl" 140 (list) (lambda () (pipeline2 1)))) 6)
  )

  (test-case "partial application"
  ; property: increment n == n + 1
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (check-true (equal? (raw-value (increment n)) (+ (raw-value n) 1)) "increment n == n + 1")
    ))
  ; property: decrement n == n - 1
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (check-true (equal? (raw-value (decrement n)) (- (raw-value n) 1)) "decrement n == n - 1")
    ))
  )

)
