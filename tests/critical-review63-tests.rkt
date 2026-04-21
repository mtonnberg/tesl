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
  (only-in tesl/tesl/prelude Int String Bool List Fact attachFact detachFact forgetFact introAnd andLeft andRight)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.map tesl_import_List_map] [List.sort tesl_import_List_sort] [List.emptyForAll tesl_import_List_emptyForAll] IsSorted)
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith] [String.toUpper tesl_import_String_toUpper] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/int [Int.divide tesl_import_Int_divide] [Int.nonZero tesl_import_Int_nonZero] [Int.nonNegative tesl_import_Int_nonNegative] IsNonZero IsNonNegative)
  (only-in tesl/tesl/float Float [Float.div tesl_import_Float_div] [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero)
  (only-in tesl/tesl/dict Dict [Dict.requireKey tesl_import_Dict_requireKey] [Dict.get tesl_import_Dict_get] [Dict.fromList tesl_import_Dict_fromList] [Dict.lookup tesl_import_Dict_lookup] HasKey)
  (only-in tesl/tesl/tuple Tuple2)
)


(provide )

(define A 'A)
(define AllPositive 'AllPositive)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define HasPrefix 'HasPrefix)
(define InRange 'InRange)
(define IsAdmin 'IsAdmin)
(define IsLong 'IsLong)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))

(define-checker
  (checkRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange lo hi n)]
  (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange lo hi n) #:value *n) (reject "out of range" #:http-code 400)))

(define-checker
  (checkAdmin [userId : String])
  #:returns [userId : String ::: (IsAdmin userId)]
  (if (tesl_import_String_startsWith *userId "admin") (accept (IsAdmin userId) #:value *userId) (reject "not admin" #:http-code 403)))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (trusted-proof (A n)))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (trusted-proof (B n)))

(define-trusted
  (proveC [n : Integer])
  #:returns (Fact (C n))
  (trusted-proof (C n)))

(define-trusted
  (proveD [n : Integer])
  #:returns (Fact (D n))
  (trusted-proof (D n)))

(define-trusted
  (proveE [n : Integer])
  #:returns (Fact (E n))
  (trusted-proof (E n)))

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  *n)

(define/pow
  (needsSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  *n)

(define/pow
  (needsPosSmall [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  *n)

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  *n)

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  *n)

(define/pow
  (needsC [n : Integer ::: (C n)])
  #:returns Integer
  *n)

(define/pow
  (needsAll5 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns Integer
  *n)

(define/pow
  (needsInRange [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  *n)

(define/pow
  (divideHelper [a : Integer] [b : Integer ::: (IsNonZero b)])
  #:returns Integer
  (raw-value (tesl_import_Int_divide *a b)))

(define/pow
  (testDivideViaHelper [a : Integer] [b : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (tesl_import_Int_nonZero b)]) (let ([divisor tesl_checked_0]) (raw-value (divideHelper a divisor)))))

(define/pow
  (divideChain [a : Integer] [b : Integer] [c : Integer])
  #:returns Integer
  (let/check ([tesl_checked_1 (tesl_import_Int_nonZero b)]) (let ([nzB tesl_checked_1]) (let/check ([tesl_checked_2 (tesl_import_Int_nonZero c)]) (let ([nzC tesl_checked_2]) (let ([r1 (tesl_import_Int_divide *a nzB)]) (raw-value (tesl_import_Int_divide (raw-value r1) nzC))))))))

(define/pow
  (getDictValue [key : String] [d : (Dict String Integer) ::: (HasKey key d)])
  #:returns Integer
  (raw-value (tesl_import_Dict_get *key d)))

(define/pow
  (testDictViaHelper [key : String] [d : (Dict String Integer)])
  #:returns Integer
  (let/check ([tesl_checked_3 (tesl_import_Dict_requireKey key d)]) (let ([checked tesl_checked_3]) (raw-value (getDictValue key checked)))))

(define/pow
  (nonNegHelper [n : Integer ::: (IsNonNegative n)])
  #:returns Integer
  *n)

(define/pow
  (testNonNegViaHelper [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_4 (tesl_import_Int_nonNegative n)]) (let ([nn tesl_checked_4]) (raw-value (nonNegHelper nn)))))

(define/pow
  (floatDivHelper [a : Real] [b : Real ::: (FloatNonZero b)])
  #:returns Real
  (raw-value (tesl_import_Float_div *a b)))

(define/pow
  (testFloatDivViaHelper [a : Real] [b : Real])
  #:returns Real
  (let/check ([tesl_checked_5 (tesl_import_Float_requireNonZero b)]) (let ([nz tesl_checked_5]) (raw-value (floatDivHelper a nz)))))

(define/pow
  (processPositiveList [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (getPositives [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPos *xs))

(define/pow
  (testForAllParamToReturn [xs : (List Integer)])
  #:returns Integer
  (let ([positives (getPositives xs)]) (raw-value (processPositiveList positives))))

(define/pow
  (getPositivesQuestion [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPos *xs))

(define/pow
  (testQuestionReturnToParam [xs : (List Integer)])
  #:returns Integer
  (let ([positives (getPositivesQuestion xs)]) (raw-value (processPositiveList positives))))

(define/pow
  (testAllCheckToParam [xs : (List Integer)])
  #:returns Integer
  (let ([r (tesl_import_List_allCheck checkPos *xs)]) (let ([tesl_case_6 (raw-value r)]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Nothing)) (raw-value 0)] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Something)) (let ([vs (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (raw-value (processPositiveList *vs)))]))))

(define/pow
  (testEmptyForAll)
  #:returns Integer
  (let ([empty (tesl_import_List_emptyForAll checkPos)]) (raw-value (processPositiveList empty))))

(define/pow
  (narrowToSmallPositive [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkSmall *xs))

(define/pow
  (countPositiveSmall [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (sequentialFilterAccumulates [xs : (List Integer)])
  #:returns (List Integer)
  (let ([p1 (tesl_import_List_filterCheck checkPos *xs)]) (tesl_import_List_filterCheck checkSmall (raw-value p1))))

(define/pow
  (testDetachSingle [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([xA (attach-proof x pa)]) (let ([detached (detach-all-proof xA)]) (let ([restored (attach-proof x detached)]) (raw-value (needsA restored)))))))

(define/pow
  (testDetachMulti [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pab (intro-and pa pb)]) (let ([xAB (attach-proof x pab)]) (let ([detached (detach-all-proof xAB)]) (let ([la (and-left detached)]) (let ([xA (attach-proof x la)]) (raw-value (needsA xA))))))))))

(define/pow
  (testDetachMultiBothProofs [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pab (intro-and pa pb)]) (let ([xAB (attach-proof x pab)]) (let ([detached (detach-all-proof xAB)]) (let ([la (and-left detached)]) (let ([rb (and-right detached)]) (let ([xA (attach-proof x la)]) (let ([xB (attach-proof x rb)]) (+ (raw-value (needsA xA)) (raw-value (needsB xB)))))))))))))

(define-checker
  (checkHasPrefix [s : String])
  #:returns [s : String ::: (HasPrefix s)]
  (if (tesl_import_String_startsWith *s "admin") (accept (HasPrefix s) #:value *s) (reject "no prefix" #:http-code 400)))

(define-checker
  (checkIsLong [s : String])
  #:returns [s : String ::: (IsLong s)]
  (if (> (raw-value (tesl_import_String_length *s)) 5) (accept (IsLong s) #:value *s) (reject "too short" #:http-code 400)))

(define/pow
  (processLongPrefixed [xs : (List String)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (filterBothCombined [xs : (List String)])
  #:returns Integer
  (let ([both (tesl_import_List_filterCheck (check-and checkHasPrefix checkIsLong) *xs)]) (raw-value (processLongPrefixed both))))

(define/pow
  (filterBothSequential [xs : (List String)])
  #:returns Integer
  (let ([prefixed (tesl_import_List_filterCheck checkHasPrefix *xs)]) (let ([long (tesl_import_List_filterCheck checkIsLong (raw-value prefixed))]) (raw-value (processLongPrefixed long)))))

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (if (> *n 0) (accept (A n) #:value *n) (reject "bad" #:http-code 400)))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (if (> *n 1) (accept ((A n) && (B n)) #:value *n) (reject "bad" #:http-code 400)))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: ((A n) && ((B n) && (C n)))]
  (if (> *n 2) (accept ((A n) && ((B n) && (C n))) #:value *n) (reject "bad" #:http-code 400)))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))]
  (if (> *n 3) (accept ((A n) && ((B n) && ((C n) && (D n)))) #:value *n) (reject "bad" #:http-code 400)))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))]
  (if (> *n 4) (accept ((A n) && ((B n) && ((C n) && ((D n) && (E n))))) #:value *n) (reject "bad" #:http-code 400)))

(define/pow
  (chain5Step [x : Integer])
  #:returns Integer
  (let/check ([tesl_checked_7 (checkA x)]) (let ([a tesl_checked_7]) (let/check ([tesl_checked_8 (checkB a)]) (let ([ab tesl_checked_8]) (let/check ([tesl_checked_9 (checkC ab)]) (let ([abc tesl_checked_9]) (let/check ([tesl_checked_10 (checkD abc)]) (let ([abcd tesl_checked_10]) (let/check ([tesl_checked_11 (checkE abcd)]) (let ([abcde tesl_checked_11]) (raw-value (needsAll5 abcde)))))))))))))

(define/pow
  (testLetDecompAB [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pab (intro-and pa pb)]) (let ([xAB (attach-proof x pab)]) (let ([tesl_proof_binding_12 xAB]) (let ([y (forget-proof tesl_proof_binding_12)] [qa (detach-all-proof tesl_proof_binding_12)]) (let ([tesl_proof_binding_13 xAB]) (let ([_ (forget-proof tesl_proof_binding_13)] [qb (detach-all-proof tesl_proof_binding_13)]) (+ (raw-value (needsA (attach-proof y qa))) (raw-value (needsB (attach-proof y qb)))))))))))))

(define/pow
  (testLetDecomp3Way [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pc (proveC x)]) (let ([pab (intro-and pa pb)]) (let ([pabc (intro-and pab pc)]) (let ([xABC (attach-proof x pabc)]) (let ([tesl_proof_binding_14 xABC]) (let ([y (forget-proof tesl_proof_binding_14)] [qc (detach-all-proof tesl_proof_binding_14)]) (raw-value (needsC (attach-proof y qc))))))))))))

(define/pow
  (testLetProofFromCheck [raw : Integer])
  #:returns Integer
  (let ([tesl_proof_binding_15 (checkPos raw)]) (let ([_ (forget-proof tesl_proof_binding_15)] [p (detach-all-proof tesl_proof_binding_15)]) (let ([proven (attach-proof raw p)]) (raw-value (needsPos proven))))))

(define-adt Inner
  [InnerA [val : Integer]]
  [InnerB [msg : String]]
)

(define-adt Outer
  [OuterWrap [inner : Inner]]
  [OuterEmpty]
)

(define/pow
  (extractNested [o : Outer])
  #:returns Integer
  (let ([tesl_case_16 *o]) (cond [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'OuterEmpty)) (raw-value -1)] [(and (and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'OuterWrap)) (let ([tesl_case_16_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_16) 'inner))]) (and (adt-value? *tesl_case_16_f0) (eq? (adt-value-variant *tesl_case_16_f0) 'InnerA)))) (let ([tesl_case_16_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_16) 'inner))]) (let ([v (hash-ref (adt-value-fields *tesl_case_16_f0) 'val)]) *v))] [(and (and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'OuterWrap)) (let ([tesl_case_16_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_16) 'inner))]) (and (adt-value? *tesl_case_16_f0) (eq? (adt-value-variant *tesl_case_16_f0) 'InnerB)))) (let ([tesl_case_16_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_16) 'inner))]) (raw-value 0))])))

(define-adt Tree
  [Leaf]
  [Node [left : Tree] [value : Integer] [right : Tree]]
)

(define/pow
  (sumTree [t : Tree])
  #:returns Integer
  (let ([tesl_case_17 *t]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_17) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_17) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_17) 'right)]) (raw-value (+ (+ (raw-value (sumTree *l)) *v) (raw-value (sumTree *r)))))))])))

(define/pow
  (treeHeight [t : Tree])
  #:returns Integer
  (let ([tesl_case_18 *t]) (cond [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_18) 'left)]) (let ([r (hash-ref (adt-value-fields *tesl_case_18) 'right)]) (let ([lh (treeHeight *l)]) (let ([rh (treeHeight *r)]) (if (> (raw-value lh) (raw-value rh)) (raw-value (+ (raw-value lh) 1)) (raw-value (+ (raw-value rh) 1)))))))])))

(define/pow
  (buildBalancedTree)
  #:returns Tree
  (raw-value (Node (Node Leaf 1 Leaf) 2 (Node (Node Leaf 3 Leaf) 4 Leaf))))

(define-checker
  (checkAllPositive [t : Tree])
  #:returns [t : Tree ::: (AllPositive t)]
  (let ([tesl_case_19 *t]) (cond [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Leaf)) (accept (AllPositive t) #:value *t)] [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_19) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_19) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_19) 'right)]) (if (<= (raw-value v) 0) (reject "non-positive node" #:http-code 400) (let/check ([tesl_checked_20 (checkAllPositive l)]) (let ([l2 tesl_checked_20]) (let/check ([tesl_checked_21 (checkAllPositive r)]) (let ([r2 tesl_checked_21]) (accept (AllPositive t) #:value *t)))))))))])))

(define/pow
  (processAllPositiveTree [t : Tree ::: (AllPositive t)])
  #:returns Integer
  (raw-value (sumTree t)))

(define/pow
  (testTreeProof [t : Tree])
  #:returns Integer
  (let/check ([tesl_checked_22 (checkAllPositive t)]) (let ([validated tesl_checked_22]) (raw-value (processAllPositiveTree validated)))))

(define/pow
  (rangeHelper [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  *n)

(define/pow
  (testMultiParamViaHelper [lo : Integer] [hi : Integer] [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_23 (checkRange lo hi n)]) (let ([validated tesl_checked_23]) (raw-value (rangeHelper lo hi validated)))))

(define/pow
  (testArithPrec [a : Integer] [b : Integer] [c : Integer])
  #:returns Integer
  (+ *a (* *b *c)))

(define/pow
  (testComparePrec [a : Integer] [b : Integer] [c : Integer])
  #:returns Boolean
  (> (+ *a *b) *c))

(define/pow
  (testBoolPrec [a : Integer] [b : Integer] [c : Integer])
  #:returns Boolean
  (and (> *a 0) (or (> *b 0) (> *c 0))))

(define-record SafePost
  [title : String ::: (IsTrimmed title)]
  [count : Integer]
)

(define/pow
  (requiresTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  *s)

(define/pow
  (makeSafePost [raw : String] [count : Integer])
  #:returns SafePost
  (let ([trimmed (tesl_import_String_trim *raw)]) (SafePost #:title trimmed #:count *count)))

(define/pow
  (readTitle [p : SafePost])
  #:returns String
  (raw-value (requiresTrimmed (tesl-dot/runtime p 'title))))

(define/pow
  (updateCountPreservesProof [p : SafePost] [newCount : Integer])
  #:returns SafePost
  (tesl-record-update *p (hash 'count *newCount)))

(define/pow
  (safeDivFloat [a : Real] [b : Real])
  #:returns Real
  (let/check ([tesl_checked_24 (tesl_import_Float_requireNonZero b)]) (let ([nz tesl_checked_24]) (raw-value (tesl_import_Float_div *a nz)))))

(define/pow
  (divChainFloat [a : Real] [b : Real] [c : Real])
  #:returns Real
  (let/check ([tesl_checked_25 (tesl_import_Float_requireNonZero b)]) (let ([nzB tesl_checked_25]) (let/check ([tesl_checked_26 (tesl_import_Float_requireNonZero c)]) (let ([nzC tesl_checked_26]) (let ([r1 (raw-value (tesl_import_Float_div *a nzB))]) (raw-value (tesl_import_Float_div (raw-value r1) nzC))))))))

(module+ test
  (require rackunit)
  (test-case "R63_PP01 Int.divide works through function parameter boundary"
  (define r (testDivideViaHelper 10 5))
  (check-equal? (raw-value r) 2)
  )

  (test-case "R63_PP02 Int.divide via helper fails correctly for zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testDivideViaHelper 10 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testDivideViaHelper 10 0) (list)"))
  )

  (test-case "R63_PP03 chained Int.divide with two proof-annotated params"
  (define r (divideChain 100 5 2))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R63_PP04 Dict.get works through function parameter boundary"
  (define d (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 42) (Tuple2 "b" 99)))))
  (define r (testDictViaHelper "a" d))
  (check-equal? (raw-value r) 42)
  )

  (test-case "R63_PP05 Dict.get via helper fails for missing key"
  (define d (raw-value (tesl_import_Dict_fromList (list (Tuple2 "b" 99)))))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testDictViaHelper "a" d) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testDictViaHelper \"a\" d) (list)"))
  )

  (test-case "R63_PP06 IsNonNegative proof through function parameter boundary"
  (define r (testNonNegViaHelper 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R63_PP07 IsNonNegative proof fails for negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testNonNegViaHelper -1) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testNonNegViaHelper -1) (list)"))
  )

  (test-case "R63_PP08 Float.div works through function parameter boundary"
  (define r (testFloatDivViaHelper 10. 4.))
  (check-equal? (raw-value r) 2.5)
  )

  (test-case "R63_PP09 Float.div via helper fails for zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testFloatDivViaHelper 10. 0.) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testFloatDivViaHelper 10. 0.) (list)"))
  )

  (test-case "R63_FA01 ForAll with ? return can be consumed by explicit-subject parameter"
  (define r (testForAllParamToReturn (list 1 2 3 -1 0)))
  (check-equal? (raw-value r) 3)
  )

  (test-case "R63_FA02 ForAll ? return flows to explicit-subject parameter"
  (define r (testQuestionReturnToParam (list 5 10 -3 0 7)))
  (check-equal? (raw-value r) 3)
  )

  (test-case "R63_FA03 allCheck result flows to explicit-subject ForAll parameter"
  (define r (testAllCheckToParam (list 1 2 3)))
  (check-equal? (raw-value r) 3)
  )

  (test-case "R63_FA04 allCheck returns Nothing when any element fails"
  (define r (testAllCheckToParam (list 1 -1 2)))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R63_FA05 List.emptyForAll produces valid ForAll list"
  (define r (testEmptyForAll))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R63_FA06 narrowToSmall pattern: filterCheck on ForAll param produces conjunction"
  (define positives (tesl_import_List_filterCheck checkPos (list 1 50 200 -1 99 0)))
  (define small (narrowToSmallPositive positives))
  (define count (countPositiveSmall small))
  (check-equal? (raw-value count) 3)
  )

  (test-case "R63_FA07 sequential filterCheck accumulates ForAll predicates"
  (define r (sequentialFilterAccumulates (list 1 50 200 -1 99 0)))
  (define count (countPositiveSmall r))
  (check-equal? (raw-value count) 3)
  )

  (test-case "R63_DC01 detachFact works on single-proof value"
  (define r (testDetachSingle 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R63_DC02 detachFact on multi-proof value succeeds: returns combined (A && B) proof"
  (define r (testDetachMulti 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R63_DC03 detachFact on multi-proof: andLeft and andRight both work on result"
  (define r (testDetachMultiBothProofs 5))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R63_SC01 combined && check produces correct ForAll conjunction"
  (define xs (list "admin1234567" "admin" "user123456" "adminXXXXXX"))
  (define r (filterBothCombined xs))
  (check-equal? (raw-value r) 2)
  )

  (test-case "R63_SC02 sequential filterCheck accumulates correctly"
  (define xs (list "admin1234567" "admin" "user123456" "adminXXXXXX"))
  (define r (filterBothSequential xs))
  (check-equal? (raw-value r) 2)
  )

  (test-case "R63_CH01 5-step proof chain accumulates and satisfies conjunction"
  (define r (chain5Step 10))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R63_CH02 5-step chain fails at step 1"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((chain5Step 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (chain5Step 0) (list)"))
  )

  (test-case "R63_CH03 5-step chain fails at step 3"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((chain5Step 2) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (chain5Step 2) (list)"))
  )

  (test-case "R63_CH04 5-step chain fails at step 5"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((chain5Step 4) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (chain5Step 4) (list)"))
  )

  (test-case "R63_LT01 let proof decomposition: (y ::: qa && qb) = xAB"
  (define r (testLetDecompAB 5))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R63_LT02 3-way proof decomposition with _ discards"
  (define r (testLetDecomp3Way 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R63_LT03 let (_ ::: p) = check f(x) pattern works"
  (define r (testLetProofFromCheck 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R63_LT04 let (_ ::: p) pattern fails when check fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testLetProofFromCheck 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testLetProofFromCheck 0) (list)"))
  )

  (test-case "R63_NP01 nested constructor pattern: OuterWrap (InnerA v)"
  (define r (extractNested (OuterWrap (InnerA 42))))
  (check-equal? (raw-value r) 42)
  )

  (test-case "R63_NP02 nested constructor pattern: OuterWrap (InnerB _)"
  (define r (extractNested (OuterWrap (InnerB "hello"))))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R63_NP03 nested constructor pattern: OuterEmpty"
  (define r (extractNested OuterEmpty))
  (check-equal? (raw-value r) -1)
  )

  (test-case "R63_NP04 recursive tree sum = 1+2+3+4 = 10"
  (define t (buildBalancedTree))
  (check-equal? (raw-value (sumTree t)) 10)
  )

  (test-case "R63_NP05 recursive tree height = 3"
  (define t (buildBalancedTree))
  (check-equal? (raw-value (treeHeight t)) 3)
  )

  (test-case "R63_NP06 recursive tree proof: all-positive tree succeeds"
  (define t (buildBalancedTree))
  (define r (testTreeProof t))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R63_NP07 recursive tree proof: negative node fails"
  (define badTree (raw-value (Node Leaf -1 Leaf)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testTreeProof badTree) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testTreeProof badTree) (list)"))
  )

  (test-case "R63_MP01 multi-param proof InRange through function boundary"
  (define r (testMultiParamViaHelper 0 100 50))
  (check-equal? (raw-value r) 50)
  )

  (test-case "R63_MP02 multi-param proof fails for out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testMultiParamViaHelper 0 100 200) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testMultiParamViaHelper 0 100 200) (list)"))
  )

  (test-case "R63_MP03 multi-param proof with negative bounds"
  (define r (testMultiParamViaHelper -50 50 -10))
  (check-equal? (raw-value r) -10)
  )

  (test-case "R63_OP01 * binds tighter than +"
  (check-equal? (raw-value (testArithPrec 2 3 4)) 14)
  )

  (test-case "R63_OP02 arithmetic before comparison"
  (check-equal? (raw-value (testComparePrec 2 3 4)) #t)
  )

  (test-case "R63_OP03 && binds tighter than ||"
  (check-equal? (raw-value (testBoolPrec 1 1 0)) #t)
  )

  (test-case "R63_OP04 && binds tighter than || negative case"
  (check-equal? (raw-value (testBoolPrec -1 1 0)) #f)
  )

  (test-case "R63_RC01 record field proof propagates on read"
  (define p (makeSafePost "  Hello  " 5))
  (define title (readTitle p))
  (check-equal? (raw-value title) "Hello")
  )

  (test-case "R63_RC02 record update on non-proof field preserves proof fields"
  (define p (makeSafePost "Hello" 1))
  (define p2 (tesl-record-update (raw-value p) (hash 'count (raw-value 99))))
  (define t (readTitle p2))
  (check-equal? (raw-value t) "Hello")
  )

  (test-case "R63_RC03 proof field accessible after helper function update"
  (define p (makeSafePost "World" 0))
  (define p2 (updateCountPreservesProof p 42))
  (define t (readTitle p2))
  (check-equal? (raw-value t) "World")
  )

  (test-case "R63_FP01 Float.div direct"
  (define r (safeDivFloat 10. 4.))
  (check-equal? (raw-value r) 2.5)
  )

  (test-case "R63_FP02 Float.div by zero fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((safeDivFloat 10. 0.) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivFloat 10. 0.) (list)"))
  )

  (test-case "R63_FP03 Float.div chained"
  (define r (divChainFloat 100. 5. 4.))
  (check-equal? (raw-value r) 5.)
  )

)
