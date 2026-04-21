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
  (only-in tesl/tesl/prelude Int String)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide InBounds checkInBounds Sanitized sanitize checkInBounds-signature sanitize-signature)

(define InBounds 'InBounds)
(define Sanitized 'Sanitized)

(define-checker
  (checkInBounds [n : Integer])
  #:returns [n : Integer ::: (InBounds n)]
  (if (and (>= *n 0) (<= *n 1000)) (accept (InBounds n) #:value *n) (reject "out of bounds" #:http-code 400)))

(define-checker
  (sanitize [s : String])
  #:returns [s : String ::: (Sanitized s)]
  (if (<= (raw-value (tesl_import_String_length *s)) 256) (accept (Sanitized s) #:value *s) (reject "string too long" #:http-code 400)))

(module+ test
  (require rackunit)
  (test-case "checkInBounds valid"
  (define n1 0)
  (define tesl_checked_0 (checkInBounds n1))
  (when (check-fail? tesl_checked_0)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl_checked_0)))
  (define r1 tesl_checked_0)
  (define n2 500)
  (define tesl_checked_1 (checkInBounds n2))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl_checked_1)))
  (define r2 tesl_checked_1)
  (define n3 1000)
  (define tesl_checked_2 (checkInBounds n3))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let r3: ~a" (check-fail-message tesl_checked_2)))
  (define r3 tesl_checked_2)
  (check-equal? 1 1)
  )

  (test-case "checkInBounds rejects out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkInBounds -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkInBounds 1001))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds 1001"))
  )

  (test-case "sanitize valid"
  (define s1 "")
  (define tesl_checked_3 (sanitize s1))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl_checked_3)))
  (define r1 tesl_checked_3)
  (define s2 "hello")
  (define tesl_checked_4 (sanitize s2))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl_checked_4)))
  (define r2 tesl_checked_4)
  (check-equal? 1 1)
  )

  (test-case "sanitize rejects too-long"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (sanitize "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check sanitize \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""))
  )

)
