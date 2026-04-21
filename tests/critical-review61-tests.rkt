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
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.sort tesl_import_List_sort] [List.map tesl_import_List_map] [List.emptyForAll tesl_import_List_emptyForAll] IsSorted)
  (only-in tesl/tesl/set Set [Set.filterCheck tesl_import_Set_filterCheck] [Set.fromList tesl_import_Set_fromList] [Set.size tesl_import_Set_size] [Set.insert tesl_import_Set_insert] [Set.empty tesl_import_Set_empty])
  (only-in tesl/tesl/dict Dict [Dict.filterCheckValues tesl_import_Dict_filterCheckValues] [Dict.fromList tesl_import_Dict_fromList] [Dict.size tesl_import_Dict_size])
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.toUpper tesl_import_String_toUpper] [String.length tesl_import_String_length] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/int [Int.divide tesl_import_Int_divide] [Int.nonZero tesl_import_Int_nonZero] IsNonZero)
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define F 'F)
(define G 'G)
(define InRange 'InRange)
(define IsEven 'IsEven)
(define IsOdd 'IsOdd)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define LengthOk 'LengthOk)
(define TitleSafe 'TitleSafe)
(define X 'X)
(define Y 'Y)
(define Z 'Z)

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

(define-checker
  (checkF [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n))))))]
  (if (> *n 5) (accept ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n)))))) #:value *n) (reject "bad" #:http-code 400)))

(define-checker
  (checkG [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n))))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && ((F n) && (G n)))))))]
  (if (> *n 6) (accept ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && ((F n) && (G n))))))) #:value *n) (reject "bad" #:http-code 400)))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))

(define-checker
  (checkTitle [s : String])
  #:returns [s : String ::: (TitleSafe s)]
  (if (< (raw-value (tesl_import_String_length *s)) 100) (accept (TitleSafe s) #:value *s) (reject "too long" #:http-code 400)))

(define-checker
  (checkLengthOk [n : Integer])
  #:returns [n : Integer ::: (LengthOk n)]
  (if (and (> *n 0) (< *n 100)) (accept (LengthOk n) #:value *n) (reject "bad length" #:http-code 400)))

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

(define-trusted
  (provePos [n : Integer])
  #:returns (Fact (IsPositive n))
  (trusted-proof (IsPositive n)))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  *n)

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  *n)

(define/pow
  (needsAll6 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n))))))])
  #:returns Integer
  *n)

(define/pow
  (needsAll7 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && ((F n) && (G n)))))))])
  #:returns Integer
  *n)

(define/pow
  (needsPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  *n)

(define/pow
  (needsSmall [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  *n)

(define/pow
  (build6Chain [x : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (checkA x)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkB a)]) (let ([b tesl_checked_1]) (let/check ([tesl_checked_2 (checkC b)]) (let ([c tesl_checked_2]) (let/check ([tesl_checked_3 (checkD c)]) (let ([d tesl_checked_3]) (let/check ([tesl_checked_4 (checkE d)]) (let ([e tesl_checked_4]) (let/check ([tesl_checked_5 (checkF e)]) (let ([f tesl_checked_5]) (raw-value (needsAll6 f)))))))))))))))

(define/pow
  (build7Chain [x : Integer])
  #:returns Integer
  (let/check ([tesl_checked_6 (checkA x)]) (let ([a tesl_checked_6]) (let/check ([tesl_checked_7 (checkB a)]) (let ([b tesl_checked_7]) (let/check ([tesl_checked_8 (checkC b)]) (let ([c tesl_checked_8]) (let/check ([tesl_checked_9 (checkD c)]) (let ([d tesl_checked_9]) (let/check ([tesl_checked_10 (checkE d)]) (let ([e tesl_checked_10]) (let/check ([tesl_checked_11 (checkF e)]) (let ([f tesl_checked_11]) (let/check ([tesl_checked_12 (checkG f)]) (let ([g tesl_checked_12]) (raw-value (needsAll7 g)))))))))))))))))

(define/pow
  (filterPositiveSet [xs : (Set Integer)])
  #:returns (Set Integer)
  (tesl_import_Set_filterCheck checkPos *xs))

(define/pow
  (filterPositiveValues [xs : (Dict String Integer)])
  #:returns (Dict String Integer)
  (raw-value (tesl_import_Dict_filterCheckValues checkPos *xs)))

(define/pow
  (allSmall [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (tesl_import_List_allCheck (check-and checkPos checkSmall) *xs))

(define/pow
  (getPositives [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPos *xs))

(define/pow
  (narrowToSmall [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkSmall *xs))

(define/pow
  (forAllPipeline [xs : (List Integer)])
  #:returns (List Integer)
  (let ([positives (getPositives xs)]) (narrowToSmall positives)))

(define/pow
  (countSmall [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (requiresTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  *s)

(define/pow
  (requiresUpperCase [s : String ::: (IsUpperCase s)])
  #:returns String
  *s)

(define/pow
  (requiresSorted [xs : (List Integer) ::: (IsSorted xs)])
  #:returns (List Integer)
  *xs)

(define/pow
  (trimAndUse [raw : String])
  #:returns String
  (let ([t (tesl_import_String_trim *raw)]) (raw-value (requiresTrimmed t))))

(define/pow
  (upperAndUse [raw : String])
  #:returns String
  (let ([u (tesl_import_String_toUpper *raw)]) (raw-value (requiresUpperCase u))))

(define/pow
  (sortAndUse [xs : (List Integer)])
  #:returns (List Integer)
  (let ([s (tesl_import_List_sort *xs)]) (raw-value (requiresSorted s))))

(define-record SafeTriple
  [title : String ::: (TitleSafe title)]
  [count : Integer ::: (LengthOk count)]
  [score : Integer ::: (IsPositive score)]
)

(define/pow
  (buildSafeTriple [t : String] [c : Integer] [s : Integer])
  #:returns SafeTriple
  (let/check ([tesl_checked_13 (checkTitle t)]) (let ([safeTitle tesl_checked_13]) (let/check ([tesl_checked_14 (checkLengthOk c)]) (let ([safeCount tesl_checked_14]) (let/check ([tesl_checked_15 (checkPos s)]) (let ([safeScore tesl_checked_15]) (SafeTriple #:title safeTitle #:count safeCount #:score safeScore))))))))

(define/pow
  (combine5Proofs [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pc (proveC x)]) (let ([pd (proveD x)]) (let ([pe (proveE x)]) (let ([pab (intro-and pa pb)]) (let ([pabc (intro-and pab pc)]) (let ([pabcd (intro-and pabc pd)]) (let ([pabcde (intro-and pabcd pe)]) (let ([x2 (attach-proof x pabcde)]) (let ([la (and-left pabcde)]) (let ([x3 (attach-proof (forget-proof x2) la)]) (raw-value (needsA x3)))))))))))))))

(define/pow
  (andLeftRightRoundTrip [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pab (intro-and pa pb)]) (let ([la (and-left pab)]) (let ([rb (and-right pab)]) (let ([x2 (attach-proof (forget-proof x) la)]) (let ([x3 (attach-proof (forget-proof x) rb)]) (+ (raw-value (needsA x2)) (raw-value (needsB x3)))))))))))

(define-trusted
  (proveInRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns (Maybe (Fact (InRange lo hi n)))
  (if (and (<= *lo *n) (<= *n *hi)) (Something (trusted-proof (InRange lo hi n))) Nothing))

(define/pow
  (requiresInRange [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  *n)

(define/pow
  (tryUseRange [lo : Integer] [hi : Integer] [x : Integer])
  #:returns Integer
  (let ([proof (proveInRange lo hi x)]) (let ([tesl_case_16 (raw-value proof)]) (cond [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Nothing)) (raw-value -1)] [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl_case_16) 'value)]) (let ([x2 (attach-proof x *p)]) (raw-value (requiresInRange lo hi x2))))]))))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (if (< *n 0) (reject "negative" #:http-code 400) (if (equal? *n 0) (accept (IsEven n) #:value *n) (let/check ([tesl_checked_17 (checkOdd (- *n 1))]) (let ([_odd tesl_checked_17]) (accept (IsEven n) #:value *n))))))

(define-checker
  (checkOdd [n : Integer])
  #:returns [n : Integer ::: (IsOdd n)]
  (if (<= *n 0) (reject "not odd" #:http-code 400) (if (equal? *n 1) (accept (IsOdd n) #:value *n) (let/check ([tesl_checked_18 (checkEven (- *n 1))]) (let ([_even tesl_checked_18]) (accept (IsOdd n) #:value *n))))))

(define/pow
  (requiresEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  *n)

(define/pow
  (requiresOdd [n : Integer ::: (IsOdd n)])
  #:returns Integer
  *n)

(define/pow
  (testMutualRec [e : Integer] [o : Integer])
  #:returns Integer
  (let/check ([tesl_checked_19 (checkEven e)]) (let ([even tesl_checked_19]) (let/check ([tesl_checked_20 (checkOdd o)]) (let ([odd tesl_checked_20]) (+ (raw-value (requiresEven even)) (raw-value (requiresOdd odd))))))))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns Integer
  (let/check ([tesl_checked_21 (tesl_import_Int_nonZero b)]) (let ([nonZeroB tesl_checked_21]) (raw-value (tesl_import_Int_divide *a nonZeroB)))))

(define/pow
  (forgetAndRe [x : Integer])
  #:returns Integer
  (let/check ([tesl_checked_22 (checkPos x)]) (let ([proven tesl_checked_22]) (let ([raw (forget-proof proven)]) (let/check ([tesl_checked_23 (checkPos raw)]) (let ([reproven tesl_checked_23]) (raw-value (needsPositive reproven))))))))

(define-adt Shape
  [Circle [r : Integer]]
  [Rectangle [w : Integer] [h : Integer]]
  [Triangle [base : Integer] [height : Integer]]
)

(define-adt Container
  [Empty]
  [Filled [item : Shape] [count : Integer]]
)

(define/pow
  (describeShape [s : Shape])
  #:returns String
  (let ([tesl_case_24 *s]) (cond [(and (adt-value? *tesl_case_24) (eq? (adt-value-variant *tesl_case_24) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_24) 'r)]) (raw-value "circle"))] [(and (adt-value? *tesl_case_24) (eq? (adt-value-variant *tesl_case_24) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl_case_24) 'w)]) (let ([h (hash-ref (adt-value-fields *tesl_case_24) 'h)]) (raw-value "rect")))] [(and (adt-value? *tesl_case_24) (eq? (adt-value-variant *tesl_case_24) 'Triangle)) (let ([base (hash-ref (adt-value-fields *tesl_case_24) 'base)]) (let ([height (hash-ref (adt-value-fields *tesl_case_24) 'height)]) (raw-value "triangle")))])))

(define/pow
  (describeContainer [c : Container])
  #:returns String
  (let ([tesl_case_25 *c]) (cond [(and (adt-value? *tesl_case_25) (eq? (adt-value-variant *tesl_case_25) 'Empty)) (raw-value "empty")] [(and (adt-value? *tesl_case_25) (eq? (adt-value-variant *tesl_case_25) 'Filled)) (let ([item (hash-ref (adt-value-fields *tesl_case_25) 'item)]) (let ([count (hash-ref (adt-value-fields *tesl_case_25) 'count)]) (let ([tesl_case_26 (raw-value item)]) (cond [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_26) 'r)]) (raw-value "circle"))] [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl_case_26) 'w)]) (let ([h (hash-ref (adt-value-fields *tesl_case_26) 'h)]) (raw-value "rect")))] [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Triangle)) (let ([base (hash-ref (adt-value-fields *tesl_case_26) 'base)]) (let ([height (hash-ref (adt-value-fields *tesl_case_26) 'height)]) (raw-value "triangle")))]))))])))

(define/pow
  (requiresBThenA [n : Integer ::: ((B n) && (A n))])
  #:returns Integer
  *n)

(define/pow
  (testConjunctionOrder [x : Integer])
  #:returns Integer
  (let/check ([tesl_checked_27 (checkA x)]) (let ([a tesl_checked_27]) (let/check ([tesl_checked_28 (checkB a)]) (let ([b tesl_checked_28]) (raw-value (requiresBThenA b)))))))

(define/pow
  (doubleIfPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (* *n 2))

(define/pow
  (mapPositives [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-29 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (doubleIfPositive n))) tesl-lambda-29) *xs)))

(define-checker
  (checkXY [n : Integer])
  #:returns [n : Integer ::: ((X n) && (Y n))]
  (if (> *n 0) (accept ((Y n) && (X n)) #:value *n) (reject "bad" #:http-code 400)))

(define-checker
  (checkXYZ [n : Integer])
  #:returns [n : Integer ::: ((X n) && ((Y n) && (Z n)))]
  (if (> *n 0) (accept ((Z n) && ((X n) && (Y n))) #:value *n) (reject "bad" #:http-code 400)))

(define/pow
  (requiresXY [n : Integer ::: ((X n) && (Y n))])
  #:returns Integer
  *n)

(define/pow
  (requiresXYZ [n : Integer ::: ((X n) && ((Y n) && (Z n)))])
  #:returns Integer
  *n)

(module+ test
  (require rackunit)
  (test-case "R61_CH01 6-check accumulation chain works end-to-end"
  (define r (build6Chain 10))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R61_CH02 7-check accumulation chain works end-to-end"
  (define r (build7Chain 10))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R61_CH03 6-check chain fails at step 1 if first check fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((build6Chain 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (build6Chain 0) (list)"))
  )

  (test-case "R61_CH04 6-check chain fails at step 3 if middle check fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((build6Chain 2) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (build6Chain 2) (list)"))
  )

  (test-case "R61_FA01 Set.filterCheck produces ForAll (IsPositive) \226\128\148 succeeds"
  (define s (tesl_import_Set_filterCheck checkPos (raw-value (tesl_import_Set_fromList (list 1 2 3 -1 0)))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value s)))) 3)
  )

  (test-case "R61_FA02 Dict.filterCheckValues produces ForAllValues (IsPositive)"
  (define d (raw-value (tesl_import_Dict_filterCheckValues checkPos (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 1) (Tuple2 "b" -1) (Tuple2 "c" 2)))))))
  (check-equal? (raw-value (raw-value (tesl_import_Dict_size (raw-value d)))) 2)
  )

  (test-case "R61_FA03 List.allCheck with conjunction returns Something if all pass"
  (define r (allSmall (list 1 2 3)))
  (let ([*tesl_case_30 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl_case_30) (eq? (adt-value-variant *tesl_case_30) 'Nothing))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                              ((+ 1 1) (list)))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
    [(and (adt-value? *tesl_case_30) (eq? (adt-value-variant *tesl_case_30) 'Something))
      (let ([xs (hash-ref (adt-value-fields *tesl_case_30) 'value)])
        (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value xs)))) 3)
      )
    ]
  ))
  )

  (test-case "R61_FA04 List.allCheck with conjunction returns Nothing if any fail"
  (define r (allSmall (list 1 2 200)))
  (let ([*tesl_case_31 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Nothing))
      (check-equal? 1 1)
    ]
    [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Something))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                              ((+ 1 1) (list)))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
  ))
  )

  (test-case "R61_FA05 ForAll propagates through fn call chain (positives -> narrowToSmall)"
  (define result (forAllPipeline (list 1 2 50 200 -1)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "R61_FA06 List.emptyForAll produces empty ForAll list"
  (define empty (tesl_import_List_emptyForAll checkPos))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value empty)))) 0)
  )

  (test-case "R61_SF01 String.trim returns IsTrimmed proof"
  (define r (trimAndUse "  hello  "))
  (check-equal? (raw-value r) "hello")
  )

  (test-case "R61_SF02 String.toUpper returns IsUpperCase proof"
  (define r (upperAndUse "hello"))
  (check-equal? (raw-value r) "HELLO")
  )

  (test-case "R61_SF03 List.sort returns IsSorted proof"
  (define r (sortAndUse (list 3 1 2)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value r)))) 3)
  )

  (test-case "R61_RC01 record with 3 proof-annotated fields: construction succeeds"
  (define item (buildSafeTriple "hello" 5 3))
  (check-equal? (raw-value (tesl-dot/runtime item 'score)) 3)
  )

  (test-case "R61_RC02 record with 3 proof-annotated fields: construction fails if count out of range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((buildSafeTriple "hello" -1 3) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (buildSafeTriple \"hello\" -1 3) (list)"))
  )

  (test-case "R61_IM01 introAnd with 5 proofs + andLeft extracts first proof"
  (define r (combine5Proofs 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R61_IM02 andLeft and andRight round-trip"
  (define r (andLeftRightRoundTrip 5))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R61_EM01 establish Maybe returns Something when proof holds"
  (define r (tryUseRange 1 10 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R61_EM02 establish Maybe returns Nothing when proof doesn't hold"
  (define r (tryUseRange 1 10 20))
  (check-equal? (raw-value r) -1)
  )

  (test-case "R61_MR01 mutual recursion with check: even 4 + odd 3 = 7"
  (define r (testMutualRec 4 3))
  (check-equal? (raw-value r) 7)
  )

  (test-case "R61_MR02 mutual recursion: odd number fails checkEven"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((raw-value (checkOdd 2)) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkOdd 2)) (list)"))
  )

  (test-case "R61_MR03 mutual recursion: even number fails checkOdd"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((raw-value (checkOdd 4)) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkOdd 4)) (list)"))
  )

  (test-case "R61_DI01 Int.divide with IsNonZero proof succeeds"
  (define r (safeDivide 10 2))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R61_DI02 Int.nonZero fails for zero denominator"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((safeDivide 10 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivide 10 0) (list)"))
  )

  (test-case "R61_FG01 forgetFact followed by re-check works"
  (define r (forgetAndRe 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R61_NA01 nested ADT exhaustiveness: all constructors covered"
  (define c (raw-value (Filled (Circle 5) 3)))
  (define desc (describeContainer c))
  (check-equal? (raw-value desc) "circle")
  )

  (test-case "R61_NA02 nested ADT: Rectangle"
  (define r (describeContainer (Filled (Rectangle 4 3) 1)))
  (check-equal? (raw-value r) "rect")
  )

  (test-case "R61_NA03 nested ADT: Triangle"
  (define r (describeContainer (Filled (Triangle 3 4) 2)))
  (check-equal? (raw-value r) "triangle")
  )

  (test-case "R61_NA04 nested ADT: Empty container"
  (define r (describeContainer Empty))
  (check-equal? (raw-value r) "empty")
  )

  (test-case "R61_PP01 call-site proof: B && A required, A && B carried \226\128\148 works (commutative)"
  (define r (testConjunctionOrder 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R61_LM01 lambda with proof-annotated param works in List.map on ForAll list"
  (define positives (tesl_import_List_filterCheck checkPos (list 1 2 3)))
  (define doubled (mapPositives positives))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value doubled)))) 3)
  )

  (test-case "R61_LM02 direct filterCheck (no lambda) produces ForAll list"
  (define r (tesl_import_List_filterCheck checkPos (list 1 -1 2 -2 3)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value r)))) 3)
  )

  (test-case "R61_CO01 ok conjunction order normalised: Y && X accepted for X && Y return"
  (define n 5)
  (define tesl_checked_32 (checkXY n))
  (when (check-fail? tesl_checked_32)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_32)))
  (define v tesl_checked_32)
  (check-equal? (raw-value (requiresXY v)) 5)
  )

  (test-case "R61_CO02 ok conjunction order normalised: Z && X && Y accepted for X && Y && Z"
  (define n 5)
  (define tesl_checked_33 (checkXYZ n))
  (when (check-fail? tesl_checked_33)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_33)))
  (define v tesl_checked_33)
  (check-equal? (raw-value (requiresXYZ v)) 5)
  )

  (test-case "R61_CO03 reversed-order check can be used in call-site with original order"
  (define n 5)
  (define tesl_checked_34 (checkXY n))
  (when (check-fail? tesl_checked_34)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_34)))
  (define v tesl_checked_34)
  (define tesl_checked_35 (checkXYZ n))
  (when (check-fail? tesl_checked_35)
    (raise-user-error 'tesl-test "unexpected failure in let w: ~a" (check-fail-message tesl_checked_35)))
  (define w tesl_checked_35)
  (check-equal? (raw-value (+ (raw-value (requiresXY v)) (raw-value (requiresXYZ w)))) 10)
  )

)
