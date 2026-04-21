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
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.trim tesl_import_String_trim] [String.contains tesl_import_String_contains] [String.isEmpty tesl_import_String_isEmpty] [String.toUpper tesl_import_String_toUpper] [String.toLower tesl_import_String_toLower] [String.startsWith tesl_import_String_startsWith] [String.endsWith tesl_import_String_endsWith] [String.split tesl_import_String_split] [String.join tesl_import_String_join] [String.replace tesl_import_String_replace])
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filter tesl_import_List_filter] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.foldl tesl_import_List_foldl] [List.sort tesl_import_List_sort] [List.length tesl_import_List_length] [List.any tesl_import_List_any] [List.all tesl_import_List_all] [List.head tesl_import_List_head] [List.isEmpty tesl_import_List_isEmpty] [List.tail tesl_import_List_tail] [List.contains tesl_import_List_contains] [List.find tesl_import_List_find] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop] [List.sum tesl_import_List_sum] [List.product tesl_import_List_product] [List.reverse tesl_import_List_reverse] [List.unique tesl_import_List_unique] [List.append tesl_import_List_append])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide] IsNonZero [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/either Either Left Right [Either.map tesl_import_Either_map] [Either.andThen tesl_import_Either_andThen] [Either.withDefault tesl_import_Either_withDefault])
  (only-in tesl/tesl/float Float [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero [Float.div tesl_import_Float_div] [Float.sqrt tesl_import_Float_sqrt])
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
)


(provide IsRange28 checkRange28 requiresRange28 proofRoundTrip IsNonEmpty28 IsShort28 checkNonEmpty28 checkShort28 requiresNonEmpty28 combinedCheck28 UserId28 ProjectId28 makeUser28 makeProject28 requiresUser28 requiresProject28 boolToString28 IsValidEmail28 checkEmail28 proofForgotten28 IsEven28 checkEven28 doubleEven28 doubleAllEven28 interpolateInt28 interpolateNeg28 BinTree28 Leaf28 Node28 treeSum28 treeHeight28 add28 multiply28 doubleAll28 Bounded28 checkBounded28 requiresBounded28 wrapBounded28 Weekday28 Monday28 Tuesday28 Wednesday28 Thursday28 Friday28 Saturday28 Sunday28 classifyDay28 Category28 Fruit28 Vegetable28 Dairy28 Meat28 Grain28 describeCategory28 IsSmall28 proveSmall28 applySmall28 filteredSubset28 IsTrimmed28 IsLong28 checkTrimmed28 checkLong28 validateTrimmedLong28 headOrDefault28 safeHead28 nestedMaybeCheck28 safeDivide28 negArithmetic28 maxSafeInt28 swapPair28 roundTripProof28 allCheckResult28 safeFloatDiv28 doubleRight28 divOrError28 listLengthNonNeg28 listSumReverseSame28 checkRange28-signature requiresRange28-signature proofRoundTrip-signature checkNonEmpty28-signature checkShort28-signature requiresNonEmpty28-signature combinedCheck28-signature makeUser28-signature makeProject28-signature requiresUser28-signature requiresProject28-signature boolToString28-signature checkEmail28-signature proofForgotten28-signature checkEven28-signature doubleEven28-signature doubleAllEven28-signature interpolateInt28-signature interpolateNeg28-signature treeSum28-signature treeHeight28-signature add28-signature multiply28-signature doubleAll28-signature checkBounded28-signature requiresBounded28-signature wrapBounded28-signature classifyDay28-signature describeCategory28-signature proveSmall28-signature applySmall28-signature filteredSubset28-signature checkTrimmed28-signature checkLong28-signature validateTrimmedLong28-signature safeHead28-signature headOrDefault28-signature nestedMaybeCheck28-signature safeDivide28-signature negArithmetic28-signature maxSafeInt28-signature swapPair28-signature roundTripProof28-signature allCheckResult28-signature safeFloatDiv28-signature divOrError28-signature doubleRight28-signature listLengthNonNeg28-signature listSumReverseSame28-signature)

(define Bounded28 'Bounded28)
(define IsEven28 'IsEven28)
(define IsLong28 'IsLong28)
(define IsNonEmpty28 'IsNonEmpty28)
(define IsRange28 'IsRange28)
(define IsShort28 'IsShort28)
(define IsSmall28 'IsSmall28)
(define IsTrimmed28 'IsTrimmed28)
(define IsValidEmail28 'IsValidEmail28)

(define-checker
  (checkRange28 [n : Integer])
  #:returns [n : Integer ::: (IsRange28 n)]
  (if (and (>= *n 0) (<= *n 1000)) (accept (IsRange28 n) #:value *n) (reject "out of 0\u20131000 range" #:http-code 400)))

(define/pow
  (requiresRange28 [n : Integer ::: (IsRange28 n)])
  #:returns Integer
  (+ *n 1))

(define/pow
  (proofRoundTrip [raw : Integer])
  #:returns Integer
  (let ([v (checkRange28 raw)]) (raw-value (requiresRange28 v))))

(define-checker
  (checkNonEmpty28 [s : String])
  #:returns [s : String ::: (IsNonEmpty28 s)]
  (if (tesl_import_String_isEmpty *s) (reject "empty" #:http-code 400) (accept (IsNonEmpty28 s) #:value *s)))

(define-checker
  (checkShort28 [s : String ::: (IsNonEmpty28 s)])
  #:returns [s : String ::: (IsShort28 s)]
  (if (<= (raw-value (tesl_import_String_length *s)) 50) (accept (IsShort28 s) #:value *s) (reject "too long" #:http-code 400)))

(define/pow
  (requiresNonEmpty28 [s : String ::: (IsNonEmpty28 s)])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define/pow
  (requiresBothProofs28 [s : String ::: (IsNonEmpty28 s)] [s2 : String ::: (IsShort28 s2)])
  #:returns String
  (format "~a / ~a" (tesl-display-val *s) (tesl-display-val *s2)))

(define/pow
  (combinedCheck28 [raw : String])
  #:returns String
  (let/check ([tesl_checked_0 (checkNonEmpty28 raw)]) (let ([ne (attach-proof (ensure-named 'ne (raw-value tesl_checked_0)) (detach-all-proof tesl_checked_0))]) (let/check ([tesl_checked_1 (checkShort28 ne)]) (let ([short (attach-proof (ensure-named 'short (raw-value tesl_checked_1)) (detach-all-proof tesl_checked_1))]) (raw-value (requiresBothProofs28 short short)))))))

(define-newtype UserId28 String)

(define-newtype ProjectId28 String)

(define/pow
  (makeUser28 [s : String])
  #:returns UserId28
  (raw-value (UserId28 *s)))

(define/pow
  (makeProject28 [s : String])
  #:returns ProjectId28
  (raw-value (ProjectId28 *s)))

(define/pow
  (requiresUser28 [uid : UserId28])
  #:returns String
  (format "user:~a" (tesl-display-val (raw-value uid.value))))

(define/pow
  (requiresProject28 [pid : ProjectId28])
  #:returns String
  (format "project:~a" (tesl-display-val (raw-value pid.value))))

(define/pow
  (boolToString28 [b : Boolean])
  #:returns String
  (if *b (raw-value "true") (raw-value "false")))

(define-checker
  (checkEmail28 [email : String])
  #:returns [email : String ::: (IsValidEmail28 email)]
  (if (and (raw-value (tesl_import_String_contains *email "@")) (>= (raw-value (tesl_import_String_length *email)) 3)) (accept (IsValidEmail28 email) #:value *email) (reject "invalid email" #:http-code 400)))

(define/pow
  (proofForgotten28 [raw : String])
  #:returns Integer
  (let ([valid (checkEmail28 raw)]) (let ([raw2 (forget-proof valid)]) (raw-value (tesl_import_String_length (raw-value raw2))))))

(define-checker
  (checkEven28 [n : Integer])
  #:returns [n : Integer ::: (IsEven28 n)]
  (if (equal? (remainder *n 2) 0) (accept (IsEven28 n) #:value *n) (reject "not even" #:http-code 400)))

(define/pow
  (doubleEven28 [n : Integer ::: (IsEven28 n)])
  #:returns Integer
  (* *n 2))

(define/pow
  (doubleAllEven28 [xs : (List Integer)])
  #:returns (List Integer)
  (let ([evens (tesl_import_List_filterCheck checkEven28 *xs)]) (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-2 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsEven28 ,n))]) (doubleEven28 n))) tesl-lambda-2) (raw-value evens)))))

(define/pow
  (interpolateInt28 [n : Integer])
  #:returns String
  (format "n=~a" (tesl-display-val *n)))

(define/pow
  (interpolateNeg28 [a : Integer] [b : Integer])
  #:returns String
  (format "diff=~a" (tesl-display-val (- *a *b))))

(define-adt BinTree28
  [Leaf28]
  [Node28 [left : BinTree28] [value : Integer] [right : BinTree28]]
)

(define/pow
  (treeSum28 [t : BinTree28])
  #:returns Integer
  (let ([tesl_case_3 *t]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Leaf28)) (raw-value 0)] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Node28)) (let ([left (hash-ref (adt-value-fields *tesl_case_3) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl_case_3) 'right)]) (raw-value (+ (+ (raw-value (treeSum28 *left)) *v) (raw-value (treeSum28 *right)))))))])))

(define/pow
  (treeHeight28 [t : BinTree28])
  #:returns Integer
  (let ([tesl_case_4 *t]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Leaf28)) (raw-value 0)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Node28)) (let ([left (hash-ref (adt-value-fields *tesl_case_4) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_4) 'right)]) (let ([lh (treeHeight28 *left)]) (let ([rh (treeHeight28 *right)]) (if (> (raw-value lh) (raw-value rh)) (raw-value (+ (raw-value lh) 1)) (raw-value (+ (raw-value rh) 1)))))))])))

(define/pow
  (add28 [x : Integer] [y : Integer])
  #:returns Integer
  (+ *x *y))

(define/pow
  (multiply28 [x : Integer] [y : Integer])
  #:returns Integer
  (* *x *y))

(define/pow
  (doubleAll28 [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (raw-value (lambda (_tesl_p5_0) (multiply28 2 _tesl_p5_0))) *xs)))

(define-checker
  (checkBounded28 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (Bounded28 lo hi n)]
  (if (and (>= *n *lo) (<= *n *hi)) (accept (Bounded28 lo hi n) #:value *n) (reject "value out of bounds" #:http-code 400)))

(define/pow
  (requiresBounded28 [lo : Integer] [hi : Integer] [n : Integer ::: (Bounded28 lo hi n)])
  #:returns String
  (format "~a in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))

(define/pow
  (wrapBounded28 [rawLo : Integer] [rawHi : Integer] [raw : Integer])
  #:returns String
  (let ([lo rawLo]) (let ([hi rawHi]) (let ([v (checkBounded28 lo hi raw)]) (raw-value (requiresBounded28 lo hi v))))))

(define-adt Weekday28
  [Monday28]
  [Tuesday28]
  [Wednesday28]
  [Thursday28]
  [Friday28]
  [Saturday28]
  [Sunday28]
)

(define/pow
  (classifyDay28 [day : Weekday28])
  #:returns String
  (let ([tesl_case_6 *day]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Saturday28)) (raw-value "weekend")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Sunday28)) (raw-value "weekend")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Monday28)) (raw-value "weekday")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Tuesday28)) (raw-value "weekday")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Wednesday28)) (raw-value "weekday")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Thursday28)) (raw-value "weekday")] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Friday28)) (raw-value "weekday")])))

(define-adt Category28
  [Fruit28]
  [Vegetable28]
  [Dairy28]
  [Meat28]
  [Grain28]
)

(define/pow
  (describeCategory28 [c : Category28])
  #:returns String
  (let ([tesl_case_7 *c]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Fruit28)) (raw-value "plant")] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Vegetable28)) (raw-value "plant")] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Dairy28)) (raw-value "animal")] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Meat28)) (raw-value "animal")] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Grain28)) (raw-value "starch")])))

(define-trusted
  (proveSmall28 [n : Integer])
  #:returns (Maybe (Fact (IsSmall28 n)))
  (if (< *n 10) (Something (trusted-proof (IsSmall28 n))) Nothing))

(define/pow
  (useSmall28 [n : Integer ::: (IsSmall28 n)])
  #:returns String
  (format "small: ~a" (tesl-display-val *n)))

(define/pow
  (applySmall28 [n : Integer])
  #:returns String
  (let ([mProof (proveSmall28 n)]) (let ([tesl_case_8 (raw-value mProof)]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Nothing)) (raw-value "not small")] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl_case_8) 'value)]) (raw-value (useSmall28 (attach-proof n p))))]))))

(define/pow
  (filteredSubset28 [xs : (List Integer)])
  #:returns Boolean
  (equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_List_sort *xs)))) (raw-value (tesl_import_List_length *xs))))

(define-checker
  (checkTrimmed28 [s : String])
  #:returns [s : String ::: (IsTrimmed28 s)]
  (if (equal? (raw-value (tesl_import_String_trim *s)) *s) (accept (IsTrimmed28 s) #:value *s) (reject "not trimmed" #:http-code 400)))

(define-checker
  (checkLong28 [s : String ::: (IsTrimmed28 s)])
  #:returns [s : String ::: (IsLong28 s)]
  (if (>= (raw-value (tesl_import_String_length *s)) 5) (accept (IsLong28 s) #:value *s) (reject "too short" #:http-code 400)))

(define/pow
  (requiresTrimmedAndLong28 [s : String ::: (IsTrimmed28 s)] [s2 : String ::: (IsLong28 s2)])
  #:returns String
  (format "ok: ~a" (tesl-display-val *s)))

(define/pow
  (validateTrimmedLong28 [raw : String])
  #:returns String
  (let/check ([tesl_checked_9 (checkTrimmed28 raw)]) (let ([trimmed (attach-proof (ensure-named 'trimmed (raw-value tesl_checked_9)) (detach-all-proof tesl_checked_9))]) (let/check ([tesl_checked_10 (checkLong28 trimmed)]) (let ([long (attach-proof (ensure-named 'long (raw-value tesl_checked_10)) (detach-all-proof tesl_checked_10))]) (raw-value (requiresTrimmedAndLong28 long long)))))))

(define/pow
  (safeHead28 [xs : (List Integer)])
  #:returns (Maybe Integer)
  (raw-value (tesl_import_List_head *xs)))

(define/pow
  (headOrDefault28 [xs : (List Integer)] [def : Integer])
  #:returns Integer
  (let ([tesl_case_11 (raw-value (safeHead28 xs))]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Nothing)) *def] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Something)) (let ([h (hash-ref (adt-value-fields *tesl_case_11) 'value)]) *h)])))

(define/pow
  (nestedMaybeCheck28 [m : (Maybe (Maybe Integer))])
  #:returns Integer
  (let ([tesl_case_12 *m]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Nothing)) (raw-value -1)] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Something)) (let ([inner (hash-ref (adt-value-fields *tesl_case_12) 'value)]) (let ([tesl_case_13 (raw-value inner)]) (cond [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Nothing)) (raw-value -2)] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_13) 'value)]) *n)])))])))

(define/pow
  (safeDivide28 [a : Integer] [b : Integer])
  #:returns (Either String Integer)
  (if (equal? *b 0) (raw-value (raw-value (Left "division by zero"))) (let/check ([tesl_checked_14 (tesl_import_Int_nonZero b)]) (let ([nb (attach-proof (ensure-named 'nb (raw-value tesl_checked_14)) (detach-all-proof tesl_checked_14))]) (raw-value (raw-value (Right (tesl_import_Int_divide *a nb))))))))

(define/pow
  (negArithmetic28 [a : Integer] [b : Integer])
  #:returns Integer
  (- *a *b))

(define/pow
  (maxSafeInt28)
  #:returns Integer
  4611686018427387903)

(define/pow
  (swapPair28 [a : Integer] [b : String])
  #:returns (Tuple2 String Integer)
  (raw-value (Tuple2 *b *a)))

(define/pow
  (roundTripProof28 [n : Integer])
  #:returns Integer
  (let ([v (checkRange28 n)]) (let ([tesl_proof_binding_15 v]) (let ([raw (forget-proof tesl_proof_binding_15)] [proof (detach-all-proof tesl_proof_binding_15)]) (let ([reattached (attach-proof raw proof)]) (raw-value (requiresRange28 reattached)))))))

(define/pow
  (forgetAndRaw28 [n : Integer])
  #:returns Boolean
  (let ([v (checkRange28 n)]) (let ([forgotten (forget-proof v)]) (let ([tesl_proof_binding_16 v]) (let ([raw (forget-proof tesl_proof_binding_16)] [_proof (detach-all-proof tesl_proof_binding_16)]) (equal? (raw-value forgotten) (raw-value raw)))))))

(define/pow
  (allCheckResult28 [xs : (List Integer)])
  #:returns String
  (let ([result (tesl_import_List_allCheck checkRange28 *xs)]) (let ([tesl_case_17 (raw-value result)]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Nothing)) (raw-value "failed")] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Something)) (raw-value "ok")]))))

(define/pow
  (safeFloatDiv28 [a : Real] [b : Real])
  #:returns (Either String Real)
  (if (equal? *b 0.) (raw-value (raw-value (Left "zero"))) (let/check ([tesl_checked_18 (tesl_import_Float_requireNonZero b)]) (let ([nb (attach-proof (ensure-named 'nb (raw-value tesl_checked_18)) (detach-all-proof tesl_checked_18))]) (raw-value (raw-value (Right (raw-value (tesl_import_Float_div *a nb)))))))))

(define/pow
  (divOrError28 [a : Integer] [b : Integer])
  #:returns (Either String Integer)
  (if (equal? *b 0) (raw-value (raw-value (Left "zero"))) (let/check ([tesl_checked_19 (tesl_import_Int_nonZero b)]) (let ([nb (attach-proof (ensure-named 'nb (raw-value tesl_checked_19)) (detach-all-proof tesl_checked_19))]) (raw-value (raw-value (Right (tesl_import_Int_divide *a nb))))))))

(define/pow
  (doubleRight28 [e : (Either String Integer)])
  #:returns (Either String Integer)
  (raw-value (tesl_import_Either_map (raw-value (lambda (_tesl_p20_0) (multiply28 2 _tesl_p20_0))) *e)))

(define/pow
  (callCheck28 [raw : Integer])
  #:returns Integer
  (let ([v (checkRange28 raw)]) (raw-value (requiresRange28 v))))

(define/pow
  (listLengthNonNeg28 [xs : (List Integer)])
  #:returns Boolean
  (>= (raw-value (tesl_import_List_length *xs)) 0))

(define/pow
  (listSumReverseSame28 [xs : (List Integer)])
  #:returns Boolean
  (equal? (raw-value (tesl_import_List_sum *xs)) (raw-value (tesl_import_List_sum (raw-value (tesl_import_List_reverse *xs))))))

(module+ test
  (require rackunit)
  (test-case "T01a: proof round-trip in bounds"
  (check-equal? (raw-value (proofRoundTrip 500)) 501)
  (check-equal? (raw-value (proofRoundTrip 0)) 1)
  (check-equal? (raw-value (proofRoundTrip 1000)) 1001)
  )

  (test-case "T01b: proof round-trip out of bounds fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (proofRoundTrip -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofRoundTrip -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (proofRoundTrip 1001)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofRoundTrip 1001"))
  )

  (test-case "T01c: proof flow through helper function"
  (check-equal? (raw-value (proofRoundTrip 42)) 43)
  (check-equal? (raw-value (proofRoundTrip 0)) 1)
  (check-equal? (raw-value (proofRoundTrip 999)) 1000)
  )

  (test-case "T02a: sequential proof accumulation \226\128\147 valid input"
  (check-equal? (raw-value (combinedCheck28 "hello")) "hello / hello")
  )

  (test-case "T02b: sequential proof accumulation \226\128\147 fails on empty"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (combinedCheck28 "")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: combinedCheck28 \"\""))
  )

  (test-case "T02c: sequential proof accumulation \226\128\147 fails on 51-char string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (combinedCheck28 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: combinedCheck28 \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""))
  )

  (test-case "T02d: second check requires proof from first"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkShort28 "hello")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkShort28 \"hello\""))
  )

  (test-case "T03a: UserId28 round-trip"
  (define uid (makeUser28 "u123"))
  (check-equal? (raw-value (requiresUser28 uid)) "user:u123")
  )

  (test-case "T03b: ProjectId28 round-trip"
  (define pid (makeProject28 "p456"))
  (check-equal? (raw-value (requiresProject28 pid)) "project:p456")
  )

  (test-case "T03c: newtypes over same base have same .value but different types"
  (define uid (makeUser28 "same"))
  (define pid (makeProject28 "same"))
  (check-equal? (raw-value (tesl-dot/runtime uid 'value)) (raw-value (tesl-dot/runtime pid 'value)))
  (check-equal? (raw-value (requiresUser28 uid)) "user:same")
  (check-equal? (raw-value (requiresProject28 pid)) "project:same")
  )

  (test-case "T03d: newtype value is accessible via .value"
  (define uid (raw-value (UserId28 "abc")))
  (check-equal? (raw-value (tesl-dot/runtime uid 'value)) "abc")
  )

  (test-case "T04a: manual Bool-to-string conversion works"
  (check-equal? (raw-value (boolToString28 #t)) "true")
  (check-equal? (raw-value (boolToString28 #f)) "false")
  )

  (test-case "T04b: Bool interpolation produces Tesl repr (true/false)"
  (check-equal? (format "~a" (tesl-display-val #t)) "true")
  (check-equal? (format "~a" (tesl-display-val #f)) "false")
  )

  (test-case "T04c: Bool comparison still works correctly"
  (check-equal? (raw-value #t) #t)
  (check-equal? (raw-value #f) #f)
  (check-not-equal? #t #f)
  )

  (test-case "T05a: forgetFact preserves raw value length"
  (check-equal? (raw-value (proofForgotten28 "a@b.c")) 5)
  )

  (test-case "T05b: forgetFact result usable in non-proof functions"
  (define email "user@example.com")
  (define v (checkEmail28 email))
  (define raw (forget-proof v))
  (check-equal? (raw-value (tesl_import_String_length (raw-value raw))) 16)
  )

  (test-case "T05c: check still validates before forgetFact"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (proofForgotten28 "notanemail")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofForgotten28 \"notanemail\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (proofForgotten28 "")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofForgotten28 \"\""))
  )

  (test-case "T06a: double all even numbers in list"
  (check-equal? (raw-value (doubleAllEven28 (list 1 2 3 4 5 6))) (list 4 8 12))
  )

  (test-case "T06b: doubleAllEven28 on all-odd list"
  (check-equal? (raw-value (doubleAllEven28 (list 1 3 5 7))) (list))
  )

  (test-case "T06c: doubleAllEven28 includes zero"
  (check-equal? (raw-value (doubleAllEven28 (list 0 1 2))) (list 0 4))
  )

  (test-case "T06d: doubleAllEven28 on empty list"
  (check-equal? (raw-value (doubleAllEven28 (list))) (list))
  )

  (test-case "T06e: proof-requiring fn cannot be passed directly to map"
  (define evens (tesl_import_List_filterCheck checkEven28 (list 2 4 6)))
  (define result (tesl_import_List_map (let () (define/pow (tesl-lambda-21 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsEven28 ,n))]) (doubleEven28 n))) tesl-lambda-21) (raw-value evens)))
  (check-equal? (raw-value result) (list 4 8 12))
  )

  (test-case "T07a: positive int interpolation"
  (check-equal? (raw-value (interpolateInt28 42)) "n=42")
  )

  (test-case "T07b: zero interpolation"
  (check-equal? (raw-value (interpolateInt28 0)) "n=0")
  )

  (test-case "T07c: negative int interpolation"
  (check-equal? (raw-value (interpolateInt28 -7)) "n=-7")
  )

  (test-case "T07d: arithmetic in interpolation"
  (define a 3)
  (define b 4)
  (check-equal? (format "~a" (tesl-display-val (+ (raw-value a) (raw-value b)))) "7")
  )

  (test-case "T07e: subtraction in interpolation"
  (check-equal? (raw-value (interpolateNeg28 10 3)) "diff=7")
  (check-equal? (raw-value (interpolateNeg28 3 10)) "diff=-7")
  )

  (test-case "T07f: string concat and interpolation"
  (check-equal? (raw-value (string-append (string-append "hello" " ") "world")) "hello world")
  (define name "Tesl")
  (check-equal? (format "Hello, ~a!" (tesl-display-val name)) "Hello, Tesl!")
  )

  (test-case "T08a: treeSum on leaf = 0"
  (check-equal? (raw-value (treeSum28 Leaf28)) 0)
  )

  (test-case "T08b: treeSum single node"
  (check-equal? (raw-value (treeSum28 (Node28 Leaf28 5 Leaf28))) 5)
  )

  (test-case "T08c: treeSum multi-level"
  (check-equal? (raw-value (treeSum28 (Node28 (Node28 Leaf28 3 Leaf28) 5 (Node28 Leaf28 7 Leaf28)))) 15)
  )

  (test-case "T08d: treeHeight of leaf = 0"
  (check-equal? (raw-value (treeHeight28 Leaf28)) 0)
  )

  (test-case "T08e: treeHeight single node = 1"
  (check-equal? (raw-value (treeHeight28 (Node28 Leaf28 1 Leaf28))) 1)
  )

  (test-case "T08f: treeHeight skewed right"
  (check-equal? (raw-value (treeHeight28 (Node28 Leaf28 1 (Node28 Leaf28 2 (Node28 Leaf28 3 Leaf28))))) 3)
  )

  (test-case "T08g: height is always positive for non-leaf"
  ; property: height non-negative
  (for ([tesl-prop-i (in-range 30)])
    (let ([n (- (random 2000001) 1000000)])
      (check-true (> (raw-value (treeHeight28 (Node28 Leaf28 n Leaf28))) 0) "height non-negative")
    ))
  )

  (test-case "T08h: summing mirrored tree"
  (define t1 (raw-value (Node28 (Node28 Leaf28 1 Leaf28) 2 (Node28 Leaf28 3 Leaf28))))
  (define t2 (raw-value (Node28 (Node28 Leaf28 3 Leaf28) 2 (Node28 Leaf28 1 Leaf28))))
  (check-equal? (raw-value (treeSum28 t1)) (treeSum28 t2))
  )

  (test-case "T09a: partial application of add28"
  (define addFive (lambda (_tesl_p22_0) (add28 5 _tesl_p22_0)))
  (check-equal? (raw-value (addFive 3)) 8)
  (check-equal? (raw-value (addFive 0)) 5)
  )

  (test-case "T09b: partial application in List.map"
  (check-equal? (raw-value (doubleAll28 (list 1 2 3))) (list 2 4 6))
  (check-equal? (raw-value (doubleAll28 (list))) (list))
  )

  (test-case "T09c: partial application with three values"
  (define addThree (lambda (_tesl_p23_0) (add28 3 _tesl_p23_0)))
  (check-equal? (raw-value (tesl_import_List_map (raw-value addThree) (list 1 2 3 4))) (list 4 5 6 7))
  )

  (test-case "T09d: partial application of multiply28"
  (define triple (lambda (_tesl_p24_0) (multiply28 3 _tesl_p24_0)))
  (check-equal? (raw-value (triple 5)) 15)
  (check-equal? (raw-value (triple 0)) 0)
  (check-equal? (raw-value (triple -2)) -6)
  )

  (test-case "T10a: bounded proof on valid value"
  (check-equal? (raw-value (wrapBounded28 0 100 50)) "50 in [0, 100]")
  )

  (test-case "T10b: bounded proof boundary values"
  (check-equal? (raw-value (wrapBounded28 0 100 0)) "0 in [0, 100]")
  (check-equal? (raw-value (wrapBounded28 0 100 100)) "100 in [0, 100]")
  )

  (test-case "T10c: bounded proof rejects out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (wrapBounded28 0 100 -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapBounded28 0 100 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (wrapBounded28 0 100 101)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapBounded28 0 100 101"))
  )

  (test-case "T10d: bounded proof with negative range"
  (check-equal? (raw-value (wrapBounded28 -50 50 0)) "0 in [-50, 50]")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (wrapBounded28 -50 50 51)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapBounded28 -50 50 51"))
  )

  (test-case "T10e: bounded proof degenerate range (lo == hi)"
  (check-equal? (raw-value (wrapBounded28 5 5 5)) "5 in [5, 5]")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (wrapBounded28 5 5 6)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapBounded28 5 5 6"))
  )

  (test-case "T11a: weekend days"
  (check-equal? (raw-value (classifyDay28 Saturday28)) "weekend")
  (check-equal? (raw-value (classifyDay28 Sunday28)) "weekend")
  )

  (test-case "T11b: weekdays via fall-through"
  (check-equal? (raw-value (classifyDay28 Monday28)) "weekday")
  (check-equal? (raw-value (classifyDay28 Friday28)) "weekday")
  (check-equal? (raw-value (classifyDay28 Wednesday28)) "weekday")
  (check-equal? (raw-value (classifyDay28 Tuesday28)) "weekday")
  (check-equal? (raw-value (classifyDay28 Thursday28)) "weekday")
  )

  (test-case "T11c: category fall-through plant"
  (check-equal? (raw-value (describeCategory28 Fruit28)) "plant")
  (check-equal? (raw-value (describeCategory28 Vegetable28)) "plant")
  )

  (test-case "T11d: category fall-through animal"
  (check-equal? (raw-value (describeCategory28 Dairy28)) "animal")
  (check-equal? (raw-value (describeCategory28 Meat28)) "animal")
  )

  (test-case "T11e: category grain has own body"
  (check-equal? (raw-value (describeCategory28 Grain28)) "starch")
  )

  (test-case "T12a: establish returns Something for small value"
  (check-equal? (raw-value (applySmall28 5)) "small: 5")
  (check-equal? (raw-value (applySmall28 0)) "small: 0")
  (check-equal? (raw-value (applySmall28 9)) "small: 9")
  )

  (test-case "T12b: establish returns Nothing for large value"
  (check-equal? (raw-value (applySmall28 10)) "not small")
  (check-equal? (raw-value (applySmall28 100)) "not small")
  )

  (test-case "T12c: establish returns Something for negative (< 10)"
  (check-equal? (raw-value (applySmall28 -5)) "small: -5")
  (check-equal? (raw-value (applySmall28 -100)) "small: -100")
  )

  (test-case "T13a: sort preserves list length"
  (check-equal? (raw-value (filteredSubset28 (list 3 1 4 1 5 9 2 6))) #t)
  (check-equal? (raw-value (filteredSubset28 (list))) #t)
  (check-equal? (raw-value (filteredSubset28 (list 1))) #t)
  )

  (test-case "T13b: sort known examples"
  (check-equal? (raw-value (tesl_import_List_sort (list 5 4 3 2 1))) (list 1 2 3 4 5))
  (check-equal? (raw-value (tesl_import_List_sort (list 1 1 2 2))) (list 1 1 2 2))
  (check-equal? (raw-value (tesl_import_List_sort (list))) (list))
  )

  (test-case "T13c: sort preserves length \226\128\147 explicit examples"
  (check-equal? (raw-value (filteredSubset28 (list 3 1 4 1 5))) #t)
  (check-equal? (raw-value (filteredSubset28 (list -5 0 5))) #t)
  (check-equal? (raw-value (filteredSubset28 (list 100))) #t)
  )

  (test-case "T13d: sort is idempotent \226\128\147 explicit examples"
  (check-equal? (raw-value (tesl_import_List_sort (list 3 1 2))) (list 1 2 3))
  (check-equal? (raw-value (tesl_import_List_sort (list 1 2 3))) (list 1 2 3))
  (check-equal? (raw-value (tesl_import_List_sort (list 2 1 4 3))) (list 1 2 3 4))
  )

  (test-case "T14a: trimmed and long \226\128\147 passes valid input"
  (check-equal? (raw-value (validateTrimmedLong28 "hello")) "ok: hello")
  (check-equal? (raw-value (validateTrimmedLong28 "abcde")) "ok: abcde")
  )

  (test-case "T14b: fails if leading whitespace"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (validateTrimmedLong28 " hello")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: validateTrimmedLong28 \" hello\""))
  )

  (test-case "T14c: fails if trailing whitespace"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (validateTrimmedLong28 "hello ")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: validateTrimmedLong28 \"hello \""))
  )

  (test-case "T14d: fails if too short after trimming"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (validateTrimmedLong28 "ab")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: validateTrimmedLong28 \"ab\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (validateTrimmedLong28 "")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: validateTrimmedLong28 \"\""))
  )

  (test-case "T15a: head of non-empty list"
  (check-equal? (raw-value (headOrDefault28 (list 1 2 3) 0)) 1)
  )

  (test-case "T15b: head of empty list gives default"
  (check-equal? (raw-value (headOrDefault28 (list) 99)) 99)
  )

  (test-case "T15c: nested Maybe in helper function"
  (check-equal? (raw-value (nestedMaybeCheck28 Nothing)) -1)
  (check-equal? (raw-value (nestedMaybeCheck28 (raw-value (Something Nothing)))) -2)
  (check-equal? (raw-value (nestedMaybeCheck28 (raw-value (Something (raw-value (Something 42)))))) 42)
  )

  (test-case "T15d: safeHead on single-element list"
  (check-equal? (raw-value (safeHead28 (list 7))) (raw-value (Something 7)))
  )

  (test-case "T15e: safeHead on empty list"
  (check-equal? (raw-value (safeHead28 (list))) Nothing)
  )

  (test-case "T16a: safe divide nonzero denominator"
  (check-equal? (raw-value (safeDivide28 10 2)) (raw-value (Right 5)))
  (check-equal? (raw-value (safeDivide28 7 3)) (raw-value (Right 2)))
  (check-equal? (raw-value (safeDivide28 0 5)) (raw-value (Right 0)))
  )

  (test-case "T16b: safe divide zero denominator"
  (check-equal? (raw-value (safeDivide28 10 0)) (raw-value (Left "division by zero")))
  )

  (test-case "T16c: safe divide negative denominator"
  (check-equal? (raw-value (safeDivide28 10 -2)) (raw-value (Right -5)))
  )

  (test-case "T16d: safe divide property \226\128\147 result * b \226\137\136 a"
  ; property: integer division
  (for ([tesl-prop-i (in-range 30)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)])
      (check-true (if (equal? (raw-value b) 0) (equal? (raw-value (safeDivide28 a b)) (raw-value (Left "division by zero"))) (not (equal? (raw-value (safeDivide28 a b)) (raw-value (Left "division by zero"))))) "integer division")
    ))
  )

  (test-case "T17a: subtraction positive result"
  (check-equal? (raw-value (negArithmetic28 10 3)) 7)
  )

  (test-case "T17b: subtraction negative result"
  (check-equal? (raw-value (negArithmetic28 3 10)) -7)
  )

  (test-case "T17c: modulo"
  (check-equal? (raw-value (remainder 17 5)) 2)
  (check-equal? (raw-value (remainder 0 5)) 0)
  )

  (test-case "T17d: integer division truncates toward zero"
  (check-equal? (raw-value (quotient 7 2)) 3)
  )

  (test-case "T17e: add is commutative"
  ; property: commutativity
  (for ([tesl-prop-i (in-range 100)])
    (let ([x (- (random 2000001) 1000000)] [y (- (random 2000001) 1000000)])
      (check-true (equal? (+ (raw-value x) (raw-value y)) (+ (raw-value y) (raw-value x))) "commutativity")
    ))
  )

  (test-case "T17f: multiply distributes over add"
  ; property: distributivity
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)] [c (- (random 2000001) 1000000)])
      (check-true (equal? (* (raw-value a) (+ (raw-value b) (raw-value c))) (+ (* (raw-value a) (raw-value b)) (* (raw-value a) (raw-value c)))) "distributivity")
    ))
  )

  (test-case "T17g: max safe Int is within range"
  (check-true (> (raw-value (maxSafeInt28)) 1000000000))
  )

  (test-case "T17h: negation"
  (check-equal? (raw-value (- 0 5)) -5)
  (check-equal? (raw-value (- 0 -5)) 5)
  )

  (test-case "T18a: tuple construction and access"
  (define p (raw-value (Tuple2 42 "hello")))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value p)))) 42)
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value p)))) "hello")
  )

  (test-case "T18b: swapPair28 reverses components"
  (define result (swapPair28 7 "world"))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value result)))) "world")
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value result)))) 7)
  )

  (test-case "T18c: tuple equality"
  (define p1 (raw-value (Tuple2 1 2)))
  (define p2 (raw-value (Tuple2 1 2)))
  (check-equal? (raw-value p1) p2)
  (check-not-equal? (Tuple2 1 3) p1)
  )

  (test-case "T19a: proof decompose and reattach round-trip"
  (check-equal? (raw-value (roundTripProof28 50)) 51)
  (check-equal? (raw-value (roundTripProof28 0)) 1)
  (check-equal? (raw-value (roundTripProof28 1000)) 1001)
  )

  (test-case "T19b: decompose fails propagates"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (roundTripProof28 -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: roundTripProof28 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (roundTripProof28 1001)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: roundTripProof28 1001"))
  )

  (test-case "T19c: proof forgetFact and raw decompose yield same value"
  (check-equal? (raw-value (forgetAndRaw28 5)) #t)
  (check-equal? (raw-value (forgetAndRaw28 100)) #t)
  )

  (test-case "T20a: allCheck accepts all-valid list"
  (check-equal? (raw-value (allCheckResult28 (list 0 50 100))) "ok")
  )

  (test-case "T20b: allCheck rejects list with invalid element"
  (check-equal? (raw-value (allCheckResult28 (list 0 50 1001))) "failed")
  )

  (test-case "T20c: allCheck accepts empty list"
  (check-equal? (raw-value (allCheckResult28 (list))) "ok")
  )

  (test-case "T20d: allCheck rejects negative element"
  (check-equal? (raw-value (allCheckResult28 (list -1 5 10))) "failed")
  )

  (test-case "T21a: float division"
  (check-equal? (raw-value (safeFloatDiv28 10. 4.)) (raw-value (Right 2.5)))
  )

  (test-case "T21b: float division by zero"
  (check-equal? (raw-value (safeFloatDiv28 1. 0.)) (raw-value (Left "zero")))
  )

  (test-case "T21c: float sqrt"
  (check-equal? (raw-value (raw-value (tesl_import_Float_sqrt 9.))) 3.)
  (check-equal? (raw-value (raw-value (tesl_import_Float_sqrt 4.))) 2.)
  (check-equal? (raw-value (raw-value (tesl_import_Float_sqrt 0.))) 0.)
  )

  (test-case "T21d: float arithmetic"
  (define result (safeFloatDiv28 1. 2.))
  (check-equal? (raw-value result) (raw-value (Right 0.5)))
  )

  (test-case "T22a: Either.map over Right"
  (check-equal? (raw-value (doubleRight28 (Right 5))) (raw-value (Right 10)))
  )

  (test-case "T22b: Either.map over Left is identity"
  (check-equal? (raw-value (doubleRight28 (Left "error"))) (raw-value (Left "error")))
  )

  (test-case "T22c: Either.withDefault on Left"
  (check-equal? (raw-value (raw-value (tesl_import_Either_withDefault 99 (Left "err")))) 99)
  )

  (test-case "T22d: Either.withDefault on Right"
  (check-equal? (raw-value (raw-value (tesl_import_Either_withDefault 99 (Right 42)))) 42)
  )

  (test-case "T22e: Either.andThen chains operations"
  (define result (raw-value (tesl_import_Either_andThen (raw-value (lambda (_tesl_p25_0) (divOrError28 100 _tesl_p25_0))) (raw-value (divOrError28 10 2)))))
  (check-equal? (raw-value result) (raw-value (Right 20)))
  )

  (test-case "T22f: Either.andThen short-circuits on Left"
  (define result (raw-value (tesl_import_Either_andThen (raw-value (lambda (_tesl_p26_0) (divOrError28 100 _tesl_p26_0))) (raw-value (divOrError28 10 0)))))
  (check-equal? (raw-value result) (raw-value (Left "zero")))
  )

  (test-case "T23a: fn can call check and use result with proof"
  (check-equal? (raw-value (callCheck28 500)) 501)
  )

  (test-case "T23b: fn calling check fails propagates failure"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (callCheck28 -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: callCheck28 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (callCheck28 1001)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: callCheck28 1001"))
  )

  (test-case "T24a: String.toUpper"
  (check-equal? (raw-value (tesl_import_String_toUpper "hello")) "HELLO")
  (check-equal? (raw-value (tesl_import_String_toUpper "")) "")
  )

  (test-case "T24b: String.toLower"
  (check-equal? (raw-value (tesl_import_String_toLower "HELLO")) "hello")
  (check-equal? (raw-value (tesl_import_String_toLower "MiXeD")) "mixed")
  )

  (test-case "T24c: String.trim"
  (check-equal? (raw-value (tesl_import_String_trim "  hello  ")) "hello")
  (check-equal? (raw-value (tesl_import_String_trim "hello")) "hello")
  (check-equal? (raw-value (tesl_import_String_trim "  ")) "")
  )

  (test-case "T24d: String.startsWith"
  (check-equal? (raw-value (tesl_import_String_startsWith "hello world" "hello")) #t)
  (check-equal? (raw-value (tesl_import_String_startsWith "hello world" "world")) #f)
  (check-equal? (raw-value (tesl_import_String_startsWith "" "")) #t)
  )

  (test-case "T24e: String.endsWith"
  (check-equal? (raw-value (tesl_import_String_endsWith "hello world" "world")) #t)
  (check-equal? (raw-value (tesl_import_String_endsWith "hello world" "hello")) #f)
  )

  (test-case "T24f: String.split and join round-trip"
  (define parts (tesl_import_String_split "a,b,c" ","))
  (check-equal? (raw-value (tesl_import_String_join (raw-value parts) ",")) "a,b,c")
  )

  (test-case "T24g: String.replace"
  (check-equal? (raw-value (tesl_import_String_replace "hello world" "world" "tesl")) "hello tesl")
  )

  (test-case "T24h: String.length"
  (check-equal? (raw-value (tesl_import_String_length "hello")) 5)
  (check-equal? (raw-value (tesl_import_String_length "")) 0)
  )

  (test-case "T25a: List.contains"
  (check-equal? (raw-value (raw-value (tesl_import_List_contains 2 (list 1 2 3)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_contains 4 (list 1 2 3)))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_List_contains 1 (list)))) #f)
  )

  (test-case "T25b: List.find"
  (define result (raw-value (tesl_import_List_find (let () (define/pow (tesl-lambda-27 [n : Integer]) #:returns Boolean (> *n 2)) tesl-lambda-27) (list 1 2 3 4))))
  (check-equal? (raw-value result) (raw-value (Something 3)))
  (define notFound (raw-value (tesl_import_List_find (let () (define/pow (tesl-lambda-28 [n : Integer]) #:returns Boolean (> *n 10)) tesl-lambda-28) (list 1 2))))
  (check-equal? (raw-value notFound) Nothing)
  )

  (test-case "T25c: List.take with proof"
  (define n3 3)
  (define tesl_checked_29 (tesl_import_Int_nonNegative n3))
  (when (check-fail? tesl_checked_29)
    (raise-user-error 'tesl-test "unexpected failure in let count: ~a" (check-fail-message tesl_checked_29)))
  (define count (attach-proof (ensure-named 'count (raw-value tesl_checked_29)) (detach-all-proof tesl_checked_29)))
  (check-equal? (raw-value (tesl_import_List_take count (list 1 2 3 4 5))) (list 1 2 3))
  (define n0 0)
  (define tesl_checked_30 (tesl_import_Int_nonNegative n0))
  (when (check-fail? tesl_checked_30)
    (raise-user-error 'tesl-test "unexpected failure in let zero: ~a" (check-fail-message tesl_checked_30)))
  (define zero (attach-proof (ensure-named 'zero (raw-value tesl_checked_30)) (detach-all-proof tesl_checked_30)))
  (check-equal? (raw-value (tesl_import_List_take zero (list 1 2 3))) (list))
  )

  (test-case "T25d: List.drop with proof"
  (define n2 2)
  (define tesl_checked_31 (tesl_import_Int_nonNegative n2))
  (when (check-fail? tesl_checked_31)
    (raise-user-error 'tesl-test "unexpected failure in let count: ~a" (check-fail-message tesl_checked_31)))
  (define count (attach-proof (ensure-named 'count (raw-value tesl_checked_31)) (detach-all-proof tesl_checked_31)))
  (check-equal? (raw-value (tesl_import_List_drop count (list 1 2 3 4 5))) (list 3 4 5))
  )

  (test-case "T25e: List.sum"
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list 1 2 3 4 5)))) 15)
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list)))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list 0 0 0)))) 0)
  )

  (test-case "T25f: List.product"
  (check-equal? (raw-value (raw-value (tesl_import_List_product (list 1 2 3 4)))) 24)
  (check-equal? (raw-value (raw-value (tesl_import_List_product (list)))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_List_product (list 0 1 2)))) 0)
  )

  (test-case "T25g: List.reverse"
  (check-equal? (raw-value (tesl_import_List_reverse (list 1 2 3))) (list 3 2 1))
  (check-equal? (raw-value (tesl_import_List_reverse (list))) (list))
  (check-equal? (raw-value (tesl_import_List_reverse (list 1))) (list 1))
  )

  (test-case "T25h: List.unique"
  (check-equal? (raw-value (tesl_import_List_unique (list 1 2 1 3 2))) (list 1 2 3))
  (check-equal? (raw-value (tesl_import_List_unique (list))) (list))
  (check-equal? (raw-value (tesl_import_List_unique (list 1 1 1))) (list 1))
  )

  (test-case "T25i: filterCheck then map"
  (define evens (tesl_import_List_filterCheck checkEven28 (list 1 2 3 4 5 6)))
  (define doubled (tesl_import_List_map (let () (define/pow (tesl-lambda-32 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsEven28 ,n))]) (* *n 2))) tesl-lambda-32) (raw-value evens)))
  (check-equal? (raw-value doubled) (list 4 8 12))
  )

  (test-case "T25j: List.any and List.all"
  (check-equal? (raw-value (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-33 [n : Integer]) #:returns Boolean (> *n 3)) tesl-lambda-33) (list 1 2 3 4)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-34 [n : Integer]) #:returns Boolean (> *n 10)) tesl-lambda-34) (list 1 2 3)))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-35 [n : Integer]) #:returns Boolean (> *n 0)) tesl-lambda-35) (list 1 2 3)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-36 [n : Integer]) #:returns Boolean (> *n 1)) tesl-lambda-36) (list 1 2 3)))) #f)
  )

  (test-case "T25k: List idempotent sort examples"
  (check-equal? (raw-value (tesl_import_List_sort (list 9 1 8 2 7 3))) (list 1 2 3 7 8 9))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (tesl_import_List_sort (list 3 1 4 1 5 9 2 6)))))) 8)
  )

  (test-case "T26a: property test with List Int parameter compiles and runs"
  ; property: length is non-negative
  (for ([tesl-prop-i (in-range 200)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (listLengthNonNeg28 xs) "length is non-negative")
    ))
  )

  (test-case "T26b: List sum is commutative under reversal"
  ; property: sum equals sum of reversed
  (for ([tesl-prop-i (in-range 200)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (listSumReverseSame28 xs) "sum equals sum of reversed")
    ))
  )

  (test-case "T26c: append length is additive"
  ; property: append length
  (for ([tesl-prop-i (in-range 200)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))] [ys (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_List_append (raw-value xs) (raw-value ys))))) (+ (raw-value (tesl_import_List_length (raw-value xs))) (raw-value (tesl_import_List_length (raw-value ys))))) "append length")
    ))
  )

)
