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


(provide ValidAge checkAge ValidScore checkScore ValidDiscount checkDiscount checkAge-signature checkScore-signature checkDiscount-signature)

(define ValidAge 'ValidAge)
(define ValidDiscount 'ValidDiscount)
(define ValidScore 'ValidScore)

(define-checker
  (checkAge [n : Integer])
  #:returns [n : Integer ::: (ValidAge n)]
  (if (and (>= *n 18) (<= *n 120)) (accept (ValidAge n) #:value *n) (reject "age must be between 18 and 120" #:http-code 422)))

(define-checker
  (checkScore [n : Integer])
  #:returns [n : Integer ::: (ValidScore n)]
  (if (and (>= *n 0) (<= *n 100)) (accept (ValidScore n) #:value *n) (reject "score must be between 0 and 100" #:http-code 422)))

(define-checker
  (checkDiscount [code : Integer])
  #:returns [code : Integer ::: (ValidDiscount code)]
  (if (equal? *code 42) (accept (ValidDiscount code) #:value *code) (reject "invalid discount code" #:http-code 422)))

(module+ test
  (require rackunit)
  (test-case "checkAge: boundary values kill all mutants"
  (check-equal? (raw-value (raw-value (checkAge 18))) 18)
  (check-equal? (raw-value (raw-value (checkAge 65))) 65)
  (check-equal? (raw-value (raw-value (checkAge 120))) 120)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkAge 17))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAge 17"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkAge 121))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAge 121"))
  )

  (test-case "checkScore: boundary values kill all mutants"
  (check-equal? (raw-value (raw-value (checkScore 0))) 0)
  (check-equal? (raw-value (raw-value (checkScore 50))) 50)
  (check-equal? (raw-value (raw-value (checkScore 100))) 100)
  (define scoreNeg1 -1)
  (define score101 101)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkScore scoreNeg1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore scoreNeg1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkScore score101))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore score101"))
  )

  (test-case "checkDiscount: equality check \226\128\148 kills == \226\134\146 != mutant"
  (check-equal? (raw-value (raw-value (checkDiscount 42))) 42)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkDiscount 7))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkDiscount 7"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkDiscount 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkDiscount 0"))
  )

)
