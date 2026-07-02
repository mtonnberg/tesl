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
  (only-in tesl/tesl/prelude Int Bool List Fact forgetFact)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck])
)


(provide )

(define InRange 'InRange)
(define IsEven 'IsEven)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)

(define-checker
  (isPositive [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review-52-tests.tesl" 40 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (isSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review-52-tests.tesl" 46 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "not small" #:http-code 400)))))

(define-checker
  (isEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review-52-tests.tesl" 52 (list (cons 'n *n)) (lambda () (if (equal? (remainder *n 2) 0) (accept (IsEven n) #:value *n) (reject "not even" #:http-code 400)))))

(define-checker
  (inRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange lo hi n)]
  (thsl-src! "tests/critical-review-52-tests.tesl" 58 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define/pow
  (needPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 63 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 64 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 65 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needInRange [_lo : Integer] [_hi : Integer] [n : Integer ::: (InRange _lo _hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 66 (list (cons '_lo *_lo) (cons '_hi *_hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (needThree [n : Integer ::: ((IsPositive n) && ((IsSmall n) && (IsEven n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 67 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (p01_lambda_with_checked_arg [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 78 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_0 (isPositive raw)]) (let ([checked tesl_checked_0]) (let ([f (let () (define/pow (tesl-lambda-1 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) n)) tesl-lambda-1)]) (raw-value (f checked))))))))

(define/pow
  (p02_triple_chain [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 84 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_2 (isPositive raw)]) (let ([a tesl_checked_2]) (let/check ([tesl_checked_3 (isSmall a)]) (let ([b tesl_checked_3]) (let/check ([tesl_checked_4 (isEven b)]) (let ([c tesl_checked_4]) (raw-value (needThree c)))))))))))

(define/pow
  (p03_triple_commutes [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 92 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_5 (isPositive raw)]) (let ([a tesl_checked_5]) (let/check ([tesl_checked_6 (isSmall a)]) (let ([b tesl_checked_6]) (let/check ([tesl_checked_7 (isEven b)]) (let ([c tesl_checked_7]) (let ([needReordered (let () (define/pow (tesl-lambda-8 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(((IsEven n) && ((IsPositive n) && (IsSmall n)))))]) n)) tesl-lambda-8)]) (raw-value (needReordered c))))))))))))

(define/pow
  (p04_forget_recheck [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 101 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_9 (isPositive raw)]) (let ([a tesl_checked_9]) (let ([b (forget-proof a)]) (let/check ([tesl_checked_10 (isPositive b)]) (let ([c tesl_checked_10]) (raw-value (needPos c))))))))))

(define/pow
  (d01_single_decompose [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 112 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_11 (isPositive raw)]) (let ([p tesl_checked_11]) (let ([tesl_proof_binding_12 p]) (let ([v (forget-proof tesl_proof_binding_12)] [proof (detach-all-proof tesl_proof_binding_12)]) (let ([reat (attach-proof v proof)]) (raw-value (needPos reat))))))))))

(define/pow
  (d02_pair_decompose [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 119 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_13 (isPositive raw)]) (let ([a tesl_checked_13]) (let/check ([tesl_checked_14 (isSmall a)]) (let ([b tesl_checked_14]) (let ([tesl_proof_binding_15 b]) (let ([v (forget-proof tesl_proof_binding_15)] [p1 (detach-all-proof tesl_proof_binding_15)]) (let ([tesl_proof_binding_16 b]) (let ([_ (forget-proof tesl_proof_binding_16)] [p2 (detach-all-proof tesl_proof_binding_16)]) (let ([reat (attach-proof v (list p1 p2))]) (let ([needBoth (let () (define/pow (tesl-lambda-17 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(((IsPositive n) && (IsSmall n))))]) n)) tesl-lambda-17)]) (raw-value (needBoth reat)))))))))))))))

(define/pow
  (d03_triple_discard [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 128 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_18 (isPositive raw)]) (let ([a tesl_checked_18]) (let/check ([tesl_checked_19 (isSmall a)]) (let ([b tesl_checked_19]) (let/check ([tesl_checked_20 (isEven b)]) (let ([c tesl_checked_20]) (let ([tesl_proof_binding_21 c]) (let ([v (forget-proof tesl_proof_binding_21)] [pe (detach-all-proof tesl_proof_binding_21)]) (raw-value (needEven (attach-proof v pe))))))))))))))

(define/pow
  (m01_multi_param [lo : Integer] [hi : Integer] [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 140 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_22 (inRange lo hi raw)]) (let ([ranged tesl_checked_22]) (raw-value (needInRange lo hi ranged)))))))

(define/pow
  (m02_multi_decomp [lo : Integer] [hi : Integer] [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-52-tests.tesl" 145 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_23 (inRange lo hi raw)]) (let ([ranged tesl_checked_23]) (let ([tesl_proof_binding_24 ranged]) (let ([v (forget-proof tesl_proof_binding_24)] [p (detach-all-proof tesl_proof_binding_24)]) (let ([reat (attach-proof v p)]) (raw-value (needInRange lo hi reat))))))))))

(define/pow
  (f01_filter_check [xs : (List Integer)])
  #:returns Integer
  (let ([checked (thsl-src! "tests/critical-review-52-tests.tesl" 156 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck isPositive *xs)))]) (let ([needAllPos (thsl-src! "tests/critical-review-52-tests.tesl" 157 (list (cons 'checked *checked) (cons 'xs *xs)) (lambda () (let () (define/pow (tesl-lambda-25 [ys : (List Integer)]) #:returns Integer (raw-value (tesl_import_List_length *ys))) tesl-lambda-25)))]) (thsl-src! "tests/critical-review-52-tests.tesl" 158 (list (cons 'needAllPos *needAllPos) (cons 'checked *checked) (cons 'xs *xs)) (lambda () (raw-value (needAllPos checked)))))))

(define/pow
  (f02_all_check [xs : (List Integer)])
  #:returns Integer
  (let ([result (thsl-src! "tests/critical-review-52-tests.tesl" 162 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck isPositive *xs)))]) (thsl-src-control! "tests/critical-review-52-tests.tesl" 163 (list (cons 'result *result) (cons 'xs *xs)) (lambda () (let ([tesl_case_26 (raw-value result)]) (cond [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Something)) (let ([checked (hash-ref (adt-value-fields *tesl_case_26) 'value)]) (thsl-src! "tests/critical-review-52-tests.tesl" 165 (list (cons 'checked checked)) (lambda () (raw-value (raw-value (tesl_import_List_length *checked))))))] [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Nothing)) (thsl-src! "tests/critical-review-52-tests.tesl" 167 (list) (lambda () (raw-value (- 0 1))))]))))))

(define/pow
  (c01_guard_with_catchall [m : (Maybe Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-52-tests.tesl" 179 (list (cons 'm *m)) (lambda () (let ([tesl_case_27 *m]) (cond [(and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Nothing)) (thsl-src! "tests/critical-review-52-tests.tesl" 181 (list) (lambda () (raw-value 0)))] [(and (and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_27) 'value)]) (> *n 0))) (let ([n (hash-ref (adt-value-fields *tesl_case_27) 'value)]) (thsl-src! "tests/critical-review-52-tests.tesl" 183 (list (cons 'n n)) (lambda () *n)))] [(and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Something)) (thsl-src! "tests/critical-review-52-tests.tesl" 185 (list) (lambda () (raw-value (- 0 1))))])))))

(define/pow
  (c03_case_arith [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-52-tests.tesl" 189 (list (cons 'a *a) (cons 'b *b)) (lambda () (let ([tesl_case_28 (raw-value (+ *a *b))]) (cond [(= *tesl_case_28 0) (thsl-src! "tests/critical-review-52-tests.tesl" 190 (list) (lambda () (raw-value 100)))] [#t (thsl-src! "tests/critical-review-52-tests.tesl" 191 (list) (lambda () (raw-value (+ *a *b))))])))))

(define/pow
  (c04_nested_nullary [m : (Maybe (Maybe Integer))])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-52-tests.tesl" 195 (list (cons 'm *m)) (lambda () (let ([tesl_case_29 *m]) (cond [(and (adt-value? *tesl_case_29) (eq? (adt-value-variant *tesl_case_29) 'Nothing)) (thsl-src! "tests/critical-review-52-tests.tesl" 196 (list) (lambda () (raw-value 0)))] [(and (and (adt-value? *tesl_case_29) (eq? (adt-value-variant *tesl_case_29) 'Something)) (let ([tesl_case_29_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_29) 'value))]) (and (adt-value? *tesl_case_29_f0) (eq? (adt-value-variant *tesl_case_29_f0) 'Nothing)))) (let ([tesl_case_29_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_29) 'value))]) (thsl-src! "tests/critical-review-52-tests.tesl" 197 (list) (lambda () (raw-value 1))))] [(and (and (adt-value? *tesl_case_29) (eq? (adt-value-variant *tesl_case_29) 'Something)) (let ([tesl_case_29_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_29) 'value))]) (and (adt-value? *tesl_case_29_f0) (eq? (adt-value-variant *tesl_case_29_f0) 'Something)))) (let ([tesl_case_29_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_29) 'value))]) (let ([n (hash-ref (adt-value-fields *tesl_case_29_f0) 'value)]) (thsl-src! "tests/critical-review-52-tests.tesl" 198 (list (cons 'n n)) (lambda () *n))))])))))

(module+ test
  (require rackunit)
  (test-case "R52_P01 lambda+check legitimately works"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 205 (list) (lambda () (p01_lambda_with_checked_arg 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 206 (list) (lambda ()
                          (p01_lambda_with_checked_arg 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p01_lambda_with_checked_arg 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 207 (list) (lambda ()
                          (p01_lambda_with_checked_arg (- 0 9)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p01_lambda_with_checked_arg (- 0 9)"))
  )

  (test-case "R52_P02 triple chain runs when all checks pass"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 211 (list) (lambda () (p02_triple_chain 4)))) 4)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 212 (list) (lambda ()
                          (p02_triple_chain 3))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p02_triple_chain 3"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 213 (list) (lambda ()
                          (p02_triple_chain (- 0 2)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p02_triple_chain (- 0 2)"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 214 (list) (lambda ()
                          (p02_triple_chain 200))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p02_triple_chain 200"))
  )

  (test-case "R52_P03 triple predicate commutativity"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 218 (list) (lambda () (p03_triple_commutes 6)))) 6)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 219 (list) (lambda ()
                          (p03_triple_commutes 7))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p03_triple_commutes 7"))
  )

  (test-case "R52_P04 forget + recheck keeps the final value"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 223 (list) (lambda () (p04_forget_recheck 11)))) 11)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 224 (list) (lambda ()
                          (p04_forget_recheck 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p04_forget_recheck 0"))
  )

  (test-case "R52_D01 single decompose+reattach is identity"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 228 (list) (lambda () (d01_single_decompose 3)))) 3)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 229 (list) (lambda ()
                          (d01_single_decompose (- 0 1)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: d01_single_decompose (- 0 1)"))
  )

  (test-case "R52_D02 pair decomposition survives reattach"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 233 (list) (lambda () (d02_pair_decompose 4)))) 4)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 234 (list) (lambda ()
                          (d02_pair_decompose 200))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: d02_pair_decompose 200"))
  )

  (test-case "R52_D03 triple decomposition projects the even proof"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 238 (list) (lambda () (d03_triple_discard 8)))) 8)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 239 (list) (lambda ()
                          (d03_triple_discard 7))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: d03_triple_discard 7"))
  )

  (test-case "R52_M01 in-range check + use"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 243 (list) (lambda () (m01_multi_param 1 10 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 244 (list) (lambda ()
                          (m01_multi_param 1 10 99))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: m01_multi_param 1 10 99"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 245 (list) (lambda ()
                          (m01_multi_param 10 20 5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: m01_multi_param 10 20 5"))
  )

  (test-case "R52_M02 decompose + reattach of 3-arg fact"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 249 (list) (lambda () (m02_multi_decomp 0 100 42)))) 42)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-52-tests.tesl" 250 (list) (lambda ()
                          (m02_multi_decomp 0 100 1000))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: m02_multi_decomp 0 100 1000"))
  )

  (test-case "R52_F01 filterCheck keeps only positives"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 254 (list) (lambda () (f01_filter_check (list 1 2 3))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 255 (list) (lambda () (f01_filter_check (list (- 0 1) 2 (- 0 3)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 259 (list) (lambda () (f01_filter_check (list))))) 0)
  )

  (test-case "R52_F02 allCheck short-circuits on any failure"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 263 (list) (lambda () (f02_all_check (list 1 2 3))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 264 (list) (lambda () (f02_all_check (list 1 (- 0 2) 3))))) (- 0 1))
  )

  (test-case "R52_C01 guard + catch-all case"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 268 (list) (lambda () (c01_guard_with_catchall Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 269 (list) (lambda () (c01_guard_with_catchall (raw-value (Something 10)))))) 10)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 270 (list) (lambda () (c01_guard_with_catchall (raw-value (Something 0)))))) (- 0 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 271 (list) (lambda () (c01_guard_with_catchall (raw-value (Something (- 0 5))))))) (- 0 1))
  )

  (test-case "R52_C03 case scrutinee arithmetic"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 275 (list) (lambda () (c03_case_arith 2 3)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 276 (list) (lambda () (c03_case_arith 10 (- 0 10))))) 100)
  )

  (test-case "R52_C04 nested bare-nullary constructor pattern"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 280 (list) (lambda () (c04_nested_nullary Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 281 (list) (lambda () (c04_nested_nullary (raw-value (Something Nothing)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-52-tests.tesl" 282 (list) (lambda () (c04_nested_nullary (raw-value (Something (raw-value (Something 42)))))))) 42)
  )

)
