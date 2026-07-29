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
  (only-in tesl/tesl/prelude Bool Int Fact)
)


(provide P1 P2 P3 check1 check2 check3 wrapSingle wrapDouble wrapTriple needsP1 needsP1P2 needsP1P2P3 letBoundWrap letBoundWrapDouble chainedWrap check1-signature check2-signature check3-signature needsP1-signature needsP1P2-signature needsP1P2P3-signature wrapSingle-signature wrapDouble-signature wrapTriple-signature letBoundWrap-signature letBoundWrapDouble-signature chainedWrap-signature)

(define P1 'P1)
(define P2 'P2)
(define P3 'P3)

(define-checker
  (check1 [n : Integer])
  #:returns [n : Integer ::: (P1 n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 26 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (P1 n) #:value *n) (reject "fail1" #:http-code 400)))))

(define-checker
  (check2 [n : Integer])
  #:returns [n : Integer ::: (P2 n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 32 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (P2 n) #:value *n) (reject "fail2" #:http-code 400)))))

(define-checker
  (check3 [n : Integer])
  #:returns [n : Integer ::: (P3 n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 38 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 42)) (accept (P3 n) #:value *n) (reject "fail3" #:http-code 400)))))

(define/pow
  (needsP1 [n : Integer ::: (P1 n)])
  #:returns Integer
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 43 (list (cons 'n *n)) (lambda () (+ *n 1))))

(define/pow
  (needsP1P2 [n : Integer ::: ((P1 n) && (P2 n))])
  #:returns Integer
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 44 (list (cons 'n *n)) (lambda () (+ *n 2))))

(define/pow
  (needsP1P2P3 [n : Integer ::: ((P1 n) && ((P2 n) && (P3 n)))])
  #:returns Integer
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 45 (list (cons 'n *n)) (lambda () (+ *n 3))))

(define-checker
  (wrapSingle [n : Integer])
  #:returns [n : Integer ::: (P1 n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 49 (list (cons 'n *n)) (lambda () (check1 n))))

(define-checker
  (wrapDouble [n : Integer])
  #:returns [n : Integer ::: ((P1 n) && (P2 n))]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 53 (list (cons 'n *n)) (lambda () ((check-and check1 check2) n))))

(define-checker
  (wrapTriple [n : Integer])
  #:returns [n : Integer ::: ((P1 n) && ((P2 n) && (P3 n)))]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 57 (list (cons 'n *n)) (lambda () ((check-and check1 (check-and check2 check3)) n))))

(define-checker
  (letBoundWrap [n : Integer])
  #:returns [n : Integer ::: (P1 n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 61 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-0 (check1 n)]) (let ([validated tesl-checked-0]) validated)))))

(define-checker
  (letBoundWrapDouble [n : Integer])
  #:returns [n : Integer ::: ((P1 n) && (P2 n))]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 66 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-1 ((check-and check1 check2) n)]) (let ([validated tesl-checked-1]) validated)))))

(define-checker
  (chainedWrap [n : Integer])
  #:returns [n : Integer ::: ((P1 n) && (P2 n))]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 71 (list (cons 'n *n)) (lambda () (wrapDouble n))))

(module+ test
  (require rackunit)
  (test-case "A1: bare single-check delegation passes"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 76 (list) (lambda () 5)))
  (define tesl-checked-2 (wrapSingle n))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-2)))
  (define v tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 78 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1 v)))) 6)
    ))
  )

  (test-case "A2: bare single-check delegation rejects"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 82 (list) (lambda ()
                          (wrapSingle 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check wrapSingle 0"))
    ))
  )

  (test-case "B1: bare double conjunction passes"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 86 (list) (lambda () 50)))
  (define tesl-checked-3 (wrapDouble n))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-3)))
  (define v tesl-checked-3)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 88 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1P2 v)))) 52)
    ))
  )

  (test-case "B2: bare double conjunction rejects first"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 92 (list) (lambda ()
                          (wrapDouble 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check wrapDouble 0"))
    ))
  )

  (test-case "B3: bare double conjunction rejects second"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 96 (list) (lambda ()
                          (wrapDouble 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check wrapDouble 100"))
    ))
  )

  (test-case "B4: bare double conjunction at boundary 1"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 100 (list) (lambda () 1)))
  (define tesl-checked-4 (wrapDouble n))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-4)))
  (define v tesl-checked-4)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 102 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1P2 v)))) 3)
    ))
  )

  (test-case "B5: bare double conjunction at boundary 99"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 106 (list) (lambda () 99)))
  (define tesl-checked-5 (wrapDouble n))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-5)))
  (define v tesl-checked-5)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 108 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1P2 v)))) 101)
    ))
  )

  (test-case "C1: bare triple conjunction passes"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 112 (list) (lambda () 50)))
  (define tesl-checked-6 (wrapTriple n))
  (when (check-fail? tesl-checked-6)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-6)))
  (define v tesl-checked-6)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 114 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1P2P3 v)))) 53)
    ))
  )

  (test-case "C2: triple rejects P1 violation"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 118 (list) (lambda ()
                          (wrapTriple 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check wrapTriple 0"))
    ))
  )

  (test-case "C3: triple rejects P2 violation"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 122 (list) (lambda ()
                          (wrapTriple 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check wrapTriple 100"))
    ))
  )

  (test-case "C4: triple rejects P3 violation"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 126 (list) (lambda ()
                          (wrapTriple 42))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check wrapTriple 42"))
    ))
  )

  (test-case "C5: triple at boundary 1 (passes all three)"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 130 (list) (lambda () 1)))
  (define tesl-checked-7 (wrapTriple n))
  (when (check-fail? tesl-checked-7)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-7)))
  (define v tesl-checked-7)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 132 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1P2P3 v)))) 4)
    ))
  )

  (test-case "D1: let-bound single check passes"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 136 (list) (lambda () 5)))
  (define tesl-checked-8 (letBoundWrap n))
  (when (check-fail? tesl-checked-8)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-8)))
  (define v tesl-checked-8)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 138 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1 v)))) 6)
    ))
  )

  (test-case "D2: let-bound single check rejects"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 142 (list) (lambda ()
                          (letBoundWrap 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check letBoundWrap 0"))
    ))
  )

  (test-case "E1: let-bound conjunction passes"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 146 (list) (lambda () 50)))
  (define tesl-checked-9 (letBoundWrapDouble n))
  (when (check-fail? tesl-checked-9)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-9)))
  (define v tesl-checked-9)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 148 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1P2 v)))) 52)
    ))
  )

  (test-case "E2: let-bound conjunction rejects first"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 152 (list) (lambda ()
                          (letBoundWrapDouble 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check letBoundWrapDouble 0"))
    ))
  )

  (test-case "E3: let-bound conjunction rejects second"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 156 (list) (lambda ()
                          (letBoundWrapDouble 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check letBoundWrapDouble 100"))
    ))
  )

  (test-case "F1: chained wrap passes"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 160 (list) (lambda () 50)))
  (define tesl-checked-10 (chainedWrap n))
  (when (check-fail? tesl-checked-10)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-10)))
  (define v tesl-checked-10)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 162 (list (cons 'v v) (cons 'n n)) (lambda () (needsP1P2 v)))) 52)
    ))
  )

  (test-case "F2: chained wrap rejects"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 166 (list) (lambda ()
                          (chainedWrap 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check chainedWrap 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/critical-review-48-conjunction-regression.tesl" 167 (list) (lambda ()
                          (chainedWrap 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check chainedWrap 100"))
    ))
  )

)
