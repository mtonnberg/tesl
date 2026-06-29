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
  (only-in tesl/tesl/prelude Bool Int Fact forgetFact detachFact introAnd andLeft andRight)
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
  (thsl-src! "tests/critical-review59-tests.tesl" 47 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "fail A" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: (B n)]
  (thsl-src! "tests/critical-review59-tests.tesl" 53 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (B n) #:value *n) (reject "fail B" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: (C n)]
  (thsl-src! "tests/critical-review59-tests.tesl" 59 (list (cons 'n *n)) (lambda () (if (not (equal? *n 42)) (accept (C n) #:value *n) (reject "fail C" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: (D n)]
  (thsl-src! "tests/critical-review59-tests.tesl" 65 (list (cons 'n *n)) (lambda () (if (not (equal? *n 99)) (accept (D n) #:value *n) (reject "fail D" #:http-code 400)))))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: (E n)]
  (thsl-src! "tests/critical-review59-tests.tesl" 71 (list (cons 'n *n)) (lambda () (if (not (equal? *n 500)) (accept (E n) #:value *n) (reject "fail E" #:http-code 400)))))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review59-tests.tesl" 77 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review59-tests.tesl" 83 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too large" #:http-code 400)))))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review59-tests.tesl" 89 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review59-tests.tesl" 92 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 96 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 97 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 98 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAll [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 99 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 100 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (doChain5 [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 105 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_0 (checkA raw)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkB a)]) (let ([b tesl_checked_1]) (let/check ([tesl_checked_2 (checkC b)]) (let ([c tesl_checked_2]) (let/check ([tesl_checked_3 (checkD c)]) (let ([d tesl_checked_3]) (let/check ([tesl_checked_4 (checkE d)]) (let ([e tesl_checked_4]) (raw-value (needsAll e)))))))))))))))

(define/pow
  (introAndLeft [raw : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review59-tests.tesl" 131 (list (cons 'raw *raw)) (lambda () (proveA raw)))]) (let ([pb (thsl-src! "tests/critical-review59-tests.tesl" 132 (list (cons 'pa *pa) (cons 'raw *raw)) (lambda () (proveB raw)))]) (let ([combined (thsl-src! "tests/critical-review59-tests.tesl" 133 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (intro-and pa pb)))]) (let ([left (thsl-src! "tests/critical-review59-tests.tesl" 134 (list (cons 'combined *combined) (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (and-left combined)))]) (let ([base (thsl-src! "tests/critical-review59-tests.tesl" 135 (list (cons 'left *left) (cons 'combined *combined) (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (forget-proof raw)))]) (let ([withA (thsl-src! "tests/critical-review59-tests.tesl" 136 (list (cons 'base *base) (cons 'left *left) (cons 'combined *combined) (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (attach-proof base left)))]) (thsl-src! "tests/critical-review59-tests.tesl" 137 (list (cons 'withA *withA) (cons 'base *base) (cons 'left *left) (cons 'combined *combined) (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (raw-value (needsA withA)))))))))))

(define/pow
  (introAndRight [raw : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review59-tests.tesl" 146 (list (cons 'raw *raw)) (lambda () (proveA raw)))]) (let ([pb (thsl-src! "tests/critical-review59-tests.tesl" 147 (list (cons 'pa *pa) (cons 'raw *raw)) (lambda () (proveB raw)))]) (let ([combined (thsl-src! "tests/critical-review59-tests.tesl" 148 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (intro-and pa pb)))]) (let ([right (thsl-src! "tests/critical-review59-tests.tesl" 149 (list (cons 'combined *combined) (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (and-right combined)))]) (let ([base (thsl-src! "tests/critical-review59-tests.tesl" 150 (list (cons 'right *right) (cons 'combined *combined) (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (forget-proof raw)))]) (let ([withB (thsl-src! "tests/critical-review59-tests.tesl" 151 (list (cons 'base *base) (cons 'right *right) (cons 'combined *combined) (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (attach-proof base right)))]) (thsl-src! "tests/critical-review59-tests.tesl" 152 (list (cons 'withB *withB) (cons 'base *base) (cons 'right *right) (cons 'combined *combined) (cons 'pb *pb) (cons 'pa *pa) (cons 'raw *raw)) (lambda () (raw-value (needsB withB)))))))))))

(define/pow
  (singleDetach [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 163 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_5 (checkA raw)]) (let ([a tesl_checked_5]) (let ([pa (detach-all-proof a)]) (let ([v (forget-proof a)]) (let ([withA (attach-proof v pa)]) (raw-value (needsA withA))))))))))

(define/pow
  (multiProofDetach [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 178 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_6 (checkA raw)]) (let ([a tesl_checked_6]) (let/check ([tesl_checked_7 (checkB a)]) (let ([b tesl_checked_7]) (let ([_p (detach-all-proof b)]) 0))))))))

(define/pow
  (isEven [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review59-tests.tesl" 191 (list (cons 'n *n)) (lambda () (if (equal? *n 0) (raw-value #t) (raw-value (isOdd (- *n 1)))))))

(define/pow
  (isOdd [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review59-tests.tesl" 197 (list (cons 'n *n)) (lambda () (if (equal? *n 0) (raw-value #f) (raw-value (isEven (- *n 1)))))))

(define/pow
  (proofDecompChain [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review59-tests.tesl" 223 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_8 (checkA raw)]) (let ([a tesl_checked_8]) (let/check ([tesl_checked_9 (checkB a)]) (let ([b tesl_checked_9]) (let ([tesl_proof_binding_10 b]) (let ([v (forget-proof tesl_proof_binding_10)] [p (detach-all-proof tesl_proof_binding_10)]) (let ([pA (and-left p)]) (let ([withA (attach-proof v pA)]) (raw-value (needsA withA)))))))))))))

(module+ test
  (require rackunit)
  (test-case "R59_DC01 five-check deep chain works with valid input"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 113 (list) (lambda () 5)))
  (define result (thsl-src! "tests/critical-review59-tests.tesl" 114 (list (cons 'r1 r1)) (lambda () (doChain5 r1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 115 (list (cons 'result result) (cons 'r1 r1)) (lambda () result))) 5)
  )

  (test-case "R59_DC02 five-check deep chain rejects first check failure"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 119 (list) (lambda () 0)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review59-tests.tesl" 120 (list (cons 'r1 r1)) (lambda ()
                          ((let () (define/pow (tesl-lambda-11) #:returns Integer (doChain5 r1)) tesl-lambda-11) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-12) #:returns Integer (doChain5 r1)) tesl-lambda-12) (list)"))
  )

  (test-case "R59_DC03 five-check deep chain rejects mid-chain failure"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 124 (list) (lambda () 42)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review59-tests.tesl" 125 (list (cons 'r1 r1)) (lambda ()
                          ((let () (define/pow (tesl-lambda-12) #:returns Integer (doChain5 r1)) tesl-lambda-12) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-13) #:returns Integer (doChain5 r1)) tesl-lambda-13) (list)"))
  )

  (test-case "R59_IA01 introAnd andLeft with establish proofs works"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 140 (list) (lambda () 5)))
  (define result (thsl-src! "tests/critical-review59-tests.tesl" 141 (list (cons 'r1 r1)) (lambda () (introAndLeft r1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 142 (list (cons 'result result) (cons 'r1 r1)) (lambda () result))) 5)
  )

  (test-case "R59_IA02 introAnd andRight with establish proofs works"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 155 (list) (lambda () 5)))
  (define result (thsl-src! "tests/critical-review59-tests.tesl" 156 (list (cons 'r1 r1)) (lambda () (introAndRight r1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 157 (list (cons 'result result) (cons 'r1 r1)) (lambda () result))) 5)
  )

  (test-case "R59_DT01 detachFact with single proof and reattach"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 170 (list) (lambda () 5)))
  (define result (thsl-src! "tests/critical-review59-tests.tesl" 171 (list (cons 'r1 r1)) (lambda () (singleDetach r1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 172 (list (cons 'result result) (cons 'r1 r1)) (lambda () result))) 5)
  )

  (test-case "R59_MP01 detachFact fails at runtime with multiple proofs"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 184 (list) (lambda () 5)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review59-tests.tesl" 185 (list (cons 'r1 r1)) (lambda ()
                          ((let () (define/pow (tesl-lambda-13) #:returns Integer (multiProofDetach r1)) tesl-lambda-13) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-14) #:returns Integer (multiProofDetach r1)) tesl-lambda-14) (list)"))
  )

  (test-case "R59_MR01 mutual recursion isEven/isOdd"
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 203 (list) (lambda () (isEven 4)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 204 (list) (lambda () (isEven 3)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 205 (list) (lambda () (isOdd 3)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 206 (list) (lambda () (isOdd 4)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 207 (list) (lambda () (isEven 0)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 208 (list) (lambda () (isOdd 0)))) #f)
  )

  (test-case "R59_PD01 proof decomp with andLeft now works correctly (fix 1.1)"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 231 (list) (lambda () 5)))
  (define result (thsl-src! "tests/critical-review59-tests.tesl" 232 (list (cons 'r1 r1)) (lambda () (proofDecompChain r1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 233 (list (cons 'result result) (cons 'r1 r1)) (lambda () result))) 5)
  )

  (test-case "R59_PD02 andRight also works on accumulated proofs"
  (define r1 (thsl-src! "tests/critical-review59-tests.tesl" 237 (list) (lambda () 5)))
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
  (define pB (thsl-src! "tests/critical-review59-tests.tesl" 241 (list (cons 'v v) (cons 'b b) (cons 'a a) (cons 'r1 r1)) (lambda () (and-right p))))
  (define withB (thsl-src! "tests/critical-review59-tests.tesl" 242 (list (cons 'pB pB) (cons 'v v) (cons 'b b) (cons 'a a) (cons 'r1 r1)) (lambda () (attach-proof v pB))))
  (define result (thsl-src! "tests/critical-review59-tests.tesl" 243 (list (cons 'withB withB) (cons 'pB pB) (cons 'v v) (cons 'b b) (cons 'a a) (cons 'r1 r1)) (lambda () (needsB withB))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review59-tests.tesl" 244 (list (cons 'result result) (cons 'withB withB) (cons 'pB pB) (cons 'v v) (cons 'b b) (cons 'a a) (cons 'r1 r1)) (lambda () result))) 5)
  )

)
