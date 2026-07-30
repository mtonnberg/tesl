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
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/int32 Int32 IsNonZero [Int32.fromInt tesl_import_Int32_fromInt] [Int32.toInt tesl_import_Int32_toInt] [Int32.fromIntClamped tesl_import_Int32_fromIntClamped] [Int32.toString tesl_import_Int32_toString] [Int32.add tesl_import_Int32_add] [Int32.subtract tesl_import_Int32_subtract] [Int32.divide tesl_import_Int32_divide] [Int32.clamp tesl_import_Int32_clamp] [Int32.isNegative tesl_import_Int32_isNegative] [Int32.minValue tesl_import_Int32_minValue] [Int32.maxValue tesl_import_Int32_maxValue] [Int32.nonZero tesl_import_Int32_nonZero])
)


(provide narrowSafe widen roundTrip saturate budgetLeft describe halve narrowSafe-signature widen-signature roundTrip-signature saturate-signature budgetLeft-signature describe-signature halve-signature)

(define/pow
  (narrowSafe [n : Integer])
  #:returns (Maybe Int32)
  (thsl-src! "example/int32-boundary.tesl" 48 (list (cons 'n *n)) (lambda () (raw-value (tesl_import_Int32_fromInt *n)))))

(define/pow
  (widen [x : Int32])
  #:returns Integer
  (thsl-src! "example/int32-boundary.tesl" 52 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Int32_toInt *x)))))

(define/pow
  (roundTrip [n : Integer] [fallback : Integer])
  #:returns Integer
  (thsl-src-control! "example/int32-boundary.tesl" 57 (list (cons 'n *n) (cons 'fallback *fallback)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Int32_fromInt *n))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([x (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/int32-boundary.tesl" 58 (list (cons 'x x)) (lambda () (raw-value (raw-value (tesl_import_Int32_toInt *x))))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/int32-boundary.tesl" 59 (list) (lambda () *fallback))])))))

(define/pow
  (saturate [n : Integer])
  #:returns Int32
  (thsl-src! "example/int32-boundary.tesl" 63 (list (cons 'n *n)) (lambda () (raw-value (tesl_import_Int32_fromIntClamped *n)))))

(define/pow
  (budgetLeft [budget : Int32] [spent : Int32])
  #:returns (Maybe Int32)
  (thsl-src! "example/int32-boundary.tesl" 68 (list (cons 'budget *budget) (cons 'spent *spent)) (lambda () (raw-value (tesl_import_Int32_subtract *budget *spent)))))

(define/pow
  (describe [x : Int32])
  #:returns String
  (thsl-src! "example/int32-boundary.tesl" 72 (list (cons 'x *x)) (lambda () (if (raw-value (tesl_import_Int32_isNegative *x)) (raw-value (string-append "-" (raw-value (tesl_import_Int32_toString *x)))) (raw-value (raw-value (tesl_import_Int32_toString *x)))))))

(define/pow
  (halve [n : Int32] [d : Int32 ::: (IsNonZero d)])
  #:returns (Maybe Int32)
  (thsl-src! "example/int32-boundary.tesl" 80 (list (cons 'n *n) (cons 'd *d)) (lambda () (raw-value (tesl_import_Int32_divide *n d)))))

(module+ test
  (require rackunit)
  (test-case "in-range value round-trips unchanged"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 83 (list) (lambda () (roundTrip 1000 (- 0 1))))) 1000)
    ))
  )

  (test-case "the int32 max boundary is in range"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 87 (list) (lambda () (roundTrip 2147483647 (- 0 1))))) 2147483647)
    ))
  )

  (test-case "a value above the int32 max is out of range"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 91 (list) (lambda () (roundTrip 2147483648 (- 0 1))))) (- 0 1))
    ))
  )

  (test-case "a large Int (> 2^53) is out of int32 range"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 95 (list) (lambda () (roundTrip 9007199254740993 (- 0 1))))) (- 0 1))
    ))
  )

  (test-case "saturating narrowing clamps to the bounds"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 99 (list) (lambda () (raw-value (tesl_import_Int32_toInt (raw-value (saturate 9007199254740993))))))) 2147483647)
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 100 (list) (lambda () (raw-value (tesl_import_Int32_toInt (raw-value (saturate (- 0 9007199254740993)))))))) (- 0 2147483648))
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 101 (list) (lambda () (raw-value (tesl_import_Int32_toInt (raw-value (saturate 7))))))) 7)
    ))
  )

  (test-case "minValue and maxValue are the range bounds"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 105 (list) (lambda () (raw-value (tesl_import_Int32_toInt tesl_import_Int32_minValue))))) (- 0 2147483648))
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 106 (list) (lambda () (raw-value (tesl_import_Int32_toInt tesl_import_Int32_maxValue))))) 2147483647)
    ))
  )

  (test-case "checked subtraction reports overflow as Nothing"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 110 (list) (lambda () (budgetLeft (saturate 10) (saturate 4))))) (raw-value (Something (saturate 6))))
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 111 (list) (lambda () (budgetLeft tesl_import_Int32_minValue (saturate 1))))) Nothing)
    ))
  )

  (test-case "checked addition reports overflow as Nothing"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 115 (list) (lambda () (raw-value (tesl_import_Int32_add tesl_import_Int32_maxValue (raw-value (saturate 1))))))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 116 (list) (lambda () (raw-value (tesl_import_Int32_add (raw-value (saturate 2)) (raw-value (saturate 3))))))) (raw-value (Something (saturate 5))))
    ))
  )

  (test-case "clamp stays inside the boundary type"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 120 (list) (lambda () (raw-value (tesl_import_Int32_toInt (raw-value (tesl_import_Int32_clamp (raw-value (saturate 99)) (raw-value (saturate 0)) (raw-value (saturate 10))))))))) 10)
    ))
  )

  (test-case "predicates and toString read the Int32 directly"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 124 (list) (lambda () (describe (saturate 42))))) "42")
  (check-true (raw-value (thsl-src! "example/int32-boundary.tesl" 125 (list) (lambda () (raw-value (tesl_import_Int32_isNegative (raw-value (saturate (- 0 1)))))))))
    ))
  )

  (test-case "division needs a proven non-zero divisor"
    (call-with-fresh-memory-db '() (lambda ()
  (define two (thsl-src! "example/int32-boundary.tesl" 129 (list) (lambda () (saturate 2))))
  (define tesl-checked-1 (tesl_import_Int32_nonZero two))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let d: ~a" (check-fail-message tesl-checked-1)))
  (define d tesl-checked-1)
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 131 (list (cons 'd d) (cons 'two two)) (lambda () (halve (saturate 9) d)))) (raw-value (Something (saturate 4))))
    ))
  )

  (test-case "the single out-of-range quotient is Nothing"
    (call-with-fresh-memory-db '() (lambda ()
  (define negOne (thsl-src! "example/int32-boundary.tesl" 137 (list) (lambda () (saturate (- 0 1)))))
  (define tesl-checked-2 (tesl_import_Int32_nonZero negOne))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let d: ~a" (check-fail-message tesl-checked-2)))
  (define d tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 139 (list (cons 'd d) (cons 'negOne negOne)) (lambda () (halve tesl_import_Int32_minValue d)))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 140 (list (cons 'd d) (cons 'negOne negOne)) (lambda () (halve (saturate 8) d)))) (raw-value (Something (saturate (- 0 8)))))
    ))
  )

)
