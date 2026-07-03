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
  (only-in tesl/tesl/prelude Int Bool String List Fact forgetFact introAnd andLeft andRight)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.filterCheck tesl_import_List_filterCheck])
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide])
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.trim tesl_import_String_trim] [String.startsWith tesl_import_String_startsWith] IsTrimmed)
)


(provide )

(define HasPrefix 'HasPrefix)
(define IsEven 'IsEven)
(define IsNonEmpty 'IsNonEmpty)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define ValidRange 'ValidRange)

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review-54-tests.tesl" 43 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review-54-tests.tesl" 49 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (IsSmall n) #:value *n) (reject "too large" #:http-code 400)))))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review-54-tests.tesl" 55 (list (cons 'n *n)) (lambda () (if (tesl-equal? (remainder *n 2) 0) (accept (IsEven n) #:value *n) (reject "not even" #:http-code 400)))))

(define-checker
  (checkRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (ValidRange lo hi n)]
  (thsl-src! "tests/critical-review-54-tests.tesl" 61 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (ValidRange lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define-checker
  (checkHasPrefix [prefix : String] [s : String])
  #:returns [s : String ::: (HasPrefix prefix s)]
  (thsl-src! "tests/critical-review-54-tests.tesl" 67 (list (cons 'prefix *prefix) (cons 's *s)) (lambda () (if (tesl_import_String_startsWith *s *prefix) (accept (HasPrefix prefix s) #:value *s) (reject "missing prefix" #:http-code 400)))))

(define/pow
  (needPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 72 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 73 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needBoth [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 74 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needAll3 [n : Integer ::: ((IsPositive n) && ((IsSmall n) && (IsEven n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 75 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needRange [lo : Integer] [hi : Integer] [n : Integer ::: (ValidRange lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 76 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (needHasPrefix [prefix : String] [s : String ::: (HasPrefix prefix s)])
  #:returns String
  (thsl-src! "tests/critical-review-54-tests.tesl" 77 (list (cons 'prefix *prefix) (cons 's *s)) (lambda () *s)))

(define/pow
  (a01_three_step_chain [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 82 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkPos raw)]) (let ([a tesl-checked-0]) (let/check ([tesl-checked-1 (checkSmall a)]) (let ([b tesl-checked-1]) (let/check ([tesl-checked-2 (checkEven b)]) (let ([c tesl-checked-2]) (raw-value (needAll3 c)))))))))))

(define/pow
  (a02_cross_step_decompose_selective [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 88 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-3 (checkPos raw)]) (let ([a tesl-checked-3]) (let/check ([tesl-checked-4 (checkSmall a)]) (let ([b tesl-checked-4]) (let/check ([tesl-checked-5 (checkEven b)]) (let ([c tesl-checked-5]) (let ([tesl-proof-binding-6 c]) (let ([v (forget-proof tesl-proof-binding-6)] [pp (detach-all-proof tesl-proof-binding-6)]) (let ([tesl-proof-binding-7 c]) (let ([_ (forget-proof tesl-proof-binding-7)] [_ps (detach-all-proof tesl-proof-binding-7)]) (let ([tesl-proof-binding-8 c]) (let ([_ (forget-proof tesl-proof-binding-8)] [pe (detach-all-proof tesl-proof-binding-8)]) (let ([reat (attach-proof v (list pp pe))]) (raw-value (needPos reat))))))))))))))))))

(define/pow
  (a03_multi_param_round_trip [lo : Integer] [hi : Integer] [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 96 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-9 (checkRange lo hi raw)]) (let ([validated tesl-checked-9]) (raw-value (needRange lo hi validated)))))))

(define/pow
  (a04_string_multi_param [prefix : String] [raw : String])
  #:returns String
  (thsl-src! "tests/critical-review-54-tests.tesl" 100 (list (cons 'prefix *prefix) (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-10 (checkHasPrefix prefix raw)]) (let ([validated tesl-checked-10]) (raw-value (needHasPrefix prefix validated)))))))

(define-trusted
  (provePos [n : Integer])
  #:returns (Fact (IsPositive n))
  (thsl-src! "tests/critical-review-54-tests.tesl" 123 (list (cons 'n *n)) (lambda () (trusted-proof (IsPositive n)))))

(define-trusted
  (tryValidRangeOneTo100 [n : Integer])
  #:returns (Maybe (Fact (IsPositive n)))
  (thsl-src! "tests/critical-review-54-tests.tesl" 126 (list (cons 'n *n)) (lambda () (if (and (<= 1 *n) (<= *n 100)) (Something (trusted-proof (IsPositive n))) Nothing))))

(define/pow
  (e01_establish_direct_use [raw : Integer])
  #:returns Integer
  (let ([pf (thsl-src! "tests/critical-review-54-tests.tesl" 132 (list (cons 'raw *raw)) (lambda () (provePos raw)))]) (thsl-src! "tests/critical-review-54-tests.tesl" 133 (list (cons 'pf *pf) (cons 'raw *raw)) (lambda () (raw-value (needPos (attach-proof raw pf)))))))

(define/pow
  (e02_establish_maybe_case [raw : Integer])
  #:returns Integer
  (let ([mProof (thsl-src! "tests/critical-review-54-tests.tesl" 136 (list (cons 'raw *raw)) (lambda () (tryValidRangeOneTo100 raw)))]) (thsl-src-control! "tests/critical-review-54-tests.tesl" 137 (list (cons 'mProof *mProof) (cons 'raw *raw)) (lambda () (let ([tesl-case-11 (raw-value mProof)]) (cond [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Nothing)) (thsl-src! "tests/critical-review-54-tests.tesl" 138 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Something)) (let ([pf (hash-ref (adt-value-fields *tesl-case-11) 'value)]) (thsl-src! "tests/critical-review-54-tests.tesl" 139 (list (cons 'pf pf)) (lambda () (raw-value (needPos (attach-proof raw pf))))))]))))))

(define/pow
  (f01_forget_recheck_same_value [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 153 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-12 (checkPos raw)]) (let ([pos tesl-checked-12]) (let ([bare (forget-proof pos)]) (let/check ([tesl-checked-13 (checkPos bare)]) (let ([pos2 tesl-checked-13]) (raw-value (needPos pos2))))))))))

(define/pow
  (f02_forget_establish_reattach [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 159 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-14 (checkPos raw)]) (let ([pos tesl-checked-14]) (let ([bare (forget-proof pos)]) (let ([pf (provePos raw)]) (raw-value (needPos (attach-proof bare pf))))))))))

(define/pow
  (d01_triple_decompose_selective [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 174 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-15 (checkPos raw)]) (let ([a tesl-checked-15]) (let/check ([tesl-checked-16 (checkSmall a)]) (let ([b tesl-checked-16]) (let/check ([tesl-checked-17 (checkEven b)]) (let ([c tesl-checked-17]) (let ([tesl-proof-binding-18 c]) (let ([v (forget-proof tesl-proof-binding-18)] [pp (detach-all-proof tesl-proof-binding-18)]) (let ([tesl-proof-binding-19 c]) (let ([_ (forget-proof tesl-proof-binding-19)] [_ps (detach-all-proof tesl-proof-binding-19)]) (let ([tesl-proof-binding-20 c]) (let ([_ (forget-proof tesl-proof-binding-20)] [_pe (detach-all-proof tesl-proof-binding-20)]) (raw-value (needPos (attach-proof v pp))))))))))))))))))

(define/pow
  (d02_introand_same_subject [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 181 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-21 (checkPos raw)]) (let ([pos tesl-checked-21]) (let/check ([tesl-checked-22 (checkSmall pos)]) (let ([sm tesl-checked-22]) (let ([tesl-proof-binding-23 pos]) (let ([v (forget-proof tesl-proof-binding-23)] [pp (detach-all-proof tesl-proof-binding-23)]) (let ([tesl-proof-binding-24 sm]) (let ([_v2 (forget-proof tesl-proof-binding-24)] [ps (detach-all-proof tesl-proof-binding-24)]) (let ([combined (intro-and pp ps)]) (let ([reat (attach-proof v combined)]) (raw-value (needBoth reat)))))))))))))))

(define/pow
  (d03_andleft_andright_conservative [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 190 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-25 (checkPos raw)]) (let ([a tesl-checked-25]) (let/check ([tesl-checked-26 (checkSmall a)]) (let ([b tesl-checked-26]) (let ([tesl-proof-binding-27 b]) (let ([v (forget-proof tesl-proof-binding-27)] [pp (detach-all-proof tesl-proof-binding-27)]) (let ([tesl-proof-binding-28 b]) (let ([_ (forget-proof tesl-proof-binding-28)] [ps (detach-all-proof tesl-proof-binding-28)]) (let ([leftPf (and-left pp)]) (let ([rightPf (and-right ps)]) (let ([both (intro-and leftPf rightPf)]) (let ([reat (attach-proof v both)]) (raw-value (needBoth reat)))))))))))))))))

(define-adt TrafficLight
  [Red]
  [Yellow]
  [Green]
)

(define/pow
  (g01_partial_guard_with_catchall [light : TrafficLight] [n : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-54-tests.tesl" 219 (list (cons 'light *light) (cons 'n *n)) (lambda () (let ([tesl-case-29 *light]) (cond [(and (and (adt-value? *tesl-case-29) (eq? (adt-value-variant *tesl-case-29) 'Red)) (> *n 0)) (thsl-src! "tests/critical-review-54-tests.tesl" 220 (list) (lambda () (raw-value 1)))] [(and (adt-value? *tesl-case-29) (eq? (adt-value-variant *tesl-case-29) 'Red)) (thsl-src! "tests/critical-review-54-tests.tesl" 221 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-29) (eq? (adt-value-variant *tesl-case-29) 'Yellow)) (thsl-src! "tests/critical-review-54-tests.tesl" 222 (list) (lambda () (raw-value 2)))] [(and (adt-value? *tesl-case-29) (eq? (adt-value-variant *tesl-case-29) 'Green)) (thsl-src! "tests/critical-review-54-tests.tesl" 223 (list) (lambda () (raw-value 3)))])))))

(define/pow
  (g02_all_unguarded_exhaustive [light : TrafficLight])
  #:returns String
  (thsl-src-control! "tests/critical-review-54-tests.tesl" 226 (list (cons 'light *light)) (lambda () (let ([tesl-case-30 *light]) (cond [(and (adt-value? *tesl-case-30) (eq? (adt-value-variant *tesl-case-30) 'Red)) (thsl-src! "tests/critical-review-54-tests.tesl" 227 (list) (lambda () (raw-value "stop")))] [(and (adt-value? *tesl-case-30) (eq? (adt-value-variant *tesl-case-30) 'Yellow)) (thsl-src! "tests/critical-review-54-tests.tesl" 228 (list) (lambda () (raw-value "slow")))] [(and (adt-value? *tesl-case-30) (eq? (adt-value-variant *tesl-case-30) 'Green)) (thsl-src! "tests/critical-review-54-tests.tesl" 229 (list) (lambda () (raw-value "go")))])))))

(define/pow
  (g03_mixed_guards_with_default [m : (Maybe Integer)] [threshold : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-54-tests.tesl" 232 (list (cons 'm *m) (cons 'threshold *threshold)) (lambda () (let ([tesl-case-31 *m]) (cond [(and (adt-value? *tesl-case-31) (eq? (adt-value-variant *tesl-case-31) 'Nothing)) (thsl-src! "tests/critical-review-54-tests.tesl" 233 (list) (lambda () (raw-value 0)))] [(and (and (adt-value? *tesl-case-31) (eq? (adt-value-variant *tesl-case-31) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl-case-31) 'value)]) (> *n *threshold))) (let ([n (hash-ref (adt-value-fields *tesl-case-31) 'value)]) (thsl-src! "tests/critical-review-54-tests.tesl" 234 (list (cons 'n n)) (lambda () *n)))] [(and (adt-value? *tesl-case-31) (eq? (adt-value-variant *tesl-case-31) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl-case-31) 'value)]) (thsl-src! "tests/critical-review-54-tests.tesl" 235 (list (cons 'n n)) (lambda () *threshold)))])))))

(define/pow
  (l01_lambda_with_proof_param [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 255 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-32 (checkPos raw)]) (let ([pos tesl-checked-32]) (let ([f (let () (define/pow (tesl-lambda-33 [x : Integer]) #:returns Integer (let ([x (tesl-establish-param-proof x *x `(IsPositive ,x))]) (needPos x))) tesl-lambda-33)]) (raw-value (f pos))))))))

(define/pow
  (l02_lambda_captures_proof [raw : Integer])
  #:returns (-> Integer Integer)
  (thsl-src! "tests/critical-review-54-tests.tesl" 260 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-34 (checkPos raw)]) (let ([pos tesl-checked-34]) (let () (define/pow (tesl-lambda-35 [y : Integer]) #:returns Integer (+ (raw-value pos) *y)) tesl-lambda-35))))))

(define/pow
  (l03_lambda_partial_apply [f : (-> Integer Integer)] [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 264 (list (cons 'f *f) (cons 'n *n)) (lambda () (raw-value (f n)))))

(define-record InnerRec
  [content : String ::: (IsNonEmpty content)]
)

(define-record OuterRec
  [inner : InnerRec]
)

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (IsNonEmpty s)]
  (thsl-src! "tests/critical-review-54-tests.tesl" 282 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (IsNonEmpty s) #:value *s) (reject "empty" #:http-code 400)))))

(define/pow
  (needNonEmpty [s : String ::: (IsNonEmpty s)])
  #:returns String
  (thsl-src! "tests/critical-review-54-tests.tesl" 287 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (n01_nested_record_field_proof [o : OuterRec])
  #:returns String
  (thsl-src! "tests/critical-review-54-tests.tesl" 290 (list (cons 'o *o)) (lambda () (raw-value (needNonEmpty (tesl-dot/runtime (tesl-dot/runtime o 'inner) 'content))))))

(define/pow
  (n02_three_level_case [m : (Maybe (Maybe Integer))])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-54-tests.tesl" 293 (list (cons 'm *m)) (lambda () (let ([tesl-case-36 *m]) (cond [(and (adt-value? *tesl-case-36) (eq? (adt-value-variant *tesl-case-36) 'Nothing)) (thsl-src! "tests/critical-review-54-tests.tesl" 294 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-36) (eq? (adt-value-variant *tesl-case-36) 'Something)) (let ([inner (hash-ref (adt-value-fields *tesl-case-36) 'value)]) (thsl-src! "tests/critical-review-54-tests.tesl" 296 (list (cons 'inner inner)) (lambda () (let ([tesl-case-37 (raw-value inner)]) (cond [(and (adt-value? *tesl-case-37) (eq? (adt-value-variant *tesl-case-37) 'Nothing)) (thsl-src! "tests/critical-review-54-tests.tesl" 297 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl-case-37) (eq? (adt-value-variant *tesl-case-37) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl-case-37) 'value)]) (thsl-src! "tests/critical-review-54-tests.tesl" 298 (list (cons 'n n)) (lambda () *n)))])))))])))))

(define/pow
  (p01_safe_divide [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-54-tests.tesl" 318 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-38 (tesl_import_Int_nonZero b)]) (let ([d tesl-checked-38]) (raw-value (tesl_import_Int_divide *a d)))))))

(define/pow
  (p02_stdlib_isTrimmed_propagation [raw : String])
  #:returns (? String _entity ::: (IsTrimmed _entity))
  (thsl-src! "tests/critical-review-54-tests.tesl" 322 (list (cons 'raw *raw)) (lambda () (tesl_import_String_trim *raw))))

(define/pow
  (p03_filter_check_creates_forall [xs : (List Integer)])
  #:returns Integer
  (let ([positives (thsl-src! "tests/critical-review-54-tests.tesl" 325 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs)))]) (let ([consumer (thsl-src! "tests/critical-review-54-tests.tesl" 326 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (let () (define/pow (tesl-lambda-39 [ns : (List Integer)]) #:returns Integer (raw-value (tesl_import_List_length *ns))) tesl-lambda-39)))]) (thsl-src! "tests/critical-review-54-tests.tesl" 327 (list (cons 'consumer *consumer) (cons 'positives *positives) (cons 'xs *xs)) (lambda () (raw-value (consumer positives)))))))

(define/pow
  (c01_proof_flows_through_some_arm [m : (Maybe Integer)])
  #:returns Integer
  (let ([result (thsl-src! "tests/critical-review-54-tests.tesl" 341 (list (cons 'm *m)) (lambda () (let ([tesl-case-40 *m]) (cond [(and (adt-value? *tesl-case-40) (eq? (adt-value-variant *tesl-case-40) 'Nothing)) (thsl-src! "tests/critical-review-54-tests.tesl" 342 (list) (lambda () 0))] [(and (adt-value? *tesl-case-40) (eq? (adt-value-variant *tesl-case-40) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl-case-40) 'value)]) (thsl-src! "tests/critical-review-54-tests.tesl" 343 (list (cons 'n n)) (lambda () *n)))]))))]) (thsl-src! "tests/critical-review-54-tests.tesl" 344 (list (cons 'result *result) (cons 'm *m)) (lambda () (raw-value result)))))

(define/pow
  (c02_proof_after_three_way_case [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-54-tests.tesl" 347 (list (cons 'n *n)) (lambda () (if (> *n 0) (raw-value "positive") (if (< *n 0) (raw-value "negative") (raw-value "zero"))))))

(define/pow
  (c03_literal_pattern_with_catchall [code : Integer])
  #:returns String
  (thsl-src-control! "tests/critical-review-54-tests.tesl" 356 (list (cons 'code *code)) (lambda () (let ([tesl-case-41 *code]) (cond [(= *tesl-case-41 200) (thsl-src! "tests/critical-review-54-tests.tesl" 357 (list) (lambda () (raw-value "ok")))] [(= *tesl-case-41 404) (thsl-src! "tests/critical-review-54-tests.tesl" 358 (list) (lambda () (raw-value "not found")))] [(= *tesl-case-41 500) (thsl-src! "tests/critical-review-54-tests.tesl" 359 (list) (lambda () (raw-value "server error")))] [#t (thsl-src! "tests/critical-review-54-tests.tesl" 360 (list) (lambda () (raw-value "other")))])))))

(module+ test
  (require rackunit)
  (test-case "R54_A: proof chain compilation and runtime correctness"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 104 (list) (lambda () (a01_three_step_chain 6)))) 6)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 105 (list) (lambda () (a01_three_step_chain 4)))) 4)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 106 (list) (lambda ()
                          (a01_three_step_chain -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: a01_three_step_chain -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 107 (list) (lambda ()
                          (a01_three_step_chain 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: a01_three_step_chain 1001"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 108 (list) (lambda ()
                          (a01_three_step_chain 5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: a01_three_step_chain 5"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 110 (list) (lambda () (a02_cross_step_decompose_selective 6)))) 6)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 111 (list) (lambda ()
                          (a02_cross_step_decompose_selective -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: a02_cross_step_decompose_selective -1"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 113 (list) (lambda () (a03_multi_param_round_trip 1 10 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 114 (list) (lambda ()
                          (a03_multi_param_round_trip 1 10 11))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: a03_multi_param_round_trip 1 10 11"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 116 (list) (lambda () (a04_string_multi_param "hello" "hello world")))) "hello world")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 117 (list) (lambda ()
                          (a04_string_multi_param "hello" "goodbye"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: a04_string_multi_param \"hello\" \"goodbye\""))
  )

  (test-case "R54_E: establish and Maybe proof"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 142 (list) (lambda () (e01_establish_direct_use 42)))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 143 (list) (lambda () (e01_establish_direct_use -5)))) -5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 145 (list) (lambda () (e02_establish_maybe_case 50)))) 50)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 146 (list) (lambda () (e02_establish_maybe_case 0)))) -1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 147 (list) (lambda () (e02_establish_maybe_case 101)))) -1)
  )

  (test-case "R54_F: forgetFact preservation"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 165 (list) (lambda () (f01_forget_recheck_same_value 7)))) 7)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 166 (list) (lambda ()
                          (f01_forget_recheck_same_value -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: f01_forget_recheck_same_value -1"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 168 (list) (lambda () (f02_forget_establish_reattach 3)))) 3)
  )

  (test-case "R54_D: detach/attach proof flows"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 200 (list) (lambda () (d01_triple_decompose_selective 6)))) 6)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 201 (list) (lambda ()
                          (d01_triple_decompose_selective -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: d01_triple_decompose_selective -1"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 203 (list) (lambda () (d02_introand_same_subject 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 204 (list) (lambda ()
                          (d02_introand_same_subject -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: d02_introand_same_subject -1"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 206 (list) (lambda () (d03_andleft_andright_conservative 3)))) 3)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 207 (list) (lambda ()
                          (d03_andleft_andright_conservative -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: d03_andleft_andright_conservative -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 208 (list) (lambda ()
                          (d03_andleft_andright_conservative 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: d03_andleft_andright_conservative 1001"))
  )

  (test-case "R54_G: guard cases"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 238 (list) (lambda () (g01_partial_guard_with_catchall Red 5)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 239 (list) (lambda () (g01_partial_guard_with_catchall Red -1)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 240 (list) (lambda () (g01_partial_guard_with_catchall Yellow 0)))) 2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 241 (list) (lambda () (g01_partial_guard_with_catchall Green 0)))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 243 (list) (lambda () (g02_all_unguarded_exhaustive Red)))) "stop")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 244 (list) (lambda () (g02_all_unguarded_exhaustive Yellow)))) "slow")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 245 (list) (lambda () (g02_all_unguarded_exhaustive Green)))) "go")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 247 (list) (lambda () (g03_mixed_guards_with_default Nothing 5)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 248 (list) (lambda () (g03_mixed_guards_with_default (raw-value (Something 10)) 5)))) 10)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 249 (list) (lambda () (g03_mixed_guards_with_default (raw-value (Something 3)) 5)))) 5)
  )

  (test-case "R54_L: lambda with proof params"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 267 (list) (lambda () (l01_lambda_with_proof_param 42)))) 42)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 268 (list) (lambda ()
                          (l01_lambda_with_proof_param -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: l01_lambda_with_proof_param -1"))
  (define g (thsl-src! "tests/critical-review-54-tests.tesl" 270 (list) (lambda () (l02_lambda_captures_proof 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 271 (list (cons 'g g)) (lambda () (l03_lambda_partial_apply g 3)))) 8)
  )

  (test-case "R54_N: nested type access"
  (define rawContent (thsl-src! "tests/critical-review-54-tests.tesl" 301 (list) (lambda () "hello")))
  (define tesl-checked-42 (checkNonEmpty rawContent))
  (when (check-fail? tesl-checked-42)
    (raise-user-error 'tesl-test "unexpected failure in let safeContent: ~a" (check-fail-message tesl-checked-42)))
  (define safeContent tesl-checked-42)
  (define inner (thsl-src! "tests/critical-review-54-tests.tesl" 303 (list (cons 'safeContent safeContent) (cons 'rawContent rawContent)) (lambda () (InnerRec #:content safeContent))))
  (define outer (thsl-src! "tests/critical-review-54-tests.tesl" 304 (list (cons 'inner inner) (cons 'safeContent safeContent) (cons 'rawContent rawContent)) (lambda () (OuterRec #:inner (raw-value inner)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 305 (list (cons 'outer outer) (cons 'inner inner) (cons 'safeContent safeContent) (cons 'rawContent rawContent)) (lambda () (n01_nested_record_field_proof outer)))) "hello")
  (define rawEmpty (thsl-src! "tests/critical-review-54-tests.tesl" 307 (list (cons 'outer outer) (cons 'inner inner) (cons 'safeContent safeContent) (cons 'rawContent rawContent)) (lambda () "")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 308 (list (cons 'rawEmpty rawEmpty) (cons 'outer outer) (cons 'inner inner) (cons 'safeContent safeContent) (cons 'rawContent rawContent)) (lambda ()
                          (checkNonEmpty rawEmpty))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkNonEmpty rawEmpty"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 310 (list (cons 'rawEmpty rawEmpty) (cons 'outer outer) (cons 'inner inner) (cons 'safeContent safeContent) (cons 'rawContent rawContent)) (lambda () (n02_three_level_case Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 311 (list (cons 'rawEmpty rawEmpty) (cons 'outer outer) (cons 'inner inner) (cons 'safeContent safeContent) (cons 'rawContent rawContent)) (lambda () (n02_three_level_case (raw-value (Something Nothing)))))) -1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 312 (list (cons 'rawEmpty rawEmpty) (cons 'outer outer) (cons 'inner inner) (cons 'safeContent safeContent) (cons 'rawContent rawContent)) (lambda () (n02_three_level_case (raw-value (Something (raw-value (Something 42)))))))) 42)
  )

  (test-case "R54_P: stdlib proof-total functions"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 330 (list) (lambda () (p01_safe_divide 10 2)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 331 (list) (lambda () (p01_safe_divide 7 3)))) 2)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-54-tests.tesl" 332 (list) (lambda ()
                          (p01_safe_divide 5 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: p01_safe_divide 5 0"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 334 (list) (lambda () (p03_filter_check_creates_forall (list 1 2 -3 4 -5))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 335 (list) (lambda () (p03_filter_check_creates_forall (list -1 -2 -3))))) 0)
  )

  (test-case "R54_C: case and pattern matching"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 363 (list) (lambda () (c01_proof_flows_through_some_arm Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 364 (list) (lambda () (c01_proof_flows_through_some_arm (raw-value (Something 42)))))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 366 (list) (lambda () (c02_proof_after_three_way_case 5)))) "positive")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 367 (list) (lambda () (c02_proof_after_three_way_case -3)))) "negative")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 368 (list) (lambda () (c02_proof_after_three_way_case 0)))) "zero")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 370 (list) (lambda () (c03_literal_pattern_with_catchall 200)))) "ok")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 371 (list) (lambda () (c03_literal_pattern_with_catchall 404)))) "not found")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 372 (list) (lambda () (c03_literal_pattern_with_catchall 500)))) "server error")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-54-tests.tesl" 373 (list) (lambda () (c03_literal_pattern_with_catchall 301)))) "other")
  )

)
