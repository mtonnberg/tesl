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
)


(provide ValidRange checkValidRange clampToRange safePair checkValidRange-signature clampToRange-signature safePair-signature)

(define ValidRange 'ValidRange)

(define-checker
  (checkValidRange [lo : Integer] [hi : Integer])
  #:returns [lo : Integer ::: (ValidRange lo hi)]
  (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 32 (list (cons 'lo *lo) (cons 'hi *hi)) (lambda () (if (< *lo *hi) (accept (ValidRange lo hi) #:value *lo) (reject "lo must be less than hi" #:http-code 400)))))

(define/pow
  (clampToRange [lo : Integer ::: (ValidRange lo hi)] [hi : Integer] [value : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 42 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'value *value)) (lambda () (if (< *value *lo) *lo (if (> *value *hi) *hi *value)))))

(define/pow
  (safePair [rawLo : Integer] [rawHi : Integer] [value : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 52 (list (cons 'rawLo *rawLo) (cons 'rawHi *rawHi) (cons 'value *value)) (lambda () (let/check ([tesl-checked-0 (checkValidRange rawLo rawHi)]) (let ([lo tesl-checked-0]) (raw-value (clampToRange lo rawHi value)))))))

(module+ test
  (require rackunit)
  (test-case "checkValidRange valid"
  (define lo1 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 105 (list) (lambda () 1)))
  (define hi1 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 106 (list (cons 'lo1 lo1)) (lambda () 10)))
  (define tesl-checked-1 (checkValidRange lo1 hi1))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let r1: ~a" (check-fail-message tesl-checked-1)))
  (define r1 tesl-checked-1)
  (define lo2 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 108 (list (cons 'r1 r1) (cons 'hi1 hi1) (cons 'lo1 lo1)) (lambda () -5)))
  (define hi2 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 109 (list (cons 'lo2 lo2) (cons 'r1 r1) (cons 'hi1 hi1) (cons 'lo1 lo1)) (lambda () 5)))
  (define tesl-checked-2 (checkValidRange lo2 hi2))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let r2: ~a" (check-fail-message tesl-checked-2)))
  (define r2 tesl-checked-2)
  (define lo3 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 111 (list (cons 'r2 r2) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'r1 r1) (cons 'hi1 hi1) (cons 'lo1 lo1)) (lambda () 0)))
  (define hi3 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 112 (list (cons 'lo3 lo3) (cons 'r2 r2) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'r1 r1) (cons 'hi1 hi1) (cons 'lo1 lo1)) (lambda () 1)))
  (define tesl-checked-3 (checkValidRange lo3 hi3))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let r3: ~a" (check-fail-message tesl-checked-3)))
  (define r3 tesl-checked-3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 114 (list (cons 'r3 r3) (cons 'hi3 hi3) (cons 'lo3 lo3) (cons 'r2 r2) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'r1 r1) (cons 'hi1 hi1) (cons 'lo1 lo1)) (lambda () r1))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 115 (list (cons 'r3 r3) (cons 'hi3 hi3) (cons 'lo3 lo3) (cons 'r2 r2) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'r1 r1) (cons 'hi1 hi1) (cons 'lo1 lo1)) (lambda () r2))) -5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 116 (list (cons 'r3 r3) (cons 'hi3 hi3) (cons 'lo3 lo3) (cons 'r2 r2) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'r1 r1) (cons 'hi1 hi1) (cons 'lo1 lo1)) (lambda () r3))) 0)
  )

  (test-case "checkValidRange rejects equal/inverted"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 120 (list) (lambda ()
                          (checkValidRange 5 5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkValidRange 5 5"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 121 (list) (lambda ()
                          (checkValidRange 10 1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkValidRange 10 1"))
  )

  (test-case "safePair clamps correctly"
  (define r1 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 125 (list) (lambda () (safePair 0 10 5))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 126 (list (cons 'r1 r1)) (lambda () r1))) 5)
  (define r2 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 127 (list (cons 'r1 r1)) (lambda () (safePair 0 10 -3))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 128 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r2))) 0)
  (define r3 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 129 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () (safePair 0 10 99))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 130 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () r3))) 10)
  (define r4 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 131 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (safePair 3 7 3))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 132 (list (cons 'r4 r4) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () r4))) 3)
  (define r5 (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 133 (list (cons 'r4 r4) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () (safePair 3 7 7))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson10-cross-parameter-proofs.tesl" 134 (list (cons 'r5 r5) (cons 'r4 r4) (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () r5))) 7)
  )

)
