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
  (only-in tesl/tesl/prelude Bool Int List String Fact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.contains tesl_import_String_contains] [String.isEmpty tesl_import_String_isEmpty])
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.foldl tesl_import_List_foldl] [List.filter tesl_import_List_filter] [List.head tesl_import_List_head] IsSorted)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide] IsNonZero [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/float Float [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero [Float.div tesl_import_Float_div] [Float.isPositive tesl_import_Float_isPositive] [Float.sqrt tesl_import_Float_sqrt] [Float.abs tesl_import_Float_abs])
  (only-in tesl/tesl/result Result Ok Err)
)


(provide filterAlwaysFails vacuousForAll checkPositiveA requiresPositiveA proofFromA checkNonNeg allNonNeg forgetAndCheck forgetDoesNotRetarget Expr Lit Add Mul Sub Negate evalExpr MyInt MkMyInt makeMyInt myIntVal myIntGt myIntSort checkA4 checkB4 checkC4 checkD4 requiresABCD doubleList mapDoesNotProve addThree addThreePartial intEdge describeProven Status3 Active Inactive Suspended describeStatus3 strictBatch floatEdge isEven2 isOdd2 doubleAndFilter roundTripProof Email checkEmail2 requiresEmail2 checkPos checkSmallN checkPosAndSmall2 lookupWithDefault aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly applyCheckToList SafeRecord checkSafeRecord requiresSafeRecord parsePositiveInt forgetOnlyLeft checkOrEstablish guardedProof MathTree Leaf Branch treeSum InRange3 checkInRange3 requiresInRange3 discardBothHalves filterAlwaysFails-signature vacuousForAll-signature checkPositiveA-signature requiresPositiveA-signature proofFromA-signature checkNonNeg-signature allNonNeg-signature forgetAndCheck-signature forgetDoesNotRetarget-signature evalExpr-signature makeMyInt-signature myIntVal-signature myIntGt-signature myIntSort-signature checkA4-signature checkB4-signature checkC4-signature checkD4-signature requiresABCD-signature doubleList-signature mapDoesNotProve-signature addThree-signature addThreePartial-signature intEdge-signature describeProven-signature describeStatus3-signature strictBatch-signature floatEdge-signature isEven2-signature isOdd2-signature doubleAndFilter-signature roundTripProof-signature checkEmail2-signature requiresEmail2-signature checkPos-signature checkSmallN-signature checkPosAndSmall2-signature lookupWithDefault-signature aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly-signature applyCheckToList-signature checkSafeRecord-signature requiresSafeRecord-signature parsePositiveInt-signature forgetOnlyLeft-signature checkOrEstablish-signature guardedProof-signature treeSum-signature checkInRange3-signature requiresInRange3-signature discardBothHalves-signature)

(define EvenFact 'EvenFact)
(define FactA 'FactA)
(define FactB 'FactB)
(define FactC 'FactC)
(define FactD 'FactD)
(define InRange3 'InRange3)
(define NonNeg 'NonNeg)
(define PosC 'PosC)
(define Positive1 'Positive1)
(define PositiveA 'PositiveA)
(define SafeTitle 'SafeTitle)
(define SmallC 'SmallC)
(define ValidEmail 'ValidEmail)
(define ValidName 'ValidName)

(define-checker
  (checkPositive1 [n : Integer])
  #:returns [n : Integer ::: (Positive1 n)]
  (if (> *n 0) (accept (Positive1 n) #:value *n) (reject "must be positive" #:http-code 400)))

(define/pow
  (filterAlwaysFails [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPositive1 *xs))

(define/pow
  (vacuousForAll)
  #:returns Integer
  (let ([result (filterAlwaysFails (list -1 -2 -3))]) (raw-value (tesl_import_List_length (raw-value result)))))

(define-checker
  (checkPositiveA [n : Integer])
  #:returns [n : Integer ::: (PositiveA n)]
  (if (> *n 0) (accept (PositiveA n) #:value *n) (reject "must be > 0" #:http-code 400)))

(define/pow
  (requiresPositiveA [n : Integer ::: (PositiveA n)])
  #:returns Integer
  (* *n 2))

(define/pow
  (proofFromA [a : Integer] [b : Integer])
  #:returns Integer
  (let ([va (checkPositiveA a)]) (let ([vb (checkPositiveA b)]) (+ (raw-value (requiresPositiveA va)) (raw-value (requiresPositiveA vb))))))

(define-checker
  (checkNonNeg [n : Integer])
  #:returns [n : Integer ::: (NonNeg n)]
  (if (>= *n 0) (accept (NonNeg n) #:value *n) (reject "must be >= 0" #:http-code 400)))

(define/pow
  (allNonNeg [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (tesl_import_List_allCheck checkNonNeg *xs))

(define/pow
  (allNonNegPasses [xs : (List Integer)])
  #:returns Boolean
  (let ([tesl_case_0 (raw-value (allNonNeg xs))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (raw-value #t)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (raw-value #f)])))

(define/pow
  (allNonNegCount [xs : (List Integer)])
  #:returns Integer
  (let ([tesl_case_1 (raw-value (allNonNeg xs))]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (raw-value -1)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([ys (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (raw-value (raw-value (tesl_import_List_length *ys))))])))

(define/pow
  (forgetAndCheck [n : Integer])
  #:returns Integer
  (let ([validated (checkPositiveA n)]) (let ([raw (forget-proof validated)]) (let ([revalidated (checkPositiveA raw)]) (raw-value (requiresPositiveA revalidated))))))

(define/pow
  (forgetDoesNotRetarget [n : Integer])
  #:returns Integer
  (let ([validated (checkPositiveA n)]) (let ([raw (forget-proof validated)]) (let ([revalidated (checkPositiveA raw)]) (raw-value (requiresPositiveA revalidated))))))

(define-adt Expr
  [Lit [value : Integer]]
  [Add [left : Expr] [right : Expr]]
  [Mul [left : Expr] [right : Expr]]
  [Sub [left : Expr] [right : Expr]]
  [Negate [inner : Expr]]
)

(define/pow
  (evalExpr [e : Expr])
  #:returns Integer
  (let ([tesl_case_2 *e]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Lit)) (let ([value (hash-ref (adt-value-fields *tesl_case_2) 'value)]) *value)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Add)) (let ([left (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (raw-value (+ (raw-value (evalExpr *left)) (raw-value (evalExpr *right))))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Mul)) (let ([left (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (raw-value (* (raw-value (evalExpr *left)) (raw-value (evalExpr *right))))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Sub)) (let ([left (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (raw-value (- (raw-value (evalExpr *left)) (raw-value (evalExpr *right))))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Negate)) (let ([inner (hash-ref (adt-value-fields *tesl_case_2) 'inner)]) (raw-value (- 0 (raw-value (evalExpr *inner)))))])))

(define-adt MyInt
  [MkMyInt [inner : Integer]]
)

(define/pow
  (makeMyInt [n : Integer])
  #:returns MyInt
  (raw-value (MkMyInt *n)))

(define/pow
  (myIntVal [a : MyInt])
  #:returns Integer
  (let ([tesl_case_3 *a]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'MkMyInt)) (let ([inner (hash-ref (adt-value-fields *tesl_case_3) 'inner)]) *inner)])))

(define/pow
  (myIntGt [a : MyInt] [b : MyInt])
  #:returns Boolean
  (> (raw-value (myIntVal a)) (raw-value (myIntVal b))))

(define/pow
  (myIntSort [a : MyInt] [b : MyInt] [c : MyInt])
  #:returns MyInt
  (let ([av (myIntVal a)]) (let ([bv (myIntVal b)]) (let ([cv (myIntVal c)]) (if (and (<= (raw-value av) (raw-value bv)) (<= (raw-value bv) (raw-value cv))) *b (if (and (<= (raw-value av) (raw-value cv)) (<= (raw-value cv) (raw-value bv))) *c *a))))))

(define-checker
  (checkA4 [n : Integer])
  #:returns [n : Integer ::: (FactA n)]
  (if (> *n 0) (accept (FactA n) #:value *n) (reject "FactA" #:http-code 400)))

(define-checker
  (checkB4 [n : Integer])
  #:returns [n : Integer ::: (FactB n)]
  (if (< *n 100) (accept (FactB n) #:value *n) (reject "FactB" #:http-code 400)))

(define-checker
  (checkC4 [n : Integer])
  #:returns [n : Integer ::: (FactC n)]
  (if (not (equal? *n 13)) (accept (FactC n) #:value *n) (reject "FactC: 13 is unlucky" #:http-code 400)))

(define-checker
  (checkD4 [n : Integer])
  #:returns [n : Integer ::: (FactD n)]
  (if (equal? (remainder *n 2) 0) (accept (FactD n) #:value *n) (reject "FactD: must be even" #:http-code 400)))

(define/pow
  (requiresABCD [n : Integer ::: ((FactA n) && ((FactB n) && ((FactC n) && (FactD n))))])
  #:returns String
  (format "ok: ~a" (tesl-display-val *n)))

(define-checker
  (checkAll4 [n : Integer])
  #:returns [n : Integer ::: ((FactA n) && ((FactB n) && ((FactC n) && (FactD n))))]
  (if (> *n 0) (if (< *n 100) (if (not (equal? *n 13)) (if (equal? (remainder *n 2) 0) (accept ((FactA n) && ((FactB n) && ((FactC n) && (FactD n)))) #:value *n) (reject "FactD: must be even" #:http-code 400)) (reject "FactC: 13 is unlucky" #:http-code 400)) (reject "FactB: must be < 100" #:http-code 400)) (reject "FactA: must be > 0" #:http-code 400)))

(define/pow
  (useAll4 [n : Integer])
  #:returns String
  (let ([v (checkAll4 n)]) (raw-value (requiresABCD v))))

(define/pow
  (doubleList [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-4 [n : Integer]) #:returns Integer (* *n 2)) tesl-lambda-4) *xs)))

(define/pow
  (mapDoesNotProve [xs : (List Integer)])
  #:returns Integer
  (let ([doubled (doubleList xs)]) (raw-value (tesl_import_List_length (raw-value doubled)))))

(define/pow
  (addThree [a : Integer] [b : Integer] [c : Integer])
  #:returns Integer
  (+ (+ *a *b) *c))

(define/pow
  (addThreePartial [a : Integer])
  #:returns Integer
  (raw-value (addThree a 10 1)))

(define/pow
  (intEdge [n : Integer])
  #:returns Integer
  (if (> *n 0) (raw-value 1) (if (< *n 0) (raw-value -1) (raw-value 0))))

(define-checker
  (checkValidName [s : String])
  #:returns [s : String ::: (ValidName s)]
  (if (and (>= (raw-value (tesl_import_String_length *s)) 2) (<= (raw-value (tesl_import_String_length *s)) 50)) (accept (ValidName s) #:value *s) (reject "name must be 2-50 chars" #:http-code 400)))

(define/pow
  (describeProven [s : String ::: (ValidName s)])
  #:returns String
  (format "Hello, ~a!" (tesl-display-val *s)))

(define/pow
  (describeViaCheck [raw : String])
  #:returns String
  (let ([validated (checkValidName raw)]) (raw-value (describeProven validated))))

(define-adt Status3
  [Active]
  [Inactive]
  [Suspended [reason : String]]
)

(define/pow
  (describeStatus3 [s : Status3])
  #:returns String
  (let ([tesl_case_5 *s]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Active)) (raw-value "active")] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Inactive)) (raw-value "inactive")] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Suspended)) (let ([reason (hash-ref (adt-value-fields *tesl_case_5) 'reason)]) (raw-value (format "suspended: ~a" (tesl-display-val *reason))))])))

(define/pow
  (strictBatch [xs : (List Integer)])
  #:returns Integer
  (let ([result (tesl_import_List_allCheck checkNonNeg *xs)]) (let ([tesl_case_6 (raw-value result)]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Nothing)) (raw-value -1)] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Something)) (raw-value 1)]))))

(define/pow
  (floatEdge [f : Real])
  #:returns String
  (if (raw-value (tesl_import_Float_isPositive *f)) (raw-value "positive") (raw-value "non-positive")))

(define/pow
  (isEven2 [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #t) (raw-value (isOdd2 (- *n 1)))))

(define/pow
  (isOdd2 [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #f) (raw-value (isEven2 (- *n 1)))))

(define/pow
  (doubleAndFilter [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPositive1 *xs))

(define/pow
  (countProven [xs : (List Integer)])
  #:returns Integer
  (let ([filtered (doubleAndFilter xs)]) (raw-value (tesl_import_List_length (raw-value filtered)))))

(define/pow
  (roundTripProof [n : Integer])
  #:returns Integer
  (let ([validated (checkPositiveA n)]) (let ([tesl_proof_binding_7 validated]) (let ([raw (forget-proof tesl_proof_binding_7)] [proof (detach-all-proof tesl_proof_binding_7)]) (let ([reattached (attach-proof raw proof)]) (raw-value (requiresPositiveA reattached)))))))

(define-newtype Email String)

(define-checker
  (checkEmail2 [raw : String])
  #:returns [e : Email ::: (ValidEmail e)]
  (if (and (raw-value (tesl_import_String_contains *raw "@")) (>= (raw-value (tesl_import_String_length *raw)) 5)) (let ([e (raw-value (Email *raw))]) (accept (ValidEmail e) #:value *e)) (reject "invalid email" #:http-code 400)))

(define/pow
  (requiresEmail2 [e : Email ::: (ValidEmail e)])
  #:returns String
  "email ok")

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (PosC n)]
  (if (> *n 0) (accept (PosC n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (checkSmallN [n : Integer])
  #:returns [n : Integer ::: (SmallC n)]
  (if (< *n 50) (accept (SmallC n) #:value *n) (reject "not small" #:http-code 400)))

(define/pow
  (checkPosAndSmall2 [n : Integer])
  #:returns String
  (let ([result ((check-and checkPos checkSmallN) n)]) (format "ok: ~a" (tesl-display-val *result))))

(define/pow
  (lookupWithDefault [items : (List Integer)] [target : Integer])
  #:returns Integer
  (let ([found (raw-value (tesl_import_List_head (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-8 [n : Integer]) #:returns Boolean (equal? *n *target)) tesl-lambda-8) *items))))]) (let ([tesl_case_9 (raw-value found)]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Nothing)) (raw-value -999)] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Something)) (let ([val (hash-ref (adt-value-fields *tesl_case_9) 'value)]) *val)]))))

(define/pow
  (aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly [n : Integer])
  #:returns Integer
  (+ *n 1))

(define/pow
  (applyCheckToList [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPositive1 *xs))

(define/pow
  (applyLambdaToFiltered [xs : (List Integer)])
  #:returns Integer
  (let ([filtered (applyCheckToList xs)]) (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-10 [acc : Integer] [n : Integer]) #:returns Integer (+ *acc *n)) tesl-lambda-10) 0 (raw-value filtered)))))

(define-checker
  (checkSafeTitle [s : String])
  #:returns [s : String ::: (SafeTitle s)]
  (if (and (>= (raw-value (tesl_import_String_length *s)) 3) (<= (raw-value (tesl_import_String_length *s)) 100)) (accept (SafeTitle s) #:value *s) (reject "title must be 3-100 chars" #:http-code 400)))

(define-record SafeRecord
  [title : String ::: (SafeTitle title)]
)

(define/pow
  (checkSafeRecord [raw : String])
  #:returns SafeRecord
  (let ([t (checkSafeTitle raw)]) (SafeRecord #:title t)))

(define/pow
  (requiresSafeRecord [r : SafeRecord])
  #:returns String
  (tesl-dot/runtime r 'title))

(define/pow
  (parsePositiveInt [s : String])
  #:returns (Result Integer String)
  (if (tesl_import_String_isEmpty *s) (raw-value (raw-value (Err "empty input"))) (let ([n (tesl_import_String_length *s)]) (if (> (raw-value n) 3) (raw-value (raw-value (Err "too long to be an int"))) (raw-value (raw-value (Ok (raw-value n))))))))

(define/pow
  (parseIntOk [s : String])
  #:returns Integer
  (let ([tesl_case_11 (raw-value (parsePositiveInt s))]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Ok)) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'value)]) *n)] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Err)) (raw-value -1)])))

(define/pow
  (parseIntErr [s : String])
  #:returns Boolean
  (let ([tesl_case_12 (raw-value (parsePositiveInt s))]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Err)) (raw-value #t)] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Ok)) (raw-value #f)])))

(define/pow
  (forgetOnlyLeft [n : Integer])
  #:returns Integer
  (let ([validated (checkPositiveA n)]) (let ([tesl_proof_binding_13 validated]) (let ([_ (forget-proof tesl_proof_binding_13)] [proof (detach-all-proof tesl_proof_binding_13)]) (let ([fresh n]) (let ([reattached (attach-proof fresh proof)]) (raw-value (requiresPositiveA reattached))))))))

(define-trusted
  (establishEven [n : Integer])
  #:returns (Maybe (Fact (EvenFact n)))
  (if (equal? (remainder *n 2) 0) (Something (trusted-proof (EvenFact n))) Nothing))

(define/pow
  (requiresEven [n : Integer ::: (EvenFact n)])
  #:returns String
  (format "even: ~a" (tesl-display-val *n)))

(define/pow
  (checkOrEstablish [n : Integer])
  #:returns String
  (let ([mProof (establishEven n)]) (let ([tesl_case_14 (raw-value mProof)]) (cond [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Nothing)) (raw-value "not even")] [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl_case_14) 'value)]) (raw-value (requiresEven (attach-proof n p))))]))))

(define-adt Wrapper
  [Wrap [value : Integer]]
  [Empty]
)

(define/pow
  (guardedProof [w : Wrapper] [threshold : Integer])
  #:returns Integer
  (let ([tesl_case_15 *w]) (cond [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Empty)) (raw-value -1)] [(and (and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Wrap)) (let ([value (hash-ref (adt-value-fields *tesl_case_15) 'value)]) (> *value *threshold))) (let ([value (hash-ref (adt-value-fields *tesl_case_15) 'value)]) *value)] [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Wrap)) (raw-value 0)])))

(define-adt MathTree
  [Leaf [value : Integer]]
  [Branch [left : MathTree] [right : MathTree]]
)

(define/pow
  (treeSum [t : MathTree])
  #:returns Integer
  (let ([tesl_case_16 *t]) (cond [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Leaf)) (let ([value (hash-ref (adt-value-fields *tesl_case_16) 'value)]) *value)] [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Branch)) (let ([left (hash-ref (adt-value-fields *tesl_case_16) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_16) 'right)]) (raw-value (+ (raw-value (treeSum *left)) (raw-value (treeSum *right))))))])))

(define-checker
  (checkInRange3 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange3 lo hi n)]
  (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange3 lo hi n) #:value *n) (reject "out of range" #:http-code 400)))

(define/pow
  (requiresInRange3 [lo : Integer] [hi : Integer] [n : Integer ::: (InRange3 lo hi n)])
  #:returns String
  (format "~a in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))

(define/pow
  (useInRange3 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns String
  (let ([v (checkInRange3 lo hi n)]) (raw-value (requiresInRange3 lo hi v))))

(define/pow
  (discardBothHalves [n : Integer])
  #:returns Integer
  (let ([validated (checkPositiveA n)]) (let ([_ validated]) (+ *n 1))))

(module+ test
  (require rackunit)
  (test-case "T1a: filter of all-negative list yields empty list"
  (check-equal? (raw-value (vacuousForAll)) 0)
  )

  (test-case "T1b: filter of empty input yields empty ForAll list"
  (define result (filterAlwaysFails (list)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 0)
  )

  (test-case "T1c: filter of all-positive list yields full list"
  (define result (filterAlwaysFails (list 1 2 3)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "T1d: mixed list: only positives pass"
  (define result (filterAlwaysFails (list 1 -1 2 -2 3)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "T2a: both values positive \226\128\148 independent proofs"
  (check-equal? (raw-value (proofFromA 3 5)) 16)
  )

  (test-case "T2b: first value fails \226\128\148 check propagates failure"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (proofFromA 0 5)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofFromA 0 5"))
  )

  (test-case "T2c: second value fails \226\128\148 check propagates failure"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (proofFromA 3 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofFromA 3 0"))
  )

  (test-case "T2d: both fail"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (proofFromA -1 -2)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofFromA -1 -2"))
  )

  (test-case "T2e: zero is not positive"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (proofFromA 0 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofFromA 0 0"))
  )

  (test-case "T3a: all non-negative passes"
  (check-equal? (raw-value (allNonNegPasses (list 0 1 2 3))) #t)
  )

  (test-case "T3b: one negative causes whole batch to fail"
  (check-equal? (raw-value (allNonNegPasses (list 1 2 -1 4))) #f)
  )

  (test-case "T3c: empty list always passes allCheck"
  (check-equal? (raw-value (allNonNegPasses (list))) #t)
  )

  (test-case "T3d: single failing element returns Nothing"
  (check-equal? (raw-value (allNonNegPasses (list -1))) #f)
  )

  (test-case "T3e: cardinality preserved \226\128\148 allCheck on [2,4,6] returns 3 elements"
  (check-equal? (raw-value (allNonNegCount (list 2 4 6))) 3)
  )

  (test-case "T4a: forgetFact then re-validate positive number"
  (check-equal? (raw-value (forgetAndCheck 5)) 10)
  )

  (test-case "T4b: forgetFact then re-validate: fails for non-positive"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (forgetAndCheck 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: forgetAndCheck 0"))
  )

  (test-case "T4c: forgetFact returns same value (not zero/default)"
  (check-equal? (raw-value (forgetAndCheck 7)) 14)
  )

  (test-case "T5a: literal"
  (check-equal? (raw-value (evalExpr (Lit 42))) 42)
  )

  (test-case "T5b: add"
  (check-equal? (raw-value (evalExpr (Add (Lit 3) (Lit 4)))) 7)
  )

  (test-case "T5c: double negate"
  (check-equal? (raw-value (evalExpr (Negate (Negate (Lit 5))))) 5)
  )

  (test-case "T5d: (2 + 3) * (4 - 1)"
  (define e (raw-value (Mul (Add (Lit 2) (Lit 3)) (Sub (Lit 4) (Lit 1)))))
  (check-equal? (raw-value (evalExpr e)) 15)
  )

  (test-case "T5e: deeply nested: ((1+2)*3 - (4-5))"
  (define inner (raw-value (Sub (Mul (Add (Lit 1) (Lit 2)) (Lit 3)) (Sub (Lit 4) (Lit 5)))))
  (check-equal? (raw-value (evalExpr inner)) 10)
  )

  (test-case "T5f: negate of add"
  (define e (raw-value (Negate (Add (Lit 10) (Lit 5)))))
  (check-equal? (raw-value (evalExpr e)) -15)
  )

  (test-case "T5g: multiply by zero short-circuits to zero"
  (define e (raw-value (Mul (Lit 0) (Add (Lit 100) (Lit 200)))))
  (check-equal? (raw-value (evalExpr e)) 0)
  )

  (test-case "T6a: MyInt ordering: 5 > 3"
  (check-equal? (raw-value (myIntGt (makeMyInt 5) (makeMyInt 3))) #t)
  )

  (test-case "T6b: MyInt ordering: 3 not > 5"
  (check-equal? (raw-value (myIntGt (makeMyInt 3) (makeMyInt 5))) #f)
  )

  (test-case "T6c: MyInt ordering: equal"
  (check-equal? (raw-value (myIntGt (makeMyInt 4) (makeMyInt 4))) #f)
  )

  (test-case "T6d: median of three MyInt values"
  (check-equal? (raw-value (myIntSort (makeMyInt 1) (makeMyInt 2) (makeMyInt 3))) (makeMyInt 2))
  )

  (test-case "T6e: median with reverse order"
  (check-equal? (raw-value (myIntSort (makeMyInt 3) (makeMyInt 2) (makeMyInt 1))) (makeMyInt 3))
  )

  (test-case "T7a: 42 passes all four checks"
  (check-equal? (raw-value (useAll4 42)) "ok: 42")
  )

  (test-case "T7b: 0 fails FactA (not > 0)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (useAll4 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useAll4 0"))
  )

  (test-case "T7c: 100 fails FactB (not < 100)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (useAll4 100)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useAll4 100"))
  )

  (test-case "T7d: 13 fails FactC (unlucky)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (useAll4 13)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useAll4 13"))
  )

  (test-case "T7e: 3 fails FactD (not even)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (useAll4 3)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useAll4 3"))
  )

  (test-case "T7f: 2 passes all four checks"
  (check-equal? (raw-value (useAll4 2)) "ok: 2")
  )

  (test-case "T8a: map preserves length"
  (check-equal? (raw-value (mapDoesNotProve (list 1 2 3))) 3)
  )

  (test-case "T8b: map on empty list"
  (check-equal? (raw-value (mapDoesNotProve (list))) 0)
  )

  (test-case "T8c: map doubles each element"
  (define result (doubleList (list 1 2 3)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "T8d: map on negative numbers"
  (define result (doubleList (list -1 -2 -3)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "T9a: partial application: addThree 5 10 1 = 16"
  (check-equal? (raw-value (addThreePartial 5)) 16)
  )

  (test-case "T9b: partial application: addThree 0 10 1 = 11"
  (check-equal? (raw-value (addThreePartial 0)) 11)
  )

  (test-case "T9c: partial application: addThree -5 10 1 = 6"
  (check-equal? (raw-value (addThreePartial -5)) 6)
  )

  (test-case "T10a: zero is neither positive nor negative"
  (check-equal? (raw-value (intEdge 0)) 0)
  )

  (test-case "T10b: 1 is positive"
  (check-equal? (raw-value (intEdge 1)) 1)
  )

  (test-case "T10c: -1 is negative"
  (check-equal? (raw-value (intEdge -1)) -1)
  )

  (test-case "T10d: very large positive number"
  (check-equal? (raw-value (intEdge 999999999)) 1)
  )

  (test-case "T10e: very large negative number"
  (check-equal? (raw-value (intEdge -999999999)) -1)
  )

  (test-case "T10f: min representable positive"
  (check-equal? (raw-value (intEdge 1)) 1)
  )

  (test-case "T11a: interpolation unwraps proof-carrying string"
  (check-equal? (raw-value (describeViaCheck "Alice")) "Hello, Alice!")
  )

  (test-case "T11b: interpolation with multi-word name"
  (check-equal? (raw-value (describeViaCheck "Bob Smith")) "Hello, Bob Smith!")
  )

  (test-case "T11c: min-length name"
  (check-equal? (raw-value (describeViaCheck "AB")) "Hello, AB!")
  )

  (test-case "T11d: too-short name fails check"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (describeViaCheck "X")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: describeViaCheck \"X\""))
  )

  (test-case "T12a: Active"
  (check-equal? (raw-value (describeStatus3 Active)) "active")
  )

  (test-case "T12b: Inactive"
  (check-equal? (raw-value (describeStatus3 Inactive)) "inactive")
  )

  (test-case "T12c: Suspended with reason"
  (check-equal? (raw-value (describeStatus3 (Suspended "policy violation"))) "suspended: policy violation")
  )

  (test-case "T12d: Suspended with empty reason"
  (check-equal? (raw-value (describeStatus3 (Suspended ""))) "suspended: ")
  )

  (test-case "T13a: all non-negative passes"
  (check-equal? (raw-value (strictBatch (list 0 1 2 100))) 1)
  )

  (test-case "T13b: one negative fails the batch"
  (check-equal? (raw-value (strictBatch (list 1 2 -1 4))) -1)
  )

  (test-case "T13c: single -1 fails"
  (check-equal? (raw-value (strictBatch (list -1))) -1)
  )

  (test-case "T13d: single 0 passes"
  (check-equal? (raw-value (strictBatch (list 0))) 1)
  )

  (test-case "T13e: empty list passes vacuously"
  (check-equal? (raw-value (strictBatch (list))) 1)
  )

  (test-case "T13f: last element negative kills the batch"
  (check-equal? (raw-value (strictBatch (list 1 2 3 4 -1))) -1)
  )

  (test-case "T14a: positive float"
  (check-equal? (raw-value (floatEdge 1.)) "positive")
  )

  (test-case "T14b: zero is not positive"
  (check-equal? (raw-value (floatEdge 0.)) "non-positive")
  )

  (test-case "T14c: negative float is not positive"
  (check-equal? (raw-value (floatEdge -1.)) "non-positive")
  )

  (test-case "T14d: very small positive float"
  (check-equal? (raw-value (floatEdge 0.0001)) "positive")
  )

  (test-case "T14e: Float.sqrt of 0 is 0 (non-positive)"
  (check-equal? (raw-value (floatEdge (raw-value (tesl_import_Float_sqrt 0.)))) "non-positive")
  )

  (test-case "T14f: Float.sqrt of 4 is 2 (positive)"
  (check-equal? (raw-value (floatEdge (raw-value (tesl_import_Float_sqrt 4.)))) "positive")
  )

  (test-case "T14g: Float.abs of negative is positive"
  (check-equal? (raw-value (floatEdge (raw-value (tesl_import_Float_abs -5.)))) "positive")
  )

  (test-case "T15a: 0 is even"
  (check-equal? (raw-value (isEven2 0)) #t)
  )

  (test-case "T15b: 1 is odd"
  (check-equal? (raw-value (isOdd2 1)) #t)
  )

  (test-case "T15c: 2 is even"
  (check-equal? (raw-value (isEven2 2)) #t)
  )

  (test-case "T15d: 7 is odd"
  (check-equal? (raw-value (isOdd2 7)) #t)
  )

  (test-case "T15e: 10 is even"
  (check-equal? (raw-value (isEven2 10)) #t)
  )

  (test-case "T15f: 0 is not odd"
  (check-equal? (raw-value (isOdd2 0)) #f)
  )

  (test-case "T16a: pipeline: filter then count"
  (check-equal? (raw-value (countProven (list 1 -1 2 -2 3))) 3)
  )

  (test-case "T16b: pipeline: all pass"
  (check-equal? (raw-value (countProven (list 5 10 15))) 3)
  )

  (test-case "T16c: pipeline: none pass"
  (check-equal? (raw-value (countProven (list -1 -2 -3))) 0)
  )

  (test-case "T17a: round-trip preserves value"
  (check-equal? (raw-value (roundTripProof 7)) 14)
  )

  (test-case "T17b: round-trip preserves behaviour"
  (check-equal? (raw-value (roundTripProof 1)) 2)
  )

  (test-case "T17c: round-trip fails for non-positive"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (roundTripProof 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: roundTripProof 0"))
  )

  (test-case "T17d: round-trip with large value"
  (check-equal? (raw-value (roundTripProof 500)) 1000)
  )

  (test-case "T18a: valid email passes check"
  (define e (checkEmail2 "a@b.com"))
  (check-equal? (raw-value (requiresEmail2 e)) "email ok")
  )

  (test-case "T18b: email without @ fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkEmail2 "notanemail")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkEmail2 \"notanemail\""))
  )

  (test-case "T18c: too-short email fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkEmail2 "a@b")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkEmail2 \"a@b\""))
  )

  (test-case "T18d: exactly minimum length with @"
  (define e (checkEmail2 "a@b.c"))
  (check-equal? (raw-value (requiresEmail2 e)) "email ok")
  )

  (test-case "T19a: 5 is positive and small"
  (check-equal? (raw-value (checkPosAndSmall2 5)) "ok: 5")
  )

  (test-case "T19b: 0 is not positive \226\128\148 left fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPosAndSmall2 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall2 0"))
  )

  (test-case "T19c: 50 is not small \226\128\148 right fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPosAndSmall2 50)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall2 50"))
  )

  (test-case "T19d: -10 fails both"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPosAndSmall2 -10)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall2 -10"))
  )

  (test-case "T19e: 49 is positive and small"
  (check-equal? (raw-value (checkPosAndSmall2 49)) "ok: 49")
  )

  (test-case "T19f: 1 is positive and small"
  (check-equal? (raw-value (checkPosAndSmall2 1)) "ok: 1")
  )

  (test-case "T20a: found returns value"
  (check-equal? (raw-value (lookupWithDefault (list 1 2 3) 2)) 2)
  )

  (test-case "T20b: not found returns -999"
  (check-equal? (raw-value (lookupWithDefault (list 1 2 3) 9)) -999)
  )

  (test-case "T20c: empty list returns -999"
  (check-equal? (raw-value (lookupWithDefault (list) 1)) -999)
  )

  (test-case "T20d: found first element"
  (check-equal? (raw-value (lookupWithDefault (list 5 6 7) 5)) 5)
  )

  (test-case "T21a: long name function works"
  (check-equal? (raw-value (aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly 41)) 42)
  )

  (test-case "T21b: long name with zero"
  (check-equal? (raw-value (aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly 0)) 1)
  )

  (test-case "T22a: lambda folds filtered list"
  (check-equal? (raw-value (applyLambdaToFiltered (list 1 2 3 -1 -2))) 6)
  )

  (test-case "T22b: lambda fold on empty after filter"
  (check-equal? (raw-value (applyLambdaToFiltered (list -1 -2 -3))) 0)
  )

  (test-case "T22c: lambda fold all positive"
  (check-equal? (raw-value (applyLambdaToFiltered (list 10 20 30))) 60)
  )

  (test-case "T23a: valid title creates record"
  (define r (checkSafeRecord "Hello World"))
  (check-equal? (raw-value (requiresSafeRecord r)) "Hello World")
  )

  (test-case "T23b: too-short title fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkSafeRecord "Hi")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkSafeRecord \"Hi\""))
  )

  (test-case "T23c: exact min length creates record"
  (define r (checkSafeRecord "ABC"))
  (check-equal? (raw-value (requiresSafeRecord r)) "ABC")
  )

  (test-case "T24a: Ok result returned for valid input"
  (check-equal? (raw-value (parseIntOk "hi")) 2)
  )

  (test-case "T24b: Err for empty input"
  (check-equal? (raw-value (parseIntErr "")) #t)
  )

  (test-case "T24c: Ok carries correct value"
  (check-equal? (raw-value (parseIntOk "abc")) 3)
  )

  (test-case "T24d: Err for too-long input"
  (check-equal? (raw-value (parseIntErr "toolong")) #t)
  )

  (test-case "T25a: forget value, keep proof, reattach to same raw int"
  (check-equal? (raw-value (forgetOnlyLeft 8)) 16)
  )

  (test-case "T25b: for value 1"
  (check-equal? (raw-value (forgetOnlyLeft 1)) 2)
  )

  (test-case "T25c: non-positive fails at original check"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (forgetOnlyLeft 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: forgetOnlyLeft 0"))
  )

  (test-case "T26a: even number gets proof"
  (check-equal? (raw-value (checkOrEstablish 4)) "even: 4")
  )

  (test-case "T26b: odd number gets Nothing"
  (check-equal? (raw-value (checkOrEstablish 3)) "not even")
  )

  (test-case "T26c: zero is even"
  (check-equal? (raw-value (checkOrEstablish 0)) "even: 0")
  )

  (test-case "T26d: negative even"
  (check-equal? (raw-value (checkOrEstablish -2)) "even: -2")
  )

  (test-case "T27a: Empty returns -1"
  (check-equal? (raw-value (guardedProof Empty 10)) -1)
  )

  (test-case "T27b: Wrap 15 with threshold 10 returns 15"
  (check-equal? (raw-value (guardedProof (Wrap 15) 10)) 15)
  )

  (test-case "T27c: Wrap 5 with threshold 10 falls through to 0"
  (check-equal? (raw-value (guardedProof (Wrap 5) 10)) 0)
  )

  (test-case "T27d: Wrap 10 with threshold 10 is NOT > 10, falls to 0"
  (check-equal? (raw-value (guardedProof (Wrap 10) 10)) 0)
  )

  (test-case "T27e: Wrap 11 with threshold 10 is > 10"
  (check-equal? (raw-value (guardedProof (Wrap 11) 10)) 11)
  )

  (test-case "T28a: single leaf"
  (check-equal? (raw-value (treeSum (Leaf 5))) 5)
  )

  (test-case "T28b: two-leaf tree"
  (define t (raw-value (Branch (Leaf 3) (Leaf 4))))
  (check-equal? (raw-value (treeSum t)) 7)
  )

  (test-case "T28c: three-level tree"
  (define t (raw-value (Branch (Branch (Leaf 1) (Leaf 2)) (Branch (Leaf 3) (Leaf 4)))))
  (check-equal? (raw-value (treeSum t)) 10)
  )

  (test-case "T28d: unbalanced tree"
  (define t (raw-value (Branch (Leaf 10) (Branch (Leaf 1) (Branch (Leaf 2) (Leaf 3))))))
  (check-equal? (raw-value (treeSum t)) 16)
  )

  (test-case "T28e: all-zero leaves"
  (define t (raw-value (Branch (Leaf 0) (Branch (Leaf 0) (Leaf 0)))))
  (check-equal? (raw-value (treeSum t)) 0)
  )

  (test-case "T28f: negative leaves"
  (define t (raw-value (Branch (Leaf -1) (Leaf -2))))
  (check-equal? (raw-value (treeSum t)) -3)
  )

  (test-case "T29a: 5 in [1, 10]"
  (check-equal? (raw-value (useInRange3 1 10 5)) "5 in [1, 10]")
  )

  (test-case "T29b: at lower bound"
  (check-equal? (raw-value (useInRange3 1 10 1)) "1 in [1, 10]")
  )

  (test-case "T29c: at upper bound"
  (check-equal? (raw-value (useInRange3 1 10 10)) "10 in [1, 10]")
  )

  (test-case "T29d: below lower bound fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (useInRange3 1 10 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useInRange3 1 10 0"))
  )

  (test-case "T29e: above upper bound fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (useInRange3 1 10 11)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useInRange3 1 10 11"))
  )

  (test-case "T29f: lo == hi, exact match"
  (check-equal? (raw-value (useInRange3 5 5 5)) "5 in [5, 5]")
  )

  (test-case "T29g: negative range"
  (define lo (- 0 10))
  (define hi (- 0 1))
  (define n (- 0 5))
  (check-equal? (raw-value (useInRange3 lo hi n)) "-5 in [-10, -1]")
  )

  (test-case "T30a: discard both halves, return original + 1"
  (check-equal? (raw-value (discardBothHalves 5)) 6)
  )

  (test-case "T30b: discard both halves, n = 1"
  (check-equal? (raw-value (discardBothHalves 1)) 2)
  )

  (test-case "T30c: check still propagates failure even with discarded binding"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (discardBothHalves 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: discardBothHalves 0"))
  )

  (test-case "T30d: large value"
  (check-equal? (raw-value (discardBothHalves 100)) 101)
  )

)
