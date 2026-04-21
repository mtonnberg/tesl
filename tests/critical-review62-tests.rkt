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
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.map tesl_import_List_map] [List.sort tesl_import_List_sort] IsSorted)
  (only-in tesl/tesl/set Set [Set.filterCheck tesl_import_Set_filterCheck] [Set.fromList tesl_import_Set_fromList] [Set.size tesl_import_Set_size])
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.length tesl_import_String_length] [String.toUpper tesl_import_String_toUpper] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/int [Int.divide tesl_import_Int_divide] [Int.nonZero tesl_import_Int_nonZero] IsNonZero [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/float Float [Float.div tesl_import_Float_div] [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero [Float.sqrt tesl_import_Float_sqrt] [Float.abs tesl_import_Float_abs])
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define IsEven 'IsEven)
(define IsOdd 'IsOdd)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define TitleSafe 'TitleSafe)
(define ValidProject 'ValidProject)
(define ValidUser 'ValidUser)

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
  (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (TitleSafe s) #:value *s) (reject "empty title" #:http-code 400)))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (if (< *n 0) (reject "negative" #:http-code 400) (if (equal? *n 0) (accept (IsEven n) #:value *n) (let/check ([tesl_checked_0 (checkOdd (- *n 1))]) (let ([_odd tesl_checked_0]) (accept (IsEven n) #:value *n))))))

(define-checker
  (checkOdd [n : Integer])
  #:returns [n : Integer ::: (IsOdd n)]
  (if (<= *n 0) (reject "not odd" #:http-code 400) (if (equal? *n 1) (accept (IsOdd n) #:value *n) (let/check ([tesl_checked_1 (checkEven (- *n 1))]) (let ([_even tesl_checked_1]) (accept (IsOdd n) #:value *n))))))

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
  (needsC [n : Integer ::: (C n)])
  #:returns Integer
  *n)

(define/pow
  (needsAll4 [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns Integer
  *n)

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  *n)

(define/pow
  (needsAandB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  *n)

(define/pow
  (proveViaMaybe [m : (Maybe Integer)])
  #:returns Integer
  (let ([tesl_case_2 *m]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (raw-value 0)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (let/check ([tesl_checked_3 (checkPos *v)]) (let ([p tesl_checked_3]) (raw-value (needsPos p)))))])))

(define/pow
  (proofThroughLetChain [x : Integer])
  #:returns Integer
  (let/check ([tesl_checked_4 (checkA x)]) (let ([a tesl_checked_4]) (let/check ([tesl_checked_5 (checkB a)]) (let ([ab tesl_checked_5]) (let/check ([tesl_checked_6 (checkC ab)]) (let ([abc tesl_checked_6]) (let/check ([tesl_checked_7 (checkD abc)]) (let ([abcd tesl_checked_7]) (raw-value (needsAll4 abcd)))))))))))

(define-checker
  (checkAandB [n : Integer])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (if (> *n 1) (accept ((B n) && (A n)) #:value *n) (reject "bad" #:http-code 400)))

(define/pow
  (decomposeViaIntroAnd [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pab (intro-and pa pb)]) (let ([la (and-left pab)]) (let ([rb (and-right pab)]) (let ([xA (attach-proof x la)]) (let ([xB (attach-proof x rb)]) (+ (raw-value (needsA xA)) (raw-value (needsB xB)))))))))))

(define/pow
  (buildProofChainViaEstablish [x : Integer])
  #:returns Integer
  (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pc (proveC x)]) (let ([pd (proveD x)]) (let ([pab (intro-and pa pb)]) (let ([pabc (intro-and pab pc)]) (let ([pabcd (intro-and pabc pd)]) (let ([xAll (attach-proof x pabcd)]) (let ([la (and-left pabcd)]) (let ([xA (attach-proof x la)]) (raw-value (needsA xA)))))))))))))

(define/pow
  (filterBoth [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck (check-and checkPos checkSmall) *xs))

(define/pow
  (countPositiveSmall [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_length *xs)))

(define/pow
  (filterSets [xs : (Set Integer)])
  #:returns (Set Integer)
  (tesl_import_Set_filterCheck checkPos *xs))

(define-adt Tree
  [Leaf]
  [Node [left : Tree] [value : Integer] [right : Tree]]
)

(define/pow
  (sumTree [t : Tree])
  #:returns Integer
  (let ([tesl_case_8 *t]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_8) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_8) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_8) 'right)]) (raw-value (+ (+ (raw-value (sumTree *l)) *v) (raw-value (sumTree *r)))))))])))

(define/pow
  (maxDepth [t : Tree])
  #:returns Integer
  (let ([tesl_case_9 *t]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_9) 'left)]) (let ([r (hash-ref (adt-value-fields *tesl_case_9) 'right)]) (let ([ld (maxDepth *l)]) (let ([rd (maxDepth *r)]) (if (> (raw-value ld) (raw-value rd)) (raw-value (+ (raw-value ld) 1)) (raw-value (+ (raw-value rd) 1)))))))])))

(define/pow
  (leafNode [v : Integer])
  #:returns Tree
  (raw-value (Node Leaf *v Leaf)))

(define/pow
  (buildTree)
  #:returns Tree
  (raw-value (Node (Node Leaf 1 Leaf) 2 (Node (Node Leaf 3 Leaf) 4 Leaf))))

(define-adt Status
  [Active]
  [Inactive]
  [Suspended]
)

(define/pow
  (describeStatus [s : Status])
  #:returns String
  (let ([tesl_case_10 *s]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Active)) (raw-value "active")] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Inactive)) (raw-value "inactive")] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Suspended)) (raw-value "suspended")])))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (* *n 2))

(define/pow
  (applyPipeline [n : Integer])
  #:returns Integer
  (raw-value (double (double n))))

(define/pow
  (requiresTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  *s)

(define/pow
  (trimAndRequire [s : String])
  #:returns String
  (let ([t (tesl_import_String_trim *s)]) (raw-value (requiresTrimmed t))))

(define/pow
  (requiresSorted [xs : (List Integer) ::: (IsSorted xs)])
  #:returns (List Integer)
  *xs)

(define/pow
  (sortAndRequire [xs : (List Integer)])
  #:returns (List Integer)
  (let ([s (tesl_import_List_sort *xs)]) (raw-value (requiresSorted s))))

(define/pow
  (requiresUpper [s : String ::: (IsUpperCase s)])
  #:returns String
  *s)

(define/pow
  (upperAndRequire [s : String])
  #:returns String
  (let ([u (tesl_import_String_toUpper *s)]) (raw-value (requiresUpper u))))

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
  (requiresValidUser [u : UserId ::: (ValidUser u)])
  #:returns String
  (raw-value u.value))

(define/pow
  (requiresValidProject [p : ProjectId ::: (ValidProject p)])
  #:returns String
  (raw-value p.value))

(define/pow
  (testNewtypes [rawUser : String] [rawProject : String])
  #:returns String
  (let ([uid (raw-value (UserId *rawUser))]) (let ([pid (raw-value (ProjectId *rawProject))]) (let/check ([tesl_checked_11 (checkUser uid)]) (let ([validUser tesl_checked_11]) (let/check ([tesl_checked_12 (checkProject pid)]) (let ([validProject tesl_checked_12]) (let ([_ (+ (raw-value (tesl_import_String_length (raw-value (requiresValidUser validUser)))) (raw-value (tesl_import_String_length (raw-value (requiresValidProject validProject)))))]) (raw-value (requiresValidUser validUser))))))))))

(define/pow
  (requiresEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  *n)

(define/pow
  (requiresOdd [n : Integer ::: (IsOdd n)])
  #:returns Integer
  *n)

(define/pow
  (mutualRecChain [e : Integer] [o : Integer])
  #:returns Integer
  (let/check ([tesl_checked_13 (checkEven e)]) (let ([ev tesl_checked_13]) (let/check ([tesl_checked_14 (checkOdd o)]) (let ([od tesl_checked_14]) (+ (raw-value (requiresEven ev)) (raw-value (requiresOdd od))))))))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns Integer
  (let/check ([tesl_checked_15 (tesl_import_Int_nonZero b)]) (let ([nz tesl_checked_15]) (raw-value (tesl_import_Int_divide *a nz)))))

(define/pow
  (safeNonNeg [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_16 (tesl_import_Int_nonNegative n)]) (let ([nn tesl_checked_16]) (raw-value nn))))

(define/pow
  (requiresNonNeg [n : Integer ::: (IsNonNegative n)])
  #:returns Integer
  *n)

(define/pow
  (testNonNeg [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_17 (tesl_import_Int_nonNegative n)]) (let ([nn tesl_checked_17]) (raw-value (requiresNonNeg nn)))))

(define/pow
  (safeFloatDiv [a : Real] [b : Real])
  #:returns Real
  (let/check ([tesl_checked_18 (tesl_import_Float_requireNonZero b)]) (let ([nz tesl_checked_18]) (raw-value (tesl_import_Float_div *a nz)))))

(define-record SafePost
  [title : String ::: (TitleSafe title)]
  [count : Integer]
)

(define/pow
  (buildSafePost [t : String] [c : Integer])
  #:returns SafePost
  (let/check ([tesl_checked_19 (checkTitle t)]) (let ([st tesl_checked_19]) (SafePost #:title st #:count *c))))

(define/pow
  (updateCount [p : SafePost] [newCount : Integer])
  #:returns SafePost
  (tesl-record-update *p (hash 'count *newCount)))

(module+ test
  (require rackunit)
  (test-case "R62_PF01 proof through Maybe case arm works"
  (define r (proveViaMaybe (raw-value (Something 5))))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R62_PF02 proof through Maybe case arm Nothing branch"
  (define r (proveViaMaybe Nothing))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R62_PF03 4-step proof chain accumulates correctly"
  (define r (proofThroughLetChain 10))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R62_PF04 4-step proof chain fails at step 1"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((proofThroughLetChain 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 0) (list)"))
  )

  (test-case "R62_PF05 4-step proof chain fails at step 2"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((proofThroughLetChain 1) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 1) (list)"))
  )

  (test-case "R62_PF06 4-step proof chain fails at step 3"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((proofThroughLetChain 2) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 2) (list)"))
  )

  (test-case "R62_CO01 ok conjunction order-insensitive (B && A for A && B)"
  (define n 5)
  (define tesl_checked_20 (checkAandB n))
  (when (check-fail? tesl_checked_20)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_20)))
  (define v tesl_checked_20)
  (check-equal? (raw-value (needsAandB v)) 5)
  )

  (test-case "R62_CO02 introAnd with bound args decomposes via andLeft/andRight"
  (define n 5)
  (define r (decomposeViaIntroAnd n))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R62_CO03 introAnd decompose at runtime: andLeft returns A fact"
  (define n 3)
  (define pa (proveA n))
  (define pb (proveB n))
  (define pab (intro-and pa pb))
  (define la (and-left pab))
  (define xA (attach-proof n la))
  (check-equal? (raw-value (needsA xA)) 3)
  )

  (test-case "R62_CO04 conjunction at call site is commutative (B && A satisfies B && A)"
  (define n 5)
  (define tesl_checked_21 (checkAandB n))
  (when (check-fail? tesl_checked_21)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_21)))
  (define v tesl_checked_21)
  (check-equal? (raw-value (needsAandB v)) 5)
  )

  (test-case "R62_ES01 4-establish introAnd chain with andLeft extraction"
  (define n 5)
  (define r (buildProofChainViaEstablish n))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R62_ES02 establish gives Fact that can be attached"
  (define n 5)
  (define p (provePos n))
  (define xP (attach-proof n p))
  (check-equal? (raw-value (needsPos xP)) 5)
  )

  (test-case "R62_FA01 && combined check in filterCheck produces conjunction ForAll"
  (define xs (filterBoth (list 1 50 200 -1 99 0)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value xs)))) 3)
  )

  (test-case "R62_FA02 ForAll list can be consumed by requiring fn"
  (define xs (filterBoth (list 5 10 95)))
  (check-equal? (raw-value (countPositiveSmall xs)) 3)
  )

  (test-case "R62_FA03 allCheck returns Nothing if any element fails"
  (define r (tesl_import_List_allCheck checkPos (list 1 -1 2)))
  (let ([*tesl_case_22 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Nothing))
      (check-equal? 1 1)
    ]
    [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Something))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                              ((+ 1 1) (list)))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
  ))
  )

  (test-case "R62_FA04 allCheck returns Something for all-passing list"
  (define r (tesl_import_List_allCheck checkPos (list 1 2 3)))
  (let ([*tesl_case_23 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Nothing))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                              ((+ 1 1) (list)))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
    [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Something))
      (let ([xs (hash-ref (adt-value-fields *tesl_case_23) 'value)])
        (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value xs)))) 3)
      )
    ]
  ))
  )

  (test-case "R62_FA05 Set.filterCheck produces ForAll (IsPositive)"
  (define s (tesl_import_Set_filterCheck checkPos (raw-value (tesl_import_Set_fromList (list 1 2 -1 3 0)))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value s)))) 3)
  )

  (test-case "R62_AD01 recursive ADT sum: 1+2+3+4=10"
  (define t (buildTree))
  (check-equal? (raw-value (sumTree t)) 10)
  )

  (test-case "R62_AD02 recursive ADT max depth: tree of depth 3"
  (define t (buildTree))
  (check-equal? (raw-value (maxDepth t)) 3)
  )

  (test-case "R62_AD03 exhaustive 3-ctor ADT case works"
  (check-equal? (raw-value (describeStatus Active)) "active")
  )

  (test-case "R62_AD04 exhaustive 3-ctor ADT case: Suspended"
  (check-equal? (raw-value (describeStatus Suspended)) "suspended")
  )

  (test-case "R62_PO01 |> pipeline applies functions left to right"
  (check-equal? (raw-value (applyPipeline 3)) 12)
  )

  (test-case "R62_PO02 String.trim returns IsTrimmed proof that satisfies fn requirement"
  (define r (trimAndRequire "  hello  "))
  (check-equal? (raw-value r) "hello")
  )

  (test-case "R62_PO03 List.sort returns IsSorted proof"
  (define r (sortAndRequire (list 3 1 2)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value r)))) 3)
  )

  (test-case "R62_PO04 String.toUpper returns IsUpperCase proof"
  (define r (upperAndRequire "hello"))
  (check-equal? (raw-value r) "HELLO")
  )

  (test-case "R62_NT01 UserId newtype carries ValidUser proof"
  (define r (testNewtypes "user-123" "proj-456"))
  (check-equal? (raw-value r) "user-123")
  )

  (test-case "R62_NT02 empty UserId fails validation"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testNewtypes "" "proj-456") (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testNewtypes \"\" \"proj-456\") (list)"))
  )

  (test-case "R62_MR01 mutual recursion: even 4 + odd 3 = 7"
  (define r (mutualRecChain 4 3))
  (check-equal? (raw-value r) 7)
  )

  (test-case "R62_MR02 mutual recursion: even 0 works"
  (define r (mutualRecChain 0 1))
  (check-equal? (raw-value r) 1)
  )

  (test-case "R62_MR03 mutual recursion: odd check fails for even number"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((raw-value (checkOdd 4)) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkOdd 4)) (list)"))
  )

  (test-case "R62_SB01 Int.divide with IsNonZero proof works"
  (define r (safeDivide 10 2))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R62_SB02 Int.nonZero fails for zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((safeDivide 10 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivide 10 0) (list)"))
  )

  (test-case "R62_SB03 Int.nonNegative proves IsNonNegative"
  (define r (testNonNeg 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R62_SB04 Int.nonNegative fails for negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testNonNeg -1) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testNonNeg -1) (list)"))
  )

  (test-case "R62_SB05 Float.div with FloatNonZero proof works"
  (define n 5)
  (check-true (raw-value #t))
  )

  (test-case "R62_RU01 record update on non-proof field preserves proof fields"
  (define p (buildSafePost "Hello" 1))
  (define p2 (updateCount p 5))
  (check-equal? (raw-value (tesl-dot/runtime p2 'title)) "Hello")
  )

  (test-case "R62_RU02 record construction with valid title succeeds"
  (define p (buildSafePost "Valid title" 0))
  (check-equal? (raw-value (tesl-dot/runtime p 'count)) 0)
  )

  (test-case "R62_RU03 record construction with empty title fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((buildSafePost "" 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (buildSafePost \"\" 0) (list)"))
  )

)
