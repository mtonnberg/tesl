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
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide InBounds checkInBounds Sanitized sanitize checkInBounds-signature sanitize-signature)

(define InBounds 'InBounds)
(define Sanitized 'Sanitized)

(define-checker
  (checkInBounds [n : Integer])
  #:returns [n : Integer ::: (InBounds n)]
  (thsl-src! "example/learn/lesson07-home.tesl" 25 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 1000)) (accept (InBounds n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define-checker
  (sanitize [s : String])
  #:returns [s : String ::: (Sanitized s)]
  (thsl-src! "example/learn/lesson07-home.tesl" 38 (list (cons 's *s)) (lambda () (if (<= (raw-value (tesl_import_String_length *s)) 256) (accept (Sanitized s) #:value *s) (reject "string too long" #:http-code 400)))))

(module+ test
  (require rackunit)
  (test-case "checkInBounds valid"
  (define n1 (thsl-src! "example/learn/lesson07-home.tesl" 85 (list) (lambda () 0)))
  (define tesl-checked-0 (checkInBounds n1))
  (when (check-fail? tesl-checked-0)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl-checked-0)))
  (define r1 tesl-checked-0)
  (define n2 (thsl-src! "example/learn/lesson07-home.tesl" 87 (list (cons 'r1 r1) (cons 'n1 n1)) (lambda () 500)))
  (define tesl-checked-1 (checkInBounds n2))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl-checked-1)))
  (define r2 tesl-checked-1)
  (define n3 (thsl-src! "example/learn/lesson07-home.tesl" 89 (list (cons 'r2 r2) (cons 'n2 n2) (cons 'r1 r1) (cons 'n1 n1)) (lambda () 1000)))
  (define tesl-checked-2 (checkInBounds n3))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let r3: ~a" (check-fail-message tesl-checked-2)))
  (define r3 tesl-checked-2)
  (check-equal? (thsl-src! "example/learn/lesson07-home.tesl" 91 (list (cons 'r3 r3) (cons 'n3 n3) (cons 'r2 r2) (cons 'n2 n2) (cons 'r1 r1) (cons 'n1 n1)) (lambda () 1)) 1)
  )

  (test-case "checkInBounds rejects out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson07-home.tesl" 95 (list) (lambda ()
                          (checkInBounds -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson07-home.tesl" 96 (list) (lambda ()
                          (checkInBounds 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds 1001"))
  )

  (test-case "sanitize valid"
  (define s1 (thsl-src! "example/learn/lesson07-home.tesl" 100 (list) (lambda () "")))
  (define tesl-checked-3 (sanitize s1))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl-checked-3)))
  (define r1 tesl-checked-3)
  (define s2 (thsl-src! "example/learn/lesson07-home.tesl" 102 (list (cons 'r1 r1) (cons 's1 s1)) (lambda () "hello")))
  (define tesl-checked-4 (sanitize s2))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl-checked-4)))
  (define r2 tesl-checked-4)
  (check-equal? (thsl-src! "example/learn/lesson07-home.tesl" 104 (list (cons 'r2 r2) (cons 's2 s2) (cons 'r1 r1) (cons 's1 s1)) (lambda () 1)) 1)
  )

  (test-case "sanitize rejects too-long"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson07-home.tesl" 108 (list) (lambda ()
                          (sanitize "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check sanitize \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""))
  )

)
