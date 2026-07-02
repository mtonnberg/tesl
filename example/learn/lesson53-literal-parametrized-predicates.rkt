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
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 64 (list (cons 'n *n)) (lambda () (if (>= *n 10) (accept (HasMin 10 n) #:value *n) (reject "value must be at least 10" #:http-code 400)))))

(define-checker
  (checkMin20 [n : Integer])
  #:returns [n : Integer ::: (HasMin 20 n)]
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 70 (list (cons 'n *n)) (lambda () (if (>= *n 20) (accept (HasMin 20 n) #:value *n) (reject "value must be at least 20" #:http-code 400)))))

(define-checker
  (checkMax100 [n : Integer])
  #:returns [n : Integer ::: (HasMax 100 n)]
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 76 (list (cons 'n *n)) (lambda () (if (<= *n 100) (accept (HasMax 100 n) #:value *n) (reject "value must be at most 100" #:http-code 400)))))

(define/pow
  (needAbove10 [n : Integer ::: (HasMin 10 n)])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 82 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needAbove20 [n : Integer ::: (HasMin 20 n)])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 83 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needBothBounds [n : Integer ::: ((HasMin 10 n) && (HasMax 100 n))])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 84 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (testAllBounds [raw : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 94 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkMin10 raw)]) (let ([a tesl-checked-0]) (let/check ([tesl-checked-1 (checkMax100 a)]) (let ([b tesl-checked-1]) (raw-value (needBothBounds b)))))))))

(define-trusted
  (proveHttp [port : Integer])
  #:returns (Fact (Named "http" port))
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 107 (list (cons 'port *port)) (lambda () (trusted-proof (Named "http" port)))))

(define-trusted
  (proveHttps [port : Integer])
  #:returns (Fact (Named "https" port))
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 111 (list (cons 'port *port)) (lambda () (trusted-proof (Named "https" port)))))

(define/pow
  (needHttp [port : Integer ::: (Named "http" port)])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 113 (list (cons 'port *port)) (lambda () *port)))

(define/pow
  (needHttps [port : Integer ::: (Named "https" port)])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 114 (list (cons 'port *port)) (lambda () *port)))

(define/pow
  (testStringTag [raw : Integer])
  #:returns Integer
  (let ([pf (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 123 (list (cons 'raw *raw)) (lambda () (proveHttp raw)))]) (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 124 (list (cons 'pf *pf) (cons 'raw *raw)) (lambda () (raw-value (needHttp (attach-proof raw pf)))))))

(define-checker
  (checkClamped [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (Clamped lo hi n)]
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 135 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (Clamped lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define/pow
  (needClamped1to100 [n : Integer ::: (Clamped 1 100 n)])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 140 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (testClampedLet [raw : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 145 (list (cons 'raw *raw)) (lambda () (let ([lo 1]) (let ([hi 100]) (let/check ([tesl-checked-2 (checkClamped lo hi raw)]) (let ([v tesl-checked-2]) (raw-value (needClamped1to100 v)))))))))

(define/pow
  (needOneAbove10 [x : Integer ::: (HasMin 10 x)])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 159 (list (cons 'x *x)) (lambda () *x)))

(define/pow
  (needForAllAbove10 [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 162 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldr (let () (define/pow (tesl-lambda-3 [acc : Integer] [x : Integer]) #:returns Integer (let ([x (tesl-establish-param-proof x *x `(HasMin ,10 ,x))]) (+ *acc (raw-value (needOneAbove10 x))))) tesl-lambda-3) 0 *xs)))))

(define/pow
  (filterAbove10 [raw : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 165 (list (cons 'raw *raw)) (lambda () (tesl_import_List_filterCheck checkMin10 *raw))))

(define/pow
  (needForAllAbove20 [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 170 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (filterAbove20 [raw : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 173 (list (cons 'raw *raw)) (lambda () (tesl_import_List_filterCheck checkMin20 *raw))))

(define/pow
  (filterInRange1to100 [raw : (List Integer)])
  #:returns Integer
  (let ([lo (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 177 (list (cons 'raw *raw)) (lambda () (filterAbove10 raw)))]) (let ([filtered (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 178 (list (cons 'lo *lo) (cons 'raw *raw)) (lambda () (tesl_import_List_filterCheck checkMax100 (raw-value lo))))]) (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 179 (list (cons 'filtered *filtered) (cons 'lo *lo) (cons 'raw *raw)) (lambda () (raw-value (tesl_import_List_length (raw-value filtered))))))))

(module+ test
  (require rackunit)
  (test-case "Part 1: integer literal predicates"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 187 (list) (lambda () (testAllBounds 10)))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 188 (list) (lambda () (testAllBounds 50)))) 50)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 189 (list) (lambda () (testAllBounds 100)))) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 192 (list) (lambda ()
                          (testAllBounds 9))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testAllBounds 9"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 193 (list) (lambda ()
                          (testAllBounds 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testAllBounds 101"))
  (define raw10 (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 196 (list) (lambda () 10)))
  (define tesl-checked-4 (checkMin10 raw10))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let v10: ~a" (check-fail-message tesl-checked-4)))
  (define v10 tesl-checked-4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 198 (list (cons 'v10 v10) (cons 'raw10 raw10)) (lambda () (needAbove10 v10)))) 10)
  (define raw20 (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 201 (list (cons 'v10 v10) (cons 'raw10 raw10)) (lambda () 20)))
  (define tesl-checked-5 (checkMin20 raw20))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let v20: ~a" (check-fail-message tesl-checked-5)))
  (define v20 tesl-checked-5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 203 (list (cons 'v20 v20) (cons 'raw20 raw20) (cons 'v10 v10) (cons 'raw10 raw10)) (lambda () (needAbove20 v20)))) 20)
  (define raw15 (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 206 (list (cons 'v20 v20) (cons 'raw20 raw20) (cons 'v10 v10) (cons 'raw10 raw10)) (lambda () 15)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 207 (list (cons 'raw15 raw15) (cons 'v20 v20) (cons 'raw20 raw20) (cons 'v10 v10) (cons 'raw10 raw10)) (lambda ()
                          (checkMin20 raw15))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkMin20 raw15"))
  )

  (test-case "Part 2: string literal predicates"
  (define port80 (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 211 (list) (lambda () 80)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 212 (list (cons 'port80 port80)) (lambda () (testStringTag port80)))) 80)
  (define port443 (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 214 (list (cons 'port80 port80)) (lambda () 443)))
  (define pf (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 215 (list (cons 'port443 port443) (cons 'port80 port80)) (lambda () (proveHttps port443))))
  (define result (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 216 (list (cons 'pf pf) (cons 'port443 port443) (cons 'port80 port80)) (lambda () (needHttps (attach-proof port443 pf)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 217 (list (cons 'result result) (cons 'pf pf) (cons 'port443 port443) (cons 'port80 port80)) (lambda () result))) 443)
  )

  (test-case "Part 3: mixed literal and variable subjects"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 221 (list) (lambda () (testClampedLet 50)))) 50)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 222 (list) (lambda () (testClampedLet 1)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 223 (list) (lambda () (testClampedLet 100)))) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 224 (list) (lambda ()
                          (testClampedLet 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testClampedLet 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 225 (list) (lambda ()
                          (testClampedLet 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testClampedLet 101"))
  )

  (test-case "Part 4: ForAll with literal-parametrized predicates"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 230 (list) (lambda () (filterInRange1to100 (list 10 20 5 30))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 231 (list) (lambda () (filterInRange1to100 (list 1 2 13))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 232 (list) (lambda () (filterInRange1to100 (list 5 8 9))))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 233 (list) (lambda () (filterInRange1to100 (list 10 100 110))))) 2)
  (define xs10 (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 236 (list) (lambda () (filterAbove10 (list 5 10 15 20 3)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 237 (list (cons 'xs10 xs10)) (lambda () (needForAllAbove10 xs10)))) 45)
  (define xs20 (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 240 (list (cons 'xs10 xs10)) (lambda () (filterAbove20 (list 15 25 30 5)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson53-literal-parametrized-predicates.tesl" 241 (list (cons 'xs20 xs20) (cons 'xs10 xs10)) (lambda () (needForAllAbove20 xs20)))) 2)
  )

)
