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
  (only-in tesl/tesl/prelude Bool Int String List Fact)
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.length tesl_import_List_length] [List.foldr tesl_import_List_foldr])
)


(provide needAbove10 needAbove20 needBothBounds needHttp testAllBounds testStringTag filterInRange1to100 needAbove10-signature needAbove20-signature needBothBounds-signature testAllBounds-signature needHttp-signature testStringTag-signature filterInRange1to100-signature)

(define Clamped 'Clamped)
(define HasMax 'HasMax)
(define HasMin 'HasMin)
(define Named 'Named)

(define-checker
  (checkMin10 [n : Integer])
  #:returns [n : Integer ::: (HasMin 10 n)]
  (if (>= *n 10) (accept (HasMin 10 n) #:value *n) (reject "value must be at least 10" #:http-code 400)))

(define-checker
  (checkMin20 [n : Integer])
  #:returns [n : Integer ::: (HasMin 20 n)]
  (if (>= *n 20) (accept (HasMin 20 n) #:value *n) (reject "value must be at least 20" #:http-code 400)))

(define-checker
  (checkMax100 [n : Integer])
  #:returns [n : Integer ::: (HasMax 100 n)]
  (if (<= *n 100) (accept (HasMax 100 n) #:value *n) (reject "value must be at most 100" #:http-code 400)))

(define/pow
  (needAbove10 [n : Integer ::: (HasMin 10 n)])
  #:returns Integer
  *n)

(define/pow
  (needAbove20 [n : Integer ::: (HasMin 20 n)])
  #:returns Integer
  *n)

(define/pow
  (needBothBounds [n : Integer ::: ((HasMin 10 n) && (HasMax 100 n))])
  #:returns Integer
  *n)

(define/pow
  (testAllBounds [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (checkMin10 raw)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkMax100 a)]) (let ([b tesl_checked_1]) (raw-value (needBothBounds b)))))))

(define-trusted
  (proveHttp [port : Integer])
  #:returns (Fact (Named "http" port))
  (trusted-proof (Named "http" port)))

(define-trusted
  (proveHttps [port : Integer])
  #:returns (Fact (Named "https" port))
  (trusted-proof (Named "https" port)))

(define/pow
  (needHttp [port : Integer ::: (Named "http" port)])
  #:returns Integer
  *port)

(define/pow
  (needHttps [port : Integer ::: (Named "https" port)])
  #:returns Integer
  *port)

(define/pow
  (testStringTag [raw : Integer])
  #:returns Integer
  (let ([pf (proveHttp raw)]) (raw-value (needHttp (attach-proof raw pf)))))

(define-checker
  (checkClamped [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (Clamped lo hi n)]
  (if (and (<= *lo *n) (<= *n *hi)) (accept (Clamped lo hi n) #:value *n) (reject "out of range" #:http-code 400)))

(define/pow
  (needClamped1to100 [n : Integer ::: (Clamped 1 100 n)])
  #:returns Integer
  *n)

(define/pow
  (testClampedLet [raw : Integer])
  #:returns Integer
  (let ([lo 1]) (let ([hi 100]) (let/check ([tesl_checked_2 (checkClamped lo hi raw)]) (let ([v tesl_checked_2]) (raw-value (needClamped1to100 v)))))))

(define/pow
  (needOneAbove10 [x : Integer ::: (HasMin 10 x)])
  #:returns Integer
  *x)

(define/pow
  (needForAllAbove10 [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldr (let () (define/pow (tesl-lambda-3 [acc : Integer] [x : Integer]) #:returns Integer (let ([x (tesl-establish-param-proof x *x `(HasMin ,10 ,x))]) (+ *acc (raw-value (needOneAbove10 x))))) tesl-lambda-3) 0 *xs)))

(define/pow
  (filterAbove10 [raw : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkMin10 *raw))

(define/pow
  (needForAllAbove20 [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (filterAbove20 [raw : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkMin20 *raw))

(define/pow
  (filterInRange1to100 [raw : (List Integer)])
  #:returns Integer
  (let ([lo (filterAbove10 raw)]) (let ([filtered (tesl_import_List_filterCheck checkMax100 (raw-value lo))]) (raw-value (tesl_import_List_length (raw-value filtered))))))

(module+ test
  (require rackunit)
  (test-case "Part 1: integer literal predicates"
  (check-equal? (raw-value (testAllBounds 10)) 10)
  (check-equal? (raw-value (testAllBounds 50)) 50)
  (check-equal? (raw-value (testAllBounds 100)) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (testAllBounds 9))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testAllBounds 9"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (testAllBounds 101))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testAllBounds 101"))
  (define raw10 10)
  (define tesl_checked_4 (checkMin10 raw10))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let v10: ~a" (check-fail-message tesl_checked_4)))
  (define v10 tesl_checked_4)
  (check-equal? (raw-value (needAbove10 v10)) 10)
  (define raw20 20)
  (define tesl_checked_5 (checkMin20 raw20))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let v20: ~a" (check-fail-message tesl_checked_5)))
  (define v20 tesl_checked_5)
  (check-equal? (raw-value (needAbove20 v20)) 20)
  (define raw15 15)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkMin20 raw15))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkMin20 raw15"))
  )

  (test-case "Part 2: string literal predicates"
  (define port80 80)
  (check-equal? (raw-value (testStringTag port80)) 80)
  (define port443 443)
  (define pf (proveHttps port443))
  (define result (needHttps (attach-proof port443 pf)))
  (check-equal? (raw-value result) 443)
  )

  (test-case "Part 3: mixed literal and variable subjects"
  (check-equal? (raw-value (testClampedLet 50)) 50)
  (check-equal? (raw-value (testClampedLet 1)) 1)
  (check-equal? (raw-value (testClampedLet 100)) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (testClampedLet 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testClampedLet 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (testClampedLet 101))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testClampedLet 101"))
  )

  (test-case "Part 4: ForAll with literal-parametrized predicates"
  (check-equal? (raw-value (filterInRange1to100 (list 10 20 5 30))) 3)
  (check-equal? (raw-value (filterInRange1to100 (list 1 2 13))) 1)
  (check-equal? (raw-value (filterInRange1to100 (list 5 8 9))) 0)
  (check-equal? (raw-value (filterInRange1to100 (list 10 100 110))) 2)
  (define xs10 (filterAbove10 (list 5 10 15 20 3)))
  (check-equal? (raw-value (needForAllAbove10 xs10)) 45)
  (define xs20 (filterAbove20 (list 15 25 30 5)))
  (check-equal? (raw-value (needForAllAbove20 xs20)) 2)
  )

)
