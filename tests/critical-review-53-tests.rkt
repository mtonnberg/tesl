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
  (only-in tesl/tesl/prelude Int Bool String List Fact forgetFact introAnd)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.filterCheck tesl_import_List_filterCheck] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop])
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.nonNegative tesl_import_Int_nonNegative] [Int.divide tesl_import_Int_divide])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide )

(define InBounds 'InBounds)
(define IsEven 'IsEven)
(define IsNonEmpty 'IsNonEmpty)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)

(define-checker
  (checkPositive [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review-53-tests.tesl" 50 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review-53-tests.tesl" 56 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (IsSmall n) #:value *n) (reject "too large" #:http-code 400)))))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review-53-tests.tesl" 62 (list (cons 'n *n)) (lambda () (if (equal? (remainder *n 2) 0) (accept (IsEven n) #:value *n) (reject "not even" #:http-code 400)))))

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (IsNonEmpty s)]
  (thsl-src! "tests/critical-review-53-tests.tesl" 68 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (IsNonEmpty s) #:value *s) (reject "empty string" #:http-code 400)))))

(define-checker
  (checkInBounds [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InBounds lo hi n)]
  (thsl-src! "tests/critical-review-53-tests.tesl" 74 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define/pow
  (needPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 81 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 82 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 83 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needNonEmpty [s : String ::: (IsNonEmpty s)])
  #:returns String
  (thsl-src! "tests/critical-review-53-tests.tesl" 84 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (needInBounds [lo : Integer] [hi : Integer] [n : Integer ::: (InBounds lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 85 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (needPosAndSmall [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 86 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needAll3 [n : Integer ::: ((IsPositive n) && ((IsSmall n) && (IsEven n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 87 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (a01_two_step_chain [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 92 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_0 (checkPositive raw)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkSmall a)]) (let ([b tesl_checked_1]) (raw-value (needPosAndSmall b)))))))))

(define/pow
  (a02_three_step_chain [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 97 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_2 (checkPositive raw)]) (let ([a tesl_checked_2]) (let/check ([tesl_checked_3 (checkSmall a)]) (let ([b tesl_checked_3]) (let/check ([tesl_checked_4 (checkEven b)]) (let ([c tesl_checked_4]) (raw-value (needAll3 c)))))))))))

(define/pow
  (a03_four_predicates [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 103 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_5 (checkPositive raw)]) (let ([a tesl_checked_5]) (let/check ([tesl_checked_6 (checkSmall a)]) (let ([b tesl_checked_6]) (let/check ([tesl_checked_7 (checkEven b)]) (let ([c tesl_checked_7]) (raw-value (needAll3 c)))))))))))

(define/pow
  (a04_commuted_conjunction [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 110 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_8 (checkPositive raw)]) (let ([a tesl_checked_8]) (let/check ([tesl_checked_9 (checkSmall a)]) (let ([b tesl_checked_9]) (let/check ([tesl_checked_10 (checkEven b)]) (let ([c tesl_checked_10]) (let ([needReorder (let () (define/pow (tesl-lambda-11 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(((IsEven n) && ((IsSmall n) && (IsPositive n)))))]) n)) tesl-lambda-11)]) (raw-value (needReorder c))))))))))))

(define/pow
  (c01_forget_and_recheck [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 120 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_12 (checkPositive raw)]) (let ([checked tesl_checked_12]) (let ([bare (forget-proof checked)]) (let/check ([tesl_checked_13 (checkPositive bare)]) (let ([rechecked tesl_checked_13]) (raw-value (needPos rechecked))))))))))

(define/pow
  (c02_two_forget_cycles [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 126 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_14 (checkPositive raw)]) (let ([a tesl_checked_14]) (let ([b (forget-proof a)]) (let/check ([tesl_checked_15 (checkPositive b)]) (let ([c tesl_checked_15]) (let/check ([tesl_checked_16 (checkSmall c)]) (let ([d tesl_checked_16]) (raw-value (needPosAndSmall d))))))))))))

(define/pow
  (d01_single_decompose [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 135 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_17 (checkPositive raw)]) (let ([p tesl_checked_17]) (let ([tesl_proof_binding_18 p]) (let ([v (forget-proof tesl_proof_binding_18)] [proof (detach-all-proof tesl_proof_binding_18)]) (let ([reat (attach-proof v proof)]) (raw-value (needPos reat))))))))))

(define/pow
  (d02_pair_decompose [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 141 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_19 (checkPositive raw)]) (let ([a tesl_checked_19]) (let/check ([tesl_checked_20 (checkSmall a)]) (let ([b tesl_checked_20]) (let ([tesl_proof_binding_21 b]) (let ([v (forget-proof tesl_proof_binding_21)] [p1 (detach-all-proof tesl_proof_binding_21)]) (let ([tesl_proof_binding_22 b]) (let ([_ (forget-proof tesl_proof_binding_22)] [p2 (detach-all-proof tesl_proof_binding_22)]) (let ([reat (attach-proof v (list p1 p2))]) (raw-value (needPosAndSmall reat))))))))))))))

(define/pow
  (d03_triple_decompose_with_discard [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 148 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_23 (checkPositive raw)]) (let ([a tesl_checked_23]) (let/check ([tesl_checked_24 (checkSmall a)]) (let ([b tesl_checked_24]) (let/check ([tesl_checked_25 (checkEven b)]) (let ([c tesl_checked_25]) (let ([tesl_proof_binding_26 c]) (let ([v (forget-proof tesl_proof_binding_26)] [pe (detach-all-proof tesl_proof_binding_26)]) (raw-value (needEven (attach-proof v pe))))))))))))))

(define/pow
  (d04_and_composition [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 155 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_27 (checkPositive raw)]) (let ([a tesl_checked_27]) (let/check ([tesl_checked_28 (checkSmall a)]) (let ([b tesl_checked_28]) (let ([tesl_proof_binding_29 b]) (let ([v (forget-proof tesl_proof_binding_29)] [p1 (detach-all-proof tesl_proof_binding_29)]) (let ([tesl_proof_binding_30 b]) (let ([_ (forget-proof tesl_proof_binding_30)] [p2 (detach-all-proof tesl_proof_binding_30)]) (let ([combined (intro-and p1 p2)]) (let ([reat (attach-proof v combined)]) (raw-value (needPosAndSmall reat)))))))))))))))

(define/pow
  (m01_basic_multi_param [lo : Integer] [hi : Integer] [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 165 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_31 (checkInBounds lo hi raw)]) (let ([validated tesl_checked_31]) (raw-value (needInBounds lo hi validated)))))))

(define/pow
  (m02_multi_param_decompose [lo : Integer] [hi : Integer] [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 169 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_32 (checkInBounds lo hi raw)]) (let ([ranged tesl_checked_32]) (let ([tesl_proof_binding_33 ranged]) (let ([v (forget-proof tesl_proof_binding_33)] [p (detach-all-proof tesl_proof_binding_33)]) (let ([reat (attach-proof v p)]) (raw-value (needInBounds lo hi reat))))))))))

(define/pow
  (s01_safe_divide [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 177 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl_checked_34 (tesl_import_Int_nonZero b)]) (let ([divisor tesl_checked_34]) (raw-value (tesl_import_Int_divide *a divisor)))))))

(define/pow
  (s02_safe_take [xs : (List Integer)] [n : Integer])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-53-tests.tesl" 181 (list (cons 'xs *xs) (cons 'n *n)) (lambda () (let/check ([tesl_checked_35 (tesl_import_Int_nonNegative n)]) (let ([count tesl_checked_35]) (raw-value (tesl_import_List_take count *xs)))))))

(define/pow
  (s03_safe_drop [xs : (List Integer)] [n : Integer])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-53-tests.tesl" 185 (list (cons 'xs *xs) (cons 'n *n)) (lambda () (let/check ([tesl_checked_36 (tesl_import_Int_nonNegative n)]) (let ([count tesl_checked_36]) (raw-value (tesl_import_List_drop count *xs)))))))

(define/pow
  (s04_nonneg_chain [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 189 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_37 (checkPositive n)]) (let ([pos tesl_checked_37]) (let/check ([tesl_checked_38 (tesl_import_Int_nonNegative pos)]) (let ([nn tesl_checked_38]) (raw-value nn))))))))

(define/pow
  (g01_guard_with_catchall [m : (Maybe Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-53-tests.tesl" 197 (list (cons 'm *m)) (lambda () (let ([tesl_case_39 *m]) (cond [(and (adt-value? *tesl_case_39) (eq? (adt-value-variant *tesl_case_39) 'Nothing)) (thsl-src! "tests/critical-review-53-tests.tesl" 198 (list) (lambda () (raw-value 0)))] [(and (and (adt-value? *tesl_case_39) (eq? (adt-value-variant *tesl_case_39) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_39) 'value)]) (> *n 0))) (let ([n (hash-ref (adt-value-fields *tesl_case_39) 'value)]) (thsl-src! "tests/critical-review-53-tests.tesl" 199 (list (cons 'n n)) (lambda () *n)))] [(and (adt-value? *tesl_case_39) (eq? (adt-value-variant *tesl_case_39) 'Something)) (thsl-src! "tests/critical-review-53-tests.tesl" 200 (list) (lambda () (raw-value 0)))])))))

(define/pow
  (g02_three_arm_adt [s : String])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-53-tests.tesl" 203 (list (cons 's *s)) (lambda () (let ([tesl_case_40 *s]) (cond [(equal? *tesl_case_40 "a") (thsl-src! "tests/critical-review-53-tests.tesl" 204 (list) (lambda () (raw-value 1)))] [(equal? *tesl_case_40 "b") (thsl-src! "tests/critical-review-53-tests.tesl" 205 (list) (lambda () (raw-value 2)))] [#t (thsl-src! "tests/critical-review-53-tests.tesl" 206 (list) (lambda () (raw-value 0)))])))))

(define/pow
  (g03_bool_exhaustive)
  #:returns String
  (thsl-src-control! "tests/critical-review-53-tests.tesl" 209 (list) (lambda () (let ([tesl_case_41 (raw-value #t)]) (cond [(eq? *tesl_case_41 #t) (thsl-src! "tests/critical-review-53-tests.tesl" 210 (list) (lambda () (raw-value "yes")))] [(eq? *tesl_case_41 #f) (thsl-src! "tests/critical-review-53-tests.tesl" 211 (list) (lambda () (raw-value "no")))])))))

(define/pow
  (f01_filtercheck_with_real_check [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-53-tests.tesl" 216 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive *xs))))

(define/pow
  (f02_filtercheck_chain [raw : (List Integer)])
  #:returns Integer
  (let ([positives (thsl-src! "tests/critical-review-53-tests.tesl" 219 (list (cons 'raw *raw)) (lambda () (tesl_import_List_filterCheck checkPositive *raw)))]) (thsl-src! "tests/critical-review-53-tests.tesl" 220 (list (cons 'positives *positives) (cons 'raw *raw)) (lambda () (raw-value (tesl_import_List_length (raw-value positives)))))))

(define/pow
  (f03_filtercheck_then_consume [xs : (List Integer)])
  #:returns Integer
  (let ([pxs (thsl-src! "tests/critical-review-53-tests.tesl" 223 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive *xs)))]) (let ([needPosAll (thsl-src! "tests/critical-review-53-tests.tesl" 224 (list (cons 'pxs *pxs) (cons 'xs *xs)) (lambda () (let () (define/pow (tesl-lambda-42 [ns : (List Integer)]) #:returns Integer (raw-value (tesl_import_List_length *ns))) tesl-lambda-42)))]) (thsl-src! "tests/critical-review-53-tests.tesl" 225 (list (cons 'needPosAll *needPosAll) (cons 'pxs *pxs) (cons 'xs *xs)) (lambda () (raw-value (needPosAll pxs)))))))

(define-trusted
  (provePositive [n : Integer])
  #:returns (Fact (IsPositive n))
  (thsl-src! "tests/critical-review-53-tests.tesl" 230 (list (cons 'n *n)) (lambda () (trusted-proof (IsPositive n)))))

(define/pow
  (e01_establish_and_use [n : Integer])
  #:returns Integer
  (let ([proof (thsl-src! "tests/critical-review-53-tests.tesl" 233 (list (cons 'n *n)) (lambda () (provePositive n)))]) (let ([valued (thsl-src! "tests/critical-review-53-tests.tesl" 234 (list (cons 'proof *proof) (cons 'n *n)) (lambda () (attach-proof n proof)))]) (thsl-src! "tests/critical-review-53-tests.tesl" 235 (list (cons 'valued *valued) (cons 'proof *proof) (cons 'n *n)) (lambda () (raw-value (needPos valued)))))))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define/pow
  (t01_newtype_accepted [uid : UserId])
  #:returns String
  (thsl-src! "tests/critical-review-53-tests.tesl" 242 (list (cons 'uid *uid)) (lambda () (raw-value uid.value))))

(define/pow
  (t02_newtype_constructor [raw : String])
  #:returns UserId
  (thsl-src! "tests/critical-review-53-tests.tesl" 244 (list (cons 'raw *raw)) (lambda () (raw-value (UserId *raw)))))

(define/pow
  (n01_nested_maybe_case [m : (Maybe (Maybe Integer))])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-53-tests.tesl" 249 (list (cons 'm *m)) (lambda () (let ([tesl_case_43 *m]) (cond [(and (adt-value? *tesl_case_43) (eq? (adt-value-variant *tesl_case_43) 'Nothing)) (thsl-src! "tests/critical-review-53-tests.tesl" 250 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_43) (eq? (adt-value-variant *tesl_case_43) 'Something)) (let ([inner (hash-ref (adt-value-fields *tesl_case_43) 'value)]) (thsl-src! "tests/critical-review-53-tests.tesl" 252 (list (cons 'inner inner)) (lambda () (let ([tesl_case_44 (raw-value inner)]) (cond [(and (adt-value? *tesl_case_44) (eq? (adt-value-variant *tesl_case_44) 'Nothing)) (thsl-src! "tests/critical-review-53-tests.tesl" 253 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl_case_44) (eq? (adt-value-variant *tesl_case_44) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_44) 'value)]) (thsl-src! "tests/critical-review-53-tests.tesl" 254 (list (cons 'n n)) (lambda () *n)))])))))])))))

(define/pow
  (n02_three_level_case [m : (Maybe Integer)])
  #:returns String
  (thsl-src-control! "tests/critical-review-53-tests.tesl" 257 (list (cons 'm *m)) (lambda () (let ([tesl_case_45 *m]) (cond [(and (adt-value? *tesl_case_45) (eq? (adt-value-variant *tesl_case_45) 'Nothing)) (thsl-src! "tests/critical-review-53-tests.tesl" 258 (list) (lambda () (raw-value "nothing")))] [(and (adt-value? *tesl_case_45) (eq? (adt-value-variant *tesl_case_45) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_45) 'value)]) (thsl-src! "tests/critical-review-53-tests.tesl" 260 (list (cons 'n n)) (lambda () (if (> *n 0) (raw-value "positive") (if (< *n 0) (raw-value "negative") (raw-value "zero"))))))])))))

(define-checker
  (ma01_maybe_positive [n : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "tests/critical-review-53-tests.tesl" 348 (list (cons 'n *n)) (lambda () (if (> *n 0) (raw-value (Something n)) Nothing))))

(define/pow
  (ma02_use_maybe_positive [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 354 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_46 (ma01_maybe_positive raw)]) (let ([m tesl_checked_46]) (let ([tesl_case_47 (raw-value m)]) (cond [(and (adt-value? *tesl_case_47) (eq? (adt-value-variant *tesl_case_47) 'Nothing)) (thsl-src! "tests/critical-review-53-tests.tesl" 356 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_47) (eq? (adt-value-variant *tesl_case_47) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_47) 'value)]) (thsl-src! "tests/critical-review-53-tests.tesl" 357 (list (cons 'v v)) (lambda () (raw-value (+ *v 1)))))])))))))

(define/pow
  (ma03_nothing_branch [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-53-tests.tesl" 360 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_48 (ma01_maybe_positive raw)]) (let ([m tesl_checked_48]) (let ([tesl_case_49 (raw-value m)]) (cond [(and (adt-value? *tesl_case_49) (eq? (adt-value-variant *tesl_case_49) 'Nothing)) (thsl-src! "tests/critical-review-53-tests.tesl" 362 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl_case_49) (eq? (adt-value-variant *tesl_case_49) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_49) 'value)]) (thsl-src! "tests/critical-review-53-tests.tesl" 363 (list (cons 'v v)) (lambda () *v)))])))))))

(module+ test
  (require rackunit)
  (test-case "R53_A: multi-step proof chains compile and run"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 271 (list) (lambda () (a01_two_step_chain 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 272 (list) (lambda () (a02_three_step_chain 6)))) 6)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-53-tests.tesl" 273 (list) (lambda ()
                          (a01_two_step_chain -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: a01_two_step_chain -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-53-tests.tesl" 274 (list) (lambda ()
                          (a02_three_step_chain 3))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: a02_three_step_chain 3"))
  )

  (test-case "R53_C: forgetFact and recheck cycles"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 278 (list) (lambda () (c01_forget_and_recheck 7)))) 7)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 279 (list) (lambda () (c02_two_forget_cycles 4)))) 4)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-53-tests.tesl" 280 (list) (lambda ()
                          (c01_forget_and_recheck 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: c01_forget_and_recheck 0"))
  )

  (test-case "R53_D: decompose and reattach"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 284 (list) (lambda () (d01_single_decompose 3)))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 285 (list) (lambda () (d02_pair_decompose 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 286 (list) (lambda () (d03_triple_decompose_with_discard 4)))) 4)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 287 (list) (lambda () (d04_and_composition 7)))) 7)
  )

  (test-case "R53_M: multi-param fact check and consumer"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 291 (list) (lambda () (m01_basic_multi_param 1 10 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 292 (list) (lambda () (m02_multi_param_decompose 0 100 42)))) 42)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-53-tests.tesl" 293 (list) (lambda ()
                          (m01_basic_multi_param 1 10 11))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: m01_basic_multi_param 1 10 11"))
  )

  (test-case "R53_S: proof-total standard library functions"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 297 (list) (lambda () (s01_safe_divide 10 2)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 298 (list) (lambda () (s01_safe_divide 7 3)))) 2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 299 (list) (lambda () (s02_safe_take (list 1 2 3 4 5) 3)))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 300 (list) (lambda () (s03_safe_drop (list 1 2 3 4 5) 2)))) (list 3 4 5))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-53-tests.tesl" 301 (list) (lambda ()
                          (s01_safe_divide 5 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: s01_safe_divide 5 0"))
  )

  (test-case "R53_G: guard + case exhaustiveness positive"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 305 (list) (lambda () (g01_guard_with_catchall Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 306 (list) (lambda () (g01_guard_with_catchall (raw-value (Something 5)))))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 307 (list) (lambda () (g01_guard_with_catchall (raw-value (Something -3)))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 308 (list) (lambda () (g02_three_arm_adt "a")))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 309 (list) (lambda () (g02_three_arm_adt "b")))) 2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 310 (list) (lambda () (g02_three_arm_adt "x")))) 0)
  )

  (test-case "R53_F: filterCheck with real check function"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 314 (list) (lambda () (f02_filtercheck_chain (list 1 2 -3 4 -5))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 315 (list) (lambda () (f03_filtercheck_then_consume (list -1 -2 -3))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 316 (list) (lambda () (f03_filtercheck_then_consume (list 1 2 3))))) 3)
  )

  (test-case "R53_E: establish function positive"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 320 (list) (lambda () (e01_establish_and_use 42)))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 321 (list) (lambda () (e01_establish_and_use -5)))) -5)
  )

  (test-case "R53_T: newtype constructor and value accessor"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 325 (list) (lambda () (t02_newtype_constructor "uid_123")))) (raw-value (UserId "uid_123")))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 326 (list) (lambda () (t01_newtype_accepted (UserId "hello"))))) "hello")
  )

  (test-case "R53_N: nested case expressions"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 330 (list) (lambda () (n01_nested_maybe_case Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 331 (list) (lambda () (n01_nested_maybe_case (raw-value (Something Nothing)))))) -1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 332 (list) (lambda () (n01_nested_maybe_case (raw-value (Something (raw-value (Something 42)))))))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 333 (list) (lambda () (n02_three_level_case Nothing)))) "nothing")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 334 (list) (lambda () (n02_three_level_case (raw-value (Something 5)))))) "positive")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 335 (list) (lambda () (n02_three_level_case (raw-value (Something -2)))))) "negative")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 336 (list) (lambda () (n02_three_level_case (raw-value (Something 0)))))) "zero")
  )

  (test-case "R53_compound: four-fact conjunction"
  ; property: pos+small+even chain
  (for ([tesl-prop-i (in-range 20)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) 0) (< (raw-value n) 1000) (equal? (remainder (raw-value n) 2) 0)) (check-true (equal? (raw-value (a03_four_predicates n)) (raw-value n)) "pos+small+even chain"))
    ))
  )

  (test-case "R53_MA: Maybe (T ::: P) basic positive cases"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 366 (list) (lambda () (ma02_use_maybe_positive 5)))) 6)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 367 (list) (lambda () (ma02_use_maybe_positive -1)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 368 (list) (lambda () (ma03_nothing_branch 10)))) 10)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-53-tests.tesl" 369 (list) (lambda () (ma03_nothing_branch -3)))) -1)
  )

)
