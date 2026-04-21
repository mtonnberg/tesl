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
  (only-in tesl/tesl/prelude Int String)
)


(provide ValidPort isValidPort Positive isPositive listenOnPort requiresPositive isValidPort-signature isPositive-signature listenOnPort-signature requiresPositive-signature)

(define Positive 'Positive)
(define ValidPort 'ValidPort)

(define-checker
  (isValidPort [port : Integer])
  #:returns [port : Integer ::: (ValidPort port)]
  (if (and (<= 1 *port) (<= *port 65535)) (accept (ValidPort port) #:value *port) (reject "port must be between 1 and 65535" #:http-code 400)))

(define-checker
  (isPositive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if (> *n 0) (accept (Positive n) #:value *n) (reject "must be positive" #:http-code 400)))

(define/pow
  (listenOnPort [port : Integer ::: (ValidPort port)])
  #:returns String
  (format "listening on port ~a" (tesl-display-val *port)))

(define/pow
  (requiresPositive [n : Integer ::: (Positive n)])
  #:returns Integer
  (* *n 2))

(module+ test
  (require rackunit)
  (test-case "isValidPort accepts valid ports"
  (define port1 1)
  (define tesl_checked_0 (isValidPort port1))
  (when (check-fail? tesl_checked_0)
    (raise-user-error 'tesl-test "unexpected failure in let x1: ~a" (check-fail-message tesl_checked_0)))
  (define x1 tesl_checked_0)
  (define port2 80)
  (define tesl_checked_1 (isValidPort port2))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let x2: ~a" (check-fail-message tesl_checked_1)))
  (define x2 tesl_checked_1)
  (define port3 65535)
  (define tesl_checked_2 (isValidPort port3))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let x3: ~a" (check-fail-message tesl_checked_2)))
  (define x3 tesl_checked_2)
  (define port4 8080)
  (define tesl_checked_3 (isValidPort port4))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let x4: ~a" (check-fail-message tesl_checked_3)))
  (define x4 tesl_checked_3)
  (check-equal? 1 1)
  )

  (test-case "isValidPort result carries ValidPort proof"
  (define port1 80)
  (define tesl_checked_4 (isValidPort port1))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let p1: ~a" (check-fail-message tesl_checked_4)))
  (define p1 tesl_checked_4)
  (define port2 8080)
  (define tesl_checked_5 (isValidPort port2))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let p2: ~a" (check-fail-message tesl_checked_5)))
  (define p2 tesl_checked_5)
  (check-equal? (raw-value (listenOnPort p1)) "listening on port 80")
  (check-equal? (raw-value (listenOnPort p2)) "listening on port 8080")
  )

  (test-case "isValidPort rejects invalid ports"
  (define port0 0)
  (define port65536 65536)
  (define portNeg1 -1)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (isValidPort port0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isValidPort port0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (isValidPort port65536))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isValidPort port65536"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (isValidPort portNeg1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isValidPort portNeg1"))
  )

  (test-case "isPositive accepts positives"
  (define n1 1)
  (define tesl_checked_6 (isPositive n1))
  (when (check-fail? tesl_checked_6)
    (raise-user-error 'tesl-test "unexpected failure in let x1: ~a" (check-fail-message tesl_checked_6)))
  (define x1 tesl_checked_6)
  (define n2 100)
  (define tesl_checked_7 (isPositive n2))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let x2: ~a" (check-fail-message tesl_checked_7)))
  (define x2 tesl_checked_7)
  (check-equal? 1 1)
  )

  (test-case "isPositive rejects non-positives"
  (define zero 0)
  (define negFive -5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (isPositive zero))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isPositive zero"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (isPositive negFive))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check isPositive negFive"))
  )

)
