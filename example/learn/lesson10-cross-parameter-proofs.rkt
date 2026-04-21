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


(provide ValidRange checkValidRange clampToRange safePair checkValidRange-signature clampToRange-signature safePair-signature)

(define ValidRange 'ValidRange)

(define-checker
  (checkValidRange [lo : Integer] [hi : Integer])
  #:returns [lo : Integer ::: (ValidRange lo hi)]
  (if (< *lo *hi) (accept (ValidRange lo hi) #:value *lo) (reject "lo must be less than hi" #:http-code 400)))

(define/pow
  (clampToRange [lo : Integer ::: (ValidRange lo hi)] [hi : Integer] [value : Integer])
  #:returns Integer
  (if (< *value *lo) *lo (if (> *value *hi) *hi *value)))

(define/pow
  (safePair [rawLo : Integer] [rawHi : Integer] [value : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (checkValidRange rawLo rawHi)]) (let ([lo tesl_checked_0]) (raw-value (clampToRange lo rawHi value)))))

(module+ test
  (require rackunit)
  (test-case "checkValidRange valid"
  (define lo1 1)
  (define hi1 10)
  (define tesl_checked_1 (checkValidRange lo1 hi1))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl_checked_1)))
  (define r1 tesl_checked_1)
  (define lo2 -5)
  (define hi2 5)
  (define tesl_checked_2 (checkValidRange lo2 hi2))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl_checked_2)))
  (define r2 tesl_checked_2)
  (define lo3 0)
  (define hi3 1)
  (define tesl_checked_3 (checkValidRange lo3 hi3))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let r3: ~a" (check-fail-message tesl_checked_3)))
  (define r3 tesl_checked_3)
  (check-equal? (raw-value r1) 1)
  (check-equal? (raw-value r2) -5)
  (check-equal? (raw-value r3) 0)
  )

  (test-case "checkValidRange rejects equal/inverted"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkValidRange 5 5))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkValidRange 5 5"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkValidRange 10 1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkValidRange 10 1"))
  )

  (test-case "safePair clamps correctly"
  (define r1 (safePair 0 10 5))
  (check-equal? (raw-value r1) 5)
  (define r2 (safePair 0 10 -3))
  (check-equal? (raw-value r2) 0)
  (define r3 (safePair 0 10 99))
  (check-equal? (raw-value r3) 10)
  (define r4 (safePair 3 7 3))
  (check-equal? (raw-value r4) 3)
  (define r5 (safePair 3 7 7))
  (check-equal? (raw-value r5) 7)
  )

)
