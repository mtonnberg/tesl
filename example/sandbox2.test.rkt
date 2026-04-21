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
  (only-in tesl/tesl/prelude Int Fact String)
  (only-in tesl/example/sandbox IsPositive)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith])
)


(provide )

(define IsLargerThan 'IsLargerThan)

(define/pow
  (double [n : Integer])
  #:returns Integer
  (+ *n *n))

(define/pow
  (add [x : Integer] [y : Integer])
  #:returns Integer
  (+ *x *y))

(define-checker
  (isLargerThan [x : Integer] [y : Integer])
  #:returns [x : Integer ::: (IsLargerThan x y)]
  (if (> *x *y) (accept (IsLargerThan x y) #:value *x) (reject "x must be larger than y" #:http-code 400)))

(define-record AnIntRecord
  [someProp : Integer]
)

(define-record AnIntRecordWithProof
  [someProp : Integer ::: (IsPositive someProp)]
  [someProp2 : Integer ::: (IsPositive someProp2)]
)

(define-record AnIntRecordWithCombinedProof
  [some2Prop : Integer ::: (IsPositive some2Prop)]
  [some2Prop2 : Integer ::: (IsPositive some2Prop2)]
)

(define/pow
  (genSmallPositive [seed : Integer])
  #:returns Integer
  (+ 1 (remainder *seed 100)))

(module+ test
  (require rackunit)
  (test-case "double basics"
  (check-equal? (raw-value (double 0)) 0)
  (check-equal? (raw-value (double 5)) 10)
  (check-equal? (raw-value (double -3)) -6)
  (check-not-equal? (double 1) 0)
  )

  (test-case "add basics"
  (check-equal? (raw-value (add 3 7)) 10)
  (check-equal? (raw-value (add 0 0)) 0)
  (check-equal? (raw-value (add -1 1)) 0)
  )

  (test-case "String.length"
  (check-equal? (raw-value (tesl_import_String_length "hello")) 5)
  (check-equal? (raw-value (tesl_import_String_length "")) 0)
  (check-equal? (raw-value (tesl_import_String_length "a")) 1)
  )

  (test-case "String.startsWith"
  (check-true (raw-value (tesl_import_String_startsWith "hello" "hel")))
  (check-true (raw-value (tesl_import_String_startsWith "hello" "")))
  )

  (test-case "comparisons"
  (check-true (> 5 3))
  (check-true (< 3 5))
  (check-true (>= 5 5))
  (check-true (<= 5 5))
  (check-not-equal? 5 3)
  )

  (test-case "property: double is 2*n"
  ; property: double n == n * 2
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (check-true (equal? (raw-value (double n)) (* (raw-value n) 2)) "double n == n * 2")
    ))
  )

  (test-case "property: add is commutative"
  ; property: add x y == add y x
  (for ([tesl-prop-i (in-range 50)])
    (let ([x (- (random 2000001) 1000000)] [y (- (random 2000001) 1000000)])
      (check-true (equal? (raw-value (add x y)) (raw-value (add y x))) "add x y == add y x")
    ))
  )

  (test-case "property: string length is non-negative"
  ; property: length >= 0
  (for ([tesl-prop-i (in-range 30)])
    (let ([s (format "s~a" (random 1000000))])
      (check-true (>= (raw-value (tesl_import_String_length (raw-value s))) 0) "length >= 0")
    ))
  )

  (test-case "property: with where clause"
  ; property: positive n always > 0
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) 0) (< (raw-value n) 10000)) (check-true (> (raw-value n) 0) "positive n always > 0"))
    ))
  )

  (test-case "property: record.  add is commutative"
  ; property:  add is commutative
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (AnIntRecord #:someProp (- (random 2000001) 1000000))] [m (AnIntRecord #:someProp (- (random 2000001) 1000000))])
      (check-true (equal? (raw-value (add (raw-value (tesl-dot/runtime n 'someProp)) (raw-value (tesl-dot/runtime m 'someProp)))) (raw-value (add (raw-value (tesl-dot/runtime m 'someProp)) (raw-value (tesl-dot/runtime n 'someProp))))) " add is commutative")
    ))
  )

  (test-case "property: record.  where statements"
  ; property:  add is commutative
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (AnIntRecord #:someProp (- (random 2000001) 1000000))])
      (when (and (> (raw-value (tesl-dot/runtime n 'someProp)) 0) (< (raw-value (tesl-dot/runtime n 'someProp)) 10000)) (check-true (> (raw-value (tesl-dot/runtime n 'someProp)) 0) " add is commutative"))
    ))
  )

  (test-case "property: record with proofs.  add is commutative"
  ; property:  add is commutative
  (for ([tesl-prop-i (in-range 100)])
    (let tesl-retry ([tesl-attempts 0])
      (if (> tesl-attempts 100)
        (void) ; skip this iteration after too many retries
        (with-handlers ([exn:fail? (lambda (e) (tesl-retry (+ tesl-attempts 1)))])
          (let ([n (let ([tesl_gen_someProp (+ 1 (random 1000000))] [tesl_gen_someProp2 (+ 1 (random 1000000))]) (AnIntRecordWithProof #:someProp (tesl-test-proof-field 'someProp tesl_gen_someProp (list 'IsPositive 'someProp)) #:someProp2 (tesl-test-proof-field 'someProp2 tesl_gen_someProp2 (list 'IsPositive 'someProp2))))] [m (let ([tesl_gen_someProp (+ 1 (random 1000000))] [tesl_gen_someProp2 (+ 1 (random 1000000))]) (AnIntRecordWithProof #:someProp (tesl-test-proof-field 'someProp tesl_gen_someProp (list 'IsPositive 'someProp)) #:someProp2 (tesl-test-proof-field 'someProp2 tesl_gen_someProp2 (list 'IsPositive 'someProp2))))])
            (check-true (equal? (raw-value (add (raw-value (tesl-dot/runtime n 'someProp)) (raw-value (tesl-dot/runtime m 'someProp)))) (raw-value (add (raw-value (tesl-dot/runtime m 'someProp)) (raw-value (tesl-dot/runtime n 'someProp))))) " add is commutative")
          )))))
  )

  (test-case "property: record with proofs.  where statements"
  ; property:  add is commutative
  (for ([tesl-prop-i (in-range 100)])
    (let tesl-retry ([tesl-attempts 0])
      (if (> tesl-attempts 100)
        (void) ; skip this iteration after too many retries
        (with-handlers ([exn:fail? (lambda (e) (tesl-retry (+ tesl-attempts 1)))])
          (let ([n (let ([tesl_gen_someProp (+ 1 (random 1000000))] [tesl_gen_someProp2 (+ 1 (random 1000000))]) (AnIntRecordWithProof #:someProp (tesl-test-proof-field 'someProp tesl_gen_someProp (list 'IsPositive 'someProp)) #:someProp2 (tesl-test-proof-field 'someProp2 tesl_gen_someProp2 (list 'IsPositive 'someProp2))))])
            (when (< (raw-value (tesl-dot/runtime n 'someProp)) 10000) (check-true (> (raw-value (tesl-dot/runtime n 'someProp)) 0) " add is commutative"))
          )))))
  )

  (test-case "property: record with combined proofs"
  ; property:  x should be larger than y
  (for ([tesl-prop-i (in-range 100)])
    (let tesl-retry ([tesl-attempts 0])
      (if (> tesl-attempts 100)
        (void) ; skip this iteration after too many retries
        (with-handlers ([exn:fail? (lambda (e) (tesl-retry (+ tesl-attempts 1)))])
          (let ([n (let ([tesl_gen_some2Prop (+ 1 (random 1000000))] [tesl_gen_some2Prop2 (+ 1 (random 1000000))]) (AnIntRecordWithCombinedProof #:some2Prop (tesl-test-proof-field 'some2Prop tesl_gen_some2Prop (list 'IsPositive 'some2Prop)) #:some2Prop2 (tesl-test-proof-field 'some2Prop2 tesl_gen_some2Prop2 (list 'IsPositive 'some2Prop2))))])
            (check-true (> (raw-value (tesl-dot/runtime n 'some2Prop)) (raw-value (tesl-dot/runtime n 'some2Prop2))) " x should be larger than y")
          )))))
  )

  (test-case "property: via custom generator"
  ; property: custom gen
  (for ([tesl-prop-i (in-range 20)])
    (let ([n (genSmallPositive tesl-prop-i)])
      (check-true (and (> (raw-value n) 0) (<= (raw-value n) 100)) "custom gen")
    ))
  )

  (test-case "doctest: double"
  (check-equal? (raw-value (double 5)) 10)
  (check-equal? (raw-value (double 0)) 0)
  (check-equal? (raw-value (double -3)) -6)
  )

  (test-case "doctest: add"
  (check-equal? (raw-value (add 3 7)) 10)
  (check-equal? (raw-value (add 0 0)) 0)
  )

)
