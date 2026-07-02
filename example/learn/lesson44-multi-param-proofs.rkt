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
  (only-in tesl/tesl/prelude Bool Int String Fact)
)


(provide InBounds checkInBounds requiresInBounds describeInBounds InWindow checkInWindow pairDescription Approved checkBudget approvedDescription InRange InOrder checkSortedPair useSortedPair checkInBounds-signature requiresInBounds-signature describeInBounds-signature checkBudget-signature approvedDescription-signature checkInWindow-signature pairDescription-signature checkSortedPair-signature useSortedPair-signature)

(define Approved 'Approved)
(define InBounds 'InBounds)
(define InOrder 'InOrder)
(define InRange 'InRange)
(define InWindow 'InWindow)

(define-checker
  (checkInBounds [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InBounds lo hi n)]
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 63 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (>= *n *lo) (<= *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "value out of bounds" #:http-code 400)))))

(define/pow
  (requiresInBounds [lo : Integer] [hi : Integer] [n : Integer ::: (InBounds lo hi n)])
  #:returns String
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 69 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (format "~a is in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))))

(define/pow
  (describeInBounds [lo : Integer] [hi : Integer] [raw : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 74 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkInBounds lo hi raw)]) (let ([safeN tesl-checked-0]) (raw-value (requiresInBounds lo hi safeN)))))))

(define-checker
  (checkBudget [amount : Integer] [budget : Integer])
  #:returns [amount : Integer ::: (Approved amount budget)]
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 87 (list (cons 'amount *amount) (cons 'budget *budget)) (lambda () (if (<= *amount *budget) (accept (Approved amount budget) #:value *amount) (reject "amount exceeds budget" #:http-code 400)))))

(define/pow
  (requiresApproved [amount : Integer ::: (Approved amount budget)] [budget : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 93 (list (cons 'amount *amount) (cons 'budget *budget)) (lambda () (format "approved ~a of ~a" (tesl-display-val *amount) (tesl-display-val *budget)))))

(define/pow
  (approvedDescription [rawAmount : Integer] [rawBudget : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 96 (list (cons 'rawAmount *rawAmount) (cons 'rawBudget *rawBudget)) (lambda () (let ([budget rawBudget]) (let/check ([tesl-checked-1 (checkBudget rawAmount budget)]) (let ([amount tesl-checked-1]) (raw-value (requiresApproved amount budget))))))))

(define-checker
  (checkInWindow [start : Integer] [span : Integer] [t : Integer])
  #:returns [t : Integer ::: (InWindow start span t)]
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 109 (list (cons 'start *start) (cons 'span *span) (cons 't *t)) (lambda () (if (and (>= *t *start) (<= *t (+ *start *span))) (accept (InWindow start span t) #:value *t) (reject "value outside window" #:http-code 400)))))

(define/pow
  (requiresInWindow [start : Integer] [span : Integer] [t : Integer ::: (InWindow start span t)])
  #:returns String
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 115 (list (cons 'start *start) (cons 'span *span) (cons 't *t)) (lambda () (format "~a is in window [~a, ~a]" (tesl-display-val *t) (tesl-display-val *start) (tesl-display-val (+ *start *span))))))

(define/pow
  (pairDescription [start : Integer] [span : Integer] [raw1 : Integer] [raw2 : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 118 (list (cons 'start *start) (cons 'span *span) (cons 'raw1 *raw1) (cons 'raw2 *raw2)) (lambda () (let/check ([tesl-checked-2 (checkInWindow start span raw1)]) (let ([t1 tesl-checked-2]) (let/check ([tesl-checked-3 (checkInWindow start span raw2)]) (let ([t2 tesl-checked-3]) (let ([s1 (requiresInWindow start span t1)]) (let ([s2 (requiresInWindow start span t2)]) (format "~a and ~a" (tesl-display-val *s1) (tesl-display-val *s2)))))))))))

(define-checker
  (checkSortedPair [a : Integer] [b : Integer])
  #:returns [a : Integer ::: ((InRange a) && (InOrder a b))]
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 136 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (and (>= *a 0) (<= *a 100) (>= *b 0) (<= *b 100) (<= *a *b)) (accept ((InRange a) && (InOrder a b)) #:value *a) (reject "pair must be sorted and in [0,100]" #:http-code 400)))))

(define/pow
  (useSortedPair [a : Integer ::: ((InRange a) && (InOrder a b))] [b : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 142 (list (cons 'a *a) (cons 'b *b)) (lambda () (format "~a \u2264 ~a (both in range)" (tesl-display-val *a) (tesl-display-val *b)))))

(define/pow
  (describeSortedPair [rawA : Integer] [b : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 147 (list (cons 'rawA *rawA) (cons 'b *b)) (lambda () (let/check ([tesl-checked-4 (checkSortedPair rawA b)]) (let ([a tesl-checked-4]) (raw-value (useSortedPair a b)))))))

(module+ test
  (require rackunit)
  (test-case "checkInBounds: value in range (via wrapper)"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 230 (list) (lambda () (describeInBounds 1 10 5)))) "5 is in [1, 10]")
  )

  (test-case "checkInBounds: boundary values (via wrapper)"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 234 (list) (lambda () (describeInBounds 0 100 0)))) "0 is in [0, 100]")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 235 (list) (lambda () (describeInBounds 0 100 100)))) "100 is in [0, 100]")
  )

  (test-case "checkInBounds: rejects out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 239 (list) (lambda ()
                          (checkInBounds 0 10 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds 0 10 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 240 (list) (lambda ()
                          (checkInBounds 0 10 11))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds 0 10 11"))
  )

  (test-case "describeInBounds: full round-trip"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 244 (list) (lambda () (describeInBounds 1 10 7)))) "7 is in [1, 10]")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 245 (list) (lambda ()
                          (describeInBounds 1 5 6))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: describeInBounds 1 5 6"))
  )

  (test-case "checkBudget: first-param proof, under budget"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 249 (list) (lambda () (approvedDescription 80 100)))) "approved 80 of 100")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 250 (list) (lambda () (approvedDescription 100 100)))) "approved 100 of 100")
  )

  (test-case "checkBudget: rejects over budget"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 254 (list) (lambda ()
                          (checkBudget 101 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBudget 101 100"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 255 (list) (lambda ()
                          (checkBudget 200 50))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBudget 200 50"))
  )

  (test-case "checkInWindow: timestamp in window"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 259 (list) (lambda () (pairDescription 100 50 120 150)))) "120 is in window [100, 150] and 150 is in window [100, 150]")
  )

  (test-case "checkInWindow: rejects outside window"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 263 (list) (lambda ()
                          (checkInWindow 100 50 99))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInWindow 100 50 99"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 264 (list) (lambda ()
                          (checkInWindow 100 50 151))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInWindow 100 50 151"))
  )

  (test-case "checkSortedPair: sorted in-range pair (via wrapper)"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 270 (list) (lambda () (describeSortedPair 10 90)))) "10 \u2264 90 (both in range)")
  )

  (test-case "checkSortedPair: equal values are valid (via wrapper)"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 274 (list) (lambda () (describeSortedPair 50 50)))) "50 \u2264 50 (both in range)")
  )

  (test-case "checkSortedPair: rejects unsorted"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 278 (list) (lambda ()
                          (checkSortedPair 90 10))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSortedPair 90 10"))
  )

  (test-case "checkSortedPair: rejects out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 282 (list) (lambda ()
                          (checkSortedPair -1 50))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSortedPair -1 50"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson44-multi-param-proofs.tesl" 283 (list) (lambda ()
                          (checkSortedPair 10 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSortedPair 10 101"))
  )

)
