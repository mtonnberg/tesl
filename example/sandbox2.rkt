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
  racket/runtime-path
  (only-in tesl/tesl/prelude forgetFact Int Fact String)
)


(provide doSomething doSomething2 ARecord ARecord2 FiveCases CaseOne CaseTwo CaseThree CaseFour CaseFive shouldWork dummy_add ValidPort IsPositive doSomething-signature doSomething2-signature)

(define-record ARecord
  [title : String]
)

(define-record ARecord2
  [title : String]
  [foo2 : Integer]
)

(define-adt FiveCases
  [CaseOne]
  [CaseTwo]
  [CaseThree]
  [CaseFour]
  [CaseFive]
)

(define/pow
  (doSomething [x : Integer ::: (ValidPort x)])
  #:returns Integer
  (raw-value (dummy_add (forget-proof x) (forget-proof x))))

(define/pow
  (doSomething2 [x : Integer ::: ((ValidPort x) && (IsPositive x))])
  #:returns Integer
  *x)

(define/pow
  (mutualRecursion1 [x : Integer])
  #:returns Integer
  (if (equal? *x 0) (raw-value 1) (raw-value (mutualRecursion2 (- *x 1)))))

(define/pow
  (mutualRecursion2 [x : Integer])
  #:returns Integer
  (if (equal? *x 0) (raw-value 1) (raw-value (mutualRecursion1 (- *x 1)))))


; ── Inlined from cyclic module Sandbox ──────────────────
(define IsPositive 'IsPositive)
(define ValidPort 'ValidPort)
(define/pow
  (shouldWork [x : Integer] [y : Integer])
  #:returns Integer
  (let ([tesl_case_0 (raw-value (validPort y))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([proof (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (raw-value (doSomething (attach-proof y proof))))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) *x])))

(define/pow
  (shouldWork2 [x : Integer] [y : Integer ::: (ValidPort x)])
  #:returns Integer
  (let ([tesl_proof_binding_1 y]) (let ([y_withoutProof (forget-proof tesl_proof_binding_1)] [xProof (detach-all-proof tesl_proof_binding_1)]) (raw-value (doSomething (attach-proof x xProof))))))

(define/pow
  (shouldWork3 [x : Integer ::: (ValidPort y)] [y : Integer ::: (ValidPort x)])
  #:returns Integer
  (let ([xProof (detach-all-proof y)]) (raw-value (doSomething (attach-proof (forget-proof x) xProof)))))

(define/pow
  (shouldWork4 [x : Integer ::: (ValidPort x)] [y : Integer ::: (IsPositive x)])
  #:returns Integer
  (let ([xProof1 (detach-all-proof x)]) (let ([tesl_proof_binding_2 y]) (let ([_ (forget-proof tesl_proof_binding_2)] [xProof2 (detach-all-proof tesl_proof_binding_2)]) (raw-value (doSomething2 (attach-proof (forget-proof x) (and (raw-value xProof1) (raw-value xProof2)))))))))

(define/pow
  (shouldWork41 [x : Integer ::: ((ValidPort x) && (IsPositive y))] [y : Integer ::: (IsPositive x)])
  #:returns Integer
  (let ([tesl_proof_binding_3 x]) (let ([x_withoutProof (forget-proof tesl_proof_binding_3)] [xProof1 (detach-all-proof tesl_proof_binding_3)]) (let ([tesl_proof_binding_4 y]) (let ([_ (forget-proof tesl_proof_binding_4)] [xProof2 (detach-all-proof tesl_proof_binding_4)]) (raw-value (doSomething2 (attach-proof x_withoutProof (list xProof1 xProof2)))))))))

(define/pow
  (shouldWork5 [x : ARecord])
  #:returns Integer
  2)

(define/pow
  (shouldWork7 [x : Sandbox3.ARecord2])
  #:returns Integer
  (tesl-dot/runtime x 'foo3))

(define/pow
  (shouldWork8 [x : Sandbox2.ARecord2])
  #:returns Integer
  (tesl-dot/runtime x 'foo2))

(define/pow
  (shouldWork9 [x : Integer] [y : Integer])
  #:returns Integer
  *x)

(define/pow
  (shouldWork91 [x : Integer])
  #:returns Integer
  (raw-value (shouldWork9 2 x)))

(define-trusted
  (validPort [port : Integer])
  #:returns (Maybe (Fact (ValidPort port)))
  (if (and (<= 1 *port) (<= *port 65535)) (Something (trusted-proof (ValidPort port))) Nothing))

(define-checker
  (checkPositive [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "Value must be over 0" #:http-code 400)))

(define/pow
  (dummy_add [x : Integer] [y : Integer])
  #:returns Integer
  (+ *x *y))


; ── Inlined from cyclic module Sandbox3 ──────────────────
(define/pow
  (doSomething3 [x : Integer ::: (ValidPort x)])
  #:returns Integer
  (raw-value (dummy_add x x)))
