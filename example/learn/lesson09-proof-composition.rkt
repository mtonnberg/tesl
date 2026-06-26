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
  (thsl-src! "example/learn/lesson09-proof-composition.tesl" 62 (list (cons 'n *n)) (lambda () (let ([tesl_proof_binding_0 n]) (let ([bare (forget-proof tesl_proof_binding_0)] [rangeProof (detach-all-proof tesl_proof_binding_0)]) bare)))))

(module+ test
  (require rackunit)
  (test-case "checkInRange valid"
  (define n1 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 117 (list) (lambda () 1)))
  (define tesl_checked_1 (checkInRange n1))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl_checked_1)))
  (define r1 tesl_checked_1)
  (define n2 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 119 (list (cons 'r1 r1) (cons 'n1 n1)) (lambda () 50)))
  (define tesl_checked_2 (checkInRange n2))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl_checked_2)))
  (define r2 tesl_checked_2)
  (define n3 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 121 (list (cons 'r2 r2) (cons 'n2 n2) (cons 'r1 r1) (cons 'n1 n1)) (lambda () 100)))
  (define tesl_checked_3 (checkInRange n3))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let r3: ~a" (check-fail-message tesl_checked_3)))
  (define r3 tesl_checked_3)
  (check-equal? (thsl-src! "example/learn/lesson09-proof-composition.tesl" 123 (list (cons 'r3 r3) (cons 'n3 n3) (cons 'r2 r2) (cons 'n2 n2) (cons 'r1 r1) (cons 'n1 n1)) (lambda () 1)) 1)
  )

  (test-case "checkInRange rejects"
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
  )

  (test-case "checkNonEmpty valid"
  (define s1 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 134 (list) (lambda () "a")))
  (define tesl_checked_4 (checkNonEmpty s1))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl_checked_4)))
  (define r1 tesl_checked_4)
  (define s2 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 136 (list (cons 'r1 r1) (cons 's1 s1)) (lambda () "hello")))
  (define tesl_checked_5 (checkNonEmpty s2))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl_checked_5)))
  (define r2 tesl_checked_5)
  (check-equal? (thsl-src! "example/learn/lesson09-proof-composition.tesl" 138 (list (cons 'r2 r2) (cons 's2 s2) (cons 'r1 r1) (cons 's1 s1)) (lambda () 1)) 1)
  )

  (test-case "checkNonEmpty rejects"
  (define empty (thsl-src! "example/learn/lesson09-proof-composition.tesl" 142 (list) (lambda () "")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson09-proof-composition.tesl" 143 (list (cons 'empty empty)) (lambda ()
                          (checkNonEmpty empty))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkNonEmpty empty"))
  )

  (test-case "processRangedNonEmpty"
  (define rawN (thsl-src! "example/learn/lesson09-proof-composition.tesl" 147 (list) (lambda () 5)))
  (define tesl_checked_6 (checkInRange rawN))
  (when (check-fail? tesl_checked_6)
    (raise-user-error 'tesl-test "unexpected failure in let n: ~a" (check-fail-message tesl_checked_6)))
  (define n tesl_checked_6)
  (define rawLabel (thsl-src! "example/learn/lesson09-proof-composition.tesl" 149 (list (cons 'n n) (cons 'rawN rawN)) (lambda () "item")))
  (define tesl_checked_7 (checkNonEmpty rawLabel))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let label: ~a" (check-fail-message tesl_checked_7)))
  (define label tesl_checked_7)
  (define r1 (thsl-src! "example/learn/lesson09-proof-composition.tesl" 151 (list (cons 'label label) (cons 'rawLabel rawLabel) (cons 'n n) (cons 'rawN rawN)) (lambda () (processRangedNonEmpty n label))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson09-proof-composition.tesl" 152 (list (cons 'r1 r1) (cons 'label label) (cons 'rawLabel rawLabel) (cons 'n n) (cons 'rawN rawN)) (lambda () r1))) "5: item")
  )

)
