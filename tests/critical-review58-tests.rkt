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
  (only-in tesl/tesl/prelude Bool Int String List Fact forgetFact attachFact detachFact introAnd andLeft andRight)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either Either Left Right)
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.length tesl_import_List_length] [List.allCheck tesl_import_List_allCheck] [List.emptyForAll tesl_import_List_emptyForAll])
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define F 'F)
(define G 'G)
(define InBounds 'InBounds)
(define IsEven 'IsEven)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define OwnedBy 'OwnedBy)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (if (> *n 0) (accept (A n) #:value *n) (reject "fail A" #:http-code 400)))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: (B n)]
  (if (< *n 1000) (accept (B n) #:value *n) (reject "fail B" #:http-code 400)))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: (C n)]
  (if (not (equal? *n 42)) (accept (C n) #:value *n) (reject "fail C" #:http-code 400)))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: (D n)]
  (if (not (equal? *n 99)) (accept (D n) #:value *n) (reject "fail D" #:http-code 400)))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: (E n)]
  (if (not (equal? *n 500)) (accept (E n) #:value *n) (reject "fail E" #:http-code 400)))

(define-checker
  (checkF [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns [n : Integer ::: (F n)]
  (if (not (equal? *n 777)) (accept (F n) #:value *n) (reject "fail F" #:http-code 400)))

(define-checker
  (checkG [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n))))))])
  #:returns [n : Integer ::: (G n)]
  (accept (G n) #:value *n))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (if (equal? (remainder *n 2) 0) (accept (IsEven n) #:value *n) (reject "not even" #:http-code 400)))

(define-checker
  (checkInBounds [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InBounds lo hi n)]
  (if (and (>= *n *lo) (<= *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))

(define-checker
  (checkOwned [userId : String] [taskId : Integer])
  #:returns [taskId : Integer ::: (OwnedBy userId taskId)]
  (if #t (accept (OwnedBy userId taskId) #:value *taskId) (reject "not owned" #:http-code 403)))

(define-trusted
  (makeA [n : Integer])
  #:returns (Fact (A n))
  (trusted-proof (A n)))

(define-trusted
  (makeB [n : Integer])
  #:returns (Fact (B n))
  (trusted-proof (B n)))

(define-trusted
  (makeG [n : Integer])
  #:returns (Fact (G n))
  (trusted-proof (G n)))

(define/pow
  (needsAll7 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && ((F n) && (G n)))))))])
  #:returns Integer
  *n)

(define/pow
  (needsAB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  *n)

(define/pow
  (needsBA [n : Integer ::: ((B n) && (A n))])
  #:returns Integer
  *n)

(define/pow
  (needsCBA [n : Integer ::: ((C n) && ((B n) && (A n)))])
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
  (needsEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  *n)

(define/pow
  (needsBothPS [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  *n)

(define/pow
  (needsForAllPos [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (needsForAllBoth [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (needsInBounds [lo : Integer] [hi : Integer] [n : Integer ::: (InBounds lo hi n)])
  #:returns Integer
  *n)

(define/pow
  (needsOwned [userId : String] [task : Integer ::: (OwnedBy userId task)])
  #:returns Integer
  *task)

(define/pow
  (testCommutativeAB [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (checkA n)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkB a)]) (let ([ab tesl_checked_1]) (raw-value (needsBA ab)))))))

(define/pow
  (testCommutativeDeep [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_2 (checkA n)]) (let ([a tesl_checked_2]) (let/check ([tesl_checked_3 (checkB a)]) (let ([b tesl_checked_3]) (let/check ([tesl_checked_4 (checkC b)]) (let ([c tesl_checked_4]) (raw-value (needsCBA c)))))))))

(define/pow
  (build7ProofChain [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_5 (checkA raw)]) (let ([a tesl_checked_5]) (let/check ([tesl_checked_6 (checkB a)]) (let ([b tesl_checked_6]) (let/check ([tesl_checked_7 (checkC b)]) (let ([c tesl_checked_7]) (let/check ([tesl_checked_8 (checkD c)]) (let ([d tesl_checked_8]) (let/check ([tesl_checked_9 (checkE d)]) (let ([e tesl_checked_9]) (let/check ([tesl_checked_10 (checkF e)]) (let ([f tesl_checked_10]) (let/check ([tesl_checked_11 (checkG f)]) (let ([g tesl_checked_11]) (raw-value (needsAll7 g)))))))))))))))))

(define-checker
  (checkA4 [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (if (> *n 0) (accept (A n) #:value *n) (reject "fail" #:http-code 400)))

(define-checker
  (checkB4 [n : Integer])
  #:returns [n : Integer ::: (B n)]
  (if (< *n 1000) (accept (B n) #:value *n) (reject "fail" #:http-code 400)))

(define-checker
  (checkC4 [n : Integer])
  #:returns [n : Integer ::: (C n)]
  (if (not (equal? *n 42)) (accept (C n) #:value *n) (reject "fail" #:http-code 400)))

(define-checker
  (checkD4 [n : Integer])
  #:returns [n : Integer ::: (D n)]
  (if (not (equal? *n 99)) (accept (D n) #:value *n) (reject "fail" #:http-code 400)))

(define/pow
  (needs4 [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns Integer
  *n)

(define/pow
  (check4Combined [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_12 ((check-and checkA4 (check-and checkB4 (check-and checkC4 checkD4))) n)]) (let ([validated tesl_checked_12]) (raw-value (needs4 validated)))))

(define/pow
  (filterBoth [nums : (List Integer)])
  #:returns Integer
  (let ([filtered (tesl_import_List_filterCheck (check-and checkPos checkSmall) *nums)]) (raw-value (needsForAllBoth filtered))))

(define/pow
  (allCheckCombined58 [nums : (List Integer)])
  #:returns (Maybe (List Integer))
  (tesl_import_List_allCheck (check-and checkPos checkSmall) *nums))

(define/pow
  (detachAndReattach [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_13 (checkPos n)]) (let ([proven tesl_checked_13]) (let ([raw (forget-proof proven)]) (let ([pf (detach-all-proof proven)]) (let ([back (attach-proof raw pf)]) (raw-value (needsPos back))))))))

(define/pow
  (introAndTest [n : Integer])
  #:returns Integer
  (let ([pA (makeA n)]) (let ([pB (makeB n)]) (let ([pAB (intro-and pA pB)]) (let ([proven (attach-proof n pAB)]) (raw-value (needsAB proven)))))))

(define/pow
  (andDecomposeTest [n : Integer])
  #:returns Integer
  (let ([pA (makeA n)]) (let ([pB (makeB n)]) (let ([pAB (intro-and pA pB)]) (let ([pA2 (and-left pAB)]) (let ([pB2 (and-right pAB)]) (let ([pRebuilt (intro-and pA2 pB2)]) *n)))))))

(define/pow
  (testInBounds [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_14 (checkInBounds 1 10 n)]) (let ([v tesl_checked_14]) (raw-value (needsInBounds 1 10 v)))))

(define/pow
  (testOwnership [userId : String] [taskId : Integer])
  #:returns Integer
  (let/check ([tesl_checked_15 (checkOwned userId taskId)]) (let ([ownedTask tesl_checked_15]) (raw-value (needsOwned userId ownedTask)))))

(define-trusted
  (alwaysProveA [n : Integer])
  #:returns (Fact (A n))
  (trusted-proof (A n)))

(define/pow
  (useEstablishFreedom [n : Integer])
  #:returns Integer
  (let ([pA (alwaysProveA n)]) (let ([proven (attach-proof n pA)]) (let ([raw proven]) raw))))

(define-adt Color
  [Red]
  [Green]
  [Blue]
)

(define/pow
  (describeColor [c : Color])
  #:returns String
  (let ([tesl_case_16 *c]) (cond [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Red)) (raw-value "red")] [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Green)) (raw-value "green")] [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Blue)) (raw-value "blue")])))

(define/pow
  (describeColorSafe [c : Color])
  #:returns String
  (let ([tesl_case_17 *c]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Red)) (raw-value "red")] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Green)) (raw-value "green")] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Blue)) (raw-value "blue")])))

(define/pow
  (seqFilterAccumulated [nums : (List Integer)])
  #:returns Integer
  (let ([pos (tesl_import_List_filterCheck checkPos *nums)]) (let ([posSmall (tesl_import_List_filterCheck checkSmall (raw-value pos))]) (raw-value (needsForAllBoth posSmall)))))

(module+ test
  (require rackunit)
  (test-case "R58_CJ01 proof conjunction is commutative (A&&B satisfies B&&A)"
  (define result (testCommutativeAB 5))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R58_CJ02 deep conjunction commutativity (A&&B&&C satisfies C&&B&&A)"
  (define result (testCommutativeDeep 5))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R58_CH01 7-proof sequential chain works correctly"
  (define result (build7ProofChain 5))
  (check-equal? (raw-value result) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (build7ProofChain 42))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 42"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (build7ProofChain 99))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 99"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (build7ProofChain 500))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 500"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (build7ProofChain 777))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 777"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (build7ProofChain 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (build7ProofChain 1001))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 1001"))
  )

  (test-case "R58_AND01 4-check && chain proves all 4 simultaneously"
  (define result (check4Combined 5))
  (check-equal? (raw-value result) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (check4Combined 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check4Combined 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (check4Combined 42))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check4Combined 42"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (check4Combined 99))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check4Combined 99"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (check4Combined 1500))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check4Combined 1500"))
  )

  (test-case "R58_FA01 combined filterCheck produces ForAll (P && Q) proof"
  (check-equal? (raw-value (filterBoth (list 1 50 200 -3 80))) 3)
  (check-equal? (raw-value (filterBoth (list))) 0)
  (check-equal? (raw-value (filterBoth (list -1 -2 -3))) 0)
  (check-equal? (raw-value (filterBoth (list 200 300 400))) 0)
  (check-equal? (raw-value (filterBoth (list 50 99 1))) 3)
  )

  (test-case "R58_AC01 allCheck with named return type preserves ForAll via let"
  (define m1 (allCheckCombined58 (list 5 10 50)))
  (let ([*tesl_case_18 (raw-value 
    m1)]) (cond
    [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Nothing))
      (check-true (raw-value #f))
    ]
    [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Something))
      (let ([r (hash-ref (adt-value-fields *tesl_case_18) 'value)])
        (check-equal? (raw-value (needsForAllBoth r)) 3)
      )
    ]
  ))
  (define m2 (allCheckCombined58 (list 5 200 10)))
  (let ([*tesl_case_19 (raw-value 
    m2)]) (cond
    [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Nothing))
      (check-true (raw-value #t))
    ]
    [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Something))
      (check-true (raw-value #f))
    ]
  ))
  (define m3 (allCheckCombined58 (list)))
  (let ([*tesl_case_20 (raw-value 
    m3)]) (cond
    [(and (adt-value? *tesl_case_20) (eq? (adt-value-variant *tesl_case_20) 'Nothing))
      (check-true (raw-value #f))
    ]
    [(and (adt-value? *tesl_case_20) (eq? (adt-value-variant *tesl_case_20) 'Something))
      (let ([r (hash-ref (adt-value-fields *tesl_case_20) 'value)])
        (check-equal? (raw-value (needsForAllBoth r)) 0)
      )
    ]
  ))
  )

  (test-case "R58_DA01 detach and re-attach to same subject works"
  (define result (detachAndReattach 5))
  (check-equal? (raw-value result) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (detachAndReattach 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: detachAndReattach 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (detachAndReattach -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: detachAndReattach -1"))
  )

  (test-case "R58_IC01 introAnd combines Facts, attachFact applies combined proof"
  (define result (introAndTest 5))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R58_IC02 andLeft/andRight decompose correctly"
  (define result (andDecomposeTest 5))
  (check-equal? (raw-value result) 5)
  )

  (test-case "R58_MP01 multi-parameter proofs in correct order work"
  (check-equal? (raw-value (testInBounds 5)) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (testInBounds 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testInBounds 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (testInBounds 11))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testInBounds 11"))
  (check-equal? (raw-value (testOwnership "alice" 42)) 42)
  )

  (test-case "R58_ES01 establish is unconditional trusted boundary"
  (check-equal? (raw-value (useEstablishFreedom -5)) -5)
  (check-equal? (raw-value (useEstablishFreedom 0)) 0)
  (check-equal? (raw-value (useEstablishFreedom 999)) 999)
  )

  (test-case "R58_GC01 exhaustive case with all constructors covered"
  (check-equal? (raw-value (describeColor Red)) "red")
  (check-equal? (raw-value (describeColor Green)) "green")
  (check-equal? (raw-value (describeColor Blue)) "blue")
  )

  (test-case "R58_SF01 sequential filterCheck accumulates ForAll proofs (fixed)"
  (define result (seqFilterAccumulated (list -1 2 3 200 50)))
  (check-equal? (raw-value result) 3)
  )

  (test-case "R58_SF02 emptyForAll produces empty list satisfying ForAll"
  (define emptyPos (tesl_import_List_emptyForAll checkPos))
  (check-equal? (raw-value (needsForAllPos emptyPos)) 0)
  (define emptyBoth (tesl_import_List_emptyForAll (check-and checkPos checkSmall)))
  (check-equal? (raw-value (needsForAllBoth emptyBoth)) 0)
  )

)
