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
  (only-in tesl/tesl/prelude Bool Int List String)
  (only-in tesl/tesl/list [List.isEmpty tesl_import_List_isEmpty])
)


(provide double negate isEmpty greetAge clamp double-signature negate-signature isEmpty-signature clamp-signature greetAge-signature)

(define/pow
  (double [n : Integer])
  #:returns Integer
  (* *n 2))

(define/pow
  (negate [n : Integer])
  #:returns Integer
  (- 0 *n))

(define/pow
  (isEmpty [xs : (List a)])
  #:returns Boolean
  (raw-value (tesl_import_List_isEmpty *xs)))

(define/pow
  (clamp [lo : Integer] [hi : Integer] [n : Integer])
  #:returns Integer
  (if (< *n *lo) *lo (if (> *n *hi) *hi *n)))

(define/pow
  (greetAge [name : String] [age : Integer])
  #:returns String
  (let ([greeting (format "Hello, ~a!" (tesl-display-val *name))]) (if (>= *age 18) (raw-value (format "~a You are an adult." (tesl-display-val *greeting))) (raw-value (format "~a You are a minor." (tesl-display-val *greeting))))))

(module+ test
  (require rackunit)
  (test-case "double"
  (check-equal? (raw-value (double 0)) 0)
  (check-equal? (raw-value (double 5)) 10)
  (check-equal? (raw-value (double -2)) -4)
  )

  (test-case "negate"
  (check-equal? (raw-value (negate 5)) -5)
  (check-equal? (raw-value (negate 0)) 0)
  (check-equal? (raw-value (negate -3)) 3)
  )

  (test-case "clamp"
  (check-equal? (raw-value (clamp 0 10 5)) 5)
  (check-equal? (raw-value (clamp 0 10 -3)) 0)
  (check-equal? (raw-value (clamp 0 10 99)) 10)
  (check-equal? (raw-value (clamp 0 10 0)) 0)
  (check-equal? (raw-value (clamp 0 10 10)) 10)
  )

  (test-case "greetAge"
  (check-equal? (raw-value (greetAge "Alice" 20)) "Hello, Alice! You are an adult.")
  (check-equal? (raw-value (greetAge "Bob" 17)) "Hello, Bob! You are a minor.")
  )

  (test-case "clamp is bounded"
  ; property: result is always in range
  (for ([tesl-prop-i (in-range 200)])
    (let ([lo (- (random 2000001) 1000000)] [hi (- (random 2000001) 1000000)] [n (- (random 2000001) 1000000)])
      (when (<= (raw-value lo) (raw-value hi)) (check-true (and (>= (raw-value (clamp lo hi n)) (raw-value lo)) (<= (raw-value (clamp lo hi n)) (raw-value hi))) "result is always in range"))
    ))
  )

  (test-case "doctest: double"
  (check-equal? (raw-value (double 0)) 0)
  (check-equal? (raw-value (double 5)) 10)
  )

  (test-case "doctest: negate"
  (check-equal? (raw-value (negate 3)) -3)
  (check-equal? (raw-value (negate 0)) 0)
  )

  (test-case "doctest: clamp"
  (check-equal? (raw-value (clamp 0 10 5)) 5)
  (check-equal? (raw-value (clamp 0 10 -3)) 0)
  (check-equal? (raw-value (clamp 0 10 99)) 10)
  )

)
