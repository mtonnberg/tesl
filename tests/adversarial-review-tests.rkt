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
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.trim tesl_import_String_trim] [String.contains tesl_import_String_contains] [String.isEmpty tesl_import_String_isEmpty])
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.foldl tesl_import_List_foldl] [List.any tesl_import_List_any] [List.all tesl_import_List_all] [List.head tesl_import_List_head])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide] IsNonZero)
  (only-in tesl/tesl/either Either Left Right)
  (only-in tesl/tesl/float Float [Float.add tesl_import_Float_add] [Float.mul tesl_import_Float_mul] [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero [Float.div tesl_import_Float_div] [Float.isPositive tesl_import_Float_isPositive] [Float.sqrt tesl_import_Float_sqrt] [Float.abs tesl_import_Float_abs])
  (only-in tesl/tesl/string [String.toUpper tesl_import_String_toUpper] [String.toLower tesl_import_String_toLower])
)


(provide checkNonEmpty checkEmail requiresRange requiresNonEmpty clampAndAdd Shape Circle Rectangle Triangle evaluate describeNested forAllChain ProjectId makeUserId makeProjectId checkSmall checkBoth requiresTrimmed checkAge decomposeThenPass checkInBounds requiresInBounds readAndWrite isOdd describeAll divByTwo requiresBounded checkAscii requiresAscii conjunctSatisfied checkPosAndSmall requiresPosAndSmall checkPositiveMsg wrapAndUnwrap safeRecip safeSqrt makeTagged TaggedInt requiresTagged checkSlug requiresSlug identityProof checkNonNegStr requiresNonNegStr treeDepth Tree Leaf Node factorial fibonacci checkInBounds1020 checkInBoundsEqual checkInBoundsNeg checkInBoundsLo fnWrapsCheck filteredPositives requiresRange-signature checkNonEmpty-signature requiresNonEmpty-signature checkEmail-signature clampAndAdd-signature describeAll-signature evaluate-signature describeNested-signature checkSmall-signature forAllChain-signature makeUserId-signature makeProjectId-signature checkBoth-signature requiresTrimmed-signature checkAge-signature decomposeThenPass-signature checkInBounds-signature requiresInBounds-signature isOdd-signature divByTwo-signature readAndWrite-signature requiresBounded-signature checkPosAndSmall-signature requiresPosAndSmall-signature makeTagged-signature requiresTagged-signature checkAscii-signature requiresAscii-signature checkPositiveMsg-signature wrapAndUnwrap-signature safeRecip-signature safeSqrt-signature checkSlug-signature requiresSlug-signature identityProof-signature checkNonNegStr-signature requiresNonNegStr-signature treeDepth-signature factorial-signature fibonacci-signature conjunctSatisfied-signature checkInBounds1020-signature checkInBoundsEqual-signature checkInBoundsNeg-signature checkInBoundsLo-signature fnWrapsCheck-signature filteredPositives-signature)

(define AsciiOnly 'AsciiOnly)
(define AtLeastFive 'AtLeastFive)
(define AtMostTen 'AtMostTen)
(define Bounded 'Bounded)
(define InBounds 'InBounds)
(define InRange 'InRange)
(define NonEmpty 'NonEmpty)
(define NonNegLen 'NonNegLen)
(define NonNegative 'NonNegative)
(define Positive 'Positive)
(define Small 'Small)
(define Trimmed 'Trimmed)
(define ValidAge 'ValidAge)
(define ValidEmail 'ValidEmail)
(define ValidSlug 'ValidSlug)

(define-checker
  (checkRange [n : Integer])
  #:returns [n : Integer ::: (InRange n)]
  (if (and (>= *n 0) (<= *n 100)) (accept (InRange n) #:value *n) (reject "must be 0\u2013100" #:http-code 400)))

(define/pow
  (requiresRange [n : Integer ::: (InRange n)])
  #:returns Integer
  (+ *n 1))

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (NonEmpty s)]
  (if (tesl_import_String_isEmpty *s) (reject "must not be empty" #:http-code 400) (accept (NonEmpty s) #:value *s)))

(define/pow
  (requiresNonEmpty [s : String ::: (NonEmpty s)])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define-checker
  (checkEmail [email : String])
  #:returns [email : String ::: (ValidEmail email)]
  (if (and (raw-value (tesl_import_String_contains *email "@")) (raw-value (tesl_import_String_contains *email ".")) (>= (raw-value (tesl_import_String_length *email)) 5)) (accept (ValidEmail email) #:value *email) (reject "invalid email address" #:http-code 400)))

(define/pow
  (safeDiv [a : Integer] [b : Integer])
  #:returns (Either String Integer)
  (if (equal? *b 0) (raw-value (raw-value (Left "division by zero"))) (let/check ([tesl_checked_0 (tesl_import_Int_nonZero b)]) (let ([checkedB tesl_checked_0]) (raw-value (raw-value (Right (tesl_import_Int_divide *a checkedB))))))))

(define/pow
  (clampAndAdd [lo : Integer] [hi : Integer] [n : Integer] [delta : Integer])
  #:returns Integer
  (let ([clamped (clamp lo hi n)]) (+ (raw-value clamped) *delta)))

(define/pow
  (clamp [lo : Integer] [hi : Integer] [n : Integer])
  #:returns Integer
  (if (< *n *lo) *lo (if (> *n *hi) *hi *n)))

(define-adt Color
  [Red]
  [Green]
  [Blue]
  [Custom [r : Integer] [g : Integer] [b : Integer]]
)

(define-adt Shape
  [Circle [radius : Integer]]
  [Rectangle [width : Integer] [height : Integer]]
  [Triangle [base : Integer] [height : Integer]]
)

(define/pow
  (describeColor [c : Color])
  #:returns String
  (let ([tesl_case_1 *c]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Red)) (raw-value "red")] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Green)) (raw-value "green")] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Blue)) (raw-value "blue")] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Custom)) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'r)]) (let ([g (hash-ref (adt-value-fields *tesl_case_1) 'g)]) (let ([b (hash-ref (adt-value-fields *tesl_case_1) 'b)]) (raw-value (format "custom(~a,~a,~a)" (tesl-display-val *r) (tesl-display-val *g) (tesl-display-val *b))))))])))

(define/pow
  (describeAll [colors : (List Color)])
  #:returns (List String)
  (raw-value (tesl_import_List_map describeColor *colors)))

(define-adt Expr
  [Lit [n : Integer]]
  [Add [left : Expr] [right : Expr]]
  [Mul [left : Expr] [right : Expr]]
  [Neg [inner : Expr]]
)

(define/pow
  (evaluate [e : Expr])
  #:returns Integer
  (let ([tesl_case_2 *e]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Lit)) (let ([n (hash-ref (adt-value-fields *tesl_case_2) 'n)]) *n)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Add)) (let ([left (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (raw-value (+ (raw-value (evaluate *left)) (raw-value (evaluate *right))))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Mul)) (let ([left (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (raw-value (* (raw-value (evaluate *left)) (raw-value (evaluate *right))))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Neg)) (let ([inner (hash-ref (adt-value-fields *tesl_case_2) 'inner)]) (raw-value (- 0 (raw-value (evaluate *inner)))))])))

(define/pow
  (describeNested [s : Shape] [label : String])
  #:returns String
  (let ([tesl_case_3 *s]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_3) 'radius)]) (raw-value (format "~a: circle with radius ~a" (tesl-display-val *label) (tesl-display-val *r))))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl_case_3) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_3) 'height)]) (raw-value (format "~a: ~ax~a rectangle" (tesl-display-val *label) (tesl-display-val *w) (tesl-display-val *h)))))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Triangle)) (let ([b (hash-ref (adt-value-fields *tesl_case_3) 'base)]) (let ([h (hash-ref (adt-value-fields *tesl_case_3) 'height)]) (raw-value (format "~a: triangle base=~a height=~a" (tesl-display-val *label) (tesl-display-val *b) (tesl-display-val *h)))))])))

(define-checker
  (checkPositive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if (> *n 0) (accept (Positive n) #:value *n) (reject "must be positive" #:http-code 400)))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (Small n)]
  (if (< *n 100) (accept (Small n) #:value *n) (reject "must be small (< 100)" #:http-code 400)))

(define/pow
  (filterAndAll [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPositive *xs))

(define/pow
  (forAllChain [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck (check-and checkPositive checkSmall) *xs))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define/pow
  (makeUserId [raw : String])
  #:returns UserId
  (raw-value (UserId *raw)))

(define/pow
  (makeProjectId [raw : String])
  #:returns ProjectId
  (raw-value (ProjectId *raw)))

(define/pow
  (requiresUserId [uid : UserId])
  #:returns String
  (string-append (raw-value uid.value) "-user"))

(define/pow
  (requiresProjectId [pid : ProjectId])
  #:returns String
  (string-append (raw-value pid.value) "-project"))

(define-checker
  (checkNonNegative [n : Integer])
  #:returns [n : Integer ::: (NonNegative n)]
  (if (>= *n 0) (accept (NonNegative n) #:value *n) (reject "must be non-negative" #:http-code 400)))

(define/pow
  (checkBoth [n : Integer])
  #:returns (? Integer _entity ::: ((NonNegative _entity) && (Small _entity)))
  ((check-and checkNonNegative checkSmall) n))

(define-checker
  (checkTrimmed [s : String])
  #:returns [s : String ::: (Trimmed s)]
  (if (and (> (raw-value (tesl_import_String_length *s)) 0) (equal? (raw-value (tesl_import_String_length (raw-value (tesl_import_String_trim *s)))) (raw-value (tesl_import_String_length *s)))) (accept (Trimmed s) #:value *s) (reject "string must be non-empty and trimmed" #:http-code 400)))

(define/pow
  (requiresTrimmed [s : String ::: (Trimmed s)])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define-checker
  (checkAge [n : Integer])
  #:returns [n : Integer ::: (ValidAge n)]
  (if (and (>= *n 0) (<= *n 150)) (accept (ValidAge n) #:value *n) (reject "invalid age" #:http-code 400)))

(define/pow
  (needsValidAge [age : Integer ::: (ValidAge age)])
  #:returns String
  (format "age is ~a" (tesl-display-val *age)))

(define/pow
  (decomposeThenPass [age : Integer])
  #:returns String
  (let/check ([tesl_checked_4 (checkAge age)]) (let ([validated tesl_checked_4]) (let ([tesl_proof_binding_5 validated]) (let ([raw (forget-proof tesl_proof_binding_5)] [proof (detach-all-proof tesl_proof_binding_5)]) (let ([reattached (attach-proof raw proof)]) (raw-value (needsValidAge reattached))))))))

(define-checker
  (checkInBounds [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InBounds lo hi n)]
  (if (and (>= *n *lo) (<= *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))

(define/pow
  (requiresInBounds [lo : Integer] [hi : Integer] [n : Integer ::: (InBounds lo hi n)])
  #:returns String
  (format "~a is in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))

(define/pow
  (isEven [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #t) (raw-value (isOdd (- *n 1)))))

(define/pow
  (isOdd [n : Integer])
  #:returns Boolean
  (if (equal? *n 0) (raw-value #f) (raw-value (isEven (- *n 1)))))

(define/pow
  (intBoundary [n : Integer])
  #:returns String
  (if (> *n 0) (raw-value "positive") (if (< *n 0) (raw-value "negative") (raw-value "zero"))))

(define/pow
  (divByTwo [n : Integer])
  #:returns Integer
  (quotient *n 2))

(define/pow
  (applyValidated [n : Integer] [f : (-> Integer Integer)])
  #:returns Integer
  (let/check ([tesl_checked_6 (checkPositive n)]) (let ([validated tesl_checked_6]) (raw-value (f validated)))))

(define/pow
  (buildMessage [name : String] [count : Integer])
  #:returns String
  (format "Hello ~a! You have ~a items." (tesl-display-val *name) (tesl-display-val *count)))

(define/pow
  (emptyInterp [s : String])
  #:returns String
  (format "~a" (tesl-display-val *s)))

(define/pow
  (nestedConcat [a : String] [b : String] [c : String])
  #:returns String
  (format "~a-~a-~a" (tesl-display-val *a) (tesl-display-val *b) (tesl-display-val *c)))

(define/pow
  (sumList [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-7 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc *x)) tesl-lambda-7) 0 *xs)))

(define/pow
  (hasNegative [xs : (List Integer)])
  #:returns Boolean
  (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-8 [x : Integer]) #:returns Boolean (< *x 0)) tesl-lambda-8) *xs)))

(define/pow
  (allPositiveCheck [xs : (List Integer)])
  #:returns Boolean
  (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-9 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-9) *xs)))

(define-capability reviewRead (implies dbRead))

(define-capability reviewWrite (implies dbWrite))

(define-capability reviewService (implies reviewRead reviewWrite))

(define/pow
  (readSomething)
  #:capabilities [reviewRead]
  #:returns String
  "read")

(define/pow
  (readAndWrite)
  #:capabilities [reviewService]
  #:returns String
  (string-append (raw-value (readSomething)) " and write"))

(define/pow
  (safeHead [xs : (List Integer)])
  #:returns (Maybe Integer)
  (raw-value (tesl_import_List_head *xs)))

(define/pow
  (withDefault [m : (Maybe Integer)] [d : Integer])
  #:returns Integer
  (let ([tesl_case_10 *m]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Nothing)) *d] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_10) 'value)]) *v)])))

(define/pow
  (chainMaybe [xs : (List Integer)])
  #:returns Integer
  (let ([h (safeHead xs)]) (raw-value (withDefault h 0))))

(define-checker
  (checkAtLeastFive [n : Integer])
  #:returns [n : Integer ::: (AtLeastFive n)]
  (if (>= *n 5) (accept (AtLeastFive n) #:value *n) (reject "must be at least 5" #:http-code 400)))

(define-checker
  (checkAtMostTen [n : Integer])
  #:returns [n : Integer ::: (AtMostTen n)]
  (if (<= *n 10) (accept (AtMostTen n) #:value *n) (reject "must be at most 10" #:http-code 400)))

(define-adt Threshold
  [Low [n : Integer]]
  [Mid [n : Integer]]
  [High [n : Integer]]
)

(define/pow
  (classifyThreshold [t : Threshold])
  #:returns String
  (let ([tesl_case_11 *t]) (cond [(and (and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Low)) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (< *n 0))) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (raw-value "low-negative"))] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Low)) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (raw-value "low-nonneg"))] [(and (and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Mid)) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (> *n 50))) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (raw-value "mid-high"))] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Mid)) (raw-value "mid-low")] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'High)) (raw-value "high")])))

(define/pow
  (countItems [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-12 [acc : Integer] [ignored : Integer]) #:returns Integer (+ *acc 1)) tesl-lambda-12) 0 *xs)))

(define/pow
  (sumSquares [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-13 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc (* *x *x))) tesl-lambda-13) 0 *xs)))

(define-checker
  (checkBounded [n : Integer])
  #:returns [n : Integer ::: (Bounded n)]
  (if (and (>= *n 1) (<= *n 999)) (accept (Bounded n) #:value *n) (reject "out of bounds [1,999]" #:http-code 400)))

(define/pow
  (requiresBounded [n : Integer ::: (Bounded n)])
  #:returns Integer
  (* *n 2))

(define/pow
  (checkPosAndSmall [n : Integer])
  #:returns (? Integer _entity ::: ((Positive _entity) && (Small _entity)))
  ((check-and checkPositive checkSmall) n))

(define/pow
  (checkPosAndSmallAndSidecar1 [n : Integer] [m : Integer])
  #:returns (? Integer _entity ::: (((Positive _entity) && (Small _entity)) && (Positive m)))
  (let ([tesl_proof_binding_14 (checkPositive m)]) (let ([_ (forget-proof tesl_proof_binding_14)] [p (detach-all-proof tesl_proof_binding_14)]) (let/check ([tesl_checked_15 ((check-and checkPositive checkSmall) n)]) (let ([_ tesl_checked_15]) (attach-proof _ p))))))

(define/pow
  (checkPosAndSmallAndSidecar2_shouldWork [n : Integer] [m : Integer])
  #:returns (? Integer _entity ::: (((Positive _entity) && (Small _entity)) && (Small m)))
  (let ([tesl_proof_binding_16 (checkSmall m)]) (let ([_ (forget-proof tesl_proof_binding_16)] [p (detach-all-proof tesl_proof_binding_16)]) (let/check ([tesl_checked_17 ((check-and checkPositive checkSmall) n)]) (let ([_ tesl_checked_17]) (attach-proof _ p))))))

(define/pow
  (foo)
  #:returns Integer
  (let ([n1 1]) (let ([n99 99]) (let ([tesl_proof_binding_18 (checkPosAndSmall n1)]) (let ([v1 (forget-proof tesl_proof_binding_18)] [v1_p1 (detach-all-proof tesl_proof_binding_18)]) (let ([tesl_proof_binding_19 (checkPosAndSmall n1)]) (let ([_ (forget-proof tesl_proof_binding_19)] [v1_p2 (detach-all-proof tesl_proof_binding_19)]) (let ([tesl_proof_binding_20 (checkPosAndSmallAndSidecar1 n99 v1)]) (let ([int1 (forget-proof tesl_proof_binding_20)] [posP (detach-all-proof tesl_proof_binding_20)]) (let ([tesl_proof_binding_21 (checkPosAndSmallAndSidecar1 n99 v1)]) (let ([_ (forget-proof tesl_proof_binding_21)] [smallP (detach-all-proof tesl_proof_binding_21)]) (let ([tesl_proof_binding_22 (checkPosAndSmallAndSidecar1 n99 v1)]) (let ([_ (forget-proof tesl_proof_binding_22)] [v1_p1_2 (detach-all-proof tesl_proof_binding_22)]) (let ([should_work (requiresPosAndSmall (attach-proof v1 (list v1_p1 v1_p1_2)))]) (let ([o (equal? (raw-value (requiresPosAndSmall (attach-proof int1 (list posP smallP)))) 99)]) 2)))))))))))))))

(define/pow
  (requiresPosAndSmall [n : Integer ::: ((Positive n) && (Small n))])
  #:returns Integer
  *n)

(define-newtype TaggedInt Integer)

(define/pow
  (makeTagged [n : Integer])
  #:returns TaggedInt
  (raw-value (TaggedInt *n)))

(define/pow
  (requiresTagged [t : TaggedInt])
  #:returns Integer
  (raw-value t.value))

(define-checker
  (checkAscii [s : String])
  #:returns [s : String ::: (AsciiOnly s)]
  (if (tesl_import_String_isEmpty *s) (reject "empty string" #:http-code 400) (accept (AsciiOnly s) #:value *s)))

(define/pow
  (requiresAscii [s : String ::: (AsciiOnly s)])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define-checker
  (checkPositiveMsg [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (checkPositive n))

(define/pow
  (wrapAndUnwrap [n : Integer])
  #:returns Integer
  (let/check ([tesl_checked_23 (checkPositive n)]) (let ([validated tesl_checked_23]) (let ([raw (forget-proof validated)]) (let ([proof (detach-proof validated)]) (let ([reattached (attach-proof raw proof)]) (let/check ([tesl_checked_24 (checkBounded reattached)]) (let ([rb tesl_checked_24]) (raw-value (requiresBounded rb))))))))))

(define/pow
  (safeRecip [x : Real])
  #:returns Real
  (let ([nz (raw-value (tesl_import_Float_requireNonZero *x))]) (raw-value (tesl_import_Float_div 1. (raw-value nz)))))

(define/pow
  (safeSqrt [x : Real])
  #:returns Real
  (raw-value (tesl_import_Float_sqrt (raw-value (tesl_import_Float_abs *x)))))

(define-checker
  (checkSlug [s : String])
  #:returns [s : String ::: (ValidSlug s)]
  (if (tesl_import_String_isEmpty *s) (reject "slug is empty" #:http-code 400) (if (> (raw-value (tesl_import_String_length *s)) 64) (reject "slug too long" #:http-code 400) (accept (ValidSlug s) #:value *s))))

(define/pow
  (requiresSlug [s : String ::: (ValidSlug s)])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define/pow
  (identityProof [n : Integer ::: (InRange n)])
  #:returns [n : Integer ::: (InRange n)]
  n)

(define-checker
  (checkNonNegStr [s : String])
  #:returns [s : String ::: (NonNegLen s)]
  (if (>= (raw-value (tesl_import_String_length *s)) 0) (accept (NonNegLen s) #:value *s) (reject "impossible negative length" #:http-code 400)))

(define/pow
  (requiresNonNegStr [s : String ::: (NonNegLen s)])
  #:returns Integer
  (raw-value (tesl_import_String_length *s)))

(define-adt Tree
  [Leaf]
  [Node [left : Tree] [value : Integer] [right : Tree]]
)

(define/pow
  (treeDepth [t : Tree])
  #:returns Integer
  (let ([tesl_case_25 *t]) (cond [(and (adt-value? *tesl_case_25) (eq? (adt-value-variant *tesl_case_25) 'Leaf)) (raw-value 0)] [(and (adt-value? *tesl_case_25) (eq? (adt-value-variant *tesl_case_25) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl_case_25) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_25) 'right)]) (let ([leftDepth (treeDepth *left)]) (let ([rightDepth (treeDepth *right)]) (if (> (raw-value leftDepth) (raw-value rightDepth)) (raw-value (+ 1 (raw-value leftDepth))) (raw-value (+ 1 (raw-value rightDepth))))))))])))

(define/pow
  (factorial [n : Integer])
  #:returns Integer
  (if (<= *n 0) (raw-value 1) (raw-value (* *n (raw-value (factorial (- *n 1)))))))

(define/pow
  (fibonacci [n : Integer])
  #:returns Integer
  (if (<= *n 0) (raw-value 0) (if (equal? *n 1) (raw-value 1) (raw-value (+ (raw-value (fibonacci (- *n 1))) (raw-value (fibonacci (- *n 2))))))))

(define/pow
  (conjunctSatisfied [n : Integer])
  #:returns String
  (let/check ([tesl_checked_26 (checkPositive n)]) (let ([pos tesl_checked_26]) (let/check ([tesl_checked_27 ((check-and checkPositive checkSmall) n)]) (let ([both tesl_checked_27]) "done")))))

(define/pow
  (sumList2 [xs : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-28 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc *x)) tesl-lambda-28) 0 *xs)))

(define/pow
  (upperLengthPreserved [s : String])
  #:returns Boolean
  (equal? (raw-value (tesl_import_String_length (raw-value (tesl_import_String_toUpper *s)))) (raw-value (tesl_import_String_length *s))))

(define/pow
  (lowerLengthPreserved [s : String])
  #:returns Boolean
  (equal? (raw-value (tesl_import_String_length (raw-value (tesl_import_String_toLower *s)))) (raw-value (tesl_import_String_length *s))))

(define/pow
  (filterPositiveTwice [xs : (List Integer)])
  #:returns (List Integer)
  (let ([once (tesl_import_List_filterCheck checkPositive *xs)]) (tesl_import_List_filterCheck checkPositive (raw-value once))))

(define/pow
  (filterPositiveOnce [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPositive *xs))

(define/pow
  (checkInBounds1020 [n : Integer])
  #:returns String
  (let ([lo 10]) (let ([hi 20]) (let/check ([tesl_checked_29 (checkInBounds lo hi n)]) (let ([v tesl_checked_29]) (raw-value (requiresInBounds lo hi v)))))))

(define/pow
  (checkInBoundsEqual [n : Integer])
  #:returns String
  (let ([lo 5]) (let ([hi 5]) (let/check ([tesl_checked_30 (checkInBounds lo hi n)]) (let ([v tesl_checked_30]) (raw-value (requiresInBounds lo hi v)))))))

(define/pow
  (checkInBoundsNeg [n : Integer])
  #:returns String
  (let ([lo -10]) (let ([hi -1]) (let/check ([tesl_checked_31 (checkInBounds lo hi n)]) (let ([v tesl_checked_31]) (raw-value (requiresInBounds lo hi v)))))))

(define/pow
  (checkInBoundsLo [n : Integer])
  #:returns String
  (let ([lo 0]) (let ([hi 100]) (let/check ([tesl_checked_32 (checkInBounds lo hi n)]) (let ([v tesl_checked_32]) (raw-value (requiresInBounds lo hi v)))))))

(define/pow
  (parseAndValidate [s : String])
  #:returns (Either String Integer)
  (let ([tesl_case_33 (raw-value (raw-value (checkNonEmpty s)))]) (cond [#t (let ([result *tesl_case_33]) (let ([n (tesl_import_String_length *result)]) (if (< (raw-value n) 10) (raw-value (raw-value (Right (raw-value n)))) (raw-value (raw-value (Left "too long"))))))])))

(define/pow
  (evalNested [e : Expr])
  #:returns Integer
  (let ([tesl_case_34 *e]) (cond [(and (adt-value? *tesl_case_34) (eq? (adt-value-variant *tesl_case_34) 'Lit)) (let ([n (hash-ref (adt-value-fields *tesl_case_34) 'n)]) *n)] [(and (adt-value? *tesl_case_34) (eq? (adt-value-variant *tesl_case_34) 'Add)) (let ([left (hash-ref (adt-value-fields *tesl_case_34) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_34) 'right)]) (raw-value (+ (raw-value (evalNested *left)) (raw-value (evalNested *right))))))] [(and (adt-value? *tesl_case_34) (eq? (adt-value-variant *tesl_case_34) 'Mul)) (let ([left (hash-ref (adt-value-fields *tesl_case_34) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_34) 'right)]) (raw-value (* (raw-value (evalNested *left)) (raw-value (evalNested *right))))))] [(and (adt-value? *tesl_case_34) (eq? (adt-value-variant *tesl_case_34) 'Neg)) (let ([inner (hash-ref (adt-value-fields *tesl_case_34) 'inner)]) (raw-value (- 0 (raw-value (evalNested *inner)))))])))

(define/pow
  (proofIndependenceCorrect [a : Integer] [b : Integer])
  #:returns Integer
  (let/check ([tesl_checked_35 (checkPositive a)]) (let ([va tesl_checked_35]) (let/check ([tesl_checked_36 (checkPositive b)]) (let ([vb tesl_checked_36]) (let/check ([tesl_checked_37 (checkBounded va)]) (let ([vab tesl_checked_37]) (let/check ([tesl_checked_38 (checkBounded vb)]) (let ([vbb tesl_checked_38]) (+ (raw-value (requiresBounded vab)) (raw-value (requiresBounded vbb))))))))))))

(define/pow
  (maxRec [a : Integer] [b : Integer])
  #:returns Integer
  (if (> *a *b) *a *b))

(define-checker
  (checkSmallBug2 [n : Integer])
  #:returns [n : Integer ::: (Small n)]
  (if (and (> *n 0) (< *n 100)) (accept (Small n) #:value *n) (reject "must be between 1 and 99" #:http-code 422)))

(define/pow
  (fnWrapsCheck [n : Integer])
  #:returns (? Integer _entity ::: (Small _entity))
  (checkSmallBug2 n))

(define-checker
  (checkPositiveBug7 [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if (> *n 0) (accept (Positive n) #:value *n) (reject "must be positive" #:http-code 422)))

(define/pow
  (filteredPositives [xs : (List Integer)])
  #:returns (List Integer)
  (tesl_import_List_filterCheck checkPositiveBug7 *xs))

(module+ test
  (require rackunit)
  (test-case "range check accepts boundary values"
  (define n0 0)
  (define tesl_checked_39 (checkRange n0))
  (when (check-fail? tesl_checked_39)
    (raise-user-error 'tesl-test "unexpected failure in let r0: ~a" (check-fail-message tesl_checked_39)))
  (define r0 tesl_checked_39)
  (define n100 100)
  (define tesl_checked_40 (checkRange n100))
  (when (check-fail? tesl_checked_40)
    (raise-user-error 'tesl-test "unexpected failure in let r100: ~a" (check-fail-message tesl_checked_40)))
  (define r100 tesl_checked_40)
  (define n50 50)
  (define tesl_checked_41 (checkRange n50))
  (when (check-fail? tesl_checked_41)
    (raise-user-error 'tesl-test "unexpected failure in let r50: ~a" (check-fail-message tesl_checked_41)))
  (define r50 tesl_checked_41)
  (check-equal? (raw-value (requiresRange r0)) 1)
  (check-equal? (raw-value (requiresRange r100)) 101)
  (check-equal? (raw-value (requiresRange r50)) 51)
  )

  (test-case "range check rejects out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkRange -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkRange -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkRange 101))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkRange 101"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkRange -100))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkRange -100"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkRange 1000))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkRange 1000"))
  )

  (test-case "proof is attached after check"
  (let ([tesl-hpv (checkRange 50)])
    (check-true
      (for/or ([f (in-list (facts-of tesl-hpv))])
        (and (pair? f) (eq? (car f) 'InRange)))
      "expected result to carry proof InRange"))
  (let ([tesl-hpv (checkRange 0)])
    (check-true
      (for/or ([f (in-list (facts-of tesl-hpv))])
        (and (pair? f) (eq? (car f) 'InRange)))
      "expected result to carry proof InRange"))
  (let ([tesl-hpv (checkRange 100)])
    (check-true
      (for/or ([f (in-list (facts-of tesl-hpv))])
        (and (pair? f) (eq? (car f) 'InRange)))
      "expected result to carry proof InRange"))
  )

  (test-case "non-empty check passes valid strings"
  (define s1 "hello")
  (define tesl_checked_42 (checkNonEmpty s1))
  (when (check-fail? tesl_checked_42)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl_checked_42)))
  (define a tesl_checked_42)
  (define s2 " ")
  (define tesl_checked_43 (checkNonEmpty s2))
  (when (check-fail? tesl_checked_43)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl_checked_43)))
  (define b tesl_checked_43)
  (define s3 "a")
  (define tesl_checked_44 (checkNonEmpty s3))
  (when (check-fail? tesl_checked_44)
    (raise-user-error 'tesl-test "unexpected failure in let c: ~a" (check-fail-message tesl_checked_44)))
  (define c tesl_checked_44)
  (check-equal? (raw-value (requiresNonEmpty a)) 5)
  (check-equal? (raw-value (requiresNonEmpty b)) 1)
  (check-equal? (raw-value (requiresNonEmpty c)) 1)
  )

  (test-case "non-empty check rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkNonEmpty ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkNonEmpty \"\""))
  )

  (test-case "email check accepts well-formed addresses"
  (define raw1 "user@example.com")
  (define tesl_checked_45 (checkEmail raw1))
  (when (check-fail? tesl_checked_45)
    (raise-user-error 'tesl-test "unexpected failure in let e1: ~a" (check-fail-message tesl_checked_45)))
  (define e1 tesl_checked_45)
  (define raw2 "a@b.c")
  (define tesl_checked_46 (checkEmail raw2))
  (when (check-fail? tesl_checked_46)
    (raise-user-error 'tesl-test "unexpected failure in let e2: ~a" (check-fail-message tesl_checked_46)))
  (define e2 tesl_checked_46)
  (check-equal? (raw-value (tesl_import_String_length e1)) 16)
  (check-equal? (raw-value (tesl_import_String_length e2)) 5)
  )

  (test-case "email check rejects malformed addresses"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkEmail ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkEmail "nodomain"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"nodomain\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkEmail "no-at-sign.com"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"no-at-sign.com\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkEmail "a@b"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"a@b\""))
  )

  (test-case "safeDiv handles zero divisor"
  (check-equal? (raw-value (safeDiv 10 0)) (raw-value (Left "division by zero")))
  (check-equal? (raw-value (safeDiv 0 0)) (raw-value (Left "division by zero")))
  (check-equal? (raw-value (safeDiv 100 5)) (raw-value (Right 20)))
  (check-equal? (raw-value (safeDiv 7 2)) (raw-value (Right 3)))
  )

  (test-case "safeDiv negative dividend"
  (check-equal? (raw-value (safeDiv -10 3)) (raw-value (Right -3)))
  (check-equal? (raw-value (safeDiv -7 2)) (raw-value (Right -3)))
  )

  (test-case "clampAndAdd boundary"
  (check-equal? (raw-value (clampAndAdd 0 10 -5 3)) 3)
  (check-equal? (raw-value (clampAndAdd 0 10 15 3)) 13)
  (check-equal? (raw-value (clampAndAdd 0 10 5 3)) 8)
  (check-equal? (raw-value (clampAndAdd 0 10 0 0)) 0)
  (check-equal? (raw-value (clampAndAdd 0 10 10 0)) 10)
  )

  (test-case "describeColor covers all constructors"
  (check-equal? (raw-value (describeColor Red)) "red")
  (check-equal? (raw-value (describeColor Green)) "green")
  (check-equal? (raw-value (describeColor Blue)) "blue")
  (check-equal? (raw-value (describeColor (Custom 255 128 0))) "custom(255,128,0)")
  )

  (test-case "describeAll handles mixed list"
  (define results (describeAll (list Red Green Blue (Custom 0 0 0))))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value results)))) 4)
  )

  (test-case "evaluate expression tree"
  (check-equal? (raw-value (evaluate (Lit 5))) 5)
  (check-equal? (raw-value (evaluate (Add (Lit 3) (Lit 4)))) 7)
  (check-equal? (raw-value (evaluate (Mul (Lit 2) (Lit 6)))) 12)
  (check-equal? (raw-value (evaluate (Neg (Lit 3)))) -3)
  (check-equal? (raw-value (evaluate (Add (Mul (Lit 2) (Lit 3)) (Neg (Lit 1))))) 5)
  (check-equal? (raw-value (evaluate (Mul (Add (Lit 1) (Lit 2)) (Add (Lit 3) (Lit 4))))) 21)
  )

  (test-case "describeNested produces correct strings"
  (check-equal? (raw-value (describeNested (Circle 5) "A")) "A: circle with radius 5")
  (check-equal? (raw-value (describeNested (Rectangle 3 4) "B")) "B: 3x4 rectangle")
  (check-equal? (raw-value (describeNested (Triangle 6 8) "C")) "C: triangle base=6 height=8")
  )

  (test-case "filterCheck produces ForAll proof"
  (define positives (filterAndAll (list 1 -2 3 -4 5)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value positives)))) 3)
  )

  (test-case "filterCheck with empty input"
  (define empty (filterAndAll (list)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value empty)))) 0)
  )

  (test-case "filterCheck with all-negative input"
  (define none (filterAndAll (list -1 -5 -100)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value none)))) 0)
  )

  (test-case "combined filterCheck both predicates"
  (define both (forAllChain (list 1 150 -5 50 200 99)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value both)))) 3)
  )

  (test-case "allCheck returns Nothing on any failure"
  (define xs (list 1 2 3 4 5))
  (define result (tesl_import_List_allCheck checkPositive (raw-value xs)))
  (check-not-equal? result Nothing)
  )

  (test-case "allCheck returns Nothing when any element fails"
  (define xs (list 1 2 -1 4 5))
  (define result (tesl_import_List_allCheck checkPositive (raw-value xs)))
  (check-equal? (raw-value result) Nothing)
  )

  (test-case "UserId and ProjectId are distinct newtypes"
  (define uid (makeUserId "user-123"))
  (define pid (makeProjectId "project-456"))
  (check-equal? (raw-value (requiresUserId uid)) "user-123-user")
  (check-equal? (raw-value (requiresProjectId pid)) "project-456-project")
  )

  (test-case "newtypes round-trip through .value"
  (define uid (makeUserId "abc"))
  (check-equal? (raw-value (tesl-dot/runtime uid 'value)) "abc")
  )

  (test-case "combined check passes when both pass"
  (define n 50)
  (define v (checkBoth n))
  (check-equal? (raw-value v) 50)
  )

  (test-case "combined check fails when first fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkBoth -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkBoth -1"))
  )

  (test-case "combined check fails when second fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkBoth 200))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkBoth 200"))
  )

  (test-case "combined check at boundary: 0 and 99"
  (define n0 0)
  (define zero (checkBoth n0))
  (define n99 99)
  (define limit (checkBoth n99))
  (check-equal? (raw-value zero) 0)
  (check-equal? (raw-value limit) 99)
  )

  (test-case "trimmed check accepts trimmed strings"
  (define s1 "hello")
  (define tesl_checked_47 (checkTrimmed s1))
  (when (check-fail? tesl_checked_47)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl_checked_47)))
  (define a tesl_checked_47)
  (define s2 "no spaces here")
  (define tesl_checked_48 (checkTrimmed s2))
  (when (check-fail? tesl_checked_48)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl_checked_48)))
  (define b tesl_checked_48)
  (check-equal? (raw-value (requiresTrimmed a)) 5)
  (check-equal? (raw-value (requiresTrimmed b)) 14)
  )

  (test-case "trimmed check rejects leading whitespace"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTrimmed " hello"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \" hello\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTrimmed "  leading"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \"  leading\""))
  )

  (test-case "trimmed check rejects trailing whitespace"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTrimmed "trailing "))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \"trailing \""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTrimmed "both ends "))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \"both ends \""))
  )

  (test-case "trimmed check rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTrimmed ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \"\""))
  )

  (test-case "proof decomposition and reattachment"
  (check-equal? (raw-value (decomposeThenPass 25)) "age is 25")
  (check-equal? (raw-value (decomposeThenPass 0)) "age is 0")
  (check-equal? (raw-value (decomposeThenPass 150)) "age is 150")
  )

  (test-case "decompose fails for out-of-range ages"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (decomposeThenPass -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decomposeThenPass -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (decomposeThenPass 151))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decomposeThenPass 151"))
  )

  (test-case "multi-param fact: in bounds"
  (define lo 1)
  (define hi 10)
  (define n 5)
  (define tesl_checked_49 (checkInBounds lo hi n))
  (when (check-fail? tesl_checked_49)
    (raise-user-error 'tesl-test "unexpected failure in let x: ~a" (check-fail-message tesl_checked_49)))
  (define x tesl_checked_49)
  (check-equal? (raw-value x) 5)
  )

  (test-case "multi-param fact: boundary values"
  (define lo 0)
  (define hi 100)
  (define v0 0)
  (define v100 100)
  (define tesl_checked_50 (checkInBounds lo hi v0))
  (when (check-fail? tesl_checked_50)
    (raise-user-error 'tesl-test "unexpected failure in let atLo: ~a" (check-fail-message tesl_checked_50)))
  (define atLo tesl_checked_50)
  (define tesl_checked_51 (checkInBounds lo hi v100))
  (when (check-fail? tesl_checked_51)
    (raise-user-error 'tesl-test "unexpected failure in let atHi: ~a" (check-fail-message tesl_checked_51)))
  (define atHi tesl_checked_51)
  (check-equal? (raw-value atLo) 0)
  (check-equal? (raw-value atHi) 100)
  )

  (test-case "multi-param fact: rejects out-of-bounds"
  (define lo 1)
  (define hi 10)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkInBounds lo hi -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds lo hi -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkInBounds lo hi 11))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds lo hi 11"))
  )

  (test-case "isEven base cases"
  (check-equal? (raw-value (isEven 0)) #t)
  (check-equal? (raw-value (isOdd 0)) #f)
  )

  (test-case "isEven/isOdd small values"
  (check-equal? (raw-value (isEven 2)) #t)
  (check-equal? (raw-value (isEven 3)) #f)
  (check-equal? (raw-value (isOdd 1)) #t)
  (check-equal? (raw-value (isOdd 4)) #f)
  )

  (test-case "isEven/isOdd larger values"
  (check-equal? (raw-value (isEven 10)) #t)
  (check-equal? (raw-value (isOdd 11)) #t)
  (check-equal? (raw-value (isEven 7)) #f)
  (check-equal? (raw-value (isOdd 8)) #f)
  )

  (test-case "intBoundary"
  (check-equal? (raw-value (intBoundary 1)) "positive")
  (check-equal? (raw-value (intBoundary -1)) "negative")
  (check-equal? (raw-value (intBoundary 0)) "zero")
  (check-equal? (raw-value (intBoundary 1000000)) "positive")
  (check-equal? (raw-value (intBoundary -1000000)) "negative")
  )

  (test-case "integer division truncates towards zero"
  (check-equal? (raw-value (divByTwo 4)) 2)
  (check-equal? (raw-value (divByTwo 5)) 2)
  (check-equal? (raw-value (divByTwo -5)) -2)
  (check-equal? (raw-value (divByTwo 0)) 0)
  (check-equal? (raw-value (divByTwo 1)) 0)
  (check-equal? (raw-value (divByTwo -1)) 0)
  )

  (test-case "lambda applied to validated value"
  (check-equal? (raw-value (applyValidated 5 (let () (define/pow (tesl-lambda-52 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-52))) 10)
  (check-equal? (raw-value (applyValidated 3 (let () (define/pow (tesl-lambda-53 [x : Integer]) #:returns Integer (+ *x 10)) tesl-lambda-53))) 13)
  )

  (test-case "lambda fails if n is not positive"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (applyValidated -1 (let () (define/pow (tesl-lambda-54 [x : Integer]) #:returns Integer x) tesl-lambda-54)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: applyValidated -1 (let () (define/pow (tesl-lambda-55 [x : Integer]) #:returns Integer x) tesl-lambda-55)"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (applyValidated 0 (let () (define/pow (tesl-lambda-55 [x : Integer]) #:returns Integer x) tesl-lambda-55)))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: applyValidated 0 (let () (define/pow (tesl-lambda-56 [x : Integer]) #:returns Integer x) tesl-lambda-56)"))
  )

  (test-case "string interpolation"
  (check-equal? (raw-value (buildMessage "Alice" 3)) "Hello Alice! You have 3 items.")
  (check-equal? (raw-value (buildMessage "Bob" 0)) "Hello Bob! You have 0 items.")
  )

  (test-case "single-value interpolation"
  (check-equal? (raw-value (emptyInterp "test")) "test")
  (check-equal? (raw-value (emptyInterp "")) "")
  )

  (test-case "multi-value interpolation"
  (check-equal? (raw-value (nestedConcat "a" "b" "c")) "a-b-c")
  (check-equal? (raw-value (nestedConcat "" "" "")) "--")
  )

  (test-case "sumList"
  (check-equal? (raw-value (sumList (list))) 0)
  (check-equal? (raw-value (sumList (list 1 2 3))) 6)
  (check-equal? (raw-value (sumList (list -1 0 1))) 0)
  (check-equal? (raw-value (sumList (list 100))) 100)
  )

  (test-case "hasNegative"
  (check-equal? (raw-value (hasNegative (list -1 2 3))) #t)
  (check-equal? (raw-value (hasNegative (list 1 2 3))) #f)
  (check-equal? (raw-value (hasNegative (list))) #f)
  )

  (test-case "allPositiveCheck"
  (check-equal? (raw-value (allPositiveCheck (list 1 2 3))) #t)
  (check-equal? (raw-value (allPositiveCheck (list 0 1 2))) #f)
  (check-equal? (raw-value (allPositiveCheck (list))) #t)
  (check-equal? (raw-value (allPositiveCheck (list -1 2 3))) #f)
  )

  (test-case "capability-required functions exist"
    (with-capabilities (reviewService)
    (check-equal? (raw-value (readSomething)) "read")
    (check-equal? (raw-value (readAndWrite)) "read and write")
    )
  )

  (test-case "safeHead on empty list"
  (check-equal? (raw-value (safeHead (list))) Nothing)
  )

  (test-case "safeHead on non-empty list"
  (check-equal? (raw-value (safeHead (list 42))) (raw-value (Something 42)))
  (check-equal? (raw-value (safeHead (list 1 2 3))) (raw-value (Something 1)))
  )

  (test-case "withDefault"
  (check-equal? (raw-value (withDefault Nothing 99)) 99)
  (check-equal? (raw-value (withDefault (raw-value (Something 5)) 99)) 5)
  (check-equal? (raw-value (withDefault (raw-value (Something 0)) 99)) 0)
  )

  (test-case "chainMaybe"
  (check-equal? (raw-value (chainMaybe (list 10 20))) 10)
  (check-equal? (raw-value (chainMaybe (list))) 0)
  )

  (test-case "checkAtLeastFive: precise boundary"
  (define n5 5)
  (define tesl_checked_56 (checkAtLeastFive n5))
  (when (check-fail? tesl_checked_56)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_56)))
  (define v tesl_checked_56)
  (check-equal? (raw-value v) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkAtLeastFive 4))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAtLeastFive 4"))
  )

  (test-case "checkAtLeastFive: values above boundary"
  (define n6 6)
  (define tesl_checked_57 (checkAtLeastFive n6))
  (when (check-fail? tesl_checked_57)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_57)))
  (define v tesl_checked_57)
  (check-equal? (raw-value v) 6)
  (define n1000 1000)
  (define tesl_checked_58 (checkAtLeastFive n1000))
  (when (check-fail? tesl_checked_58)
    (raise-user-error 'tesl-test "unexpected failure in let w: ~a" (check-fail-message tesl_checked_58)))
  (define w tesl_checked_58)
  (check-equal? (raw-value w) 1000)
  )

  (test-case "checkAtMostTen: precise boundary"
  (define n10 10)
  (define tesl_checked_59 (checkAtMostTen n10))
  (when (check-fail? tesl_checked_59)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_59)))
  (define v tesl_checked_59)
  (check-equal? (raw-value v) 10)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkAtMostTen 11))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAtMostTen 11"))
  )

  (test-case "checkAtMostTen: values below boundary"
  (define n9 9)
  (define tesl_checked_60 (checkAtMostTen n9))
  (when (check-fail? tesl_checked_60)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_60)))
  (define v tesl_checked_60)
  (check-equal? (raw-value v) 9)
  (define nNeg -100)
  (define tesl_checked_61 (checkAtMostTen nNeg))
  (when (check-fail? tesl_checked_61)
    (raise-user-error 'tesl-test "unexpected failure in let w: ~a" (check-fail-message tesl_checked_61)))
  (define w tesl_checked_61)
  (check-equal? (raw-value w) -100)
  )

  (test-case "range proof: filterCheck never exceeds bounds"
  ; property: every filtered element is in 0..100
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (<= (raw-value n) 100)) (check-true (let/check ([tesl_checked_62 (checkRange n)]) (let ([validated tesl_checked_62]) (and (>= (raw-value (requiresRange validated)) 1) (<= (raw-value (requiresRange validated)) 101)))) "every filtered element is in 0..100"))
    ))
  )

  (test-case "at-least-five proof invariant"
  ; property: checkAtLeastFive succeeds for >= 5
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 5) (< (raw-value n) 1000)) (check-true (let/check ([tesl_checked_63 (checkAtLeastFive n)]) (let ([v tesl_checked_63]) (>= (raw-value v) 5))) "checkAtLeastFive succeeds for >= 5"))
    ))
  )

  (test-case "non-empty length invariant"
  ; property: checkNonEmpty preserves length
  (for ([tesl-prop-i (in-range 100)])
    (let ([s (format "s~a" (random 1000000))])
      (when (> (raw-value (tesl_import_String_length (raw-value s))) 0) (check-true (let/check ([tesl_checked_64 (checkNonEmpty s)]) (let ([v tesl_checked_64]) (equal? (raw-value (requiresNonEmpty v)) (raw-value (tesl_import_String_length (raw-value s)))))) "checkNonEmpty preserves length"))
    ))
  )

  (test-case "case guard routing"
  (check-equal? (raw-value (classifyThreshold (Low -5))) "low-negative")
  (check-equal? (raw-value (classifyThreshold (Low 0))) "low-nonneg")
  (check-equal? (raw-value (classifyThreshold (Low 10))) "low-nonneg")
  (check-equal? (raw-value (classifyThreshold (Mid 51))) "mid-high")
  (check-equal? (raw-value (classifyThreshold (Mid 50))) "mid-low")
  (check-equal? (raw-value (classifyThreshold (Mid 0))) "mid-low")
  (check-equal? (raw-value (classifyThreshold (High 999))) "high")
  )

  (test-case "countItems via foldl"
  (check-equal? (raw-value (countItems (list))) 0)
  (check-equal? (raw-value (countItems (list 1))) 1)
  (check-equal? (raw-value (countItems (list 1 2 3 4 5))) 5)
  )

  (test-case "sumSquares via foldl"
  (check-equal? (raw-value (sumSquares (list))) 0)
  (check-equal? (raw-value (sumSquares (list 1 2 3))) 14)
  (check-equal? (raw-value (sumSquares (list 0 0 0))) 0)
  (check-equal? (raw-value (sumSquares (list 3 4))) 25)
  )

  (test-case "bounded: boundary values accepted"
  (define n1 1)
  (define tesl_checked_65 (checkBounded n1))
  (when (check-fail? tesl_checked_65)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_65)))
  (define v1 tesl_checked_65)
  (check-equal? (raw-value (requiresBounded v1)) 2)
  (define n999 999)
  (define tesl_checked_66 (checkBounded n999))
  (when (check-fail? tesl_checked_66)
    (raise-user-error 'tesl-test "unexpected failure in let v999: ~a" (check-fail-message tesl_checked_66)))
  (define v999 tesl_checked_66)
  (check-equal? (raw-value (requiresBounded v999)) 1998)
  )

  (test-case "bounded: out-of-range rejected"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkBounded 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBounded 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkBounded 1000))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBounded 1000"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkBounded -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBounded -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkBounded 9999))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBounded 9999"))
  )

  (test-case "bounded: midpoint accepted"
  (define n500 500)
  (define tesl_checked_67 (checkBounded n500))
  (when (check-fail? tesl_checked_67)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_67)))
  (define v tesl_checked_67)
  (check-equal? (raw-value (requiresBounded v)) 1000)
  )

  (test-case "pos+small: only values in (0,100) pass"
  (define n1 1)
  (define v1 (checkPosAndSmall n1))
  (check-equal? (raw-value (requiresPosAndSmall v1)) 1)
  (define n99 99)
  (define v99 (checkPosAndSmall n99))
  (check-equal? (raw-value (requiresPosAndSmall v99)) 99)
  (define tesl_proof_bind_68 (checkPosAndSmallAndSidecar1 n99 n1))
  (when (check-fail? tesl_proof_bind_68)
    (raise-user-error 'tesl-test "unexpected failure in let-proof: ~a" (check-fail-message tesl_proof_bind_68)))
  (define tesl_ignored_69 (forget-proof tesl_proof_bind_68))
  (define n1_p1 (detach-all-proof tesl_proof_bind_68))
  (define tesl_proof_bind_70 (checkPosAndSmallAndSidecar2_shouldWork n99 n1))
  (when (check-fail? tesl_proof_bind_70)
    (raise-user-error 'tesl-test "unexpected failure in let-proof: ~a" (check-fail-message tesl_proof_bind_70)))
  (define tesl_ignored_71 (forget-proof tesl_proof_bind_70))
  (define n1_p2 (detach-all-proof tesl_proof_bind_70))
  (check-equal? (raw-value (requiresPosAndSmall (attach-proof n1 (list n1_p1 n1_p2)))) 1)
  (define tesl_proof_bind_72 (checkPosAndSmallAndSidecar1 n99 n1))
  (when (check-fail? tesl_proof_bind_72)
    (raise-user-error 'tesl-test "unexpected failure in let-proof: ~a" (check-fail-message tesl_proof_bind_72)))
  (define int1 (forget-proof tesl_proof_bind_72))
  (define posP (detach-all-proof tesl_proof_bind_72))
  (define smallP (detach-all-proof tesl_proof_bind_72))
  (check-equal? (raw-value (requiresPosAndSmall (attach-proof int1 (list posP smallP)))) 99)
  )

  (test-case "pos+small: zero fails (not positive)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPosAndSmall 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall 0"))
  )

  (test-case "pos+small: 100 fails (not small)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPosAndSmall 100))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall 100"))
  )

  (test-case "pos+small: negative fails (not positive)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPosAndSmall -5))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall -5"))
  )

  (test-case "TaggedInt round-trips"
  (define t (makeTagged 42))
  (check-equal? (raw-value (requiresTagged t)) 42)
  (define t2 (makeTagged 0))
  (check-equal? (raw-value (requiresTagged t2)) 0)
  (define t3 (makeTagged -7))
  (check-equal? (raw-value (requiresTagged t3)) -7)
  )

  (test-case "TaggedInt from large value"
  (define t (makeTagged 2147483647))
  (check-equal? (raw-value (requiresTagged t)) 2147483647)
  )

  (test-case "ascii check accepts non-empty strings"
  (define s1 "hello")
  (define tesl_checked_73 (checkAscii s1))
  (when (check-fail? tesl_checked_73)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_73)))
  (define v1 tesl_checked_73)
  (check-equal? (raw-value (requiresAscii v1)) 5)
  (define s2 "a")
  (define tesl_checked_74 (checkAscii s2))
  (when (check-fail? tesl_checked_74)
    (raise-user-error 'tesl-test "unexpected failure in let v2: ~a" (check-fail-message tesl_checked_74)))
  (define v2 tesl_checked_74)
  (check-equal? (raw-value (requiresAscii v2)) 1)
  )

  (test-case "ascii check rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkAscii ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAscii \"\""))
  )

  (test-case "proof survives fn wrapper"
  (define n5 5)
  (define tesl_checked_75 (checkPositiveMsg n5))
  (when (check-fail? tesl_checked_75)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_75)))
  (define v tesl_checked_75)
  (define tesl_checked_76 (checkBounded v))
  (when (check-fail? tesl_checked_76)
    (raise-user-error 'tesl-test "unexpected failure in let vb: ~a" (check-fail-message tesl_checked_76)))
  (define vb tesl_checked_76)
  (define w (requiresBounded vb))
  (check-equal? (raw-value w) 10)
  )

  (test-case "fn wrapper rejects bad input"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPositiveMsg 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositiveMsg 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPositiveMsg -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositiveMsg -1"))
  )

  (test-case "detach-reattach round-trip"
  (check-equal? (raw-value (wrapAndUnwrap 5)) 10)
  (check-equal? (raw-value (wrapAndUnwrap 1)) 2)
  (check-equal? (raw-value (wrapAndUnwrap 99)) 198)
  )

  (test-case "detach-reattach fails on non-positive input"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (wrapAndUnwrap 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapAndUnwrap 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (wrapAndUnwrap -10))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapAndUnwrap -10"))
  )

  (test-case "safe reciprocal of 2.0"
  (check-equal? (raw-value (safeRecip 2.)) 0.5)
  )

  (test-case "safe reciprocal of -4.0"
  (check-equal? (raw-value (safeRecip -4.)) (- 0.25))
  )

  (test-case "safe reciprocal rejects 0.0"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (safeRecip 0.))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: safeRecip 0."))
  )

  (test-case "safeSqrt of 0.0"
  (check-equal? (raw-value (safeSqrt 0.)) 0.)
  )

  (test-case "safeSqrt of negative (uses abs)"
  (check-equal? (raw-value (safeSqrt -9.)) 3.)
  )

  (test-case "slug: accepts short non-empty string"
  (define s1 "my-slug")
  (define tesl_checked_77 (checkSlug s1))
  (when (check-fail? tesl_checked_77)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_77)))
  (define v1 tesl_checked_77)
  (check-equal? (raw-value (requiresSlug v1)) 7)
  (define s2 "a")
  (define tesl_checked_78 (checkSlug s2))
  (when (check-fail? tesl_checked_78)
    (raise-user-error 'tesl-test "unexpected failure in let v2: ~a" (check-fail-message tesl_checked_78)))
  (define v2 tesl_checked_78)
  (check-equal? (raw-value (requiresSlug v2)) 1)
  )

  (test-case "slug: rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkSlug ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSlug \"\""))
  )

  (test-case "slug: accepts exactly 64 chars"
  (define s64 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  (define tesl_checked_79 (checkSlug s64))
  (when (check-fail? tesl_checked_79)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_79)))
  (define v tesl_checked_79)
  (check-equal? (raw-value (requiresSlug v)) 64)
  )

  (test-case "slug: rejects 65 chars"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkSlug "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSlug \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""))
  )

  (test-case "identityProof preserves InRange"
  (define n50 50)
  (define tesl_checked_80 (checkRange n50))
  (when (check-fail? tesl_checked_80)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_80)))
  (define v tesl_checked_80)
  (define out (identityProof v))
  (check-equal? (raw-value (requiresRange out)) 51)
  )

  (test-case "nonNegStr: all strings have non-negative length"
  (define s1 "")
  (define tesl_checked_81 (checkNonNegStr s1))
  (when (check-fail? tesl_checked_81)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_81)))
  (define v1 tesl_checked_81)
  (check-equal? (raw-value (requiresNonNegStr v1)) 0)
  (define s2 "hello world")
  (define tesl_checked_82 (checkNonNegStr s2))
  (when (check-fail? tesl_checked_82)
    (raise-user-error 'tesl-test "unexpected failure in let v2: ~a" (check-fail-message tesl_checked_82)))
  (define v2 tesl_checked_82)
  (check-equal? (raw-value (requiresNonNegStr v2)) 11)
  )

  (test-case "tree depth: leaf"
  (check-equal? (raw-value (treeDepth Leaf)) 0)
  )

  (test-case "tree depth: single node"
  (define t (raw-value (Node Leaf 42 Leaf)))
  (check-equal? (raw-value (treeDepth t)) 1)
  )

  (test-case "tree depth: balanced depth-2 tree"
  (define t (raw-value (Node (Node Leaf 1 Leaf) 2 (Node Leaf 3 Leaf))))
  (check-equal? (raw-value (treeDepth t)) 2)
  )

  (test-case "tree depth: right-skewed depth-3"
  (define t (raw-value (Node Leaf 1 (Node Leaf 2 (Node Leaf 3 Leaf)))))
  (check-equal? (raw-value (treeDepth t)) 3)
  )

  (test-case "tree depth: left-heavy"
  (define t (raw-value (Node (Node (Node Leaf 1 Leaf) 2 Leaf) 3 Leaf)))
  (check-equal? (raw-value (treeDepth t)) 3)
  )

  (test-case "factorial base cases"
  (check-equal? (raw-value (factorial 0)) 1)
  (check-equal? (raw-value (factorial 1)) 1)
  (check-equal? (raw-value (factorial -5)) 1)
  )

  (test-case "factorial small values"
  (check-equal? (raw-value (factorial 2)) 2)
  (check-equal? (raw-value (factorial 3)) 6)
  (check-equal? (raw-value (factorial 4)) 24)
  (check-equal? (raw-value (factorial 5)) 120)
  )

  (test-case "fibonacci base cases"
  (check-equal? (raw-value (fibonacci 0)) 0)
  (check-equal? (raw-value (fibonacci 1)) 1)
  )

  (test-case "fibonacci small values"
  (check-equal? (raw-value (fibonacci 2)) 1)
  (check-equal? (raw-value (fibonacci 3)) 2)
  (check-equal? (raw-value (fibonacci 4)) 3)
  (check-equal? (raw-value (fibonacci 5)) 5)
  (check-equal? (raw-value (fibonacci 6)) 8)
  (check-equal? (raw-value (fibonacci 10)) 55)
  )

  (test-case "conjunct both pass: 1"
  (check-equal? (raw-value (conjunctSatisfied 1)) "done")
  )

  (test-case "conjunct both pass: 50"
  (check-equal? (raw-value (conjunctSatisfied 50)) "done")
  )

  (test-case "conjunct fails: 0 (not positive)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (conjunctSatisfied 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: conjunctSatisfied 0"))
  )

  (test-case "conjunct fails: 100 (not small)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (conjunctSatisfied 100))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: conjunctSatisfied 100"))
  )

  (test-case "foldl sum is commutative for pairs"
  (define xs1 (list 1 2 3 4 5))
  (define xs2 (list 5 4 3 2 1))
  (check-equal? (raw-value (sumList2 xs1)) (sumList2 xs2))
  )

  (test-case "foldl sum of singleton is identity"
  (check-equal? (raw-value (sumList2 (list 42))) 42)
  (check-equal? (raw-value (sumList2 (list -7))) -7)
  )

  (test-case "foldl sum with 50 random"
  ; property: sum ≥ min
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 1) (<= (raw-value n) 1000)) (check-true (>= (raw-value (sumList2 (list n))) 1) "sum \226\137\165 min"))
    ))
  )

  (test-case "toUpper preserves length on ASCII"
  (check-equal? (raw-value (upperLengthPreserved "hello")) #t)
  (check-equal? (raw-value (upperLengthPreserved "")) #t)
  (check-equal? (raw-value (upperLengthPreserved "HELLO WORLD")) #t)
  )

  (test-case "toLower preserves length on ASCII"
  (check-equal? (raw-value (lowerLengthPreserved "HELLO")) #t)
  (check-equal? (raw-value (lowerLengthPreserved "mixed Case String")) #t)
  (check-equal? (raw-value (lowerLengthPreserved "")) #t)
  )

  (test-case "filter idempotence: empty list"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (filterPositiveTwice (list)))))) 0)
  )

  (test-case "filter idempotence: all positive"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (filterPositiveTwice (list 1 2 3)))))) (raw-value (tesl_import_List_length (raw-value (filterPositiveOnce (list 1 2 3))))))
  )

  (test-case "filter idempotence: mixed"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (filterPositiveTwice (list 1 -2 3 -4 5)))))) (raw-value (tesl_import_List_length (raw-value (filterPositiveOnce (list 1 -2 3 -4 5))))))
  )

  (test-case "inBounds: all values between lo and hi pass"
  (check-equal? (raw-value (checkInBounds1020 15)) "15 is in [10, 20]")
  )

  (test-case "inBounds: lo == hi is a valid range"
  (check-equal? (raw-value (checkInBoundsEqual 5)) "5 is in [5, 5]")
  )

  (test-case "inBounds: negative range works"
  (check-equal? (raw-value (checkInBoundsNeg -5)) "-5 is in [-10, -1]")
  )

  (test-case "inBounds: value at lo boundary"
  (check-equal? (raw-value (checkInBoundsLo 0)) "0 is in [0, 100]")
  )

  (test-case "inBounds: value just below lo fails"
  (define lo 5)
  (define hi 15)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkInBounds lo hi 4))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds lo hi 4"))
  )

  (test-case "parseAndValidate: short non-empty string"
  (check-equal? (raw-value (parseAndValidate "hi")) (raw-value (Right 2)))
  )

  (test-case "parseAndValidate: exactly 9 chars"
  (check-equal? (raw-value (parseAndValidate "123456789")) (raw-value (Right 9)))
  )

  (test-case "parseAndValidate: 10 chars rejected as too long"
  (check-equal? (raw-value (parseAndValidate "1234567890")) (raw-value (Left "too long")))
  )

  (test-case "parseAndValidate: empty string fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (parseAndValidate ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: parseAndValidate \"\""))
  )

  (test-case "eval: neg of neg"
  (define e (raw-value (Neg (Neg (Lit 5)))))
  (check-equal? (raw-value (evalNested e)) 5)
  )

  (test-case "eval: (2 + 3) * (4 + 1)"
  (define e (raw-value (Mul (Add (Lit 2) (Lit 3)) (Add (Lit 4) (Lit 1)))))
  (check-equal? (raw-value (evalNested e)) 25)
  )

  (test-case "eval: deeply nested add"
  (define e (raw-value (Add (Add (Add (Lit 1) (Lit 2)) (Lit 3)) (Lit 4))))
  (check-equal? (raw-value (evalNested e)) 10)
  )

  (test-case "eval: multiply by zero"
  (define e (raw-value (Mul (Lit 0) (Add (Lit 100) (Lit 200)))))
  (check-equal? (raw-value (evalNested e)) 0)
  )

  (test-case "proof independence: both positive, both in bounds"
  (check-equal? (raw-value (proofIndependenceCorrect 5 10)) 30)
  )

  (test-case "proof independence: first fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (proofIndependenceCorrect 0 5))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofIndependenceCorrect 0 5"))
  )

  (test-case "proof independence: second fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (proofIndependenceCorrect 5 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofIndependenceCorrect 5 0"))
  )

  (test-case "proof independence: first out of bounds"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (proofIndependenceCorrect 1000 5))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofIndependenceCorrect 1000 5"))
  )

  (test-case "proof independence: both out of bounds"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (proofIndependenceCorrect 1000 2000))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofIndependenceCorrect 1000 2000"))
  )

  (test-case "Bug1: maxRec returns larger of two, first larger"
  (check-equal? (raw-value (maxRec 5 3)) 5)
  )

  (test-case "Bug1: maxRec returns larger of two, second larger"
  (check-equal? (raw-value (maxRec 2 9)) 9)
  )

  (test-case "Bug1: maxRec with equal values"
  (check-equal? (raw-value (maxRec 7 7)) 7)
  )

  (test-case "Bug1: maxRec with negative numbers"
  (define a -3)
  (define b -1)
  (check-equal? (raw-value (maxRec a b)) b)
  )

  (test-case "Bug2: fn wrapping check passes for valid value"
  (define n 42)
  (define v (fnWrapsCheck n))
  (check-equal? (raw-value #t) #t)
  )

  (test-case "Bug2: fn wrapping check fails for invalid value"
  (define n 0)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (fnWrapsCheck n))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: fnWrapsCheck n"))
  )

  (test-case "Bug2: fn wrapping check fails for out-of-range value"
  (define n 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (fnWrapsCheck n))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: fnWrapsCheck n"))
  )

  (test-case "Bug7: filterCheck result satisfies ForAll Positive"
  (define result (filteredPositives (list 1 2 3 -1 -2)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "Bug7: filterCheck all positive"
  (define result (filteredPositives (list 10 20 30)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 3)
  )

  (test-case "Bug7: filterCheck all negative gives empty list"
  (define result (filteredPositives (list -1 -2 -3)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value result)))) 0)
  )

)
