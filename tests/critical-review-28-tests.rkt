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
  (only-in tesl/tesl/prelude Bool Int List String Fact forgetFact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.trim tesl_import_String_trim] [String.contains tesl_import_String_contains] [String.isEmpty tesl_import_String_isEmpty] [String.toUpper tesl_import_String_toUpper] [String.toLower tesl_import_String_toLower] [String.startsWith tesl_import_String_startsWith] [String.endsWith tesl_import_String_endsWith] [String.split tesl_import_String_split] [String.join tesl_import_String_join] [String.replace tesl_import_String_replace])
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.sort tesl_import_List_sort] [List.length tesl_import_List_length] [List.any tesl_import_List_any] [List.all tesl_import_List_all] [List.head tesl_import_List_head] [List.contains tesl_import_List_contains] [List.find tesl_import_List_find] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop] [List.sum tesl_import_List_sum] [List.product tesl_import_List_product] [List.reverse tesl_import_List_reverse] [List.unique tesl_import_List_unique] [List.append tesl_import_List_append])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide] IsNonZero [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/either Either Left Right [Either.map tesl_import_Either_map] [Either.andThen tesl_import_Either_andThen] [Either.withDefault tesl_import_Either_withDefault])
  (only-in tesl/tesl/float Float [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero [Float.div tesl_import_Float_div] [Float.sqrt tesl_import_Float_sqrt])
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
)


(provide checkRange28 requiresRange28 proofRoundTrip IsShort28 checkNonEmpty28 checkShort28 requiresNonEmpty28 combinedCheck28 ProjectId28 makeUser28 makeProject28 requiresUser28 requiresProject28 checkEmail28 proofForgotten28 checkEven28 doubleEven28 doubleAllEven28 interpolateNeg28 treeSum28 treeHeight28 multiply28 doubleAll28 checkBounded28 requiresBounded28 wrapBounded28 classifyDay28 Category28 Fruit28 Vegetable28 Dairy28 Meat28 Grain28 describeCategory28 proveSmall28 applySmall28 IsLong28 checkTrimmed28 checkLong28 validateTrimmedLong28 safeHead28 nestedMaybeCheck28 maxSafeInt28 divOrError28 listSumReverseSame28 checkRange28-signature requiresRange28-signature proofRoundTrip-signature checkNonEmpty28-signature checkShort28-signature requiresNonEmpty28-signature combinedCheck28-signature makeUser28-signature makeProject28-signature requiresUser28-signature requiresProject28-signature checkEmail28-signature proofForgotten28-signature checkEven28-signature doubleEven28-signature doubleAllEven28-signature interpolateNeg28-signature treeSum28-signature treeHeight28-signature multiply28-signature doubleAll28-signature checkBounded28-signature requiresBounded28-signature wrapBounded28-signature classifyDay28-signature describeCategory28-signature proveSmall28-signature applySmall28-signature checkTrimmed28-signature checkLong28-signature validateTrimmedLong28-signature safeHead28-signature nestedMaybeCheck28-signature maxSafeInt28-signature divOrError28-signature listSumReverseSame28-signature)

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
  (thsl-src! "tests/critical-review-28-tests.tesl" 137 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 1000)) (accept (IsRange28 n) #:value *n) (reject "out of 0\u20131000 range" #:http-code 400)))))

(define/pow
  (requiresRange28 [n : Integer ::: (IsRange28 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 142 (list (cons 'n *n)) (lambda () (+ *n 1))))

(define/pow
  (proofRoundTrip [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 145 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkRange28 raw)]) (let ([v tesl-checked-0]) (raw-value (requiresRange28 v)))))))

(define-checker
  (checkNonEmpty28 [s : String])
  #:returns [s : String ::: (IsNonEmpty28 s)]
  (thsl-src! "tests/critical-review-28-tests.tesl" 172 (list (cons 's *s)) (lambda () (if (tesl_import_String_isEmpty *s) (reject "empty" #:http-code 400) (accept (IsNonEmpty28 s) #:value *s)))))

(define-checker
  (checkShort28 [s : String ::: (IsNonEmpty28 s)])
  #:returns [s : String ::: (IsShort28 s)]
  (thsl-src! "tests/critical-review-28-tests.tesl" 178 (list (cons 's *s)) (lambda () (if (<= (raw-value (tesl_import_String_length *s)) 50) (accept (IsShort28 s) #:value *s) (reject "too long" #:http-code 400)))))

(define/pow
  (requiresNonEmpty28 [s : String ::: (IsNonEmpty28 s)])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 184 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define/pow
  (requiresBothProofs28 [s : String ::: (IsNonEmpty28 s)] [s2 : String ::: (IsShort28 s2)])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 187 (list (cons 's *s) (cons 's2 *s2)) (lambda () (format "~a / ~a" (tesl-display-val *s) (tesl-display-val *s2)))))

(define/pow
  (combinedCheck28 [raw : String])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 190 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-1 (checkNonEmpty28 raw)]) (let ([ne tesl-checked-1]) (let/check ([tesl-checked-2 (checkShort28 ne)]) (let ([short tesl-checked-2]) (raw-value (requiresBothProofs28 short short)))))))))

(define-newtype UserId28 String)

(define-newtype ProjectId28 String)

(define/pow
  (makeUser28 [s : String])
  #:returns UserId28
  (thsl-src! "tests/critical-review-28-tests.tesl" 213 (list (cons 's *s)) (lambda () (raw-value (UserId28 *s)))))

(define/pow
  (makeProject28 [s : String])
  #:returns ProjectId28
  (thsl-src! "tests/critical-review-28-tests.tesl" 214 (list (cons 's *s)) (lambda () (raw-value (ProjectId28 *s)))))

(define/pow
  (requiresUser28 [uid : UserId28])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 215 (list (cons 'uid *uid)) (lambda () (format "user:~a" (tesl-display-val (raw-value uid.value))))))

(define/pow
  (requiresProject28 [pid : ProjectId28])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 216 (list (cons 'pid *pid)) (lambda () (format "project:~a" (tesl-display-val (raw-value pid.value))))))

(define/pow
  (boolToString28 [b : Boolean])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 247 (list (cons 'b *b)) (lambda () (if *b (raw-value "true") (raw-value "false")))))

(define-checker
  (checkEmail28 [email : String])
  #:returns [email : String ::: (IsValidEmail28 email)]
  (thsl-src! "tests/critical-review-28-tests.tesl" 275 (list (cons 'email *email)) (lambda () (if (and (raw-value (tesl_import_String_contains *email "@")) (>= (raw-value (tesl_import_String_length *email)) 3)) (accept (IsValidEmail28 email) #:value *email) (reject "invalid email" #:http-code 400)))))

(define/pow
  (proofForgotten28 [raw : String])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 281 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-3 (checkEmail28 raw)]) (let ([valid tesl-checked-3]) (let ([raw2 (forget-proof valid)]) (raw-value (tesl_import_String_length (raw-value raw2)))))))))

(define-checker
  (checkEven28 [n : Integer])
  #:returns [n : Integer ::: (IsEven28 n)]
  (thsl-src! "tests/critical-review-28-tests.tesl" 308 (list (cons 'n *n)) (lambda () (if (tesl-equal? (remainder *n 2) 0) (accept (IsEven28 n) #:value *n) (reject "not even" #:http-code 400)))))

(define/pow
  (doubleEven28 [n : Integer ::: (IsEven28 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 313 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (doubleAllEven28 [xs : (List Integer)])
  #:returns (List Integer)
  (let ([evens (thsl-src! "tests/critical-review-28-tests.tesl" 316 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkEven28 *xs)))]) (thsl-src! "tests/critical-review-28-tests.tesl" 317 (list (cons 'evens *evens) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-4 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsEven28 ,n))]) (doubleEven28 n))) tesl-lambda-4) (raw-value evens)))))))

(define/pow
  (interpolateInt28 [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 347 (list (cons 'n *n)) (lambda () (format "n=~a" (tesl-display-val *n)))))

(define/pow
  (interpolateNeg28 [a : Integer] [b : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 348 (list (cons 'a *a) (cons 'b *b)) (lambda () (format "diff=~a" (tesl-display-val (- *a *b))))))

(define-adt BinTree28
  [Leaf28]
  [Node28 [left : BinTree28] [value : Integer] [right : BinTree28]]
)

(define/pow
  (treeSum28 [t : BinTree28])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-28-tests.tesl" 387 (list (cons 't *t)) (lambda () (let ([tesl-case-5 *t]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Leaf28)) (thsl-src! "tests/critical-review-28-tests.tesl" 388 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Node28)) (let ([left (hash-ref (adt-value-fields *tesl-case-5) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl-case-5) 'right)]) (thsl-src! "tests/critical-review-28-tests.tesl" 389 (list (cons 'left left) (cons 'v v) (cons 'right right)) (lambda () (raw-value (+ (+ (raw-value (treeSum28 *left)) *v) (raw-value (treeSum28 *right)))))))))])))))

(define/pow
  (treeHeight28 [t : BinTree28])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-28-tests.tesl" 392 (list (cons 't *t)) (lambda () (let ([tesl-case-6 *t]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Leaf28)) (thsl-src! "tests/critical-review-28-tests.tesl" 393 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Node28)) (let ([left (hash-ref (adt-value-fields *tesl-case-6) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl-case-6) 'right)]) (thsl-src! "tests/critical-review-28-tests.tesl" 395 (list (cons 'left left) (cons 'right right)) (lambda () (let ([lh (treeHeight28 *left)]) (let ([rh (treeHeight28 *right)]) (if (> (raw-value lh) (raw-value rh)) (raw-value (+ (raw-value lh) 1)) (raw-value (+ (raw-value rh) 1)))))))))])))))

(define/pow
  (add28 [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 441 (list (cons 'x *x) (cons 'y *y)) (lambda () (+ *x *y))))

(define/pow
  (multiply28 [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 442 (list (cons 'x *x) (cons 'y *y)) (lambda () (* *x *y))))

(define/pow
  (doubleAll28 [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-28-tests.tesl" 443 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (raw-value (lambda (tesl-p-7-0) (multiply28 2 tesl-p-7-0))) *xs)))))

(define-checker
  (checkBounded28 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (Bounded28 lo hi n)]
  (thsl-src! "tests/critical-review-28-tests.tesl" 474 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (>= *n *lo) (<= *n *hi)) (accept (Bounded28 lo hi n) #:value *n) (reject "value out of bounds" #:http-code 400)))))

(define/pow
  (requiresBounded28 [lo : Integer] [hi : Integer] [n : Integer ::: (Bounded28 lo hi n)])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 480 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (format "~a in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))))

(define/pow
  (wrapBounded28 [rawLo : Integer] [rawHi : Integer] [raw : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 483 (list (cons 'rawLo *rawLo) (cons 'rawHi *rawHi) (cons 'raw *raw)) (lambda () (let ([lo rawLo]) (let ([hi rawHi]) (let/check ([tesl-checked-8 (checkBounded28 lo hi raw)]) (let ([v tesl-checked-8]) (raw-value (requiresBounded28 lo hi v)))))))))

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
  (thsl-src-control! "tests/critical-review-28-tests.tesl" 525 (list (cons 'day *day)) (lambda () (let ([tesl-case-9 *day]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Saturday28)) (thsl-src! "tests/critical-review-28-tests.tesl" 528 (list) (lambda () (raw-value "weekend")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Sunday28)) (thsl-src! "tests/critical-review-28-tests.tesl" 528 (list) (lambda () (raw-value "weekend")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Monday28)) (thsl-src! "tests/critical-review-28-tests.tesl" 534 (list) (lambda () (raw-value "weekday")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Tuesday28)) (thsl-src! "tests/critical-review-28-tests.tesl" 534 (list) (lambda () (raw-value "weekday")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Wednesday28)) (thsl-src! "tests/critical-review-28-tests.tesl" 534 (list) (lambda () (raw-value "weekday")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Thursday28)) (thsl-src! "tests/critical-review-28-tests.tesl" 534 (list) (lambda () (raw-value "weekday")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Friday28)) (thsl-src! "tests/critical-review-28-tests.tesl" 534 (list) (lambda () (raw-value "weekday")))])))))

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
  (thsl-src-control! "tests/critical-review-28-tests.tesl" 557 (list (cons 'c *c)) (lambda () (let ([tesl-case-10 *c]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Fruit28)) (thsl-src! "tests/critical-review-28-tests.tesl" 560 (list) (lambda () (raw-value "plant")))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Vegetable28)) (thsl-src! "tests/critical-review-28-tests.tesl" 560 (list) (lambda () (raw-value "plant")))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Dairy28)) (thsl-src! "tests/critical-review-28-tests.tesl" 563 (list) (lambda () (raw-value "animal")))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Meat28)) (thsl-src! "tests/critical-review-28-tests.tesl" 563 (list) (lambda () (raw-value "animal")))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Grain28)) (thsl-src! "tests/critical-review-28-tests.tesl" 565 (list) (lambda () (raw-value "starch")))])))))

(define-trusted
  (proveSmall28 [n : Integer])
  #:returns (Maybe (Fact (IsSmall28 n)))
  (thsl-src! "tests/critical-review-28-tests.tesl" 587 (list (cons 'n *n)) (lambda () (if (< *n 10) (Something (trusted-proof (IsSmall28 n))) Nothing))))

(define/pow
  (useSmall28 [n : Integer ::: (IsSmall28 n)])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 592 (list (cons 'n *n)) (lambda () (format "small: ~a" (tesl-display-val *n)))))

(define/pow
  (applySmall28 [n : Integer])
  #:returns String
  (let ([mProof (thsl-src! "tests/critical-review-28-tests.tesl" 595 (list (cons 'n *n)) (lambda () (proveSmall28 n)))]) (thsl-src-control! "tests/critical-review-28-tests.tesl" 596 (list (cons 'mProof *mProof) (cons 'n *n)) (lambda () (let ([tesl-case-11 (raw-value mProof)]) (cond [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Nothing)) (thsl-src! "tests/critical-review-28-tests.tesl" 597 (list) (lambda () (raw-value "not small")))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl-case-11) 'value)]) (thsl-src! "tests/critical-review-28-tests.tesl" 598 (list (cons 'p p)) (lambda () (raw-value (useSmall28 (attach-proof n p))))))]))))))

(define/pow
  (filteredSubset28 [xs : (List Integer)])
  #:returns Boolean
  (thsl-src! "tests/critical-review-28-tests.tesl" 620 (list (cons 'xs *xs)) (lambda () (tesl-equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_List_sort *xs)))) (raw-value (tesl_import_List_length *xs))))))

(define-checker
  (checkTrimmed28 [s : String])
  #:returns [s : String ::: (IsTrimmed28 s)]
  (thsl-src! "tests/critical-review-28-tests.tesl" 656 (list (cons 's *s)) (lambda () (if (tesl-equal? (raw-value (tesl_import_String_trim *s)) *s) (accept (IsTrimmed28 s) #:value *s) (reject "not trimmed" #:http-code 400)))))

(define-checker
  (checkLong28 [s : String ::: (IsTrimmed28 s)])
  #:returns [s : String ::: (IsLong28 s)]
  (thsl-src! "tests/critical-review-28-tests.tesl" 662 (list (cons 's *s)) (lambda () (if (>= (raw-value (tesl_import_String_length *s)) 5) (accept (IsLong28 s) #:value *s) (reject "too short" #:http-code 400)))))

(define/pow
  (requiresTrimmedAndLong28 [s : String ::: (IsTrimmed28 s)] [s2 : String ::: (IsLong28 s2)])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 668 (list (cons 's *s) (cons 's2 *s2)) (lambda () (format "ok: ~a" (tesl-display-val *s)))))

(define/pow
  (validateTrimmedLong28 [raw : String])
  #:returns String
  (thsl-src! "tests/critical-review-28-tests.tesl" 671 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-12 (checkTrimmed28 raw)]) (let ([trimmed tesl-checked-12]) (let/check ([tesl-checked-13 (checkLong28 trimmed)]) (let ([long tesl-checked-13]) (raw-value (requiresTrimmedAndLong28 long long)))))))))

(define/pow
  (safeHead28 [xs : (List Integer)])
  #:returns (Maybe Integer)
  (thsl-src! "tests/critical-review-28-tests.tesl" 696 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_head *xs)))))

(define/pow
  (headOrDefault28 [xs : (List Integer)] [def : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-28-tests.tesl" 699 (list (cons 'xs *xs) (cons 'def *def)) (lambda () (let ([tesl-case-14 (raw-value (safeHead28 xs))]) (cond [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Nothing)) (thsl-src! "tests/critical-review-28-tests.tesl" 700 (list) (lambda () *def))] [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Something)) (let ([h (hash-ref (adt-value-fields *tesl-case-14) 'value)]) (thsl-src! "tests/critical-review-28-tests.tesl" 701 (list (cons 'h h)) (lambda () *h)))])))))

(define/pow
  (nestedMaybeCheck28 [m : (Maybe (Maybe Integer))])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-28-tests.tesl" 704 (list (cons 'm *m)) (lambda () (let ([tesl-case-15 *m]) (cond [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Nothing)) (thsl-src! "tests/critical-review-28-tests.tesl" 705 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Something)) (let ([inner (hash-ref (adt-value-fields *tesl-case-15) 'value)]) (thsl-src! "tests/critical-review-28-tests.tesl" 707 (list (cons 'inner inner)) (lambda () (let ([tesl-case-16 (raw-value inner)]) (cond [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Nothing)) (thsl-src! "tests/critical-review-28-tests.tesl" 708 (list) (lambda () (raw-value -2)))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl-case-16) 'value)]) (thsl-src! "tests/critical-review-28-tests.tesl" 709 (list (cons 'n n)) (lambda () *n)))])))))])))))

(define/pow
  (safeDivide28 [a : Integer] [b : Integer])
  #:returns (Either String Integer)
  (thsl-src! "tests/critical-review-28-tests.tesl" 737 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (tesl-equal? *b 0) (raw-value (raw-value (Left "division by zero"))) (let/check ([tesl-checked-17 (tesl_import_Int_nonZero b)]) (let ([nb tesl-checked-17]) (raw-value (raw-value (Right (tesl_import_Int_divide *a nb))))))))))

(define/pow
  (negArithmetic28 [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 769 (list (cons 'a *a) (cons 'b *b)) (lambda () (- *a *b))))

(define/pow
  (maxSafeInt28)
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 771 (list) (lambda () 4611686018427387903)))

(define/pow
  (swapPair28 [a : Integer] [b : String])
  #:returns (Tuple2 String Integer)
  (thsl-src! "tests/critical-review-28-tests.tesl" 813 (list (cons 'a *a) (cons 'b *b)) (lambda () (raw-value (Tuple2 *b *a)))))

(define/pow
  (roundTripProof28 [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 838 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-18 (checkRange28 n)]) (let ([v tesl-checked-18]) (let ([tesl-proof-binding-19 v]) (let ([raw (forget-proof tesl-proof-binding-19)] [proof (detach-all-proof tesl-proof-binding-19)]) (let ([reattached (attach-proof raw proof)]) (raw-value (requiresRange28 reattached))))))))))

(define/pow
  (forgetAndRaw28 [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review-28-tests.tesl" 844 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-20 (checkRange28 n)]) (let ([v tesl-checked-20]) (let ([forgotten (forget-proof v)]) (let ([tesl-proof-binding-21 v]) (let ([raw (forget-proof tesl-proof-binding-21)] [_proof (detach-all-proof tesl-proof-binding-21)]) (tesl-equal? (raw-value forgotten) (raw-value raw))))))))))

(define/pow
  (allCheckResult28 [xs : (List Integer)])
  #:returns String
  (let ([result (thsl-src! "tests/critical-review-28-tests.tesl" 869 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck checkRange28 *xs)))]) (thsl-src-control! "tests/critical-review-28-tests.tesl" 870 (list (cons 'result *result) (cons 'xs *xs)) (lambda () (let ([tesl-case-22 (raw-value result)]) (cond [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Nothing)) (thsl-src! "tests/critical-review-28-tests.tesl" 871 (list) (lambda () (raw-value "failed")))] [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Something)) (thsl-src! "tests/critical-review-28-tests.tesl" 872 (list) (lambda () (raw-value "ok")))]))))))

(define/pow
  (safeFloatDiv28 [a : Real] [b : Real])
  #:returns (Either String Real)
  (thsl-src! "tests/critical-review-28-tests.tesl" 894 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (tesl-equal? *b 0.) (raw-value (raw-value (Left "zero"))) (let/check ([tesl-checked-23 (tesl_import_Float_requireNonZero b)]) (let ([nb tesl-checked-23]) (raw-value (raw-value (Right (raw-value (tesl_import_Float_div *a nb)))))))))))

(define/pow
  (divOrError28 [a : Integer] [b : Integer])
  #:returns (Either String Integer)
  (thsl-src! "tests/critical-review-28-tests.tesl" 923 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (tesl-equal? *b 0) (raw-value (raw-value (Left "zero"))) (let/check ([tesl-checked-24 (tesl_import_Int_nonZero b)]) (let ([nb tesl-checked-24]) (raw-value (raw-value (Right (tesl_import_Int_divide *a nb))))))))))

(define/pow
  (doubleRight28 [e : (Either String Integer)])
  #:returns (Either String Integer)
  (thsl-src! "tests/critical-review-28-tests.tesl" 930 (list (cons 'e *e)) (lambda () (raw-value (tesl_import_Either_map (raw-value (lambda (tesl-p-25-0) (multiply28 2 tesl-p-25-0))) *e)))))

(define/pow
  (callCheck28 [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-28-tests.tesl" 964 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-26 (checkRange28 raw)]) (let ([v tesl-checked-26]) (raw-value (requiresRange28 v)))))))

(define/pow
  (listLengthNonNeg28 [xs : (List Integer)])
  #:returns Boolean
  (thsl-src! "tests/critical-review-28-tests.tesl" 1100 (list (cons 'xs *xs)) (lambda () (>= (raw-value (tesl_import_List_length *xs)) 0))))

(define/pow
  (listSumReverseSame28 [xs : (List Integer)])
  #:returns Boolean
  (thsl-src! "tests/critical-review-28-tests.tesl" 1103 (list (cons 'xs *xs)) (lambda () (tesl-equal? (raw-value (tesl_import_List_sum *xs)) (raw-value (tesl_import_List_sum (raw-value (tesl_import_List_reverse *xs))))))))

(module+ test
  (require rackunit)
  (test-case "T01a: proof round-trip in bounds"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 149 (list) (lambda () (proofRoundTrip 500)))) 501)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 150 (list) (lambda () (proofRoundTrip 0)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 151 (list) (lambda () (proofRoundTrip 1000)))) 1001)
    ))
  )

  (test-case "T01b: proof round-trip out of bounds fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 155 (list) (lambda ()
                          (proofRoundTrip -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofRoundTrip -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 156 (list) (lambda ()
                          (proofRoundTrip 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofRoundTrip 1001"))
    ))
  )

  (test-case "T01c: proof flow through helper function"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 160 (list) (lambda () (proofRoundTrip 42)))) 43)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 161 (list) (lambda () (proofRoundTrip 0)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 162 (list) (lambda () (proofRoundTrip 999)))) 1000)
    ))
  )

  (test-case "T02a: sequential proof accumulation \226\128\147 valid input"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 195 (list) (lambda () (combinedCheck28 "hello")))) "hello / hello")
    ))
  )

  (test-case "T02b: sequential proof accumulation \226\128\147 fails on empty"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 199 (list) (lambda ()
                          (combinedCheck28 ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: combinedCheck28 \"\""))
    ))
  )

  (test-case "T02c: sequential proof accumulation \226\128\147 fails on 51-char string"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 203 (list) (lambda ()
                          (combinedCheck28 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: combinedCheck28 \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""))
    ))
  )

  (test-case "T03a: UserId28 round-trip"
    (call-with-fresh-memory-db '() (lambda ()
  (define uid (thsl-src! "tests/critical-review-28-tests.tesl" 219 (list) (lambda () (makeUser28 "u123"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 220 (list (cons 'uid uid)) (lambda () (requiresUser28 uid)))) "user:u123")
    ))
  )

  (test-case "T03b: ProjectId28 round-trip"
    (call-with-fresh-memory-db '() (lambda ()
  (define pid (thsl-src! "tests/critical-review-28-tests.tesl" 224 (list) (lambda () (makeProject28 "p456"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 225 (list (cons 'pid pid)) (lambda () (requiresProject28 pid)))) "project:p456")
    ))
  )

  (test-case "T03c: newtypes over same base have same .value but different types"
    (call-with-fresh-memory-db '() (lambda ()
  (define uid (thsl-src! "tests/critical-review-28-tests.tesl" 229 (list) (lambda () (makeUser28 "same"))))
  (define pid (thsl-src! "tests/critical-review-28-tests.tesl" 230 (list (cons 'uid uid)) (lambda () (makeProject28 "same"))))
  (check-equal? (thsl-src! "tests/critical-review-28-tests.tesl" 231 (list (cons 'pid pid) (cons 'uid uid)) (lambda () (raw-value (tesl-dot/runtime uid 'value)))) (raw-value (tesl-dot/runtime pid 'value)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 232 (list (cons 'pid pid) (cons 'uid uid)) (lambda () (requiresUser28 uid)))) "user:same")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 233 (list (cons 'pid pid) (cons 'uid uid)) (lambda () (requiresProject28 pid)))) "project:same")
    ))
  )

  (test-case "T03d: newtype value is accessible via .value"
    (call-with-fresh-memory-db '() (lambda ()
  (define uid (thsl-src! "tests/critical-review-28-tests.tesl" 237 (list) (lambda () (raw-value (UserId28 "abc")))))
  (check-equal? (thsl-src! "tests/critical-review-28-tests.tesl" 238 (list (cons 'uid uid)) (lambda () (raw-value (tesl-dot/runtime uid 'value)))) "abc")
    ))
  )

  (test-case "T04a: manual Bool-to-string conversion works"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 253 (list) (lambda () (boolToString28 #t)))) "true")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 254 (list) (lambda () (boolToString28 #f)))) "false")
    ))
  )

  (test-case "T04b: Bool interpolation produces Tesl repr (true/false)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (thsl-src! "tests/critical-review-28-tests.tesl" 259 (list) (lambda () (format "~a" (tesl-display-val #t)))) "true")
  (check-equal? (thsl-src! "tests/critical-review-28-tests.tesl" 260 (list) (lambda () (format "~a" (tesl-display-val #f)))) "false")
    ))
  )

  (test-case "T04c: Bool comparison still works correctly"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 264 (list) (lambda () #t))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 265 (list) (lambda () #f))) #f)
  (check-not-equal? (thsl-src! "tests/critical-review-28-tests.tesl" 266 (list) (lambda () #t)) #f)
    ))
  )

  (test-case "T05a: forgetFact preserves raw value length"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 286 (list) (lambda () (proofForgotten28 "a@b.c")))) 5)
    ))
  )

  (test-case "T05b: forgetFact result usable in non-proof functions"
    (call-with-fresh-memory-db '() (lambda ()
  (define email (thsl-src! "tests/critical-review-28-tests.tesl" 290 (list) (lambda () "user@example.com")))
  (define tesl-checked-27 (checkEmail28 email))
  (when (check-fail? tesl-checked-27)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-27)))
  (define v tesl-checked-27)
  (define raw (thsl-src! "tests/critical-review-28-tests.tesl" 292 (list (cons 'v v) (cons 'email email)) (lambda () (forget-proof v))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 293 (list (cons 'raw raw) (cons 'v v) (cons 'email email)) (lambda () (tesl_import_String_length (raw-value raw))))) 16)
    ))
  )

  (test-case "T05c: check still validates before forgetFact"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 297 (list) (lambda ()
                          (proofForgotten28 "notanemail"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofForgotten28 \"notanemail\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 298 (list) (lambda ()
                          (proofForgotten28 ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofForgotten28 \"\""))
    ))
  )

  (test-case "T06a: double all even numbers in list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 320 (list) (lambda () (doubleAllEven28 (list 1 2 3 4 5 6))))) (list 4 8 12))
    ))
  )

  (test-case "T06b: doubleAllEven28 on all-odd list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 324 (list) (lambda () (doubleAllEven28 (list 1 3 5 7))))) (list))
    ))
  )

  (test-case "T06c: doubleAllEven28 includes zero"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 328 (list) (lambda () (doubleAllEven28 (list 0 1 2))))) (list 0 4))
    ))
  )

  (test-case "T06d: doubleAllEven28 on empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 332 (list) (lambda () (doubleAllEven28 (list))))) (list))
    ))
  )

  (test-case "T06e: proof-requiring fn cannot be passed directly to map"
    (call-with-fresh-memory-db '() (lambda ()
  (define evens (thsl-src! "tests/critical-review-28-tests.tesl" 339 (list) (lambda () (tesl_import_List_filterCheck checkEven28 (list 2 4 6)))))
  (define result (thsl-src! "tests/critical-review-28-tests.tesl" 340 (list (cons 'evens evens)) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-28 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsEven28 ,n))]) (doubleEven28 n))) tesl-lambda-28) (raw-value evens)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 341 (list (cons 'result result) (cons 'evens evens)) (lambda () result))) (list 4 8 12))
    ))
  )

  (test-case "T07a: positive int interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 351 (list) (lambda () (interpolateInt28 42)))) "n=42")
    ))
  )

  (test-case "T07b: zero interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 355 (list) (lambda () (interpolateInt28 0)))) "n=0")
    ))
  )

  (test-case "T07c: negative int interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 359 (list) (lambda () (interpolateInt28 -7)))) "n=-7")
    ))
  )

  (test-case "T07d: arithmetic in interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (define a (thsl-src! "tests/critical-review-28-tests.tesl" 363 (list) (lambda () 3)))
  (define b (thsl-src! "tests/critical-review-28-tests.tesl" 364 (list (cons 'a a)) (lambda () 4)))
  (check-equal? (thsl-src! "tests/critical-review-28-tests.tesl" 365 (list (cons 'b b) (cons 'a a)) (lambda () (format "~a" (tesl-display-val (+ (raw-value a) (raw-value b)))))) "7")
    ))
  )

  (test-case "T07e: subtraction in interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 369 (list) (lambda () (interpolateNeg28 10 3)))) "diff=7")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 370 (list) (lambda () (interpolateNeg28 3 10)))) "diff=-7")
    ))
  )

  (test-case "T07f: string concat and interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 374 (list) (lambda () (string-append (string-append "hello" " ") "world")))) "hello world")
  (define name (thsl-src! "tests/critical-review-28-tests.tesl" 375 (list) (lambda () "Tesl")))
  (check-equal? (thsl-src! "tests/critical-review-28-tests.tesl" 376 (list (cons 'name name)) (lambda () (format "Hello, ~a!" (tesl-display-val name)))) "Hello, Tesl!")
    ))
  )

  (test-case "T08a: treeSum on leaf = 0"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 403 (list) (lambda () (treeSum28 Leaf28)))) 0)
    ))
  )

  (test-case "T08b: treeSum single node"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 407 (list) (lambda () (treeSum28 (Node28 Leaf28 5 Leaf28))))) 5)
    ))
  )

  (test-case "T08c: treeSum multi-level"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 411 (list) (lambda () (treeSum28 (Node28 (Node28 Leaf28 3 Leaf28) 5 (Node28 Leaf28 7 Leaf28)))))) 15)
    ))
  )

  (test-case "T08d: treeHeight of leaf = 0"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 415 (list) (lambda () (treeHeight28 Leaf28)))) 0)
    ))
  )

  (test-case "T08e: treeHeight single node = 1"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 419 (list) (lambda () (treeHeight28 (Node28 Leaf28 1 Leaf28))))) 1)
    ))
  )

  (test-case "T08f: treeHeight skewed right"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 423 (list) (lambda () (treeHeight28 (Node28 Leaf28 1 (Node28 Leaf28 2 (Node28 Leaf28 3 Leaf28))))))) 3)
    ))
  )

  (test-case "T08g: height is always positive for non-leaf"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: height non-negative
  (for ([tesl-prop-i (in-range 30)])
    (let ([n (- (random 2000001) 1000000)])
      (check-true (> (raw-value (treeHeight28 (Node28 Leaf28 n Leaf28))) 0) "height non-negative")
    ))
    ))
  )

  (test-case "T08h: summing mirrored tree"
    (call-with-fresh-memory-db '() (lambda ()
  (define t1 (thsl-src! "tests/critical-review-28-tests.tesl" 433 (list) (lambda () (raw-value (Node28 (Node28 Leaf28 1 Leaf28) 2 (Node28 Leaf28 3 Leaf28))))))
  (define t2 (thsl-src! "tests/critical-review-28-tests.tesl" 434 (list (cons 't1 t1)) (lambda () (raw-value (Node28 (Node28 Leaf28 3 Leaf28) 2 (Node28 Leaf28 1 Leaf28))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 435 (list (cons 't2 t2) (cons 't1 t1)) (lambda () (treeSum28 t1)))) (treeSum28 t2))
    ))
  )

  (test-case "T09a: partial application of add28"
    (call-with-fresh-memory-db '() (lambda ()
  (define addFive (thsl-src! "tests/critical-review-28-tests.tesl" 446 (list) (lambda () (lambda (tesl-p-29-0) (add28 5 tesl-p-29-0)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 447 (list (cons 'addFive addFive)) (lambda () (addFive 3)))) 8)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 448 (list (cons 'addFive addFive)) (lambda () (addFive 0)))) 5)
    ))
  )

  (test-case "T09b: partial application in List.map"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 452 (list) (lambda () (doubleAll28 (list 1 2 3))))) (list 2 4 6))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 453 (list) (lambda () (doubleAll28 (list))))) (list))
    ))
  )

  (test-case "T09c: partial application with three values"
    (call-with-fresh-memory-db '() (lambda ()
  (define addThree (thsl-src! "tests/critical-review-28-tests.tesl" 457 (list) (lambda () (lambda (tesl-p-30-0) (add28 3 tesl-p-30-0)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 458 (list (cons 'addThree addThree)) (lambda () (tesl_import_List_map (raw-value addThree) (list 1 2 3 4))))) (list 4 5 6 7))
    ))
  )

  (test-case "T09d: partial application of multiply28"
    (call-with-fresh-memory-db '() (lambda ()
  (define triple (thsl-src! "tests/critical-review-28-tests.tesl" 462 (list) (lambda () (lambda (tesl-p-31-0) (multiply28 3 tesl-p-31-0)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 463 (list (cons 'triple triple)) (lambda () (triple 5)))) 15)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 464 (list (cons 'triple triple)) (lambda () (triple 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 465 (list (cons 'triple triple)) (lambda () (triple -2)))) -6)
    ))
  )

  (test-case "T10a: bounded proof on valid value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 489 (list) (lambda () (wrapBounded28 0 100 50)))) "50 in [0, 100]")
    ))
  )

  (test-case "T10b: bounded proof boundary values"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 493 (list) (lambda () (wrapBounded28 0 100 0)))) "0 in [0, 100]")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 494 (list) (lambda () (wrapBounded28 0 100 100)))) "100 in [0, 100]")
    ))
  )

  (test-case "T10c: bounded proof rejects out-of-range"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 498 (list) (lambda ()
                          (wrapBounded28 0 100 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapBounded28 0 100 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 499 (list) (lambda ()
                          (wrapBounded28 0 100 101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapBounded28 0 100 101"))
    ))
  )

  (test-case "T10d: bounded proof with negative range"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 503 (list) (lambda () (wrapBounded28 -50 50 0)))) "0 in [-50, 50]")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 504 (list) (lambda ()
                          (wrapBounded28 -50 50 51))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapBounded28 -50 50 51"))
    ))
  )

  (test-case "T10e: bounded proof degenerate range (lo == hi)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 508 (list) (lambda () (wrapBounded28 5 5 5)))) "5 in [5, 5]")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 509 (list) (lambda ()
                          (wrapBounded28 5 5 6))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: wrapBounded28 5 5 6"))
    ))
  )

  (test-case "T11a: weekend days"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 537 (list) (lambda () (classifyDay28 Saturday28)))) "weekend")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 538 (list) (lambda () (classifyDay28 Sunday28)))) "weekend")
    ))
  )

  (test-case "T11b: weekdays via fall-through"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 542 (list) (lambda () (classifyDay28 Monday28)))) "weekday")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 543 (list) (lambda () (classifyDay28 Friday28)))) "weekday")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 544 (list) (lambda () (classifyDay28 Wednesday28)))) "weekday")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 545 (list) (lambda () (classifyDay28 Tuesday28)))) "weekday")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 546 (list) (lambda () (classifyDay28 Thursday28)))) "weekday")
    ))
  )

  (test-case "T11c: category fall-through plant"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 568 (list) (lambda () (describeCategory28 Fruit28)))) "plant")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 569 (list) (lambda () (describeCategory28 Vegetable28)))) "plant")
    ))
  )

  (test-case "T11d: category fall-through animal"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 573 (list) (lambda () (describeCategory28 Dairy28)))) "animal")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 574 (list) (lambda () (describeCategory28 Meat28)))) "animal")
    ))
  )

  (test-case "T11e: category grain has own body"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 578 (list) (lambda () (describeCategory28 Grain28)))) "starch")
    ))
  )

  (test-case "T12a: establish returns Something for small value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 601 (list) (lambda () (applySmall28 5)))) "small: 5")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 602 (list) (lambda () (applySmall28 0)))) "small: 0")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 603 (list) (lambda () (applySmall28 9)))) "small: 9")
    ))
  )

  (test-case "T12b: establish returns Nothing for large value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 607 (list) (lambda () (applySmall28 10)))) "not small")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 608 (list) (lambda () (applySmall28 100)))) "not small")
    ))
  )

  (test-case "T12c: establish returns Something for negative (< 10)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 612 (list) (lambda () (applySmall28 -5)))) "small: -5")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 613 (list) (lambda () (applySmall28 -100)))) "small: -100")
    ))
  )

  (test-case "T13a: sort preserves list length"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 623 (list) (lambda () (filteredSubset28 (list 3 1 4 1 5 9 2 6))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 624 (list) (lambda () (filteredSubset28 (list))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 625 (list) (lambda () (filteredSubset28 (list 1))))) #t)
    ))
  )

  (test-case "T13b: sort known examples"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 629 (list) (lambda () (tesl_import_List_sort (list 5 4 3 2 1))))) (list 1 2 3 4 5))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 630 (list) (lambda () (tesl_import_List_sort (list 1 1 2 2))))) (list 1 1 2 2))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 631 (list) (lambda () (tesl_import_List_sort (list))))) (list))
    ))
  )

  (test-case "T13c: sort preserves length \226\128\147 explicit examples"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 637 (list) (lambda () (filteredSubset28 (list 3 1 4 1 5))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 638 (list) (lambda () (filteredSubset28 (list -5 0 5))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 639 (list) (lambda () (filteredSubset28 (list 100))))) #t)
    ))
  )

  (test-case "T13d: sort is idempotent \226\128\147 explicit examples"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 644 (list) (lambda () (tesl_import_List_sort (list 3 1 2))))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 645 (list) (lambda () (tesl_import_List_sort (list 1 2 3))))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 646 (list) (lambda () (tesl_import_List_sort (list 2 1 4 3))))) (list 1 2 3 4))
    ))
  )

  (test-case "T14a: trimmed and long \226\128\147 passes valid input"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 676 (list) (lambda () (validateTrimmedLong28 "hello")))) "ok: hello")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 677 (list) (lambda () (validateTrimmedLong28 "abcde")))) "ok: abcde")
    ))
  )

  (test-case "T14b: fails if leading whitespace"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 681 (list) (lambda ()
                          (validateTrimmedLong28 " hello"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: validateTrimmedLong28 \" hello\""))
    ))
  )

  (test-case "T14c: fails if trailing whitespace"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 685 (list) (lambda ()
                          (validateTrimmedLong28 "hello "))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: validateTrimmedLong28 \"hello \""))
    ))
  )

  (test-case "T14d: fails if too short after trimming"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 689 (list) (lambda ()
                          (validateTrimmedLong28 "ab"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: validateTrimmedLong28 \"ab\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 690 (list) (lambda ()
                          (validateTrimmedLong28 ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: validateTrimmedLong28 \"\""))
    ))
  )

  (test-case "T15a: head of non-empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 712 (list) (lambda () (headOrDefault28 (list 1 2 3) 0)))) 1)
    ))
  )

  (test-case "T15b: head of empty list gives default"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 716 (list) (lambda () (headOrDefault28 (list) 99)))) 99)
    ))
  )

  (test-case "T15c: nested Maybe in helper function"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 720 (list) (lambda () (nestedMaybeCheck28 Nothing)))) -1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 721 (list) (lambda () (nestedMaybeCheck28 (raw-value (Something Nothing)))))) -2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 722 (list) (lambda () (nestedMaybeCheck28 (raw-value (Something (raw-value (Something 42)))))))) 42)
    ))
  )

  (test-case "T15d: safeHead on single-element list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 726 (list) (lambda () (safeHead28 (list 7))))) (raw-value (Something 7)))
    ))
  )

  (test-case "T15e: safeHead on empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 730 (list) (lambda () (safeHead28 (list))))) Nothing)
    ))
  )

  (test-case "T16a: safe divide nonzero denominator"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 744 (list) (lambda () (safeDivide28 10 2)))) (raw-value (Right 5)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 745 (list) (lambda () (safeDivide28 7 3)))) (raw-value (Right 2)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 746 (list) (lambda () (safeDivide28 0 5)))) (raw-value (Right 0)))
    ))
  )

  (test-case "T16b: safe divide zero denominator"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 750 (list) (lambda () (safeDivide28 10 0)))) (raw-value (Left "division by zero")))
    ))
  )

  (test-case "T16c: safe divide negative denominator"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 754 (list) (lambda () (safeDivide28 10 -2)))) (raw-value (Right -5)))
    ))
  )

  (test-case "T16d: safe divide property \226\128\147 result * b \226\137\136 a"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: integer division
  (for ([tesl-prop-i (in-range 30)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)])
      (check-true (if (tesl-equal? (raw-value b) 0) (tesl-equal? (raw-value (safeDivide28 a b)) (raw-value (Left "division by zero"))) (not (tesl-equal? (raw-value (safeDivide28 a b)) (raw-value (Left "division by zero"))))) "integer division")
    ))
    ))
  )

  (test-case "T17a: subtraction positive result"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 774 (list) (lambda () (negArithmetic28 10 3)))) 7)
    ))
  )

  (test-case "T17b: subtraction negative result"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 778 (list) (lambda () (negArithmetic28 3 10)))) -7)
    ))
  )

  (test-case "T17c: modulo"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 782 (list) (lambda () (remainder 17 5)))) 2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 783 (list) (lambda () (remainder 0 5)))) 0)
    ))
  )

  (test-case "T17d: integer division truncates toward zero"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 787 (list) (lambda () (quotient 7 2)))) 3)
    ))
  )

  (test-case "T17e: add is commutative"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: commutativity
  (for ([tesl-prop-i (in-range 100)])
    (let ([x (- (random 2000001) 1000000)] [y (- (random 2000001) 1000000)])
      (check-true (tesl-equal? (+ (raw-value x) (raw-value y)) (+ (raw-value y) (raw-value x))) "commutativity")
    ))
    ))
  )

  (test-case "T17f: multiply distributes over add"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: distributivity
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)] [c (- (random 2000001) 1000000)])
      (check-true (tesl-equal? (* (raw-value a) (+ (raw-value b) (raw-value c))) (+ (* (raw-value a) (raw-value b)) (* (raw-value a) (raw-value c)))) "distributivity")
    ))
    ))
  )

  (test-case "T17g: max safe Int is within range"
    (call-with-fresh-memory-db '() (lambda ()
  (check-true (thsl-src! "tests/critical-review-28-tests.tesl" 801 (list) (lambda () (> (raw-value (maxSafeInt28)) 1000000000))))
    ))
  )

  (test-case "T17h: negation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 805 (list) (lambda () (- 0 5)))) -5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 806 (list) (lambda () (- 0 -5)))) 5)
    ))
  )

  (test-case "T18a: tuple construction and access"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "tests/critical-review-28-tests.tesl" 816 (list) (lambda () (raw-value (Tuple2 42 "hello")))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 817 (list (cons 'p p)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value p)))))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 818 (list (cons 'p p)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value p)))))) "hello")
    ))
  )

  (test-case "T18b: swapPair28 reverses components"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-28-tests.tesl" 822 (list) (lambda () (swapPair28 7 "world"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 823 (list (cons 'result result)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value result)))))) "world")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 824 (list (cons 'result result)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value result)))))) 7)
    ))
  )

  (test-case "T18c: tuple equality"
    (call-with-fresh-memory-db '() (lambda ()
  (define p1 (thsl-src! "tests/critical-review-28-tests.tesl" 828 (list) (lambda () (raw-value (Tuple2 1 2)))))
  (define p2 (thsl-src! "tests/critical-review-28-tests.tesl" 829 (list (cons 'p1 p1)) (lambda () (raw-value (Tuple2 1 2)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 830 (list (cons 'p2 p2) (cons 'p1 p1)) (lambda () p1))) p2)
  (check-not-equal? (thsl-src! "tests/critical-review-28-tests.tesl" 831 (list (cons 'p2 p2) (cons 'p1 p1)) (lambda () (Tuple2 1 3))) p1)
    ))
  )

  (test-case "T19a: proof decompose and reattach round-trip"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 850 (list) (lambda () (roundTripProof28 50)))) 51)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 851 (list) (lambda () (roundTripProof28 0)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 852 (list) (lambda () (roundTripProof28 1000)))) 1001)
    ))
  )

  (test-case "T19b: decompose fails propagates"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 856 (list) (lambda ()
                          (roundTripProof28 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: roundTripProof28 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 857 (list) (lambda ()
                          (roundTripProof28 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: roundTripProof28 1001"))
    ))
  )

  (test-case "T19c: proof forgetFact and raw decompose yield same value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 861 (list) (lambda () (forgetAndRaw28 5)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 862 (list) (lambda () (forgetAndRaw28 100)))) #t)
    ))
  )

  (test-case "T20a: allCheck accepts all-valid list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 875 (list) (lambda () (allCheckResult28 (list 0 50 100))))) "ok")
    ))
  )

  (test-case "T20b: allCheck rejects list with invalid element"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 879 (list) (lambda () (allCheckResult28 (list 0 50 1001))))) "failed")
    ))
  )

  (test-case "T20c: allCheck accepts empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 883 (list) (lambda () (allCheckResult28 (list))))) "ok")
    ))
  )

  (test-case "T20d: allCheck rejects negative element"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 887 (list) (lambda () (allCheckResult28 (list -1 5 10))))) "failed")
    ))
  )

  (test-case "T21a: float division"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 901 (list) (lambda () (safeFloatDiv28 10. 4.)))) (raw-value (Right 2.5)))
    ))
  )

  (test-case "T21b: float division by zero"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 905 (list) (lambda () (safeFloatDiv28 1. 0.)))) (raw-value (Left "zero")))
    ))
  )

  (test-case "T21c: float sqrt"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 909 (list) (lambda () (raw-value (tesl_import_Float_sqrt 9.))))) 3.)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 910 (list) (lambda () (raw-value (tesl_import_Float_sqrt 4.))))) 2.)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 911 (list) (lambda () (raw-value (tesl_import_Float_sqrt 0.))))) 0.)
    ))
  )

  (test-case "T21d: float arithmetic"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-28-tests.tesl" 915 (list) (lambda () (safeFloatDiv28 1. 2.))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 916 (list (cons 'result result)) (lambda () result))) (raw-value (Right 0.5)))
    ))
  )

  (test-case "T22a: Either.map over Right"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 933 (list) (lambda () (doubleRight28 (Right 5))))) (raw-value (Right 10)))
    ))
  )

  (test-case "T22b: Either.map over Left is identity"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 937 (list) (lambda () (doubleRight28 (Left "error"))))) (raw-value (Left "error")))
    ))
  )

  (test-case "T22c: Either.withDefault on Left"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 941 (list) (lambda () (raw-value (tesl_import_Either_withDefault 99 (Left "err")))))) 99)
    ))
  )

  (test-case "T22d: Either.withDefault on Right"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 945 (list) (lambda () (raw-value (tesl_import_Either_withDefault 99 (Right 42)))))) 42)
    ))
  )

  (test-case "T22e: Either.andThen chains operations"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-28-tests.tesl" 951 (list) (lambda () (raw-value (tesl_import_Either_andThen (raw-value (lambda (tesl-p-32-0) (divOrError28 100 tesl-p-32-0))) (raw-value (divOrError28 10 2)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 952 (list (cons 'result result)) (lambda () result))) (raw-value (Right 20)))
    ))
  )

  (test-case "T22f: Either.andThen short-circuits on Left"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-28-tests.tesl" 956 (list) (lambda () (raw-value (tesl_import_Either_andThen (raw-value (lambda (tesl-p-33-0) (divOrError28 100 tesl-p-33-0))) (raw-value (divOrError28 10 0)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 957 (list (cons 'result result)) (lambda () result))) (raw-value (Left "zero")))
    ))
  )

  (test-case "T23a: fn can call check and use result with proof"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 968 (list) (lambda () (callCheck28 500)))) 501)
    ))
  )

  (test-case "T23b: fn calling check fails propagates failure"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 972 (list) (lambda ()
                          (callCheck28 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: callCheck28 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-28-tests.tesl" 973 (list) (lambda ()
                          (callCheck28 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: callCheck28 1001"))
    ))
  )

  (test-case "T24a: String.toUpper"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 980 (list) (lambda () (tesl_import_String_toUpper "hello")))) "HELLO")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 981 (list) (lambda () (tesl_import_String_toUpper "")))) "")
    ))
  )

  (test-case "T24b: String.toLower"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 985 (list) (lambda () (tesl_import_String_toLower "HELLO")))) "hello")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 986 (list) (lambda () (tesl_import_String_toLower "MiXeD")))) "mixed")
    ))
  )

  (test-case "T24c: String.trim"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 990 (list) (lambda () (tesl_import_String_trim "  hello  ")))) "hello")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 991 (list) (lambda () (tesl_import_String_trim "hello")))) "hello")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 992 (list) (lambda () (tesl_import_String_trim "  ")))) "")
    ))
  )

  (test-case "T24d: String.startsWith"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 996 (list) (lambda () (tesl_import_String_startsWith "hello world" "hello")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 997 (list) (lambda () (tesl_import_String_startsWith "hello world" "world")))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 998 (list) (lambda () (tesl_import_String_startsWith "" "")))) #t)
    ))
  )

  (test-case "T24e: String.endsWith"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1002 (list) (lambda () (tesl_import_String_endsWith "hello world" "world")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1003 (list) (lambda () (tesl_import_String_endsWith "hello world" "hello")))) #f)
    ))
  )

  (test-case "T24f: String.split and join round-trip"
    (call-with-fresh-memory-db '() (lambda ()
  (define parts (thsl-src! "tests/critical-review-28-tests.tesl" 1007 (list) (lambda () (tesl_import_String_split "a,b,c" ","))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1008 (list (cons 'parts parts)) (lambda () (tesl_import_String_join (raw-value parts) ",")))) "a,b,c")
    ))
  )

  (test-case "T24g: String.replace"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1012 (list) (lambda () (tesl_import_String_replace "hello world" "world" "tesl")))) "hello tesl")
    ))
  )

  (test-case "T24h: String.length"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1016 (list) (lambda () (tesl_import_String_length "hello")))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1017 (list) (lambda () (tesl_import_String_length "")))) 0)
    ))
  )

  (test-case "T25a: List.contains"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1024 (list) (lambda () (raw-value (tesl_import_List_contains 2 (list 1 2 3)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1025 (list) (lambda () (raw-value (tesl_import_List_contains 4 (list 1 2 3)))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1026 (list) (lambda () (raw-value (tesl_import_List_contains 1 (list)))))) #f)
    ))
  )

  (test-case "T25b: List.find"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-28-tests.tesl" 1030 (list) (lambda () (raw-value (tesl_import_List_find (let () (define/pow (tesl-lambda-34 [n : Integer]) #:returns Boolean (> *n 2)) tesl-lambda-34) (list 1 2 3 4))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1031 (list (cons 'result result)) (lambda () result))) (raw-value (Something 3)))
  (define notFound (thsl-src! "tests/critical-review-28-tests.tesl" 1032 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_find (let () (define/pow (tesl-lambda-35 [n : Integer]) #:returns Boolean (> *n 10)) tesl-lambda-35) (list 1 2))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1033 (list (cons 'notFound notFound) (cons 'result result)) (lambda () notFound))) Nothing)
    ))
  )

  (test-case "T25c: List.take with proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define n3 (thsl-src! "tests/critical-review-28-tests.tesl" 1037 (list) (lambda () 3)))
  (define tesl-checked-36 (tesl_import_Int_nonNegative n3))
  (when (check-fail? tesl-checked-36)
    (raise-user-error 'tesl-test "unexpected failure in let count: ~a" (check-fail-message tesl-checked-36)))
  (define count tesl-checked-36)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1039 (list (cons 'count count) (cons 'n3 n3)) (lambda () (tesl_import_List_take count (list 1 2 3 4 5))))) (list 1 2 3))
  (define n0 (thsl-src! "tests/critical-review-28-tests.tesl" 1040 (list (cons 'count count) (cons 'n3 n3)) (lambda () 0)))
  (define tesl-checked-37 (tesl_import_Int_nonNegative n0))
  (when (check-fail? tesl-checked-37)
    (raise-user-error 'tesl-test "unexpected failure in let zero: ~a" (check-fail-message tesl-checked-37)))
  (define zero tesl-checked-37)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1042 (list (cons 'zero zero) (cons 'n0 n0) (cons 'count count) (cons 'n3 n3)) (lambda () (tesl_import_List_take zero (list 1 2 3))))) (list))
    ))
  )

  (test-case "T25d: List.drop with proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define n2 (thsl-src! "tests/critical-review-28-tests.tesl" 1046 (list) (lambda () 2)))
  (define tesl-checked-38 (tesl_import_Int_nonNegative n2))
  (when (check-fail? tesl-checked-38)
    (raise-user-error 'tesl-test "unexpected failure in let count: ~a" (check-fail-message tesl-checked-38)))
  (define count tesl-checked-38)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1048 (list (cons 'count count) (cons 'n2 n2)) (lambda () (tesl_import_List_drop count (list 1 2 3 4 5))))) (list 3 4 5))
    ))
  )

  (test-case "T25e: List.sum"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1052 (list) (lambda () (raw-value (tesl_import_List_sum (list 1 2 3 4 5)))))) 15)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1053 (list) (lambda () (raw-value (tesl_import_List_sum (list)))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1054 (list) (lambda () (raw-value (tesl_import_List_sum (list 0 0 0)))))) 0)
    ))
  )

  (test-case "T25f: List.product"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1058 (list) (lambda () (raw-value (tesl_import_List_product (list 1 2 3 4)))))) 24)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1059 (list) (lambda () (raw-value (tesl_import_List_product (list)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1060 (list) (lambda () (raw-value (tesl_import_List_product (list 0 1 2)))))) 0)
    ))
  )

  (test-case "T25g: List.reverse"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1064 (list) (lambda () (tesl_import_List_reverse (list 1 2 3))))) (list 3 2 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1065 (list) (lambda () (tesl_import_List_reverse (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1066 (list) (lambda () (tesl_import_List_reverse (list 1))))) (list 1))
    ))
  )

  (test-case "T25h: List.unique"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1070 (list) (lambda () (tesl_import_List_unique (list 1 2 1 3 2))))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1071 (list) (lambda () (tesl_import_List_unique (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1072 (list) (lambda () (tesl_import_List_unique (list 1 1 1))))) (list 1))
    ))
  )

  (test-case "T25i: filterCheck then map"
    (call-with-fresh-memory-db '() (lambda ()
  (define evens (thsl-src! "tests/critical-review-28-tests.tesl" 1076 (list) (lambda () (tesl_import_List_filterCheck checkEven28 (list 1 2 3 4 5 6)))))
  (define doubled (thsl-src! "tests/critical-review-28-tests.tesl" 1077 (list (cons 'evens evens)) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-39 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsEven28 ,n))]) (* *n 2))) tesl-lambda-39) (raw-value evens)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1078 (list (cons 'doubled doubled) (cons 'evens evens)) (lambda () doubled))) (list 4 8 12))
    ))
  )

  (test-case "T25j: List.any and List.all"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1082 (list) (lambda () (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-40 [n : Integer]) #:returns Boolean (> *n 3)) tesl-lambda-40) (list 1 2 3 4)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1083 (list) (lambda () (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-41 [n : Integer]) #:returns Boolean (> *n 10)) tesl-lambda-41) (list 1 2 3)))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1084 (list) (lambda () (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-42 [n : Integer]) #:returns Boolean (> *n 0)) tesl-lambda-42) (list 1 2 3)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1085 (list) (lambda () (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-43 [n : Integer]) #:returns Boolean (> *n 1)) tesl-lambda-43) (list 1 2 3)))))) #f)
    ))
  )

  (test-case "T25k: List idempotent sort examples"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1089 (list) (lambda () (tesl_import_List_sort (list 9 1 8 2 7 3))))) (list 1 2 3 7 8 9))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-28-tests.tesl" 1090 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (tesl_import_List_sort (list 3 1 4 1 5 9 2 6)))))))) 8)
    ))
  )

  (test-case "T26a: property test with List Int parameter compiles and runs"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: length is non-negative
  (for ([tesl-prop-i (in-range 200)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (listLengthNonNeg28 xs) "length is non-negative")
    ))
    ))
  )

  (test-case "T26b: List sum is commutative under reversal"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: sum equals sum of reversed
  (for ([tesl-prop-i (in-range 200)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (listSumReverseSame28 xs) "sum equals sum of reversed")
    ))
    ))
  )

  (test-case "T26c: append length is additive"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: append length
  (for ([tesl-prop-i (in-range 200)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))] [ys (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (tesl-equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_List_append (raw-value xs) (raw-value ys))))) (+ (raw-value (tesl_import_List_length (raw-value xs))) (raw-value (tesl_import_List_length (raw-value ys))))) "append length")
    ))
    ))
  )

)
