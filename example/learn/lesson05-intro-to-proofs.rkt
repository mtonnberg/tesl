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
)


(provide ValidPort isValidPort Positive isPositive listenOnPort requiresPositive isValidPort-signature isPositive-signature listenOnPort-signature requiresPositive-signature)

(define Positive 'Positive)
(define ValidPort 'ValidPort)

(define-checker
  (isValidPort [port : Integer])
  #:returns [port : Integer ::: (ValidPort port)]
  (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 39 (list (cons 'port *port)) (lambda () (if (and (<= 1 *port) (<= *port 65535)) (accept (ValidPort port) #:value *port) (reject "port must be between 1 and 65535" #:http-code 400)))))

(define-checker
  (isPositive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 48 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (Positive n) #:value *n) (reject "must be positive" #:http-code 400)))))

(define/pow
  (listenOnPort [port : Integer ::: (ValidPort port)])
  #:returns String
  (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 59 (list (cons 'port *port)) (lambda () (format "listening on port ~a" (tesl-display-val *port)))))

(define/pow
  (requiresPositive [n : Integer ::: (Positive n)])
  #:returns Integer
  (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 62 (list (cons 'n *n)) (lambda () (* *n 2))))

(module+ test
  (require rackunit)
  (test-case "isValidPort accepts valid ports"
  (define port1 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 112 (list) (lambda () 1)))
  (define tesl_checked_0 (isValidPort port1))
  (when (check-fail? tesl_checked_0)
    (raise-user-error 'tesl-test "unexpected failure in let x1: ~a" (check-fail-message tesl_checked_0)))
  (define x1 tesl_checked_0)
  (define port2 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 114 (list (cons 'x1 x1) (cons 'port1 port1)) (lambda () 80)))
  (define tesl_checked_1 (isValidPort port2))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let x2: ~a" (check-fail-message tesl_checked_1)))
  (define x2 tesl_checked_1)
  (define port3 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 116 (list (cons 'x2 x2) (cons 'port2 port2) (cons 'x1 x1) (cons 'port1 port1)) (lambda () 65535)))
  (define tesl_checked_2 (isValidPort port3))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let x3: ~a" (check-fail-message tesl_checked_2)))
  (define x3 tesl_checked_2)
  (define port4 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 118 (list (cons 'x3 x3) (cons 'port3 port3) (cons 'x2 x2) (cons 'port2 port2) (cons 'x1 x1) (cons 'port1 port1)) (lambda () 8080)))
  (define tesl_checked_3 (isValidPort port4))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let x4: ~a" (check-fail-message tesl_checked_3)))
  (define x4 tesl_checked_3)
  (check-equal? (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 120 (list (cons 'x4 x4) (cons 'port4 port4) (cons 'x3 x3) (cons 'port3 port3) (cons 'x2 x2) (cons 'port2 port2) (cons 'x1 x1) (cons 'port1 port1)) (lambda () 1)) 1)
  )

  (test-case "isValidPort result carries ValidPort proof"
  (define port1 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 124 (list) (lambda () 80)))
  (define tesl_checked_4 (isValidPort port1))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let p1: ~a" (check-fail-message tesl_checked_4)))
  (define p1 tesl_checked_4)
  (define port2 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 126 (list (cons 'p1 p1) (cons 'port1 port1)) (lambda () 8080)))
  (define tesl_checked_5 (isValidPort port2))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let p2: ~a" (check-fail-message tesl_checked_5)))
  (define p2 tesl_checked_5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 128 (list (cons 'p2 p2) (cons 'port2 port2) (cons 'p1 p1) (cons 'port1 port1)) (lambda () (listenOnPort p1)))) "listening on port 80")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 129 (list (cons 'p2 p2) (cons 'port2 port2) (cons 'p1 p1) (cons 'port1 port1)) (lambda () (listenOnPort p2)))) "listening on port 8080")
  )

  (test-case "isValidPort rejects invalid ports"
  (define port0 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 133 (list) (lambda () 0)))
  (define port65536 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 134 (list (cons 'port0 port0)) (lambda () 65536)))
  (define portNeg1 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 135 (list (cons 'port65536 port65536) (cons 'port0 port0)) (lambda () -1)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 136 (list (cons 'portNeg1 portNeg1) (cons 'port65536 port65536) (cons 'port0 port0)) (lambda ()
                          (isValidPort port0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isValidPort port0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 137 (list (cons 'portNeg1 portNeg1) (cons 'port65536 port65536) (cons 'port0 port0)) (lambda ()
                          (isValidPort port65536))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isValidPort port65536"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 138 (list (cons 'portNeg1 portNeg1) (cons 'port65536 port65536) (cons 'port0 port0)) (lambda ()
                          (isValidPort portNeg1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isValidPort portNeg1"))
  )

  (test-case "isPositive accepts positives"
  (define n1 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 142 (list) (lambda () 1)))
  (define tesl_checked_6 (isPositive n1))
  (when (check-fail? tesl_checked_6)
    (raise-user-error 'tesl-test "unexpected failure in let x1: ~a" (check-fail-message tesl_checked_6)))
  (define x1 tesl_checked_6)
  (define n2 (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 144 (list (cons 'x1 x1) (cons 'n1 n1)) (lambda () 100)))
  (define tesl_checked_7 (isPositive n2))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let x2: ~a" (check-fail-message tesl_checked_7)))
  (define x2 tesl_checked_7)
  (check-equal? (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 146 (list (cons 'x2 x2) (cons 'n2 n2) (cons 'x1 x1) (cons 'n1 n1)) (lambda () 1)) 1)
  )

  (test-case "isPositive rejects non-positives"
  (define zero (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 150 (list) (lambda () 0)))
  (define negFive (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 151 (list (cons 'zero zero)) (lambda () -5)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 152 (list (cons 'negFive negFive) (cons 'zero zero)) (lambda ()
                          (isPositive zero))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isPositive zero"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson05-intro-to-proofs.tesl" 153 (list (cons 'negFive negFive) (cons 'zero zero)) (lambda ()
                          (isPositive negFive))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isPositive negFive"))
  )

)
