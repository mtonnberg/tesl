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
  (thsl-src! "tests/critical-review-35-tests.tesl" 176 (list (cons 'n *n)) (lambda () (if (>= *n 0) (accept (NonNeg35 n) #:value *n) (reject "must be non-negative" #:http-code 400)))))

(define/pow
  (requireNonNeg35 [n : Integer ::: (NonNeg35 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 181 (list (cons 'n *n)) (lambda () (+ *n 1))))

(define-checker
  (checkA35 [s : String])
  #:returns [s : String ::: (IsA35 s)]
  (thsl-src! "tests/critical-review-35-tests.tesl" 206 (list (cons 's *s)) (lambda () (if (tesl_import_String_startsWith *s "A") (accept (IsA35 s) #:value *s) (reject "must start with A" #:http-code 400)))))

(define-checker
  (checkB35 [s : String])
  #:returns [s : String ::: (IsB35 s)]
  (thsl-src! "tests/critical-review-35-tests.tesl" 212 (list (cons 's *s)) (lambda () (if (tesl_import_String_endsWith *s "B") (accept (IsB35 s) #:value *s) (reject "must end with B" #:http-code 400)))))

(define-checker
  (checkEv35 [n : Integer])
  #:returns [n : Integer ::: (Ev35 n)]
  (thsl-src! "tests/critical-review-35-tests.tesl" 242 (list (cons 'n *n)) (lambda () (if (tesl-equal? (remainder *n 2) 0) (accept (Ev35 n) #:value *n) (reject "not even" #:http-code 400)))))

(define-checker
  (checkSmall35 [n : Integer])
  #:returns [n : Integer ::: (Small35 n)]
  (thsl-src! "tests/critical-review-35-tests.tesl" 248 (list (cons 'n *n)) (lambda () (if (< *n 20) (accept (Small35 n) #:value *n) (reject "too large" #:http-code 400)))))

(define/pow
  (doubleFilter35 [xs : (List Integer)])
  #:returns (List Integer)
  (let ([evens (thsl-src! "tests/critical-review-35-tests.tesl" 254 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkEv35 *xs)))]) (thsl-src! "tests/critical-review-35-tests.tesl" 255 (list (cons 'evens *evens) (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkSmall35 (raw-value evens))))))

(define-trusted
  (alwaysTrue35 [n : Integer])
  #:returns (Fact (AlwaysTrue35 n))
  (thsl-src! "tests/critical-review-35-tests.tesl" 273 (list (cons 'n *n)) (lambda () (trusted-proof (AlwaysTrue35 n)))))

(define/pow
  (requiresTrue35 [n : Integer ::: (AlwaysTrue35 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 275 (list (cons 'n *n)) (lambda () (* *n 3))))

(define/pow
  (useEstablish35 [n : Integer])
  #:returns Integer
  (let ([proof (thsl-src! "tests/critical-review-35-tests.tesl" 278 (list (cons 'n *n)) (lambda () (alwaysTrue35 n)))]) (thsl-src! "tests/critical-review-35-tests.tesl" 279 (list (cons 'proof *proof) (cons 'n *n)) (lambda () (raw-value (requiresTrue35 (attach-proof n proof)))))))

(define-checker
  (checkPosDecomp35 [n : Integer])
  #:returns [n : Integer ::: (Pos35 n)]
  (thsl-src! "tests/critical-review-35-tests.tesl" 294 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (Pos35 n) #:value *n) (reject "not positive" #:http-code 400)))))

(define/pow
  (requiresPos35 [n : Integer ::: (Pos35 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 299 (list (cons 'n *n)) (lambda () (+ *n 100))))

(define/pow
  (decomposeAndReattach35 [n : Integer ::: (Pos35 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 302 (list (cons 'n *n)) (lambda () (let ([tesl-proof-binding-0 n]) (let ([val (forget-proof tesl-proof-binding-0)] [p (detach-all-proof tesl-proof-binding-0)]) (let ([reattached (attach-proof val p)]) (raw-value (requiresPos35 reattached))))))))

(define-adt (MyList35 a)
  [Nil35]
  [Cons35 [head : a] [tail : (MyList35 a)]]
)

(define/pow
  (myLength35 [xs : (MyList35 Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 324 (list (cons 'xs *xs)) (lambda () (let ([tesl-case-1 *xs]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nil35)) (thsl-src! "tests/critical-review-35-tests.tesl" 325 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Cons35)) (let ([tail (hash-ref (adt-value-fields *tesl-case-1) 'tail)]) (thsl-src! "tests/critical-review-35-tests.tesl" 326 (list (cons 'tail tail)) (lambda () (raw-value (+ 1 (raw-value (myLength35 *tail)))))))])))))

(define/pow
  (myMap35 [f : (-> Integer Integer)] [xs : (MyList35 Integer)])
  #:returns (MyList35 Integer)
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 329 (list (cons 'f *f) (cons 'xs *xs)) (lambda () (let ([tesl-case-2 *xs]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nil35)) (thsl-src! "tests/critical-review-35-tests.tesl" 330 (list) (lambda () (raw-value Nil35)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Cons35)) (let ([head (hash-ref (adt-value-fields *tesl-case-2) 'head)]) (let ([tail (hash-ref (adt-value-fields *tesl-case-2) 'tail)]) (thsl-src! "tests/critical-review-35-tests.tesl" 331 (list (cons 'head head) (cons 'tail tail)) (lambda () (raw-value (raw-value (Cons35 (f *head) (myMap35 f *tail))))))))])))))

(define/pow
  (myAppend35 [xs : (MyList35 Integer)] [ys : (MyList35 Integer)])
  #:returns (MyList35 Integer)
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 334 (list (cons 'xs *xs) (cons 'ys *ys)) (lambda () (let ([tesl-case-3 *xs]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nil35)) (thsl-src! "tests/critical-review-35-tests.tesl" 335 (list) (lambda () *ys))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Cons35)) (let ([head (hash-ref (adt-value-fields *tesl-case-3) 'head)]) (let ([tail (hash-ref (adt-value-fields *tesl-case-3) 'tail)]) (thsl-src! "tests/critical-review-35-tests.tesl" 336 (list (cons 'head head) (cons 'tail tail)) (lambda () (raw-value (raw-value (Cons35 *head (myAppend35 *tail ys))))))))])))))

(define/pow
  (flattenMaybe35 [m : (Maybe (Maybe Integer))])
  #:returns (Maybe Integer)
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 354 (list (cons 'm *m)) (lambda () (let ([tesl-case-4 *m]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "tests/critical-review-35-tests.tesl" 355 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([inner (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tests/critical-review-35-tests.tesl" 357 (list (cons 'inner inner)) (lambda () (let ([tesl-case-5 (raw-value inner)]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "tests/critical-review-35-tests.tesl" 358 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([val (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tests/critical-review-35-tests.tesl" 359 (list (cons 'val val)) (lambda () (raw-value (raw-value (Something *val))))))])))))])))))

(define-checker
  (checkSafeTitle35 [s : String])
  #:returns [s : String ::: (SafeTitle35 s)]
  (thsl-src! "tests/critical-review-35-tests.tesl" 376 (list (cons 's *s)) (lambda () (if (and (> (raw-value (tesl_import_String_length *s)) 0) (<= (raw-value (tesl_import_String_length *s)) 100)) (accept (SafeTitle35 s) #:value *s) (reject "title must be 1-100 chars" #:http-code 400)))))

(define-record ProvenRecord35
  [title : String ::: (SafeTitle35 title)]
)

(define/pow
  (requiresSafeTitle35 [s : String ::: (SafeTitle35 s)])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 386 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define/pow
  (readAndConsume35 [rec : ProvenRecord35])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 389 (list (cons 'rec *rec)) (lambda () (raw-value (requiresSafeTitle35 (tesl-dot/runtime rec 'title))))))

(define/pow
  (safeFloatDiv35 [a : Real] [b : Real])
  #:returns (Maybe Real)
  (thsl-src! "tests/critical-review-35-tests.tesl" 447 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (tesl-equal? *b 0.) (raw-value Nothing) (let/check ([tesl-checked-6 (tesl_import_Float_requireNonZero b)]) (let ([divisor tesl-checked-6]) (raw-value (raw-value (Something (raw-value (tesl_import_Float_div *a divisor)))))))))))

(define/pow
  (xor35 [a : Boolean] [b : Boolean])
  #:returns Boolean
  (thsl-src! "tests/critical-review-35-tests.tesl" 475 (list (cons 'a *a) (cons 'b *b)) (lambda () (and (or *a *b) (not (and *a *b))))))

(define/pow
  (nand35 [a : Boolean] [b : Boolean])
  #:returns Boolean
  (thsl-src! "tests/critical-review-35-tests.tesl" 478 (list (cons 'a *a) (cons 'b *b)) (lambda () (not (and *a *b)))))

(define-newtype UserId35 String)

(define/pow
  (wrapAndUnwrap35 [s : String])
  #:returns String
  (let ([uid (thsl-src! "tests/critical-review-35-tests.tesl" 498 (list (cons 's *s)) (lambda () (raw-value (UserId35 *s))))]) (thsl-src! "tests/critical-review-35-tests.tesl" 499 (list (cons 'uid *uid) (cons 's *s)) (lambda () (raw-value uid.value)))))

(define-adt Prio35
  [Critical35]
  [High35]
  [Medium35]
  [Low35]
)

(define/pow
  (classifyPrio35 [p : Prio35] [urgent : Boolean])
  #:returns String
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 526 (list (cons 'p *p) (cons 'urgent *urgent)) (lambda () (let ([tesl-case-7 *p]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Critical35)) (thsl-src! "tests/critical-review-35-tests.tesl" 527 (list) (lambda () (raw-value "must do now")))] [(and (and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'High35)) urgent) (thsl-src! "tests/critical-review-35-tests.tesl" 528 (list) (lambda () (raw-value "escalated")))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'High35)) (thsl-src! "tests/critical-review-35-tests.tesl" 529 (list) (lambda () (raw-value "important")))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Medium35)) (thsl-src! "tests/critical-review-35-tests.tesl" 530 (list) (lambda () (raw-value "normal")))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Low35)) (thsl-src! "tests/critical-review-35-tests.tesl" 531 (list) (lambda () (raw-value "backlog")))])))))

(define/pow
  (sumFold35 [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 547 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-8 [acc : Integer] [x : Integer]) #:returns Integer (+ *acc *x)) tesl-lambda-8) 0 *xs)))))

(define/pow
  (productFold35 [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 550 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-9 [acc : Integer] [x : Integer]) #:returns Integer (* *acc *x)) tesl-lambda-9) 1 *xs)))))

(define/pow
  (concatFold35 [xs : (List String)])
  #:returns String
  (thsl-src! "tests/critical-review-35-tests.tesl" 553 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-10 [acc : String] [s : String]) #:returns String (string-append *acc *s)) tesl-lambda-10) "" *xs)))))

(define/pow
  (applyN35 [f : (-> Integer Integer)] [n : Integer] [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 572 (list (cons 'f *f) (cons 'n *n) (cons 'x *x)) (lambda () (if (<= *n 0) *x (raw-value (applyN35 f (- *n 1) (f x)))))))

(define/pow
  (add335 [a : Integer] [b : Integer] [c : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-35-tests.tesl" 588 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (+ (+ *a *b) *c))))

(define-checker
  (checkPos35 [n : Integer])
  #:returns [n : Integer ::: (PosVal35 n)]
  (thsl-src! "tests/critical-review-35-tests.tesl" 608 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (PosVal35 n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmallInt35 [n : Integer])
  #:returns [n : Integer ::: (SmallInt35 n)]
  (thsl-src! "tests/critical-review-35-tests.tesl" 614 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (SmallInt35 n) #:value *n) (reject "too large" #:http-code 400)))))

(define/pow
  (requiresBoth35 [n : Integer ::: ((PosVal35 n) && (SmallInt35 n))])
  #:returns String
  (thsl-src! "tests/critical-review-35-tests.tesl" 620 (list (cons 'n *n)) (lambda () (format "valid: ~a" (tesl-display-val *n)))))

(define/pow
  (sequentialChecks35 [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-35-tests.tesl" 623 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-11 (checkPos35 n)]) (let ([v1 tesl-checked-11]) (let/check ([tesl-checked-12 (checkSmallInt35 v1)]) (let ([v2 tesl-checked-12]) (raw-value (requiresBoth35 v2)))))))))

(define-adt (Pair35 a b)
  [MkPair35 [fst : a] [snd : b]]
)

(define/pow
  (swapPair35 [p : (Pair35 Integer String)])
  #:returns (Pair35 String Integer)
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 751 (list (cons 'p *p)) (lambda () (let ([tesl-case-13 *p]) (cond [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'MkPair35)) (let ([fst (hash-ref (adt-value-fields *tesl-case-13) 'fst)]) (let ([snd (hash-ref (adt-value-fields *tesl-case-13) 'snd)]) (thsl-src! "tests/critical-review-35-tests.tesl" 752 (list (cons 'fst fst) (cons 'snd snd)) (lambda () (raw-value (raw-value (MkPair35 *snd *fst)))))))])))))

(define/pow
  (mapPair35 [f : (-> Integer Integer)] [g : (-> String String)] [p : (Pair35 Integer String)])
  #:returns (Pair35 Integer String)
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 755 (list (cons 'f *f) (cons 'g *g) (cons 'p *p)) (lambda () (let ([tesl-case-14 *p]) (cond [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'MkPair35)) (let ([fst (hash-ref (adt-value-fields *tesl-case-14) 'fst)]) (let ([snd (hash-ref (adt-value-fields *tesl-case-14) 'snd)]) (thsl-src! "tests/critical-review-35-tests.tesl" 756 (list (cons 'fst fst) (cons 'snd snd)) (lambda () (raw-value (raw-value (MkPair35 (f *fst) (g *snd))))))))])))))

(define/pow
  (verifyForgetAndRecheck35 [n : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "tests/critical-review-35-tests.tesl" 771 (list (cons 'n *n)) (lambda () (if (> *n 0) (let/check ([tesl-checked-15 (checkPosDecomp35 n)]) (let ([checked tesl-checked-15]) (let ([forgotten (forget-proof checked)]) (let/check ([tesl-checked-16 (checkPosDecomp35 forgotten)]) (let ([rechecked tesl-checked-16]) (raw-value (raw-value (Something (requiresPos35 rechecked))))))))) (raw-value Nothing)))))

(define-adt Season35
  [Spring35]
  [Summer35]
  [Autumn35]
  [Winter35]
)

(define/pow
  (isWarm35 [s : Season35])
  #:returns Boolean
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 889 (list (cons 's *s)) (lambda () (let ([tesl-case-17 *s]) (cond [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Spring35)) (thsl-src! "tests/critical-review-35-tests.tesl" 892 (list) (lambda () (raw-value #t)))] [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Summer35)) (thsl-src! "tests/critical-review-35-tests.tesl" 892 (list) (lambda () (raw-value #t)))] [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Autumn35)) (thsl-src! "tests/critical-review-35-tests.tesl" 895 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Winter35)) (thsl-src! "tests/critical-review-35-tests.tesl" 895 (list) (lambda () (raw-value #f)))])))))

(define/pow
  (httpStatus35 [code : Integer])
  #:returns String
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 938 (list (cons 'code *code)) (lambda () (let ([tesl-case-18 *code]) (cond [(= *tesl-case-18 200) (thsl-src! "tests/critical-review-35-tests.tesl" 939 (list) (lambda () (raw-value "OK")))] [(= *tesl-case-18 201) (thsl-src! "tests/critical-review-35-tests.tesl" 940 (list) (lambda () (raw-value "Created")))] [(= *tesl-case-18 400) (thsl-src! "tests/critical-review-35-tests.tesl" 941 (list) (lambda () (raw-value "Bad Request")))] [(= *tesl-case-18 404) (thsl-src! "tests/critical-review-35-tests.tesl" 942 (list) (lambda () (raw-value "Not Found")))] [(= *tesl-case-18 500) (thsl-src! "tests/critical-review-35-tests.tesl" 943 (list) (lambda () (raw-value "Internal Server Error")))] [#t (thsl-src! "tests/critical-review-35-tests.tesl" 944 (list) (lambda () (raw-value "Unknown")))])))))

(define/pow
  (commandRouter35 [cmd : String])
  #:returns String
  (thsl-src-control! "tests/critical-review-35-tests.tesl" 947 (list (cons 'cmd *cmd)) (lambda () (let ([tesl-case-19 *cmd]) (cond [(equal? *tesl-case-19 "help") (thsl-src! "tests/critical-review-35-tests.tesl" 948 (list) (lambda () (raw-value "showing help")))] [(equal? *tesl-case-19 "quit") (thsl-src! "tests/critical-review-35-tests.tesl" 949 (list) (lambda () (raw-value "goodbye")))] [(equal? *tesl-case-19 "version") (thsl-src! "tests/critical-review-35-tests.tesl" 950 (list) (lambda () (raw-value "1.0.0")))] [#t (let ([other *tesl-case-19]) (thsl-src! "tests/critical-review-35-tests.tesl" 951 (list (cons 'other other)) (lambda () (raw-value (format "unknown: ~a" (tesl-display-val *other))))))])))))

(define/pow
  (classify35 [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-35-tests.tesl" 980 (list (cons 'n *n)) (lambda () (if (< *n 0) (raw-value "negative") (if (tesl-equal? *n 0) (raw-value "zero") (if (< *n 10) (raw-value "small") (raw-value "large")))))))

(module+ test
  (require rackunit)
  (test-case "T01 \226\128\148 correct subject proof works"
  (define a (thsl-src! "tests/critical-review-35-tests.tesl" 184 (list) (lambda () 10)))
  (define tesl-checked-20 (checkNonNeg35 a))
  (when (check-fail? tesl-checked-20)
    (raise-user-error 'tesl-test "unexpected failure in let checkedA: ~a" (check-fail-message tesl-checked-20)))
  (define checkedA tesl-checked-20)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 186 (list (cons 'checkedA checkedA) (cons 'a a)) (lambda () (requireNonNeg35 checkedA)))) 11)
  (define zero (thsl-src! "tests/critical-review-35-tests.tesl" 187 (list (cons 'checkedA checkedA) (cons 'a a)) (lambda () 0)))
  (define tesl-checked-21 (checkNonNeg35 zero))
  (when (check-fail? tesl-checked-21)
    (raise-user-error 'tesl-test "unexpected failure in let checkedZero: ~a" (check-fail-message tesl-checked-21)))
  (define checkedZero tesl-checked-21)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 189 (list (cons 'checkedZero checkedZero) (cons 'zero zero) (cons 'checkedA checkedA) (cons 'a a)) (lambda () (requireNonNeg35 checkedZero)))) 1)
  )

  (test-case "T01b \226\128\148 check rejects negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 193 (list) (lambda ()
                          (checkNonNeg35 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkNonNeg35 -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 194 (list) (lambda ()
                          (checkNonNeg35 -999))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkNonNeg35 -999"))
  )

  (test-case "T02 \226\128\148 composed check first failure"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 218 (list) (lambda ()
                          ((check-and checkA35 checkB35) "XB"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and checkA35 checkB35) \"XB\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 219 (list) (lambda ()
                          ((check-and checkA35 checkB35) "AX"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and checkA35 checkB35) \"AX\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 220 (list) (lambda ()
                          ((check-and checkA35 checkB35) "XX"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and checkA35 checkB35) \"XX\""))
  (define s (thsl-src! "tests/critical-review-35-tests.tesl" 221 (list) (lambda () "AB")))
  (define tesl-checked-22 ((check-and checkA35 checkB35) s))
  (when (check-fail? tesl-checked-22)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl-checked-22)))
  (define result tesl-checked-22)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 223 (list (cons 'result result) (cons 's s)) (lambda () (tesl_import_String_length result)))) 2)
  )

  (test-case "T02b \226\128\148 reversed composition"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 228 (list) (lambda ()
                          ((check-and checkB35 checkA35) "AX"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and checkB35 checkA35) \"AX\""))
  (define s2 (thsl-src! "tests/critical-review-35-tests.tesl" 229 (list) (lambda () "AB")))
  (define tesl-checked-23 ((check-and checkB35 checkA35) s2))
  (when (check-fail? tesl-checked-23)
    (raise-user-error 'tesl-test "unexpected failure in let result2: ~a" (check-fail-message tesl-checked-23)))
  (define result2 tesl-checked-23)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 231 (list (cons 'result2 result2) (cons 's2 s2)) (lambda () (tesl_import_String_length result2)))) 2)
  )

  (test-case "T03 \226\128\148 double filterCheck"
  (define result (thsl-src! "tests/critical-review-35-tests.tesl" 258 (list) (lambda () (doubleFilter35 (list 1 2 3 4 22 100 6 18)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 259 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 4)
  (define empty (thsl-src! "tests/critical-review-35-tests.tesl" 260 (list (cons 'result result)) (lambda () (doubleFilter35 (list 1 3 5 7)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 261 (list (cons 'empty empty) (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value empty)))))) 0)
  (define allPass (thsl-src! "tests/critical-review-35-tests.tesl" 262 (list (cons 'empty empty) (cons 'result result)) (lambda () (doubleFilter35 (list 2 4 6)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 263 (list (cons 'allPass allPass) (cons 'empty empty) (cons 'result result)) (lambda () allPass))) (list 2 4 6))
  )

  (test-case "T04 \226\128\148 establish unconditional"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 282 (list) (lambda () (useEstablish35 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 283 (list) (lambda () (useEstablish35 -42)))) -126)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 284 (list) (lambda () (useEstablish35 100)))) 300)
  )

  (test-case "T05 \226\128\148 proof decomposition and reattachment"
  (define raw (thsl-src! "tests/critical-review-35-tests.tesl" 307 (list) (lambda () 5)))
  (define tesl-checked-24 (checkPosDecomp35 raw))
  (when (check-fail? tesl-checked-24)
    (raise-user-error 'tesl-test "unexpected failure in let checked: ~a" (check-fail-message tesl-checked-24)))
  (define checked tesl-checked-24)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 309 (list (cons 'checked checked) (cons 'raw raw)) (lambda () (decomposeAndReattach35 checked)))) 105)
  (define raw2 (thsl-src! "tests/critical-review-35-tests.tesl" 310 (list (cons 'checked checked) (cons 'raw raw)) (lambda () 1)))
  (define tesl-checked-25 (checkPosDecomp35 raw2))
  (when (check-fail? tesl-checked-25)
    (raise-user-error 'tesl-test "unexpected failure in let checked2: ~a" (check-fail-message tesl-checked-25)))
  (define checked2 tesl-checked-25)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 312 (list (cons 'checked2 checked2) (cons 'raw2 raw2) (cons 'checked checked) (cons 'raw raw)) (lambda () (decomposeAndReattach35 checked2)))) 101)
  )

  (test-case "T06 \226\128\148 recursive ADT list"
  (define xs (thsl-src! "tests/critical-review-35-tests.tesl" 339 (list) (lambda () (raw-value (Cons35 1 (Cons35 2 (Cons35 3 Nil35)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 340 (list (cons 'xs xs)) (lambda () (myLength35 xs)))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 341 (list (cons 'xs xs)) (lambda () (myLength35 Nil35)))) 0)
  (define doubled (thsl-src! "tests/critical-review-35-tests.tesl" 342 (list (cons 'xs xs)) (lambda () (myMap35 (let () (define/pow (tesl-lambda-26 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-26) xs))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 343 (list (cons 'doubled doubled) (cons 'xs xs)) (lambda () (myLength35 doubled)))) 3)
  (define ys (thsl-src! "tests/critical-review-35-tests.tesl" 344 (list (cons 'doubled doubled) (cons 'xs xs)) (lambda () (raw-value (Cons35 4 (Cons35 5 Nil35))))))
  (define combined (thsl-src! "tests/critical-review-35-tests.tesl" 345 (list (cons 'ys ys) (cons 'doubled doubled) (cons 'xs xs)) (lambda () (myAppend35 xs ys))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 346 (list (cons 'combined combined) (cons 'ys ys) (cons 'doubled doubled) (cons 'xs xs)) (lambda () (myLength35 combined)))) 5)
  )

  (test-case "T07 \226\128\148 nested Maybe"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 362 (list) (lambda () (flattenMaybe35 Nothing)))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 363 (list) (lambda () (flattenMaybe35 (raw-value (Something Nothing)))))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 364 (list) (lambda () (flattenMaybe35 (raw-value (Something (raw-value (Something 42)))))))) (raw-value (Something 42)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 365 (list) (lambda () (flattenMaybe35 (raw-value (Something (raw-value (Something 0)))))))) (raw-value (Something 0)))
  )

  (test-case "T08 \226\128\148 record field proof propagation"
  (define raw (thsl-src! "tests/critical-review-35-tests.tesl" 392 (list) (lambda () "hello")))
  (define tesl-checked-27 (checkSafeTitle35 raw))
  (when (check-fail? tesl-checked-27)
    (raise-user-error 'tesl-test "unexpected failure in let safe: ~a" (check-fail-message tesl-checked-27)))
  (define safe tesl-checked-27)
  (define rec (thsl-src! "tests/critical-review-35-tests.tesl" 394 (list (cons 'safe safe) (cons 'raw raw)) (lambda () (ProvenRecord35 #:title safe))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 395 (list (cons 'rec rec) (cons 'safe safe) (cons 'raw raw)) (lambda () (readAndConsume35 rec)))) 5)
  )

  (test-case "T08b \226\128\148 proof boundary check"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 399 (list) (lambda ()
                          (checkSafeTitle35 ""))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSafeTitle35 \"\""))
  (define long (thsl-src! "tests/critical-review-35-tests.tesl" 400 (list) (lambda () "aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeaaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeef")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 401 (list (cons 'long long)) (lambda ()
                          (checkSafeTitle35 long))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSafeTitle35 long"))
  )

  (test-case "T09 \226\128\148 integer identity and absorption"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 409 (list) (lambda () (+ 0 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 410 (list) (lambda () (* 0 12345)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 411 (list) (lambda () (* 1 1)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 412 (list) (lambda () (* -1 -1)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 413 (list) (lambda () (* -1 0)))) 0)
  (define maxish (thsl-src! "tests/critical-review-35-tests.tesl" 414 (list) (lambda () 4611686018427387903)))
  (check-true (thsl-src! "tests/critical-review-35-tests.tesl" 415 (list (cons 'maxish maxish)) (lambda () (> (raw-value maxish) 0))))
  (define minish (thsl-src! "tests/critical-review-35-tests.tesl" 416 (list (cons 'maxish maxish)) (lambda () -4611686018427387903)))
  (check-true (thsl-src! "tests/critical-review-35-tests.tesl" 417 (list (cons 'minish minish) (cons 'maxish maxish)) (lambda () (< (raw-value minish) 0))))
  )

  (test-case "T09b \226\128\148 Int stdlib"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 421 (list) (lambda () (raw-value (tesl_import_Int_abs 5))))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 422 (list) (lambda () (raw-value (tesl_import_Int_abs -5))))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 423 (list) (lambda () (raw-value (tesl_import_Int_abs 0))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 424 (list) (lambda () (raw-value (tesl_import_Int_min 3 7))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 425 (list) (lambda () (raw-value (tesl_import_Int_max 3 7))))) 7)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 426 (list) (lambda () (raw-value (tesl_import_Int_min -1 1))))) -1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 427 (list) (lambda () (raw-value (tesl_import_Int_gcd 12 8))))) 4)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 428 (list) (lambda () (raw-value (tesl_import_Int_gcd 7 13))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 429 (list) (lambda () (raw-value (tesl_import_Int_pow 2 10))))) 1024)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 430 (list) (lambda () (raw-value (tesl_import_Int_pow 0 5))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 431 (list) (lambda () (raw-value (tesl_import_Int_pow 5 0))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 432 (list) (lambda () (raw-value (tesl_import_Int_isEven 4))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 433 (list) (lambda () (raw-value (tesl_import_Int_isOdd 3))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 434 (list) (lambda () (raw-value (tesl_import_Int_isEven 0))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 435 (list) (lambda () (raw-value (tesl_import_Int_sign 5))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 436 (list) (lambda () (raw-value (tesl_import_Int_sign -5))))) -1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 437 (list) (lambda () (raw-value (tesl_import_Int_sign 0))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 438 (list) (lambda () (raw-value (tesl_import_Int_toString 42))))) "42")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 439 (list) (lambda () (raw-value (tesl_import_Int_toString -7))))) "-7")
  )

  (test-case "T10 \226\128\148 float proof-total division"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 454 (list) (lambda () (safeFloatDiv35 10. 2.)))) (raw-value (Something 5.)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 455 (list) (lambda () (safeFloatDiv35 0. 1.)))) (raw-value (Something 0.)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 456 (list) (lambda () (safeFloatDiv35 10. 0.)))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 457 (list) (lambda () (safeFloatDiv35 -6. 3.)))) (raw-value (Something -2.)))
  )

  (test-case "T10b \226\128\148 float stdlib"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 461 (list) (lambda () (raw-value (tesl_import_Float_round 3.7))))) 4)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 462 (list) (lambda () (raw-value (tesl_import_Float_floor 3.7))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 463 (list) (lambda () (raw-value (tesl_import_Float_ceil 3.2))))) 4)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 464 (list) (lambda () (raw-value (tesl_import_Float_abs -2.5))))) 2.5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 465 (list) (lambda () (raw-value (tesl_import_Float_abs 2.5))))) 2.5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 466 (list) (lambda () (raw-value (tesl_import_Float_isNaN 1.))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 467 (list) (lambda () (raw-value (tesl_import_Float_isInfinite 1.))))) #f)
  )

  (test-case "T11 \226\128\148 boolean logic"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 481 (list) (lambda () (xor35 #t #f)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 482 (list) (lambda () (xor35 #f #t)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 483 (list) (lambda () (xor35 #t #t)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 484 (list) (lambda () (xor35 #f #f)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 485 (list) (lambda () (nand35 #t #t)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 486 (list) (lambda () (nand35 #t #f)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 487 (list) (lambda () (nand35 #f #t)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 488 (list) (lambda () (nand35 #f #f)))) #t)
  )

  (test-case "T12 \226\128\148 newtype round-trip"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 502 (list) (lambda () (wrapAndUnwrap35 "user-1")))) "user-1")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 503 (list) (lambda () (wrapAndUnwrap35 "")))) "")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 504 (list) (lambda () (wrapAndUnwrap35 "abc")))) "abc")
  )

  (test-case "T12b \226\128\148 newtype identity"
  (define uid1 (thsl-src! "tests/critical-review-35-tests.tesl" 508 (list) (lambda () (raw-value (UserId35 "a")))))
  (define uid2 (thsl-src! "tests/critical-review-35-tests.tesl" 509 (list (cons 'uid1 uid1)) (lambda () (raw-value (UserId35 "a")))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 510 (list (cons 'uid2 uid2) (cons 'uid1 uid1)) (lambda () uid1))) uid2)
  (define uid3 (thsl-src! "tests/critical-review-35-tests.tesl" 511 (list (cons 'uid2 uid2) (cons 'uid1 uid1)) (lambda () (raw-value (UserId35 "b")))))
  (check-not-equal? (thsl-src! "tests/critical-review-35-tests.tesl" 512 (list (cons 'uid3 uid3) (cons 'uid2 uid2) (cons 'uid1 uid1)) (lambda () uid1)) uid3)
  )

  (test-case "T13 \226\128\148 case guard with bool"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 534 (list) (lambda () (classifyPrio35 Critical35 #f)))) "must do now")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 535 (list) (lambda () (classifyPrio35 Critical35 #t)))) "must do now")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 536 (list) (lambda () (classifyPrio35 High35 #t)))) "escalated")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 537 (list) (lambda () (classifyPrio35 High35 #f)))) "important")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 538 (list) (lambda () (classifyPrio35 Medium35 #f)))) "normal")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 539 (list) (lambda () (classifyPrio35 Low35 #t)))) "backlog")
  )

  (test-case "T14 \226\128\148 List.foldl"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 556 (list) (lambda () (sumFold35 (list 1 2 3 4 5))))) 15)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 557 (list) (lambda () (sumFold35 (list))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 558 (list) (lambda () (sumFold35 (list -1 1))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 559 (list) (lambda () (productFold35 (list 1 2 3 4))))) 24)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 560 (list) (lambda () (productFold35 (list))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 561 (list) (lambda () (productFold35 (list 5 0 3))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 562 (list) (lambda () (concatFold35 (list "a" "b" "c"))))) "abc")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 563 (list) (lambda () (concatFold35 (list))))) "")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 564 (list) (lambda () (concatFold35 (list "hello"))))) "hello")
  )

  (test-case "T15 \226\128\148 applyN with lambda"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 578 (list) (lambda () (applyN35 (let () (define/pow (tesl-lambda-28 [x : Integer]) #:returns Integer (+ *x 1)) tesl-lambda-28) 5 0)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 579 (list) (lambda () (applyN35 (let () (define/pow (tesl-lambda-29 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-29) 3 1)))) 8)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 580 (list) (lambda () (applyN35 (let () (define/pow (tesl-lambda-30 [x : Integer]) #:returns Integer x) tesl-lambda-30) 100 42)))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 581 (list) (lambda () (applyN35 (let () (define/pow (tesl-lambda-31 [x : Integer]) #:returns Integer (+ *x 10)) tesl-lambda-31) 0 5)))) 5)
  )

  (test-case "T16 \226\128\148 partial application"
  (define add1 (thsl-src! "tests/critical-review-35-tests.tesl" 591 (list) (lambda () (lambda (tesl-p-32-0) (lambda (tesl-p-32-1) (add335 1 tesl-p-32-0 tesl-p-32-1))))))
  (define add1_2 (thsl-src! "tests/critical-review-35-tests.tesl" 592 (list (cons 'add1 add1)) (lambda () (add1 2))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 593 (list (cons 'add1_2 add1_2) (cons 'add1 add1)) (lambda () (add1_2 3)))) 6)
  (define add10_20 (thsl-src! "tests/critical-review-35-tests.tesl" 594 (list (cons 'add1_2 add1_2) (cons 'add1 add1)) (lambda () (lambda (tesl-p-33-0) (add335 10 20 tesl-p-33-0)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 595 (list (cons 'add10_20 add10_20) (cons 'add1_2 add1_2) (cons 'add1 add1)) (lambda () (add10_20 30)))) 60)
  (define addAll (thsl-src! "tests/critical-review-35-tests.tesl" 596 (list (cons 'add10_20 add10_20) (cons 'add1_2 add1_2) (cons 'add1 add1)) (lambda () (tesl_import_List_map (raw-value (lambda (tesl-p-34-0) (add335 0 0 tesl-p-34-0))) (list 1 2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 597 (list (cons 'addAll addAll) (cons 'add10_20 add10_20) (cons 'add1_2 add1_2) (cons 'add1 add1)) (lambda () addAll))) (list 1 2 3))
  )

  (test-case "T17 \226\128\148 sequential check accumulation"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 628 (list) (lambda () (sequentialChecks35 42)))) "valid: 42")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 629 (list) (lambda () (sequentialChecks35 1)))) "valid: 1")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 630 (list) (lambda () (sequentialChecks35 999)))) "valid: 999")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 631 (list) (lambda ()
                          (checkPos35 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPos35 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 632 (list) (lambda ()
                          (checkPos35 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPos35 -1"))
  (define posRaw (thsl-src! "tests/critical-review-35-tests.tesl" 633 (list) (lambda () 5)))
  (define tesl-checked-35 (checkPos35 posRaw))
  (when (check-fail? tesl-checked-35)
    (raise-user-error 'tesl-test "unexpected failure in let posVal: ~a" (check-fail-message tesl-checked-35)))
  (define posVal tesl-checked-35)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 635 (list (cons 'posVal posVal) (cons 'posRaw posRaw)) (lambda ()
                          ((raw-value (checkSmallInt35 1000)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkSmallInt35 1000)) (list)"))
  )

  (test-case "T18 \226\128\148 string edge cases"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 643 (list) (lambda () (tesl_import_String_length "")))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 644 (list) (lambda () (tesl_import_String_isEmpty "")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 645 (list) (lambda () (tesl_import_String_trim "   ")))) "")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 646 (list) (lambda () (tesl_import_String_contains "abc" "")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 647 (list) (lambda () (tesl_import_String_contains "" "a")))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 648 (list) (lambda () (tesl_import_String_startsWith "" "")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 649 (list) (lambda () (tesl_import_String_endsWith "" "")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 650 (list) (lambda () (tesl_import_String_replace "aaa" "a" "b")))) "bbb")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 651 (list) (lambda () (tesl_import_String_split "a,b,c" ",")))) (list "a" "b" "c"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 652 (list) (lambda () (tesl_import_String_split "" ",")))) (list ""))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 653 (list) (lambda () (tesl_import_String_join (list "a" "b" "c") ", ")))) "a, b, c")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 654 (list) (lambda () (tesl_import_String_join (list "a" "b") "")))) "ab")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 655 (list) (lambda () (tesl_import_String_indexOf "hello" "ll")))) (raw-value (Something 2)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 656 (list) (lambda () (tesl_import_String_indexOf "hello" "xyz")))) Nothing)
  )

  (test-case "T18b \226\128\148 string stdlib proofs"
  (define trimmed (thsl-src! "tests/critical-review-35-tests.tesl" 660 (list) (lambda () (tesl_import_String_trim "  hello  "))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 661 (list (cons 'trimmed trimmed)) (lambda () trimmed))) "hello")
  (define upper (thsl-src! "tests/critical-review-35-tests.tesl" 662 (list (cons 'trimmed trimmed)) (lambda () (tesl_import_String_toUpper "hello"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 663 (list (cons 'upper upper) (cons 'trimmed trimmed)) (lambda () upper))) "HELLO")
  (define lower (thsl-src! "tests/critical-review-35-tests.tesl" 664 (list (cons 'upper upper) (cons 'trimmed trimmed)) (lambda () (tesl_import_String_toLower "HELLO"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 665 (list (cons 'lower lower) (cons 'upper upper) (cons 'trimmed trimmed)) (lambda () lower))) "hello")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 666 (list (cons 'lower lower) (cons 'upper upper) (cons 'trimmed trimmed)) (lambda () (tesl_import_String_toUpper "")))) "")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 667 (list (cons 'lower lower) (cons 'upper upper) (cons 'trimmed trimmed)) (lambda () (tesl_import_String_toLower "")))) "")
  )

  (test-case "T18c \226\128\148 string interpolation with expressions"
  (define n (thsl-src! "tests/critical-review-35-tests.tesl" 671 (list) (lambda () 42)))
  (define s (thsl-src! "tests/critical-review-35-tests.tesl" 672 (list (cons 'n n)) (lambda () (format "the answer is ~a" (tesl-display-val n)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 673 (list (cons 's s) (cons 'n n)) (lambda () s))) "the answer is 42")
  (define prefix (thsl-src! "tests/critical-review-35-tests.tesl" 674 (list (cons 's s) (cons 'n n)) (lambda () "pre")))
  (define suffix (thsl-src! "tests/critical-review-35-tests.tesl" 675 (list (cons 'prefix prefix) (cons 's s) (cons 'n n)) (lambda () "suf")))
  (define combined (thsl-src! "tests/critical-review-35-tests.tesl" 676 (list (cons 'suffix suffix) (cons 'prefix prefix) (cons 's s) (cons 'n n)) (lambda () (format "~a-~a" (tesl-display-val prefix) (tesl-display-val suffix)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 677 (list (cons 'combined combined) (cons 'suffix suffix) (cons 'prefix prefix) (cons 's s) (cons 'n n)) (lambda () combined))) "pre-suf")
  )

  (test-case "T19 \226\128\148 Dict roundtrip"
  (define d (thsl-src! "tests/critical-review-35-tests.tesl" 685 (list) (lambda () (raw-value (tesl_import_Dict_insert "a" 1 (raw-value (tesl_import_Dict_insert "b" 2 tesl_import_Dict_empty)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 686 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value d)))))) 2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 687 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_member "a" (raw-value d)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 688 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_member "c" (raw-value d)))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 689 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_lookup "a" (raw-value d)))))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 690 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_lookup "c" (raw-value d)))))) Nothing)
  (define d2 (thsl-src! "tests/critical-review-35-tests.tesl" 691 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_insert "a" 99 (raw-value d))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 692 (list (cons 'd2 d2) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_lookup "a" (raw-value d2)))))) (raw-value (Something 99)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 693 (list (cons 'd2 d2) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value d2)))))) 2)
  )

  (test-case "T19b \226\128\148 Dict.requireKey and Dict.get"
  (define d (thsl-src! "tests/critical-review-35-tests.tesl" 697 (list) (lambda () (raw-value (tesl_import_Dict_insert "key" 42 tesl_import_Dict_empty)))))
  (define keyStr (thsl-src! "tests/critical-review-35-tests.tesl" 698 (list (cons 'd d)) (lambda () "key")))
  (define tesl-checked-36 (tesl_import_Dict_requireKey keyStr d))
  (when (check-fail? tesl-checked-36)
    (raise-user-error 'tesl-test "unexpected failure in let checked: ~a" (check-fail-message tesl-checked-36)))
  (define checked tesl-checked-36)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 700 (list (cons 'checked checked) (cons 'keyStr keyStr) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_get (raw-value keyStr) checked))))) 42)
  (define missingKey (thsl-src! "tests/critical-review-35-tests.tesl" 701 (list (cons 'checked checked) (cons 'keyStr keyStr) (cons 'd d)) (lambda () "missing")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 702 (list (cons 'missingKey missingKey) (cons 'checked checked) (cons 'keyStr keyStr) (cons 'd d)) (lambda ()
                          ((raw-value (tesl_import_Dict_requireKey (raw-value missingKey) (raw-value d))) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (tesl_import_Dict_requireKey (raw-value missingKey) (raw-value d))) (list)"))
  )

  (test-case "T19c \226\128\148 Dict isEmpty and fromList"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 706 (list) (lambda () (raw-value (tesl_import_Dict_isEmpty tesl_import_Dict_empty))))) #t)
  (define d (thsl-src! "tests/critical-review-35-tests.tesl" 707 (list) (lambda () (raw-value (tesl_import_Dict_insert "x" 1 tesl_import_Dict_empty)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 708 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_isEmpty (raw-value d)))))) #f)
  (define d2 (thsl-src! "tests/critical-review-35-tests.tesl" 709 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 1) (Tuple2 "b" 2)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 710 (list (cons 'd2 d2) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value d2)))))) 2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 711 (list (cons 'd2 d2) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_lookup "a" (raw-value d2)))))) (raw-value (Something 1)))
  )

  (test-case "T20 \226\128\148 Set operations"
  (define s1 (thsl-src! "tests/critical-review-35-tests.tesl" 719 (list) (lambda () (raw-value (tesl_import_Set_fromList (list 1 2 3 2 1))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 720 (list (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_size (raw-value s1)))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 721 (list (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 1 (raw-value s1)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 722 (list (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 4 (raw-value s1)))))) #f)
  (define s2 (thsl-src! "tests/critical-review-35-tests.tesl" 723 (list (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_fromList (list 3 4 5))))))
  (define unionSet (thsl-src! "tests/critical-review-35-tests.tesl" 724 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_union (raw-value s1) (raw-value s2))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 725 (list (cons 'unionSet unionSet) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_size (raw-value unionSet)))))) 5)
  (define interSet (thsl-src! "tests/critical-review-35-tests.tesl" 726 (list (cons 'unionSet unionSet) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_intersection (raw-value s1) (raw-value s2))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 727 (list (cons 'interSet interSet) (cons 'unionSet unionSet) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_size (raw-value interSet)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 728 (list (cons 'interSet interSet) (cons 'unionSet unionSet) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 3 (raw-value interSet)))))) #t)
  (define diffSet (thsl-src! "tests/critical-review-35-tests.tesl" 729 (list (cons 'interSet interSet) (cons 'unionSet unionSet) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_difference (raw-value s1) (raw-value s2))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 730 (list (cons 'diffSet diffSet) (cons 'interSet interSet) (cons 'unionSet unionSet) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_size (raw-value diffSet)))))) 2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 731 (list (cons 'diffSet diffSet) (cons 'interSet interSet) (cons 'unionSet unionSet) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 1 (raw-value diffSet)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 732 (list (cons 'diffSet diffSet) (cons 'interSet interSet) (cons 'unionSet unionSet) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 3 (raw-value diffSet)))))) #f)
  )

  (test-case "T20b \226\128\148 Set edge cases"
  (define empty (thsl-src! "tests/critical-review-35-tests.tesl" 736 (list) (lambda () (raw-value (tesl_import_Set_fromList (list))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 737 (list (cons 'empty empty)) (lambda () (raw-value (tesl_import_Set_isEmpty (raw-value empty)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 738 (list (cons 'empty empty)) (lambda () (raw-value (tesl_import_Set_size (raw-value empty)))))) 0)
  (define single (thsl-src! "tests/critical-review-35-tests.tesl" 739 (list (cons 'empty empty)) (lambda () (raw-value (tesl_import_Set_insert 1 (raw-value empty))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 740 (list (cons 'single single) (cons 'empty empty)) (lambda () (raw-value (tesl_import_Set_size (raw-value single)))))) 1)
  )

  (test-case "T21 \226\128\148 parameterized pair ADT"
  (define p (thsl-src! "tests/critical-review-35-tests.tesl" 759 (list) (lambda () (raw-value (MkPair35 42 "hello")))))
  (define swapped (thsl-src! "tests/critical-review-35-tests.tesl" 760 (list (cons 'p p)) (lambda () (swapPair35 p))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 761 (list (cons 'swapped swapped) (cons 'p p)) (lambda () swapped))) (raw-value (MkPair35 "hello" 42)))
  (define mapped (thsl-src! "tests/critical-review-35-tests.tesl" 762 (list (cons 'swapped swapped) (cons 'p p)) (lambda () (mapPair35 (let () (define/pow (tesl-lambda-37 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-37) (let () (define/pow (tesl-lambda-38 [s : String]) #:returns String (string-append *s "!")) tesl-lambda-38) p))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 763 (list (cons 'mapped mapped) (cons 'swapped swapped) (cons 'p p)) (lambda () mapped))) (raw-value (MkPair35 84 "hello!")))
  )

  (test-case "T22 \226\128\148 forgetFact and re-check"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 782 (list) (lambda () (verifyForgetAndRecheck35 5)))) (raw-value (Something 105)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 783 (list) (lambda () (verifyForgetAndRecheck35 0)))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 784 (list) (lambda () (verifyForgetAndRecheck35 1)))) (raw-value (Something 101)))
  )

  (test-case "T23 \226\128\148 list edge cases"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 792 (list) (lambda () (raw-value (tesl_import_List_head (list)))))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 793 (list) (lambda () (raw-value (tesl_import_List_head (list 1)))))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 794 (list) (lambda () (tesl_import_List_reverse (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 795 (list) (lambda () (tesl_import_List_reverse (list 1))))) (list 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 796 (list) (lambda () (tesl_import_List_sort (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 797 (list) (lambda () (tesl_import_List_sort (list 1))))) (list 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 798 (list) (lambda () (raw-value (tesl_import_List_sum (list)))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 799 (list) (lambda () (raw-value (tesl_import_List_sum (list 42)))))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 800 (list) (lambda () (raw-value (tesl_import_List_contains 1 (list 1 2 3)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 801 (list) (lambda () (raw-value (tesl_import_List_contains 4 (list 1 2 3)))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 802 (list) (lambda () (raw-value (tesl_import_List_contains 1 (list)))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 803 (list) (lambda () (tesl_import_List_unique (list 1 1 2 2 3))))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 804 (list) (lambda () (tesl_import_List_unique (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 805 (list) (lambda () (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-39 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-39) (list 0 0 1)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 806 (list) (lambda () (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-40 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-40) (list 0 0 0)))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 807 (list) (lambda () (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-41 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-41) (list 1 2 3)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 808 (list) (lambda () (raw-value (tesl_import_List_all (let () (define/pow (tesl-lambda-42 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-42) (list 1 0 3)))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 809 (list) (lambda () (raw-value (tesl_import_List_count (let () (define/pow (tesl-lambda-43 [x : Integer]) #:returns Boolean (> *x 0)) tesl-lambda-43) (list 1 -1 2 -2 3)))))) 3)
  )

  (test-case "T23b \226\128\148 List.range and List.take/drop"
  (define raw0 (thsl-src! "tests/critical-review-35-tests.tesl" 813 (list) (lambda () 0)))
  (define raw3 (thsl-src! "tests/critical-review-35-tests.tesl" 814 (list (cons 'raw0 raw0)) (lambda () 3)))
  (define raw5 (thsl-src! "tests/critical-review-35-tests.tesl" 815 (list (cons 'raw3 raw3) (cons 'raw0 raw0)) (lambda () 5)))
  (define tesl-checked-44 (tesl_import_Int_nonNegative raw0))
  (when (check-fail? tesl-checked-44)
    (raise-user-error 'tesl-test "unexpected failure in let n0: ~a" (check-fail-message tesl-checked-44)))
  (define n0 tesl-checked-44)
  (define tesl-checked-45 (tesl_import_Int_nonNegative raw3))
  (when (check-fail? tesl-checked-45)
    (raise-user-error 'tesl-test "unexpected failure in let n3: ~a" (check-fail-message tesl-checked-45)))
  (define n3 tesl-checked-45)
  (define tesl-checked-46 (tesl_import_Int_nonNegative raw5))
  (when (check-fail? tesl-checked-46)
    (raise-user-error 'tesl-test "unexpected failure in let n5: ~a" (check-fail-message tesl-checked-46)))
  (define n5 tesl-checked-46)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 819 (list (cons 'n5 n5) (cons 'n3 n3) (cons 'n0 n0) (cons 'raw5 raw5) (cons 'raw3 raw3) (cons 'raw0 raw0)) (lambda () (tesl_import_List_take n0 (list 1 2 3))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 820 (list (cons 'n5 n5) (cons 'n3 n3) (cons 'n0 n0) (cons 'raw5 raw5) (cons 'raw3 raw3) (cons 'raw0 raw0)) (lambda () (tesl_import_List_take n3 (list 1 2 3 4 5))))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 821 (list (cons 'n5 n5) (cons 'n3 n3) (cons 'n0 n0) (cons 'raw5 raw5) (cons 'raw3 raw3) (cons 'raw0 raw0)) (lambda () (tesl_import_List_drop n0 (list 1 2 3))))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 822 (list (cons 'n5 n5) (cons 'n3 n3) (cons 'n0 n0) (cons 'raw5 raw5) (cons 'raw3 raw3) (cons 'raw0 raw0)) (lambda () (tesl_import_List_drop n3 (list 1 2 3 4 5))))) (list 4 5))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 823 (list (cons 'n5 n5) (cons 'n3 n3) (cons 'n0 n0) (cons 'raw5 raw5) (cons 'raw3 raw3) (cons 'raw0 raw0)) (lambda () (tesl_import_List_take n5 (list 1 2 3))))) (list 1 2 3))
  )

  (test-case "T24 \226\128\148 arithmetic properties"
  ; property: addition commutative
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)])
      (when (and (> (raw-value a) -10000) (< (raw-value a) 10000) (> (raw-value b) -10000) (< (raw-value b) 10000)) (check-true (tesl-equal? (+ (raw-value a) (raw-value b)) (+ (raw-value b) (raw-value a))) "addition commutative"))
    ))
  ; property: multiplication commutative
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)])
      (when (and (> (raw-value a) -1000) (< (raw-value a) 1000) (> (raw-value b) -1000) (< (raw-value b) 1000)) (check-true (tesl-equal? (* (raw-value a) (raw-value b)) (* (raw-value b) (raw-value a))) "multiplication commutative"))
    ))
  ; property: addition associative
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)] [c (- (random 2000001) 1000000)])
      (when (and (> (raw-value a) -1000) (< (raw-value a) 1000) (> (raw-value b) -1000) (< (raw-value b) 1000) (> (raw-value c) -1000) (< (raw-value c) 1000)) (check-true (tesl-equal? (+ (+ (raw-value a) (raw-value b)) (raw-value c)) (+ (raw-value a) (+ (raw-value b) (raw-value c)))) "addition associative"))
    ))
  )

  (test-case "T25 \226\128\148 list properties"
  ; property: reverse involution
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (tesl-equal? (raw-value (tesl_import_List_reverse (raw-value (tesl_import_List_reverse (raw-value xs))))) (raw-value xs)) "reverse involution")
    ))
  ; property: sort idempotent
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (tesl-equal? (raw-value (tesl_import_List_sort (raw-value (tesl_import_List_sort (raw-value xs))))) (raw-value (tesl_import_List_sort (raw-value xs)))) "sort idempotent")
    ))
  ; property: length non-negative
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (>= (raw-value (tesl_import_List_length (raw-value xs))) 0) "length non-negative")
    ))
  ; property: append length additive
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))] [ys (map (lambda (_) (- (random 2000001) 1000000)) (make-list (random 8) #f))])
      (check-true (tesl-equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_List_append (raw-value xs) (raw-value ys))))) (+ (raw-value (tesl_import_List_length (raw-value xs))) (raw-value (tesl_import_List_length (raw-value ys))))) "append length additive")
    ))
  )

  (test-case "T26 \226\128\148 Either partition"
  (define xs (thsl-src! "tests/critical-review-35-tests.tesl" 866 (list) (lambda () (list (Left "e1") (Right 1) (Left "e2") (Right 2)))))
  (define result (thsl-src! "tests/critical-review-35-tests.tesl" 867 (list (cons 'xs xs)) (lambda () (raw-value (tesl_import_Either_partition (raw-value xs))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 868 (list (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value result)))))) (list "e1" "e2"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 869 (list (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value result)))))) (list 1 2))
  (define allLeft (thsl-src! "tests/critical-review-35-tests.tesl" 870 (list (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_Either_partition (list (Left "a") (Left "b")))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 871 (list (cons 'allLeft allLeft) (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value allLeft)))))) (list "a" "b"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 872 (list (cons 'allLeft allLeft) (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value allLeft)))))) (list))
  (define empty (thsl-src! "tests/critical-review-35-tests.tesl" 873 (list (cons 'allLeft allLeft) (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_Either_partition (list))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 874 (list (cons 'empty empty) (cons 'allLeft allLeft) (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value empty)))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 875 (list (cons 'empty empty) (cons 'allLeft allLeft) (cons 'result result) (cons 'xs xs)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value empty)))))) (list))
  )

  (test-case "T27 \226\128\148 fall-through"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 898 (list) (lambda () (isWarm35 Spring35)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 899 (list) (lambda () (isWarm35 Summer35)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 900 (list) (lambda () (isWarm35 Autumn35)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 901 (list) (lambda () (isWarm35 Winter35)))) #f)
  )

  (test-case "T28 \226\128\148 Int.divide with proof"
  (define rawDivisor (thsl-src! "tests/critical-review-35-tests.tesl" 909 (list) (lambda () 3)))
  (define tesl-checked-47 (tesl_import_Int_nonZero rawDivisor))
  (when (check-fail? tesl-checked-47)
    (raise-user-error 'tesl-test "unexpected failure in let divisor: ~a" (check-fail-message tesl-checked-47)))
  (define divisor tesl-checked-47)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 911 (list (cons 'divisor divisor) (cons 'rawDivisor rawDivisor)) (lambda () (tesl_import_Int_divide 12 divisor)))) 4)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 912 (list (cons 'divisor divisor) (cons 'rawDivisor rawDivisor)) (lambda () (tesl_import_Int_divide 0 divisor)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 913 (list (cons 'divisor divisor) (cons 'rawDivisor rawDivisor)) (lambda () (tesl_import_Int_divide -12 divisor)))) -4)
  (define rawDivisor2 (thsl-src! "tests/critical-review-35-tests.tesl" 914 (list (cons 'divisor divisor) (cons 'rawDivisor rawDivisor)) (lambda () 1)))
  (define tesl-checked-48 (tesl_import_Int_nonZero rawDivisor2))
  (when (check-fail? tesl-checked-48)
    (raise-user-error 'tesl-test "unexpected failure in let divisor2: ~a" (check-fail-message tesl-checked-48)))
  (define divisor2 tesl-checked-48)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 916 (list (cons 'divisor2 divisor2) (cons 'rawDivisor2 rawDivisor2) (cons 'divisor divisor) (cons 'rawDivisor rawDivisor)) (lambda () (tesl_import_Int_divide 42 divisor2)))) 42)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-35-tests.tesl" 917 (list (cons 'divisor2 divisor2) (cons 'rawDivisor2 rawDivisor2) (cons 'divisor divisor) (cons 'rawDivisor rawDivisor)) (lambda ()
                          ((tesl_import_Int_nonZero 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (tesl_import_Int_nonZero 0) (list)"))
  )

  (test-case "T29 \226\128\148 allCheck"
  (define allPos (thsl-src! "tests/critical-review-35-tests.tesl" 925 (list) (lambda () (tesl_import_List_allCheck checkPosDecomp35 (list 1 2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 926 (list (cons 'allPos allPos)) (lambda () allPos))) (raw-value (Something (list 1 2 3))))
  (define hasBad (thsl-src! "tests/critical-review-35-tests.tesl" 927 (list (cons 'allPos allPos)) (lambda () (tesl_import_List_allCheck checkPosDecomp35 (list 1 -1 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 928 (list (cons 'hasBad hasBad) (cons 'allPos allPos)) (lambda () hasBad))) Nothing)
  (define emptyList (thsl-src! "tests/critical-review-35-tests.tesl" 929 (list (cons 'hasBad hasBad) (cons 'allPos allPos)) (lambda () (tesl_import_List_allCheck checkPosDecomp35 (list)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 930 (list (cons 'emptyList emptyList) (cons 'hasBad hasBad) (cons 'allPos allPos)) (lambda () emptyList))) (raw-value (Something (list))))
  )

  (test-case "T30 \226\128\148 literal patterns"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 954 (list) (lambda () (httpStatus35 200)))) "OK")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 955 (list) (lambda () (httpStatus35 404)))) "Not Found")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 956 (list) (lambda () (httpStatus35 418)))) "Unknown")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 957 (list) (lambda () (commandRouter35 "help")))) "showing help")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 958 (list) (lambda () (commandRouter35 "quit")))) "goodbye")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 959 (list) (lambda () (commandRouter35 "foo")))) "unknown: foo")
  )

  (test-case "T31 \226\128\148 List.zip"
  (define zipped (thsl-src! "tests/critical-review-35-tests.tesl" 967 (list) (lambda () (raw-value (tesl_import_List_zip (list 1 2 3) (list "a" "b" "c"))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 968 (list (cons 'zipped zipped)) (lambda () (raw-value (tesl_import_List_length (raw-value zipped)))))) 3)
  (define emptyZip (thsl-src! "tests/critical-review-35-tests.tesl" 969 (list (cons 'zipped zipped)) (lambda () (raw-value (tesl_import_List_zip (list) (list))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 970 (list (cons 'emptyZip emptyZip) (cons 'zipped zipped)) (lambda () (raw-value (tesl_import_List_length (raw-value emptyZip)))))) 0)
  (define unevenZip (thsl-src! "tests/critical-review-35-tests.tesl" 971 (list (cons 'emptyZip emptyZip) (cons 'zipped zipped)) (lambda () (raw-value (tesl_import_List_zip (list 1 2) (list "a" "b" "c"))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 972 (list (cons 'unevenZip unevenZip) (cons 'emptyZip emptyZip) (cons 'zipped zipped)) (lambda () (raw-value (tesl_import_List_length (raw-value unevenZip)))))) 2)
  )

  (test-case "T32 \226\128\148 nested if/else"
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 992 (list) (lambda () (classify35 -5)))) "negative")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 993 (list) (lambda () (classify35 0)))) "zero")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 994 (list) (lambda () (classify35 5)))) "small")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-35-tests.tesl" 995 (list) (lambda () (classify35 100)))) "large")
  )

)
