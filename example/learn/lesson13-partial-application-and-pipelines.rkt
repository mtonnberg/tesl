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


(provide add double triple increment decrement pipeline add-signature double-signature triple-signature increment-signature decrement-signature pipeline-signature)

(define/pow
  (add [x : Integer] [y : Integer])
  #:returns Integer
  (+ *x *y))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (* *n 2))

(define/pow
  (triple [n : Integer])
  #:returns Integer
  (* *n 3))

(define/pow
  (increment [n : Integer])
  #:returns Integer
  (let ([addOne (lambda (_tesl_p0_0) (add 1 _tesl_p0_0))]) (raw-value (addOne n))))

(define/pow
  (decrement [n : Integer])
  #:returns Integer
  (let ([subOne (lambda (_tesl_p1_0) (add -1 _tesl_p1_0))]) (raw-value (subOne n))))

(define/pow
  (pipeline [n : Integer])
  #:returns Integer
  (raw-value (double (double n))))

(define/pow
  (pipeline2 [n : Integer])
  #:returns Integer
  (raw-value (triple (double n))))

(module+ test
  (require rackunit)
  (test-case "add"
  (check-equal? (raw-value (add 3 7)) 10)
  (check-equal? (raw-value (add 0 0)) 0)
  (check-equal? (raw-value (add -5 5)) 0)
  )

  (test-case "double and triple"
  (check-equal? (raw-value (double 5)) 10)
  (check-equal? (raw-value (double 0)) 0)
  (check-equal? (raw-value (triple 3)) 9)
  )

  (test-case "increment and decrement"
  (check-equal? (raw-value (increment 4)) 5)
  (check-equal? (raw-value (increment 0)) 1)
  (check-equal? (raw-value (decrement 5)) 4)
  (check-equal? (raw-value (decrement 0)) -1)
  )

  (test-case "pipeline"
  (check-equal? (raw-value (pipeline 3)) 12)
  (check-equal? (raw-value (pipeline 1)) 4)
  (check-equal? (raw-value (pipeline 0)) 0)
  )

  (test-case "pipeline2"
  (check-equal? (raw-value (pipeline2 2)) 12)
  (check-equal? (raw-value (pipeline2 1)) 6)
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
