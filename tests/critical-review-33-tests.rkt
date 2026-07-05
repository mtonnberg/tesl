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
  (thsl-src! "tests/critical-review-33-tests.tesl" 156 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPos33 n) #:value *n) (reject "must be positive" #:http-code 400)))))

(define/pow
  (filterToPositives [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-33-tests.tesl" 162 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos33 *xs))))

(define/pow
  (emptyListForAll)
  #:returns Integer
  (let ([result (thsl-src! "tests/critical-review-33-tests.tesl" 165 (list) (lambda () (filterToPositives (list))))]) (thsl-src! "tests/critical-review-33-tests.tesl" 166 (list (cons 'result *result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))))

(define-checker
  (checkPrime33 [n : Integer])
  #:returns [n : Integer ::: (IsPrime33 n)]
  (thsl-src! "tests/critical-review-33-tests.tesl" 195 (list (cons 'n *n)) (lambda () (if (or (tesl-equal? *n 2) (or (tesl-equal? *n 3) (or (tesl-equal? *n 5) (or (tesl-equal? *n 7) (or (tesl-equal? *n 11) (tesl-equal? *n 13)))))) (accept (IsPrime33 n) #:value *n) (reject "not a small prime" #:http-code 400)))))

(define/pow
  (requiresPrime33 [n : Integer ::: (IsPrime33 n)])
  #:returns String
  (thsl-src! "tests/critical-review-33-tests.tesl" 201 (list (cons 'n *n)) (lambda () (format "prime: ~a" (tesl-display-val *n)))))

(define/pow
  (proofThroughLetChain [n : Integer ::: (IsPrime33 n)])
  #:returns String
  (let ([a (thsl-src! "tests/critical-review-33-tests.tesl" 204 (list (cons 'n *n)) (lambda () n))]) (thsl-src! "tests/critical-review-33-tests.tesl" 205 (list (cons 'a *a) (cons 'n *n)) (lambda () (raw-value (requiresPrime33 a))))))

(define-checker
  (checkShort33 [s : String])
  #:returns [s : String ::: (IsShort33 s)]
  (thsl-src! "tests/critical-review-33-tests.tesl" 227 (list (cons 's *s)) (lambda () (if (<= (raw-value (tesl_import_String_length *s)) 10) (accept (IsShort33 s) #:value *s) (reject "too long" #:http-code 400)))))

(define-checker
  (checkTrimmed33 [s : String])
  #:returns [s : String ::: (IsTrimmed33 s)]
  (let ([trimmed (thsl-src! "tests/critical-review-33-tests.tesl" 233 (list (cons 's *s)) (lambda () (tesl_import_String_trim *s)))]) (thsl-src! "tests/critical-review-33-tests.tesl" 234 (list (cons 'trimmed *trimmed) (cons 's *s)) (lambda () (if (tesl-equal? (raw-value trimmed) *s) (accept (IsTrimmed33 s) #:value *s) (reject "not trimmed" #:http-code 400))))))

(define/pow
  (requiresBothProofs33 [s : String ::: ((IsShort33 s) && (IsTrimmed33 s))])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 240 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define/pow
  (composedBoth33 [raw : String])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 243 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkShort33 raw)]) (let ([v tesl-checked-0]) (let/check ([tesl-checked-1 (checkTrimmed33 v)]) (let ([w tesl-checked-1]) (raw-value (tesl_import_String_length w)))))))))

(define-trusted
  (alwaysEstablish33 [n : Integer])
  #:returns (Fact (AlwaysValid33 n))
  (thsl-src! "tests/critical-review-33-tests.tesl" 271 (list (cons 'n *n)) (lambda () (trusted-proof (AlwaysValid33 n)))))

(define/pow
  (requiresAlwaysValid33 [n : Integer ::: (AlwaysValid33 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 274 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (applyAlwaysValid33 [n : Integer])
  #:returns Integer
  (let ([proof (thsl-src! "tests/critical-review-33-tests.tesl" 277 (list (cons 'n *n)) (lambda () (alwaysEstablish33 n)))]) (thsl-src! "tests/critical-review-33-tests.tesl" 278 (list (cons 'proof *proof) (cons 'n *n)) (lambda () (raw-value (requiresAlwaysValid33 (attach-proof n proof)))))))

(define/pow
  (isEven33 [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review-33-tests.tesl" 297 (list (cons 'n *n)) (lambda () (if (tesl-equal? *n 0) (raw-value #t) (raw-value (isOdd33 (- *n 1)))))))

(define/pow
  (isOdd33 [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review-33-tests.tesl" 303 (list (cons 'n *n)) (lambda () (if (tesl-equal? *n 0) (raw-value #f) (raw-value (isEven33 (- *n 1)))))))

(define-adt IntTree33
  [Leaf33]
  [Node33 [left : IntTree33] [value : Integer] [right : IntTree33]]
)

(define/pow
  (treeSum33 [t : IntTree33])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-33-tests.tesl" 335 (list (cons 't *t)) (lambda () (let ([tesl-case-2 *t]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Leaf33)) (thsl-src! "tests/critical-review-33-tests.tesl" 336 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Node33)) (let ([left (hash-ref (adt-value-fields *tesl-case-2) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl-case-2) 'right)]) (thsl-src! "tests/critical-review-33-tests.tesl" 337 (list (cons 'left left) (cons 'value value) (cons 'right right)) (lambda () (raw-value (+ (+ (raw-value (treeSum33 *left)) *value) (raw-value (treeSum33 *right)))))))))])))))

(define/pow
  (treeDepth33 [t : IntTree33])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-33-tests.tesl" 340 (list (cons 't *t)) (lambda () (let ([tesl-case-3 *t]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Leaf33)) (thsl-src! "tests/critical-review-33-tests.tesl" 341 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Node33)) (let ([left (hash-ref (adt-value-fields *tesl-case-3) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl-case-3) 'right)]) (thsl-src! "tests/critical-review-33-tests.tesl" 343 (list (cons 'left left) (cons 'right right)) (lambda () (let ([ld (treeDepth33 *left)]) (let ([rd (treeDepth33 *right)]) (let ([maxDepth (if (> (raw-value ld) (raw-value rd)) ld rd)]) (raw-value (+ 1 (raw-value maxDepth))))))))))])))))

(define/pow
  (treeMap33 [f : (-> Integer Integer)] [t : IntTree33])
  #:returns IntTree33
  (thsl-src-control! "tests/critical-review-33-tests.tesl" 352 (list (cons 'f *f) (cons 't *t)) (lambda () (let ([tesl-case-4 *t]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Leaf33)) (thsl-src! "tests/critical-review-33-tests.tesl" 353 (list) (lambda () (raw-value Leaf33)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Node33)) (let ([left (hash-ref (adt-value-fields *tesl-case-4) 'left)]) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (let ([right (hash-ref (adt-value-fields *tesl-case-4) 'right)]) (thsl-src! "tests/critical-review-33-tests.tesl" 355 (list (cons 'left left) (cons 'value value) (cons 'right right)) (lambda () (raw-value (raw-value (Node33 (treeMap33 f *left) (f *value) (treeMap33 f *right)))))))))])))))

(define-adt (Box33 a)
  [MkBox33 [value : a]]
)

(define/pow
  (boxMap33 [f : (-> a b)] [box : (Box33 a)])
  #:returns (Box33 b)
  (thsl-src-control! "tests/critical-review-33-tests.tesl" 386 (list (cons 'f *f) (cons 'box *box)) (lambda () (let ([tesl-case-5 *box]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'MkBox33)) (let ([value (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tests/critical-review-33-tests.tesl" 387 (list (cons 'value value)) (lambda () (raw-value (raw-value (MkBox33 (f *value)))))))])))))

(define/pow
  (boxFlatMap33 [f : (-> a (Box33 b))] [box : (Box33 a)])
  #:returns (Box33 b)
  (thsl-src-control! "tests/critical-review-33-tests.tesl" 390 (list (cons 'f *f) (cons 'box *box)) (lambda () (let ([tesl-case-6 *box]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'MkBox33)) (let ([value (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "tests/critical-review-33-tests.tesl" 391 (list (cons 'value value)) (lambda () (raw-value (f *value)))))])))))

(define/pow
  (doubleBox33 [box : (Box33 Integer)])
  #:returns (Box33 Integer)
  (thsl-src! "tests/critical-review-33-tests.tesl" 394 (list (cons 'box *box)) (lambda () (raw-value (boxMap33 (let () (define/pow (tesl-lambda-7 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-7) box)))))

(define/pow
  (intToStr33 [x : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-33-tests.tesl" 396 (list (cons 'x *x)) (lambda () (format "value: ~a" (tesl-display-val *x)))))

(define/pow
  (maxFixnum33)
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 414 (list) (lambda () 4611686018427387903)))

(define/pow
  (minFixnum33)
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 415 (list) (lambda () -4611686018427387903)))

(define/pow
  (addZero33 [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 416 (list (cons 'n *n)) (lambda () (+ *n 0))))

(define/pow
  (mulOne33 [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 417 (list (cons 'n *n)) (lambda () (* *n 1))))

(define/pow
  (subSelf33 [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 418 (list (cons 'n *n)) (lambda () (- *n *n))))

(define/pow
  (floatAddNegZero33 [x : Real])
  #:returns Real
  (thsl-src! "tests/critical-review-33-tests.tesl" 456 (list (cons 'x *x)) (lambda () (+ *x 0.))))

(define/pow
  (floatMulByOne33 [x : Real])
  #:returns Real
  (thsl-src! "tests/critical-review-33-tests.tesl" 459 (list (cons 'x *x)) (lambda () (* *x 1.))))

(define/pow
  (floatAbsNeg33 [x : Real])
  #:returns Real
  (thsl-src! "tests/critical-review-33-tests.tesl" 462 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Float_abs (- 0. *x))))))

(define/pow
  (interpolateComplex33 [n : Integer])
  #:returns String
  (let ([doubled (thsl-src! "tests/critical-review-33-tests.tesl" 486 (list (cons 'n *n)) (lambda () (* *n 2)))]) (let ([tripled (thsl-src! "tests/critical-review-33-tests.tesl" 487 (list (cons 'doubled *doubled) (cons 'n *n)) (lambda () (* *n 3)))]) (thsl-src! "tests/critical-review-33-tests.tesl" 488 (list (cons 'tripled *tripled) (cons 'doubled *doubled) (cons 'n *n)) (lambda () (format "n=~a, doubled=~a, tripled=~a" (tesl-display-val *n) (tesl-display-val *doubled) (tesl-display-val *tripled)))))))

(define/pow
  (interpolateZero33)
  #:returns String
  (let ([z (thsl-src! "tests/critical-review-33-tests.tesl" 491 (list) (lambda () 0))]) (thsl-src! "tests/critical-review-33-tests.tesl" 492 (list (cons 'z *z)) (lambda () (format "zero: ~a" (tesl-display-val *z))))))

(define/pow
  (interpolateNegative33 [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-33-tests.tesl" 495 (list (cons 'n *n)) (lambda () (format "negative: ~a" (tesl-display-val *n)))))

(define-checker
  (checkEven33 [n : Integer])
  #:returns [n : Integer ::: (IsEven33 n)]
  (thsl-src! "tests/critical-review-33-tests.tesl" 518 (list (cons 'n *n)) (lambda () (if (tesl-equal? (remainder *n 2) 0) (accept (IsEven33 n) #:value *n) (reject "not even" #:http-code 400)))))

(define/pow
  (narrowForAll33 [xs : (List Integer)])
  #:returns (List Integer)
  (let ([positives (thsl-src! "tests/critical-review-33-tests.tesl" 524 (list (cons 'xs *xs)) (lambda () (filterToPositives xs)))]) (thsl-src! "tests/critical-review-33-tests.tesl" 525 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkEven33 (raw-value positives))))))

(define-checker
  (checkChecked33 [n : Integer])
  #:returns [n : Integer ::: (IsChecked33 n)]
  (thsl-src! "tests/critical-review-33-tests.tesl" 544 (list (cons 'n *n)) (lambda () (if (>= *n 0) (accept (IsChecked33 n) #:value *n) (reject "must be non-negative" #:http-code 400)))))

(define/pow
  (requiresChecked33 [n : Integer ::: (IsChecked33 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 550 (list (cons 'n *n)) (lambda () (+ *n 100))))

(define/pow
  (decomposeAndReuse33 [n : Integer ::: (IsChecked33 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 553 (list (cons 'n *n)) (lambda () (raw-value (requiresChecked33 n)))))

(define-adt Status33
  [Active33]
  [Inactive33]
  [Pending33 [reason : String]]
)

(define/pow
  (describeStatus33 [s : Status33] [userId : String])
  #:returns String
  (thsl-src-control! "tests/critical-review-33-tests.tesl" 576 (list (cons 's *s) (cons 'userId *userId)) (lambda () (let ([tesl-case-8 *s]) (cond [(and (and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Active33)) (tesl_import_String_startsWith *userId "admin")) (thsl-src! "tests/critical-review-33-tests.tesl" 578 (list) (lambda () (raw-value "admin active")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Active33)) (thsl-src! "tests/critical-review-33-tests.tesl" 580 (list) (lambda () (raw-value "user active")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Inactive33)) (thsl-src! "tests/critical-review-33-tests.tesl" 582 (list) (lambda () (raw-value "inactive")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Pending33)) (let ([reason (hash-ref (adt-value-fields *tesl-case-8) 'reason)]) (thsl-src! "tests/critical-review-33-tests.tesl" 584 (list (cons 'reason reason)) (lambda () (raw-value (format "pending: ~a" (tesl-display-val *reason))))))])))))

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
  (thsl-src-control! "tests/critical-review-33-tests.tesl" 612 (list (cons 'w *w)) (lambda () (let ([tesl-case-9 *w]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Empty33)) (thsl-src! "tests/critical-review-33-tests.tesl" 614 (list) (lambda () (raw-value "empty")))] [(and (and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Wrapped)) (let ([tesl-case-9_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-9) 'inner))]) (and (adt-value? *tesl-case-9_f0) (eq? (adt-value-variant *tesl-case-9_f0) 'InnerA)))) (let ([tesl-case-9_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-9) 'inner))]) (let ([val (hash-ref (adt-value-fields *tesl-case-9_f0) 'val)]) (thsl-src! "tests/critical-review-33-tests.tesl" 616 (list (cons 'val val)) (lambda () (raw-value (format "int: ~a" (tesl-display-val *val)))))))] [(and (and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Wrapped)) (let ([tesl-case-9_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-9) 'inner))]) (and (adt-value? *tesl-case-9_f0) (eq? (adt-value-variant *tesl-case-9_f0) 'InnerB)))) (let ([tesl-case-9_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-9) 'inner))]) (let ([val (hash-ref (adt-value-fields *tesl-case-9_f0) 'val)]) (thsl-src! "tests/critical-review-33-tests.tesl" 618 (list (cons 'val val)) (lambda () (raw-value (format "str: ~a" (tesl-display-val *val)))))))])))))

(define-newtype WrappedInt33 Integer)

(define/pow
  (makeWrapped33 [n : Integer])
  #:returns WrappedInt33
  (thsl-src! "tests/critical-review-33-tests.tesl" 634 (list (cons 'n *n)) (lambda () (raw-value (WrappedInt33 *n)))))

(define/pow
  (extractWrapped33 [w : WrappedInt33])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 637 (list (cons 'w *w)) (lambda () (raw-value w.value))))

(define/pow
  (doubleWrapped33 [w : WrappedInt33])
  #:returns WrappedInt33
  (thsl-src! "tests/critical-review-33-tests.tesl" 640 (list (cons 'w *w)) (lambda () (raw-value (WrappedInt33 (* (raw-value w.value) 2))))))

(define/pow
  (lookupWithProof33 [key : String] [dict : (Dict String Integer)])
  #:returns (Maybe Integer)
  (thsl-src! "tests/critical-review-33-tests.tesl" 664 (list (cons 'key *key) (cons 'dict *dict)) (lambda () (if (raw-value (tesl_import_Dict_member *key *dict)) (let/check ([tesl-checked-10 (tesl_import_Dict_requireKey key dict)]) (let ([checkedDict tesl-checked-10]) (raw-value (raw-value (Something (raw-value (tesl_import_Dict_get *key checkedDict))))))) (raw-value Nothing)))))

(define/pow
  (applyTwice33 [f : (-> Integer Integer)] [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 685 (list (cons 'f *f) (cons 'x *x)) (lambda () (raw-value (f (f x))))))

(define/pow
  (doubleAll33 [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-33-tests.tesl" 688 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-11 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-11) *xs)))))

(define/pow
  (proofTotalDivide33 [a : Integer] [b : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "tests/critical-review-33-tests.tesl" 709 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (tesl-equal? *b 0) (raw-value Nothing) (let/check ([tesl-checked-12 (tesl_import_Int_nonZero b)]) (let ([divisor tesl-checked-12]) (raw-value (raw-value (Something (tesl_import_Int_divide *a divisor))))))))))

(define/pow
  (proofTotalFloatDiv33 [a : Real] [b : Real])
  #:returns (Maybe Real)
  (thsl-src! "tests/critical-review-33-tests.tesl" 735 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (tesl-equal? *b 0.) (raw-value Nothing) (let/check ([tesl-checked-13 (tesl_import_Float_requireNonZero b)]) (let ([divisor tesl-checked-13]) (raw-value (raw-value (Something (raw-value (tesl_import_Float_div *a divisor)))))))))))

(define/pow
  (allCheckSome33 [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (thsl-src! "tests/critical-review-33-tests.tesl" 752 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck checkPos33 *xs))))

(define/pow
  (allCheckNone33 [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (thsl-src! "tests/critical-review-33-tests.tesl" 755 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck checkPos33 *xs))))

(define-checker
  (checkInRange33 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange33 lo hi n)]
  (thsl-src! "tests/critical-review-33-tests.tesl" 774 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange33 lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define/pow
  (requiresInRange33 [lo : Integer] [hi : Integer] [n : Integer ::: (InRange33 lo hi n)])
  #:returns String
  (thsl-src! "tests/critical-review-33-tests.tesl" 780 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (format "~a is in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))))

(define/pow
  (forgetAndRecheck33 [n : Integer ::: (IsPos33 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-33-tests.tesl" 817 (list (cons 'n *n)) (lambda () (let ([forgotten (forget-proof n)]) (let/check ([tesl-checked-14 (checkPos33 forgotten)]) (let ([rechecked tesl-checked-14]) (raw-value rechecked)))))))

(define/pow
  (tryForgetRecheck33 [raw : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "tests/critical-review-33-tests.tesl" 822 (list (cons 'raw *raw)) (lambda () (if (> *raw 0) (let/check ([tesl-checked-15 (checkPos33 raw)]) (let ([checked tesl-checked-15]) (raw-value (raw-value (Something (forgetAndRecheck33 checked)))))) (raw-value Nothing)))))

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
  (thsl-src-control! "tests/critical-review-33-tests.tesl" 851 (list (cons 'day *day)) (lambda () (let ([tesl-case-16 *day]) (cond [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Saturday33)) (thsl-src! "tests/critical-review-33-tests.tesl" 854 (list) (lambda () (raw-value "weekend")))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Sunday33)) (thsl-src! "tests/critical-review-33-tests.tesl" 854 (list) (lambda () (raw-value "weekend")))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Monday33)) (thsl-src! "tests/critical-review-33-tests.tesl" 860 (list) (lambda () (raw-value "weekday")))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Tuesday33)) (thsl-src! "tests/critical-review-33-tests.tesl" 860 (list) (lambda () (raw-value "weekday")))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Wednesday33)) (thsl-src! "tests/critical-review-33-tests.tesl" 860 (list) (lambda () (raw-value "weekday")))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Thursday33)) (thsl-src! "tests/critical-review-33-tests.tesl" 860 (list) (lambda () (raw-value "weekday")))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Friday33)) (thsl-src! "tests/critical-review-33-tests.tesl" 860 (list) (lambda () (raw-value "weekday")))])))))

(define/pow
  (sortedInts33 [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-33-tests.tesl" 876 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_sort *xs)))))

(define/pow
  (partitionEithers33 [xs : (List (Either String Integer))])
  #:returns (Tuple2 (List String) (List Integer))
  (thsl-src! "tests/critical-review-33-tests.tesl" 898 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_Either_partition *xs)))))

(define/pow
  (boolLiterals33)
  #:returns Boolean
  (thsl-src! "tests/critical-review-33-tests.tesl" 1011 (list) (lambda () #t)))

(define/pow
  (boolNegation33 [b : Boolean])
  #:returns Boolean
  (thsl-src! "tests/critical-review-33-tests.tesl" 1014 (list (cons 'b *b)) (lambda () (if (tesl-equal? *b #t) (raw-value #f) (raw-value #t)))))

(define-adt FixShape33
  [FixCircle33 [radius : Integer]]
  [FixRect33 [w : Integer] [h : Integer]]
  [FixPoint33]
)

(define-checker
  (fixCheckPos33 [n : Integer])
  #:returns [n : Integer ::: (FixIsPos33 n)]
  (thsl-src! "tests/critical-review-33-tests.tesl" 1114 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (FixIsPos33 n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (fixCheckSmall33 [n : Integer])
  #:returns [n : Integer ::: (FixIsSmall33 n)]
  (thsl-src! "tests/critical-review-33-tests.tesl" 1120 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (FixIsSmall33 n) #:value *n) (reject "too large" #:http-code 400)))))

(define/pow
  (fixRequiresBoth33 [n : Integer ::: ((FixIsPos33 n) && (FixIsSmall33 n))])
  #:returns String
  (thsl-src! "tests/critical-review-33-tests.tesl" 1126 (list (cons 'n *n)) (lambda () (format "ok: ~a" (tesl-display-val *n)))))

(module+ test
  (require rackunit)
  (test-case "T01 \226\128\148 ForAll on empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 169 (list) (lambda () (emptyListForAll)))) 0)
  (define result (thsl-src! "tests/critical-review-33-tests.tesl" 170 (list) (lambda () (filterToPositives (list)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 171 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_isEmpty (raw-value result)))))) #t)
  (define nonEmpty (thsl-src! "tests/critical-review-33-tests.tesl" 172 (list (cons 'result result)) (lambda () (filterToPositives (list 1 2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 173 (list (cons 'nonEmpty nonEmpty) (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value nonEmpty)))))) 3)
  (define mixed (thsl-src! "tests/critical-review-33-tests.tesl" 174 (list (cons 'nonEmpty nonEmpty) (cons 'result result)) (lambda () (filterToPositives (list -1 2 -3 4)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 175 (list (cons 'mixed mixed) (cons 'nonEmpty nonEmpty) (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value mixed)))))) 2)
    ))
  )

  (test-case "T01b \226\128\148 checkPos33 boundary"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 179 (list) (lambda ()
                          (checkPos33 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPos33 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 180 (list) (lambda ()
                          (checkPos33 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPos33 -1"))
  (define p1 (thsl-src! "tests/critical-review-33-tests.tesl" 181 (list) (lambda () 1)))
  (define tesl-checked-17 (checkPos33 p1))
  (when (check-fail? tesl-checked-17)
    (raise-user-error 'tesl-test "unexpected failure in let r: ~a" (check-fail-message tesl-checked-17)))
  (define r tesl-checked-17)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 183 (list (cons 'r r) (cons 'p1 p1)) (lambda () r))) 1)
    ))
  )

  (test-case "T02 \226\128\148 proof survives let chain"
    (call-with-fresh-memory-db '() (lambda ()
  (define p7 (thsl-src! "tests/critical-review-33-tests.tesl" 208 (list) (lambda () 7)))
  (define tesl-checked-18 (checkPrime33 p7))
  (when (check-fail? tesl-checked-18)
    (raise-user-error 'tesl-test "unexpected failure in let v7: ~a" (check-fail-message tesl-checked-18)))
  (define v7 tesl-checked-18)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 210 (list (cons 'v7 v7) (cons 'p7 p7)) (lambda () (proofThroughLetChain v7)))) "prime: 7")
  (define p13 (thsl-src! "tests/critical-review-33-tests.tesl" 211 (list (cons 'v7 v7) (cons 'p7 p7)) (lambda () 13)))
  (define tesl-checked-19 (checkPrime33 p13))
  (when (check-fail? tesl-checked-19)
    (raise-user-error 'tesl-test "unexpected failure in let v13: ~a" (check-fail-message tesl-checked-19)))
  (define v13 tesl-checked-19)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 213 (list (cons 'v13 v13) (cons 'p13 p13) (cons 'v7 v7) (cons 'p7 p7)) (lambda () (proofThroughLetChain v13)))) "prime: 13")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 214 (list (cons 'v13 v13) (cons 'p13 p13) (cons 'v7 v7) (cons 'p7 p7)) (lambda ()
                          (checkPrime33 4))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPrime33 4"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 215 (list (cons 'v13 v13) (cons 'p13 p13) (cons 'v7 v7) (cons 'p7 p7)) (lambda ()
                          (checkPrime33 1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPrime33 1"))
    ))
  )

  (test-case "T03 \226\128\148 check composition both proofs"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 248 (list) (lambda () (composedBoth33 "hello")))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 249 (list) (lambda () (composedBoth33 "hi")))) 2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 250 (list) (lambda () (composedBoth33 "")))) 0)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 251 (list) (lambda ()
                          (checkTrimmed33 "  padded  "))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTrimmed33 \"  padded  \""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 252 (list) (lambda ()
                          (checkShort33 "way too long for short check"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkShort33 \"way too long for short check\""))
    ))
  )

  (test-case "T03b \226\128\148 reversed composition also fails long strings"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 256 (list) (lambda ()
                          ((check-and checkTrimmed33 checkShort33) "this is too long definitely"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and checkTrimmed33 checkShort33) \"this is too long definitely\""))
  (define shortStr (thsl-src! "tests/critical-review-33-tests.tesl" 257 (list) (lambda () "ok")))
  (define tesl-checked-20 ((check-and checkShort33 checkTrimmed33) shortStr))
  (when (check-fail? tesl-checked-20)
    (raise-user-error 'tesl-test "unexpected failure in let result: ~a" (check-fail-message tesl-checked-20)))
  (define result tesl-checked-20)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 259 (list (cons 'result result) (cons 'shortStr shortStr)) (lambda () (tesl_import_String_length result)))) 2)
    ))
  )

  (test-case "T04 \226\128\148 establish is unconditional"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 281 (list) (lambda () (applyAlwaysValid33 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 282 (list) (lambda () (applyAlwaysValid33 -999)))) -1998)
    ))
  )

  (test-case "T04b \226\128\148 establish on any value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 286 (list) (lambda () (applyAlwaysValid33 1000000)))) 2000000)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 287 (list) (lambda () (applyAlwaysValid33 -1)))) -2)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 288 (list) (lambda () (applyAlwaysValid33 7)))) 14)
    ))
  )

  (test-case "T05 \226\128\148 mutual recursion even/odd"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 309 (list) (lambda () (isEven33 0)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 310 (list) (lambda () (isEven33 1)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 311 (list) (lambda () (isEven33 4)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 312 (list) (lambda () (isOdd33 3)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 313 (list) (lambda () (isOdd33 10)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 314 (list) (lambda () (isEven33 100)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 315 (list) (lambda () (isOdd33 99)))) #t)
    ))
  )

  (test-case "T05b \226\128\148 mutual recursion property"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: even and odd are complementary
  (for ([tesl-prop-i (in-range 30)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (< (raw-value n) 50)) (check-true (not (tesl-equal? (raw-value (isEven33 n)) (raw-value (isOdd33 n)))) "even and odd are complementary"))
    ))
    ))
  )

  (test-case "T06 \226\128\148 recursive ADT operations"
    (call-with-fresh-memory-db '() (lambda ()
  (define leaf (thsl-src! "tests/critical-review-33-tests.tesl" 358 (list) (lambda () Leaf33)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 359 (list (cons 'leaf leaf)) (lambda () (treeSum33 leaf)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 360 (list (cons 'leaf leaf)) (lambda () (treeDepth33 leaf)))) 0)
  (define single (thsl-src! "tests/critical-review-33-tests.tesl" 361 (list (cons 'leaf leaf)) (lambda () (raw-value (Node33 Leaf33 5 Leaf33)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 362 (list (cons 'single single) (cons 'leaf leaf)) (lambda () (treeSum33 single)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 363 (list (cons 'single single) (cons 'leaf leaf)) (lambda () (treeDepth33 single)))) 1)
  (define tree (thsl-src! "tests/critical-review-33-tests.tesl" 364 (list (cons 'single single) (cons 'leaf leaf)) (lambda () (raw-value (Node33 (Node33 Leaf33 2 Leaf33) 4 (Node33 Leaf33 6 Leaf33))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 365 (list (cons 'tree tree) (cons 'single single) (cons 'leaf leaf)) (lambda () (treeSum33 tree)))) 12)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 366 (list (cons 'tree tree) (cons 'single single) (cons 'leaf leaf)) (lambda () (treeDepth33 tree)))) 2)
  (define doubled (thsl-src! "tests/critical-review-33-tests.tesl" 367 (list (cons 'tree tree) (cons 'single single) (cons 'leaf leaf)) (lambda () (treeMap33 (let () (define/pow (tesl-lambda-21 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-21) tree))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 368 (list (cons 'doubled doubled) (cons 'tree tree) (cons 'single single) (cons 'leaf leaf)) (lambda () (treeSum33 doubled)))) 24)
    ))
  )

  (test-case "T06b \226\128\148 deep tree"
    (call-with-fresh-memory-db '() (lambda ()
  (define deep (thsl-src! "tests/critical-review-33-tests.tesl" 372 (list) (lambda () (raw-value (Node33 (Node33 (Node33 Leaf33 1 Leaf33) 2 Leaf33) 3 Leaf33)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 373 (list (cons 'deep deep)) (lambda () (treeSum33 deep)))) 6)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 374 (list (cons 'deep deep)) (lambda () (treeDepth33 deep)))) 3)
    ))
  )

  (test-case "T07 \226\128\148 parameterized ADT operations"
    (call-with-fresh-memory-db '() (lambda ()
  (define intBox (thsl-src! "tests/critical-review-33-tests.tesl" 399 (list) (lambda () (raw-value (MkBox33 42)))))
  (define doubled (thsl-src! "tests/critical-review-33-tests.tesl" 400 (list (cons 'intBox intBox)) (lambda () (doubleBox33 intBox))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 401 (list (cons 'doubled doubled) (cons 'intBox intBox)) (lambda () doubled))) (raw-value (MkBox33 84)))
  (define strBox (thsl-src! "tests/critical-review-33-tests.tesl" 402 (list (cons 'doubled doubled) (cons 'intBox intBox)) (lambda () (boxMap33 intToStr33 intBox))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 403 (list (cons 'strBox strBox) (cons 'doubled doubled) (cons 'intBox intBox)) (lambda () strBox))) (raw-value (MkBox33 "value: 42")))
  (define flatMapped (thsl-src! "tests/critical-review-33-tests.tesl" 404 (list (cons 'strBox strBox) (cons 'doubled doubled) (cons 'intBox intBox)) (lambda () (boxFlatMap33 (let () (define/pow (tesl-lambda-22 [x : Integer]) #:returns Any (raw-value (MkBox33 (+ *x 1)))) tesl-lambda-22) intBox))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 405 (list (cons 'flatMapped flatMapped) (cons 'strBox strBox) (cons 'doubled doubled) (cons 'intBox intBox)) (lambda () flatMapped))) (raw-value (MkBox33 43)))
    ))
  )

  (test-case "T08 \226\128\148 integer identity laws"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 421 (list) (lambda () (addZero33 42)))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 422 (list) (lambda () (addZero33 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 423 (list) (lambda () (addZero33 -100)))) -100)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 424 (list) (lambda () (mulOne33 99)))) 99)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 425 (list) (lambda () (mulOne33 -5)))) -5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 426 (list) (lambda () (subSelf33 12345)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 427 (list) (lambda () (subSelf33 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 428 (list) (lambda () (subSelf33 -999)))) 0)
    ))
  )

  (test-case "T08b \226\128\148 integer boundary values"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 432 (list) (lambda () (maxFixnum33)))) 4611686018427387903)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 433 (list) (lambda () (minFixnum33)))) -4611686018427387903)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 434 (list) (lambda () (> (raw-value (maxFixnum33)) 0)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 435 (list) (lambda () (< (raw-value (minFixnum33)) 0)))) #t)
    ))
  )

  (test-case "T08c \226\128\148 integer arithmetic properties"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: addZero identity
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (> (raw-value n) -1000000) (< (raw-value n) 1000000)) (check-true (tesl-equal? (raw-value (addZero33 n)) (raw-value n)) "addZero identity"))
    ))
  ; property: mulOne identity
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (> (raw-value n) -1000000) (< (raw-value n) 1000000)) (check-true (tesl-equal? (raw-value (mulOne33 n)) (raw-value n)) "mulOne identity"))
    ))
  ; property: subSelf is zero
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (> (raw-value n) -1000000) (< (raw-value n) 1000000)) (check-true (tesl-equal? (raw-value (subSelf33 n)) 0) "subSelf is zero"))
    ))
    ))
  )

  (test-case "T09 \226\128\148 float basic operations"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 465 (list) (lambda () (floatAbsNeg33 3.14)))) 3.14)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 466 (list) (lambda () (floatAbsNeg33 0.)))) 0.)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 467 (list) (lambda () (floatAbsNeg33 -2.71)))) 2.71)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 468 (list) (lambda () (floatAddNegZero33 1.5)))) 1.5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 469 (list) (lambda () (floatMulByOne33 2.5)))) 2.5)
    ))
  )

  (test-case "T09b \226\128\148 float NaN/Infinity detection"
    (call-with-fresh-memory-db '() (lambda ()
  (define inf (thsl-src! "tests/critical-review-33-tests.tesl" 473 (list) (lambda () 1.)))
  (define b1 (thsl-src! "tests/critical-review-33-tests.tesl" 474 (list (cons 'inf inf)) (lambda () (raw-value (tesl_import_Float_isNaN (raw-value inf))))))
  (define b2 (thsl-src! "tests/critical-review-33-tests.tesl" 475 (list (cons 'b1 b1) (cons 'inf inf)) (lambda () (raw-value (tesl_import_Float_isInfinite (raw-value inf))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 476 (list (cons 'b2 b2) (cons 'b1 b1) (cons 'inf inf)) (lambda () b1))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 477 (list (cons 'b2 b2) (cons 'b1 b1) (cons 'inf inf)) (lambda () b2))) #f)
    ))
  )

  (test-case "T10 \226\128\148 string interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 498 (list) (lambda () (interpolateComplex33 5)))) "n=5, doubled=10, tripled=15")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 499 (list) (lambda () (interpolateZero33)))) "zero: 0")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 500 (list) (lambda () (interpolateNegative33 -7)))) "negative: -7")
    ))
  )

  (test-case "T10b \226\128\148 interpolation property"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: interpolated length is positive
  (for ([tesl-prop-i (in-range 20)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (< (raw-value n) 1000)) (check-true (> (raw-value (tesl_import_String_length (raw-value (interpolateComplex33 n)))) 0) "interpolated length is positive"))
    ))
    ))
  )

  (test-case "T11 \226\128\148 ForAll narrowing"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-33-tests.tesl" 528 (list) (lambda () (narrowForAll33 (list 1 2 3 4 -2 6)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 529 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
  (define empty (thsl-src! "tests/critical-review-33-tests.tesl" 530 (list (cons 'result result)) (lambda () (narrowForAll33 (list -1 3 5)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 531 (list (cons 'empty empty) (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value empty)))))) 0)
  (define allEven (thsl-src! "tests/critical-review-33-tests.tesl" 532 (list (cons 'empty empty) (cons 'result result)) (lambda () (narrowForAll33 (list 2 4 6 8)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 533 (list (cons 'allEven allEven) (cons 'empty empty) (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value allEven)))))) 4)
    ))
  )

  (test-case "T12 \226\128\148 proof decomposition and reattachment"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw5 (thsl-src! "tests/critical-review-33-tests.tesl" 556 (list) (lambda () 5)))
  (define tesl-checked-23 (checkChecked33 raw5))
  (when (check-fail? tesl-checked-23)
    (raise-user-error 'tesl-test "unexpected failure in let c5: ~a" (check-fail-message tesl-checked-23)))
  (define c5 tesl-checked-23)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 558 (list (cons 'c5 c5) (cons 'raw5 raw5)) (lambda () (decomposeAndReuse33 c5)))) 105)
  (define raw0 (thsl-src! "tests/critical-review-33-tests.tesl" 559 (list (cons 'c5 c5) (cons 'raw5 raw5)) (lambda () 0)))
  (define tesl-checked-24 (checkChecked33 raw0))
  (when (check-fail? tesl-checked-24)
    (raise-user-error 'tesl-test "unexpected failure in let c0: ~a" (check-fail-message tesl-checked-24)))
  (define c0 tesl-checked-24)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 561 (list (cons 'c0 c0) (cons 'raw0 raw0) (cons 'c5 c5) (cons 'raw5 raw5)) (lambda () (decomposeAndReuse33 c0)))) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 562 (list (cons 'c0 c0) (cons 'raw0 raw0) (cons 'c5 c5) (cons 'raw5 raw5)) (lambda ()
                          (checkChecked33 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkChecked33 -1"))
    ))
  )

  (test-case "T13 \226\128\148 case with where guard"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 587 (list) (lambda () (describeStatus33 Active33 "admin_user")))) "admin active")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 588 (list) (lambda () (describeStatus33 Active33 "regular_user")))) "user active")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 589 (list) (lambda () (describeStatus33 Inactive33 "anyone")))) "inactive")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 590 (list) (lambda () (describeStatus33 (Pending33 "review") "user")))) "pending: review")
    ))
  )

  (test-case "T13b \226\128\148 where guard priority"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 594 (list) (lambda () (describeStatus33 Active33 "administrator")))) "admin active")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 595 (list) (lambda () (describeStatus33 Active33 "Admin")))) "user active")
    ))
  )

  (test-case "T14 \226\128\148 nested constructor patterns"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 621 (list) (lambda () (unwrapInner33 Empty33)))) "empty")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 622 (list) (lambda () (unwrapInner33 (Wrapped (InnerA 42)))))) "int: 42")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 623 (list) (lambda () (unwrapInner33 (Wrapped (InnerB "hello")))))) "str: hello")
    ))
  )

  (test-case "T15 \226\128\148 newtype .value accessor"
    (call-with-fresh-memory-db '() (lambda ()
  (define w (thsl-src! "tests/critical-review-33-tests.tesl" 643 (list) (lambda () (makeWrapped33 21))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 644 (list (cons 'w w)) (lambda () (extractWrapped33 w)))) 21)
  (define dw (thsl-src! "tests/critical-review-33-tests.tesl" 645 (list (cons 'w w)) (lambda () (doubleWrapped33 w))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 646 (list (cons 'dw dw) (cons 'w w)) (lambda () (extractWrapped33 dw)))) 42)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 647 (list (cons 'dw dw) (cons 'w w)) (lambda () (extractWrapped33 (makeWrapped33 0))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 648 (list (cons 'dw dw) (cons 'w w)) (lambda () (extractWrapped33 (makeWrapped33 -5))))) -5)
    ))
  )

  (test-case "T15b \226\128\148 newtype identity"
    (call-with-fresh-memory-db '() (lambda ()
  (define a (thsl-src! "tests/critical-review-33-tests.tesl" 652 (list) (lambda () (makeWrapped33 10))))
  (define b (thsl-src! "tests/critical-review-33-tests.tesl" 653 (list (cons 'a a)) (lambda () (doubleWrapped33 a))))
  (define c (thsl-src! "tests/critical-review-33-tests.tesl" 654 (list (cons 'b b) (cons 'a a)) (lambda () (doubleWrapped33 b))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 655 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (extractWrapped33 c)))) 40)
    ))
  )

  (test-case "T16 \226\128\148 Dict.requireKey and Dict.get"
    (call-with-fresh-memory-db '() (lambda ()
  (define d (thsl-src! "tests/critical-review-33-tests.tesl" 671 (list) (lambda () (raw-value (tesl_import_Dict_insert "a" 1 (raw-value (tesl_import_Dict_insert "b" 2 tesl_import_Dict_empty)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 672 (list (cons 'd d)) (lambda () (lookupWithProof33 "a" d)))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 673 (list (cons 'd d)) (lambda () (lookupWithProof33 "b" d)))) (raw-value (Something 2)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 674 (list (cons 'd d)) (lambda () (lookupWithProof33 "c" d)))) Nothing)
  (define emptyD (thsl-src! "tests/critical-review-33-tests.tesl" 675 (list (cons 'd d)) (lambda () tesl_import_Dict_empty)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 676 (list (cons 'emptyD emptyD) (cons 'd d)) (lambda () (lookupWithProof33 "x" emptyD)))) Nothing)
    ))
  )

  (test-case "T17 \226\128\148 lambda and HOF"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 691 (list) (lambda () (applyTwice33 (let () (define/pow (tesl-lambda-25 [x : Integer]) #:returns Integer (+ *x 3)) tesl-lambda-25) 1)))) 7)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 692 (list) (lambda () (applyTwice33 (let () (define/pow (tesl-lambda-26 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-26) 3)))) 12)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 693 (list) (lambda () (doubleAll33 (list 1 2 3))))) (list 2 4 6))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 694 (list) (lambda () (doubleAll33 (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 695 (list) (lambda () (doubleAll33 (list -1 0 1))))) (list -2 0 2))
    ))
  )

  (test-case "T17b \226\128\148 partial application of named function"
    (call-with-fresh-memory-db '() (lambda ()
  (define add10 (thsl-src! "tests/critical-review-33-tests.tesl" 699 (list) (lambda () (let () (define/pow (tesl-lambda-27 [x : Integer]) #:returns Integer (+ *x 10)) tesl-lambda-27))))
  (define results (thsl-src! "tests/critical-review-33-tests.tesl" 700 (list (cons 'add10 add10)) (lambda () (tesl_import_List_map (raw-value add10) (list 1 2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 701 (list (cons 'results results) (cons 'add10 add10)) (lambda () results))) (list 11 12 13))
    ))
  )

  (test-case "T18 \226\128\148 proof-total divide"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 716 (list) (lambda () (proofTotalDivide33 10 2)))) (raw-value (Something 5)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 717 (list) (lambda () (proofTotalDivide33 10 0)))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 718 (list) (lambda () (proofTotalDivide33 7 3)))) (raw-value (Something 2)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 719 (list) (lambda () (proofTotalDivide33 0 5)))) (raw-value (Something 0)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 720 (list) (lambda () (proofTotalDivide33 -10 2)))) (raw-value (Something -5)))
    ))
  )

  (test-case "T18b \226\128\148 divide properties"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: divide by self is 1
  (for ([tesl-prop-i (in-range 30)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (> (raw-value n) 0) (< (raw-value n) 10000)) (check-true (let/check ([tesl-checked-28 (tesl_import_Int_nonZero n)]) (let ([divisor tesl-checked-28]) (tesl-equal? (raw-value (tesl_import_Int_divide (raw-value n) divisor)) 1))) "divide by self is 1"))
    ))
    ))
  )

  (test-case "T19 \226\128\148 proof-total float divide"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 742 (list) (lambda () (proofTotalFloatDiv33 10. 2.)))) (raw-value (Something 5.)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 743 (list) (lambda () (proofTotalFloatDiv33 10. 0.)))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 744 (list) (lambda () (proofTotalFloatDiv33 0. 1.)))) (raw-value (Something 0.)))
    ))
  )

  (test-case "T20 \226\128\148 List.allCheck semantics"
    (call-with-fresh-memory-db '() (lambda ()
  (define allPos (thsl-src! "tests/critical-review-33-tests.tesl" 758 (list) (lambda () (allCheckSome33 (list 1 2 3 4 5)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 759 (list (cons 'allPos allPos)) (lambda () allPos))) (raw-value (Something (list 1 2 3 4 5))))
  (define mixed (thsl-src! "tests/critical-review-33-tests.tesl" 760 (list (cons 'allPos allPos)) (lambda () (allCheckNone33 (list 1 2 -3 4)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 761 (list (cons 'mixed mixed) (cons 'allPos allPos)) (lambda () mixed))) Nothing)
  (define empty (thsl-src! "tests/critical-review-33-tests.tesl" 762 (list (cons 'mixed mixed) (cons 'allPos allPos)) (lambda () (allCheckSome33 (list)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 763 (list (cons 'empty empty) (cons 'mixed mixed) (cons 'allPos allPos)) (lambda () empty))) (raw-value (Something (list))))
    ))
  )

  (test-case "T21 \226\128\148 multi-param fact"
    (call-with-fresh-memory-db '() (lambda ()
  (define lo (thsl-src! "tests/critical-review-33-tests.tesl" 783 (list) (lambda () 0)))
  (define hi (thsl-src! "tests/critical-review-33-tests.tesl" 784 (list (cons 'lo lo)) (lambda () 100)))
  (define n50 (thsl-src! "tests/critical-review-33-tests.tesl" 785 (list (cons 'hi hi) (cons 'lo lo)) (lambda () 50)))
  (define tesl-checked-29 (checkInRange33 lo hi n50))
  (when (check-fail? tesl-checked-29)
    (raise-user-error 'tesl-test "unexpected failure in let checked: ~a" (check-fail-message tesl-checked-29)))
  (define checked tesl-checked-29)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 787 (list (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda () (requiresInRange33 lo hi checked)))) "50 is in [0, 100]")
  (define lo2 (thsl-src! "tests/critical-review-33-tests.tesl" 788 (list (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda () 0)))
  (define hi2 (thsl-src! "tests/critical-review-33-tests.tesl" 789 (list (cons 'lo2 lo2) (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda () 10)))
  (define nOut (thsl-src! "tests/critical-review-33-tests.tesl" 790 (list (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda () 11)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 791 (list (cons 'nOut nOut) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda ()
                          (checkInRange33 lo2 hi2 nOut))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInRange33 lo2 hi2 nOut"))
  (define nNeg (thsl-src! "tests/critical-review-33-tests.tesl" 792 (list (cons 'nOut nOut) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda () -1)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 793 (list (cons 'nNeg nNeg) (cons 'nOut nOut) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda ()
                          (checkInRange33 lo2 hi2 nNeg))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkInRange33 lo2 hi2 nNeg"))
  (define n0 (thsl-src! "tests/critical-review-33-tests.tesl" 794 (list (cons 'nNeg nNeg) (cons 'nOut nOut) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda () 0)))
  (define tesl-checked-30 (checkInRange33 lo2 hi2 n0))
  (when (check-fail? tesl-checked-30)
    (raise-user-error 'tesl-test "unexpected failure in let c0: ~a" (check-fail-message tesl-checked-30)))
  (define c0 tesl-checked-30)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 796 (list (cons 'c0 c0) (cons 'n0 n0) (cons 'nNeg nNeg) (cons 'nOut nOut) (cons 'hi2 hi2) (cons 'lo2 lo2) (cons 'checked checked) (cons 'n50 n50) (cons 'hi hi) (cons 'lo lo)) (lambda () (requiresInRange33 lo2 hi2 c0)))) "0 is in [0, 10]")
    ))
  )

  (test-case "T21b \226\128\148 multi-param boundary values"
    (call-with-fresh-memory-db '() (lambda ()
  (define lo (thsl-src! "tests/critical-review-33-tests.tesl" 800 (list) (lambda () -5)))
  (define hi (thsl-src! "tests/critical-review-33-tests.tesl" 801 (list (cons 'lo lo)) (lambda () 5)))
  (define nLo (thsl-src! "tests/critical-review-33-tests.tesl" 802 (list (cons 'hi hi) (cons 'lo lo)) (lambda () -5)))
  (define nHi (thsl-src! "tests/critical-review-33-tests.tesl" 803 (list (cons 'nLo nLo) (cons 'hi hi) (cons 'lo lo)) (lambda () 5)))
  (define tesl-checked-31 (checkInRange33 lo hi nLo))
  (when (check-fail? tesl-checked-31)
    (raise-user-error 'tesl-test "unexpected failure in let cLo: ~a" (check-fail-message tesl-checked-31)))
  (define cLo tesl-checked-31)
  (define tesl-checked-32 (checkInRange33 lo hi nHi))
  (when (check-fail? tesl-checked-32)
    (raise-user-error 'tesl-test "unexpected failure in let cHi: ~a" (check-fail-message tesl-checked-32)))
  (define cHi tesl-checked-32)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 806 (list (cons 'cHi cHi) (cons 'cLo cLo) (cons 'nHi nHi) (cons 'nLo nLo) (cons 'hi hi) (cons 'lo lo)) (lambda () (requiresInRange33 lo hi cLo)))) "-5 is in [-5, 5]")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 807 (list (cons 'cHi cHi) (cons 'cLo cLo) (cons 'nHi nHi) (cons 'nLo nLo) (cons 'hi hi) (cons 'lo lo)) (lambda () (requiresInRange33 lo hi cHi)))) "5 is in [-5, 5]")
    ))
  )

  (test-case "T22 \226\128\148 forgetFact then re-check"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 829 (list) (lambda () (tryForgetRecheck33 5)))) (raw-value (Something 5)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 830 (list) (lambda () (tryForgetRecheck33 -5)))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 831 (list) (lambda () (tryForgetRecheck33 1)))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 832 (list) (lambda () (tryForgetRecheck33 0)))) Nothing)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 833 (list) (lambda ()
                          (checkPos33 -100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPos33 -100"))
    ))
  )

  (test-case "T23 \226\128\148 fall-through case arms"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 863 (list) (lambda () (classifyWeekend33 Saturday33)))) "weekend")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 864 (list) (lambda () (classifyWeekend33 Sunday33)))) "weekend")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 865 (list) (lambda () (classifyWeekend33 Monday33)))) "weekday")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 866 (list) (lambda () (classifyWeekend33 Friday33)))) "weekday")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 867 (list) (lambda () (classifyWeekend33 Wednesday33)))) "weekday")
    ))
  )

  (test-case "T24 \226\128\148 sort idempotency"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: sort is idempotent
  (for ([tesl-prop-i (in-range 50)])
    (let ([xs (tesl-prop-build-list (tesl-prop-random 8) (lambda () (- (tesl-prop-random 2000001) 1000000)))])
      (check-true (tesl-equal? (raw-value (sortedInts33 (sortedInts33 xs))) (raw-value (sortedInts33 xs))) "sort is idempotent")
    ))
    ))
  )

  (test-case "T24b \226\128\148 sort correctness"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 885 (list) (lambda () (sortedInts33 (list 3 1 2))))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 886 (list) (lambda () (sortedInts33 (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 887 (list) (lambda () (sortedInts33 (list 1))))) (list 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 888 (list) (lambda () (sortedInts33 (list 2 2 1))))) (list 1 2 2))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 889 (list) (lambda () (sortedInts33 (list 5 4 3 2 1))))) (list 1 2 3 4 5))
    ))
  )

  (test-case "T25 \226\128\148 Either.partition"
    (call-with-fresh-memory-db '() (lambda ()
  (define mixed (thsl-src! "tests/critical-review-33-tests.tesl" 901 (list) (lambda () (list (Left "error1") (Right 1) (Left "error2") (Right 2) (Right 3)))))
  (define result (thsl-src! "tests/critical-review-33-tests.tesl" 902 (list (cons 'mixed mixed)) (lambda () (partitionEithers33 mixed))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 903 (list (cons 'result result) (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value result)))))) (list "error1" "error2"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 904 (list (cons 'result result) (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value result)))))) (list 1 2 3))
  (define allLeft (thsl-src! "tests/critical-review-33-tests.tesl" 905 (list (cons 'result result) (cons 'mixed mixed)) (lambda () (list (Left "a") (Left "b")))))
  (define r2 (thsl-src! "tests/critical-review-33-tests.tesl" 906 (list (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (partitionEithers33 allLeft))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 907 (list (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value r2)))))) (list "a" "b"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 908 (list (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value r2)))))) (list))
  (define allRight (thsl-src! "tests/critical-review-33-tests.tesl" 909 (list (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (list (Right 10) (Right 20)))))
  (define r3 (thsl-src! "tests/critical-review-33-tests.tesl" 910 (list (cons 'allRight allRight) (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (partitionEithers33 allRight))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 911 (list (cons 'r3 r3) (cons 'allRight allRight) (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value r3)))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 912 (list (cons 'r3 r3) (cons 'allRight allRight) (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value r3)))))) (list 10 20))
  (define empty (thsl-src! "tests/critical-review-33-tests.tesl" 913 (list (cons 'r3 r3) (cons 'allRight allRight) (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (partitionEithers33 (list)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 914 (list (cons 'empty empty) (cons 'r3 r3) (cons 'allRight allRight) (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value empty)))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 915 (list (cons 'empty empty) (cons 'r3 r3) (cons 'allRight allRight) (cons 'r2 r2) (cons 'allLeft allLeft) (cons 'result result) (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value empty)))))) (list))
    ))
  )

  (test-case "T26 \226\128\148 Set operations"
    (call-with-fresh-memory-db '() (lambda ()
  (define s1 (thsl-src! "tests/critical-review-33-tests.tesl" 924 (list) (lambda () (raw-value (tesl_import_Set_fromList (list 1 2 3 2 1))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 925 (list (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 1 (raw-value s1)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 926 (list (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 4 (raw-value s1)))))) #f)
  (define s2 (thsl-src! "tests/critical-review-33-tests.tesl" 927 (list (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_insert 4 (raw-value s1))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 928 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 4 (raw-value s2)))))) #t)
  (define sorted (thsl-src! "tests/critical-review-33-tests.tesl" 929 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (tesl_import_List_sort (raw-value (tesl_import_Set_toList (raw-value s1)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 930 (list (cons 'sorted sorted) (cons 's2 s2) (cons 's1 s1)) (lambda () sorted))) (list 1 2 3))
    ))
  )

  (test-case "T27 \226\128\148 String edge cases"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 939 (list) (lambda () (tesl_import_String_length "")))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 940 (list) (lambda () (tesl_import_String_isEmpty "")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 941 (list) (lambda () (tesl_import_String_isEmpty "a")))) #f)
  (define trimmed (thsl-src! "tests/critical-review-33-tests.tesl" 942 (list) (lambda () (tesl_import_String_trim "  hello  "))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 943 (list (cons 'trimmed trimmed)) (lambda () trimmed))) "hello")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 944 (list (cons 'trimmed trimmed)) (lambda () (tesl_import_String_trim "")))) "")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 945 (list (cons 'trimmed trimmed)) (lambda () (tesl_import_String_trim "  ")))) "")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 946 (list (cons 'trimmed trimmed)) (lambda () (tesl_import_String_contains "" "x")))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 947 (list (cons 'trimmed trimmed)) (lambda () (tesl_import_String_contains "hello" "")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 948 (list (cons 'trimmed trimmed)) (lambda () (tesl_import_String_startsWith "hello" "he")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 949 (list (cons 'trimmed trimmed)) (lambda () (tesl_import_String_startsWith "hello" "world")))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 950 (list (cons 'trimmed trimmed)) (lambda () (tesl_import_String_startsWith "" "")))) #t)
    ))
  )

  (test-case "T27b \226\128\148 String length property"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: trim length <= original
  (for ([tesl-prop-i (in-range 30)])
    (let ([s (tesl-prop-gen-string)])
      (check-true (<= (raw-value (tesl_import_String_length (raw-value (tesl_import_String_trim (raw-value s))))) (raw-value (tesl_import_String_length (raw-value s)))) "trim length <= original")
    ))
    ))
  )

  (test-case "T28 \226\128\148 List edge cases"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 965 (list) (lambda () (raw-value (tesl_import_List_head (list)))))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 966 (list) (lambda () (raw-value (tesl_import_List_head (list 1 2 3)))))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 967 (list) (lambda () (raw-value (tesl_import_List_isEmpty (list)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 968 (list) (lambda () (raw-value (tesl_import_List_isEmpty (list 1)))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 969 (list) (lambda () (raw-value (tesl_import_List_length (list)))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 970 (list) (lambda () (raw-value (tesl_import_List_length (list 1 2 3)))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 971 (list) (lambda () (tesl_import_List_reverse (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 972 (list) (lambda () (tesl_import_List_reverse (list 1))))) (list 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 973 (list) (lambda () (tesl_import_List_reverse (list 1 2 3))))) (list 3 2 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 974 (list) (lambda () (raw-value (tesl_import_List_sum (list)))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 975 (list) (lambda () (raw-value (tesl_import_List_sum (list 1 2 3)))))) 6)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 976 (list) (lambda () (tesl_import_List_append (list 1 2) (list 3 4))))) (list 1 2 3 4))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 977 (list) (lambda () (tesl_import_List_append (list) (list 1))))) (list 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 978 (list) (lambda () (tesl_import_List_append (list 1) (list))))) (list 1))
    ))
  )

  (test-case "T28b \226\128\148 List property tests"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: length after append
  (for ([tesl-prop-i (in-range 30)])
    (let ([xs (tesl-prop-build-list (tesl-prop-random 8) (lambda () (- (tesl-prop-random 2000001) 1000000)))] [ys (tesl-prop-build-list (tesl-prop-random 8) (lambda () (- (tesl-prop-random 2000001) 1000000)))])
      (check-true (tesl-equal? (raw-value (tesl_import_List_length (raw-value (tesl_import_List_append (raw-value xs) (raw-value ys))))) (+ (raw-value (tesl_import_List_length (raw-value xs))) (raw-value (tesl_import_List_length (raw-value ys))))) "length after append")
    ))
  ; property: reverse is involution
  (for ([tesl-prop-i (in-range 30)])
    (let ([xs (tesl-prop-build-list (tesl-prop-random 8) (lambda () (- (tesl-prop-random 2000001) 1000000)))])
      (check-true (tesl-equal? (raw-value (tesl_import_List_reverse (raw-value (tesl_import_List_reverse (raw-value xs))))) (raw-value xs)) "reverse is involution")
    ))
    ))
  )

  (test-case "T29 \226\128\148 List.take and List.drop with NonNegative proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw3 (thsl-src! "tests/critical-review-33-tests.tesl" 995 (list) (lambda () 3)))
  (define raw0 (thsl-src! "tests/critical-review-33-tests.tesl" 996 (list (cons 'raw3 raw3)) (lambda () 0)))
  (define tesl-checked-33 (tesl_import_Int_nonNegative raw3))
  (when (check-fail? tesl-checked-33)
    (raise-user-error 'tesl-test "unexpected failure in let n3: ~a" (check-fail-message tesl-checked-33)))
  (define n3 tesl-checked-33)
  (define tesl-checked-34 (tesl_import_Int_nonNegative raw0))
  (when (check-fail? tesl-checked-34)
    (raise-user-error 'tesl-test "unexpected failure in let n0: ~a" (check-fail-message tesl-checked-34)))
  (define n0 tesl-checked-34)
  (define xs (thsl-src! "tests/critical-review-33-tests.tesl" 999 (list (cons 'n0 n0) (cons 'n3 n3) (cons 'raw0 raw0) (cons 'raw3 raw3)) (lambda () (list 1 2 3 4 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1000 (list (cons 'xs xs) (cons 'n0 n0) (cons 'n3 n3) (cons 'raw0 raw0) (cons 'raw3 raw3)) (lambda () (tesl_import_List_take n3 (raw-value xs))))) (list 1 2 3))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1001 (list (cons 'xs xs) (cons 'n0 n0) (cons 'n3 n3) (cons 'raw0 raw0) (cons 'raw3 raw3)) (lambda () (tesl_import_List_take n0 (raw-value xs))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1002 (list (cons 'xs xs) (cons 'n0 n0) (cons 'n3 n3) (cons 'raw0 raw0) (cons 'raw3 raw3)) (lambda () (tesl_import_List_drop n3 (raw-value xs))))) (list 4 5))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1003 (list (cons 'xs xs) (cons 'n0 n0) (cons 'n3 n3) (cons 'raw0 raw0) (cons 'raw3 raw3)) (lambda () (tesl_import_List_drop n0 (raw-value xs))))) (list 1 2 3 4 5))
    ))
  )

  (test-case "T30 \226\128\148 Bool literal capitalization"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1020 (list) (lambda () (boolLiterals33)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1021 (list) (lambda () (boolNegation33 #t)))) #f)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1022 (list) (lambda () (boolNegation33 #f)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1023 (list) (lambda () (tesl-equal? 1 1)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1024 (list) (lambda () (tesl-equal? 1 2)))) #f)
    ))
  )

  (test-case "FIX-01a \226\128\148 case nullary constructor in test block"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "tests/critical-review-33-tests.tesl" 1039 (list) (lambda () FixPoint33)))
  (let ([*tesl-case-35 (raw-value 
    s)]) (cond
    [(and (adt-value? *tesl-case-35) (eq? (adt-value-variant *tesl-case-35) 'FixCircle33))
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1041 (list) (lambda () 1)) 2)
    ]
    [(and (adt-value? *tesl-case-35) (eq? (adt-value-variant *tesl-case-35) 'FixRect33))
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1042 (list) (lambda () 1)) 2)
    ]
    [(and (adt-value? *tesl-case-35) (eq? (adt-value-variant *tesl-case-35) 'FixPoint33))
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1043 (list) (lambda () 1)) 1)
    ]
  ))
    ))
  )

  (test-case "FIX-01b \226\128\148 case PCon field binding in test block"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "tests/critical-review-33-tests.tesl" 1047 (list) (lambda () (raw-value (FixCircle33 7)))))
  (let ([*tesl-case-36 (raw-value 
    s)]) (cond
    [(and (adt-value? *tesl-case-36) (eq? (adt-value-variant *tesl-case-36) 'FixCircle33))
      (let ([r (hash-ref (adt-value-fields *tesl-case-36) 'radius)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1049 (list) (lambda () r))) 7)
      )
    ]
    [#t
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1050 (list) (lambda () 1)) 2)
    ]
  ))
    ))
  )

  (test-case "FIX-01c \226\128\148 case multi-field PCon in test block"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "tests/critical-review-33-tests.tesl" 1054 (list) (lambda () (raw-value (FixRect33 3 4)))))
  (let ([*tesl-case-37 (raw-value 
    s)]) (cond
    [(and (adt-value? *tesl-case-37) (eq? (adt-value-variant *tesl-case-37) 'FixCircle33))
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1056 (list) (lambda () 1)) 2)
    ]
    [(and (adt-value? *tesl-case-37) (eq? (adt-value-variant *tesl-case-37) 'FixRect33))
      (let ([w (hash-ref (adt-value-fields *tesl-case-37) 'w)])
      (let ([h (hash-ref (adt-value-fields *tesl-case-37) 'h)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1057 (list) (lambda () (+ (raw-value w) (raw-value h))))) 7)
      )
      )
    ]
    [(and (adt-value? *tesl-case-37) (eq? (adt-value-variant *tesl-case-37) 'FixPoint33))
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1058 (list) (lambda () 1)) 2)
    ]
  ))
    ))
  )

  (test-case "FIX-01d \226\128\148 case PVar catch-all in test block"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "tests/critical-review-33-tests.tesl" 1062 (list) (lambda () (raw-value (FixCircle33 99)))))
  (let ([*tesl-case-38 (raw-value 
    s)]) (cond
    [#t
      (let ([v *tesl-case-38])
        (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1064 (list) (lambda () #t))) #t)
      )
    ]
  ))
    ))
  )

  (test-case "FIX-01e \226\128\148 case PLit string match in test block"
    (call-with-fresh-memory-db '() (lambda ()
  (define label (thsl-src! "tests/critical-review-33-tests.tesl" 1068 (list) (lambda () "hello")))
  (let ([*tesl-case-39 (raw-value 
    label)]) (cond
    [(equal? *tesl-case-39 "hello")
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1070 (list) (lambda () 1)) 1)
    ]
    [#t
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1071 (list) (lambda () 1)) 2)
    ]
  ))
    ))
  )

  (test-case "FIX-01f \226\128\148 case PLit int match in test block"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review-33-tests.tesl" 1075 (list) (lambda () 42)))
  (let ([*tesl-case-40 (raw-value 
    n)]) (cond
    [(= *tesl-case-40 42)
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1077 (list) (lambda () 1)) 1)
    ]
    [#t
      (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1078 (list) (lambda () 1)) 2)
    ]
  ))
    ))
  )

  (test-case "FIX-02a \226\128\148 lambda string interpolation in test block"
    (call-with-fresh-memory-db '() (lambda ()
  (define xs (thsl-src! "tests/critical-review-33-tests.tesl" 1088 (list) (lambda () (list "hello" "world"))))
  (define result (thsl-src! "tests/critical-review-33-tests.tesl" 1089 (list (cons 'xs xs)) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-41 [s : String]) #:returns String (format "item: ~a" (tesl-display-val *s))) tesl-lambda-41) (raw-value xs)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1090 (list (cons 'result result) (cons 'xs xs)) (lambda () result))) (list "item: hello" "item: world"))
    ))
  )

  (test-case "FIX-02b \226\128\148 lambda string interpolation with Int param"
    (call-with-fresh-memory-db '() (lambda ()
  (define ns (thsl-src! "tests/critical-review-33-tests.tesl" 1094 (list) (lambda () (list 1 2 3))))
  (define result (thsl-src! "tests/critical-review-33-tests.tesl" 1095 (list (cons 'ns ns)) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-42 [n : Integer]) #:returns String (format "num: ~a" (tesl-display-val *n))) tesl-lambda-42) (raw-value ns)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1096 (list (cons 'result result) (cons 'ns ns)) (lambda () result))) (list "num: 1" "num: 2" "num: 3"))
    ))
  )

  (test-case "FIX-02c \226\128\148 lambda multiple params string interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (define xs (thsl-src! "tests/critical-review-33-tests.tesl" 1100 (list) (lambda () (list "a" "b"))))
  (define result (thsl-src! "tests/critical-review-33-tests.tesl" 1101 (list (cons 'xs xs)) (lambda () (tesl_import_List_map (let () (define/pow (tesl-lambda-43 [s : String]) #:returns String (format "~a~a" (tesl-display-val *s) (tesl-display-val *s))) tesl-lambda-43) (raw-value xs)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1102 (list (cons 'result result) (cons 'xs xs)) (lambda () result))) (list "aa" "bb"))
    ))
  )

  (test-case "FIX-03a \226\128\148 check composed (&&) result used directly"
    (call-with-fresh-memory-db '() (lambda ()
  (define tesl-checked-44 ((check-and fixCheckPos33 fixCheckSmall33) 42))
  (when (check-fail? tesl-checked-44)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-44)))
  (define v tesl-checked-44)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1130 (list (cons 'v v)) (lambda () (fixRequiresBoth33 v)))) "ok: 42")
    ))
  )

  (test-case "FIX-03b \226\128\148 detachFact on composed check result"
    (call-with-fresh-memory-db '() (lambda ()
  (define tesl-checked-45 ((check-and fixCheckPos33 fixCheckSmall33) 7))
  (when (check-fail? tesl-checked-45)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-45)))
  (define v tesl-checked-45)
  (define d (thsl-src! "tests/critical-review-33-tests.tesl" 1135 (list (cons 'v v)) (lambda () (detach-all-proof v))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1136 (list (cons 'd d) (cons 'v v)) (lambda () (fixRequiresBoth33 v)))) "ok: 7")
    ))
  )

  (test-case "FIX-03c \226\128\148 composed check fails correctly on invalid input"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 1140 (list) (lambda ()
                          ((check-and fixCheckPos33 fixCheckSmall33) -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and fixCheckPos33 fixCheckSmall33) -1"))
    ))
  )

  (test-case "FIX-03d \226\128\148 composed check fails on second predicate"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 1144 (list) (lambda ()
                          ((check-and fixCheckPos33 fixCheckSmall33) 200))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and fixCheckPos33 fixCheckSmall33) 200"))
    ))
  )

  (test-case "FIX-05 \226\128\148 nowMillis is available, now is not"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (thsl-src! "tests/critical-review-33-tests.tesl" 1154 (list) (lambda () 1)) 1)
    ))
  )

  (test-case "FIX-06a \226\128\148 compound check with let-bound variable (not inline literal)"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review-33-tests.tesl" 1164 (list) (lambda () 42)))
  (define tesl-checked-46 ((check-and fixCheckPos33 fixCheckSmall33) raw))
  (when (check-fail? tesl-checked-46)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-46)))
  (define v tesl-checked-46)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-33-tests.tesl" 1166 (list (cons 'v v) (cons 'raw raw)) (lambda () (fixRequiresBoth33 v)))) "ok: 42")
    ))
  )

  (test-case "FIX-06b \226\128\148 compound check with let-bound var, check fails correctly"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review-33-tests.tesl" 1170 (list) (lambda () -5)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 1171 (list (cons 'raw raw)) (lambda ()
                          ((check-and fixCheckPos33 fixCheckSmall33) raw))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and fixCheckPos33 fixCheckSmall33) raw"))
    ))
  )

  (test-case "FIX-06c \226\128\148 compound check with let-bound var, fails on second predicate"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review-33-tests.tesl" 1175 (list) (lambda () 200)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-33-tests.tesl" 1176 (list (cons 'raw raw)) (lambda ()
                          ((check-and fixCheckPos33 fixCheckSmall33) raw))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check (check-and fixCheckPos33 fixCheckSmall33) raw"))
    ))
  )

)
