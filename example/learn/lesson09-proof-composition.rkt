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
  (only-in tesl/tesl/prelude Int Fact String)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide InRange NonEmpty checkInRange checkNonEmpty processRangedNonEmpty demonstrate decomposeBoth checkInRange-signature checkNonEmpty-signature processRangedNonEmpty-signature demonstrate-signature decomposeBoth-signature)

(define InRange 'InRange)
(define NonEmpty 'NonEmpty)

(define-checker
  (checkInRange [n : Integer])
  #:returns [n : Integer ::: (InRange n)]
  (thsl-src! "example/learn/lesson09-proof-composition.tesl" 33 (list (cons 'n *n)) (lambda () (if (and (>= *n 1) (<= *n 100)) (accept (InRange n) #:value *n) (reject "out of range" #:http-code 400)))))

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (NonEmpty s)]
  (thsl-src! "example/learn/lesson09-proof-composition.tesl" 41 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (NonEmpty s) #:value *s) (reject "must not be empty" #:http-code 400)))))

(define/pow
  (processRangedNonEmpty [n : Integer ::: (InRange n)] [label : String ::: (NonEmpty label)])
  #:returns String
  (thsl-src! "example/learn/lesson09-proof-composition.tesl" 49 (list (cons 'n *n) (cons 'label *label)) (lambda () (format "~a: ~a" (tesl-display-val *n) (tesl-display-val *label)))))

(define/pow
  (demonstrate [n : Integer ::: (InRange n)])
  #:returns Integer
  (thsl-src! "example/learn/lesson09-proof-composition.tesl" 55 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (decomposeBoth [n : Integer ::: (InRange n)])
  #:returns Integer
  (thsl-src! "example/learn/lesson09-proof-composition.tesl" 62 (list (cons 'n *n)) (lambda () (let ([tesl-proof-binding-0 n]) (let ([bare (forget-proof tesl-proof-binding-0)] [rangeProof (detach-all-proof tesl-proof-binding-0)]) bare)))))

(module+ test
  (require rackunit)
  (test-case "checkInRange valid"
    (call-with-fresh-memory-db '() (lambda ()
  (define n1 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 117 (list) (lambda () 1)))
  (define tesl-checked-1 (checkInRange n1))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl-checked-1)))
  (define r1 tesl-checked-1)
  (define n2 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 119 (list (cons 'r1 r1) (cons 'n1 n1)) (lambda () 50)))
  (define tesl-checked-2 (checkInRange n2))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl-checked-2)))
  (define r2 tesl-checked-2)
  (define n3 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 121 (list (cons 'r2 r2) (cons 'n2 n2) (cons 'r1 r1) (cons 'n1 n1)) (lambda () 100)))
  (define tesl-checked-3 (checkInRange n3))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let r3: ~a" (check-fail-message tesl-checked-3)))
  (define r3 tesl-checked-3)
  (check-equal? (thsl-src! "example/learn/lesson09-proof-composition.tesl" 123 (list (cons 'r3 r3) (cons 'n3 n3) (cons 'r2 r2) (cons 'n2 n2) (cons 'r1 r1) (cons 'n1 n1)) (lambda () 1)) 1)
    ))
  )

  (test-case "checkInRange rejects"
    (call-with-fresh-memory-db '() (lambda ()
  (define zero (thsl-src! "example/learn/lesson09-proof-composition.tesl" 127 (list) (lambda () 0)))
  (define oneOhOne (thsl-src! "example/learn/lesson09-proof-composition.tesl" 128 (list (cons 'zero zero)) (lambda () 101)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson09-proof-composition.tesl" 129 (list (cons 'oneOhOne oneOhOne) (cons 'zero zero)) (lambda ()
                          (checkInRange zero))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInRange zero"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson09-proof-composition.tesl" 130 (list (cons 'oneOhOne oneOhOne) (cons 'zero zero)) (lambda ()
                          (checkInRange oneOhOne))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInRange oneOhOne"))
    ))
  )

  (test-case "checkNonEmpty valid"
    (call-with-fresh-memory-db '() (lambda ()
  (define s1 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 134 (list) (lambda () "a")))
  (define tesl-checked-4 (checkNonEmpty s1))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl-checked-4)))
  (define r1 tesl-checked-4)
  (define s2 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 136 (list (cons 'r1 r1) (cons 's1 s1)) (lambda () "hello")))
  (define tesl-checked-5 (checkNonEmpty s2))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl-checked-5)))
  (define r2 tesl-checked-5)
  (check-equal? (thsl-src! "example/learn/lesson09-proof-composition.tesl" 138 (list (cons 'r2 r2) (cons 's2 s2) (cons 'r1 r1) (cons 's1 s1)) (lambda () 1)) 1)
    ))
  )

  (test-case "checkNonEmpty rejects"
    (call-with-fresh-memory-db '() (lambda ()
  (define empty (thsl-src! "example/learn/lesson09-proof-composition.tesl" 142 (list) (lambda () "")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson09-proof-composition.tesl" 143 (list (cons 'empty empty)) (lambda ()
                          (checkNonEmpty empty))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkNonEmpty empty"))
    ))
  )

  (test-case "processRangedNonEmpty"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawN (thsl-src! "example/learn/lesson09-proof-composition.tesl" 147 (list) (lambda () 5)))
  (define tesl-checked-6 (checkInRange rawN))
  (when (check-fail? tesl-checked-6)
    (raise-user-error 'tesl-test "unexpected failure in let n: ~a" (check-fail-message tesl-checked-6)))
  (define n tesl-checked-6)
  (define rawLabel (thsl-src! "example/learn/lesson09-proof-composition.tesl" 149 (list (cons 'n n) (cons 'rawN rawN)) (lambda () "item")))
  (define tesl-checked-7 (checkNonEmpty rawLabel))
  (when (check-fail? tesl-checked-7)
    (raise-user-error 'tesl-test "unexpected failure in let label: ~a" (check-fail-message tesl-checked-7)))
  (define label tesl-checked-7)
  (define r1 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 151 (list (cons 'label label) (cons 'rawLabel rawLabel) (cons 'n n) (cons 'rawN rawN)) (lambda () (processRangedNonEmpty n label))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson09-proof-composition.tesl" 152 (list (cons 'r1 r1) (cons 'label label) (cons 'rawLabel rawLabel) (cons 'n n) (cons 'rawN rawN)) (lambda () r1))) "5: item")
    ))
  )

)
