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
  (only-in tesl/tesl/prelude Int Bool String List Fact)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.filterCheck tesl_import_List_filterCheck] [List.map tesl_import_List_map] [List.sort tesl_import_List_sort] IsSorted)
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.length tesl_import_String_length] IsTrimmed)
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define InRange 'InRange)
(define IsEven 'IsEven)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define IsValidRange 'IsValidRange)

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 33 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 39 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (IsSmall n) #:value *n) (reject "too large" #:http-code 400)))))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 45 (list (cons 'n *n)) (lambda () (if (equal? (remainder *n 2) 0) (accept (IsEven n) #:value *n) (reject "not even" #:http-code 400)))))

(define/pow
  (needPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 50 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 51 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needBoth [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 52 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needAll3 [n : Integer ::: ((IsPositive n) && ((IsSmall n) && (IsEven n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 53 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (r55_la01_map_with_paren_lambda [xs : (List Integer)])
  #:returns Integer
  (let ([doubled (thsl-src! "tests/critical-review-55-tests.tesl" 58 (list (cons 'xs *xs)) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [n : Integer]) #:returns Integer (+ *n *n)) tesl-lambda-0) *xs)))]) (thsl-src! "tests/critical-review-55-tests.tesl" 59 (list (cons 'doubled *doubled) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled)))))))

(define/pow
  (r55_la02_filter_with_paren_lambda [xs : (List Integer)])
  #:returns (List Integer)
  (let ([positives (thsl-src! "tests/critical-review-55-tests.tesl" 62 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs)))]) (thsl-src! "tests/critical-review-55-tests.tesl" 63 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-1 [n : Integer]) #:returns Integer (+ *n 1)) tesl-lambda-1) (raw-value positives)))))))

(define/pow
  (r55_tu01_tuple_proof_via_var [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 76 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_2 (checkPos raw)]) (let ([pos tesl_checked_2]) (let ([_pair (raw-value (Tuple2 pos 0))]) (raw-value (needPos pos))))))))

(define/pow
  (r55_tu02_tuple_first_raw [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 81 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_3 (checkPos raw)]) (let ([pos tesl_checked_3]) (let ([pair (raw-value (Tuple2 pos 5))]) (+ (raw-value (tesl_import_Tuple2_first (raw-value pair))) (raw-value (tesl_import_Tuple2_second (raw-value pair))))))))))

(define/pow
  (r55_fm01_forall_via_filtercheck [xs : (List Integer)])
  #:returns Integer
  (let ([positives (thsl-src! "tests/critical-review-55-tests.tesl" 95 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs)))]) (let ([needPosAll (thsl-src! "tests/critical-review-55-tests.tesl" 96 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (let () (define/pow (tesl-lambda-4 [ns : (List Integer)]) #:returns Integer (raw-value (tesl_import_List_length *ns))) tesl-lambda-4)))]) (thsl-src! "tests/critical-review-55-tests.tesl" 97 (list (cons 'needPosAll *needPosAll) (cons 'positives *positives) (cons 'xs *xs)) (lambda () (raw-value (needPosAll positives)))))))

(define/pow
  (r55_fm02_forall_lost_through_map_runtime [xs : (List Integer)])
  #:returns Integer
  (let ([positives (thsl-src! "tests/critical-review-55-tests.tesl" 100 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs)))]) (let ([doubled (thsl-src! "tests/critical-review-55-tests.tesl" 101 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-5 [n : Integer]) #:returns Integer (+ *n *n)) tesl-lambda-5) (raw-value positives))))]) (thsl-src! "tests/critical-review-55-tests.tesl" 102 (list (cons 'doubled *doubled) (cons 'positives *positives) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled))))))))

(define/pow
  (r55_ch01_combined_check [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 114 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_6 ((check-and checkPos checkSmall) raw)]) (let ([result tesl_checked_6]) (raw-value (needBoth result)))))))

(define/pow
  (r55_ch02_combined_in_filtercheck [xs : (List Integer)])
  #:returns Integer
  (let ([result (thsl-src! "tests/critical-review-55-tests.tesl" 118 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck (check-and checkPos checkSmall) *xs)))]) (thsl-src! "tests/critical-review-55-tests.tesl" 119 (list (cons 'result *result) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))))

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 139 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkB [n : Integer])
  #:returns [n : Integer ::: (B n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 145 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (B n) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkC [n : Integer])
  #:returns [n : Integer ::: (C n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 151 (list (cons 'n *n)) (lambda () (if (equal? (remainder *n 2) 0) (accept (C n) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkD [n : Integer])
  #:returns [n : Integer ::: (D n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 157 (list (cons 'n *n)) (lambda () (if (equal? (remainder *n 3) 0) (accept (D n) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkE [n : Integer])
  #:returns [n : Integer ::: (E n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 163 (list (cons 'n *n)) (lambda () (if (equal? (remainder *n 5) 0) (accept (E n) #:value *n) (reject "bad" #:http-code 400)))))

(define/pow
  (needAll5 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 168 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needAE [n : Integer ::: ((A n) && (E n))])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 169 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (r55_mp01_five_step [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 172 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_7 (checkA raw)]) (let ([a tesl_checked_7]) (let/check ([tesl_checked_8 (checkB a)]) (let ([b tesl_checked_8]) (let/check ([tesl_checked_9 (checkC b)]) (let ([c tesl_checked_9]) (let/check ([tesl_checked_10 (checkD c)]) (let ([d tesl_checked_10]) (let/check ([tesl_checked_11 (checkE d)]) (let ([e tesl_checked_11]) (raw-value (needAll5 e)))))))))))))))

(define/pow
  (r55_mp02_five_conjunct_selective [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 180 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_12 (checkA raw)]) (let ([a tesl_checked_12]) (let/check ([tesl_checked_13 (checkB a)]) (let ([b tesl_checked_13]) (let/check ([tesl_checked_14 (checkC b)]) (let ([c tesl_checked_14]) (let/check ([tesl_checked_15 (checkD c)]) (let ([d tesl_checked_15]) (let/check ([tesl_checked_16 (checkE d)]) (let ([e tesl_checked_16]) (let ([tesl_proof_binding_17 e]) (let ([v (forget-proof tesl_proof_binding_17)] [pa (detach-all-proof tesl_proof_binding_17)]) (let ([tesl_proof_binding_18 e]) (let ([_ (forget-proof tesl_proof_binding_18)] [pe (detach-all-proof tesl_proof_binding_18)]) (raw-value (needAE (attach-proof v (list pa pe)))))))))))))))))))))

(define-trusted
  (proveRange [lo : Integer] [hi : Integer])
  #:returns (Fact (IsValidRange lo hi))
  (thsl-src! "tests/critical-review-55-tests.tesl" 203 (list (cons 'lo *lo) (cons 'hi *hi)) (lambda () (trusted-proof (IsValidRange lo hi)))))

(define-record BoundedInt
  [value : Integer ::: (IsPositive value)]
)

(define/pow
  (makeBoundedInt [lo : Integer] [hi : Integer] [value : Integer ::: (IsPositive value)])
  #:returns BoundedInt
  (let ([rangeProof (thsl-src! "tests/critical-review-55-tests.tesl" 210 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'value *value)) (lambda () (proveRange lo hi)))]) (thsl-src! "tests/critical-review-55-tests.tesl" 211 (list (cons 'rangeProof *rangeProof) (cons 'lo *lo) (cons 'hi *hi) (cons 'value *value)) (lambda () (BoundedInt #:value value)))))

(define-checker
  (checkInRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange lo hi n)]
  (thsl-src! "tests/critical-review-55-tests.tesl" 227 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define/pow
  (needInRange [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 232 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (r55_li01_named_bounds [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-55-tests.tesl" 235 (list (cons 'raw *raw)) (lambda () (let ([lo 1]) (let ([hi 100]) (let/check ([tesl_checked_19 (checkInRange lo hi raw)]) (let ([v tesl_checked_19]) (raw-value (needInRange lo hi v)))))))))

(define/pow
  (r55_sp01_trim_produces_istrimmed [raw : String])
  #:returns (? String _entity ::: (IsTrimmed _entity))
  (thsl-src! "tests/critical-review-55-tests.tesl" 251 (list (cons 'raw *raw)) (lambda () (tesl_import_String_trim *raw))))

(define/pow
  (r55_sp02_sort_produces_issorted [xs : (List Integer)])
  #:returns (? (List Integer) _entity ::: (IsSorted _entity))
  (thsl-src! "tests/critical-review-55-tests.tesl" 254 (list (cons 'xs *xs)) (lambda () (tesl_import_List_sort *xs))))

(define/pow
  (r55_sp03_use_trimmed [raw : String])
  #:returns Integer
  (let ([trimmed (thsl-src! "tests/critical-review-55-tests.tesl" 257 (list (cons 'raw *raw)) (lambda () (r55_sp01_trim_produces_istrimmed raw)))]) (let ([needTrimmed (thsl-src! "tests/critical-review-55-tests.tesl" 258 (list (cons 'trimmed *trimmed) (cons 'raw *raw)) (lambda () (let () (define/pow (tesl-lambda-20 [s : String]) #:returns Integer (let ([s (tesl-establish-param-proof s *s `(IsTrimmed ,s))]) (tesl_import_String_length *s))) tesl-lambda-20)))]) (thsl-src! "tests/critical-review-55-tests.tesl" 259 (list (cons 'needTrimmed *needTrimmed) (cons 'trimmed *trimmed) (cons 'raw *raw)) (lambda () (raw-value (needTrimmed trimmed)))))))

(define-adt TrafficLight
  [TrafficRed]
  [TrafficYellow]
  [TrafficGreen]
)

(define/pow
  (r55_dc01_unique_ctors [t : TrafficLight])
  #:returns String
  (thsl-src-control! "tests/critical-review-55-tests.tesl" 274 (list (cons 't *t)) (lambda () (let ([tesl_case_21 *t]) (cond [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'TrafficRed)) (thsl-src! "tests/critical-review-55-tests.tesl" 275 (list) (lambda () (raw-value "stop")))] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'TrafficYellow)) (thsl-src! "tests/critical-review-55-tests.tesl" 276 (list) (lambda () (raw-value "caution")))] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'TrafficGreen)) (thsl-src! "tests/critical-review-55-tests.tesl" 277 (list) (lambda () (raw-value "go")))])))))

(define/pow
  (r55_mc01_literal_and_ctor [m : (Maybe Integer)])
  #:returns String
  (thsl-src-control! "tests/critical-review-55-tests.tesl" 288 (list (cons 'm *m)) (lambda () (let ([tesl_case_22 *m]) (cond [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Nothing)) (thsl-src! "tests/critical-review-55-tests.tesl" 289 (list) (lambda () (raw-value "nothing")))] [(and (and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Something)) (let ([tesl_case_22_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_22) 'value))]) (= *tesl_case_22_f0 0))) (let ([tesl_case_22_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_22) 'value))]) (thsl-src! "tests/critical-review-55-tests.tesl" 290 (list) (lambda () (raw-value "zero"))))] [(and (and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Something)) (let ([tesl_case_22_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_22) 'value))]) (= *tesl_case_22_f0 1))) (let ([tesl_case_22_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_22) 'value))]) (thsl-src! "tests/critical-review-55-tests.tesl" 291 (list) (lambda () (raw-value "one"))))] [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Something)) (thsl-src! "tests/critical-review-55-tests.tesl" 292 (list) (lambda () (raw-value "other")))])))))

(define-adt Status2
  [Status2Active]
  [Status2Done]
  [Status2Cancelled]
)

(define/pow
  (r55_mc02_fallthrough_arms [s : Status2])
  #:returns String
  (thsl-src-control! "tests/critical-review-55-tests.tesl" 300 (list (cons 's *s)) (lambda () (let ([tesl_case_23 *s]) (cond [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Status2Active)) (thsl-src! "tests/critical-review-55-tests.tesl" 303 (list) (lambda () (raw-value "completed")))] [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Status2Done)) (thsl-src! "tests/critical-review-55-tests.tesl" 303 (list) (lambda () (raw-value "completed")))] [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Status2Cancelled)) (thsl-src! "tests/critical-review-55-tests.tesl" 305 (list) (lambda () (raw-value "cancelled")))])))))

(module+ test
  (require rackunit)
  (test-case "R55_LA: parenthesized lambda in application position"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 66 (list) (lambda () (r55_la01_map_with_paren_lambda (list 1 2 3))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 67 (list) (lambda () (r55_la01_map_with_paren_lambda (list))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 69 (list) (lambda () (r55_la02_filter_with_paren_lambda (list 1 2 -3))))) (list 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 70 (list) (lambda () (r55_la02_filter_with_paren_lambda (list -1 -2))))) (list))
  )

  (test-case "R55_TU: Tuple access and proof via variable"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 86 (list) (lambda () (r55_tu01_tuple_proof_via_var 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-55-tests.tesl" 87 (list) (lambda ()
                          (r55_tu01_tuple_proof_via_var -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: r55_tu01_tuple_proof_via_var -1"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 89 (list) (lambda () (r55_tu02_tuple_first_raw 3)))) 8)
  )

  (test-case "R55_FM: ForAll proof correctness"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 105 (list) (lambda () (r55_fm01_forall_via_filtercheck (list 1 2 -3 4))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 106 (list) (lambda () (r55_fm01_forall_via_filtercheck (list -1 -2))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 108 (list) (lambda () (r55_fm02_forall_lost_through_map_runtime (list 1 2 3))))) 3)
  )

  (test-case "R55_CH: combined check && operator"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 122 (list) (lambda () (r55_ch01_combined_check 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 123 (list) (lambda () (r55_ch01_combined_check 999)))) 999)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-55-tests.tesl" 124 (list) (lambda ()
                          (r55_ch01_combined_check -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: r55_ch01_combined_check -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-55-tests.tesl" 125 (list) (lambda ()
                          (r55_ch01_combined_check 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: r55_ch01_combined_check 1001"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 127 (list) (lambda () (r55_ch02_combined_in_filtercheck (list 1 2 -3 1500))))) 2)
  )

  (test-case "R55_MP: 5-step proof chains"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 189 (list) (lambda () (r55_mp01_five_step 30)))) 30)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 190 (list) (lambda () (r55_mp01_five_step 60)))) 60)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-55-tests.tesl" 191 (list) (lambda ()
                          (r55_mp01_five_step -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: r55_mp01_five_step -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-55-tests.tesl" 192 (list) (lambda ()
                          (r55_mp01_five_step 5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: r55_mp01_five_step 5"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-55-tests.tesl" 193 (list) (lambda ()
                          (r55_mp01_five_step 7))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: r55_mp01_five_step 7"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 195 (list) (lambda () (r55_mp02_five_conjunct_selective 30)))) 30)
  )

  (test-case "R55_GW: ghost witness correct usage"
  (define lo (thsl-src! "tests/critical-review-55-tests.tesl" 214 (list) (lambda () 1)))
  (define hi (thsl-src! "tests/critical-review-55-tests.tesl" 215 (list (cons 'lo lo)) (lambda () 100)))
  (define rawVal (thsl-src! "tests/critical-review-55-tests.tesl" 216 (list (cons 'hi hi) (cons 'lo lo)) (lambda () 50)))
  (define tesl_checked_24 (checkPos rawVal))
  (when (check-fail? tesl_checked_24)
    (raise-user-error 'tesl-test "unexpected failure in let posVal: ~a" (check-fail-message tesl_checked_24)))
  (define posVal tesl_checked_24)
  (define bounded (thsl-src! "tests/critical-review-55-tests.tesl" 218 (list (cons 'posVal posVal) (cons 'rawVal rawVal) (cons 'hi hi) (cons 'lo lo)) (lambda () (makeBoundedInt lo hi posVal))))
  (check-equal? (thsl-src! "tests/critical-review-55-tests.tesl" 219 (list (cons 'bounded bounded) (cons 'posVal posVal) (cons 'rawVal rawVal) (cons 'hi hi) (cons 'lo lo)) (lambda () (raw-value (tesl-dot/runtime bounded 'value)))) 50)
  )

  (test-case "R55_LI: named variable bounds for multi-param proofs"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 241 (list) (lambda () (r55_li01_named_bounds 50)))) 50)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 242 (list) (lambda () (r55_li01_named_bounds 1)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 243 (list) (lambda () (r55_li01_named_bounds 100)))) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-55-tests.tesl" 244 (list) (lambda ()
                          (r55_li01_named_bounds 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: r55_li01_named_bounds 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-55-tests.tesl" 245 (list) (lambda ()
                          (r55_li01_named_bounds 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: r55_li01_named_bounds 101"))
  )

  (test-case "R55_SP: stdlib proof propagation"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 262 (list) (lambda () (r55_sp03_use_trimmed "  hello  ")))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 263 (list) (lambda () (r55_sp03_use_trimmed "hello")))) 5)
  )

  (test-case "R55_DC: unique constructor names"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 280 (list) (lambda () (r55_dc01_unique_ctors TrafficRed)))) "stop")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 281 (list) (lambda () (r55_dc01_unique_ctors TrafficYellow)))) "caution")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 282 (list) (lambda () (r55_dc01_unique_ctors TrafficGreen)))) "go")
  )

  (test-case "R55_MC: mixed patterns and fall-through"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 308 (list) (lambda () (r55_mc01_literal_and_ctor Nothing)))) "nothing")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 309 (list) (lambda () (r55_mc01_literal_and_ctor (raw-value (Something 0)))))) "zero")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 310 (list) (lambda () (r55_mc01_literal_and_ctor (raw-value (Something 1)))))) "one")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 311 (list) (lambda () (r55_mc01_literal_and_ctor (raw-value (Something 42)))))) "other")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 313 (list) (lambda () (r55_mc02_fallthrough_arms Status2Active)))) "completed")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 314 (list) (lambda () (r55_mc02_fallthrough_arms Status2Done)))) "completed")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-55-tests.tesl" 315 (list) (lambda () (r55_mc02_fallthrough_arms Status2Cancelled)))) "cancelled")
  )

)
