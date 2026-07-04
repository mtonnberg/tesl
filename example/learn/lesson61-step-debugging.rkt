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
  (only-in tesl/tesl/prelude Int String Bool)
)


(provide describeScore computeGrade describeScore-signature computeGrade-signature)

(define ValidScore 'ValidScore)

(define-checker
  (checkScore [n : Integer])
  #:returns [n : Integer ::: (ValidScore n)]
  (thsl-src! "example/learn/lesson61-step-debugging.tesl" 91 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 100)) (accept (ValidScore n) #:value *n) (reject "score must be 0-100" #:http-code 400)))))

(define/pow
  (describeScore [score : Integer ::: (ValidScore score)])
  #:returns String
  (thsl-src! "example/learn/lesson61-step-debugging.tesl" 100 (list (cons 'score *score)) (lambda () (if (>= *score 90) (raw-value "A") (if (>= *score 80) (raw-value "B") (if (>= *score 70) (raw-value "C") (if (>= *score 60) (raw-value "D") (raw-value "F"))))))))

(define/pow
  (computeGrade [rawScore : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson61-step-debugging.tesl" 116 (list (cons 'rawScore *rawScore)) (lambda () (let/check ([tesl-checked-0 (checkScore rawScore)]) (let ([validated tesl-checked-0]) (raw-value (describeScore validated)))))))

(module+ test
  (require rackunit)
  (test-case "checkScore accepts valid score 0"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "example/learn/lesson61-step-debugging.tesl" 172 (list) (lambda () 0)))
  (define tesl-checked-1 (checkScore n))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl-checked-1)))
  (define result tesl-checked-1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson61-step-debugging.tesl" 174 (list (cons 'result result) (cons 'n n)) (lambda () result))) 0)
    ))
  )

  (test-case "checkScore accepts valid score 100"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "example/learn/lesson61-step-debugging.tesl" 178 (list) (lambda () 100)))
  (define tesl-checked-2 (checkScore n))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl-checked-2)))
  (define result tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson61-step-debugging.tesl" 180 (list (cons 'result result) (cons 'n n)) (lambda () result))) 100)
    ))
  )

  (test-case "checkScore accepts mid-range score"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "example/learn/lesson61-step-debugging.tesl" 184 (list) (lambda () 75)))
  (define tesl-checked-3 (checkScore n))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl-checked-3)))
  (define result tesl-checked-3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson61-step-debugging.tesl" 186 (list (cons 'result result) (cons 'n n)) (lambda () result))) 75)
    ))
  )

  (test-case "checkScore rejects negative score"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "example/learn/lesson61-step-debugging.tesl" 190 (list) (lambda () -10)))
  (define y (thsl-src! "example/learn/lesson61-step-debugging.tesl" 191 (list (cons 'n n)) (lambda () "doo")))
  (define z (thsl-src! "example/learn/lesson61-step-debugging.tesl" 192 (list (cons 'y y) (cons 'n n)) (lambda () 2.32)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson61-step-debugging.tesl" 193 (list (cons 'z z) (cons 'y y) (cons 'n n)) (lambda ()
                          ((raw-value (checkScore n)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkScore n)) (list)"))
    ))
  )

  (test-case "checkScore rejects score over 100"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "example/learn/lesson61-step-debugging.tesl" 197 (list) (lambda () 150)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson61-step-debugging.tesl" 198 (list (cons 'n n)) (lambda ()
                          ((raw-value (checkScore n)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkScore n)) (list)"))
    ))
  )

  (test-case "computeGrade returns A for 95"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson61-step-debugging.tesl" 202 (list) (lambda () (computeGrade 95)))) "A")
    ))
  )

  (test-case "computeGrade returns B for 85"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson61-step-debugging.tesl" 206 (list) (lambda () (computeGrade 85)))) "B")
    ))
  )

  (test-case "computeGrade returns C for 75"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson61-step-debugging.tesl" 210 (list) (lambda () (computeGrade 75)))) "C")
    ))
  )

  (test-case "computeGrade returns F for 55"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson61-step-debugging.tesl" 214 (list) (lambda () (computeGrade 55)))) "F")
    ))
  )

)
