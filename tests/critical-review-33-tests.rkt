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
  (only-in tesl/tesl/prelude Bool Int List String Fact forgetFact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.trim tesl_import_String_trim] [String.contains tesl_import_String_contains] [String.isEmpty tesl_import_String_isEmpty] [String.startsWith tesl_import_String_startsWith] IsTrimmed)
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.sort tesl_import_List_sort] [List.length tesl_import_List_length] [List.head tesl_import_List_head] [List.isEmpty tesl_import_List_isEmpty] [List.append tesl_import_List_append] [List.reverse tesl_import_List_reverse] [List.sum tesl_import_List_sum] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either Either Left Right [Either.partition tesl_import_Either_partition])
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide] IsNonZero [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/float Float [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero [Float.div tesl_import_Float_div] [Float.abs tesl_import_Float_abs] [Float.isNaN tesl_import_Float_isNaN] [Float.isInfinite tesl_import_Float_isInfinite])
  (only-in tesl/tesl/dict Dict [Dict.empty tesl_import_Dict_empty] [Dict.insert tesl_import_Dict_insert] [Dict.requireKey tesl_import_Dict_requireKey] [Dict.get tesl_import_Dict_get] [Dict.member tesl_import_Dict_member] HasKey)
  (only-in tesl/tesl/set [Set.insert tesl_import_Set_insert] [Set.member tesl_import_Set_member] [Set.fromList tesl_import_Set_fromList] [Set.toList tesl_import_Set_toList])
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
)


(provide checkPos33 filterToPositives emptyListForAll checkPrime33 requiresPrime33 proofThroughLetChain IsTrimmed33 checkShort33 checkTrimmed33 composedBoth33 requiresBothProofs33 alwaysEstablish33 requiresAlwaysValid33 isOdd33 treeSum33 treeDepth33 treeMap33 boxMap33 boxFlatMap33 doubleBox33 minFixnum33 addZero33 mulOne33 subSelf33 floatMulByOne33 floatAbsNeg33 interpolateZero33 interpolateNegative33 checkEven33 narrowForAll33 checkChecked33 decomposeAndReuse33 describeStatus33 Inner33 InnerA InnerB unwrapInner33 makeWrapped33 extractWrapped33 doubleWrapped33 doubleAll33 allCheckNone33 checkInRange33 requiresInRange33 classifyWeekend33 checkPos33-signature filterToPositives-signature emptyListForAll-signature checkPrime33-signature requiresPrime33-signature proofThroughLetChain-signature checkShort33-signature checkTrimmed33-signature requiresBothProofs33-signature composedBoth33-signature alwaysEstablish33-signature requiresAlwaysValid33-signature isOdd33-signature treeSum33-signature treeDepth33-signature treeMap33-signature boxMap33-signature boxFlatMap33-signature doubleBox33-signature minFixnum33-signature addZero33-signature mulOne33-signature subSelf33-signature floatMulByOne33-signature floatAbsNeg33-signature interpolateZero33-signature interpolateNegative33-signature checkEven33-signature narrowForAll33-signature checkChecked33-signature decomposeAndReuse33-signature describeStatus33-signature unwrapInner33-signature makeWrapped33-signature extractWrapped33-signature doubleWrapped33-signature doubleAll33-signature allCheckNone33-signature checkInRange33-signature requiresInRange33-signature classifyWeekend33-signature)

(define AlwaysValid33 'AlwaysValid33)
(define FixIsPos33 'FixIsPos33)
(define FixIsSmall33 'FixIsSmall33)
(define InRange33 'InRange33)
(define IsChecked33 'IsChecked33)
(define IsEven33 'IsEven33)
(define IsPos33 'IsPos33)
(define IsPrime33 'IsPrime33)
(define IsShort33 'IsShort33)
(define IsTrimmed33 'IsTrimmed33)

(define-checker
  (checkPos33 [n : Integer])
  #:returns [n : Integer ::: (IsPos33 n)]
  (if (> *n 0) (accept (IsPos33 n) #:value *n) (reject "must be positive" #:http-code 400)))

(define/pow
  (filterToPositives [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPos33 *xs))

(define/pow
  (emptyListForAll)
  #:returns Integer
  (let ([result (filterToPositives (list))]) (raw-value (tesl_import_List_length (raw-value result)))))

(define-checker
  (checkPrime33 [n : Integer])
  #:returns [n : Integer ::: (IsPrime33 n)]
  (if (or (equal? *n 2) (or (equal? *n 3) (or (equal? *n 5) (or (equal? *n 7) (or (equal? *n 11) (equal? *n 13)))))) (accept (IsPrime33 n) #:value *n) (reject "not a small prime" #:http-code 400)))

(define/pow
  (requiresPrime33 [n : Integer ::: (IsPrime33 n)])
  #:returns String
  (format "prime: ~a" (tesl-display-val *n)))

(define/pow
  (proofThroughLetChain [n : Integer ::: (IsPrime33 n)])
  #:returns String
  (let ([a n]) (raw-value (requiresPrime33 a))))

(define-checker
  (checkShort33 [s : String])
  #:returns [s : String ::: (IsShort33 s)]
  (if (<= (raw-value (tesl_import_String_length *s)) 10) (accept (IsShort33 s) #:value *s) (reject "too long" #:http-code 400)))

(define-checker
  (checkTrimmed33 [s : String])
  #:returns [s : String ::: (IsTrimmed33 s)]
  (let ([trimmed (tesl_import_String_trim *s)]) (if (equal? (raw-value trimmed) *s) (accept (IsTrimmed33 s) #:value *s) (reject "not trimmed" #:http-code 400))))

(define/pow
  (requiresBothProofs33 [s : String ::: ((IsShort33 s) && (IsTrimmed33 s))])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define/pow
  (composedBoth33 [raw : String])
  #:returns Integer
  (let ([v (checkShort33 raw)]) (let ([w (checkTrimmed33 v)]) (raw-value (tesl_import_String_length (raw-value w))))))

(define-trusted
  (alwaysEstablish33 [n : Integer])
  #:returns (Fact (AlwaysValid33 n))
  (trusted-proof (AlwaysValid33 n)))

(define/pow
  (requiresAlwaysValid33 [n : Integer ::: (AlwaysValid33 n)])
  #:returns Integer
  (* *n 2))

(define/pow
  (applyAlwaysValid33 [n : Integer])
  #:returns Integer
  (let ([proof (alwaysEstablish33 n)]) (raw-value (requiresAlwaysValid33 (attach-proof n proof)))))

(define/pow
  (isEven33 [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #t) (raw-value (isOdd33 (- *n 1)))))

(define/pow
  (isOdd33 [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #f) (raw-value (isEven33 (- *n 1)))))

(define-adt IntTree33
  [Leaf33]
  [Node33 [left : IntTree33] [value : Integer] [right : IntTree33]]
)

(define/pow
  (treeSum33 [t : IntTree33])
  #:returns Integer
  (let ([tesl_case_0 *t]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Leaf33)) (raw-value 0)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Node33)) (let ([left (hash-ref (adt-value-fields *tesl_case_0) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl_case_0) 'right)]) (raw-value (+ (+ (raw-value (treeSum33 *left)) *value) (raw-value (treeSum33 *right)))))))])))

(define/pow
  (treeDepth33 [t : IntTree33])
  #:returns Integer
  (let ([tesl_case_1 *t]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Leaf33)) (raw-value 0)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Node33)) (let ([left (hash-ref (adt-value-fields *tesl_case_1) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_1) 'right)]) (let ([ld (treeDepth33 *left)]) (let ([rd (treeDepth33 *right)]) (let ([maxDepth (if (> (raw-value ld) (raw-value rd)) ld rd)]) (raw-value (+ 1 (raw-value maxDepth))))))))])))

(define/pow
  (treeMap33 [f : (-> Integer Integer)] [t : IntTree33])
  #:returns IntTree33
  (let ([tesl_case_2 *t]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Leaf33)) (raw-value Leaf33)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Node33)) (let ([left (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (raw-value (raw-value (Node33 (treeMap33 f *left) (f *value) (treeMap33 f *right)))))))])))

(define-adt (Box33 a)
  [MkBox33 [value : a]]
)

(define/pow
  (boxMap33 [f : (-> a b)] [box : (Box33 a)])
  #:returns (Box33 b)
  (let ([tesl_case_3 *box]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'MkBox33)) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (raw-value (MkBox33 (f *value)))))])))

(define/pow
  (boxFlatMap33 [f : (-> a (Box33 b))] [box : (Box33 a)])
  #:returns (Box33 b)
  (let ([tesl_case_4 *box]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'MkBox33)) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value (f *value)))])))

(define/pow
  (doubleBox33 [box : (Box33 Integer)])
  #:returns (Box33 Integer)
  (raw-value (boxMap33 (let () (define/pow (tesl-lambda-5 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-5) box)))

(define/pow
  (intToStr33 [x : Integer])
  #:returns String
  (format "value: ~a" (tesl-display-val *x)))

(define/pow
  (maxFixnum33)
  #:returns Integer
  4611686018427387903)

(define/pow
  (minFixnum33)
  #:returns Integer
  -4611686018427387903)

(define/pow
  (addZero33 [n : Integer])
  #:returns Integer
  (+ *n 0))

(define/pow
  (mulOne33 [n : Integer])
  #:returns Integer
  (* *n 1))

(define/pow
  (subSelf33 [n : Integer])
  #:returns Integer
  (- *n *n))

(define/pow
  (floatAddNegZero33 [x : Real])
  #:returns Real
  (+ *x 0.))

(define/pow
  (floatMulByOne33 [x : Real])
  #:returns Real
  (* *x 1.))

(define/pow
  (floatAbsNeg33 [x : Real])
  #:returns Real
  (raw-value (tesl_import_Float_abs (- 0. *x))))

(define/pow
  (interpolateComplex33 [n : Integer])
  #:returns String
  (let ([doubled (* *n 2)]) (let ([tripled (* *n 3)]) (format "n=~a, doubled=~a, tripled=~a" (tesl-display-val *n) (tesl-display-val *doubled) (tesl-display-val *tripled)))))

(define/pow
  (interpolateZero33)
  #:returns String
  (let ([z 0]) (format "zero: ~a" (tesl-display-val *z))))

(define/pow
  (interpolateNegative33 [n : Integer])
  #:returns String
  (format "negative: ~a" (tesl-display-val *n)))

(define-checker
  (checkEven33 [n : Integer])
  #:returns [n : Integer ::: (IsEven33 n)]
  (if (equal? (remainder *n 2) 0) (accept (IsEven33 n) #:value *n) (reject "not even" #:http-code 400)))

(define/pow
  (narrowForAll33 [xs : (List Integer)])
  #:returns (List Integer)
  (let ([positives (filterToPositives xs)]) (tesl_import_List_filterCheck checkEven33 (raw-value positives))))

(define-checker
  (checkChecked33 [n : Integer])
  #:returns [n : Integer ::: (IsChecked33 n)]
  (if (>= *n 0) (accept (IsChecked33 n) #:value *n) (reject "must be non-negative" #:http-code 400)))

(define/pow
  (requiresChecked33 [n : Integer ::: (IsChecked33 n)])
  #:returns Integer
  (+ *n 100))

(define/pow
  (decomposeAndReuse33 [n : Integer ::: (IsChecked33 n)])
  #:returns Integer
  (raw-value (requiresChecked33 n)))

(define-adt Status33
  [Active33]
  [Inactive33]
  [Pending33 [reason : String]]
)

(define/pow
  (describeStatus33 [s : Status33] [userId : String])
  #:returns String
  (let ([tesl_case_6 *s]) (cond [(and (and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Active33)) (tesl_import_String_startsWith *userId "admin")) (raw-value "admin active")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Active33)) (raw-value "user active")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Inactive33)) (raw-value "inactive")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Pending33)) (let ([reason (hash-ref (adt-value-fields *tesl_case_6) 'reason)]) (raw-value (format "pending: ~a" (tesl-display-val *reason))))])))

(define-adt Inner33
  [InnerA [val : Integer]]
  [InnerB [val : String]]
)

(define-adt Wrapper33
  [Wrapped [inner : Inner33]]
  [Empty33]
)

(define/pow
  (unwrapInner33 [w : Wrapper33])
  #:returns String
  (let ([tesl_case_7 *w]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Empty33)) (raw-value "empty")] [(and (and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Wrapped)) (let ([tesl_case_7_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_7) 'inner))]) (and (adt-value? *tesl_case_7_f0) (eq? (adt-value-variant *tesl_case_7_f0) 'InnerA)))) (let ([tesl_case_7_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_7) 'inner))]) (let ([val (hash-ref (adt-value-fields *tesl_case_7_f0) 'val)]) (raw-value (format "int: ~a" (tesl-display-val *val)))))] [(and (and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Wrapped)) (let ([tesl_case_7_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_7) 'inner))]) (and (adt-value? *tesl_case_7_f0) (eq? (adt-value-variant *tesl_case_7_f0) 'InnerB)))) (let ([tesl_case_7_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_7) 'inner))]) (let ([val (hash-ref (adt-value-fields *tesl_case_7_f0) 'val)]) (raw-value (format "str: ~a" (tesl-display-val *val)))))])))

(define-newtype WrappedInt33 Integer)

(define/pow
  (makeWrapped33 [n : Integer])
  #:returns WrappedInt33
  (raw-value (WrappedInt33 *n)))

(define/pow
  (extractWrapped33 [w : WrappedInt33])
  #:returns Integer
  (raw-value w.value))

(define/pow
  (doubleWrapped33 [w : WrappedInt33])
  #:returns WrappedInt33
  (raw-value (WrappedInt33 (* (raw-value w.value) 2))))

(define/pow
  (lookupWithProof33 [key : String] [dict : (Dict String Integer)])
  #:returns (Maybe Integer)
  (if (raw-value (tesl_import_Dict_member *key *dict)) (let/check ([tesl_checked_8 (tesl_import_Dict_requireKey key dict)]) (let ([checkedDict (attach-proof (ensure-named 'checkedDict (raw-value tesl_checked_8)) (detach-all-proof tesl_checked_8))]) (raw-value (raw-value (Something (raw-value (tesl_import_Dict_get *key checkedDict))))))) (raw-value Nothing)))

(define/pow
  (applyTwice33 [f : (-> Integer Integer)] [x : Integer])
  #:returns Integer
  (raw-value (f (f x))))

(define/pow
  (doubleAll33 [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-9 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-9) *xs)))

(define/pow
  (proofTotalDivide33 [a : Integer] [b : Integer])
  #:returns (Maybe Integer)
  (if (equal? *b 0) (raw-value Nothing) (let/check ([tesl_checked_10 (tesl_import_Int_nonZero b)]) (let ([divisor (attach-proof (ensure-named 'divisor (raw-value tesl_checked_10)) (detach-all-proof tesl_checked_10))]) (raw-value (raw-value (Something (tesl_import_Int_divide *a divisor))))))))

(define/pow
  (proofTotalFloatDiv33 [a : Real] [b : Real])
  #:returns (Maybe Real)
  (if (equal? *b 0.) (raw-value Nothing) (let/check ([tesl_checked_11 (tesl_import_Float_requireNonZero b)]) (let ([divisor (attach-proof (ensure-named 'divisor (raw-value tesl_checked_11)) (detach-all-proof tesl_checked_11))]) (raw-value (raw-value (Something (raw-value (tesl_import_Float_div *a divisor)))))))))

(define/pow
  (allCheckSome33 [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (tesl_import_List_allCheck checkPos33 *xs))

(define/pow
  (allCheckNone33 [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (tesl_import_List_allCheck checkPos33 *xs))

(define-checker
  (checkInRange33 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange33 lo hi n)]
  (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange33 lo hi n) #:value *n) (reject "out of range" #:http-code 400)))

(define/pow
  (requiresInRange33 [lo : Integer] [hi : Integer] [n : Integer ::: (InRange33 lo hi n)])
  #:returns String
  (format "~a is in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))

(define/pow
  (forgetAndRecheck33 [n : Integer ::: (IsPos33 n)])
  #:returns Integer
  (let ([forgotten (forget-proof n)]) (let/check ([tesl_checked_12 (checkPos33 forgotten)]) (let ([rechecked (attach-proof (ensure-named 'rechecked (raw-value tesl_checked_12)) (detach-all-proof tesl_checked_12))]) (raw-value rechecked)))))

(define/pow
  (tryForgetRecheck33 [raw : Integer])
  #:returns (Maybe Integer)
  (if (> *raw 0) (let ([checked (checkPos33 raw)]) (raw-value (raw-value (Something (forgetAndRecheck33 checked))))) (raw-value Nothing)))

(define-adt Weekday33
  [Monday33]
  [Tuesday33]
  [Wednesday33]
  [Thursday33]
  [Friday33]
  [Saturday33]
  [Sunday33]
)

(define/pow
  (classifyWeekend33 [day : Weekday33])
  #:returns String
  (let ([tesl_case_13 *day]) (cond [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Saturday33)) (raw-value "weekend")] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Sunday33)) (raw-value "weekend")] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Monday33)) (raw-value "weekday")] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Tuesday33)) (raw-value "weekday")] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Wednesday33)) (raw-value "weekday")] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Thursday33)) (raw-value "weekday")] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Friday33)) (raw-value "weekday")])))

(define/pow
  (sortedInts33 [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_sort *xs)))

(define/pow
  (partitionEithers33 [xs : (List (Either String Integer))])
  #:returns (Tuple2 (List String) (List Integer))
  (raw-value (tesl_import_Either_partition *xs)))

(define/pow
  (boolLiterals33)
  #:returns Boolean
  #t)

(define/pow
  (boolNegation33 [b : Boolean])
  #:returns Boolean
  (if (equal? *b #t) (raw-value #f) (raw-value #t)))

(define-adt FixShape33
  [FixCircle33 [radius : Integer]]
  [FixRect33 [w : Integer] [h : Integer]]
  [FixPoint33]
)

(define-checker
  (fixCheckPos33 [n : Integer])
  #:returns [n : Integer ::: (FixIsPos33 n)]
  (if (> *n 0) (accept (FixIsPos33 n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (fixCheckSmall33 [n : Integer])
  #:returns [n : Integer ::: (FixIsSmall33 n)]
  (if (< *n 100) (accept (FixIsSmall33 n) #:value *n) (reject "too large" #:http-code 400)))

(define/pow
  (fixRequiresBoth33 [n : Integer ::: ((FixIsPos33 n) && (FixIsSmall33 n))])
  #:returns String
  (format "ok: ~a" (tesl-display-val *n)))

(module+ test
  (require rackunit)
  (test-case "T01 \226\128\148 ForAll on empty list"
  (check-equal? (raw-value (emptyListForAll)) 0)
  (define result (filterToPositives (list)))
  (check-equal? (raw-value (raw-value (tesl_import_List_isEmpty (raw-value result)))) #t)
  (define nonEmpty (filterToPositives (list 1 2 3)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value nonEmpty)))) 3)
  (define mixed (filterToPositives (list -1 2 -3 4)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value mixed)))) 2)
  )

  (test-case "T01b \226\128\148 checkPos33 boundary"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPos33 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPos33 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPos33 -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPos33 -1"))
  (define p1 1)
  (define r (checkPos33 p1))
  (check-equal? (raw-value r) 1)
  )

  (test-case "T02 \226\128\148 proof survives let chain"
  (define p7 7)
  (define v7 (checkPrime33 p7))
  (check-equal? (raw-value (proofThroughLetChain v7)) "prime: 7")
  (define p13 13)
  (define v13 (checkPrime33 p13))
  (check-equal? (raw-value (proofThroughLetChain v13)) "prime: 13")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPrime33 4)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPrime33 4"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPrime33 1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPrime33 1"))
  )

  (test-case "T03 \226\128\148 check composition both proofs"
  (check-equal? (raw-value (composedBoth33 "hello")) 5)
  (check-equal? (raw-value (composedBoth33 "hi")) 2)
  (check-equal? (raw-value (composedBoth33 "")) 0)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkTrimmed33 "  padded  ")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkTrimmed33 \"  padded  \""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkShort33 "way too long for short check")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkShort33 \"way too long for short check\""))
  )

  (test-case "T03b \226\128\148 reversed composition also fails long strings"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and checkTrimmed33 checkShort33) "this is too long definitely")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and checkTrimmed33 checkShort33) \"this is too long definitely\""))
  (define shortStr "ok")
  (define result ((check-and checkShort33 checkTrimmed33) shortStr))
  (check-equal? (raw-value (tesl_import_String_length (raw-value result))) 2)
  )

  (test-case "T04 \226\128\148 establish is unconditional"
  (check-equal? (raw-value (applyAlwaysValid33 0)) 0)
  (check-equal? (raw-value (applyAlwaysValid33 -999)) -1998)
  )

  (test-case "T04b \226\128\148 establish on any value"
  (check-equal? (raw-value (applyAlwaysValid33 1000000)) 2000000)
  (check-equal? (raw-value (applyAlwaysValid33 -1)) -2)
  (check-equal? (raw-value (applyAlwaysValid33 7)) 14)
  )

  (test-case "T05 \226\128\148 mutual recursion even/odd"
  (check-equal? (raw-value (isEven33 0)) #t)
  (check-equal? (raw-value (isEven33 1)) #f)
  (check-equal? (raw-value (isEven33 4)) #t)
  (check-equal? (raw-value (isOdd33 3)) #t)
  (check-equal? (raw-value (isOdd33 10)) #f)
  (check-equal? (raw-value (isEven33 100)) #t)
  (check-equal? (raw-value (isOdd33 99)) #t)
  )

  (test-case "T05b \226\128\148 mutual recursion property"
  ; property: even and odd are complementary
  (for ([tesl-prop-i (in-range 30)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (< (raw-value n) 50)) (check-true (not (equal? (raw-value (isEven33 n)) (raw-value (isOdd33 n)))) "even and odd are complementary"))
    ))
  )

  (test-case "T06 \226\128\148 recursive ADT operations"
  (define leaf Leaf33)
  (check-equal? (raw-value (treeSum33 leaf)) 0)
  (check-equal? (raw-value (treeDepth33 leaf)) 0)
  (define single (raw-value (Node33 Leaf33 5 Leaf33)))
  (check-equal? (raw-value (treeSum33 single)) 5)
  (check-equal? (raw-value (treeDepth33 single)) 1)
  (define tree (raw-value (Node33 (Node33 Leaf33 2 Leaf33) 4 (Node33 Leaf33 6 Leaf33))))
  (check-equal? (raw-value (treeSum33 tree)) 12)
  (check-equal? (raw-value (treeDepth33 tree)) 2)
  (define doubled (treeMap33 (let () (define/pow (tesl-lambda-14 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-14) tree))
  (check-equal? (raw-value (treeSum33 doubled)) 24)
  )

  (test-case "T06b \226\128\148 deep tree"
  (define deep (raw-value (Node33 (Node33 (Node33 Leaf33 1 Leaf33) 2 Leaf33) 3 Leaf33)))
  (check-equal? (raw-value (treeSum33 deep)) 6)
  (check-equal? (raw-value (treeDepth33 deep)) 3)
  )

  (test-case "T07 \226\128\148 parameterized ADT operations"
  (define intBox (raw-value (MkBox33 42)))
  (define doubled (doubleBox33 intBox))
  (check-equal? (raw-value doubled) (raw-value (MkBox33 84)))
  (define strBox (boxMap33 intToStr33 intBox))
  (check-equal? (raw-value strBox) (raw-value (MkBox33 "value: 42")))
  (define flatMapped (boxFlatMap33 (let () (define/pow (tesl-lambda-15 [x : Integer]) #:returns Any (raw-value (MkBox33 (+ *x 1)))) tesl-lambda-15) intBox))
  (check-equal? (raw-value flatMapped) (raw-value (MkBox33 43)))
  )

  (test-case "T08 \226\128\148 integer identity laws"
  (check-equal? (raw-value (addZero33 42)) 42)
  (check-equal? (raw-value (addZero33 0)) 0)
  (check-equal? (raw-value (addZero33 -100)) -100)
  (check-equal? (raw-value (mulOne33 99)) 99)
  (check-equal? (raw-value (mulOne33 -5)) -5)
  (check-equal? (raw-value (subSelf33 12345)) 0)
  (check-equal? (raw-value (subSelf33 0)) 0)
  (check-equal? (raw-value (subSelf33 -999)) 0)
  )

  (test-case "T08b \226\128\148 integer boundary values"
  (check-equal? (raw-value (maxFixnum33)) 4611686018427387903)
  (check-equal? (raw-value (minFixnum33)) -4611686018427387903)
  (check-equal? (raw-value (> (raw-value (maxFixnum33)) 0)) #t)
  (check-equal? (raw-value (< (raw-value (minFixnum33)) 0)) #t)
  )

  (test-case "T08c \226\128\148 integer arithmetic properties"
  ; property: addZero identity
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) -1000000) (< (raw-value n) 1000000)) (check-true (equal? (raw-value (addZero33 n)) (raw-value n)) "addZero identity"))
    ))
  ; property: mulOne identity
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) -1000000) (< (raw-value n) 1000000)) (check-true (equal? (raw-value (mulOne33 n)) (raw-value n)) "mulOne identity"))
    ))
  ; property: subSelf is zero
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) -1000000) (< (raw-value n) 1000000)) (check-true (equal? (raw-value (subSelf33 n)) 0) "subSelf is zero"))
    ))
  )

  (test-case "T09 \226\128\148 float basic operations"
  (check-equal? (raw-value (floatAbsNeg33 3.14)) 3.14)
  (check-equal? (raw-value (floatAbsNeg33 0.)) 0.)
  (check-equal? (raw-value (floatAbsNeg33 -2.71)) 2.71)
  (check-equal? (raw-value (floatAddNegZero33 1.5)) 1.5)
  (check-equal? (raw-value (floatMulByOne33 2.5)) 2.5)
  )

  (test-case "T09b \226\128\148 float NaN/Infinity detection"
  (define inf 1.)
  (define b1 (raw-value (tesl_import_Float_isNaN (raw-value inf))))
  (define b2 (raw-value (tesl_import_Float_isInfinite (raw-value inf))))
  (check-equal? (raw-value b1) #f)
  (check-equal? (raw-value b2) #f)
  )

  (test-case "T10 \226\128\148 string interpolation"
  (check-equal? (raw-value (interpolateComplex33 5)) "n=5, doubled=10, tripled=15")
  (check-equal? (raw-value (interpolateZero33)) "zero: 0")
  (check-equal? (raw-value (interpolateNegative33 -7)) "negative: -7")
  )

  (test-case "T10b \226\128\148 interpolation property"
  ; property: interpolated length is positive
  (for ([tesl-prop-i (in-range 20)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (< (raw-value n) 1000)) (check-true (> (raw-value (tesl_import_String_length (raw-value (interpolateComplex33 n)))) 0) "interpolated length is positive"))
    ))
  )

  (test-case "T11 \226\128\148 ForAll narrowing"
  (define result (narrowForAll33 (list 1 2 3 4 -2 6)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  (define empty (narrowForAll33 (list -1 3 5)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value empty)))) 0)
  (define allEven (narrowForAll33 (list 2 4 6 8)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value allEven)))) 4)
  )

  (test-case "T12 \226\128\148 proof decomposition and reattachment"
  (define raw5 5)
  (define c5 (checkChecked33 raw5))
  (check-equal? (raw-value (decomposeAndReuse33 c5)) 105)
  (define raw0 0)
  (define c0 (checkChecked33 raw0))
  (check-equal? (raw-value (decomposeAndReuse33 c0)) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkChecked33 -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkChecked33 -1"))
  )

  (test-case "T13 \226\128\148 case with where guard"
  (check-equal? (raw-value (describeStatus33 Active33 "admin_user")) "admin active")
  (check-equal? (raw-value (describeStatus33 Active33 "regular_user")) "user active")
  (check-equal? (raw-value (describeStatus33 Inactive33 "anyone")) "inactive")
  (check-equal? (raw-value (describeStatus33 (Pending33 "review") "user")) "pending: review")
  )

  (test-case "T13b \226\128\148 where guard priority"
  (check-equal? (raw-value (describeStatus33 Active33 "administrator")) "admin active")
  (check-equal? (raw-value (describeStatus33 Active33 "Admin")) "user active")
  )

  (test-case "T14 \226\128\148 nested constructor patterns"
  (check-equal? (raw-value (unwrapInner33 Empty33)) "empty")
  (check-equal? (raw-value (unwrapInner33 (Wrapped (InnerA 42)))) "int: 42")
  (check-equal? (raw-value (unwrapInner33 (Wrapped (InnerB "hello")))) "str: hello")
  )

  (test-case "T15 \226\128\148 newtype .value accessor"
  (define w (makeWrapped33 21))
  (check-equal? (raw-value (extractWrapped33 w)) 21)
  (define dw (doubleWrapped33 w))
  (check-equal? (raw-value (extractWrapped33 dw)) 42)
  (check-equal? (raw-value (extractWrapped33 (makeWrapped33 0))) 0)
  (check-equal? (raw-value (extractWrapped33 (makeWrapped33 -5))) -5)
  )

  (test-case "T15b \226\128\148 newtype identity"
  (define a (makeWrapped33 10))
  (define b (doubleWrapped33 a))
  (define c (doubleWrapped33 b))
  (check-equal? (raw-value (extractWrapped33 c)) 40)
  )

  (test-case "T16 \226\128\148 Dict.requireKey and Dict.get"
  (define d (raw-value (tesl_import_Dict_insert "a" 1 (raw-value (tesl_import_Dict_insert "b" 2 tesl_import_Dict_empty)))))
  (check-equal? (raw-value (lookupWithProof33 "a" d)) (raw-value (Something 1)))
  (check-equal? (raw-value (lookupWithProof33 "b" d)) (raw-value (Something 2)))
  (check-equal? (raw-value (lookupWithProof33 "c" d)) Nothing)
  (define emptyD tesl_import_Dict_empty)
  (check-equal? (raw-value (lookupWithProof33 "x" emptyD)) Nothing)
  )

  (test-case "T17 \226\128\148 lambda and HOF"
  (check-equal? (raw-value (applyTwice33 (let () (define/pow (tesl-lambda-16 [x : Integer]) #:returns Integer (+ *x 3)) tesl-lambda-16) 1)) 7)
  (check-equal? (raw-value (applyTwice33 (let () (define/pow (tesl-lambda-17 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-17) 3)) 12)
  (check-equal? (raw-value (doubleAll33 (list 1 2 3))) (list 2 4 6))
  (check-equal? (raw-value (doubleAll33 (list))) (list))
  (check-equal? (raw-value (doubleAll33 (list -1 0 1))) (list -2 0 2))
  )

  (test-case "T17b \226\128\148 partial application of named function"
  (define add10 (let () (define/pow (tesl-lambda-18 [x : Integer]) #:returns Integer (+ *x 10)) tesl-lambda-18))
  (define results (tesl_import_List_map (raw-value add10) (list 1 2 3)))
  (check-equal? (raw-value results) (list 11 12 13))
  )

  (test-case "T18 \226\128\148 proof-total divide"
  (check-equal? (raw-value (proofTotalDivide33 10 2)) (raw-value (Something 5)))
  (check-equal? (raw-value (proofTotalDivide33 10 0)) Nothing)
  (check-equal? (raw-value (proofTotalDivide33 7 3)) (raw-value (Something 2)))
  (check-equal? (raw-value (proofTotalDivide33 0 5)) (raw-value (Something 0)))
  (check-equal? (raw-value (proofTotalDivide33 -10 2)) (raw-value (Something -5)))
  )

  (test-case "T18b \226\128\148 divide properties"
  ; property: divide by self is 1
  (for ([tesl-prop-i (in-range 30)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) 0) (< (raw-value n) 10000)) (check-true (let/check ([tesl_checked_19 (tesl_import_Int_nonZero n)]) (let ([divisor (attach-proof (ensure-named 'divisor (raw-value tesl_checked_19)) (detach-all-proof tesl_checked_19))]) (equal? (raw-value (tesl_import_Int_divide (raw-value n) divisor)) 1))) "divide by self is 1"))
    ))
  )

  (test-case "T19 \226\128\148 proof-total float divide"
  (check-equal? (raw-value (proofTotalFloatDiv33 10. 2.)) (raw-value (Something 5.)))
  (check-equal? (raw-value (proofTotalFloatDiv33 10. 0.)) Nothing)
  (check-equal? (raw-value (proofTotalFloatDiv33 0. 1.)) (raw-value (Something 0.)))
  )

  (test-case "T20 \226\128\148 List.allCheck semantics"
  (define allPos (allCheckSome33 (list 1 2 3 4 5)))
  (check-equal? (raw-value allPos) (raw-value (Something (list 1 2 3 4 5))))
  (define mixed (allCheckNone33 (list 1 2 -3 4)))
  (check-equal? (raw-value mixed) Nothing)
  (define empty (allCheckSome33 (list)))
  (check-equal? (raw-value empty) (raw-value (Something (list))))
  )

  (test-case "T21 \226\128\148 multi-param fact"
  (define lo 0)
  (define hi 100)
  (define n50 50)
  (define checked (checkInRange33 lo hi n50))
  (check-equal? (raw-value (requiresInRange33 lo hi checked)) "50 is in [0, 100]")
  (define lo2 0)
  (define hi2 10)
  (define nOut 11)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkInRange33 lo2 hi2 nOut)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkInRange33 lo2 hi2 nOut"))
  (define nNeg -1)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkInRange33 lo2 hi2 nNeg)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkInRange33 lo2 hi2 nNeg"))
  (define n0 0)
  (define c0 (checkInRange33 lo2 hi2 n0))
  (check-equal? (raw-value (requiresInRange33 lo2 hi2 c0)) "0 is in [0, 10]")
  )

  (test-case "T21b \226\128\148 multi-param boundary values"
  (define lo -5)
  (define hi 5)
  (define nLo -5)
  (define nHi 5)
  (define cLo (checkInRange33 lo hi nLo))
  (define cHi (checkInRange33 lo hi nHi))
  (check-equal? (raw-value (requiresInRange33 lo hi cLo)) "-5 is in [-5, 5]")
  (check-equal? (raw-value (requiresInRange33 lo hi cHi)) "5 is in [-5, 5]")
  )

  (test-case "T22 \226\128\148 forgetFact then re-check"
  (check-equal? (raw-value (tryForgetRecheck33 5)) (raw-value (Something 5)))
  (check-equal? (raw-value (tryForgetRecheck33 -5)) Nothing)
  (check-equal? (raw-value (tryForgetRecheck33 1)) (raw-value (Something 1)))
  (check-equal? (raw-value (tryForgetRecheck33 0)) Nothing)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPos33 -100)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPos33 -100"))
  )

  (test-case "T23 \226\128\148 fall-through case arms"
  (check-equal? (raw-value (classifyWeekend33 Saturday33)) "weekend")
  (check-equal? (raw-value (classifyWeekend33 Sunday33)) "weekend")
  (check-equal? (raw-value (classifyWeekend33 Monday33)) "weekday")
  (check-equal? (raw-value (classifyWeekend33 Friday33)) "weekday")
  (check-equal? (raw-value (classifyWeekend33 Wednesday33)) "weekday")
  )

  (test-case "T24 \226\128\148 sort idempotency"
  ; property: sort is idempotent
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (equal? (raw-value (sortedInts33 (sortedInts33 xs))) (raw-value (sortedInts33 xs))) "sort is idempotent")
    ))
  )

  (test-case "T24b \226\128\148 sort correctness"
  (check-equal? (raw-value (sortedInts33 (list 3 1 2))) (list 1 2 3))
  (check-equal? (raw-value (sortedInts33 (list))) (list))
  (check-equal? (raw-value (sortedInts33 (list 1))) (list 1))
  (check-equal? (raw-value (sortedInts33 (list 2 2 1))) (list 1 2 2))
  (check-equal? (raw-value (sortedInts33 (list 5 4 3 2 1))) (list 1 2 3 4 5))
  )

  (test-case "T25 \226\128\148 Either.partition"
  (define mixed (list (Left "error1") (Right 1) (Left "error2") (Right 2) (Right 3)))
  (define result (partitionEithers33 mixed))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value result)))) (list "error1" "error2"))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value result)))) (list 1 2 3))
  (define allLeft (list (Left "a") (Left "b")))
  (define r2 (partitionEithers33 allLeft))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value r2)))) (list "a" "b"))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value r2)))) (list))
  (define allRight (list (Right 10) (Right 20)))
  (define r3 (partitionEithers33 allRight))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value r3)))) (list))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value r3)))) (list 10 20))
  (define empty (partitionEithers33 (list)))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value empty)))) (list))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value empty)))) (list))
  )

  (test-case "T26 \226\128\148 Set operations"
  (define s1 (raw-value (tesl_import_Set_fromList (list 1 2 3 2 1))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_member 1 (raw-value s1)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Set_member 4 (raw-value s1)))) #f)
  (define s2 (raw-value (tesl_import_Set_insert 4 (raw-value s1))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_member 4 (raw-value s2)))) #t)
  (define sorted (tesl_import_List_sort (raw-value (tesl_import_Set_toList (raw-value s1)))))
  (check-equal? (raw-value sorted) (list 1 2 3))
  )

  (test-case "T27 \226\128\148 String edge cases"
  (check-equal? (raw-value (tesl_import_String_length "")) 0)
  (check-equal? (raw-value (tesl_import_String_isEmpty "")) #t)
  (check-equal? (raw-value (tesl_import_String_isEmpty "a")) #f)
  (define trimmed (tesl_import_String_trim "  hello  "))
  (check-equal? (raw-value trimmed) "hello")
  (check-equal? (raw-value (tesl_import_String_trim "")) "")
  (check-equal? (raw-value (tesl_import_String_trim "  ")) "")
  (check-equal? (raw-value (tesl_import_String_contains "" "x")) #f)
  (check-equal? (raw-value (tesl_import_String_contains "hello" "")) #t)
  (check-equal? (raw-value (tesl_import_String_startsWith "hello" "he")) #t)
  (check-equal? (raw-value (tesl_import_String_startsWith "hello" "world")) #f)
  (check-equal? (raw-value (tesl_import_String_startsWith "" "")) #t)
  )

  (test-case "T27b \226\128\148 String length property"
  ; property: trim length <= original
  (for ([tesl-prop-i (in-range 30)])
    (let ([s (format "s~a" (random 1000000))])
      (check-true (<= (raw-value (tesl_import_String_length (raw-value (tesl_import_String_trim (raw-value s))))) (raw-value (tesl_import_String_length (raw-value s)))) "trim length <= original")
    ))
  )

  (test-case "T28 \226\128\148 List edge cases"
  (check-equal? (raw-value (raw-value (tesl_import_List_head (list)))) Nothing)
  (check-equal? (raw-value (raw-value (tesl_import_List_head (list 1 2 3)))) (raw-value (Something 1)))
  (check-equal? (raw-value (raw-value (tesl_import_List_isEmpty (list)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_isEmpty (list 1)))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_List_length (list)))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_List_length (list 1 2 3)))) 3)
  (check-equal? (raw-value (tesl_import_List_reverse (list))) (list))
  (check-equal? (raw-value (tesl_import_List_reverse (list 1))) (list 1))
  (check-equal? (raw-value (tesl_import_List_reverse (list 1 2 3))) (list 3 2 1))
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list)))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list 1 2 3)))) 6)
  (check-equal? (raw-value (tesl_import_List_append (list 1 2) (list 3 4))) (list 1 2 3 4))
  (check-equal? (raw-value (tesl_import_List_append (list) (list 1))) (list 1))
  (check-equal? (raw-value (tesl_import_List_append (list 1) (list))) (list 1))
  )

  (test-case "T28b \226\128\148 List property tests"
  ; property: length after append
  (for ([tesl-prop-i (in-range 30)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))] [ys (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_List_append (raw-value xs) (raw-value ys))))) (+ (raw-value (tesl_import_List_length (raw-value xs))) (raw-value (tesl_import_List_length (raw-value ys))))) "length after append")
    ))
  ; property: reverse is involution
  (for ([tesl-prop-i (in-range 30)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (equal? (raw-value (tesl_import_List_reverse (raw-value (tesl_import_List_reverse (raw-value xs))))) (raw-value xs)) "reverse is involution")
    ))
  )

  (test-case "T29 \226\128\148 List.take and List.drop with NonNegative proof"
  (define raw3 3)
  (define raw0 0)
  (define tesl_checked_20 (tesl_import_Int_nonNegative raw3))
  (when (check-fail? tesl_checked_20)
    (raise-user-error 'tesl-test "unexpected failure in let n3: ~a" (check-fail-message tesl_checked_20)))
  (define n3 (attach-proof (ensure-named 'n3 (raw-value tesl_checked_20)) (detach-all-proof tesl_checked_20)))
  (define tesl_checked_21 (tesl_import_Int_nonNegative raw0))
  (when (check-fail? tesl_checked_21)
    (raise-user-error 'tesl-test "unexpected failure in let n0: ~a" (check-fail-message tesl_checked_21)))
  (define n0 (attach-proof (ensure-named 'n0 (raw-value tesl_checked_21)) (detach-all-proof tesl_checked_21)))
  (define xs (list 1 2 3 4 5))
  (check-equal? (raw-value (tesl_import_List_take n3 (raw-value xs))) (list 1 2 3))
  (check-equal? (raw-value (tesl_import_List_take n0 (raw-value xs))) (list))
  (check-equal? (raw-value (tesl_import_List_drop n3 (raw-value xs))) (list 4 5))
  (check-equal? (raw-value (tesl_import_List_drop n0 (raw-value xs))) (list 1 2 3 4 5))
  )

  (test-case "T30 \226\128\148 Bool literal capitalization"
  (check-equal? (raw-value (boolLiterals33)) #t)
  (check-equal? (raw-value (boolNegation33 #t)) #f)
  (check-equal? (raw-value (boolNegation33 #f)) #t)
  (check-equal? (raw-value (equal? 1 1)) #t)
  (check-equal? (raw-value (equal? 1 2)) #f)
  )

  (test-case "FIX-01a \226\128\148 case nullary constructor in test block"
  (define s FixPoint33)
  (let ([*tesl_case_22 (raw-value 
    s)]) (cond
    [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'FixCircle33))
      (check-equal? 1 2)
    ]
    [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'FixRect33))
      (check-equal? 1 2)
    ]
    [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'FixPoint33))
      (check-equal? 1 1)
    ]
  ))
  )

  (test-case "FIX-01b \226\128\148 case PCon field binding in test block"
  (define s (raw-value (FixCircle33 7)))
  (let ([*tesl_case_23 (raw-value 
    s)]) (cond
    [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'FixCircle33))
      (let ([r (hash-ref (adt-value-fields *tesl_case_23) 'radius)])
        (check-equal? (raw-value r) 7)
      )
    ]
    [#t
      (check-equal? 1 2)
    ]
  ))
  )

  (test-case "FIX-01c \226\128\148 case multi-field PCon in test block"
  (define s (raw-value (FixRect33 3 4)))
  (let ([*tesl_case_24 (raw-value 
    s)]) (cond
    [(and (adt-value? *tesl_case_24) (eq? (adt-value-variant *tesl_case_24) 'FixCircle33))
      (check-equal? 1 2)
    ]
    [(and (adt-value? *tesl_case_24) (eq? (adt-value-variant *tesl_case_24) 'FixRect33))
      (let ([w (hash-ref (adt-value-fields *tesl_case_24) 'w)])
      (let ([h (hash-ref (adt-value-fields *tesl_case_24) 'h)])
        (check-equal? (raw-value (+ (raw-value w) (raw-value h))) 7)
      )
      )
    ]
    [(and (adt-value? *tesl_case_24) (eq? (adt-value-variant *tesl_case_24) 'FixPoint33))
      (check-equal? 1 2)
    ]
  ))
  )

  (test-case "FIX-01d \226\128\148 case PVar catch-all in test block"
  (define s (raw-value (FixCircle33 99)))
  (let ([*tesl_case_25 (raw-value 
    s)]) (cond
    [#t
      (let ([v *tesl_case_25])
        (check-equal? (raw-value #t) #t)
      )
    ]
  ))
  )

  (test-case "FIX-01e \226\128\148 case PLit string match in test block"
  (define label "hello")
  (let ([*tesl_case_26 (raw-value 
    label)]) (cond
    [(equal? *tesl_case_26 "hello")
      (check-equal? 1 1)
    ]
    [#t
      (check-equal? 1 2)
    ]
  ))
  )

  (test-case "FIX-01f \226\128\148 case PLit int match in test block"
  (define n 42)
  (let ([*tesl_case_27 (raw-value 
    n)]) (cond
    [(= *tesl_case_27 42)
      (check-equal? 1 1)
    ]
    [#t
      (check-equal? 1 2)
    ]
  ))
  )

  (test-case "FIX-02a \226\128\148 lambda string interpolation in test block"
  (define xs (list "hello" "world"))
  (define result (tesl_import_List_map (let () (define/pow (tesl-lambda-28 [s : String]) #:returns String (format "item: ~a" (tesl-display-val *s))) tesl-lambda-28) (raw-value xs)))
  (check-equal? (raw-value result) (list "item: hello" "item: world"))
  )

  (test-case "FIX-02b \226\128\148 lambda string interpolation with Int param"
  (define ns (list 1 2 3))
  (define result (tesl_import_List_map (let () (define/pow (tesl-lambda-29 [n : Integer]) #:returns String (format "num: ~a" (tesl-display-val *n))) tesl-lambda-29) (raw-value ns)))
  (check-equal? (raw-value result) (list "num: 1" "num: 2" "num: 3"))
  )

  (test-case "FIX-02c \226\128\148 lambda multiple params string interpolation"
  (define xs (list "a" "b"))
  (define result (tesl_import_List_map (let () (define/pow (tesl-lambda-30 [s : String]) #:returns String (format "~a~a" (tesl-display-val *s) (tesl-display-val *s))) tesl-lambda-30) (raw-value xs)))
  (check-equal? (raw-value result) (list "aa" "bb"))
  )

  (test-case "FIX-03a \226\128\148 check composed (&&) result used directly"
  (define tesl_checked_31 ((check-and fixCheckPos33 fixCheckSmall33) 42))
  (when (check-fail? tesl_checked_31)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_31)))
  (define v (attach-proof (ensure-named 'v (raw-value tesl_checked_31)) (detach-all-proof tesl_checked_31)))
  (check-equal? (raw-value (fixRequiresBoth33 v)) "ok: 42")
  )

  (test-case "FIX-03b \226\128\148 detachFact on composed check result"
  (define tesl_checked_32 ((check-and fixCheckPos33 fixCheckSmall33) 7))
  (when (check-fail? tesl_checked_32)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_32)))
  (define v (attach-proof (ensure-named 'v (raw-value tesl_checked_32)) (detach-all-proof tesl_checked_32)))
  (define d (detach-proof v))
  (check-equal? (raw-value (fixRequiresBoth33 v)) "ok: 7")
  )

  (test-case "FIX-03c \226\128\148 composed check fails correctly on invalid input"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and fixCheckPos33 fixCheckSmall33) -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and fixCheckPos33 fixCheckSmall33) -1"))
  )

  (test-case "FIX-03d \226\128\148 composed check fails on second predicate"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and fixCheckPos33 fixCheckSmall33) 200)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and fixCheckPos33 fixCheckSmall33) 200"))
  )

  (test-case "FIX-05 \226\128\148 nowMillis is available, now is not"
  (check-equal? 1 1)
  )

  (test-case "FIX-06a \226\128\148 compound check with let-bound variable (not inline literal)"
  (define raw 42)
  (define tesl_checked_33 ((check-and fixCheckPos33 fixCheckSmall33) raw))
  (when (check-fail? tesl_checked_33)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_33)))
  (define v (attach-proof (ensure-named 'v (raw-value tesl_checked_33)) (detach-all-proof tesl_checked_33)))
  (check-equal? (raw-value (fixRequiresBoth33 v)) "ok: 42")
  )

  (test-case "FIX-06b \226\128\148 compound check with let-bound var, check fails correctly"
  (define raw -5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and fixCheckPos33 fixCheckSmall33) raw)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and fixCheckPos33 fixCheckSmall33) raw"))
  )

  (test-case "FIX-06c \226\128\148 compound check with let-bound var, fails on second predicate"
  (define raw 200)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and fixCheckPos33 fixCheckSmall33) raw)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and fixCheckPos33 fixCheckSmall33) raw"))
  )

)
