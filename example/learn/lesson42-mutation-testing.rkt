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


(provide ValidAge checkAge ValidScore checkScore ValidDiscount checkDiscount checkAge-signature checkScore-signature checkDiscount-signature)

(define ValidAge 'ValidAge)
(define ValidDiscount 'ValidDiscount)
(define ValidScore 'ValidScore)

(define-checker
  (checkAge [n : Integer])
  #:returns [n : Integer ::: (ValidAge n)]
  (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 52 (list (cons 'n *n)) (lambda () (if (and (>= *n 18) (<= *n 120)) (accept (ValidAge n) #:value *n) (reject "age must be between 18 and 120" #:http-code 422)))))

(define-checker
  (checkScore [n : Integer])
  #:returns [n : Integer ::: (ValidScore n)]
  (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 111 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 100)) (accept (ValidScore n) #:value *n) (reject "score must be between 0 and 100" #:http-code 422)))))

(define-checker
  (checkDiscount [code : Integer])
  #:returns [code : Integer ::: (ValidDiscount code)]
  (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 135 (list (cons 'code *code)) (lambda () (if (tesl-equal? *code 42) (accept (ValidDiscount code) #:value *code) (reject "invalid discount code" #:http-code 422)))))

(module+ test
  (require rackunit)
  (test-case "checkAge: boundary values kill all mutants"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 97 (list) (lambda () (raw-value (checkAge 18))))) 18)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 98 (list) (lambda () (raw-value (checkAge 65))))) 65)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 99 (list) (lambda () (raw-value (checkAge 120))))) 120)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 100 (list) (lambda ()
                          (checkAge 17))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAge 17"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 101 (list) (lambda ()
                          (checkAge 121))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAge 121"))
  )

  (test-case "checkScore: boundary values kill all mutants"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 117 (list) (lambda () (raw-value (checkScore 0))))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 118 (list) (lambda () (raw-value (checkScore 50))))) 50)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 119 (list) (lambda () (raw-value (checkScore 100))))) 100)
  (define scoreNeg1 (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 120 (list) (lambda () -1)))
  (define score101 (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 121 (list (cons 'scoreNeg1 scoreNeg1)) (lambda () 101)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 122 (list (cons 'score101 score101) (cons 'scoreNeg1 scoreNeg1)) (lambda ()
                          (checkScore scoreNeg1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore scoreNeg1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 123 (list (cons 'score101 score101) (cons 'scoreNeg1 scoreNeg1)) (lambda ()
                          (checkScore score101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore score101"))
  )

  (test-case "checkDiscount: equality check \226\128\148 kills == \226\134\146 != mutant"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 149 (list) (lambda () (raw-value (checkDiscount 42))))) 42)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 150 (list) (lambda ()
                          (checkDiscount 7))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkDiscount 7"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson42-mutation-testing.tesl" 151 (list) (lambda ()
                          (checkDiscount 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkDiscount 0"))
  )

)
