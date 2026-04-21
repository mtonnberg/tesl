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
  (only-in tesl/tesl/prelude Bool Int String List Fact forgetFact detachFact introAnd andLeft andRight)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.map tesl_import_List_map] [List.length tesl_import_List_length])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first])
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define InRange 'InRange)
(define IsPositive 'IsPositive)
(define TitleSafe 'TitleSafe)
(define ValidUserId 'ValidUserId)

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
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))

(define-checker
  (checkTitle [s : String])
  #:returns [s : String ::: (TitleSafe s)]
  (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (TitleSafe s) #:value *s) (reject "empty title" #:http-code 400)))

(define-checker
  (checkInRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange lo hi n)]
  (if (and (>= *n *lo) (<= *n *hi)) (accept (InRange lo hi n) #:value *n) (reject "out of range" #:http-code 400)))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (trusted-proof (A n)))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (trusted-proof (B n)))

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
  (needsAll4 [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns Integer
  *n)

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  *n)

(define/pow
  (needsTitle [s : String ::: (TitleSafe s)])
  #:returns String
  *s)

(define/pow
  (needsInRange [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  *n)

(define/pow
  (chain3 [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (checkA raw)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkB a)]) (let ([b tesl_checked_1]) (let/check ([tesl_checked_2 (checkC b)]) (let ([c tesl_checked_2]) (raw-value (needsABC c)))))))))

(define/pow
  (chain4 [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_3 (checkA raw)]) (let ([a tesl_checked_3]) (let/check ([tesl_checked_4 (checkB a)]) (let ([b tesl_checked_4]) (let/check ([tesl_checked_5 (checkC b)]) (let ([c tesl_checked_5]) (let/check ([tesl_checked_6 (checkD c)]) (let ([d tesl_checked_6]) (raw-value (needsAll4 d)))))))))))

(define-record SafeItem
  [title : String ::: (TitleSafe title)]
  [count : Integer ::: (IsPositive count)]
)

(define/pow
  (makeItem [rawTitle : String] [rawCount : Integer])
  #:returns SafeItem
  (let/check ([tesl_checked_7 (checkTitle rawTitle)]) (let ([t tesl_checked_7]) (let/check ([tesl_checked_8 (checkPos rawCount)]) (let ([c tesl_checked_8]) (SafeItem #:title t #:count c))))))

(define/pow
  (useItemTitle [item : SafeItem])
  #:returns String
  (raw-value (needsTitle (tesl-dot/runtime item 'title))))

(define/pow
  (useItemCount [item : SafeItem])
  #:returns Integer
  (raw-value (needsPos (tesl-dot/runtime item 'count))))

(define/pow
  (doublePos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (* *n 2))

(define/pow
  (doubleAllPositive [xs : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-9 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (doublePos n))) tesl-lambda-9) *xs)))

(define/pow
  (inBounds [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_10 (checkInRange 0 100 raw)]) (let ([checked tesl_checked_10]) (raw-value (needsInRange 0 100 checked)))))

(define-trusted
  (forgeA [n : Integer])
  #:returns (Fact (A n))
  (trusted-proof (A n)))

(define/pow
  (passThroughUnconditional [n : Integer])
  #:returns Integer
  (let ([proof (forgeA n)]) (let ([raw (forget-proof n)]) (let ([faked (attach-proof raw proof)]) (raw-value (needsA faked))))))

(define-checker
  (checkAndAppend [s : String])
  #:returns [result : String ::: (TitleSafe result)]
  (let ([result (string-append *s "!")]) (if (> (raw-value (tesl_import_String_length (raw-value result))) 0) (accept (TitleSafe result) #:value *result) (reject "empty after append" #:http-code 400))))

(define/pow
  (callLambdaWithProof [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_11 (checkPos raw)]) (let ([pos tesl_checked_11]) (let ([f (let () (define/pow (tesl-lambda-12 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (+ *n 1))) tesl-lambda-12)]) (raw-value (f pos))))))

(define/pow
  (combine4Proofs [n : Integer])
  #:returns Integer
  (let ([pa (proveA n)]) (let ([pb (proveB n)]) (let ([pab (intro-and pa pb)]) (let ([la (and-left pab)]) (let ([rb (and-right pab)]) (let ([base (forget-proof n)]) (let ([withA (attach-proof base la)]) (let ([withB (attach-proof (forget-proof n) rb)]) (+ (raw-value (needsA withA)) (raw-value (needsB withB))))))))))))

(define/pow
  (detachFrom4Chain [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_13 (checkA raw)]) (let ([a tesl_checked_13]) (let/check ([tesl_checked_14 (checkB a)]) (let ([b tesl_checked_14]) (let/check ([tesl_checked_15 (checkC b)]) (let ([c tesl_checked_15]) (let/check ([tesl_checked_16 (checkD c)]) (let ([d tesl_checked_16]) (let ([_p (detach-all-proof d)]) 0))))))))))

(define/pow
  (tupleProofLoss [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_17 (checkPos raw)]) (let ([pos tesl_checked_17]) (let ([t (raw-value (Tuple2 pos "hello"))]) (let ([extracted (raw-value (tesl_import_Tuple2_first (raw-value t)))]) (let/check ([tesl_checked_18 (checkPos extracted)]) (let ([reproved tesl_checked_18]) (raw-value (needsPos reproved)))))))))

(define-record PlainPair
  [n : Integer]
  [s : String]
)

(define/pow
  (plainFieldLoss [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_19 (checkPos raw)]) (let ([pos tesl_checked_19]) (let ([pair (PlainPair #:n *pos #:s "x")]) (let/check ([tesl_checked_20 (checkPos (tesl-dot/runtime pair 'n))]) (let ([reproved tesl_checked_20]) (raw-value (needsPos reproved))))))))

(define/pow
  (updateTitle [item : SafeItem] [newTitle : String])
  #:returns SafeItem
  (let/check ([tesl_checked_21 (checkTitle newTitle)]) (let ([t tesl_checked_21]) (tesl-record-update *item (hash 'title t)))))

(define/pow
  (updateCount [item : SafeItem] [newCount : Integer])
  #:returns SafeItem
  (let/check ([tesl_checked_22 (checkPos newCount)]) (let ([c tesl_checked_22]) (tesl-record-update *item (hash 'count c)))))

(define/pow
  (updateBoth [item : SafeItem] [newTitle : String] [newCount : Integer])
  #:returns SafeItem
  (let/check ([tesl_checked_23 (checkTitle newTitle)]) (let ([t tesl_checked_23]) (let/check ([tesl_checked_24 (checkPos newCount)]) (let ([c tesl_checked_24]) (tesl-record-update *item (hash 'title t 'count c)))))))

(define/pow
  (detachConjunction [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_25 (checkA raw)]) (let ([a tesl_checked_25]) (let/check ([tesl_checked_26 (checkB a)]) (let ([b tesl_checked_26]) (let/check ([tesl_checked_27 (checkC b)]) (let ([c tesl_checked_27]) (let/check ([tesl_checked_28 (checkD c)]) (let ([d tesl_checked_28]) (let ([combined (detach-all-proof d)]) (let ([base (forget-proof d)]) (let ([withAll (attach-proof base combined)]) (raw-value (needsAll4 withAll))))))))))))))

(define/pow
  (detachTwoProofs [raw : Integer])
  #:returns Integer
  (let/check ([tesl_checked_29 (checkA raw)]) (let ([a tesl_checked_29]) (let/check ([tesl_checked_30 (checkB a)]) (let ([b tesl_checked_30]) (let ([combined (detach-all-proof b)]) (let ([base (forget-proof b)]) (let ([withAB (attach-proof base combined)]) (raw-value (needsAB withAB))))))))))

(define-newtype MkUserId String)

(define-checker
  (checkAndWrapUserId [raw : String])
  #:returns [u : MkUserId ::: (ValidUserId u)]
  (if (>= (raw-value (tesl_import_String_length *raw)) 3) (accept/value '(ValidUserId u) (MkUserId *raw)) (reject "user id too short" #:http-code 400)))

(define/pow
  (needsValidId [u : MkUserId ::: (ValidUserId u)])
  #:returns MkUserId
  *u)

(define-adt Color
  [Red]
  [Green]
  [Blue]
)

(define/pow
  (colorName [c : Color])
  #:returns String
  (let ([tesl_case_31 *c]) (cond [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Red)) (raw-value "red")] [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Green)) (raw-value "green")] [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Blue)) (raw-value "blue")])))

(define-adt Suit
  [Hearts]
  [Diamonds]
  [Clubs]
  [Spades]
)

(define/pow
  (suitColor [s : Suit])
  #:returns String
  (let ([tesl_case_32 *s]) (cond [(and (adt-value? *tesl_case_32) (eq? (adt-value-variant *tesl_case_32) 'Hearts)) (raw-value "red")] [(and (adt-value? *tesl_case_32) (eq? (adt-value-variant *tesl_case_32) 'Diamonds)) (raw-value "red")] [(and (adt-value? *tesl_case_32) (eq? (adt-value-variant *tesl_case_32) 'Clubs)) (raw-value "black")] [(and (adt-value? *tesl_case_32) (eq? (adt-value-variant *tesl_case_32) 'Spades)) (raw-value "black")])))

(define/pow
  (suitColorWildcard [s : Suit])
  #:returns String
  (let ([tesl_case_33 *s]) (cond [(and (adt-value? *tesl_case_33) (eq? (adt-value-variant *tesl_case_33) 'Hearts)) (raw-value "red")] [(and (adt-value? *tesl_case_33) (eq? (adt-value-variant *tesl_case_33) 'Diamonds)) (raw-value "red")] [#t (raw-value "black")])))

(define/pow
  (maybeWithFallback [m : (Maybe Integer)])
  #:returns Integer
  (let ([tesl_case_34 *m]) (cond [(and (adt-value? *tesl_case_34) (eq? (adt-value-variant *tesl_case_34) 'Nothing)) (raw-value 0)] [(and (adt-value? *tesl_case_34) (eq? (adt-value-variant *tesl_case_34) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_34) 'value)]) *v)])))

(module+ test
  (require rackunit)
  (test-case "R60_CH01 three-check chain accumulation"
  (define r (chain3 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R60_CH02 four-check chain accumulation"
  (define r (chain4 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R60_CH03 four-check chain rejects invalid first step"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-35) #:returns Integer (chain4 0)) tesl-lambda-35) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-36) #:returns Integer (chain4 0)) tesl-lambda-36) (list)"))
  )

  (test-case "R60_CH04 four-check chain rejects middle step (n=42 fails C)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-36) #:returns Integer (chain4 42)) tesl-lambda-36) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-37) #:returns Integer (chain4 42)) tesl-lambda-37) (list)"))
  )

  (test-case "R60_RF01 proof-annotated field construction and title access"
  (define item (makeItem "hello" 5))
  (define t (useItemTitle item))
  (check-equal? (raw-value t) "hello")
  )

  (test-case "R60_RF02 proof-annotated field construction and count access"
  (define item (makeItem "hello" 5))
  (define c (useItemCount item))
  (check-equal? (raw-value c) 5)
  )

  (test-case "R60_RF03 proof-annotated field construction rejects bad title"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-37) #:returns Any (makeItem "" 5)) tesl-lambda-37) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-38) #:returns Any (makeItem \"\" 5)) tesl-lambda-38) (list)"))
  )

  (test-case "R60_RF04 proof-annotated field construction rejects bad count"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-38) #:returns Any (makeItem "ok" 0)) tesl-lambda-38) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-39) #:returns Any (makeItem \"ok\" 0)) tesl-lambda-39) (list)"))
  )

  (test-case "R60_FA01 ForAll list with lambda wrapper"
  (define raw (list 1 2 3 4))
  (define pos (tesl_import_List_filterCheck checkPos (raw-value raw)))
  (define doubled (doubleAllPositive pos))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value doubled)))) 4)
  )

  (test-case "R60_FA02 ForAll filterCheck excludes invalid elements"
  (define raw (list 1 -2 3 -4 5))
  (define pos (tesl_import_List_filterCheck checkPos (raw-value raw)))
  (define doubled (doubleAllPositive pos))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value doubled)))) 3)
  )

  (test-case "R60_MP01 multi-param proof with correct literal args"
  (define r (inBounds 50))
  (check-equal? (raw-value r) 50)
  )

  (test-case "R60_MP02 multi-param proof rejects out-of-range value"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-39) #:returns Integer (inBounds 150)) tesl-lambda-39) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-40) #:returns Integer (inBounds 150)) tesl-lambda-40) (list)"))
  )

  (test-case "R60_ES01 establish forges proof unconditionally (negative value)"
  (define r (passThroughUnconditional -5))
  (check-equal? (raw-value r) -5)
  )

  (test-case "R60_ES02 establish forges proof unconditionally (zero)"
  (define r (passThroughUnconditional 0))
  (check-equal? (raw-value r) 0)
  )

  (test-case "R60_OK01 ok with let-bound transformed value"
  (define tesl_checked_40 (checkAndAppend "hello"))
  (when (check-fail? tesl_checked_40)
    (raise-user-error 'tesl-test "unexpected failure in let r: ~a" (check-fail-message tesl_checked_40)))
  (define r tesl_checked_40)
  (define result (needsTitle r))
  (check-equal? (raw-value result) "hello!")
  )

  (test-case "R60_LM01 lambda with proof-annotated param is callable"
  (define r (callLambdaWithProof 5))
  (check-equal? (raw-value r) 6)
  )

  (test-case "R60_IA01 introAnd from two establish calls, andLeft gives A"
  (define r (combine4Proofs 5))
  (check-equal? (raw-value r) 10)
  )

  (test-case "R60_DT01 detachFact with 4 accumulated proofs fails at runtime"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-41) #:returns Integer (detachFrom4Chain 5)) tesl-lambda-41) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-42) #:returns Integer (detachFrom4Chain 5)) tesl-lambda-42) (list)"))
  )

  (test-case "R60_TU01 tuple accessor loses proof requiring re-check"
  (define r (tupleProofLoss 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R60_UC01 unannotated field loses proof requiring re-check"
  (define r (plainFieldLoss 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R60_RU01 record update preserves proof on annotated title field"
  (define item (makeItem "hello" 5))
  (define newTitle "world")
  (define updated (updateTitle item newTitle))
  (define t (useItemTitle updated))
  (check-equal? (raw-value t) "world")
  )

  (test-case "R60_RU02 updated item count proof is preserved after title update"
  (define item (makeItem "hello" 5))
  (define newTitle "world")
  (define updated (updateTitle item newTitle))
  (define c (useItemCount updated))
  (check-equal? (raw-value c) 5)
  )

  (test-case "R60_RU03 record update preserves proof on annotated count field"
  (define item (makeItem "hello" 5))
  (define newCount 42)
  (define updated (updateCount item newCount))
  (define c (useItemCount updated))
  (check-equal? (raw-value c) 42)
  )

  (test-case "R60_RU04 updated item title proof preserved after count update"
  (define item (makeItem "hello" 5))
  (define newCount 42)
  (define updated (updateCount item newCount))
  (define t (useItemTitle updated))
  (check-equal? (raw-value t) "hello")
  )

  (test-case "R60_RU05 updating both annotated fields preserves both proofs"
  (define item (makeItem "hello" 5))
  (define newTitle "world")
  (define newCount 99)
  (define updated (updateBoth item newTitle newCount))
  (define t (useItemTitle updated))
  (define c (useItemCount updated))
  (check-equal? (raw-value t) "world")
  (check-equal? (raw-value c) 99)
  )

  (test-case "R60_RU06 updated record rejects bad title at update time"
  (define item (makeItem "hello" 5))
  (define bad "")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-42) #:returns Any (updateTitle item bad)) tesl-lambda-42) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-43) #:returns Any (updateTitle item bad)) tesl-lambda-43) (list)"))
  )

  (test-case "R60_RU07 updated record rejects bad count at update time"
  (define item (makeItem "hello" 5))
  (define bad 0)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-43) #:returns Any (updateCount item bad)) tesl-lambda-43) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-44) #:returns Any (updateCount item bad)) tesl-lambda-44) (list)"))
  )

  (test-case "R60_DT2_01 detachFact on 4-chain returns conjunction"
  (define r (detachConjunction 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R60_DT2_02 detachFact on 2-chain returns A&&B conjunction"
  (define r (detachTwoProofs 5))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R60_DT2_03 detachFact on single proof still works"
  (define raw 5)
  (define tesl_checked_44 (checkA raw))
  (when (check-fail? tesl_checked_44)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl_checked_44)))
  (define a tesl_checked_44)
  (define p (detach-all-proof a))
  (define base (forget-proof a))
  (define withA (attach-proof base p))
  (define r (needsA withA))
  (check-equal? (raw-value r) 5)
  )

  (test-case "R60_CK01 ok with constructor application compiles and runs"
  (define tesl_checked_45 (checkAndWrapUserId "abc"))
  (when (check-fail? tesl_checked_45)
    (raise-user-error 'tesl-test "unexpected failure in let uid: ~a" (check-fail-message tesl_checked_45)))
  (define uid tesl_checked_45)
  (define result (needsValidId uid))
  (check-equal? (raw-value (tesl-dot/runtime result 'value)) "abc")
  )

  (test-case "R60_CK02 ok with constructor application rejects short id"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((let () (define/pow (tesl-lambda-46) #:returns Any (raw-value (checkAndWrapUserId "ab"))) tesl-lambda-46) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-47) #:returns Any (raw-value (checkAndWrapUserId \"ab\"))) tesl-lambda-47) (list)"))
  )

  (test-case "R60_EX01 exhaustive 3-constructor ADT case works"
  (check-equal? (raw-value (colorName Red)) "red")
  (check-equal? (raw-value (colorName Green)) "green")
  (check-equal? (raw-value (colorName Blue)) "blue")
  )

  (test-case "R60_EX02 exhaustive 4-constructor ADT case works"
  (check-equal? (raw-value (suitColor Hearts)) "red")
  (check-equal? (raw-value (suitColor Spades)) "black")
  )

  (test-case "R60_EX03 wildcard covers remaining constructors"
  (check-equal? (raw-value (suitColorWildcard Hearts)) "red")
  (check-equal? (raw-value (suitColorWildcard Clubs)) "black")
  )

  (test-case "R60_EX04 exhaustive Maybe case works"
  (check-equal? (raw-value (maybeWithFallback Nothing)) 0)
  (check-equal? (raw-value (maybeWithFallback (raw-value (Something 42)))) 42)
  )

)
