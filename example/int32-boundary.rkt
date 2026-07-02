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
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/int32 Int32 [Int32.fromInt tesl_import_Int32_fromInt] [Int32.toInt tesl_import_Int32_toInt])
)


(provide narrowSafe widen roundTrip narrowSafe-signature widen-signature roundTrip-signature)

(define/pow
  (narrowSafe [n : Integer])
  #:returns (Maybe Int32)
  (thsl-src! "example/int32-boundary.tesl" 20 (list (cons 'n *n)) (lambda () (raw-value (tesl_import_Int32_fromInt *n)))))

(define/pow
  (widen [x : Int32])
  #:returns Integer
  (thsl-src! "example/int32-boundary.tesl" 24 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Int32_toInt *x)))))

(define/pow
  (roundTrip [n : Integer] [fallback : Integer])
  #:returns Integer
  (thsl-src-control! "example/int32-boundary.tesl" 29 (list (cons 'n *n) (cons 'fallback *fallback)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Int32_fromInt *n))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([x (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/int32-boundary.tesl" 30 (list (cons 'x x)) (lambda () (raw-value (raw-value (tesl_import_Int32_toInt *x))))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/int32-boundary.tesl" 31 (list) (lambda () *fallback))])))))

(module+ test
  (require rackunit)
  (test-case "in-range value round-trips unchanged"
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 34 (list) (lambda () (roundTrip 1000 (- 0 1))))) 1000)
  )

  (test-case "the int32 max boundary is in range"
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 38 (list) (lambda () (roundTrip 2147483647 (- 0 1))))) 2147483647)
  )

  (test-case "a value above the int32 max is out of range"
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 42 (list) (lambda () (roundTrip 2147483648 (- 0 1))))) (- 0 1))
  )

  (test-case "a large Int (> 2^53) is out of int32 range"
  (check-equal? (raw-value (thsl-src! "example/int32-boundary.tesl" 46 (list) (lambda () (roundTrip 9007199254740993 (- 0 1))))) (- 0 1))
  )

)
