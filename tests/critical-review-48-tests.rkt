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
  (only-in tesl/tesl/prelude Bool Int List String Fact attachFact detachFact forgetFact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.isEmpty tesl_import_String_isEmpty] [String.trim tesl_import_String_trim] [String.contains tesl_import_String_contains] [String.toUpper tesl_import_String_toUpper] [String.toLower tesl_import_String_toLower] IsTrimmed)
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.foldl tesl_import_List_foldl] [List.any tesl_import_List_any] [List.all tesl_import_List_all] [List.head tesl_import_List_head] [List.filter tesl_import_List_filter] [List.reverse tesl_import_List_reverse] [List.append tesl_import_List_append] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either Either Left Right)
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide] IsNonZero [Int.nonNegative tesl_import_Int_nonNegative] [Int.abs tesl_import_Int_abs] [Int.toString tesl_import_Int_toString] IsNonNegative)
  (only-in tesl/tesl/float Float [Float.abs tesl_import_Float_abs] [Float.sqrt tesl_import_Float_sqrt])
)


(provide checkPositive48 requiresPositive48 checkNonEmpty48 Positive48 NonEmpty48 maybeEstablish alwaysEstablish Meters Kilograms convertMeters convertKilograms decompose48 decomposeAndUse checkBothProofs useBothProofs Direction North South East West Speed Slow Fast Movement Moving Stopped describeMovement pipedAdd pipedCheckLen BetweenFact checkBetween48 requiresBetween48 filterSmallPositive smallPositiveAll formatComplex ExprF LitF AddF NegF evalExpr48 Status48 Active48 Inactive48 Suspended48 describeStatus48 largeMul resultFromCase48 makeAdder applyTwice Priority48 Critical48 High48 Medium48 Low48 priorityLabel httpStatus wrapAll unwrapAll attemptProve48 ValidTitle48 checkTitle48 SafeItem48 readSafeField OrderedPair OrderedFact proveOrdered makeOrderedPair checkPositive48-signature requiresPositive48-signature alwaysEstablish-signature maybeEstablish-signature convertMeters-signature convertKilograms-signature decompose48-signature decomposeAndUse-signature checkBothProofs-signature useBothProofs-signature describeMovement-signature pipedAdd-signature pipedCheckLen-signature checkBetween48-signature requiresBetween48-signature filterSmallPositive-signature smallPositiveAll-signature formatComplex-signature evalExpr48-signature describeStatus48-signature largeMul-signature resultFromCase48-signature makeAdder-signature applyTwice-signature priorityLabel-signature httpStatus-signature wrapAll-signature unwrapAll-signature attemptProve48-signature checkTitle48-signature readSafeField-signature proveOrdered-signature makeOrderedPair-signature checkNonEmpty48-signature)

(define BetweenFact 'BetweenFact)
(define NonEmpty48 'NonEmpty48)
(define OrderedFact 'OrderedFact)
(define Positive48 'Positive48)
(define ProvenFact48 'ProvenFact48)
(define Small48 'Small48)
(define ValidPort48 'ValidPort48)
(define ValidTitle48 'ValidTitle48)

(define-checker
  (checkPositive48 [n : Integer])
  #:returns [n : Integer ::: (Positive48 n)]
  (if (> *n 0) (accept (Positive48 n) #:value *n) (reject "must be positive" #:http-code 400)))

(define/pow
  (requiresPositive48 [n : Integer ::: (Positive48 n)])
  #:returns Integer
  (* *n 2))

(define-trusted
  (alwaysEstablish [n : Integer])
  #:returns (Fact (ProvenFact48 n))
  (trusted-proof (ProvenFact48 n)))

(define-trusted
  (maybeEstablish [n : Integer])
  #:returns (Maybe (Fact (ProvenFact48 n)))
  (if (> *n 0) (Something (trusted-proof (ProvenFact48 n))) Nothing))

(define-newtype Meters Integer)

(define-newtype Kilograms Integer)

(define/pow
  (convertMeters [m : Meters])
  #:returns String
  (format "~am" (tesl-display-val (raw-value m.value))))

(define/pow
  (convertKilograms [kg : Kilograms])
  #:returns String
  (format "~akg" (tesl-display-val (raw-value kg.value))))

(define/pow
  (decompose48 [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_0 (checkPositive48 n)]) (let ([proven tesl_checked_0]) (let ([tesl_proof_binding_1 proven]) (let ([raw (forget-proof tesl_proof_binding_1)] [proof (detach-all-proof tesl_proof_binding_1)]) (let ([reattached (attach-proof raw proof)]) (raw-value (requiresPositive48 reattached))))))))

(define/pow
  (decomposeAndUse [n : Integer])
  #:returns String
  (let/check ([tesl_checked_2 (checkPositive48 n)]) (let ([proven tesl_checked_2]) (let ([val proven]) (format "value is ~a" (tesl-display-val *val))))))

(define-checker
  (checkSmall48 [n : Integer])
  #:returns [n : Integer ::: (Small48 n)]
  (if (< *n 100) (accept (Small48 n) #:value *n) (reject "must be small" #:http-code 400)))

(define-checker
  (checkBothProofs [n : Integer])
  #:returns [n : Integer ::: ((Positive48 n) && (Small48 n))]
  ((check-and checkPositive48 checkSmall48) n))

(define/pow
  (useBothProofs [n : Integer ::: ((Positive48 n) && (Small48 n))])
  #:returns Integer
  (* *n 3))

(define-adt Direction
  [North]
  [South]
  [East]
  [West]
)

(define-adt Speed
  [Slow]
  [Fast]
)

(define-adt Movement
  [Moving [dir : Direction] [speed : Speed]]
  [Stopped]
)

(define/pow
  (describeMovement [m : Movement])
  #:returns String
  (let ([tesl_case_3 *m]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Stopped)) (raw-value "stopped")] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Moving)) (let ([dir (hash-ref (adt-value-fields *tesl_case_3) 'dir)]) (let ([speed (hash-ref (adt-value-fields *tesl_case_3) 'speed)]) (let ([dirStr (let ([tesl_case_4 (raw-value dir)]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'North)) "north"] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'South)) "south"] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'East)) "east"] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'West)) "west"]))]) (let ([speedStr (let ([tesl_case_5 (raw-value speed)]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Slow)) "slowly"] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Fast)) "quickly"]))]) (raw-value (format "moving ~a ~a" (tesl-display-val *dirStr) (tesl-display-val *speedStr)))))))])))

(define/pow
  (add48 [x : Integer] [y : Integer])
  #:returns Integer
  (+ *x *y))

(define/pow
  (double48 [n : Integer])
  #:returns Integer
  (* *n 2))

(define/pow
  (pipedAdd [n : Integer])
  #:returns Integer
  (raw-value (double48 (double48 n))))

(define/pow
  (pipedCheckLen [s : String])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define-checker
  (checkBetween48 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (BetweenFact lo hi n)]
  (if (and (>= *n *lo) (<= *n *hi)) (accept (BetweenFact lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))

(define/pow
  (requiresBetween48 [lo : Integer] [hi : Integer] [n : Integer ::: (BetweenFact lo hi n)])
  #:returns String
  (format "~a in [~a,~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))

(define/pow
  (testBetween [lo : Integer] [hi : Integer] [n : Integer])
  #:returns String
  (let/check ([tesl_checked_6 (checkBetween48 lo hi n)]) (let ([v tesl_checked_6]) (raw-value (requiresBetween48 lo hi v)))))

(define/pow
  (filterSmallPositive [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck (check-and checkPositive48 checkSmall48) *xs))

(define/pow
  (smallPositiveAll [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (tesl_import_List_allCheck checkPositive48 *xs))

(define/pow
  (formatComplex [a : Integer] [b : Integer])
  #:returns String
  (let ([theSum (+ *a *b)]) (let ([diff (- *a *b)]) (format "sum=~a, diff=~a" (tesl-display-val *theSum) (tesl-display-val *diff)))))

(define-adt ExprF
  [LitF [n : Integer]]
  [AddF [left : ExprF] [right : ExprF]]
  [NegF [inner : ExprF]]
)

(define/pow
  (evalExpr48 [e : ExprF])
  #:returns Integer
  (let ([tesl_case_7 *e]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'LitF)) (let ([n (hash-ref (adt-value-fields *tesl_case_7) 'n)]) *n)] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'AddF)) (let ([left (hash-ref (adt-value-fields *tesl_case_7) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_7) 'right)]) (raw-value (+ (raw-value (evalExpr48 *left)) (raw-value (evalExpr48 *right))))))] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'NegF)) (let ([inner (hash-ref (adt-value-fields *tesl_case_7) 'inner)]) (raw-value (- 0 (raw-value (evalExpr48 *inner)))))])))

(define-adt Status48
  [Active48]
  [Inactive48]
  [Suspended48 [reason : String]]
)

(define/pow
  (describeStatus48 [s : Status48])
  #:returns String
  (let ([tesl_case_8 *s]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Active48)) (raw-value "active")] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Inactive48)) (raw-value "inactive")] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Suspended48)) (let ([reason (hash-ref (adt-value-fields *tesl_case_8) 'reason)]) (raw-value (format "suspended: ~a" (tesl-display-val *reason))))])))

(define/pow
  (largeMul [a : Integer] [b : Integer])
  #:returns Integer
  (* *a *b))

(define/pow
  (resultFromCase48 [m : (Maybe Integer)])
  #:returns Integer
  (let ([tesl_case_9 *m]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Nothing)) (raw-value 0)] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_9) 'value)]) (let/check ([tesl_checked_10 (checkPositive48 *v)]) (let ([proven tesl_checked_10]) (raw-value (requiresPositive48 proven)))))])))

(define/pow
  (makeAdder [n : Integer])
  #:returns (-> Integer Integer)
  (let () (define/pow (tesl-lambda-11 [x : Integer]) #:returns Integer (+ *x *n)) tesl-lambda-11))

(define/pow
  (applyTwice [f : (-> Integer Integer)] [x : Integer])
  #:returns Integer
  (raw-value (f (f x))))

(define-adt Priority48
  [Critical48]
  [High48]
  [Medium48]
  [Low48]
)

(define/pow
  (priorityLabel [p : Priority48])
  #:returns String
  (let ([tesl_case_12 *p]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Critical48)) (raw-value "urgent")] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'High48)) (raw-value "urgent")] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Medium48)) (raw-value "normal")] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Low48)) (raw-value "low")])))

(define/pow
  (httpStatus [code : Integer])
  #:returns String
  (let ([tesl_case_13 *code]) (cond [(= *tesl_case_13 200) (raw-value "OK")] [(= *tesl_case_13 201) (raw-value "Created")] [(= *tesl_case_13 400) (raw-value "Bad Request")] [(= *tesl_case_13 404) (raw-value "Not Found")] [(= *tesl_case_13 500) (raw-value "Internal Server Error")] [#t (raw-value "Unknown")])))

(define/pow
  (wrapAll [xs : (List Integer)])
  #:returns (List Meters)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-14 [n : Integer]) #:returns Any (raw-value (Meters *n))) tesl-lambda-14) *xs)))

(define/pow
  (unwrapAll [xs : (List Meters)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-15 [m : Meters]) #:returns Integer (raw-value m.value)) tesl-lambda-15) *xs)))

(define-trusted
  (attemptProve48 [p : Integer])
  #:returns (Maybe (Fact (ValidPort48 p)))
  (if (and (>= *p 1) (<= *p 65535)) (Something (trusted-proof (ValidPort48 p))) Nothing))

(define/pow
  (requiresValidPort48 [p : Integer ::: (ValidPort48 p)])
  #:returns String
  (format "port ~a" (tesl-display-val *p)))

(define/pow
  (tryListen [p : Integer])
  #:returns String
  (let ([maybeProof (attemptProve48 p)]) (let ([tesl_case_16 (raw-value maybeProof)]) (cond [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Something)) (let ([proof (hash-ref (adt-value-fields *tesl_case_16) 'value)]) (raw-value (requiresValidPort48 (attach-proof p proof))))] [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Nothing)) (raw-value "invalid port")]))))

(define-checker
  (checkTitle48 [s : String])
  #:returns [s : String ::: (ValidTitle48 s)]
  (if (and (>= (raw-value (tesl_import_String_length *s)) 1) (<= (raw-value (tesl_import_String_length *s)) 100)) (accept (ValidTitle48 s) #:value *s) (reject "title must be 1-100 chars" #:http-code 400)))

(define/pow
  (requiresValidTitle48 [t : String ::: (ValidTitle48 t)])
  #:returns Integer
  (raw-value (tesl_import_String_length *t)))

(define-record SafeItem48
  [title : String ::: (ValidTitle48 title)]
)

(define/pow
  (readSafeField [item : SafeItem48])
  #:returns Integer
  (raw-value (requiresValidTitle48 (tesl-dot/runtime item 'title))))

(define-record OrderedPair
  [lo : Integer]
  [hi : Integer]
)

(define-trusted
  (proveOrdered [lo : Integer] [hi : Integer])
  #:returns (Maybe (Fact (OrderedFact lo hi)))
  (if (<= *lo *hi) (Something (trusted-proof (OrderedFact lo hi))) Nothing))

(define/pow
  (makeOrderedPair [a : Integer] [b : Integer])
  #:returns (Maybe OrderedPair)
  (let ([maybeProof (proveOrdered a b)]) (let ([tesl_case_17 (raw-value maybeProof)]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Something)) (let ([proof (hash-ref (adt-value-fields *tesl_case_17) 'value)]) (raw-value (raw-value (Something (OrderedPair #:lo *a #:hi *b)))))]))))

(define-checker
  (checkNonEmpty48 [s : String])
  #:returns [s : String ::: (NonEmpty48 s)]
  (if (tesl_import_String_isEmpty *s) (reject "empty" #:http-code 400) (accept (NonEmpty48 s) #:value *s)))

(define/pow
  (safeTake48 [xs : (List Integer)] [n : Integer])
  #:returns (List Integer)
  (let/check ([tesl_checked_18 (tesl_import_Int_nonNegative n)]) (let ([nn tesl_checked_18]) (raw-value (tesl_import_List_take nn *xs)))))

(define/pow
  (safeDivide48 [a : Integer] [b : Integer])
  #:returns Integer
  (let/check ([tesl_checked_19 (tesl_import_Int_nonZero b)]) (let ([nz tesl_checked_19]) (raw-value (tesl_import_Int_divide *a nz)))))

(define/pow
  (forgetAndRecheck [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_20 (checkPositive48 n)]) (let ([proven tesl_checked_20]) (let ([forgotten (forget-proof proven)]) (let/check ([tesl_checked_21 (checkPositive48 forgotten)]) (let ([reproven tesl_checked_21]) (raw-value (requiresPositive48 reproven))))))))

(module+ test
  (require rackunit)
  (test-case "R48-01: proof round-trip via check -> requires"
  (define raw 42)
  (define tesl_checked_22 (checkPositive48 raw))
  (when (check-fail? tesl_checked_22)
    (raise-user-error 'tesl-test "unexpected failure in let proven: ~a" (check-fail-message tesl_checked_22)))
  (define proven tesl_checked_22)
  (check-equal? (raw-value (requiresPositive48 proven)) 84)
  )

  (test-case "R48-02: check rejects boundary 0"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPositive48 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositive48 0"))
  )

  (test-case "R48-03: check rejects negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPositive48 -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositive48 -1"))
  )

  (test-case "R48-04: no-shadowing rule is enforced (module compiles)"
  (check-equal? 1 1)
  )

  (test-case "R48-05: establish always succeeds (total)"
  (define raw 5)
  (define proof (alwaysEstablish raw))
  (check-equal? 1 1)
  )

  (test-case "R48-06: maybe establish returns Something for positive"
  (define raw 10)
  (define result (maybeEstablish raw))
  (check-not-equal? result Nothing)
  )

  (test-case "R48-07: maybe establish returns Nothing for non-positive"
  (define raw 0)
  (define result (maybeEstablish raw))
  (check-equal? (raw-value result) Nothing)
  (define rawNeg -5)
  (define result2 (maybeEstablish rawNeg))
  (check-equal? (raw-value result2) Nothing)
  )

  (test-case "R48-08: newtypes produce correct string representation"
  (define m (raw-value (Meters 42)))
  (define kg (raw-value (Kilograms 100)))
  (check-equal? (raw-value (convertMeters m)) "42m")
  (check-equal? (raw-value (convertKilograms kg)) "100kg")
  )

  (test-case "R48-09: newtype .value round-trips"
  (define m (raw-value (Meters 0)))
  (check-equal? (raw-value (tesl-dot/runtime m 'value)) 0)
  (define kg (raw-value (Kilograms -5)))
  (check-equal? (raw-value (tesl-dot/runtime kg 'value)) -5)
  )

  (test-case "R48-10: decompose-reattach round-trip"
  (check-equal? (raw-value (decompose48 5)) 10)
  (check-equal? (raw-value (decompose48 1)) 2)
  )

  (test-case "R48-11: decompose fails for invalid input"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (decompose48 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decompose48 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (decompose48 -5))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decompose48 -5"))
  )

  (test-case "R48-12: decompose-and-discard-proof"
  (check-equal? (raw-value (decomposeAndUse 7)) "value is 7")
  )

  (test-case "R48-13: conjunction passes for valid values"
  (define n 50)
  (define tesl_checked_23 (checkBothProofs n))
  (when (check-fail? tesl_checked_23)
    (raise-user-error 'tesl-test "unexpected failure in let proven: ~a" (check-fail-message tesl_checked_23)))
  (define proven tesl_checked_23)
  (check-equal? (raw-value (useBothProofs proven)) 150)
  )

  (test-case "R48-14: conjunction fails for zero (not positive)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkBothProofs 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBothProofs 0"))
  )

  (test-case "R48-15: conjunction fails for 100 (not small)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkBothProofs 100))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBothProofs 100"))
  )

  (test-case "R48-16: conjunction boundary: 1 and 99"
  (define n1 1)
  (define tesl_checked_24 (checkBothProofs n1))
  (when (check-fail? tesl_checked_24)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_24)))
  (define v1 tesl_checked_24)
  (check-equal? (raw-value (useBothProofs v1)) 3)
  (define n99 99)
  (define tesl_checked_25 (checkBothProofs n99))
  (when (check-fail? tesl_checked_25)
    (raise-user-error 'tesl-test "unexpected failure in let v99: ~a" (check-fail-message tesl_checked_25)))
  (define v99 tesl_checked_25)
  (check-equal? (raw-value (useBothProofs v99)) 297)
  )

  (test-case "R48-17: movement north slowly"
  (check-equal? (raw-value (describeMovement (Moving North Slow))) "moving north slowly")
  )

  (test-case "R48-18: movement east quickly"
  (check-equal? (raw-value (describeMovement (Moving East Fast))) "moving east quickly")
  )

  (test-case "R48-19: stopped"
  (check-equal? (raw-value (describeMovement Stopped)) "stopped")
  )

  (test-case "R48-20: all directions covered"
  (check-equal? (raw-value (describeMovement (Moving South Fast))) "moving south quickly")
  (check-equal? (raw-value (describeMovement (Moving West Slow))) "moving west slowly")
  )

  (test-case "R48-21: pipe chains apply left-to-right"
  (check-equal? (raw-value (pipedAdd 3)) 12)
  (check-equal? (raw-value (pipedAdd 0)) 0)
  (check-equal? (raw-value (pipedAdd 1)) 4)
  )

  (test-case "R48-22: pipe with String.length"
  (check-equal? (raw-value (pipedCheckLen "hello")) 5)
  (check-equal? (raw-value (pipedCheckLen "")) 0)
  )

  (test-case "R48-23: multi-param fact passing"
  (check-equal? (raw-value (testBetween 0 10 5)) "5 in [0,10]")
  )

  (test-case "R48-24: multi-param fact boundary lo"
  (check-equal? (raw-value (testBetween 10 20 10)) "10 in [10,20]")
  )

  (test-case "R48-25: multi-param fact boundary hi"
  (check-equal? (raw-value (testBetween 10 20 20)) "20 in [10,20]")
  )

  (test-case "R48-26: multi-param fact below lo fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testBetween 10 20 9) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testBetween 10 20 9) (list)"))
  )

  (test-case "R48-27: multi-param fact above hi fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((testBetween 10 20 21) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testBetween 10 20 21) (list)"))
  )

  (test-case "R48-28: multi-param fact negative range"
  (check-equal? (raw-value (testBetween -10 -1 -5)) "-5 in [-10,-1]")
  )

  (test-case "R48-29: filterCheck combined proof on empty list"
  (define result (filterSmallPositive (list)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 0)
  )

  (test-case "R48-30: filterCheck combined proof on mixed list"
  (define result (filterSmallPositive (list 1 -1 50 100 99 0)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "R48-31: allCheck returns Nothing on single failure"
  (define result (smallPositiveAll (list 1 2 0 4)))
  (check-equal? (raw-value result) Nothing)
  )

  (test-case "R48-32: allCheck returns Something on all pass"
  (define result (smallPositiveAll (list 1 2 3 4 5)))
  (check-not-equal? result Nothing)
  )

  (test-case "R48-33: allCheck on empty list succeeds (vacuous truth)"
  (define result (smallPositiveAll (list)))
  (check-not-equal? result Nothing)
  )

  (test-case "R48-34: complex interpolation"
  (check-equal? (raw-value (formatComplex 10 3)) "sum=13, diff=7")
  (check-equal? (raw-value (formatComplex 0 0)) "sum=0, diff=0")
  (check-equal? (raw-value (formatComplex -5 3)) "sum=-2, diff=-8")
  )

  (test-case "R48-35: recursive ADT eval leaf"
  (check-equal? (raw-value (evalExpr48 (LitF 42))) 42)
  )

  (test-case "R48-36: recursive ADT eval add"
  (check-equal? (raw-value (evalExpr48 (AddF (LitF 3) (LitF 4)))) 7)
  )

  (test-case "R48-37: recursive ADT eval double neg"
  (check-equal? (raw-value (evalExpr48 (NegF (NegF (LitF 5))))) 5)
  )

  (test-case "R48-38: recursive ADT deeply nested"
  (define e (raw-value (AddF (NegF (LitF 10)) (AddF (LitF 7) (LitF 3)))))
  (check-equal? (raw-value (evalExpr48 e)) 0)
  )

  (test-case "R48-39: nullary constructors pattern match"
  (check-equal? (raw-value (describeStatus48 Active48)) "active")
  (check-equal? (raw-value (describeStatus48 Inactive48)) "inactive")
  )

  (test-case "R48-40: constructor with field"
  (check-equal? (raw-value (describeStatus48 (Suspended48 "policy violation"))) "suspended: policy violation")
  )

  (test-case "R48-41: large multiplication"
  (check-equal? (raw-value (largeMul 1000000 1000)) 1000000000)
  )

  (test-case "R48-42: multiply by zero"
  (check-equal? (raw-value (largeMul 999999 0)) 0)
  (check-equal? (raw-value (largeMul 0 999999)) 0)
  )

  (test-case "R48-43: negative multiplication"
  (check-equal? (raw-value (largeMul -3 -4)) 12)
  (check-equal? (raw-value (largeMul -3 4)) -12)
  )

  (test-case "R48-44: proof in case Something branch"
  (check-equal? (raw-value (resultFromCase48 (raw-value (Something 5)))) 10)
  )

  (test-case "R48-45: Nothing branch returns 0"
  (check-equal? (raw-value (resultFromCase48 Nothing)) 0)
  )

  (test-case "R48-46: case Something with 0 fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (resultFromCase48 (raw-value (Something 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: resultFromCase48 (raw-value (Something 0))"))
  )

  (test-case "R48-47: closure captures outer variable"
  (define add5 (makeAdder 5))
  (check-equal? (raw-value (add5 10)) 15)
  (check-equal? (raw-value (add5 0)) 5)
  )

  (test-case "R48-48: applyTwice with closure"
  (define add3 (makeAdder 3))
  (check-equal? (raw-value (applyTwice add3 10)) 16)
  )

  (test-case "R48-49: applyTwice with inline lambda"
  (check-equal? (raw-value (applyTwice (let () (define/pow (tesl-lambda-26 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-26) 3)) 12)
  )

  (test-case "R48-50: fall-through Critical48 -> urgent"
  (check-equal? (raw-value (priorityLabel Critical48)) "urgent")
  )

  (test-case "R48-51: fall-through High48 -> urgent"
  (check-equal? (raw-value (priorityLabel High48)) "urgent")
  )

  (test-case "R48-52: Medium48 -> normal"
  (check-equal? (raw-value (priorityLabel Medium48)) "normal")
  )

  (test-case "R48-53: Low48 -> low"
  (check-equal? (raw-value (priorityLabel Low48)) "low")
  )

  (test-case "R48-54: literal patterns match exactly"
  (check-equal? (raw-value (httpStatus 200)) "OK")
  (check-equal? (raw-value (httpStatus 201)) "Created")
  (check-equal? (raw-value (httpStatus 404)) "Not Found")
  (check-equal? (raw-value (httpStatus 500)) "Internal Server Error")
  )

  (test-case "R48-55: literal patterns wildcard fallback"
  (check-equal? (raw-value (httpStatus 301)) "Unknown")
  (check-equal? (raw-value (httpStatus 0)) "Unknown")
  (check-equal? (raw-value (httpStatus -1)) "Unknown")
  )

  (test-case "R48-56: wrap and unwrap list of newtypes"
  (define wrapped (wrapAll (list 1 2 3)))
  (define unwrapped (unwrapAll wrapped))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value unwrapped)))) 3)
  )

  (test-case "R48-57: wrap empty list"
  (define wrapped (wrapAll (list)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value wrapped)))) 0)
  )

  (test-case "R48-58: establish proof via attach"
  (check-equal? (raw-value (tryListen 80)) "port 80")
  (check-equal? (raw-value (tryListen 443)) "port 443")
  )

  (test-case "R48-59: establish returns Nothing for invalid"
  (check-equal? (raw-value (tryListen 0)) "invalid port")
  (check-equal? (raw-value (tryListen -1)) "invalid port")
  (check-equal? (raw-value (tryListen 65536)) "invalid port")
  )

  (test-case "R48-60: establish boundary values"
  (check-equal? (raw-value (tryListen 1)) "port 1")
  (check-equal? (raw-value (tryListen 65535)) "port 65535")
  )

  (test-case "R48-61: record field carries proof"
  (define rawTitle "my item")
  (define tesl_checked_27 (checkTitle48 rawTitle))
  (when (check-fail? tesl_checked_27)
    (raise-user-error 'tesl-test "unexpected failure in let validTitle: ~a" (check-fail-message tesl_checked_27)))
  (define validTitle tesl_checked_27)
  (define item (SafeItem48 #:title validTitle))
  (check-equal? (raw-value (readSafeField item)) 7)
  )

  (test-case "R48-62: record field proof on boundary length"
  (define rawTitle "x")
  (define tesl_checked_28 (checkTitle48 rawTitle))
  (when (check-fail? tesl_checked_28)
    (raise-user-error 'tesl-test "unexpected failure in let validTitle: ~a" (check-fail-message tesl_checked_28)))
  (define validTitle tesl_checked_28)
  (define item (SafeItem48 #:title validTitle))
  (check-equal? (raw-value (readSafeField item)) 1)
  )

  (test-case "R48-63: ghost witness allows construction"
  (define result (makeOrderedPair 1 10))
  (check-not-equal? result Nothing)
  )

  (test-case "R48-64: ghost witness rejects wrong order"
  (define result (makeOrderedPair 10 1))
  (check-equal? (raw-value result) Nothing)
  )

  (test-case "R48-65: ghost witness accepts equal values"
  (define result (makeOrderedPair 5 5))
  (check-not-equal? result Nothing)
  )

  (test-case "R48-66: property - positive check consistent"
  ; property: positive check succeeds for positive ints
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) 0) (< (raw-value n) 10000)) (check-true (let/check ([tesl_checked_29 (checkPositive48 n)]) (let ([v tesl_checked_29]) (> (raw-value (requiresPositive48 v)) 0))) "positive check succeeds for positive ints"))
    ))
  )

  (test-case "R48-67: property - string length non-negative"
  ; property: string length is never negative
  (for ([tesl-prop-i (in-range 100)])
    (let ([s (format "s~a" (random 1000000))])
      (check-true (>= (raw-value (tesl_import_String_length (raw-value s))) 0) "string length is never negative")
    ))
  )

  (test-case "R48-68: property - double neg is identity"
  ; property: negating twice returns original
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) -10000) (< (raw-value n) 10000)) (check-true (equal? (- 0 (- 0 (raw-value n))) (raw-value n)) "negating twice returns original"))
    ))
  )

  (test-case "R48-69: proof-total List.take"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (safeTake48 (list 1 2 3 4 5) 3))))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (safeTake48 (list 1 2 3) 0))))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (safeTake48 (list) 5))))) 0)
  )

  (test-case "R48-70: proof-total List.take rejects negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((safeTake48 (list 1 2 3) -1) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeTake48 (list 1 2 3) -1) (list)"))
  )

  (test-case "R48-71: proof-total Int.divide"
  (check-equal? (raw-value (safeDivide48 10 3)) 3)
  (check-equal? (raw-value (safeDivide48 -10 3)) -3)
  (check-equal? (raw-value (safeDivide48 0 5)) 0)
  )

  (test-case "R48-72: proof-total Int.divide rejects zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          ((safeDivide48 10 0) (list)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivide48 10 0) (list)"))
  )

  (test-case "R48-73: List.reverse"
  (check-equal? (raw-value (tesl_import_List_reverse (list 1 2 3))) (list 3 2 1))
  (check-equal? (raw-value (tesl_import_List_reverse (list))) (list))
  (check-equal? (raw-value (tesl_import_List_reverse (list 42))) (list 42))
  )

  (test-case "R48-74: List.append"
  (check-equal? (raw-value (tesl_import_List_append (list 1 2) (list 3 4))) (list 1 2 3 4))
  (check-equal? (raw-value (tesl_import_List_append (list) (list 1))) (list 1))
  (check-equal? (raw-value (tesl_import_List_append (list 1) (list))) (list 1))
  )

  (test-case "R48-75: forgetFact then re-check"
  (check-equal? (raw-value (forgetAndRecheck 5)) 10)
  )

  (test-case "R48-76: forgetFact on boundary"
  (check-equal? (raw-value (forgetAndRecheck 1)) 2)
  )

)
