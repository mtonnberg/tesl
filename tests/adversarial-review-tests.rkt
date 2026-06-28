#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/dsl/debug/checkpoint
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
  (thsl-src! "tests/adversarial-review-tests.tesl" 113 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 100)) (accept (InRange n) #:value *n) (reject "must be 0\u2013100" #:http-code 400)))))

(define/pow
  (requiresRange [n : Integer ::: (InRange n)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 119 (list (cons 'n *n)) (lambda () (+ *n 1))))

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (NonEmpty s)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 159 (list (cons 's *s)) (lambda () (if (tesl_import_String_isEmpty *s) (reject "must not be empty" #:http-code 400) (accept (NonEmpty s) #:value *s)))))

(define/pow
  (requiresNonEmpty [s : String ::: (NonEmpty s)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 165 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define-checker
  (checkEmail [email : String])
  #:returns [email : String ::: (ValidEmail email)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 190 (list (cons 'email *email)) (lambda () (if (and (raw-value (tesl_import_String_contains *email "@")) (raw-value (tesl_import_String_contains *email ".")) (>= (raw-value (tesl_import_String_length *email)) 5)) (accept (ValidEmail email) #:value *email) (reject "invalid email address" #:http-code 400)))))

(define/pow
  (safeDiv [a : Integer] [b : Integer])
  #:returns (Either String Integer)
  (thsl-src! "tests/adversarial-review-tests.tesl" 220 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (equal? *b 0) (raw-value (raw-value (Left "division by zero"))) (let/check ([tesl_checked_0 (tesl_import_Int_nonZero b)]) (let ([checkedB tesl_checked_0]) (raw-value (raw-value (Right (tesl_import_Int_divide *a checkedB))))))))))

(define/pow
  (clampAndAdd [lo : Integer] [hi : Integer] [n : Integer] [delta : Integer])
  #:returns Integer
  (let ([clamped (thsl-src! "tests/adversarial-review-tests.tesl" 227 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n) (cons 'delta *delta)) (lambda () (clamp lo hi n)))]) (thsl-src! "tests/adversarial-review-tests.tesl" 228 (list (cons 'clamped *clamped) (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n) (cons 'delta *delta)) (lambda () (+ (raw-value clamped) *delta)))))

(define/pow
  (clamp [lo : Integer] [hi : Integer] [n : Integer])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 231 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (< *n *lo) *lo (if (> *n *hi) *hi *n)))))

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
  (thsl-src-control! "tests/adversarial-review-tests.tesl" 275 (list (cons 'c *c)) (lambda () (let ([tesl_case_1 *c]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Red)) (thsl-src! "tests/adversarial-review-tests.tesl" 276 (list) (lambda () (raw-value "red")))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Green)) (thsl-src! "tests/adversarial-review-tests.tesl" 277 (list) (lambda () (raw-value "green")))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Blue)) (thsl-src! "tests/adversarial-review-tests.tesl" 278 (list) (lambda () (raw-value "blue")))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Custom)) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'r)]) (let ([g (hash-ref (adt-value-fields *tesl_case_1) 'g)]) (let ([b (hash-ref (adt-value-fields *tesl_case_1) 'b)]) (thsl-src! "tests/adversarial-review-tests.tesl" 279 (list (cons 'r r) (cons 'g g) (cons 'b b)) (lambda () (raw-value (format "custom(~a,~a,~a)" (tesl-display-val *r) (tesl-display-val *g) (tesl-display-val *b))))))))])))))

(define/pow
  (describeAll [colors : (List Color)])
  #:returns (List String)
  (thsl-src! "tests/adversarial-review-tests.tesl" 282 (list (cons 'colors *colors)) (lambda () (raw-value (tesl_import_List_map describeColor *colors)))))

(define-adt Expr
  [Lit [n : Integer]]
  [Add [left : Expr] [right : Expr]]
  [Mul [left : Expr] [right : Expr]]
  [Neg [inner : Expr]]
)

(define/pow
  (evaluate [e : Expr])
  #:returns Integer
  (thsl-src-control! "tests/adversarial-review-tests.tesl" 304 (list (cons 'e *e)) (lambda () (let ([tesl_case_2 *e]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Lit)) (let ([n (hash-ref (adt-value-fields *tesl_case_2) 'n)]) (thsl-src! "tests/adversarial-review-tests.tesl" 305 (list (cons 'n n)) (lambda () *n)))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Add)) (let ([left (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (thsl-src! "tests/adversarial-review-tests.tesl" 306 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (+ (raw-value (evaluate *left)) (raw-value (evaluate *right))))))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Mul)) (let ([left (hash-ref (adt-value-fields *tesl_case_2) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_2) 'right)]) (thsl-src! "tests/adversarial-review-tests.tesl" 307 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (* (raw-value (evaluate *left)) (raw-value (evaluate *right))))))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Neg)) (let ([inner (hash-ref (adt-value-fields *tesl_case_2) 'inner)]) (thsl-src! "tests/adversarial-review-tests.tesl" 308 (list (cons 'inner inner)) (lambda () (raw-value (- 0 (raw-value (evaluate *inner)))))))])))))

(define/pow
  (describeNested [s : Shape] [label : String])
  #:returns String
  (thsl-src-control! "tests/adversarial-review-tests.tesl" 320 (list (cons 's *s) (cons 'label *label)) (lambda () (let ([tesl_case_3 *s]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_3) 'radius)]) (thsl-src! "tests/adversarial-review-tests.tesl" 321 (list (cons 'r r)) (lambda () (raw-value (format "~a: circle with radius ~a" (tesl-display-val *label) (tesl-display-val *r))))))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl_case_3) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_3) 'height)]) (thsl-src! "tests/adversarial-review-tests.tesl" 322 (list (cons 'w w) (cons 'h h)) (lambda () (raw-value (format "~a: ~ax~a rectangle" (tesl-display-val *label) (tesl-display-val *w) (tesl-display-val *h)))))))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Triangle)) (let ([b (hash-ref (adt-value-fields *tesl_case_3) 'base)]) (let ([h (hash-ref (adt-value-fields *tesl_case_3) 'height)]) (thsl-src! "tests/adversarial-review-tests.tesl" 323 (list (cons 'b b) (cons 'h h)) (lambda () (raw-value (format "~a: triangle base=~a height=~a" (tesl-display-val *label) (tesl-display-val *b) (tesl-display-val *h)))))))])))))

(define-checker
  (checkPositive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 338 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (Positive n) #:value *n) (reject "must be positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (Small n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 346 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (Small n) #:value *n) (reject "must be small (< 100)" #:http-code 400)))))

(define/pow
  (filterAndAll [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/adversarial-review-tests.tesl" 352 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive *xs))))

(define/pow
  (forAllChain [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/adversarial-review-tests.tesl" 355 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck (check-and checkPositive checkSmall) *xs))))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define/pow
  (makeUserId [raw : String])
  #:returns UserId
  (thsl-src! "tests/adversarial-review-tests.tesl" 397 (list (cons 'raw *raw)) (lambda () (raw-value (UserId *raw)))))

(define/pow
  (makeProjectId [raw : String])
  #:returns ProjectId
  (thsl-src! "tests/adversarial-review-tests.tesl" 400 (list (cons 'raw *raw)) (lambda () (raw-value (ProjectId *raw)))))

(define/pow
  (requiresUserId [uid : UserId])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 403 (list (cons 'uid *uid)) (lambda () (string-append (raw-value uid.value) "-user"))))

(define/pow
  (requiresProjectId [pid : ProjectId])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 406 (list (cons 'pid *pid)) (lambda () (string-append (raw-value pid.value) "-project"))))

(define-checker
  (checkNonNegative [n : Integer])
  #:returns [n : Integer ::: (NonNegative n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 427 (list (cons 'n *n)) (lambda () (if (>= *n 0) (accept (NonNegative n) #:value *n) (reject "must be non-negative" #:http-code 400)))))

(define/pow
  (checkBoth [n : Integer])
  #:returns (? Integer _entity ::: ((NonNegative _entity) && (Small _entity)))
  (thsl-src! "tests/adversarial-review-tests.tesl" 433 (list (cons 'n *n)) (lambda () ((check-and checkNonNegative checkSmall) n))))

(define-checker
  (checkTrimmed [s : String])
  #:returns [s : String ::: (Trimmed s)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 465 (list (cons 's *s)) (lambda () (if (and (> (raw-value (tesl_import_String_length *s)) 0) (equal? (raw-value (tesl_import_String_length (raw-value (tesl_import_String_trim *s)))) (raw-value (tesl_import_String_length *s)))) (accept (Trimmed s) #:value *s) (reject "string must be non-empty and trimmed" #:http-code 400)))))

(define/pow
  (requiresTrimmed [s : String ::: (Trimmed s)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 471 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define-checker
  (checkAge [n : Integer])
  #:returns [n : Integer ::: (ValidAge n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 503 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 150)) (accept (ValidAge n) #:value *n) (reject "invalid age" #:http-code 400)))))

(define/pow
  (needsValidAge [age : Integer ::: (ValidAge age)])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 509 (list (cons 'age *age)) (lambda () (format "age is ~a" (tesl-display-val *age)))))

(define/pow
  (decomposeThenPass [age : Integer])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 512 (list (cons 'age *age)) (lambda () (let/check ([tesl_checked_4 (checkAge age)]) (let ([validated tesl_checked_4]) (let ([tesl_proof_binding_5 validated]) (let ([raw (forget-proof tesl_proof_binding_5)] [proof (detach-all-proof tesl_proof_binding_5)]) (let ([reattached (attach-proof raw proof)]) (raw-value (needsValidAge reattached))))))))))

(define-checker
  (checkInBounds [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InBounds lo hi n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 535 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (>= *n *lo) (<= *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define/pow
  (requiresInBounds [lo : Integer] [hi : Integer] [n : Integer ::: (InBounds lo hi n)])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 541 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (format "~a is in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))))

(define/pow
  (isEven [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/adversarial-review-tests.tesl" 574 (list (cons 'n *n)) (lambda () (if (equal? *n 0) (raw-value #t) (raw-value (isOdd (- *n 1)))))))

(define/pow
  (isOdd [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/adversarial-review-tests.tesl" 580 (list (cons 'n *n)) (lambda () (if (equal? *n 0) (raw-value #f) (raw-value (isEven (- *n 1)))))))

(define/pow
  (intBoundary [n : Integer])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 609 (list (cons 'n *n)) (lambda () (if (> *n 0) (raw-value "positive") (if (< *n 0) (raw-value "negative") (raw-value "zero"))))))

(define/pow
  (divByTwo [n : Integer])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 618 (list (cons 'n *n)) (lambda () (quotient *n 2))))

(define/pow
  (applyValidated [n : Integer] [f : (-> Integer Integer)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 642 (list (cons 'n *n) (cons 'f *f)) (lambda () (let/check ([tesl_checked_6 (checkPositive n)]) (let ([validated tesl_checked_6]) (raw-value (f validated)))))))

(define/pow
  (buildMessage [name : String] [count : Integer])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 660 (list (cons 'name *name) (cons 'count *count)) (lambda () (format "Hello ~a! You have ~a items." (tesl-display-val *name) (tesl-display-val *count)))))

(define/pow
  (emptyInterp [s : String])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 663 (list (cons 's *s)) (lambda () (format "~a" (tesl-display-val *s)))))

(define/pow
  (nestedConcat [a : String] [b : String] [c : String])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 666 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (format "~a-~a-~a" (tesl-display-val *a) (tesl-display-val *b) (tesl-display-val *c)))))

(define/pow
  (sumList [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 688 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-7 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc *x)) tesl-lambda-7) 0 *xs)))))

(define/pow
  (hasNegative [xs : (List Integer)])
  #:returns Boolean
  (thsl-src! "tests/adversarial-review-tests.tesl" 691 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-8 [x : Integer]) #:returns Boolean (< *x 0)) tesl-lambda-8) *xs)))))

(define/pow
  (allPositiveCheck [xs : (List Integer)])
  #:returns Boolean
  (thsl-src! "tests/adversarial-review-tests.tesl" 694 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-9 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-9) *xs)))))

(define-capability reviewRead (implies dbRead))

(define-capability reviewWrite (implies dbWrite))

(define-capability reviewService (implies reviewRead reviewWrite))

(define/pow
  (readSomething)
  #:capabilities [reviewRead]
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 726 (list) (lambda () "read")))

(define/pow
  (readAndWrite)
  #:capabilities [reviewService]
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 730 (list) (lambda () (string-append (raw-value (readSomething)) " and write"))))

(define/pow
  (safeHead [xs : (List Integer)])
  #:returns (Maybe Integer)
  (thsl-src! "tests/adversarial-review-tests.tesl" 742 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_head *xs)))))

(define/pow
  (withDefault [m : (Maybe Integer)] [d : Integer])
  #:returns Integer
  (thsl-src-control! "tests/adversarial-review-tests.tesl" 745 (list (cons 'm *m) (cons 'd *d)) (lambda () (let ([tesl_case_10 *m]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Nothing)) (thsl-src! "tests/adversarial-review-tests.tesl" 746 (list) (lambda () *d))] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_10) 'value)]) (thsl-src! "tests/adversarial-review-tests.tesl" 747 (list (cons 'v v)) (lambda () *v)))])))))

(define/pow
  (chainMaybe [xs : (List Integer)])
  #:returns Integer
  (let ([h (thsl-src! "tests/adversarial-review-tests.tesl" 750 (list (cons 'xs *xs)) (lambda () (safeHead xs)))]) (thsl-src! "tests/adversarial-review-tests.tesl" 751 (list (cons 'h *h) (cons 'xs *xs)) (lambda () (raw-value (withDefault h 0))))))

(define-checker
  (checkAtLeastFive [n : Integer])
  #:returns [n : Integer ::: (AtLeastFive n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 782 (list (cons 'n *n)) (lambda () (if (>= *n 5) (accept (AtLeastFive n) #:value *n) (reject "must be at least 5" #:http-code 400)))))

(define-checker
  (checkAtMostTen [n : Integer])
  #:returns [n : Integer ::: (AtMostTen n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 790 (list (cons 'n *n)) (lambda () (if (<= *n 10) (accept (AtMostTen n) #:value *n) (reject "must be at most 10" #:http-code 400)))))

(define-adt Threshold
  [Low [n : Integer]]
  [Mid [n : Integer]]
  [High [n : Integer]]
)

(define/pow
  (classifyThreshold [t : Threshold])
  #:returns String
  (thsl-src-control! "tests/adversarial-review-tests.tesl" 862 (list (cons 't *t)) (lambda () (let ([tesl_case_11 *t]) (cond [(and (and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Low)) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (< *n 0))) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (thsl-src! "tests/adversarial-review-tests.tesl" 863 (list (cons 'n n)) (lambda () (raw-value "low-negative"))))] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Low)) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (thsl-src! "tests/adversarial-review-tests.tesl" 864 (list (cons 'n n)) (lambda () (raw-value "low-nonneg"))))] [(and (and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Mid)) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (> *n 50))) (let ([n (hash-ref (adt-value-fields *tesl_case_11) 'n)]) (thsl-src! "tests/adversarial-review-tests.tesl" 865 (list (cons 'n n)) (lambda () (raw-value "mid-high"))))] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Mid)) (thsl-src! "tests/adversarial-review-tests.tesl" 866 (list) (lambda () (raw-value "mid-low")))] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'High)) (thsl-src! "tests/adversarial-review-tests.tesl" 867 (list) (lambda () (raw-value "high")))])))))

(define/pow
  (countItems [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 884 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-12 [acc : Integer] [ignored : Integer]) #:returns Integer (+ *acc 1)) tesl-lambda-12) 0 *xs)))))

(define/pow
  (sumSquares [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 887 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-13 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc (* *x *x))) tesl-lambda-13) 0 *xs)))))

(define-checker
  (checkBounded [n : Integer])
  #:returns [n : Integer ::: (Bounded n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 915 (list (cons 'n *n)) (lambda () (if (and (>= *n 1) (<= *n 999)) (accept (Bounded n) #:value *n) (reject "out of bounds [1,999]" #:http-code 400)))))

(define/pow
  (requiresBounded [n : Integer ::: (Bounded n)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 920 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (checkPosAndSmall [n : Integer])
  #:returns (? Integer _entity ::: ((Positive _entity) && (Small _entity)))
  (thsl-src! "tests/adversarial-review-tests.tesl" 951 (list (cons 'n *n)) (lambda () ((check-and checkPositive checkSmall) n))))

(define/pow
  (checkPosAndSmallAndSidecar1 [n : Integer] [m : Integer])
  #:returns (? Integer _entity ::: (((Positive _entity) && (Small _entity)) && (Positive m)))
  (let ([tesl_proof_binding_14 (thsl-src! "tests/adversarial-review-tests.tesl" 954 (list (cons 'n *n) (cons 'm *m)) (lambda () (checkPositive m)))]) (let ([_ (forget-proof tesl_proof_binding_14)] [p (detach-all-proof tesl_proof_binding_14)]) (thsl-src! "tests/adversarial-review-tests.tesl" 955 (list (cons '_ *_) (cons 'n *n) (cons 'm *m)) (lambda () (attach-proof ((check-and checkPositive checkSmall) n) p))))))

(define/pow
  (checkPosAndSmallAndSidecar2_shouldWork [n : Integer] [m : Integer])
  #:returns (? Integer _entity ::: (((Positive _entity) && (Small _entity)) && (Small m)))
  (let ([tesl_proof_binding_15 (thsl-src! "tests/adversarial-review-tests.tesl" 962 (list (cons 'n *n) (cons 'm *m)) (lambda () (checkSmall m)))]) (let ([_ (forget-proof tesl_proof_binding_15)] [p (detach-all-proof tesl_proof_binding_15)]) (thsl-src! "tests/adversarial-review-tests.tesl" 963 (list (cons '_ *_) (cons 'n *n) (cons 'm *m)) (lambda () (attach-proof ((check-and checkPositive checkSmall) n) p))))))

(define/pow
  (foo)
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 966 (list) (lambda () (let ([n1 1]) (let ([n99 99]) (let ([tesl_proof_binding_16 (checkPosAndSmall n1)]) (let ([v1 (forget-proof tesl_proof_binding_16)] [v1_smallFact (detach-all-proof tesl_proof_binding_16)]) (let ([tesl_proof_binding_17 (checkPosAndSmallAndSidecar1 n99 v1)]) (let ([int1 (forget-proof tesl_proof_binding_17)] [posP (detach-all-proof tesl_proof_binding_17)]) (let ([tesl_proof_binding_18 (checkPosAndSmallAndSidecar1 n99 v1)]) (let ([_ (forget-proof tesl_proof_binding_18)] [smallP (detach-all-proof tesl_proof_binding_18)]) (let ([tesl_proof_binding_19 (checkPosAndSmallAndSidecar1 n99 v1)]) (let ([_ (forget-proof tesl_proof_binding_19)] [v1_positiveFact (detach-all-proof tesl_proof_binding_19)]) (let ([_ (requiresPosAndSmall (attach-proof v1 (list v1_positiveFact v1_smallFact)))]) (let ([_ (equal? (raw-value (requiresPosAndSmall (attach-proof int1 (list posP smallP)))) 99)]) 2)))))))))))))))

(define/pow
  (requiresPosAndSmall [n : Integer ::: ((Positive n) && (Small n))])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 974 (list (cons 'n *n)) (lambda () *n)))

(define-newtype TaggedInt Integer)

(define/pow
  (makeTagged [n : Integer])
  #:returns TaggedInt
  (thsl-src! "tests/adversarial-review-tests.tesl" 1020 (list (cons 'n *n)) (lambda () (raw-value (TaggedInt *n)))))

(define/pow
  (requiresTagged [t : TaggedInt])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1021 (list (cons 't *t)) (lambda () (raw-value t.value))))

(define-checker
  (checkAscii [s : String])
  #:returns [s : String ::: (AsciiOnly s)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 1045 (list (cons 's *s)) (lambda () (if (tesl_import_String_isEmpty *s) (reject "empty string" #:http-code 400) (accept (AsciiOnly s) #:value *s)))))

(define/pow
  (requiresAscii [s : String ::: (AsciiOnly s)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1050 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define-checker
  (checkPositiveMsg [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 1071 (list (cons 'n *n)) (lambda () (checkPositive n))))

(define/pow
  (wrapAndUnwrap [n : Integer])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1092 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_20 (checkPositive n)]) (let ([validated tesl_checked_20]) (let ([raw (forget-proof validated)]) (let ([proof (detach-all-proof validated)]) (let ([reattached (attach-proof raw proof)]) (let/check ([tesl_checked_21 (checkBounded reattached)]) (let ([rb tesl_checked_21]) (raw-value (requiresBounded rb))))))))))))

(define/pow
  (safeRecip [x : Real])
  #:returns Real
  (let ([nz (thsl-src! "tests/adversarial-review-tests.tesl" 1115 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Float_requireNonZero *x))))]) (thsl-src! "tests/adversarial-review-tests.tesl" 1116 (list (cons 'nz *nz) (cons 'x *x)) (lambda () (raw-value (tesl_import_Float_div 1. (raw-value nz)))))))

(define/pow
  (safeSqrt [x : Real])
  #:returns Real
  (thsl-src! "tests/adversarial-review-tests.tesl" 1119 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Float_sqrt (raw-value (tesl_import_Float_abs *x)))))))

(define-checker
  (checkSlug [s : String])
  #:returns [s : String ::: (ValidSlug s)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 1149 (list (cons 's *s)) (lambda () (if (tesl_import_String_isEmpty *s) (reject "slug is empty" #:http-code 400) (if (> (raw-value (tesl_import_String_length *s)) 64) (reject "slug too long" #:http-code 400) (accept (ValidSlug s) #:value *s))))))

(define/pow
  (requiresSlug [s : String ::: (ValidSlug s)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1157 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define/pow
  (identityProof [n : Integer ::: (InRange n)])
  #:returns [n : Integer ::: (InRange n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 1187 (list (cons 'n *n)) (lambda () n)))

(define-checker
  (checkNonNegStr [s : String])
  #:returns [s : String ::: (NonNegLen s)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 1203 (list (cons 's *s)) (lambda () (if (>= (raw-value (tesl_import_String_length *s)) 0) (accept (NonNegLen s) #:value *s) (reject "impossible negative length" #:http-code 400)))))

(define/pow
  (requiresNonNegStr [s : String ::: (NonNegLen s)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1208 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define-adt Tree
  [Leaf]
  [Node [left : Tree] [value : Integer] [right : Tree]]
)

(define/pow
  (treeDepth [t : Tree])
  #:returns Integer
  (thsl-src-control! "tests/adversarial-review-tests.tesl" 1228 (list (cons 't *t)) (lambda () (let ([tesl_case_22 *t]) (cond [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Leaf)) (thsl-src! "tests/adversarial-review-tests.tesl" 1229 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Node)) (let ([left (hash-ref (adt-value-fields *tesl_case_22) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_22) 'right)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1231 (list (cons 'left left) (cons 'right right)) (lambda () (let ([leftDepth (treeDepth *left)]) (let ([rightDepth (treeDepth *right)]) (if (> (raw-value leftDepth) (raw-value rightDepth)) (raw-value (+ 1 (raw-value leftDepth))) (raw-value (+ 1 (raw-value rightDepth))))))))))])))))

(define/pow
  (factorial [n : Integer])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1268 (list (cons 'n *n)) (lambda () (if (<= *n 0) (raw-value 1) (raw-value (* *n (raw-value (factorial (- *n 1)))))))))

(define/pow
  (fibonacci [n : Integer])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1274 (list (cons 'n *n)) (lambda () (if (<= *n 0) (raw-value 0) (if (equal? *n 1) (raw-value 1) (raw-value (+ (raw-value (fibonacci (- *n 1))) (raw-value (fibonacci (- *n 2))))))))))

(define/pow
  (conjunctSatisfied [n : Integer])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 1315 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_23 (checkPositive n)]) (let ([_pos tesl_checked_23]) (let/check ([tesl_checked_24 ((check-and checkPositive checkSmall) n)]) (let ([_both tesl_checked_24]) "done")))))))

(define/pow
  (sumList2 [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1340 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-25 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc *x)) tesl-lambda-25) 0 *xs)))))

(define/pow
  (upperLengthPreserved [s : String])
  #:returns Boolean
  (thsl-src! "tests/adversarial-review-tests.tesl" 1365 (list (cons 's *s)) (lambda () (equal? (raw-value (tesl_import_String_length (raw-value (tesl_import_String_toUpper *s)))) (raw-value (tesl_import_String_length *s))))))

(define/pow
  (lowerLengthPreserved [s : String])
  #:returns Boolean
  (thsl-src! "tests/adversarial-review-tests.tesl" 1368 (list (cons 's *s)) (lambda () (equal? (raw-value (tesl_import_String_length (raw-value (tesl_import_String_toLower *s)))) (raw-value (tesl_import_String_length *s))))))

(define/pow
  (filterPositiveTwice [xs : (List Integer)])
  #:returns (List Integer)
  (let ([once (thsl-src! "tests/adversarial-review-tests.tesl" 1387 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive *xs)))]) (thsl-src! "tests/adversarial-review-tests.tesl" 1388 (list (cons 'once *once) (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive (raw-value once))))))

(define/pow
  (filterPositiveOnce [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/adversarial-review-tests.tesl" 1391 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive *xs))))

(define/pow
  (checkInBounds1020 [n : Integer])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 1412 (list (cons 'n *n)) (lambda () (let ([lo 10]) (let ([hi 20]) (let/check ([tesl_checked_26 (checkInBounds lo hi n)]) (let ([v tesl_checked_26]) (raw-value (requiresInBounds lo hi v)))))))))

(define/pow
  (checkInBoundsEqual [n : Integer])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 1418 (list (cons 'n *n)) (lambda () (let ([lo 5]) (let ([hi 5]) (let/check ([tesl_checked_27 (checkInBounds lo hi n)]) (let ([v tesl_checked_27]) (raw-value (requiresInBounds lo hi v)))))))))

(define/pow
  (checkInBoundsNeg [n : Integer])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 1424 (list (cons 'n *n)) (lambda () (let ([lo -10]) (let ([hi -1]) (let/check ([tesl_checked_28 (checkInBounds lo hi n)]) (let ([v tesl_checked_28]) (raw-value (requiresInBounds lo hi v)))))))))

(define/pow
  (checkInBoundsLo [n : Integer])
  #:returns String
  (thsl-src! "tests/adversarial-review-tests.tesl" 1430 (list (cons 'n *n)) (lambda () (let ([lo 0]) (let ([hi 100]) (let/check ([tesl_checked_29 (checkInBounds lo hi n)]) (let ([v tesl_checked_29]) (raw-value (requiresInBounds lo hi v)))))))))

(define/pow
  (parseAndValidate [s : String])
  #:returns (Either String Integer)
  (thsl-src-control! "tests/adversarial-review-tests.tesl" 1462 (list (cons 's *s)) (lambda () (let ([tesl_case_30 (raw-value (raw-value (checkNonEmpty s)))]) (cond [#t (let ([result *tesl_case_30]) (thsl-src! "tests/adversarial-review-tests.tesl" 1464 (list (cons 'result result)) (lambda () (let ([n (tesl_import_String_length *result)]) (if (< (raw-value n) 10) (raw-value (raw-value (Right (raw-value n)))) (raw-value (raw-value (Left "too long"))))))))])))))

(define/pow
  (evalNested [e : Expr])
  #:returns Integer
  (thsl-src-control! "tests/adversarial-review-tests.tesl" 1492 (list (cons 'e *e)) (lambda () (let ([tesl_case_31 *e]) (cond [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Lit)) (let ([n (hash-ref (adt-value-fields *tesl_case_31) 'n)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1493 (list (cons 'n n)) (lambda () *n)))] [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Add)) (let ([left (hash-ref (adt-value-fields *tesl_case_31) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_31) 'right)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1495 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (+ (raw-value (evalNested *left)) (raw-value (evalNested *right))))))))] [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Mul)) (let ([left (hash-ref (adt-value-fields *tesl_case_31) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_31) 'right)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1497 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (* (raw-value (evalNested *left)) (raw-value (evalNested *right))))))))] [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Neg)) (let ([inner (hash-ref (adt-value-fields *tesl_case_31) 'inner)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1498 (list (cons 'inner inner)) (lambda () (raw-value (- 0 (raw-value (evalNested *inner)))))))])))))

(define/pow
  (proofIndependenceCorrect [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1532 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl_checked_32 (checkPositive a)]) (let ([va tesl_checked_32]) (let/check ([tesl_checked_33 (checkPositive b)]) (let ([vb tesl_checked_33]) (let/check ([tesl_checked_34 (checkBounded va)]) (let ([vab tesl_checked_34]) (let/check ([tesl_checked_35 (checkBounded vb)]) (let ([vbb tesl_checked_35]) (+ (raw-value (requiresBounded vab)) (raw-value (requiresBounded vbb))))))))))))))

(define/pow
  (maxRec [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/adversarial-review-tests.tesl" 1567 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (> *a *b) *a *b))))

(define-checker
  (checkSmallBug2 [n : Integer])
  #:returns [n : Integer ::: (Small n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 1596 (list (cons 'n *n)) (lambda () (if (and (> *n 0) (< *n 100)) (accept (Small n) #:value *n) (reject "must be between 1 and 99" #:http-code 422)))))

(define/pow
  (fnWrapsCheck [n : Integer])
  #:returns (? Integer _entity ::: (Small _entity))
  (thsl-src! "tests/adversarial-review-tests.tesl" 1602 (list (cons 'n *n)) (lambda () (checkSmallBug2 n))))

(define-checker
  (checkPositiveBug7 [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (thsl-src! "tests/adversarial-review-tests.tesl" 1626 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (Positive n) #:value *n) (reject "must be positive" #:http-code 422)))))

(define/pow
  (filteredPositives [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/adversarial-review-tests.tesl" 1632 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositiveBug7 *xs))))

(module+ test
  (require rackunit)
  (test-case "range check accepts boundary values"
  (define n0 (thsl-src! "tests/adversarial-review-tests.tesl" 122 (list) (lambda () 0)))
  (define tesl_checked_36 (checkRange n0))
  (when (check-fail? tesl_checked_36)
    (raise-user-error 'tesl-test "unexpected failure in let r0: ~a" (check-fail-message tesl_checked_36)))
  (define r0 tesl_checked_36)
  (define n100 (thsl-src! "tests/adversarial-review-tests.tesl" 124 (list (cons 'r0 r0) (cons 'n0 n0)) (lambda () 100)))
  (define tesl_checked_37 (checkRange n100))
  (when (check-fail? tesl_checked_37)
    (raise-user-error 'tesl-test "unexpected failure in let r100: ~a" (check-fail-message tesl_checked_37)))
  (define r100 tesl_checked_37)
  (define n50 (thsl-src! "tests/adversarial-review-tests.tesl" 126 (list (cons 'r100 r100) (cons 'n100 n100) (cons 'r0 r0) (cons 'n0 n0)) (lambda () 50)))
  (define tesl_checked_38 (checkRange n50))
  (when (check-fail? tesl_checked_38)
    (raise-user-error 'tesl-test "unexpected failure in let r50: ~a" (check-fail-message tesl_checked_38)))
  (define r50 tesl_checked_38)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 128 (list (cons 'r50 r50) (cons 'n50 n50) (cons 'r100 r100) (cons 'n100 n100) (cons 'r0 r0) (cons 'n0 n0)) (lambda () (requiresRange r0)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 129 (list (cons 'r50 r50) (cons 'n50 n50) (cons 'r100 r100) (cons 'n100 n100) (cons 'r0 r0) (cons 'n0 n0)) (lambda () (requiresRange r100)))) 101)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 130 (list (cons 'r50 r50) (cons 'n50 n50) (cons 'r100 r100) (cons 'n100 n100) (cons 'r0 r0) (cons 'n0 n0)) (lambda () (requiresRange r50)))) 51)
  )

  (test-case "range check rejects out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 134 (list) (lambda ()
                          (checkRange -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkRange -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 135 (list) (lambda ()
                          (checkRange 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkRange 101"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 136 (list) (lambda ()
                          (checkRange -100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkRange -100"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 137 (list) (lambda ()
                          (checkRange 1000))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkRange 1000"))
  )

  (test-case "proof is attached after check"
  (let ([tesl-hpv (thsl-src! "tests/adversarial-review-tests.tesl" 147 (list) (lambda () (checkRange 50)))])
    (check-true
      (for/or ([f (in-list (facts-of tesl-hpv))])
        (and (pair? f) (eq? (car f) 'InRange)))
      "expected result to carry proof InRange"))
  (let ([tesl-hpv (thsl-src! "tests/adversarial-review-tests.tesl" 148 (list) (lambda () (checkRange 0)))])
    (check-true
      (for/or ([f (in-list (facts-of tesl-hpv))])
        (and (pair? f) (eq? (car f) 'InRange)))
      "expected result to carry proof InRange"))
  (let ([tesl-hpv (thsl-src! "tests/adversarial-review-tests.tesl" 149 (list) (lambda () (checkRange 100)))])
    (check-true
      (for/or ([f (in-list (facts-of tesl-hpv))])
        (and (pair? f) (eq? (car f) 'InRange)))
      "expected result to carry proof InRange"))
  )

  (test-case "non-empty check passes valid strings"
  (define s1 (thsl-src! "tests/adversarial-review-tests.tesl" 168 (list) (lambda () "hello")))
  (define tesl_checked_39 (checkNonEmpty s1))
  (when (check-fail? tesl_checked_39)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl_checked_39)))
  (define a tesl_checked_39)
  (define s2 (thsl-src! "tests/adversarial-review-tests.tesl" 170 (list (cons 'a a) (cons 's1 s1)) (lambda () " ")))
  (define tesl_checked_40 (checkNonEmpty s2))
  (when (check-fail? tesl_checked_40)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl_checked_40)))
  (define b tesl_checked_40)
  (define s3 (thsl-src! "tests/adversarial-review-tests.tesl" 172 (list (cons 'b b) (cons 's2 s2) (cons 'a a) (cons 's1 s1)) (lambda () "a")))
  (define tesl_checked_41 (checkNonEmpty s3))
  (when (check-fail? tesl_checked_41)
    (raise-user-error 'tesl-test "unexpected failure in let c: ~a" (check-fail-message tesl_checked_41)))
  (define c tesl_checked_41)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 174 (list (cons 'c c) (cons 's3 s3) (cons 'b b) (cons 's2 s2) (cons 'a a) (cons 's1 s1)) (lambda () (requiresNonEmpty a)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 175 (list (cons 'c c) (cons 's3 s3) (cons 'b b) (cons 's2 s2) (cons 'a a) (cons 's1 s1)) (lambda () (requiresNonEmpty b)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 176 (list (cons 'c c) (cons 's3 s3) (cons 'b b) (cons 's2 s2) (cons 'a a) (cons 's1 s1)) (lambda () (requiresNonEmpty c)))) 1)
  )

  (test-case "non-empty check rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 180 (list) (lambda ()
                          (checkNonEmpty ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkNonEmpty \"\""))
  )

  (test-case "email check accepts well-formed addresses"
  (define raw1 (thsl-src! "tests/adversarial-review-tests.tesl" 196 (list) (lambda () "user@example.com")))
  (define tesl_checked_42 (checkEmail raw1))
  (when (check-fail? tesl_checked_42)
    (raise-user-error 'tesl-test "unexpected failure in let e1: ~a" (check-fail-message tesl_checked_42)))
  (define e1 tesl_checked_42)
  (define raw2 (thsl-src! "tests/adversarial-review-tests.tesl" 198 (list (cons 'e1 e1) (cons 'raw1 raw1)) (lambda () "a@b.c")))
  (define tesl_checked_43 (checkEmail raw2))
  (when (check-fail? tesl_checked_43)
    (raise-user-error 'tesl-test "unexpected failure in let e2: ~a" (check-fail-message tesl_checked_43)))
  (define e2 tesl_checked_43)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 200 (list (cons 'e2 e2) (cons 'raw2 raw2) (cons 'e1 e1) (cons 'raw1 raw1)) (lambda () (tesl_import_String_length e1)))) 16)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 201 (list (cons 'e2 e2) (cons 'raw2 raw2) (cons 'e1 e1) (cons 'raw1 raw1)) (lambda () (tesl_import_String_length e2)))) 5)
  )

  (test-case "email check rejects malformed addresses"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 205 (list) (lambda ()
                          (checkEmail ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 206 (list) (lambda ()
                          (checkEmail "nodomain"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"nodomain\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 207 (list) (lambda ()
                          (checkEmail "no-at-sign.com"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"no-at-sign.com\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 208 (list) (lambda ()
                          (checkEmail "a@b"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"a@b\""))
  )

  (test-case "safeDiv handles zero divisor"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 240 (list) (lambda () (safeDiv 10 0)))) (raw-value (Left "division by zero")))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 241 (list) (lambda () (safeDiv 0 0)))) (raw-value (Left "division by zero")))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 242 (list) (lambda () (safeDiv 100 5)))) (raw-value (Right 20)))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 243 (list) (lambda () (safeDiv 7 2)))) (raw-value (Right 3)))
  )

  (test-case "safeDiv negative dividend"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 247 (list) (lambda () (safeDiv -10 3)))) (raw-value (Right -3)))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 248 (list) (lambda () (safeDiv -7 2)))) (raw-value (Right -3)))
  )

  (test-case "clampAndAdd boundary"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 252 (list) (lambda () (clampAndAdd 0 10 -5 3)))) 3)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 253 (list) (lambda () (clampAndAdd 0 10 15 3)))) 13)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 254 (list) (lambda () (clampAndAdd 0 10 5 3)))) 8)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 255 (list) (lambda () (clampAndAdd 0 10 0 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 256 (list) (lambda () (clampAndAdd 0 10 10 0)))) 10)
  )

  (test-case "describeColor covers all constructors"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 285 (list) (lambda () (describeColor Red)))) "red")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 286 (list) (lambda () (describeColor Green)))) "green")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 287 (list) (lambda () (describeColor Blue)))) "blue")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 288 (list) (lambda () (describeColor (Custom 255 128 0))))) "custom(255,128,0)")
  )

  (test-case "describeAll handles mixed list"
  (define results (thsl-src! "tests/adversarial-review-tests.tesl" 292 (list) (lambda () (describeAll (list Red Green Blue (Custom 0 0 0))))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 293 (list (cons 'results results)) (lambda () (raw-value (tesl_import_List_length (raw-value results)))))) 4)
  )

  (test-case "evaluate expression tree"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 311 (list) (lambda () (evaluate (Lit 5))))) 5)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 312 (list) (lambda () (evaluate (Add (Lit 3) (Lit 4)))))) 7)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 313 (list) (lambda () (evaluate (Mul (Lit 2) (Lit 6)))))) 12)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 314 (list) (lambda () (evaluate (Neg (Lit 3)))))) -3)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 315 (list) (lambda () (evaluate (Add (Mul (Lit 2) (Lit 3)) (Neg (Lit 1))))))) 5)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 316 (list) (lambda () (evaluate (Mul (Add (Lit 1) (Lit 2)) (Add (Lit 3) (Lit 4))))))) 21)
  )

  (test-case "describeNested produces correct strings"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 326 (list) (lambda () (describeNested (Circle 5) "A")))) "A: circle with radius 5")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 327 (list) (lambda () (describeNested (Rectangle 3 4) "B")))) "B: 3x4 rectangle")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 328 (list) (lambda () (describeNested (Triangle 6 8) "C")))) "C: triangle base=6 height=8")
  )

  (test-case "filterCheck produces ForAll proof"
  (define positives (thsl-src! "tests/adversarial-review-tests.tesl" 358 (list) (lambda () (filterAndAll (list 1 -2 3 -4 5)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 359 (list (cons 'positives positives)) (lambda () (raw-value (tesl_import_List_length (raw-value positives)))))) 3)
  )

  (test-case "filterCheck with empty input"
  (define empty (thsl-src! "tests/adversarial-review-tests.tesl" 363 (list) (lambda () (filterAndAll (list)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 364 (list (cons 'empty empty)) (lambda () (raw-value (tesl_import_List_length (raw-value empty)))))) 0)
  )

  (test-case "filterCheck with all-negative input"
  (define none (thsl-src! "tests/adversarial-review-tests.tesl" 368 (list) (lambda () (filterAndAll (list -1 -5 -100)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 369 (list (cons 'none none)) (lambda () (raw-value (tesl_import_List_length (raw-value none)))))) 0)
  )

  (test-case "combined filterCheck both predicates"
  (define both (thsl-src! "tests/adversarial-review-tests.tesl" 373 (list) (lambda () (forAllChain (list 1 150 -5 50 200 99)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 374 (list (cons 'both both)) (lambda () (raw-value (tesl_import_List_length (raw-value both)))))) 3)
  )

  (test-case "allCheck returns Nothing on any failure"
  (define xs (thsl-src! "tests/adversarial-review-tests.tesl" 378 (list) (lambda () (list 1 2 3 4 5))))
  (define result (thsl-src! "tests/adversarial-review-tests.tesl" 379 (list (cons 'xs xs)) (lambda () (tesl_import_List_allCheck checkPositive (raw-value xs)))))
  (check-not-equal? (thsl-src! "tests/adversarial-review-tests.tesl" 380 (list (cons 'result result) (cons 'xs xs)) (lambda () result)) Nothing)
  )

  (test-case "allCheck returns Nothing when any element fails"
  (define xs (thsl-src! "tests/adversarial-review-tests.tesl" 384 (list) (lambda () (list 1 2 -1 4 5))))
  (define result (thsl-src! "tests/adversarial-review-tests.tesl" 385 (list (cons 'xs xs)) (lambda () (tesl_import_List_allCheck checkPositive (raw-value xs)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 386 (list (cons 'result result) (cons 'xs xs)) (lambda () result))) Nothing)
  )

  (test-case "UserId and ProjectId are distinct newtypes"
  (define uid (thsl-src! "tests/adversarial-review-tests.tesl" 409 (list) (lambda () (makeUserId "user-123"))))
  (define pid (thsl-src! "tests/adversarial-review-tests.tesl" 410 (list (cons 'uid uid)) (lambda () (makeProjectId "project-456"))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 411 (list (cons 'pid pid) (cons 'uid uid)) (lambda () (requiresUserId uid)))) "user-123-user")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 412 (list (cons 'pid pid) (cons 'uid uid)) (lambda () (requiresProjectId pid)))) "project-456-project")
  )

  (test-case "newtypes round-trip through .value"
  (define uid (thsl-src! "tests/adversarial-review-tests.tesl" 416 (list) (lambda () (makeUserId "abc"))))
  (check-equal? (thsl-src! "tests/adversarial-review-tests.tesl" 417 (list (cons 'uid uid)) (lambda () (raw-value (tesl-dot/runtime uid 'value)))) "abc")
  )

  (test-case "combined check passes when both pass"
  (define n (thsl-src! "tests/adversarial-review-tests.tesl" 436 (list) (lambda () 50)))
  (define v (thsl-src! "tests/adversarial-review-tests.tesl" 437 (list (cons 'n n)) (lambda () (checkBoth n))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 438 (list (cons 'v v) (cons 'n n)) (lambda () v))) 50)
  )

  (test-case "combined check fails when first fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 442 (list) (lambda ()
                          (checkBoth -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkBoth -1"))
  )

  (test-case "combined check fails when second fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 446 (list) (lambda ()
                          (checkBoth 200))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkBoth 200"))
  )

  (test-case "combined check at boundary: 0 and 99"
  (define n0 (thsl-src! "tests/adversarial-review-tests.tesl" 450 (list) (lambda () 0)))
  (define zero (thsl-src! "tests/adversarial-review-tests.tesl" 451 (list (cons 'n0 n0)) (lambda () (checkBoth n0))))
  (define n99 (thsl-src! "tests/adversarial-review-tests.tesl" 452 (list (cons 'zero zero) (cons 'n0 n0)) (lambda () 99)))
  (define limit (thsl-src! "tests/adversarial-review-tests.tesl" 453 (list (cons 'n99 n99) (cons 'zero zero) (cons 'n0 n0)) (lambda () (checkBoth n99))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 454 (list (cons 'limit limit) (cons 'n99 n99) (cons 'zero zero) (cons 'n0 n0)) (lambda () zero))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 455 (list (cons 'limit limit) (cons 'n99 n99) (cons 'zero zero) (cons 'n0 n0)) (lambda () limit))) 99)
  )

  (test-case "trimmed check accepts trimmed strings"
  (define s1 (thsl-src! "tests/adversarial-review-tests.tesl" 474 (list) (lambda () "hello")))
  (define tesl_checked_44 (checkTrimmed s1))
  (when (check-fail? tesl_checked_44)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl_checked_44)))
  (define a tesl_checked_44)
  (define s2 (thsl-src! "tests/adversarial-review-tests.tesl" 476 (list (cons 'a a) (cons 's1 s1)) (lambda () "no spaces here")))
  (define tesl_checked_45 (checkTrimmed s2))
  (when (check-fail? tesl_checked_45)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl_checked_45)))
  (define b tesl_checked_45)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 478 (list (cons 'b b) (cons 's2 s2) (cons 'a a) (cons 's1 s1)) (lambda () (requiresTrimmed a)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 479 (list (cons 'b b) (cons 's2 s2) (cons 'a a) (cons 's1 s1)) (lambda () (requiresTrimmed b)))) 14)
  )

  (test-case "trimmed check rejects leading whitespace"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 483 (list) (lambda ()
                          (checkTrimmed " hello"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \" hello\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 484 (list) (lambda ()
                          (checkTrimmed "  leading"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \"  leading\""))
  )

  (test-case "trimmed check rejects trailing whitespace"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 488 (list) (lambda ()
                          (checkTrimmed "trailing "))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \"trailing \""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 489 (list) (lambda ()
                          (checkTrimmed "both ends "))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \"both ends \""))
  )

  (test-case "trimmed check rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 493 (list) (lambda ()
                          (checkTrimmed ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed \"\""))
  )

  (test-case "proof decomposition and reattachment"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 518 (list) (lambda () (decomposeThenPass 25)))) "age is 25")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 519 (list) (lambda () (decomposeThenPass 0)))) "age is 0")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 520 (list) (lambda () (decomposeThenPass 150)))) "age is 150")
  )

  (test-case "decompose fails for out-of-range ages"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 524 (list) (lambda ()
                          (decomposeThenPass -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decomposeThenPass -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 525 (list) (lambda ()
                          (decomposeThenPass 151))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decomposeThenPass 151"))
  )

  (test-case "multi-param fact: in bounds"
  (define lo (thsl-src! "tests/adversarial-review-tests.tesl" 544 (list) (lambda () 1)))
  (define hi (thsl-src! "tests/adversarial-review-tests.tesl" 545 (list (cons 'lo lo)) (lambda () 10)))
  (define n (thsl-src! "tests/adversarial-review-tests.tesl" 546 (list (cons 'hi hi) (cons 'lo lo)) (lambda () 5)))
  (define tesl_checked_46 (checkInBounds lo hi n))
  (when (check-fail? tesl_checked_46)
    (raise-user-error 'tesl-test "unexpected failure in let x: ~a" (check-fail-message tesl_checked_46)))
  (define x tesl_checked_46)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 548 (list (cons 'x x) (cons 'n n) (cons 'hi hi) (cons 'lo lo)) (lambda () x))) 5)
  )

  (test-case "multi-param fact: boundary values"
  (define lo (thsl-src! "tests/adversarial-review-tests.tesl" 552 (list) (lambda () 0)))
  (define hi (thsl-src! "tests/adversarial-review-tests.tesl" 553 (list (cons 'lo lo)) (lambda () 100)))
  (define v0 (thsl-src! "tests/adversarial-review-tests.tesl" 554 (list (cons 'hi hi) (cons 'lo lo)) (lambda () 0)))
  (define v100 (thsl-src! "tests/adversarial-review-tests.tesl" 555 (list (cons 'v0 v0) (cons 'hi hi) (cons 'lo lo)) (lambda () 100)))
  (define tesl_checked_47 (checkInBounds lo hi v0))
  (when (check-fail? tesl_checked_47)
    (raise-user-error 'tesl-test "unexpected failure in let atLo: ~a" (check-fail-message tesl_checked_47)))
  (define atLo tesl_checked_47)
  (define tesl_checked_48 (checkInBounds lo hi v100))
  (when (check-fail? tesl_checked_48)
    (raise-user-error 'tesl-test "unexpected failure in let atHi: ~a" (check-fail-message tesl_checked_48)))
  (define atHi tesl_checked_48)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 558 (list (cons 'atHi atHi) (cons 'atLo atLo) (cons 'v100 v100) (cons 'v0 v0) (cons 'hi hi) (cons 'lo lo)) (lambda () atLo))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 559 (list (cons 'atHi atHi) (cons 'atLo atLo) (cons 'v100 v100) (cons 'v0 v0) (cons 'hi hi) (cons 'lo lo)) (lambda () atHi))) 100)
  )

  (test-case "multi-param fact: rejects out-of-bounds"
  (define lo (thsl-src! "tests/adversarial-review-tests.tesl" 563 (list) (lambda () 1)))
  (define hi (thsl-src! "tests/adversarial-review-tests.tesl" 564 (list (cons 'lo lo)) (lambda () 10)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 565 (list (cons 'hi hi) (cons 'lo lo)) (lambda ()
                          (checkInBounds lo hi -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds lo hi -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 566 (list (cons 'hi hi) (cons 'lo lo)) (lambda ()
                          (checkInBounds lo hi 11))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds lo hi 11"))
  )

  (test-case "isEven base cases"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 586 (list) (lambda () (isEven 0)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 587 (list) (lambda () (isOdd 0)))) #f)
  )

  (test-case "isEven/isOdd small values"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 591 (list) (lambda () (isEven 2)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 592 (list) (lambda () (isEven 3)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 593 (list) (lambda () (isOdd 1)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 594 (list) (lambda () (isOdd 4)))) #f)
  )

  (test-case "isEven/isOdd larger values"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 598 (list) (lambda () (isEven 10)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 599 (list) (lambda () (isOdd 11)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 600 (list) (lambda () (isEven 7)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 601 (list) (lambda () (isOdd 8)))) #f)
  )

  (test-case "intBoundary"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 621 (list) (lambda () (intBoundary 1)))) "positive")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 622 (list) (lambda () (intBoundary -1)))) "negative")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 623 (list) (lambda () (intBoundary 0)))) "zero")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 624 (list) (lambda () (intBoundary 1000000)))) "positive")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 625 (list) (lambda () (intBoundary -1000000)))) "negative")
  )

  (test-case "integer division truncates towards zero"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 629 (list) (lambda () (divByTwo 4)))) 2)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 630 (list) (lambda () (divByTwo 5)))) 2)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 631 (list) (lambda () (divByTwo -5)))) -2)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 632 (list) (lambda () (divByTwo 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 633 (list) (lambda () (divByTwo 1)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 634 (list) (lambda () (divByTwo -1)))) 0)
  )

  (test-case "lambda applied to validated value"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 646 (list) (lambda () (applyValidated 5 (let () (define/pow (tesl-lambda-49 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-49))))) 10)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 647 (list) (lambda () (applyValidated 3 (let () (define/pow (tesl-lambda-50 [x : Integer]) #:returns Integer (+ *x 10)) tesl-lambda-50))))) 13)
  )

  (test-case "lambda fails if n is not positive"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 651 (list) (lambda ()
                          (applyValidated -1 (let () (define/pow (tesl-lambda-51 [x : Integer]) #:returns Integer x) tesl-lambda-51)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: applyValidated -1 (let () (define/pow (tesl-lambda-52 [x : Integer]) #:returns Integer x) tesl-lambda-52)"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 652 (list) (lambda ()
                          (applyValidated 0 (let () (define/pow (tesl-lambda-52 [x : Integer]) #:returns Integer x) tesl-lambda-52)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: applyValidated 0 (let () (define/pow (tesl-lambda-53 [x : Integer]) #:returns Integer x) tesl-lambda-53)"))
  )

  (test-case "string interpolation"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 669 (list) (lambda () (buildMessage "Alice" 3)))) "Hello Alice! You have 3 items.")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 670 (list) (lambda () (buildMessage "Bob" 0)))) "Hello Bob! You have 0 items.")
  )

  (test-case "single-value interpolation"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 674 (list) (lambda () (emptyInterp "test")))) "test")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 675 (list) (lambda () (emptyInterp "")))) "")
  )

  (test-case "multi-value interpolation"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 679 (list) (lambda () (nestedConcat "a" "b" "c")))) "a-b-c")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 680 (list) (lambda () (nestedConcat "" "" "")))) "--")
  )

  (test-case "sumList"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 697 (list) (lambda () (sumList (list))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 698 (list) (lambda () (sumList (list 1 2 3))))) 6)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 699 (list) (lambda () (sumList (list -1 0 1))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 700 (list) (lambda () (sumList (list 100))))) 100)
  )

  (test-case "hasNegative"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 704 (list) (lambda () (hasNegative (list -1 2 3))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 705 (list) (lambda () (hasNegative (list 1 2 3))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 706 (list) (lambda () (hasNegative (list))))) #f)
  )

  (test-case "allPositiveCheck"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 710 (list) (lambda () (allPositiveCheck (list 1 2 3))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 711 (list) (lambda () (allPositiveCheck (list 0 1 2))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 712 (list) (lambda () (allPositiveCheck (list))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 713 (list) (lambda () (allPositiveCheck (list -1 2 3))))) #f)
  )

  (test-case "capability-required functions exist"
    (with-capabilities (reviewService)
    (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 733 (list) (lambda () (readSomething)))) "read")
    (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 734 (list) (lambda () (readAndWrite)))) "read and write")
    )
  )

  (test-case "safeHead on empty list"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 754 (list) (lambda () (safeHead (list))))) Nothing)
  )

  (test-case "safeHead on non-empty list"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 758 (list) (lambda () (safeHead (list 42))))) (raw-value (Something 42)))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 759 (list) (lambda () (safeHead (list 1 2 3))))) (raw-value (Something 1)))
  )

  (test-case "withDefault"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 763 (list) (lambda () (withDefault Nothing 99)))) 99)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 764 (list) (lambda () (withDefault (raw-value (Something 5)) 99)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 765 (list) (lambda () (withDefault (raw-value (Something 0)) 99)))) 0)
  )

  (test-case "chainMaybe"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 769 (list) (lambda () (chainMaybe (list 10 20))))) 10)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 770 (list) (lambda () (chainMaybe (list))))) 0)
  )

  (test-case "checkAtLeastFive: precise boundary"
  (define n5 (thsl-src! "tests/adversarial-review-tests.tesl" 796 (list) (lambda () 5)))
  (define tesl_checked_53 (checkAtLeastFive n5))
  (when (check-fail? tesl_checked_53)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_53)))
  (define v tesl_checked_53)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 798 (list (cons 'v v) (cons 'n5 n5)) (lambda () v))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 799 (list (cons 'v v) (cons 'n5 n5)) (lambda ()
                          (checkAtLeastFive 4))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAtLeastFive 4"))
  )

  (test-case "checkAtLeastFive: values above boundary"
  (define n6 (thsl-src! "tests/adversarial-review-tests.tesl" 803 (list) (lambda () 6)))
  (define tesl_checked_54 (checkAtLeastFive n6))
  (when (check-fail? tesl_checked_54)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_54)))
  (define v tesl_checked_54)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 805 (list (cons 'v v) (cons 'n6 n6)) (lambda () v))) 6)
  (define n1000 (thsl-src! "tests/adversarial-review-tests.tesl" 806 (list (cons 'v v) (cons 'n6 n6)) (lambda () 1000)))
  (define tesl_checked_55 (checkAtLeastFive n1000))
  (when (check-fail? tesl_checked_55)
    (raise-user-error 'tesl-test "unexpected failure in let w: ~a" (check-fail-message tesl_checked_55)))
  (define w tesl_checked_55)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 808 (list (cons 'w w) (cons 'n1000 n1000) (cons 'v v) (cons 'n6 n6)) (lambda () w))) 1000)
  )

  (test-case "checkAtMostTen: precise boundary"
  (define n10 (thsl-src! "tests/adversarial-review-tests.tesl" 812 (list) (lambda () 10)))
  (define tesl_checked_56 (checkAtMostTen n10))
  (when (check-fail? tesl_checked_56)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_56)))
  (define v tesl_checked_56)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 814 (list (cons 'v v) (cons 'n10 n10)) (lambda () v))) 10)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 815 (list (cons 'v v) (cons 'n10 n10)) (lambda ()
                          (checkAtMostTen 11))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAtMostTen 11"))
  )

  (test-case "checkAtMostTen: values below boundary"
  (define n9 (thsl-src! "tests/adversarial-review-tests.tesl" 819 (list) (lambda () 9)))
  (define tesl_checked_57 (checkAtMostTen n9))
  (when (check-fail? tesl_checked_57)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_57)))
  (define v tesl_checked_57)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 821 (list (cons 'v v) (cons 'n9 n9)) (lambda () v))) 9)
  (define nNeg (thsl-src! "tests/adversarial-review-tests.tesl" 822 (list (cons 'v v) (cons 'n9 n9)) (lambda () -100)))
  (define tesl_checked_58 (checkAtMostTen nNeg))
  (when (check-fail? tesl_checked_58)
    (raise-user-error 'tesl-test "unexpected failure in let w: ~a" (check-fail-message tesl_checked_58)))
  (define w tesl_checked_58)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 824 (list (cons 'w w) (cons 'nNeg nNeg) (cons 'v v) (cons 'n9 n9)) (lambda () w))) -100)
  )

  (test-case "range proof: filterCheck never exceeds bounds"
  ; property: every filtered element is in 0..100
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (<= (raw-value n) 100)) (check-true (let/check ([tesl_checked_59 (checkRange n)]) (let ([validated tesl_checked_59]) (and (>= (raw-value (requiresRange validated)) 1) (<= (raw-value (requiresRange validated)) 101)))) "every filtered element is in 0..100"))
    ))
  )

  (test-case "at-least-five proof invariant"
  ; property: checkAtLeastFive succeeds for >= 5
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 5) (< (raw-value n) 1000)) (check-true (let/check ([tesl_checked_60 (checkAtLeastFive n)]) (let ([v tesl_checked_60]) (>= (raw-value v) 5))) "checkAtLeastFive succeeds for >= 5"))
    ))
  )

  (test-case "non-empty length invariant"
  ; property: checkNonEmpty preserves length
  (for ([tesl-prop-i (in-range 100)])
    (let ([s (format "s~a" (random 1000000))])
      (when (> (raw-value (tesl_import_String_length (raw-value s))) 0) (check-true (let/check ([tesl_checked_61 (checkNonEmpty s)]) (let ([v tesl_checked_61]) (equal? (raw-value (requiresNonEmpty v)) (raw-value (tesl_import_String_length (raw-value s)))))) "checkNonEmpty preserves length"))
    ))
  )

  (test-case "case guard routing"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 870 (list) (lambda () (classifyThreshold (Low -5))))) "low-negative")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 871 (list) (lambda () (classifyThreshold (Low 0))))) "low-nonneg")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 872 (list) (lambda () (classifyThreshold (Low 10))))) "low-nonneg")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 873 (list) (lambda () (classifyThreshold (Mid 51))))) "mid-high")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 874 (list) (lambda () (classifyThreshold (Mid 50))))) "mid-low")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 875 (list) (lambda () (classifyThreshold (Mid 0))))) "mid-low")
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 876 (list) (lambda () (classifyThreshold (High 999))))) "high")
  )

  (test-case "countItems via foldl"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 890 (list) (lambda () (countItems (list))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 891 (list) (lambda () (countItems (list 1))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 892 (list) (lambda () (countItems (list 1 2 3 4 5))))) 5)
  )

  (test-case "sumSquares via foldl"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 896 (list) (lambda () (sumSquares (list))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 897 (list) (lambda () (sumSquares (list 1 2 3))))) 14)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 898 (list) (lambda () (sumSquares (list 0 0 0))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 899 (list) (lambda () (sumSquares (list 3 4))))) 25)
  )

  (test-case "bounded: boundary values accepted"
  (define n1 (thsl-src! "tests/adversarial-review-tests.tesl" 923 (list) (lambda () 1)))
  (define tesl_checked_62 (checkBounded n1))
  (when (check-fail? tesl_checked_62)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_62)))
  (define v1 tesl_checked_62)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 925 (list (cons 'v1 v1) (cons 'n1 n1)) (lambda () (requiresBounded v1)))) 2)
  (define n999 (thsl-src! "tests/adversarial-review-tests.tesl" 926 (list (cons 'v1 v1) (cons 'n1 n1)) (lambda () 999)))
  (define tesl_checked_63 (checkBounded n999))
  (when (check-fail? tesl_checked_63)
    (raise-user-error 'tesl-test "unexpected failure in let v999: ~a" (check-fail-message tesl_checked_63)))
  (define v999 tesl_checked_63)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 928 (list (cons 'v999 v999) (cons 'n999 n999) (cons 'v1 v1) (cons 'n1 n1)) (lambda () (requiresBounded v999)))) 1998)
  )

  (test-case "bounded: out-of-range rejected"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 932 (list) (lambda ()
                          (checkBounded 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBounded 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 933 (list) (lambda ()
                          (checkBounded 1000))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBounded 1000"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 934 (list) (lambda ()
                          (checkBounded -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBounded -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 935 (list) (lambda ()
                          (checkBounded 9999))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBounded 9999"))
  )

  (test-case "bounded: midpoint accepted"
  (define n500 (thsl-src! "tests/adversarial-review-tests.tesl" 939 (list) (lambda () 500)))
  (define tesl_checked_64 (checkBounded n500))
  (when (check-fail? tesl_checked_64)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_64)))
  (define v tesl_checked_64)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 941 (list (cons 'v v) (cons 'n500 n500)) (lambda () (requiresBounded v)))) 1000)
  )

  (test-case "pos+small: only values in (0,100) pass"
  (define n1 (thsl-src! "tests/adversarial-review-tests.tesl" 977 (list) (lambda () 1)))
  (define v1 (thsl-src! "tests/adversarial-review-tests.tesl" 978 (list (cons 'n1 n1)) (lambda () (checkPosAndSmall n1))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 979 (list (cons 'v1 v1) (cons 'n1 n1)) (lambda () (requiresPosAndSmall v1)))) 1)
  (define n99 (thsl-src! "tests/adversarial-review-tests.tesl" 980 (list (cons 'v1 v1) (cons 'n1 n1)) (lambda () 99)))
  (define v99 (thsl-src! "tests/adversarial-review-tests.tesl" 981 (list (cons 'n99 n99) (cons 'v1 v1) (cons 'n1 n1)) (lambda () (checkPosAndSmall n99))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 982 (list (cons 'v99 v99) (cons 'n99 n99) (cons 'v1 v1) (cons 'n1 n1)) (lambda () (requiresPosAndSmall v99)))) 99)
  (define tesl_proof_bind_65 (checkPosAndSmallAndSidecar1 n99 n1))
  (when (check-fail? tesl_proof_bind_65)
    (raise-user-error 'tesl-test "unexpected failure in let-proof: ~a" (check-fail-message tesl_proof_bind_65)))
  (define tesl_ignored_66 (forget-proof tesl_proof_bind_65))
  (define n1_p1 (detach-all-proof tesl_proof_bind_65))
  (define tesl_proof_bind_67 (checkPosAndSmallAndSidecar2_shouldWork n99 n1))
  (when (check-fail? tesl_proof_bind_67)
    (raise-user-error 'tesl-test "unexpected failure in let-proof: ~a" (check-fail-message tesl_proof_bind_67)))
  (define tesl_ignored_68 (forget-proof tesl_proof_bind_67))
  (define n1_p2 (detach-all-proof tesl_proof_bind_67))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 986 (list (cons '_ _) (cons '_ _) (cons 'v99 v99) (cons 'n99 n99) (cons 'v1 v1) (cons 'n1 n1)) (lambda () (requiresPosAndSmall (attach-proof n1 (list n1_p1 n1_p2)))))) 1)
  (define tesl_proof_bind_69 (checkPosAndSmallAndSidecar1 n99 n1))
  (when (check-fail? tesl_proof_bind_69)
    (raise-user-error 'tesl-test "unexpected failure in let-proof: ~a" (check-fail-message tesl_proof_bind_69)))
  (define int1 (forget-proof tesl_proof_bind_69))
  (define posP (detach-all-proof tesl_proof_bind_69))
  (define smallP (detach-all-proof tesl_proof_bind_69))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 989 (list (cons 'int1 int1) (cons '_ _) (cons '_ _) (cons 'v99 v99) (cons 'n99 n99) (cons 'v1 v1) (cons 'n1 n1)) (lambda () (requiresPosAndSmall (attach-proof int1 (list posP smallP)))))) 99)
  )

  (test-case "pos+small: zero fails (not positive)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1001 (list) (lambda ()
                          (checkPosAndSmall 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall 0"))
  )

  (test-case "pos+small: 100 fails (not small)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1005 (list) (lambda ()
                          (checkPosAndSmall 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall 100"))
  )

  (test-case "pos+small: negative fails (not positive)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1009 (list) (lambda ()
                          (checkPosAndSmall -5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall -5"))
  )

  (test-case "TaggedInt round-trips"
  (define t (thsl-src! "tests/adversarial-review-tests.tesl" 1024 (list) (lambda () (makeTagged 42))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1025 (list (cons 't t)) (lambda () (requiresTagged t)))) 42)
  (define t2 (thsl-src! "tests/adversarial-review-tests.tesl" 1026 (list (cons 't t)) (lambda () (makeTagged 0))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1027 (list (cons 't2 t2) (cons 't t)) (lambda () (requiresTagged t2)))) 0)
  (define t3 (thsl-src! "tests/adversarial-review-tests.tesl" 1028 (list (cons 't2 t2) (cons 't t)) (lambda () (makeTagged -7))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1029 (list (cons 't3 t3) (cons 't2 t2) (cons 't t)) (lambda () (requiresTagged t3)))) -7)
  )

  (test-case "TaggedInt from large value"
  (define t (thsl-src! "tests/adversarial-review-tests.tesl" 1033 (list) (lambda () (makeTagged 2147483647))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1034 (list (cons 't t)) (lambda () (requiresTagged t)))) 2147483647)
  )

  (test-case "ascii check accepts non-empty strings"
  (define s1 (thsl-src! "tests/adversarial-review-tests.tesl" 1053 (list) (lambda () "hello")))
  (define tesl_checked_70 (checkAscii s1))
  (when (check-fail? tesl_checked_70)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_70)))
  (define v1 tesl_checked_70)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1055 (list (cons 'v1 v1) (cons 's1 s1)) (lambda () (requiresAscii v1)))) 5)
  (define s2 (thsl-src! "tests/adversarial-review-tests.tesl" 1056 (list (cons 'v1 v1) (cons 's1 s1)) (lambda () "a")))
  (define tesl_checked_71 (checkAscii s2))
  (when (check-fail? tesl_checked_71)
    (raise-user-error 'tesl-test "unexpected failure in let v2: ~a" (check-fail-message tesl_checked_71)))
  (define v2 tesl_checked_71)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1058 (list (cons 'v2 v2) (cons 's2 s2) (cons 'v1 v1) (cons 's1 s1)) (lambda () (requiresAscii v2)))) 1)
  )

  (test-case "ascii check rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1062 (list) (lambda ()
                          (checkAscii ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkAscii \"\""))
  )

  (test-case "proof survives fn wrapper"
  (define n5 (thsl-src! "tests/adversarial-review-tests.tesl" 1074 (list) (lambda () 5)))
  (define tesl_checked_72 (checkPositiveMsg n5))
  (when (check-fail? tesl_checked_72)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_72)))
  (define v tesl_checked_72)
  (define tesl_checked_73 (checkBounded v))
  (when (check-fail? tesl_checked_73)
    (raise-user-error 'tesl-test "unexpected failure in let vb: ~a" (check-fail-message tesl_checked_73)))
  (define vb tesl_checked_73)
  (define w (thsl-src! "tests/adversarial-review-tests.tesl" 1077 (list (cons 'vb vb) (cons 'v v) (cons 'n5 n5)) (lambda () (requiresBounded vb))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1078 (list (cons 'w w) (cons 'vb vb) (cons 'v v) (cons 'n5 n5)) (lambda () w))) 10)
  )

  (test-case "fn wrapper rejects bad input"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1082 (list) (lambda ()
                          (checkPositiveMsg 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositiveMsg 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1083 (list) (lambda ()
                          (checkPositiveMsg -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositiveMsg -1"))
  )

  (test-case "detach-reattach round-trip"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1100 (list) (lambda () (wrapAndUnwrap 5)))) 10)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1101 (list) (lambda () (wrapAndUnwrap 1)))) 2)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1102 (list) (lambda () (wrapAndUnwrap 99)))) 198)
  )

  (test-case "detach-reattach fails on non-positive input"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1106 (list) (lambda ()
                          (wrapAndUnwrap 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapAndUnwrap 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1107 (list) (lambda ()
                          (wrapAndUnwrap -10))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapAndUnwrap -10"))
  )

  (test-case "safe reciprocal of 2.0"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1122 (list) (lambda () (safeRecip 2.)))) 0.5)
  )

  (test-case "safe reciprocal of -4.0"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1126 (list) (lambda () (safeRecip -4.)))) (- 0.25))
  )

  (test-case "safe reciprocal rejects 0.0"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1130 (list) (lambda ()
                          (safeRecip 0.))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: safeRecip 0."))
  )

  (test-case "safeSqrt of 0.0"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1134 (list) (lambda () (safeSqrt 0.)))) 0.)
  )

  (test-case "safeSqrt of negative (uses abs)"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1138 (list) (lambda () (safeSqrt -9.)))) 3.)
  )

  (test-case "slug: accepts short non-empty string"
  (define s1 (thsl-src! "tests/adversarial-review-tests.tesl" 1160 (list) (lambda () "my-slug")))
  (define tesl_checked_74 (checkSlug s1))
  (when (check-fail? tesl_checked_74)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_74)))
  (define v1 tesl_checked_74)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1162 (list (cons 'v1 v1) (cons 's1 s1)) (lambda () (requiresSlug v1)))) 7)
  (define s2 (thsl-src! "tests/adversarial-review-tests.tesl" 1163 (list (cons 'v1 v1) (cons 's1 s1)) (lambda () "a")))
  (define tesl_checked_75 (checkSlug s2))
  (when (check-fail? tesl_checked_75)
    (raise-user-error 'tesl-test "unexpected failure in let v2: ~a" (check-fail-message tesl_checked_75)))
  (define v2 tesl_checked_75)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1165 (list (cons 'v2 v2) (cons 's2 s2) (cons 'v1 v1) (cons 's1 s1)) (lambda () (requiresSlug v2)))) 1)
  )

  (test-case "slug: rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1169 (list) (lambda ()
                          (checkSlug ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSlug \"\""))
  )

  (test-case "slug: accepts exactly 64 chars"
  (define s64 (thsl-src! "tests/adversarial-review-tests.tesl" 1173 (list) (lambda () "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
  (define tesl_checked_76 (checkSlug s64))
  (when (check-fail? tesl_checked_76)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_76)))
  (define v tesl_checked_76)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1175 (list (cons 'v v) (cons 's64 s64)) (lambda () (requiresSlug v)))) 64)
  )

  (test-case "slug: rejects 65 chars"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1179 (list) (lambda ()
                          (checkSlug "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSlug \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""))
  )

  (test-case "identityProof preserves InRange"
  (define n50 (thsl-src! "tests/adversarial-review-tests.tesl" 1190 (list) (lambda () 50)))
  (define tesl_checked_77 (checkRange n50))
  (when (check-fail? tesl_checked_77)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_77)))
  (define v tesl_checked_77)
  (define out (thsl-src! "tests/adversarial-review-tests.tesl" 1192 (list (cons 'v v) (cons 'n50 n50)) (lambda () (identityProof v))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1193 (list (cons 'out out) (cons 'v v) (cons 'n50 n50)) (lambda () (requiresRange out)))) 51)
  )

  (test-case "nonNegStr: all strings have non-negative length"
  (define s1 (thsl-src! "tests/adversarial-review-tests.tesl" 1211 (list) (lambda () "")))
  (define tesl_checked_78 (checkNonNegStr s1))
  (when (check-fail? tesl_checked_78)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl_checked_78)))
  (define v1 tesl_checked_78)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1213 (list (cons 'v1 v1) (cons 's1 s1)) (lambda () (requiresNonNegStr v1)))) 0)
  (define s2 (thsl-src! "tests/adversarial-review-tests.tesl" 1214 (list (cons 'v1 v1) (cons 's1 s1)) (lambda () "hello world")))
  (define tesl_checked_79 (checkNonNegStr s2))
  (when (check-fail? tesl_checked_79)
    (raise-user-error 'tesl-test "unexpected failure in let v2: ~a" (check-fail-message tesl_checked_79)))
  (define v2 tesl_checked_79)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1216 (list (cons 'v2 v2) (cons 's2 s2) (cons 'v1 v1) (cons 's1 s1)) (lambda () (requiresNonNegStr v2)))) 11)
  )

  (test-case "tree depth: leaf"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1239 (list) (lambda () (treeDepth Leaf)))) 0)
  )

  (test-case "tree depth: single node"
  (define t (thsl-src! "tests/adversarial-review-tests.tesl" 1243 (list) (lambda () (raw-value (Node Leaf 42 Leaf)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1244 (list (cons 't t)) (lambda () (treeDepth t)))) 1)
  )

  (test-case "tree depth: balanced depth-2 tree"
  (define t (thsl-src! "tests/adversarial-review-tests.tesl" 1248 (list) (lambda () (raw-value (Node (Node Leaf 1 Leaf) 2 (Node Leaf 3 Leaf))))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1249 (list (cons 't t)) (lambda () (treeDepth t)))) 2)
  )

  (test-case "tree depth: right-skewed depth-3"
  (define t (thsl-src! "tests/adversarial-review-tests.tesl" 1253 (list) (lambda () (raw-value (Node Leaf 1 (Node Leaf 2 (Node Leaf 3 Leaf)))))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1254 (list (cons 't t)) (lambda () (treeDepth t)))) 3)
  )

  (test-case "tree depth: left-heavy"
  (define t (thsl-src! "tests/adversarial-review-tests.tesl" 1258 (list) (lambda () (raw-value (Node (Node (Node Leaf 1 Leaf) 2 Leaf) 3 Leaf)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1259 (list (cons 't t)) (lambda () (treeDepth t)))) 3)
  )

  (test-case "factorial base cases"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1283 (list) (lambda () (factorial 0)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1284 (list) (lambda () (factorial 1)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1285 (list) (lambda () (factorial -5)))) 1)
  )

  (test-case "factorial small values"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1289 (list) (lambda () (factorial 2)))) 2)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1290 (list) (lambda () (factorial 3)))) 6)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1291 (list) (lambda () (factorial 4)))) 24)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1292 (list) (lambda () (factorial 5)))) 120)
  )

  (test-case "fibonacci base cases"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1296 (list) (lambda () (fibonacci 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1297 (list) (lambda () (fibonacci 1)))) 1)
  )

  (test-case "fibonacci small values"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1301 (list) (lambda () (fibonacci 2)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1302 (list) (lambda () (fibonacci 3)))) 2)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1303 (list) (lambda () (fibonacci 4)))) 3)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1304 (list) (lambda () (fibonacci 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1305 (list) (lambda () (fibonacci 6)))) 8)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1306 (list) (lambda () (fibonacci 10)))) 55)
  )

  (test-case "conjunct both pass: 1"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1320 (list) (lambda () (conjunctSatisfied 1)))) "done")
  )

  (test-case "conjunct both pass: 50"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1324 (list) (lambda () (conjunctSatisfied 50)))) "done")
  )

  (test-case "conjunct fails: 0 (not positive)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1328 (list) (lambda ()
                          (conjunctSatisfied 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: conjunctSatisfied 0"))
  )

  (test-case "conjunct fails: 100 (not small)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1332 (list) (lambda ()
                          (conjunctSatisfied 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: conjunctSatisfied 100"))
  )

  (test-case "foldl sum is commutative for pairs"
  (define xs1 (thsl-src! "tests/adversarial-review-tests.tesl" 1344 (list) (lambda () (list 1 2 3 4 5))))
  (define xs2 (thsl-src! "tests/adversarial-review-tests.tesl" 1345 (list (cons 'xs1 xs1)) (lambda () (list 5 4 3 2 1))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1346 (list (cons 'xs2 xs2) (cons 'xs1 xs1)) (lambda () (sumList2 xs1)))) (sumList2 xs2))
  )

  (test-case "foldl sum of singleton is identity"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1350 (list) (lambda () (sumList2 (list 42))))) 42)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1351 (list) (lambda () (sumList2 (list -7))))) -7)
  )

  (test-case "foldl sum with 50 random"
  ; property: sum ≥ min
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 1) (<= (raw-value n) 1000)) (check-true (>= (raw-value (sumList2 (list n))) 1) "sum \226\137\165 min"))
    ))
  )

  (test-case "toUpper preserves length on ASCII"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1371 (list) (lambda () (upperLengthPreserved "hello")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1372 (list) (lambda () (upperLengthPreserved "")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1373 (list) (lambda () (upperLengthPreserved "HELLO WORLD")))) #t)
  )

  (test-case "toLower preserves length on ASCII"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1377 (list) (lambda () (lowerLengthPreserved "HELLO")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1378 (list) (lambda () (lowerLengthPreserved "mixed Case String")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1379 (list) (lambda () (lowerLengthPreserved "")))) #t)
  )

  (test-case "filter idempotence: empty list"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1394 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (filterPositiveTwice (list)))))))) 0)
  )

  (test-case "filter idempotence: all positive"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1398 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (filterPositiveTwice (list 1 2 3)))))))) (raw-value (tesl_import_List_length (raw-value (filterPositiveOnce (list 1 2 3))))))
  )

  (test-case "filter idempotence: mixed"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1402 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (filterPositiveTwice (list 1 -2 3 -4 5)))))))) (raw-value (tesl_import_List_length (raw-value (filterPositiveOnce (list 1 -2 3 -4 5))))))
  )

  (test-case "inBounds: all values between lo and hi pass"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1436 (list) (lambda () (checkInBounds1020 15)))) "15 is in [10, 20]")
  )

  (test-case "inBounds: lo == hi is a valid range"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1440 (list) (lambda () (checkInBoundsEqual 5)))) "5 is in [5, 5]")
  )

  (test-case "inBounds: negative range works"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1444 (list) (lambda () (checkInBoundsNeg -5)))) "-5 is in [-10, -1]")
  )

  (test-case "inBounds: value at lo boundary"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1448 (list) (lambda () (checkInBoundsLo 0)))) "0 is in [0, 100]")
  )

  (test-case "inBounds: value just below lo fails"
  (define lo (thsl-src! "tests/adversarial-review-tests.tesl" 1452 (list) (lambda () 5)))
  (define hi (thsl-src! "tests/adversarial-review-tests.tesl" 1453 (list (cons 'lo lo)) (lambda () 15)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1454 (list (cons 'hi hi) (cons 'lo lo)) (lambda ()
                          (checkInBounds lo hi 4))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInBounds lo hi 4"))
  )

  (test-case "parseAndValidate: short non-empty string"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1471 (list) (lambda () (parseAndValidate "hi")))) (raw-value (Right 2)))
  )

  (test-case "parseAndValidate: exactly 9 chars"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1475 (list) (lambda () (parseAndValidate "123456789")))) (raw-value (Right 9)))
  )

  (test-case "parseAndValidate: 10 chars rejected as too long"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1479 (list) (lambda () (parseAndValidate "1234567890")))) (raw-value (Left "too long")))
  )

  (test-case "parseAndValidate: empty string fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1484 (list) (lambda ()
                          (parseAndValidate ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: parseAndValidate \"\""))
  )

  (test-case "eval: neg of neg"
  (define e (thsl-src! "tests/adversarial-review-tests.tesl" 1501 (list) (lambda () (raw-value (Neg (Neg (Lit 5)))))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1502 (list (cons 'e e)) (lambda () (evalNested e)))) 5)
  )

  (test-case "eval: (2 + 3) * (4 + 1)"
  (define e (thsl-src! "tests/adversarial-review-tests.tesl" 1506 (list) (lambda () (raw-value (Mul (Add (Lit 2) (Lit 3)) (Add (Lit 4) (Lit 1)))))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1507 (list (cons 'e e)) (lambda () (evalNested e)))) 25)
  )

  (test-case "eval: deeply nested add"
  (define e (thsl-src! "tests/adversarial-review-tests.tesl" 1511 (list) (lambda () (raw-value (Add (Add (Add (Lit 1) (Lit 2)) (Lit 3)) (Lit 4))))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1512 (list (cons 'e e)) (lambda () (evalNested e)))) 10)
  )

  (test-case "eval: multiply by zero"
  (define e (thsl-src! "tests/adversarial-review-tests.tesl" 1516 (list) (lambda () (raw-value (Mul (Lit 0) (Add (Lit 100) (Lit 200)))))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1517 (list (cons 'e e)) (lambda () (evalNested e)))) 0)
  )

  (test-case "proof independence: both positive, both in bounds"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1539 (list) (lambda () (proofIndependenceCorrect 5 10)))) 30)
  )

  (test-case "proof independence: first fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1543 (list) (lambda ()
                          (proofIndependenceCorrect 0 5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofIndependenceCorrect 0 5"))
  )

  (test-case "proof independence: second fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1547 (list) (lambda ()
                          (proofIndependenceCorrect 5 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofIndependenceCorrect 5 0"))
  )

  (test-case "proof independence: first out of bounds"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1551 (list) (lambda ()
                          (proofIndependenceCorrect 1000 5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofIndependenceCorrect 1000 5"))
  )

  (test-case "proof independence: both out of bounds"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1555 (list) (lambda ()
                          (proofIndependenceCorrect 1000 2000))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofIndependenceCorrect 1000 2000"))
  )

  (test-case "Bug1: maxRec returns larger of two, first larger"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1573 (list) (lambda () (maxRec 5 3)))) 5)
  )

  (test-case "Bug1: maxRec returns larger of two, second larger"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1577 (list) (lambda () (maxRec 2 9)))) 9)
  )

  (test-case "Bug1: maxRec with equal values"
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1581 (list) (lambda () (maxRec 7 7)))) 7)
  )

  (test-case "Bug1: maxRec with negative numbers"
  (define a (thsl-src! "tests/adversarial-review-tests.tesl" 1585 (list) (lambda () -3)))
  (define b (thsl-src! "tests/adversarial-review-tests.tesl" 1586 (list (cons 'a a)) (lambda () -1)))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1587 (list (cons 'b b) (cons 'a a)) (lambda () (maxRec a b)))) b)
  )

  (test-case "Bug2: fn wrapping check passes for valid value"
  (define n (thsl-src! "tests/adversarial-review-tests.tesl" 1605 (list) (lambda () 42)))
  (define v (thsl-src! "tests/adversarial-review-tests.tesl" 1606 (list (cons 'n n)) (lambda () (fnWrapsCheck n))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1607 (list (cons 'v v) (cons 'n n)) (lambda () #t))) #t)
  )

  (test-case "Bug2: fn wrapping check fails for invalid value"
  (define n (thsl-src! "tests/adversarial-review-tests.tesl" 1611 (list) (lambda () 0)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1612 (list (cons 'n n)) (lambda ()
                          (fnWrapsCheck n))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: fnWrapsCheck n"))
  )

  (test-case "Bug2: fn wrapping check fails for out-of-range value"
  (define n (thsl-src! "tests/adversarial-review-tests.tesl" 1616 (list) (lambda () 100)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/adversarial-review-tests.tesl" 1617 (list (cons 'n n)) (lambda ()
                          (fnWrapsCheck n))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: fnWrapsCheck n"))
  )

  (test-case "Bug7: filterCheck result satisfies ForAll Positive"
  (define result (thsl-src! "tests/adversarial-review-tests.tesl" 1635 (list) (lambda () (filteredPositives (list 1 2 3 -1 -2)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1636 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
  )

  (test-case "Bug7: filterCheck all positive"
  (define result (thsl-src! "tests/adversarial-review-tests.tesl" 1640 (list) (lambda () (filteredPositives (list 10 20 30)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1641 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
  )

  (test-case "Bug7: filterCheck all negative gives empty list"
  (define result (thsl-src! "tests/adversarial-review-tests.tesl" 1645 (list) (lambda () (filteredPositives (list -1 -2 -3)))))
  (check-equal? (raw-value (thsl-src! "tests/adversarial-review-tests.tesl" 1646 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 0)
  )

)
