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
  racket/runtime-path
  (only-in tesl/tesl/prelude forgetFact attachFact detachFact Int Fact)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide shouldWork dummy_add ValidPort IsPositive doSomething doSomething2 ARecord ARecord2 FiveCases CaseOne CaseTwo CaseThree CaseFour CaseFive doSomething3 shouldWork-signature dummy_add-signature)

(define IsPositive 'IsPositive)
(define ValidPort 'ValidPort)

(define/pow
  (shouldWork [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src-control! "example/sandbox.tesl" 10 (list (cons 'x *x) (cons 'y *y)) (lambda () (let ([tesl-case-0 (raw-value (validPort y))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([proof (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/sandbox.tesl" 11 (list (cons 'proof proof)) (lambda () (raw-value (doSomething (attach-proof y proof))))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/sandbox.tesl" 12 (list) (lambda () *x))])))))

(define/pow
  (shouldWork2 [x : Integer] [y : Integer ::: (ValidPort x)])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 15 (list (cons 'x *x) (cons 'y *y)) (lambda () (let ([tesl-proof-binding-1 y]) (let ([y_withoutProof (forget-proof tesl-proof-binding-1)] [xProof (detach-all-proof tesl-proof-binding-1)]) (raw-value (doSomething (attach-proof x xProof))))))))

(define/pow
  (shouldWork3 [x : Integer ::: (ValidPort y)] [y : Integer ::: (ValidPort x)])
  #:returns Integer
  (let ([xProof (thsl-src! "example/sandbox.tesl" 20 (list (cons 'x *x) (cons 'y *y)) (lambda () (detach-all-proof y)))]) (thsl-src! "example/sandbox.tesl" 21 (list (cons 'xProof *xProof) (cons 'x *x) (cons 'y *y)) (lambda () (raw-value (doSomething (attach-proof (forget-proof x) xProof)))))))

(define/pow
  (shouldWork4 [x : Integer ::: (ValidPort x)] [y : Integer ::: (IsPositive x)])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 24 (list (cons 'x *x) (cons 'y *y)) (lambda () (let ([xProof1 (detach-all-proof x)]) (let ([tesl-proof-binding-2 y]) (let ([_ (forget-proof tesl-proof-binding-2)] [xProof2 (detach-all-proof tesl-proof-binding-2)]) (raw-value (doSomething2 (attach-proof (forget-proof x) (and (raw-value xProof1) (raw-value xProof2)))))))))))

(define/pow
  (shouldWork41 [x : Integer ::: ((ValidPort x) && (IsPositive y))] [y : Integer ::: (IsPositive x)])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 29 (list (cons 'x *x) (cons 'y *y)) (lambda () (let ([tesl-proof-binding-3 x]) (let ([x_withoutProof (forget-proof tesl-proof-binding-3)] [xProof1 (detach-all-proof tesl-proof-binding-3)]) (let ([tesl-proof-binding-4 y]) (let ([_ (forget-proof tesl-proof-binding-4)] [xProof2 (detach-all-proof tesl-proof-binding-4)]) (raw-value (doSomething2 (attach-proof x_withoutProof (list xProof1 xProof2)))))))))))

(define/pow
  (shouldWork5 [x : ARecord])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 35 (list (cons 'x *x)) (lambda () 2)))

(define/pow
  (shouldWork7 [x : Sandbox3.ARecord2])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 37 (list (cons 'x *x)) (lambda () (tesl-dot/runtime x 'foo3))))

(define/pow
  (shouldWork8 [x : Sandbox2.ARecord2])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 39 (list (cons 'x *x)) (lambda () (tesl-dot/runtime x 'foo2))))

(define/pow
  (shouldWork9 [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 42 (list (cons 'x *x) (cons 'y *y)) (lambda () *x)))

(define/pow
  (shouldWork91 [x : Integer])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 45 (list (cons 'x *x)) (lambda () (raw-value (shouldWork9 2 x)))))

(define-trusted
  (validPort [port : Integer])
  #:returns (Maybe (Fact (ValidPort port)))
  (thsl-src! "example/sandbox.tesl" 50 (list (cons 'port *port)) (lambda () (if (and (<= 1 *port) (<= *port 65535)) (Something (trusted-proof (ValidPort port))) Nothing))))

(define-checker
  (checkPositive [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "example/sandbox.tesl" 58 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "Value must be over 0" #:http-code 400)))))

(define/pow
  (dummy_add [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "example/sandbox.tesl" 64 (list (cons 'x *x) (cons 'y *y)) (lambda () (+ *x *y))))


; ── Inlined from cyclic module Sandbox2 ──────────────────
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
  (thsl-src! "example/sandbox2.tesl" 29 (list (cons 'x *x)) (lambda () (raw-value (dummy_add (forget-proof x) (forget-proof x))))))

(define/pow
  (doSomething2 [x : Integer ::: ((ValidPort x) && (IsPositive x))])
  #:returns Integer
  (thsl-src! "example/sandbox2.tesl" 32 (list (cons 'x *x)) (lambda () *x)))

(define/pow
  (mutualRecursion1 [x : Integer])
  #:returns Integer
  (thsl-src! "example/sandbox2.tesl" 35 (list (cons 'x *x)) (lambda () (if (tesl-equal? *x 0) (raw-value 1) (raw-value (mutualRecursion2 (- *x 1)))))))

(define/pow
  (mutualRecursion2 [x : Integer])
  #:returns Integer
  (thsl-src! "example/sandbox2.tesl" 41 (list (cons 'x *x)) (lambda () (if (tesl-equal? *x 0) (raw-value 1) (raw-value (mutualRecursion1 (- *x 1)))))))


; ── Inlined from cyclic module Sandbox3 ──────────────────
(define/pow
  (doSomething3 [x : Integer ::: (ValidPort x)])
  #:returns Integer
  (thsl-src! "example/sandbox3.tesl" 16 (list (cons 'x *x)) (lambda () (raw-value (dummy_add x x)))))
