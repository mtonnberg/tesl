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
  (only-in tesl/tesl/prelude Bool Int String List Fact forgetFact attachFact detachFact introAnd andLeft andRight)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (if (> *n 0) (accept (A n) #:value *n) (reject "fail A" #:http-code 400)))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: (B n)]
  (if (< *n 1000) (accept (B n) #:value *n) (reject "fail B" #:http-code 400)))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: (C n)]
  (if (not (equal? *n 42)) (accept (C n) #:value *n) (reject "fail C" #:http-code 400)))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: (D n)]
  (if (not (equal? *n 99)) (accept (D n) #:value *n) (reject "fail D" #:http-code 400)))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: (E n)]
  (if (not (equal? *n 500)) (accept (E n) #:value *n) (reject "fail E" #:http-code 400)))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too large" #:http-code 400)))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (trusted-proof (A n)))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (trusted-proof (B n)))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  *n)

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  *n)

(define/pow
  (needsAB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  *n)

(define/pow
  (needsAll [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns Integer
  *n)

(define/pow
  (needsPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  *n)

(define/pow
  (doChain5 [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (checkA raw)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkB a)]) (let ([b tesl_checked_1]) (let/check ([tesl_checked_2 (checkC b)]) (let ([c tesl_checked_2]) (let/check ([tesl_checked_3 (checkD c)]) (let ([d tesl_checked_3]) (let/check ([tesl_checked_4 (checkE d)]) (let ([e tesl_checked_4]) (raw-value (needsAll e)))))))))))))

(define/pow
  (introAndLeft [raw : Integer])
  #:returns Integer
  (let ([pa (proveA raw)]) (let ([pb (proveB raw)]) (let ([combined (intro-and pa pb)]) (let ([left (and-left combined)]) (let ([base (forget-proof raw)]) (let ([withA (attach-proof base left)]) (raw-value (needsA withA)))))))))

(define/pow
  (introAndRight [raw : Integer])
  #:returns Integer
  (let ([pa (proveA raw)]) (let ([pb (proveB raw)]) (let ([combined (intro-and pa pb)]) (let ([right (and-right combined)]) (let ([base (forget-proof raw)]) (let ([withB (attach-proof base right)]) (raw-value (needsB withB)))))))))

(define/pow
  (singleDetach [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_5 (checkA raw)]) (let ([a tesl_checked_5]) (let ([pa (detach-all-proof a)]) (let ([v (forget-proof a)]) (let ([withA (attach-proof v pa)]) (raw-value (needsA withA))))))))

(define/pow
  (multiProofDetach [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_6 (checkA raw)]) (let ([a tesl_checked_6]) (let/check ([tesl_checked_7 (checkB a)]) (let ([b tesl_checked_7]) (let ([p (detach-all-proof b)]) 0))))))

(define/pow
  (isEven [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #t) (raw-value (isOdd (- *n 1)))))

(define/pow
  (isOdd [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #f) (raw-value (isEven (- *n 1)))))

(define/pow
  (proofDecompChain [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_8 (checkA raw)]) (let ([a tesl_checked_8]) (let/check ([tesl_checked_9 (checkB a)]) (let ([b tesl_checked_9]) (let ([tesl_proof_binding_10 b]) (let ([v (forget-proof tesl_proof_binding_10)] [p (detach-all-proof tesl_proof_binding_10)]) (let ([pA (and-left p)]) (let ([withA (attach-proof v pA)]) (raw-value (needsA withA)))))))))))

(module+ test
  (require rackunit)
  (test-case "R59_DC01 five-check deep chain works with valid input"
  (define r1 5)
  (define result (doChain5 r1))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R59_DC02 five-check deep chain rejects first check failure"
  (define r1 0)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-11) #:returns Integer (doChain5 r1)) tesl-lambda-11) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-12) #:returns Integer (doChain5 r1)) tesl-lambda-12) (list)"))
  )

  (test-case "R59_DC03 five-check deep chain rejects mid-chain failure"
  (define r1 42)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-12) #:returns Integer (doChain5 r1)) tesl-lambda-12) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-13) #:returns Integer (doChain5 r1)) tesl-lambda-13) (list)"))
  )

  (test-case "R59_IA01 introAnd andLeft with establish proofs works"
  (define r1 5)
  (define result (introAndLeft r1))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R59_IA02 introAnd andRight with establish proofs works"
  (define r1 5)
  (define result (introAndRight r1))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R59_DT01 detachFact with single proof and reattach"
  (define r1 5)
  (define result (singleDetach r1))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R59_MP01 detachFact fails at runtime with multiple proofs"
  (define r1 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-13) #:returns Integer (multiProofDetach r1)) tesl-lambda-13) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-14) #:returns Integer (multiProofDetach r1)) tesl-lambda-14) (list)"))
  )

  (test-case "R59_MR01 mutual recursion isEven/isOdd"
  (check-equal? (raw-value (isEven 4)) #t)
  (check-equal? (raw-value (isEven 3)) #f)
  (check-equal? (raw-value (isOdd 3)) #t)
  (check-equal? (raw-value (isOdd 4)) #f)
  (check-equal? (raw-value (isEven 0)) #t)
  (check-equal? (raw-value (isOdd 0)) #f)
  )

  (test-case "R59_PD01 proof decomp with andLeft now works correctly (fix 1.1)"
  (define r1 5)
  (define result (proofDecompChain r1))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R59_PD02 andRight also works on accumulated proofs"
  (define r1 5)
  (define tesl_checked_14 (checkA r1))
  (when (check-fail? tesl_checked_14)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl_checked_14)))
  (define a tesl_checked_14)
  (define tesl_checked_15 (checkB a))
  (when (check-fail? tesl_checked_15)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl_checked_15)))
  (define b tesl_checked_15)
  (define tesl_proof_bind_16 b)
  (when (check-fail? tesl_proof_bind_16)
    (raise-user-error 'tesl-test "unexpected failure in let-proof: ~a" (check-fail-message tesl_proof_bind_16)))
  (define v (forget-proof tesl_proof_bind_16))
  (define p (detach-all-proof tesl_proof_bind_16))
  (define pB (and-right p))
  (define withB (attach-proof v pB))
  (define result (needsB withB))
  (check-equal? (raw-value result) 5)
  )

)
