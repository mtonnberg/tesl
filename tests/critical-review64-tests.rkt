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
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.sort tesl_import_List_sort] [List.emptyForAll tesl_import_List_emptyForAll] IsSorted)
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.toUpper tesl_import_String_toUpper] [String.length tesl_import_String_length] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/int [Int.divide tesl_import_Int_divide] [Int.nonZero tesl_import_Int_nonZero] [Int.nonNegative tesl_import_Int_nonNegative] IsNonZero IsNonNegative)
  (only-in tesl/tesl/float Float [Float.div tesl_import_Float_div] [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero)
  (only-in tesl/tesl/dict Dict [Dict.fromList tesl_import_Dict_fromList] [Dict.filterCheckValues tesl_import_Dict_filterCheckValues] [Dict.size tesl_import_Dict_size] [Dict.requireKey tesl_import_Dict_requireKey] [Dict.get tesl_import_Dict_get] HasKey)
  (only-in tesl/tesl/tuple Tuple2)
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define HasMax 'HasMax)
(define HasMin 'HasMin)
(define InBounds 'InBounds)
(define IsActive 'IsActive)
(define IsPinned 'IsPinned)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define IsVerified 'IsVerified)
(define NonEmpty 'NonEmpty)
(define ValidProject 'ValidProject)
(define ValidUser 'ValidUser)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (if (> *n 0) (accept (A n) #:value *n) (reject "a" #:http-code 400)))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (if (> *n 1) (accept ((A n) && (B n)) #:value *n) (reject "b" #:http-code 400)))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: ((A n) && ((B n) && (C n)))]
  (if (> *n 2) (accept ((A n) && ((B n) && (C n))) #:value *n) (reject "c" #:http-code 400)))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))]
  (if (> *n 3) (accept ((A n) && ((B n) && ((C n) && (D n)))) #:value *n) (reject "d" #:http-code 400)))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))]
  (if (> *n 4) (accept ((A n) && ((B n) && ((C n) && ((D n) && (E n))))) #:value *n) (reject "e" #:http-code 400)))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))

(define-checker
  (checkActive [n : Integer])
  #:returns [n : Integer ::: (IsActive n)]
  (if (> *n 0) (accept (IsActive n) #:value *n) (reject "not active" #:http-code 400)))

(define-checker
  (checkPinned [n : Integer])
  #:returns [n : Integer ::: (IsPinned n)]
  (if (> *n 10) (accept (IsPinned n) #:value *n) (reject "not pinned" #:http-code 400)))

(define-checker
  (checkVerified [n : Integer ::: ((IsActive n) && (IsPinned n))])
  #:returns [n : Integer ::: (IsVerified n)]
  (if (> *n 50) (accept (IsVerified n) #:value *n) (reject "not verified" #:http-code 400)))

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (NonEmpty s)]
  (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (NonEmpty s) #:value *s) (reject "empty" #:http-code 400)))

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
  (checkBounds [n : Integer])
  #:returns (Maybe (Fact (InBounds n)))
  (if (and (>= *n 0) (<= *n 255)) (Something (trusted-proof (InBounds n))) Nothing))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  *n)

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  *n)

(define/pow
  (needsAB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  *n)

(define/pow
  (needsABC [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns Integer
  *n)

(define/pow
  (needsAll5 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns Integer
  *n)

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
  (needsActive [n : Integer ::: (IsActive n)])
  #:returns Integer
  *n)

(define/pow
  (needsVerified [n : Integer ::: ((IsActive n) && ((IsPinned n) && (IsVerified n)))])
  #:returns Integer
  *n)

(define/pow
  (needsNonEmpty [s : String ::: (NonEmpty s)])
  #:returns String
  *s)

(define/pow
  (needsSorted [xs : (List Integer) ::: (IsSorted xs)])
  #:returns (List Integer)
  *xs)

(define/pow
  (needsTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  *s)

(define/pow
  (needsUpper [s : String ::: (IsUpperCase s)])
  #:returns String
  *s)

(define/pow
  (needsInBounds [n : Integer ::: (InBounds n)])
  #:returns Integer
  *n)

(define/pow
  (fiveStepChain [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (checkA n)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkB a)]) (let ([b tesl_checked_1]) (let/check ([tesl_checked_2 (checkC b)]) (let ([c tesl_checked_2]) (let/check ([tesl_checked_3 (checkD c)]) (let ([d tesl_checked_3]) (let/check ([tesl_checked_4 (checkE d)]) (let ([e tesl_checked_4]) (raw-value (needsAll5 e)))))))))))))

(define/pow
  (threeStepVerify [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_5 (checkActive n)]) (let ([a tesl_checked_5]) (let/check ([tesl_checked_6 (checkPinned a)]) (let ([p tesl_checked_6]) (let/check ([tesl_checked_7 (checkVerified p)]) (let ([v tesl_checked_7]) (raw-value (needsVerified v)))))))))

(define/pow
  (threeWayDecomp [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns Integer
  (let ([tesl_proof_binding_8 n]) (let ([x (forget-proof tesl_proof_binding_8)] [pa (detach-all-proof tesl_proof_binding_8)]) (let ([tesl_proof_binding_9 n]) (let ([_ (forget-proof tesl_proof_binding_9)] [pb (detach-all-proof tesl_proof_binding_9)]) (let ([tesl_proof_binding_10 n]) (let ([_ (forget-proof tesl_proof_binding_10)] [pc (detach-all-proof tesl_proof_binding_10)]) x)))))))

(define/pow
  (useFirstProof [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns Integer
  (let ([tesl_proof_binding_11 n]) (let ([x (forget-proof tesl_proof_binding_11)] [pa (detach-all-proof tesl_proof_binding_11)]) (raw-value (needsA (attach-proof x pa))))))

(define/pow
  (keepProofOnly [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  (let ([tesl_proof_binding_12 n]) (let ([_ (forget-proof tesl_proof_binding_12)] [pa (detach-all-proof tesl_proof_binding_12)]) (let ([bare (forget-proof n)]) (raw-value (needsA (attach-proof bare pa)))))))

(define/pow
  (maybePositive [n : Integer])
  #:returns (Maybe Integer)
  (if (> *n 0) (let/check ([tesl_checked_13 (checkPos n)]) (let ([p tesl_checked_13]) (raw-value (Something p)))) Nothing))

(define/pow
  (processIfPositive [n : Integer])
  #:returns Integer
  (let ([x (maybePositive n)]) (let ([tesl_case_14 (raw-value x)]) (cond [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Nothing)) (raw-value -1)] [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_14) 'value)]) (raw-value (needsPos v)))]))))

(define/pow
  (maybeSmallPos [n : Integer])
  #:returns (Maybe Integer)
  (if (and (> *n 0) (< *n 100)) (let/check ([tesl_checked_15 (checkPos n)]) (let ([p tesl_checked_15]) (let/check ([tesl_checked_16 (checkSmall p)]) (let ([s tesl_checked_16]) (raw-value (Something s)))))) Nothing))

(define/pow
  (useSmallPos [n : Integer])
  #:returns Integer
  (let ([tesl_case_17 (raw-value (maybeSmallPos n))]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Nothing)) (raw-value 0)] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_17) 'value)]) (raw-value (needsPosSmall v)))])))

(define-adt NumCategory
  [Small [value : Integer]]
  [Large [value : Integer]]
  [Zero]
)

(define/pow
  (processCategory [cat : NumCategory])
  #:returns Integer
  (let ([tesl_case_18 *cat]) (cond [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Zero)) (raw-value 0)] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Small)) (let ([n (hash-ref (adt-value-fields *tesl_case_18) 'value)]) (let/check ([tesl_checked_19 (checkPos *n)]) (let ([p tesl_checked_19]) (raw-value (needsPos p)))))] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Large)) (let ([n (hash-ref (adt-value-fields *tesl_case_18) 'value)]) (let/check ([tesl_checked_20 (checkPos *n)]) (let ([p tesl_checked_20]) (raw-value (needsPos p)))))])))

(define-adt Priority
  [Critical]
  [High]
  [Medium]
  [Low]
  [None]
)

(define/pow
  (priorityScore [p : Priority])
  #:returns Integer
  (let ([tesl_case_21 *p]) (cond [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'Critical)) (raw-value 100)] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'High)) (raw-value 50)] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'Medium)) (raw-value 50)] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'Low)) (raw-value 0)] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'None)) (raw-value 0)])))

(define/pow
  (filterPositiveValues [d : (Dict String Integer)])
  #:returns (Dict String Integer)
  (raw-value (tesl_import_Dict_filterCheckValues checkPos *d)))

(define/pow
  (safeGet [key : String] [d : (Dict String Integer)])
  #:returns Integer
  (let/check ([tesl_checked_22 (tesl_import_Dict_requireKey key d)]) (let ([checked tesl_checked_22]) (raw-value (tesl_import_Dict_get *key checked)))))

(define/pow
  (trimThenUpper [raw : String])
  #:returns String
  (let ([trimmed (tesl_import_String_trim *raw)]) (let ([upper (tesl_import_String_toUpper (raw-value trimmed))]) (raw-value (needsUpper upper)))))

(define/pow
  (pipelineVersion [raw : String])
  #:returns String
  (raw-value (tesl_import_String_toUpper (raw-value (tesl_import_String_trim *raw)))))

(define/pow
  (sortAndGetLength [xs : (List Integer)])
  #:returns Integer
  (let ([sorted (tesl_import_List_sort *xs)]) (let ([r (needsSorted sorted)]) (raw-value (tesl_import_List_length (raw-value r))))))

(define/pow
  (safeProcess [n : Integer])
  #:returns Integer
  (let ([mProof (checkBounds n)]) (let ([tesl_case_23 (raw-value mProof)]) (cond [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Nothing)) (raw-value -1)] [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl_case_23) 'value)]) (let ([proven (attach-proof n *p)]) (raw-value (needsInBounds proven))))]))))

(define/pow
  (isEven [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #t) (raw-value (isOdd (- *n 1)))))

(define/pow
  (isOdd [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #f) (raw-value (isEven (- *n 1)))))

(define/pow
  (filterActive [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkActive *xs))

(define/pow
  (filterActivePinned [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPinned *xs))

(define/pow
  (filterActivePinnedVerified [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkVerified *xs))

(define/pow
  (countVerified [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (threeLayerFilter [xs : (List Integer)])
  #:returns Integer
  (let ([active (filterActive xs)]) (let ([pinned (filterActivePinned active)]) (let ([verified (filterActivePinnedVerified pinned)]) (raw-value (countVerified verified))))))

(define/pow
  (processForAllList [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (buildVerifiedForAll)
  #:returns (List Integer)
  (let ([xs (list 100 60 80 200 55)]) (let ([active (filterActive xs)]) (let ([pinned (filterActivePinned active)]) (filterActivePinnedVerified pinned)))))

(define/pow
  (countPositive [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (decomposeViaAndLeft [n : Integer])
  #:returns Integer
  (let ([pa (proveA n)]) (let ([pb (proveB n)]) (let ([pab (intro-and pa pb)]) (let ([la (and-left pab)]) (let ([xA (attach-proof n la)]) (raw-value (needsA xA))))))))

(define/pow
  (decomposeViaAndRight [n : Integer])
  #:returns Integer
  (let ([pa (proveA n)]) (let ([pb (proveB n)]) (let ([pab (intro-and pa pb)]) (let ([rb (and-right pab)]) (let ([xB (attach-proof n rb)]) (raw-value (needsB xB))))))))

(define/pow
  (useBothParts [n : Integer])
  #:returns Integer
  (let ([pa (proveA n)]) (let ([pb (proveB n)]) (let ([pab (intro-and pa pb)]) (let ([la (and-left pab)]) (let ([rb (and-right pab)]) (let ([xA (attach-proof n la)]) (let ([xB (attach-proof n rb)]) (+ (raw-value (needsA xA)) (raw-value (needsB xB)))))))))))

(define-record SafeDoc
  [title : String ::: (NonEmpty title)]
  [wordCount : Integer]
)

(define/pow
  (makeDoc [rawTitle : String] [wc : Integer])
  #:returns SafeDoc
  (let/check ([tesl_checked_24 (checkNonEmpty rawTitle)]) (let ([t tesl_checked_24]) (SafeDoc #:title t #:wordCount *wc))))

(define/pow
  (readTitle [doc : SafeDoc])
  #:returns String
  (raw-value (needsNonEmpty (tesl-dot/runtime doc 'title))))

(define/pow
  (updateWordCount [doc : SafeDoc] [newCount : Integer])
  #:returns SafeDoc
  (tesl-record-update *doc (hash 'wordCount *newCount)))

(define/pow
  (readUpdatedTitle [rawTitle : String] [wc : Integer])
  #:returns String
  (let ([doc (makeDoc rawTitle wc)]) (let ([updated (updateWordCount doc 9999)]) (raw-value (readTitle updated)))))

(define/pow
  (applyCombined [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_25 ((check-and checkPos checkSmall) n)]) (let ([r tesl_checked_25]) (raw-value (needsPosSmall r)))))

(define/pow
  (filterActivePinnedDirect [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck (check-and checkActive checkPinned) *xs))

(define-checker
  (checkMin10 [n : Integer])
  #:returns [n : Integer ::: (HasMin 10 n)]
  (if (>= *n 10) (accept (HasMin 10 n) #:value *n) (reject "too small" #:http-code 400)))

(define-checker
  (checkMin20 [n : Integer])
  #:returns [n : Integer ::: (HasMin 20 n)]
  (if (>= *n 20) (accept (HasMin 20 n) #:value *n) (reject "too small" #:http-code 400)))

(define-checker
  (checkMax100 [n : Integer])
  #:returns [n : Integer ::: (HasMax 100 n)]
  (if (<= *n 100) (accept (HasMax 100 n) #:value *n) (reject "too big" #:http-code 400)))

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
  (needForAllAbove10 [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (needForAllAbove20 [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (filterAbove10 [raw : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkMin10 *raw))

(define/pow
  (filterAbove20 [raw : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkMin20 *raw))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define-checker
  (checkUser [u : UserId])
  #:returns [u : UserId ::: (ValidUser u)]
  (if (> (raw-value (tesl_import_String_length (raw-value u.value))) 0) (accept (ValidUser u) #:value *u) (reject "empty user id" #:http-code 400)))

(define-checker
  (checkProject [p : ProjectId])
  #:returns [p : ProjectId ::: (ValidProject p)]
  (if (> (raw-value (tesl_import_String_length (raw-value p.value))) 0) (accept (ValidProject p) #:value *p) (reject "empty project id" #:http-code 400)))

(define/pow
  (needsValidUser [u : UserId ::: (ValidUser u)])
  #:returns String
  (raw-value u.value))

(define/pow
  (needsValidProject [p : ProjectId ::: (ValidProject p)])
  #:returns String
  (raw-value p.value))

(module+ test
  (require rackunit)
  (test-case "R64_DC01 5-step sequential check chain with accumulating proofs"
  (define r (fiveStepChain 10))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R64_DC02 5-step chain: failure at step 3 (n <= 2) propagates"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((fiveStepChain 2) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (fiveStepChain 2) (list)"))
  )

  (test-case "R64_DC03 5-step chain: failure at step 1 (n <= 0) propagates"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((fiveStepChain 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (fiveStepChain 0) (list)"))
  )

  (test-case "R64_DC04 3-step check with 3-proof conjunction requirement"
  (define r (threeStepVerify 100))
  (check-equal? (raw-value r) 100)
  )

  (test-case "R64_DC05 3-step chain: fails at pinned threshold (n <= 10)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((threeStepVerify 5) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (threeStepVerify 5) (list)"))
  )

  (test-case "R64_DC06 3-step chain: fails at verified threshold (n <= 50)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((threeStepVerify 25) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (threeStepVerify 25) (list)"))
  )

  (test-case "R64_DX01 3-way conjunction decomposition preserves value"
  (define n 42)
  (define pa (proveA n))
  (define pb (proveB n))
  (define pc (proveC n))
  (define ab (intro-and pa pb))
  (define abc (intro-and ab pc))
  (define withProof (attach-proof n abc))
  (define r (threeWayDecomp withProof))
  (check-equal? (raw-value r) 42)
  )

  (test-case "R64_DX02 3-way decomposition: use first proof, discard rest"
  (define n 7)
  (define pa (proveA n))
  (define pb (proveB n))
  (define pc (proveC n))
  (define abc (intro-and (intro-and pa pb) pc))
  (define withProof (attach-proof n abc))
  (define r (useFirstProof withProof))
  (check-equal? (raw-value r) 7)
  )

  (test-case "R64_DX03 decompose with _ on value slot, keep proof"
  (define n 99)
  (define pa (proveA n))
  (define pb (proveB n))
  (define ab (intro-and pa pb))
  (define withProof (attach-proof n ab))
  (define r (keepProofOnly withProof))
  (check-equal? (raw-value r) 99)
  )

  (test-case "R64_MF01 Maybe proof return - Something arm propagates proof correctly"
  (define r (processIfPositive 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R64_MF02 Maybe proof return - Nothing arm works without proof"
  (define r (processIfPositive -3))
  (check-equal? (raw-value r) -1)
  )

  (test-case "R64_MF03 Maybe with conjunction proof - both proofs flow through case arm"
  (define r (useSmallPos 42))
  (check-equal? (raw-value r) 42)
  )

  (test-case "R64_MF04 Maybe with conjunction proof - out-of-range input returns Nothing"
  (define r (useSmallPos 200))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R64_CS01 proof produced in case arm - small variant"
  (define cat (raw-value (Small 5)))
  (define r (processCategory cat))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R64_CS02 proof produced in case arm - large variant"
  (define cat (raw-value (Large 500)))
  (define r (processCategory cat))
  (check-equal? (raw-value r) 500)
  )

  (test-case "R64_CS03 case arm with no proof - zero returns directly"
  (define r (processCategory Zero))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R64_CS04 proof check failure inside case arm"
  (define cat (raw-value (Small 0)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((processCategory cat) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (processCategory cat) (list)"))
  )

  (test-case "R64_AS01 fallthrough - Critical returns 100"
  (check-equal? (raw-value (priorityScore Critical)) 100)
  )

  (test-case "R64_AS02 fallthrough - High falls through to Medium result (50)"
  (check-equal? (raw-value (priorityScore High)) 50)
  )

  (test-case "R64_AS03 fallthrough - Medium returns 50 directly"
  (check-equal? (raw-value (priorityScore Medium)) 50)
  )

  (test-case "R64_AS04 fallthrough - Low falls through to None result (0)"
  (check-equal? (raw-value (priorityScore Low)) 0)
  )

  (test-case "R64_AS05 fallthrough - None returns 0 directly"
  (check-equal? (raw-value (priorityScore None)) 0)
  )

  (test-case "R64_DP01 Dict.filterCheckValues: keeps only positive values"
  (define d (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 5) (Tuple2 "b" -1) (Tuple2 "c" 10) (Tuple2 "d" -3)))))
  (define filtered (filterPositiveValues d))
  (define sz (raw-value (tesl_import_Dict_size (raw-value filtered))))
  (check-equal? (raw-value sz) 2)
  )

  (test-case "R64_DP02 Dict.filterCheckValues: all-positive dict unchanged size"
  (define d (raw-value (tesl_import_Dict_fromList (list (Tuple2 "x" 1) (Tuple2 "y" 2) (Tuple2 "z" 3)))))
  (define filtered (filterPositiveValues d))
  (define sz (raw-value (tesl_import_Dict_size (raw-value filtered))))
  (check-equal? (raw-value sz) 3)
  )

  (test-case "R64_DP03 Dict.filterCheckValues: all-negative dict gives empty"
  (define d (raw-value (tesl_import_Dict_fromList (list (Tuple2 "x" -1) (Tuple2 "y" -2)))))
  (define filtered (filterPositiveValues d))
  (define sz (raw-value (tesl_import_Dict_size (raw-value filtered))))
  (check-equal? (raw-value sz) 0)
  )

  (test-case "R64_DP04 Dict.requireKey + Dict.get round-trip succeeds for present key"
  (define d (raw-value (tesl_import_Dict_fromList (list (Tuple2 "hello" 42)))))
  (define r (safeGet "hello" d))
  (check-equal? (raw-value r) 42)
  )

  (test-case "R64_DP05 Dict.requireKey fails for missing key"
  (define d (raw-value (tesl_import_Dict_fromList (list (Tuple2 "other" 99)))))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((safeGet "hello" d) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeGet \"hello\" d) (list)"))
  )

  (test-case "R64_PP01 stdlib proof chain: trim then toUpper proofs compose"
  (define raw "  hello world  ")
  (define r (trimThenUpper raw))
  (check-equal? (raw-value r) "HELLO WORLD")
  )

  (test-case "R64_PP02 same stdlib chain via |> pipeline operator"
  (define raw "  test  ")
  (define r (pipelineVersion raw))
  (check-equal? (raw-value r) "TEST")
  )

  (test-case "R64_PP03 List.sort produces IsSorted proof usable by consumer"
  (define xs (list 3 1 4 1 5 9 2 6))
  (define r (sortAndGetLength xs))
  (check-equal? (raw-value r) 8)
  )

  (test-case "R64_EP01 establish returning Maybe(Fact) - value in bounds"
  (define r (safeProcess 128))
  (check-equal? (raw-value r) 128)
  )

  (test-case "R64_EP02 establish returning Maybe(Fact) - value out of bounds"
  (define r (safeProcess 300))
  (check-equal? (raw-value r) -1)
  )

  (test-case "R64_EP03 establish returning Maybe(Fact) - lower boundary value 0"
  (define r (safeProcess 0))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R64_EP04 establish returning Maybe(Fact) - upper boundary value 255"
  (define r (safeProcess 255))
  (check-equal? (raw-value r) 255)
  )

  (test-case "R64_EP05 establish returning Maybe(Fact) - negative value is out of bounds"
  (define r (safeProcess -1))
  (check-equal? (raw-value r) -1)
  )

  (test-case "R64_MR01 mutual recursion - isEven 0 is True"
  (check-equal? (raw-value (isEven 0)) #t)
  )

  (test-case "R64_MR02 mutual recursion - isOdd 1 is True"
  (check-equal? (raw-value (isOdd 1)) #t)
  )

  (test-case "R64_MR03 mutual recursion - isEven 10 is True"
  (check-equal? (raw-value (isEven 10)) #t)
  )

  (test-case "R64_MR04 mutual recursion - isOdd 7 is True"
  (check-equal? (raw-value (isOdd 7)) #t)
  )

  (test-case "R64_MR05 mutual recursion - isEven 3 is False"
  (check-equal? (raw-value (isEven 3)) #f)
  )

  (test-case "R64_FA01 3-level ForAll filter chain: correct count"
  (define xs (list 100 60 5 80 15 200 2 55))
  (define r (threeLayerFilter xs))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R64_FA02 3-level ForAll chain with empty input gives 0"
  (define xs (list))
  (define r (threeLayerFilter xs))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R64_FA03 ForAll list built from 3-level filter usable as proof parameter"
  (define verified (buildVerifiedForAll))
  (define r (processForAllList verified))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R64_FA04 List.emptyForAll produces valid empty ForAll list for use as parameter"
  (define empty (tesl_import_List_emptyForAll checkPos))
  (define r (countPositive empty))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R64_FA05 List.allCheck returns Nothing when any element fails"
  (define xs (list 1 2 0 4))
  (define result (tesl_import_List_allCheck checkPos (raw-value xs)))
  (let ([*tesl_case_26 (raw-value 
    result)]) (cond
    [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Nothing))
      (check-equal? 1 1)
    ]
    [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Something))
      (check-equal? 0 1)
    ]
  ))
  )

  (test-case "R64_FA06 List.allCheck returns Something when all pass"
  (define xs (list 1 2 3 4))
  (define result (tesl_import_List_allCheck checkPos (raw-value xs)))
  (let ([*tesl_case_27 (raw-value 
    result)]) (cond
    [(and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Nothing))
      (check-equal? 0 1)
    ]
    [(and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Something))
      (let ([ys (hash-ref (adt-value-fields *tesl_case_27) 'value)])
        (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value ys)))) 4)
      )
    ]
  ))
  )

  (test-case "R64_SC01 String.trim produces IsTrimmed proof usable by consumer"
  (define raw "  hello  ")
  (define trimmed (tesl_import_String_trim (raw-value raw)))
  (define r (needsTrimmed trimmed))
  (check-equal? (raw-value r) "hello")
  )

  (test-case "R64_SC02 String.toUpper produces IsUpperCase proof usable by consumer"
  (define raw "hello")
  (define upper (tesl_import_String_toUpper (raw-value raw)))
  (define r (needsUpper upper))
  (check-equal? (raw-value r) "HELLO")
  )

  (test-case "R64_SC03 List.sort produces IsSorted proof usable by consumer"
  (define xs (list 5 2 8 1 9 3))
  (define sorted (tesl_import_List_sort (raw-value xs)))
  (define r (needsSorted sorted))
  (define len (raw-value (tesl_import_List_length (raw-value r))))
  (check-equal? (raw-value len) 6)
  )

  (test-case "R64_SC04 Int.nonZero check enables Int.divide"
  (define a 100)
  (define b 7)
  (define tesl_checked_28 (tesl_import_Int_nonZero b))
  (when (check-fail? tesl_checked_28)
    (raise-user-error 'tesl-test "unexpected failure in let nz: ~a" (check-fail-message tesl_checked_28)))
  (define nz tesl_checked_28)
  (define r (tesl_import_Int_divide (raw-value a) nz))
  (check-equal? (raw-value r) 14)
  )

  (test-case "R64_SC05 Int.nonZero check fails for zero denominator"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((raw-value (tesl_import_Int_nonZero 0)) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (tesl_import_Int_nonZero 0)) (list)"))
  )

  (test-case "R64_SC06 Float.requireNonZero enables Float.div"
  (define a 10.)
  (define b 4.)
  (define tesl_checked_29 (tesl_import_Float_requireNonZero b))
  (when (check-fail? tesl_checked_29)
    (raise-user-error 'tesl-test "unexpected failure in let nz: ~a" (check-fail-message tesl_checked_29)))
  (define nz tesl_checked_29)
  (define r (raw-value (tesl_import_Float_div (raw-value a) nz)))
  (check-equal? (raw-value r) 2.5)
  )

  (test-case "R64_SC07 Int.nonNegative check works for zero"
  (define n 0)
  (define tesl_checked_30 (tesl_import_Int_nonNegative n))
  (when (check-fail? tesl_checked_30)
    (raise-user-error 'tesl-test "unexpected failure in let nn: ~a" (check-fail-message tesl_checked_30)))
  (define nn tesl_checked_30)
  (check-equal? (raw-value nn) 0)
  )

  (test-case "R64_SC08 Int.nonNegative fails for negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((raw-value (tesl_import_Int_nonNegative -1)) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (tesl_import_Int_nonNegative -1)) (list)"))
  )

  (test-case "R64_SC09 Float.requireNonZero fails for zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((raw-value (tesl_import_Float_requireNonZero 0.)) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (tesl_import_Float_requireNonZero 0.)) (list)"))
  )

  (test-case "R64_AN01 andLeft extracts A proof from introAnd(A,B) result"
  (define r (decomposeViaAndLeft 42))
  (check-equal? (raw-value r) 42)
  )

  (test-case "R64_AN02 andRight extracts B proof from introAnd(A,B) result"
  (define r (decomposeViaAndRight 99))
  (check-equal? (raw-value r) 99)
  )

  (test-case "R64_AN03 both andLeft and andRight work on same conjunction"
  (define r (useBothParts 5))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R64_IN01 introAnd same-subject produces usable A && B conjunction"
  (define n 77)
  (define pa (proveA n))
  (define pb (proveB n))
  (define ab (intro-and pa pb))
  (define withProof (attach-proof n ab))
  (define r (needsAB withProof))
  (check-equal? (raw-value r) 77)
  )

  (test-case "R64_IN02 introAnd chained for 3 same-subject proofs"
  (define n 11)
  (define pa (proveA n))
  (define pb (proveB n))
  (define pc (proveC n))
  (define ab (intro-and pa pb))
  (define abc (intro-and ab pc))
  (define withProof (attach-proof n abc))
  (define r (needsABC withProof))
  (check-equal? (raw-value r) 11)
  )

  (test-case "R64_RR01 record field proof round-trip: construction + field access preserves proof"
  (define rawTitle "My Document")
  (define doc (makeDoc rawTitle 500))
  (define r (readTitle doc))
  (check-equal? (raw-value r) "My Document")
  )

  (test-case "R64_RR02 record construction fails when field check fails"
  (define rawTitle "")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((makeDoc rawTitle 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (makeDoc rawTitle 0) (list)"))
  )

  (test-case "R64_RR03 record update preserves proof on non-updated proof-annotated field"
  (define rawTitle "Updated Doc")
  (define r (readUpdatedTitle rawTitle 100))
  (check-equal? (raw-value r) "Updated Doc")
  )

  (test-case "R64_XP01 combined check && on single value succeeds when both pass"
  (define r (applyCombined 42))
  (check-equal? (raw-value r) 42)
  )

  (test-case "R64_XP02 combined check && fails when first check fails (negative)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((applyCombined -1) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (applyCombined -1) (list)"))
  )

  (test-case "R64_XP03 combined check && fails when second check fails (too big)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((applyCombined 999) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (applyCombined 999) (list)"))
  )

  (test-case "R64_XP04 combined check in filterCheck produces correct ForAll"
  (define xs (list 0 5 15 100 3))
  (define filtered (filterActivePinnedDirect xs))
  (define r (raw-value (tesl_import_List_length (raw-value filtered))))
  (check-equal? (raw-value r) 2)
  )

  (test-case "R64_LI01 literal-parametrized predicate HasMin 10 works on single value"
  (define n 15)
  (define tesl_checked_31 (checkMin10 n))
  (when (check-fail? tesl_checked_31)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl_checked_31)))
  (define p tesl_checked_31)
  (define r (needAbove10 p))
  (check-equal? (raw-value r) 15)
  )

  (test-case "R64_LI02 literal-parametrized predicate HasMin 20 is distinct from HasMin 10"
  (define n 25)
  (define tesl_checked_32 (checkMin20 n))
  (when (check-fail? tesl_checked_32)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl_checked_32)))
  (define p tesl_checked_32)
  (define r (needAbove20 p))
  (check-equal? (raw-value r) 25)
  )

  (test-case "R64_LI03 literal-parametrized conjunction HasMin 10 && HasMax 100"
  (define n 50)
  (define tesl_checked_33 (checkMin10 n))
  (when (check-fail? tesl_checked_33)
    (raise-user-error 'tesl-test "unexpected failure in let lo: ~a" (check-fail-message tesl_checked_33)))
  (define lo tesl_checked_33)
  (define tesl_checked_34 (checkMax100 lo))
  (when (check-fail? tesl_checked_34)
    (raise-user-error 'tesl-test "unexpected failure in let hi: ~a" (check-fail-message tesl_checked_34)))
  (define hi tesl_checked_34)
  (define r (needBothBounds hi))
  (check-equal? (raw-value r) 50)
  )

  (test-case "R64_LI04 HasMin 10 check fails for value below threshold"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((raw-value (checkMin10 5)) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkMin10 5)) (list)"))
  )

  (test-case "R64_LI05 HasMax 100 check fails for value above threshold"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((raw-value (checkMax100 150)) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkMax100 150)) (list)"))
  )

  (test-case "R64_LI06 ForAll (HasMin 10) from filterCheck matches parameter annotation"
  (define xs (list 5 10 15 20 3))
  (define filtered (filterAbove10 xs))
  (define r (needForAllAbove10 filtered))
  (check-equal? (raw-value r) 3)
  )

  (test-case "R64_LI07 ForAll (HasMin 20) is distinct from ForAll (HasMin 10)"
  (define xs (list 15 25 30))
  (define filtered (filterAbove20 xs))
  (define r (needForAllAbove20 filtered))
  (check-equal? (raw-value r) 2)
  )

  (test-case "R64_LI08 ForAll (HasMin 10) correctly keeps only values >= 10"
  (define xs (list 1 2 9 10 11 100))
  (define filtered (filterAbove10 xs))
  (define r (needForAllAbove10 filtered))
  (check-equal? (raw-value r) 3)
  )

  (test-case "R64_LI09 ForAll (HasMin 20) from empty input"
  (define xs (list 1 5 15))
  (define filtered (filterAbove20 xs))
  (define r (needForAllAbove20 filtered))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R64_NT01 newtype UserId and ProjectId are distinct nominal types"
  (define rawUser "user-abc")
  (define rawProject "proj-xyz")
  (define uid (raw-value (UserId (raw-value rawUser))))
  (define pid (raw-value (ProjectId (raw-value rawProject))))
  (define tesl_checked_35 (checkUser uid))
  (when (check-fail? tesl_checked_35)
    (raise-user-error 'tesl-test "unexpected failure in let vu: ~a" (check-fail-message tesl_checked_35)))
  (define vu tesl_checked_35)
  (define tesl_checked_36 (checkProject pid))
  (when (check-fail? tesl_checked_36)
    (raise-user-error 'tesl-test "unexpected failure in let vp: ~a" (check-fail-message tesl_checked_36)))
  (define vp tesl_checked_36)
  (define r1 (needsValidUser vu))
  (define r2 (needsValidProject vp))
  (check-equal? (raw-value r1) "user-abc")
  (check-equal? (raw-value r2) "proj-xyz")
  )

  (test-case "R64_NT02 newtype .value field unwraps to base type"
  (define raw "hello")
  (define uid (raw-value (UserId (raw-value raw))))
  (check-equal? (raw-value (tesl-dot/runtime uid 'value)) "hello")
  )

  (test-case "R64_NT03 two newtypes over String wrapping same raw value are distinct"
  (define raw "same-raw")
  (define uid (raw-value (UserId (raw-value raw))))
  (define pid (raw-value (ProjectId (raw-value raw))))
  (check-equal? (raw-value (tesl-dot/runtime uid 'value)) (raw-value (tesl-dot/runtime pid 'value)))
  )

)
