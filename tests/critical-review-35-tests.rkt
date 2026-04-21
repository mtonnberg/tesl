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
  (only-in tesl/tesl/prelude Bool Int String List Fact forgetFact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.isEmpty tesl_import_String_isEmpty] [String.trim tesl_import_String_trim] [String.contains tesl_import_String_contains] [String.replace tesl_import_String_replace] [String.split tesl_import_String_split] [String.join tesl_import_String_join] [String.startsWith tesl_import_String_startsWith] [String.endsWith tesl_import_String_endsWith] [String.toUpper tesl_import_String_toUpper] [String.toLower tesl_import_String_toLower] [String.indexOf tesl_import_String_indexOf] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.foldl tesl_import_List_foldl] [List.length tesl_import_List_length] [List.head tesl_import_List_head] [List.reverse tesl_import_List_reverse] [List.sum tesl_import_List_sum] [List.append tesl_import_List_append] [List.sort tesl_import_List_sort] [List.contains tesl_import_List_contains] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop] [List.zip tesl_import_List_zip] [List.unique tesl_import_List_unique] [List.any tesl_import_List_any] [List.all tesl_import_List_all] [List.count tesl_import_List_count] [List.allCheck tesl_import_List_allCheck] IsSorted)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either Either Left Right [Either.partition tesl_import_Either_partition])
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.nonNegative tesl_import_Int_nonNegative] [Int.divide tesl_import_Int_divide] [Int.abs tesl_import_Int_abs] [Int.min tesl_import_Int_min] [Int.max tesl_import_Int_max] [Int.pow tesl_import_Int_pow] [Int.gcd tesl_import_Int_gcd] [Int.isEven tesl_import_Int_isEven] [Int.isOdd tesl_import_Int_isOdd] [Int.toString tesl_import_Int_toString] [Int.sign tesl_import_Int_sign] IsNonZero)
  (only-in tesl/tesl/float Float [Float.requireNonZero tesl_import_Float_requireNonZero] [Float.div tesl_import_Float_div] [Float.abs tesl_import_Float_abs] [Float.isNaN tesl_import_Float_isNaN] [Float.isInfinite tesl_import_Float_isInfinite] [Float.round tesl_import_Float_round] [Float.floor tesl_import_Float_floor] [Float.ceil tesl_import_Float_ceil] FloatNonZero)
  (only-in tesl/tesl/dict Dict [Dict.empty tesl_import_Dict_empty] [Dict.insert tesl_import_Dict_insert] [Dict.lookup tesl_import_Dict_lookup] [Dict.member tesl_import_Dict_member] [Dict.size tesl_import_Dict_size] [Dict.isEmpty tesl_import_Dict_isEmpty] [Dict.fromList tesl_import_Dict_fromList] [Dict.requireKey tesl_import_Dict_requireKey] [Dict.get tesl_import_Dict_get] HasKey)
  (only-in tesl/tesl/set [Set.fromList tesl_import_Set_fromList] [Set.member tesl_import_Set_member] [Set.insert tesl_import_Set_insert] [Set.size tesl_import_Set_size] [Set.union tesl_import_Set_union] [Set.intersection tesl_import_Set_intersection] [Set.difference tesl_import_Set_difference] [Set.isEmpty tesl_import_Set_isEmpty])
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
)


(provide requireNonNeg35 checkB35 checkSmall35 requiresTrue35 myLength35 myMap35 myAppend35 checkSafeTitle35 ProvenRecord35 readAndConsume35 nand35 wrapAndUnwrap35 classifyPrio35 productFold35 concatFold35 checkSmallInt35 requiresBoth35 sequentialChecks35 swapPair35 mapPair35 requireNonNeg35-signature checkB35-signature checkSmall35-signature requiresTrue35-signature myLength35-signature myMap35-signature myAppend35-signature checkSafeTitle35-signature readAndConsume35-signature nand35-signature wrapAndUnwrap35-signature classifyPrio35-signature productFold35-signature concatFold35-signature checkSmallInt35-signature requiresBoth35-signature sequentialChecks35-signature swapPair35-signature mapPair35-signature)

(define AlwaysTrue35 'AlwaysTrue35)
(define Ev35 'Ev35)
(define IsA35 'IsA35)
(define IsB35 'IsB35)
(define NonNeg35 'NonNeg35)
(define Pos35 'Pos35)
(define PosVal35 'PosVal35)
(define SafeTitle35 'SafeTitle35)
(define Small35 'Small35)
(define SmallInt35 'SmallInt35)

(define-checker
  (checkNonNeg35 [n : Integer])
  #:returns [n : Integer ::: (NonNeg35 n)]
  (if (>= *n 0) (accept (NonNeg35 n) #:value *n) (reject "must be non-negative" #:http-code 400)))

(define/pow
  (requireNonNeg35 [n : Integer ::: (NonNeg35 n)])
  #:returns Integer
  (+ *n 1))

(define-checker
  (checkA35 [s : String])
  #:returns [s : String ::: (IsA35 s)]
  (if (tesl_import_String_startsWith *s "A") (accept (IsA35 s) #:value *s) (reject "must start with A" #:http-code 400)))

(define-checker
  (checkB35 [s : String])
  #:returns [s : String ::: (IsB35 s)]
  (if (tesl_import_String_endsWith *s "B") (accept (IsB35 s) #:value *s) (reject "must end with B" #:http-code 400)))

(define-checker
  (checkEv35 [n : Integer])
  #:returns [n : Integer ::: (Ev35 n)]
  (if (equal? (remainder *n 2) 0) (accept (Ev35 n) #:value *n) (reject "not even" #:http-code 400)))

(define-checker
  (checkSmall35 [n : Integer])
  #:returns [n : Integer ::: (Small35 n)]
  (if (< *n 20) (accept (Small35 n) #:value *n) (reject "too large" #:http-code 400)))

(define/pow
  (doubleFilter35 [xs : (List Integer)])
  #:returns (List Integer)
  (let ([evens (tesl_import_List_filterCheck checkEv35 *xs)]) (tesl_import_List_filterCheck checkSmall35 (raw-value evens))))

(define-trusted
  (alwaysTrue35 [n : Integer])
  #:returns (Fact (AlwaysTrue35 n))
  (trusted-proof (AlwaysTrue35 n)))

(define/pow
  (requiresTrue35 [n : Integer ::: (AlwaysTrue35 n)])
  #:returns Integer
  (* *n 3))

(define/pow
  (useEstablish35 [n : Integer])
  #:returns Integer
  (let ([proof (alwaysTrue35 n)]) (raw-value (requiresTrue35 (attach-proof n proof)))))

(define-checker
  (checkPosDecomp35 [n : Integer])
  #:returns [n : Integer ::: (Pos35 n)]
  (if (> *n 0) (accept (Pos35 n) #:value *n) (reject "not positive" #:http-code 400)))

(define/pow
  (requiresPos35 [n : Integer ::: (Pos35 n)])
  #:returns Integer
  (+ *n 100))

(define/pow
  (decomposeAndReattach35 [n : Integer ::: (Pos35 n)])
  #:returns Integer
  (let ([tesl_proof_binding_0 n]) (let ([val (forget-proof tesl_proof_binding_0)] [p (detach-all-proof tesl_proof_binding_0)]) (let ([reattached (attach-proof val p)]) (raw-value (requiresPos35 reattached))))))

(define-adt (MyList35 a)
  [Nil35]
  [Cons35 [head : a] [tail : (MyList35 a)]]
)

(define/pow
  (myLength35 [xs : (MyList35 Integer)])
  #:returns Integer
  (let ([tesl_case_1 *xs]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nil35)) (raw-value 0)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Cons35)) (let ([tail (hash-ref (adt-value-fields *tesl_case_1) 'tail)]) (raw-value (+ 1 (raw-value (myLength35 *tail)))))])))

(define/pow
  (myMap35 [f : (-> Integer Integer)] [xs : (MyList35 Integer)])
  #:returns (MyList35 Integer)
  (let ([tesl_case_2 *xs]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nil35)) (raw-value Nil35)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Cons35)) (let ([head (hash-ref (adt-value-fields *tesl_case_2) 'head)]) (let ([tail (hash-ref (adt-value-fields *tesl_case_2) 'tail)]) (raw-value (raw-value (Cons35 (f *head) (myMap35 f *tail))))))])))

(define/pow
  (myAppend35 [xs : (MyList35 Integer)] [ys : (MyList35 Integer)])
  #:returns (MyList35 Integer)
  (let ([tesl_case_3 *xs]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Nil35)) *ys] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Cons35)) (let ([head (hash-ref (adt-value-fields *tesl_case_3) 'head)]) (let ([tail (hash-ref (adt-value-fields *tesl_case_3) 'tail)]) (raw-value (raw-value (Cons35 *head (myAppend35 *tail ys))))))])))

(define/pow
  (flattenMaybe35 [m : (Maybe (Maybe Integer))])
  #:returns (Maybe Integer)
  (let ([tesl_case_4 *m]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Something)) (let ([inner (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (let ([tesl_case_5 (raw-value inner)]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Something)) (let ([val (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (raw-value (raw-value (Something *val))))])))])))

(define-checker
  (checkSafeTitle35 [s : String])
  #:returns [s : String ::: (SafeTitle35 s)]
  (if (and (> (raw-value (tesl_import_String_length *s)) 0) (<= (raw-value (tesl_import_String_length *s)) 100)) (accept (SafeTitle35 s) #:value *s) (reject "title must be 1-100 chars" #:http-code 400)))

(define-record ProvenRecord35
  [title : String ::: (SafeTitle35 title)]
)

(define/pow
  (requiresSafeTitle35 [s : String ::: (SafeTitle35 s)])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define/pow
  (readAndConsume35 [rec : ProvenRecord35])
  #:returns Integer
  (raw-value (requiresSafeTitle35 (tesl-dot/runtime rec 'title))))

(define/pow
  (safeFloatDiv35 [a : Real] [b : Real])
  #:returns (Maybe Real)
  (if (equal? *b 0.) (raw-value Nothing) (let/check ([tesl_checked_6 (tesl_import_Float_requireNonZero b)]) (let ([divisor (attach-proof (ensure-named 'divisor (raw-value tesl_checked_6)) (detach-all-proof tesl_checked_6))]) (raw-value (raw-value (Something (raw-value (tesl_import_Float_div *a divisor)))))))))

(define/pow
  (xor35 [a : Boolean] [b : Boolean])
  #:returns Boolean
  (and (or *a *b) (not (and *a *b))))

(define/pow
  (nand35 [a : Boolean] [b : Boolean])
  #:returns Boolean
  (not (and *a *b)))

(define-newtype UserId35 String)

(define/pow
  (wrapAndUnwrap35 [s : String])
  #:returns String
  (let ([uid (raw-value (UserId35 *s))]) (raw-value uid.value)))

(define-adt Prio35
  [Critical35]
  [High35]
  [Medium35]
  [Low35]
)

(define/pow
  (classifyPrio35 [p : Prio35] [urgent : Boolean])
  #:returns String
  (let ([tesl_case_7 *p]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Critical35)) (raw-value "must do now")] [(and (and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'High35)) urgent) (raw-value "escalated")] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'High35)) (raw-value "important")] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Medium35)) (raw-value "normal")] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Low35)) (raw-value "backlog")])))

(define/pow
  (sumFold35 [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-8 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc *x)) tesl-lambda-8) 0 *xs)))

(define/pow
  (productFold35 [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-9 [acc : Integer] [x : Integer]) #:returns Integer (* *acc *x)) tesl-lambda-9) 1 *xs)))

(define/pow
  (concatFold35 [xs : (List String)])
  #:returns String
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-10 [acc : String] [s : String]) #:returns String (string-append *acc *s)) tesl-lambda-10) "" *xs)))

(define/pow
  (applyN35 [f : (-> Integer Integer)] [n : Integer] [x : Integer])
  #:returns Integer
  (if (<= *n 0) *x (raw-value (applyN35 f (- *n 1) (f x)))))

(define/pow
  (add335 [a : Integer] [b : Integer] [c : Integer])
  #:returns Integer
  (+ (+ *a *b) *c))

(define-checker
  (checkPos35 [n : Integer])
  #:returns [n : Integer ::: (PosVal35 n)]
  (if (> *n 0) (accept (PosVal35 n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (checkSmallInt35 [n : Integer])
  #:returns [n : Integer ::: (SmallInt35 n)]
  (if (< *n 1000) (accept (SmallInt35 n) #:value *n) (reject "too large" #:http-code 400)))

(define/pow
  (requiresBoth35 [n : Integer ::: ((PosVal35 n) && (SmallInt35 n))])
  #:returns String
  (format "valid: ~a" (tesl-display-val *n)))

(define/pow
  (sequentialChecks35 [n : Integer])
  #:returns String
  (let ([v1 (checkPos35 n)]) (let ([v2 (checkSmallInt35 v1)]) (raw-value (requiresBoth35 v2)))))

(define-adt (Pair35 a b)
  [MkPair35 [fst : a] [snd : b]]
)

(define/pow
  (swapPair35 [p : (Pair35 Integer String)])
  #:returns (Pair35 String Integer)
  (let ([tesl_case_11 *p]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'MkPair35)) (let ([fst (hash-ref (adt-value-fields *tesl_case_11) 'fst)]) (let ([snd (hash-ref (adt-value-fields *tesl_case_11) 'snd)]) (raw-value (raw-value (MkPair35 *snd *fst)))))])))

(define/pow
  (mapPair35 [f : (-> Integer Integer)] [g : (-> String String)] [p : (Pair35 Integer String)])
  #:returns (Pair35 Integer String)
  (let ([tesl_case_12 *p]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'MkPair35)) (let ([fst (hash-ref (adt-value-fields *tesl_case_12) 'fst)]) (let ([snd (hash-ref (adt-value-fields *tesl_case_12) 'snd)]) (raw-value (raw-value (MkPair35 (f *fst) (g *snd))))))])))

(define/pow
  (verifyForgetAndRecheck35 [n : Integer])
  #:returns (Maybe Integer)
  (if (> *n 0) (let ([checked (checkPosDecomp35 n)]) (let ([forgotten (forget-proof checked)]) (let/check ([tesl_checked_13 (checkPosDecomp35 forgotten)]) (let ([rechecked (attach-proof (ensure-named 'rechecked (raw-value tesl_checked_13)) (detach-all-proof tesl_checked_13))]) (raw-value (raw-value (Something (requiresPos35 rechecked)))))))) (raw-value Nothing)))

(define-adt Season35
  [Spring35]
  [Summer35]
  [Autumn35]
  [Winter35]
)

(define/pow
  (isWarm35 [s : Season35])
  #:returns Boolean
  (let ([tesl_case_14 *s]) (cond [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Spring35)) (raw-value #t)] [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Summer35)) (raw-value #t)] [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Autumn35)) (raw-value #f)] [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Winter35)) (raw-value #f)])))

(define/pow
  (httpStatus35 [code : Integer])
  #:returns String
  (let ([tesl_case_15 *code]) (cond [(= *tesl_case_15 200) (raw-value "OK")] [(= *tesl_case_15 201) (raw-value "Created")] [(= *tesl_case_15 400) (raw-value "Bad Request")] [(= *tesl_case_15 404) (raw-value "Not Found")] [(= *tesl_case_15 500) (raw-value "Internal Server Error")] [#t (raw-value "Unknown")])))

(define/pow
  (commandRouter35 [cmd : String])
  #:returns String
  (let ([tesl_case_16 *cmd]) (cond [(equal? *tesl_case_16 "help") (raw-value "showing help")] [(equal? *tesl_case_16 "quit") (raw-value "goodbye")] [(equal? *tesl_case_16 "version") (raw-value "1.0.0")] [#t (let ([other *tesl_case_16]) (raw-value (format "unknown: ~a" (tesl-display-val *other))))])))

(define/pow
  (classify35 [n : Integer])
  #:returns String
  (if (< *n 0) (raw-value "negative") (if (equal? *n 0) (raw-value "zero") (if (< *n 10) (raw-value "small") (raw-value "large")))))

(module+ test
  (require rackunit)
  (test-case "T01 \226\128\148 correct subject proof works"
  (define a 10)
  (define checkedA (checkNonNeg35 a))
  (check-equal? (raw-value (requireNonNeg35 checkedA)) 11)
  (define zero 0)
  (define checkedZero (checkNonNeg35 zero))
  (check-equal? (raw-value (requireNonNeg35 checkedZero)) 1)
  )

  (test-case "T01b \226\128\148 check rejects negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkNonNeg35 -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkNonNeg35 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkNonNeg35 -999)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkNonNeg35 -999"))
  )

  (test-case "T02 \226\128\148 composed check first failure"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and checkA35 checkB35) "XB")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and checkA35 checkB35) \"XB\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and checkA35 checkB35) "AX")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and checkA35 checkB35) \"AX\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and checkA35 checkB35) "XX")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and checkA35 checkB35) \"XX\""))
  (define s "AB")
  (define result ((check-and checkA35 checkB35) s))
  (check-equal? (raw-value (tesl_import_String_length (raw-value result))) 2)
  )

  (test-case "T02b \226\128\148 reversed composition"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((check-and checkB35 checkA35) "AX")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (check-and checkB35 checkA35) \"AX\""))
  (define s2 "AB")
  (define result2 ((check-and checkB35 checkA35) s2))
  (check-equal? (raw-value (tesl_import_String_length (raw-value result2))) 2)
  )

  (test-case "T03 \226\128\148 double filterCheck"
  (define result (doubleFilter35 (list 1 2 3 4 22 100 6 18)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 4)
  (define empty (doubleFilter35 (list 1 3 5 7)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value empty)))) 0)
  (define allPass (doubleFilter35 (list 2 4 6)))
  (check-equal? (raw-value allPass) (list 2 4 6))
  )

  (test-case "T04 \226\128\148 establish unconditional"
  (check-equal? (raw-value (useEstablish35 0)) 0)
  (check-equal? (raw-value (useEstablish35 -42)) -126)
  (check-equal? (raw-value (useEstablish35 100)) 300)
  )

  (test-case "T05 \226\128\148 proof decomposition and reattachment"
  (define raw 5)
  (define checked (checkPosDecomp35 raw))
  (check-equal? (raw-value (decomposeAndReattach35 checked)) 105)
  (define raw2 1)
  (define checked2 (checkPosDecomp35 raw2))
  (check-equal? (raw-value (decomposeAndReattach35 checked2)) 101)
  )

  (test-case "T06 \226\128\148 recursive ADT list"
  (define xs (raw-value (Cons35 1 (Cons35 2 (Cons35 3 Nil35)))))
  (check-equal? (raw-value (myLength35 xs)) 3)
  (check-equal? (raw-value (myLength35 Nil35)) 0)
  (define doubled (myMap35 (let () (define/pow (tesl-lambda-17 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-17) xs))
  (check-equal? (raw-value (myLength35 doubled)) 3)
  (define ys (raw-value (Cons35 4 (Cons35 5 Nil35))))
  (define combined (myAppend35 xs ys))
  (check-equal? (raw-value (myLength35 combined)) 5)
  )

  (test-case "T07 \226\128\148 nested Maybe"
  (check-equal? (raw-value (flattenMaybe35 Nothing)) Nothing)
  (check-equal? (raw-value (flattenMaybe35 (raw-value (Something Nothing)))) Nothing)
  (check-equal? (raw-value (flattenMaybe35 (raw-value (Something (raw-value (Something 42)))))) (raw-value (Something 42)))
  (check-equal? (raw-value (flattenMaybe35 (raw-value (Something (raw-value (Something 0)))))) (raw-value (Something 0)))
  )

  (test-case "T08 \226\128\148 record field proof propagation"
  (define raw "hello")
  (define safe (checkSafeTitle35 raw))
  (define rec (ProvenRecord35 #:title safe))
  (check-equal? (raw-value (readAndConsume35 rec)) 5)
  )

  (test-case "T08b \226\128\148 proof boundary check"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkSafeTitle35 "")))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkSafeTitle35 \"\""))
  (define long "aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeaaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeef")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkSafeTitle35 long)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkSafeTitle35 long"))
  )

  (test-case "T09 \226\128\148 integer identity and absorption"
  (check-equal? (raw-value (+ 0 0)) 0)
  (check-equal? (raw-value (* 0 12345)) 0)
  (check-equal? (raw-value (* 1 1)) 1)
  (check-equal? (raw-value (* -1 -1)) 1)
  (check-equal? (raw-value (* -1 0)) 0)
  (define maxish 4611686018427387903)
  (check-true (> (raw-value maxish) 0))
  (define minish -4611686018427387903)
  (check-true (< (raw-value minish) 0))
  )

  (test-case "T09b \226\128\148 Int stdlib"
  (check-equal? (raw-value (raw-value (tesl_import_Int_abs 5))) 5)
  (check-equal? (raw-value (raw-value (tesl_import_Int_abs -5))) 5)
  (check-equal? (raw-value (raw-value (tesl_import_Int_abs 0))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_Int_min 3 7))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_Int_max 3 7))) 7)
  (check-equal? (raw-value (raw-value (tesl_import_Int_min -1 1))) -1)
  (check-equal? (raw-value (raw-value (tesl_import_Int_gcd 12 8))) 4)
  (check-equal? (raw-value (raw-value (tesl_import_Int_gcd 7 13))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_Int_pow 2 10))) 1024)
  (check-equal? (raw-value (raw-value (tesl_import_Int_pow 0 5))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_Int_pow 5 0))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_Int_isEven 4))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Int_isOdd 3))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Int_isEven 0))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Int_sign 5))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_Int_sign -5))) -1)
  (check-equal? (raw-value (raw-value (tesl_import_Int_sign 0))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_Int_toString 42))) "42")
  (check-equal? (raw-value (raw-value (tesl_import_Int_toString -7))) "-7")
  )

  (test-case "T10 \226\128\148 float proof-total division"
  (check-equal? (raw-value (safeFloatDiv35 10. 2.)) (raw-value (Something 5.)))
  (check-equal? (raw-value (safeFloatDiv35 0. 1.)) (raw-value (Something 0.)))
  (check-equal? (raw-value (safeFloatDiv35 10. 0.)) Nothing)
  (check-equal? (raw-value (safeFloatDiv35 -6. 3.)) (raw-value (Something -2.)))
  )

  (test-case "T10b \226\128\148 float stdlib"
  (check-equal? (raw-value (raw-value (tesl_import_Float_round 3.7))) 4)
  (check-equal? (raw-value (raw-value (tesl_import_Float_floor 3.7))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_Float_ceil 3.2))) 4)
  (check-equal? (raw-value (raw-value (tesl_import_Float_abs -2.5))) 2.5)
  (check-equal? (raw-value (raw-value (tesl_import_Float_abs 2.5))) 2.5)
  (check-equal? (raw-value (raw-value (tesl_import_Float_isNaN 1.))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_Float_isInfinite 1.))) #f)
  )

  (test-case "T11 \226\128\148 boolean logic"
  (check-equal? (raw-value (xor35 #t #f)) #t)
  (check-equal? (raw-value (xor35 #f #t)) #t)
  (check-equal? (raw-value (xor35 #t #t)) #f)
  (check-equal? (raw-value (xor35 #f #f)) #f)
  (check-equal? (raw-value (nand35 #t #t)) #f)
  (check-equal? (raw-value (nand35 #t #f)) #t)
  (check-equal? (raw-value (nand35 #f #t)) #t)
  (check-equal? (raw-value (nand35 #f #f)) #t)
  )

  (test-case "T12 \226\128\148 newtype round-trip"
  (check-equal? (raw-value (wrapAndUnwrap35 "user-1")) "user-1")
  (check-equal? (raw-value (wrapAndUnwrap35 "")) "")
  (check-equal? (raw-value (wrapAndUnwrap35 "abc")) "abc")
  )

  (test-case "T12b \226\128\148 newtype identity"
  (define uid1 (raw-value (UserId35 "a")))
  (define uid2 (raw-value (UserId35 "a")))
  (check-equal? (raw-value uid1) uid2)
  (define uid3 (raw-value (UserId35 "b")))
  (check-not-equal? uid1 uid3)
  )

  (test-case "T13 \226\128\148 case guard with bool"
  (check-equal? (raw-value (classifyPrio35 Critical35 #f)) "must do now")
  (check-equal? (raw-value (classifyPrio35 Critical35 #t)) "must do now")
  (check-equal? (raw-value (classifyPrio35 High35 #t)) "escalated")
  (check-equal? (raw-value (classifyPrio35 High35 #f)) "important")
  (check-equal? (raw-value (classifyPrio35 Medium35 #f)) "normal")
  (check-equal? (raw-value (classifyPrio35 Low35 #t)) "backlog")
  )

  (test-case "T14 \226\128\148 List.foldl"
  (check-equal? (raw-value (sumFold35 (list 1 2 3 4 5))) 15)
  (check-equal? (raw-value (sumFold35 (list))) 0)
  (check-equal? (raw-value (sumFold35 (list -1 1))) 0)
  (check-equal? (raw-value (productFold35 (list 1 2 3 4))) 24)
  (check-equal? (raw-value (productFold35 (list))) 1)
  (check-equal? (raw-value (productFold35 (list 5 0 3))) 0)
  (check-equal? (raw-value (concatFold35 (list "a" "b" "c"))) "abc")
  (check-equal? (raw-value (concatFold35 (list))) "")
  (check-equal? (raw-value (concatFold35 (list "hello"))) "hello")
  )

  (test-case "T15 \226\128\148 applyN with lambda"
  (check-equal? (raw-value (applyN35 (let () (define/pow (tesl-lambda-18 [x : Integer]) #:returns Integer (+ *x 1)) tesl-lambda-18) 5 0)) 5)
  (check-equal? (raw-value (applyN35 (let () (define/pow (tesl-lambda-19 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-19) 3 1)) 8)
  (check-equal? (raw-value (applyN35 (let () (define/pow (tesl-lambda-20 [x : Integer]) #:returns Integer x) tesl-lambda-20) 100 42)) 42)
  (check-equal? (raw-value (applyN35 (let () (define/pow (tesl-lambda-21 [x : Integer]) #:returns Integer (+ *x 10)) tesl-lambda-21) 0 5)) 5)
  )

  (test-case "T16 \226\128\148 partial application"
  (define add1 (lambda (_tesl_p22_0) (lambda (_tesl_p22_1) (add335 1 _tesl_p22_0 _tesl_p22_1))))
  (define add1_2 (add1 2))
  (check-equal? (raw-value (add1_2 3)) 6)
  (define add10_20 (lambda (_tesl_p23_0) (add335 10 20 _tesl_p23_0)))
  (check-equal? (raw-value (add10_20 30)) 60)
  (define addAll (tesl_import_List_map (raw-value (lambda (_tesl_p24_0) (add335 0 0 _tesl_p24_0))) (list 1 2 3)))
  (check-equal? (raw-value addAll) (list 1 2 3))
  )

  (test-case "T17 \226\128\148 sequential check accumulation"
  (check-equal? (raw-value (sequentialChecks35 42)) "valid: 42")
  (check-equal? (raw-value (sequentialChecks35 1)) "valid: 1")
  (check-equal? (raw-value (sequentialChecks35 999)) "valid: 999")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPos35 0)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPos35 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value (checkPos35 -1)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPos35 -1"))
  (define posRaw 5)
  (define posVal (checkPos35 posRaw))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((checkSmallInt35 1000) (list))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (checkSmallInt35 1000) (list)"))
  )

  (test-case "T18 \226\128\148 string edge cases"
  (check-equal? (raw-value (tesl_import_String_length "")) 0)
  (check-equal? (raw-value (tesl_import_String_isEmpty "")) #t)
  (check-equal? (raw-value (tesl_import_String_trim "   ")) "")
  (check-equal? (raw-value (tesl_import_String_contains "abc" "")) #t)
  (check-equal? (raw-value (tesl_import_String_contains "" "a")) #f)
  (check-equal? (raw-value (tesl_import_String_startsWith "" "")) #t)
  (check-equal? (raw-value (tesl_import_String_endsWith "" "")) #t)
  (check-equal? (raw-value (tesl_import_String_replace "aaa" "a" "b")) "bbb")
  (check-equal? (raw-value (tesl_import_String_split "a,b,c" ",")) (list "a" "b" "c"))
  (check-equal? (raw-value (tesl_import_String_split "" ",")) (list ""))
  (check-equal? (raw-value (tesl_import_String_join (list "a" "b" "c") ", ")) "a, b, c")
  (check-equal? (raw-value (tesl_import_String_join (list "a" "b") "")) "ab")
  (check-equal? (raw-value (tesl_import_String_indexOf "hello" "ll")) (raw-value (Something 2)))
  (check-equal? (raw-value (tesl_import_String_indexOf "hello" "xyz")) Nothing)
  )

  (test-case "T18b \226\128\148 string stdlib proofs"
  (define trimmed (tesl_import_String_trim "  hello  "))
  (check-equal? (raw-value trimmed) "hello")
  (define upper (tesl_import_String_toUpper "hello"))
  (check-equal? (raw-value upper) "HELLO")
  (define lower (tesl_import_String_toLower "HELLO"))
  (check-equal? (raw-value lower) "hello")
  (check-equal? (raw-value (tesl_import_String_toUpper "")) "")
  (check-equal? (raw-value (tesl_import_String_toLower "")) "")
  )

  (test-case "T18c \226\128\148 string interpolation with expressions"
  (define n 42)
  (define s (format "the answer is ~a" (tesl-display-val n)))
  (check-equal? (raw-value s) "the answer is 42")
  (define prefix "pre")
  (define suffix "suf")
  (define combined (format "~a-~a" (tesl-display-val prefix) (tesl-display-val suffix)))
  (check-equal? (raw-value combined) "pre-suf")
  )

  (test-case "T19 \226\128\148 Dict roundtrip"
  (define d (raw-value (tesl_import_Dict_insert "a" 1 (raw-value (tesl_import_Dict_insert "b" 2 tesl_import_Dict_empty)))))
  (check-equal? (raw-value (raw-value (tesl_import_Dict_size (raw-value d)))) 2)
  (check-equal? (raw-value (raw-value (tesl_import_Dict_member "a" (raw-value d)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Dict_member "c" (raw-value d)))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_Dict_lookup "a" (raw-value d)))) (raw-value (Something 1)))
  (check-equal? (raw-value (raw-value (tesl_import_Dict_lookup "c" (raw-value d)))) Nothing)
  (define d2 (raw-value (tesl_import_Dict_insert "a" 99 (raw-value d))))
  (check-equal? (raw-value (raw-value (tesl_import_Dict_lookup "a" (raw-value d2)))) (raw-value (Something 99)))
  (check-equal? (raw-value (raw-value (tesl_import_Dict_size (raw-value d2)))) 2)
  )

  (test-case "T19b \226\128\148 Dict.requireKey and Dict.get"
  (define d (raw-value (tesl_import_Dict_insert "key" 42 tesl_import_Dict_empty)))
  (define keyStr "key")
  (define tesl_checked_25 (tesl_import_Dict_requireKey keyStr d))
  (when (check-fail? tesl_checked_25)
    (raise-user-error 'tesl-test "unexpected failure in let checked: ~a" (check-fail-message tesl_checked_25)))
  (define checked (attach-proof (ensure-named 'checked (raw-value tesl_checked_25)) (detach-all-proof tesl_checked_25)))
  (check-equal? (raw-value (raw-value (tesl_import_Dict_get (raw-value keyStr) checked))) 42)
  (define missingKey "missing")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((raw-value (tesl_import_Dict_requireKey (raw-value missingKey) (raw-value d))) (list))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (tesl_import_Dict_requireKey (raw-value missingKey) (raw-value d))) (list)"))
  )

  (test-case "T19c \226\128\148 Dict isEmpty and fromList"
  (check-equal? (raw-value (raw-value (tesl_import_Dict_isEmpty tesl_import_Dict_empty))) #t)
  (define d (raw-value (tesl_import_Dict_insert "x" 1 tesl_import_Dict_empty)))
  (check-equal? (raw-value (raw-value (tesl_import_Dict_isEmpty (raw-value d)))) #f)
  (define d2 (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 1) (Tuple2 "b" 2)))))
  (check-equal? (raw-value (raw-value (tesl_import_Dict_size (raw-value d2)))) 2)
  (check-equal? (raw-value (raw-value (tesl_import_Dict_lookup "a" (raw-value d2)))) (raw-value (Something 1)))
  )

  (test-case "T20 \226\128\148 Set operations"
  (define s1 (raw-value (tesl_import_Set_fromList (list 1 2 3 2 1))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value s1)))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_Set_member 1 (raw-value s1)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Set_member 4 (raw-value s1)))) #f)
  (define s2 (raw-value (tesl_import_Set_fromList (list 3 4 5))))
  (define unionSet (raw-value (tesl_import_Set_union (raw-value s1) (raw-value s2))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value unionSet)))) 5)
  (define interSet (raw-value (tesl_import_Set_intersection (raw-value s1) (raw-value s2))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value interSet)))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_Set_member 3 (raw-value interSet)))) #t)
  (define diffSet (raw-value (tesl_import_Set_difference (raw-value s1) (raw-value s2))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value diffSet)))) 2)
  (check-equal? (raw-value (raw-value (tesl_import_Set_member 1 (raw-value diffSet)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Set_member 3 (raw-value diffSet)))) #f)
  )

  (test-case "T20b \226\128\148 Set edge cases"
  (define empty (raw-value (tesl_import_Set_fromList (list))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_isEmpty (raw-value empty)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value empty)))) 0)
  (define single (raw-value (tesl_import_Set_insert 1 (raw-value empty))))
  (check-equal? (raw-value (raw-value (tesl_import_Set_size (raw-value single)))) 1)
  )

  (test-case "T21 \226\128\148 parameterized pair ADT"
  (define p (raw-value (MkPair35 42 "hello")))
  (define swapped (swapPair35 p))
  (check-equal? (raw-value swapped) (raw-value (MkPair35 "hello" 42)))
  (define mapped (mapPair35 (let () (define/pow (tesl-lambda-26 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-26) (let () (define/pow (tesl-lambda-27 [s : String]) #:returns String (string-append *s "!")) tesl-lambda-27) p))
  (check-equal? (raw-value mapped) (raw-value (MkPair35 84 "hello!")))
  )

  (test-case "T22 \226\128\148 forgetFact and re-check"
  (check-equal? (raw-value (verifyForgetAndRecheck35 5)) (raw-value (Something 105)))
  (check-equal? (raw-value (verifyForgetAndRecheck35 0)) Nothing)
  (check-equal? (raw-value (verifyForgetAndRecheck35 1)) (raw-value (Something 101)))
  )

  (test-case "T23 \226\128\148 list edge cases"
  (check-equal? (raw-value (raw-value (tesl_import_List_head (list)))) Nothing)
  (check-equal? (raw-value (raw-value (tesl_import_List_head (list 1)))) (raw-value (Something 1)))
  (check-equal? (raw-value (tesl_import_List_reverse (list))) (list))
  (check-equal? (raw-value (tesl_import_List_reverse (list 1))) (list 1))
  (check-equal? (raw-value (tesl_import_List_sort (list))) (list))
  (check-equal? (raw-value (tesl_import_List_sort (list 1))) (list 1))
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list)))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list 42)))) 42)
  (check-equal? (raw-value (raw-value (tesl_import_List_contains 1 (list 1 2 3)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_contains 4 (list 1 2 3)))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_List_contains 1 (list)))) #f)
  (check-equal? (raw-value (tesl_import_List_unique (list 1 1 2 2 3))) (list 1 2 3))
  (check-equal? (raw-value (tesl_import_List_unique (list))) (list))
  (check-equal? (raw-value (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-28 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-28) (list 0 0 1)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-29 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-29) (list 0 0 0)))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-30 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-30) (list 1 2 3)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-31 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-31) (list 1 0 3)))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_List_count (let () (define/pow (tesl-lambda-32 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-32) (list 1 -1 2 -2 3)))) 3)
  )

  (test-case "T23b \226\128\148 List.range and List.take/drop"
  (define raw0 0)
  (define raw3 3)
  (define raw5 5)
  (define tesl_checked_33 (tesl_import_Int_nonNegative raw0))
  (when (check-fail? tesl_checked_33)
    (raise-user-error 'tesl-test "unexpected failure in let n0: ~a" (check-fail-message tesl_checked_33)))
  (define n0 (attach-proof (ensure-named 'n0 (raw-value tesl_checked_33)) (detach-all-proof tesl_checked_33)))
  (define tesl_checked_34 (tesl_import_Int_nonNegative raw3))
  (when (check-fail? tesl_checked_34)
    (raise-user-error 'tesl-test "unexpected failure in let n3: ~a" (check-fail-message tesl_checked_34)))
  (define n3 (attach-proof (ensure-named 'n3 (raw-value tesl_checked_34)) (detach-all-proof tesl_checked_34)))
  (define tesl_checked_35 (tesl_import_Int_nonNegative raw5))
  (when (check-fail? tesl_checked_35)
    (raise-user-error 'tesl-test "unexpected failure in let n5: ~a" (check-fail-message tesl_checked_35)))
  (define n5 (attach-proof (ensure-named 'n5 (raw-value tesl_checked_35)) (detach-all-proof tesl_checked_35)))
  (check-equal? (raw-value (tesl_import_List_take n0 (list 1 2 3))) (list))
  (check-equal? (raw-value (tesl_import_List_take n3 (list 1 2 3 4 5))) (list 1 2 3))
  (check-equal? (raw-value (tesl_import_List_drop n0 (list 1 2 3))) (list 1 2 3))
  (check-equal? (raw-value (tesl_import_List_drop n3 (list 1 2 3 4 5))) (list 4 5))
  (check-equal? (raw-value (tesl_import_List_take n5 (list 1 2 3))) (list 1 2 3))
  )

  (test-case "T24 \226\128\148 arithmetic properties"
  ; property: addition commutative
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)])
      (when (and (> (raw-value a) -10000) (< (raw-value a) 10000) (> (raw-value b) -10000) (< (raw-value b) 10000)) (check-true (equal? (+ (raw-value a) (raw-value b)) (+ (raw-value b) (raw-value a))) "addition commutative"))
    ))
  ; property: multiplication commutative
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)])
      (when (and (> (raw-value a) -1000) (< (raw-value a) 1000) (> (raw-value b) -1000) (< (raw-value b) 1000)) (check-true (equal? (* (raw-value a) (raw-value b)) (* (raw-value b) (raw-value a))) "multiplication commutative"))
    ))
  ; property: addition associative
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)] [c (- (random 2000001) 1000000)])
      (when (and (> (raw-value a) -1000) (< (raw-value a) 1000) (> (raw-value b) -1000) (< (raw-value b) 1000) (> (raw-value c) -1000) (< (raw-value c) 1000)) (check-true (equal? (+ (+ (raw-value a) (raw-value b)) (raw-value c)) (+ (raw-value a) (+ (raw-value b) (raw-value c)))) "addition associative"))
    ))
  )

  (test-case "T25 \226\128\148 list properties"
  ; property: reverse involution
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (equal? (raw-value (tesl_import_List_reverse (raw-value (tesl_import_List_reverse (raw-value xs))))) (raw-value xs)) "reverse involution")
    ))
  ; property: sort idempotent
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (equal? (raw-value (tesl_import_List_sort (raw-value (tesl_import_List_sort (raw-value xs))))) (raw-value (tesl_import_List_sort (raw-value xs)))) "sort idempotent")
    ))
  ; property: length non-negative
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (>= (raw-value (tesl_import_List_length (raw-value xs))) 0) "length non-negative")
    ))
  ; property: append length additive
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))] [ys (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_List_append (raw-value xs) (raw-value ys))))) (+ (raw-value (tesl_import_List_length (raw-value xs))) (raw-value (tesl_import_List_length (raw-value ys))))) "append length additive")
    ))
  )

  (test-case "T26 \226\128\148 Either partition"
  (define xs (list (Left "e1") (Right 1) (Left "e2") (Right 2)))
  (define result (raw-value (tesl_import_Either_partition (raw-value xs))))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value result)))) (list "e1" "e2"))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value result)))) (list 1 2))
  (define allLeft (raw-value (tesl_import_Either_partition (list (Left "a") (Left "b")))))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value allLeft)))) (list "a" "b"))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value allLeft)))) (list))
  (define empty (raw-value (tesl_import_Either_partition (list))))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value empty)))) (list))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value empty)))) (list))
  )

  (test-case "T27 \226\128\148 fall-through"
  (check-equal? (raw-value (isWarm35 Spring35)) #t)
  (check-equal? (raw-value (isWarm35 Summer35)) #t)
  (check-equal? (raw-value (isWarm35 Autumn35)) #f)
  (check-equal? (raw-value (isWarm35 Winter35)) #f)
  )

  (test-case "T28 \226\128\148 Int.divide with proof"
  (define rawDivisor 3)
  (define tesl_checked_36 (tesl_import_Int_nonZero rawDivisor))
  (when (check-fail? tesl_checked_36)
    (raise-user-error 'tesl-test "unexpected failure in let divisor: ~a" (check-fail-message tesl_checked_36)))
  (define divisor (attach-proof (ensure-named 'divisor (raw-value tesl_checked_36)) (detach-all-proof tesl_checked_36)))
  (check-equal? (raw-value (tesl_import_Int_divide 12 divisor)) 4)
  (check-equal? (raw-value (tesl_import_Int_divide 0 divisor)) 0)
  (check-equal? (raw-value (tesl_import_Int_divide -12 divisor)) -4)
  (define rawDivisor2 1)
  (define tesl_checked_37 (tesl_import_Int_nonZero rawDivisor2))
  (when (check-fail? tesl_checked_37)
    (raise-user-error 'tesl-test "unexpected failure in let divisor2: ~a" (check-fail-message tesl_checked_37)))
  (define divisor2 (attach-proof (ensure-named 'divisor2 (raw-value tesl_checked_37)) (detach-all-proof tesl_checked_37)))
  (check-equal? (raw-value (tesl_import_Int_divide 42 divisor2)) 42)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (raw-value ((tesl_import_Int_nonZero 0) (list))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (tesl_import_Int_nonZero 0) (list)"))
  )

  (test-case "T29 \226\128\148 allCheck"
  (define allPos (tesl_import_List_allCheck checkPosDecomp35 (list 1 2 3)))
  (check-equal? (raw-value allPos) (raw-value (Something (list 1 2 3))))
  (define hasBad (tesl_import_List_allCheck checkPosDecomp35 (list 1 -1 3)))
  (check-equal? (raw-value hasBad) Nothing)
  (define emptyList (tesl_import_List_allCheck checkPosDecomp35 (list)))
  (check-equal? (raw-value emptyList) (raw-value (Something (list))))
  )

  (test-case "T30 \226\128\148 literal patterns"
  (check-equal? (raw-value (httpStatus35 200)) "OK")
  (check-equal? (raw-value (httpStatus35 404)) "Not Found")
  (check-equal? (raw-value (httpStatus35 418)) "Unknown")
  (check-equal? (raw-value (commandRouter35 "help")) "showing help")
  (check-equal? (raw-value (commandRouter35 "quit")) "goodbye")
  (check-equal? (raw-value (commandRouter35 "foo")) "unknown: foo")
  )

  (test-case "T31 \226\128\148 List.zip"
  (define zipped (raw-value (tesl_import_List_zip (list 1 2 3) (list "a" "b" "c"))))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value zipped)))) 3)
  (define emptyZip (raw-value (tesl_import_List_zip (list) (list))))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value emptyZip)))) 0)
  (define unevenZip (raw-value (tesl_import_List_zip (list 1 2) (list "a" "b" "c"))))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value unevenZip)))) 2)
  )

  (test-case "T32 \226\128\148 nested if/else"
  (check-equal? (raw-value (classify35 -5)) "negative")
  (check-equal? (raw-value (classify35 0)) "zero")
  (check-equal? (raw-value (classify35 5)) "small")
  (check-equal? (raw-value (classify35 100)) "large")
  )

)
