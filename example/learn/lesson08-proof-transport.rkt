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
  (only-in tesl/tesl/prelude Int forgetFact Fact String)
)


(provide ValidAge checkAge birthday showAge checkAge-signature birthday-signature showAge-signature)

(define ValidAge 'ValidAge)

(define-checker
  (checkAge [n : Integer])
  #:returns [n : Integer ::: (ValidAge n)]
  (thsl-src! "example/learn/lesson08-proof-transport.tesl" 28 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 150)) (accept (ValidAge n) #:value *n) (reject "invalid age" #:http-code 400)))))

(define/pow
  (birthday [age : Integer ::: (ValidAge age)])
  #:returns Integer
  (let ([withoutProof (thsl-src! "example/learn/lesson08-proof-transport.tesl" 39 (list (cons 'age *age)) (lambda () (forget-proof age)))]) (thsl-src! "example/learn/lesson08-proof-transport.tesl" 40 (list (cons 'withoutProof *withoutProof) (cons 'age *age)) (lambda () (+ (raw-value withoutProof) 1)))))

(define/pow
  (showAge [age : Integer ::: (ValidAge age)])
  #:returns String
  (thsl-src! "example/learn/lesson08-proof-transport.tesl" 49 (list (cons 'age *age)) (lambda () (let ([tesl-proof-binding-0 age]) (let ([rawAge (forget-proof tesl-proof-binding-0)] [ageProof (detach-all-proof tesl-proof-binding-0)]) (format "age is ~a" (tesl-display-val *rawAge)))))))

(module+ test
  (require rackunit)
  (test-case "checkAge valid"
    (call-with-fresh-memory-db '() (lambda ()
  (define n1 (thsl-src! "example/learn/lesson08-proof-transport.tesl" 162 (list) (lambda () 0)))
  (define tesl-checked-1 (checkAge n1))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl-checked-1)))
  (define r1 tesl-checked-1)
  (define n2 (thsl-src! "example/learn/lesson08-proof-transport.tesl" 164 (list (cons 'r1 r1) (cons 'n1 n1)) (lambda () 25)))
  (define tesl-checked-2 (checkAge n2))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl-checked-2)))
  (define r2 tesl-checked-2)
  (define n3 (thsl-src! "example/learn/lesson08-proof-transport.tesl" 166 (list (cons 'r2 r2) (cons 'n2 n2) (cons 'r1 r1) (cons 'n1 n1)) (lambda () 150)))
  (define tesl-checked-3 (checkAge n3))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let r3: ~a" (check-fail-message tesl-checked-3)))
  (define r3 tesl-checked-3)
  (check-equal? (thsl-src! "example/learn/lesson08-proof-transport.tesl" 168 (list (cons 'r3 r3) (cons 'n3 n3) (cons 'r2 r2) (cons 'n2 n2) (cons 'r1 r1) (cons 'n1 n1)) (lambda () 1)) 1)
    ))
  )

  (test-case "checkAge rejects"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson08-proof-transport.tesl" 172 (list) (lambda ()
                          (checkAge -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAge -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson08-proof-transport.tesl" 173 (list) (lambda ()
                          (checkAge 151))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAge 151"))
    ))
  )

  (test-case "birthday increments"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "example/learn/lesson08-proof-transport.tesl" 177 (list) (lambda () 30)))
  (define tesl-checked-4 (checkAge n))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let age: ~a" (check-fail-message tesl-checked-4)))
  (define age tesl-checked-4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson08-proof-transport.tesl" 179 (list (cons 'age age) (cons 'n n)) (lambda () (birthday age)))) 31)
    ))
  )

  (test-case "showAge produces string"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "example/learn/lesson08-proof-transport.tesl" 183 (list) (lambda () 25)))
  (define tesl-checked-5 (checkAge n))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let age: ~a" (check-fail-message tesl-checked-5)))
  (define age tesl-checked-5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson08-proof-transport.tesl" 185 (list (cons 'age age) (cons 'n n)) (lambda () (showAge age)))) "age is 25")
    ))
  )

)
