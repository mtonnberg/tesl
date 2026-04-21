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
  (only-in tesl/tesl/prelude Int forgetFact Fact String)
)


(provide ValidAge checkAge birthday showAge checkAge-signature birthday-signature showAge-signature)

(define ValidAge 'ValidAge)

(define-checker
  (checkAge [n : Integer])
  #:returns [n : Integer ::: (ValidAge n)]
  (if (and (>= *n 0) (<= *n 150)) (accept (ValidAge n) #:value *n) (reject "invalid age" #:http-code 400)))

(define/pow
  (birthday [age : Integer ::: (ValidAge age)])
  #:returns Integer
  (let ([withoutProof (forget-proof age)]) (+ (raw-value withoutProof) 1)))

(define/pow
  (showAge [age : Integer ::: (ValidAge age)])
  #:returns String
  (let ([tesl_proof_binding_0 age]) (let ([rawAge (forget-proof tesl_proof_binding_0)] [ageProof (detach-all-proof tesl_proof_binding_0)]) (format "age is ~a" (tesl-display-val *rawAge)))))

(module+ test
  (require rackunit)
  (test-case "checkAge valid"
  (define n1 0)
  (define tesl_checked_1 (checkAge n1))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl_checked_1)))
  (define r1 tesl_checked_1)
  (define n2 25)
  (define tesl_checked_2 (checkAge n2))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl_checked_2)))
  (define r2 tesl_checked_2)
  (define n3 150)
  (define tesl_checked_3 (checkAge n3))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let r3: ~a" (check-fail-message tesl_checked_3)))
  (define r3 tesl_checked_3)
  (check-equal? 1 1)
  )

  (test-case "checkAge rejects"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkAge -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAge -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkAge 151))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAge 151"))
  )

  (test-case "birthday increments"
  (define n 30)
  (define tesl_checked_4 (checkAge n))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let age: ~a" (check-fail-message tesl_checked_4)))
  (define age tesl_checked_4)
  (check-equal? (raw-value (birthday age)) 31)
  )

  (test-case "showAge produces string"
  (define n 25)
  (define tesl_checked_5 (checkAge n))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let age: ~a" (check-fail-message tesl_checked_5)))
  (define age tesl_checked_5)
  (check-equal? (raw-value (showAge age)) "age is 25")
  )

)
