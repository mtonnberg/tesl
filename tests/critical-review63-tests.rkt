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
  (only-in tesl/tesl/prelude Int String Bool List Fact attachFact detachFact forgetFact introAnd andLeft andRight)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.map tesl_import_List_map] [List.sort tesl_import_List_sort] [List.emptyForAll tesl_import_List_emptyForAll] IsSorted)
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith] [String.toUpper tesl_import_String_toUpper] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/int [Int.divide tesl_import_Int_divide] [Int.nonZero tesl_import_Int_nonZero] [Int.nonNegative tesl_import_Int_nonNegative] IsNonZero IsNonNegative)
  (only-in tesl/tesl/float Float [Float.div tesl_import_Float_div] [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero)
  (only-in tesl/tesl/dict Dict [Dict.requireKey tesl_import_Dict_requireKey] [Dict.get tesl_import_Dict_get] [Dict.fromList tesl_import_Dict_fromList] [Dict.lookup tesl_import_Dict_lookup] HasKey)
  (only-in tesl/tesl/tuple Tuple2)
)


(provide )

(define A 'A)
(define AllPositive 'AllPositive)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define HasPrefix 'HasPrefix)
(define InRange 'InRange)
(define IsAdmin 'IsAdmin)
(define IsLong 'IsLong)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review63-tests.tesl" 88 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review63-tests.tesl" 94 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))))

(define-checker
  (checkRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange lo hi n)]
  (thsl-src! "tests/critical-review63-tests.tesl" 100 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define-checker
  (checkAdmin [userId : String])
  #:returns [userId : String ::: (IsAdmin userId)]
  (thsl-src! "tests/critical-review63-tests.tesl" 106 (list (cons 'userId *userId)) (lambda () (if (tesl_import_String_startsWith *userId "admin") (accept (IsAdmin userId) #:value *userId) (reject "not admin" #:http-code 403)))))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review63-tests.tesl" 111 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review63-tests.tesl" 112 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define-trusted
  (proveC [n : Integer])
  #:returns (Fact (C n))
  (thsl-src! "tests/critical-review63-tests.tesl" 113 (list (cons 'n *n)) (lambda () (trusted-proof (C n)))))

(define-trusted
  (proveD [n : Integer])
  #:returns (Fact (D n))
  (thsl-src! "tests/critical-review63-tests.tesl" 114 (list (cons 'n *n)) (lambda () (trusted-proof (D n)))))

(define-trusted
  (proveE [n : Integer])
  #:returns (Fact (E n))
  (thsl-src! "tests/critical-review63-tests.tesl" 115 (list (cons 'n *n)) (lambda () (trusted-proof (E n)))))

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 117 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 118 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPosSmall [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 119 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 120 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 121 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsC [n : Integer ::: (C n)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 122 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAll5 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 123 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsInRange [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 124 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (divideHelper [a : Integer] [b : Integer ::: (IsNonZero b)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 133 (list (cons 'a *a) (cons 'b *b)) (lambda () (raw-value (tesl_import_Int_divide *a b)))))

(define/pow
  (testDivideViaHelper [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 136 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl_checked_0 (tesl_import_Int_nonZero b)]) (let ([divisor tesl_checked_0]) (raw-value (divideHelper a divisor)))))))

(define/pow
  (divideChain [a : Integer] [b : Integer] [c : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 149 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (let/check ([tesl_checked_1 (tesl_import_Int_nonZero b)]) (let ([nzB tesl_checked_1]) (let/check ([tesl_checked_2 (tesl_import_Int_nonZero c)]) (let ([nzC tesl_checked_2]) (let ([r1 (tesl_import_Int_divide *a nzB)]) (raw-value (tesl_import_Int_divide (raw-value r1) nzC))))))))))

(define/pow
  (getDictValue [key : String] [d : (Dict String Integer) ::: (HasKey key d)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 160 (list (cons 'key *key) (cons 'd *d)) (lambda () (raw-value (tesl_import_Dict_get *key d)))))

(define/pow
  (testDictViaHelper [key : String] [d : (Dict String Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 163 (list (cons 'key *key) (cons 'd *d)) (lambda () (let/check ([tesl_checked_3 (tesl_import_Dict_requireKey key d)]) (let ([checked tesl_checked_3]) (raw-value (getDictValue key checked)))))))

(define/pow
  (nonNegHelper [n : Integer ::: (IsNonNegative n)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 177 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (testNonNegViaHelper [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 180 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_4 (tesl_import_Int_nonNegative n)]) (let ([nn tesl_checked_4]) (raw-value (nonNegHelper nn)))))))

(define/pow
  (floatDivHelper [a : Real] [b : Real ::: (FloatNonZero b)])
  #:returns Real
  (thsl-src! "tests/critical-review63-tests.tesl" 193 (list (cons 'a *a) (cons 'b *b)) (lambda () (raw-value (tesl_import_Float_div *a b)))))

(define/pow
  (testFloatDivViaHelper [a : Real] [b : Real])
  #:returns Real
  (thsl-src! "tests/critical-review63-tests.tesl" 196 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl_checked_5 (tesl_import_Float_requireNonZero b)]) (let ([nz tesl_checked_5]) (raw-value (floatDivHelper a nz)))))))

(define/pow
  (processPositiveList [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 213 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (getPositives [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review63-tests.tesl" 216 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs))))

(define/pow
  (testForAllParamToReturn [xs : (List Integer)])
  #:returns Integer
  (let ([positives (thsl-src! "tests/critical-review63-tests.tesl" 219 (list (cons 'xs *xs)) (lambda () (getPositives xs)))]) (thsl-src! "tests/critical-review63-tests.tesl" 220 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (raw-value (processPositiveList positives))))))

(define/pow
  (getPositivesQuestion [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review63-tests.tesl" 228 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs))))

(define/pow
  (testQuestionReturnToParam [xs : (List Integer)])
  #:returns Integer
  (let ([positives (thsl-src! "tests/critical-review63-tests.tesl" 231 (list (cons 'xs *xs)) (lambda () (getPositivesQuestion xs)))]) (thsl-src! "tests/critical-review63-tests.tesl" 232 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (raw-value (processPositiveList positives))))))

(define/pow
  (testAllCheckToParam [xs : (List Integer)])
  #:returns Integer
  (let ([r (thsl-src! "tests/critical-review63-tests.tesl" 240 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck checkPos *xs)))]) (thsl-src-control! "tests/critical-review63-tests.tesl" 241 (list (cons 'r *r) (cons 'xs *xs)) (lambda () (let ([tesl_case_6 (raw-value r)]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Nothing)) (thsl-src! "tests/critical-review63-tests.tesl" 242 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Something)) (let ([vs (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (thsl-src! "tests/critical-review63-tests.tesl" 243 (list (cons 'vs vs)) (lambda () (raw-value (processPositiveList *vs)))))]))))))

(define/pow
  (testEmptyForAll)
  #:returns Integer
  (let ([empty (thsl-src! "tests/critical-review63-tests.tesl" 256 (list) (lambda () (tesl_import_List_emptyForAll checkPos)))]) (thsl-src! "tests/critical-review63-tests.tesl" 257 (list (cons 'empty *empty)) (lambda () (raw-value (processPositiveList empty))))))

(define/pow
  (narrowToSmallPositive [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review63-tests.tesl" 265 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkSmall *xs))))

(define/pow
  (countPositiveSmall [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 268 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (sequentialFilterAccumulates [xs : (List Integer)])
  #:returns (List Integer)
  (let ([p1 (thsl-src! "tests/critical-review63-tests.tesl" 278 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs)))]) (thsl-src! "tests/critical-review63-tests.tesl" 279 (list (cons 'p1 *p1) (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkSmall (raw-value p1))))))

(define/pow
  (testDetachSingle [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review63-tests.tesl" 292 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([xA (thsl-src! "tests/critical-review63-tests.tesl" 293 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x pa)))]) (let ([detached (thsl-src! "tests/critical-review63-tests.tesl" 294 (list (cons 'xA *xA) (cons 'pa *pa) (cons 'x *x)) (lambda () (detach-all-proof xA)))]) (let ([restored (thsl-src! "tests/critical-review63-tests.tesl" 295 (list (cons 'detached *detached) (cons 'xA *xA) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x detached)))]) (thsl-src! "tests/critical-review63-tests.tesl" 296 (list (cons 'restored *restored) (cons 'detached *detached) (cons 'xA *xA) (cons 'pa *pa) (cons 'x *x)) (lambda () (raw-value (needsA restored)))))))))

(define/pow
  (testDetachMulti [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review63-tests.tesl" 299 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([pb (thsl-src! "tests/critical-review63-tests.tesl" 300 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (proveB x)))]) (let ([pab (thsl-src! "tests/critical-review63-tests.tesl" 301 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pa pb)))]) (let ([xAB (thsl-src! "tests/critical-review63-tests.tesl" 302 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x pab)))]) (let ([detached (thsl-src! "tests/critical-review63-tests.tesl" 304 (list (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (detach-all-proof xAB)))]) (let ([la (thsl-src! "tests/critical-review63-tests.tesl" 306 (list (cons 'detached *detached) (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-left detached)))]) (let ([xA (thsl-src! "tests/critical-review63-tests.tesl" 307 (list (cons 'la *la) (cons 'detached *detached) (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x la)))]) (thsl-src! "tests/critical-review63-tests.tesl" 308 (list (cons 'xA *xA) (cons 'la *la) (cons 'detached *detached) (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (raw-value (needsA xA))))))))))))

(define/pow
  (testDetachMultiBothProofs [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review63-tests.tesl" 311 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([pb (thsl-src! "tests/critical-review63-tests.tesl" 312 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (proveB x)))]) (let ([pab (thsl-src! "tests/critical-review63-tests.tesl" 313 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pa pb)))]) (let ([xAB (thsl-src! "tests/critical-review63-tests.tesl" 314 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x pab)))]) (let ([detached (thsl-src! "tests/critical-review63-tests.tesl" 315 (list (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (detach-all-proof xAB)))]) (let ([la (thsl-src! "tests/critical-review63-tests.tesl" 316 (list (cons 'detached *detached) (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-left detached)))]) (let ([rb (thsl-src! "tests/critical-review63-tests.tesl" 317 (list (cons 'la *la) (cons 'detached *detached) (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-right detached)))]) (let ([xA (thsl-src! "tests/critical-review63-tests.tesl" 318 (list (cons 'rb *rb) (cons 'la *la) (cons 'detached *detached) (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x la)))]) (let ([xB (thsl-src! "tests/critical-review63-tests.tesl" 319 (list (cons 'xA *xA) (cons 'rb *rb) (cons 'la *la) (cons 'detached *detached) (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x rb)))]) (thsl-src! "tests/critical-review63-tests.tesl" 320 (list (cons 'xB *xB) (cons 'xA *xA) (cons 'rb *rb) (cons 'la *la) (cons 'detached *detached) (cons 'xAB *xAB) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (+ (raw-value (needsA xA)) (raw-value (needsB xB)))))))))))))))

(define-checker
  (checkHasPrefix [s : String])
  #:returns [s : String ::: (HasPrefix s)]
  (thsl-src! "tests/critical-review63-tests.tesl" 345 (list (cons 's *s)) (lambda () (if (tesl_import_String_startsWith *s "admin") (accept (HasPrefix s) #:value *s) (reject "no prefix" #:http-code 400)))))

(define-checker
  (checkIsLong [s : String])
  #:returns [s : String ::: (IsLong s)]
  (thsl-src! "tests/critical-review63-tests.tesl" 351 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 5) (accept (IsLong s) #:value *s) (reject "too short" #:http-code 400)))))

(define/pow
  (processLongPrefixed [xs : (List String)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 357 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (filterBothCombined [xs : (List String)])
  #:returns Integer
  (let ([both (thsl-src! "tests/critical-review63-tests.tesl" 360 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck (check-and checkHasPrefix checkIsLong) *xs)))]) (thsl-src! "tests/critical-review63-tests.tesl" 361 (list (cons 'both *both) (cons 'xs *xs)) (lambda () (raw-value (processLongPrefixed both))))))

(define/pow
  (filterBothSequential [xs : (List String)])
  #:returns Integer
  (let ([prefixed (thsl-src! "tests/critical-review63-tests.tesl" 364 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkHasPrefix *xs)))]) (let ([long (thsl-src! "tests/critical-review63-tests.tesl" 365 (list (cons 'prefixed *prefixed) (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkIsLong (raw-value prefixed))))]) (thsl-src! "tests/critical-review63-tests.tesl" 366 (list (cons 'long *long) (cons 'prefixed *prefixed) (cons 'xs *xs)) (lambda () (raw-value (processLongPrefixed long)))))))

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review63-tests.tesl" 385 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (thsl-src! "tests/critical-review63-tests.tesl" 391 (list (cons 'n *n)) (lambda () (if (> *n 1) (accept ((A n) && (B n)) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: ((A n) && ((B n) && (C n)))]
  (thsl-src! "tests/critical-review63-tests.tesl" 397 (list (cons 'n *n)) (lambda () (if (> *n 2) (accept ((A n) && ((B n) && (C n))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))]
  (thsl-src! "tests/critical-review63-tests.tesl" 403 (list (cons 'n *n)) (lambda () (if (> *n 3) (accept ((A n) && ((B n) && ((C n) && (D n)))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))]
  (thsl-src! "tests/critical-review63-tests.tesl" 409 (list (cons 'n *n)) (lambda () (if (> *n 4) (accept ((A n) && ((B n) && ((C n) && ((D n) && (E n))))) #:value *n) (reject "bad" #:http-code 400)))))

(define/pow
  (chain5Step [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 415 (list (cons 'x *x)) (lambda () (let/check ([tesl_checked_7 (checkA x)]) (let ([a tesl_checked_7]) (let/check ([tesl_checked_8 (checkB a)]) (let ([ab tesl_checked_8]) (let/check ([tesl_checked_9 (checkC ab)]) (let ([abc tesl_checked_9]) (let/check ([tesl_checked_10 (checkD abc)]) (let ([abcd tesl_checked_10]) (let/check ([tesl_checked_11 (checkE abcd)]) (let ([abcde tesl_checked_11]) (raw-value (needsAll5 abcde)))))))))))))))

(define/pow
  (testLetDecompAB [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 444 (list (cons 'x *x)) (lambda () (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pab (intro-and pa pb)]) (let ([xAB (attach-proof x pab)]) (let ([tesl_proof_binding_12 xAB]) (let ([y (forget-proof tesl_proof_binding_12)] [qa (detach-all-proof tesl_proof_binding_12)]) (let ([tesl_proof_binding_13 xAB]) (let ([_ (forget-proof tesl_proof_binding_13)] [qb (detach-all-proof tesl_proof_binding_13)]) (+ (raw-value (needsA (attach-proof y qa))) (raw-value (needsB (attach-proof y qb)))))))))))))))

(define/pow
  (testLetDecomp3Way [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 457 (list (cons 'x *x)) (lambda () (let ([pa (proveA x)]) (let ([pb (proveB x)]) (let ([pc (proveC x)]) (let ([pab (intro-and pa pb)]) (let ([pabc (intro-and pab pc)]) (let ([xABC (attach-proof x pabc)]) (let ([tesl_proof_binding_14 xABC]) (let ([y (forget-proof tesl_proof_binding_14)] [qc (detach-all-proof tesl_proof_binding_14)]) (raw-value (needsC (attach-proof y qc))))))))))))))

(define/pow
  (testLetProofFromCheck [raw : Integer])
  #:returns Integer
  (let ([tesl_proof_binding_15 (thsl-src! "tests/critical-review63-tests.tesl" 472 (list (cons 'raw *raw)) (lambda () (checkPos raw)))]) (let ([_ (forget-proof tesl_proof_binding_15)] [p (detach-all-proof tesl_proof_binding_15)]) (let ([proven (thsl-src! "tests/critical-review63-tests.tesl" 473 (list (cons '_ *_) (cons 'raw *raw)) (lambda () (attach-proof raw p)))]) (thsl-src! "tests/critical-review63-tests.tesl" 474 (list (cons 'proven *proven) (cons '_ *_) (cons 'raw *raw)) (lambda () (raw-value (needsPos proven))))))))

(define-adt Inner
  [InnerA [val : Integer]]
  [InnerB [msg : String]]
)

(define-adt Outer
  [OuterWrap [inner : Inner]]
  [OuterEmpty]
)

(define/pow
  (extractNested [o : Outer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review63-tests.tesl" 498 (list (cons 'o *o)) (lambda () (let ([tesl_case_16 *o]) (cond [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'OuterEmpty)) (thsl-src! "tests/critical-review63-tests.tesl" 499 (list) (lambda () (raw-value -1)))] [(and (and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'OuterWrap)) (let ([tesl_case_16_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_16) 'inner))]) (and (adt-value? *tesl_case_16_f0) (eq? (adt-value-variant *tesl_case_16_f0) 'InnerA)))) (let ([tesl_case_16_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_16) 'inner))]) (let ([v (hash-ref (adt-value-fields *tesl_case_16_f0) 'val)]) (thsl-src! "tests/critical-review63-tests.tesl" 500 (list (cons 'v v)) (lambda () *v))))] [(and (and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'OuterWrap)) (let ([tesl_case_16_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_16) 'inner))]) (and (adt-value? *tesl_case_16_f0) (eq? (adt-value-variant *tesl_case_16_f0) 'InnerB)))) (let ([tesl_case_16_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_16) 'inner))]) (thsl-src! "tests/critical-review63-tests.tesl" 501 (list) (lambda () (raw-value 0))))])))))

(define-adt Tree
  [Leaf]
  [Node [left : Tree] [value : Integer] [right : Tree]]
)

(define/pow
  (sumTree [t : Tree])
  #:returns Integer
  (thsl-src-control! "tests/critical-review63-tests.tesl" 523 (list (cons 't *t)) (lambda () (let ([tesl_case_17 *t]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Leaf)) (thsl-src! "tests/critical-review63-tests.tesl" 524 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_17) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_17) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_17) 'right)]) (thsl-src! "tests/critical-review63-tests.tesl" 525 (list (cons 'l l) (cons 'v v) (cons 'r r)) (lambda () (raw-value (+ (+ (raw-value (sumTree *l)) *v) (raw-value (sumTree *r)))))))))])))))

(define/pow
  (treeHeight [t : Tree])
  #:returns Integer
  (thsl-src-control! "tests/critical-review63-tests.tesl" 528 (list (cons 't *t)) (lambda () (let ([tesl_case_18 *t]) (cond [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Leaf)) (thsl-src! "tests/critical-review63-tests.tesl" 529 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_18) 'left)]) (let ([r (hash-ref (adt-value-fields *tesl_case_18) 'right)]) (thsl-src! "tests/critical-review63-tests.tesl" 531 (list (cons 'l l) (cons 'r r)) (lambda () (let ([lh (treeHeight *l)]) (let ([rh (treeHeight *r)]) (if (> (raw-value lh) (raw-value rh)) (raw-value (+ (raw-value lh) 1)) (raw-value (+ (raw-value rh) 1)))))))))])))))

(define/pow
  (buildBalancedTree)
  #:returns Tree
  (thsl-src! "tests/critical-review63-tests.tesl" 539 (list) (lambda () (raw-value (Node (Node Leaf 1 Leaf) 2 (Node (Node Leaf 3 Leaf) 4 Leaf))))))

(define-checker
  (checkAllPositive [t : Tree])
  #:returns [t : Tree ::: (AllPositive t)]
  (thsl-src-control! "tests/critical-review63-tests.tesl" 557 (list (cons 't *t)) (lambda () (let ([tesl_case_19 *t]) (cond [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Leaf)) (thsl-src! "tests/critical-review63-tests.tesl" 559 (list) (lambda () (accept (AllPositive t) #:value *t)))] [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_19) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_19) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_19) 'right)]) (thsl-src! "tests/critical-review63-tests.tesl" 561 (list (cons 'l l) (cons 'v v) (cons 'r r)) (lambda () (if (<= (raw-value v) 0) (reject "non-positive node" #:http-code 400) (let/check ([tesl_checked_20 (checkAllPositive l)]) (let ([l2 tesl_checked_20]) (let/check ([tesl_checked_21 (checkAllPositive r)]) (let ([r2 tesl_checked_21]) (accept (AllPositive t) #:value *t)))))))))))])))))

(define/pow
  (processAllPositiveTree [t : Tree ::: (AllPositive t)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 568 (list (cons 't *t)) (lambda () (raw-value (sumTree t)))))

(define/pow
  (testTreeProof [t : Tree])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 571 (list (cons 't *t)) (lambda () (let/check ([tesl_checked_22 (checkAllPositive t)]) (let ([validated tesl_checked_22]) (raw-value (processAllPositiveTree validated)))))))

(define/pow
  (rangeHelper [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 589 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (testMultiParamViaHelper [lo : Integer] [hi : Integer] [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 592 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (let/check ([tesl_checked_23 (checkRange lo hi n)]) (let ([validated tesl_checked_23]) (raw-value (rangeHelper lo hi validated)))))))

(define/pow
  (testArithPrec [a : Integer] [b : Integer] [c : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review63-tests.tesl" 614 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (+ *a (* *b *c)))))

(define/pow
  (testComparePrec [a : Integer] [b : Integer] [c : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review63-tests.tesl" 617 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (> (+ *a *b) *c))))

(define/pow
  (testBoolPrec [a : Integer] [b : Integer] [c : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review63-tests.tesl" 620 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (and (> *a 0) (or (> *b 0) (> *c 0))))))

(define-record SafePost
  [title : String ::: (IsTrimmed title)]
  [count : Integer]
)

(define/pow
  (requiresTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  (thsl-src! "tests/critical-review63-tests.tesl" 647 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (makeSafePost [raw : String] [count : Integer])
  #:returns SafePost
  (let ([trimmed (thsl-src! "tests/critical-review63-tests.tesl" 650 (list (cons 'raw *raw) (cons 'count *count)) (lambda () (tesl_import_String_trim *raw)))]) (thsl-src! "tests/critical-review63-tests.tesl" 651 (list (cons 'trimmed *trimmed) (cons 'raw *raw) (cons 'count *count)) (lambda () (SafePost #:title trimmed #:count *count)))))

(define/pow
  (readTitle [p : SafePost])
  #:returns String
  (thsl-src! "tests/critical-review63-tests.tesl" 654 (list (cons 'p *p)) (lambda () (raw-value (requiresTrimmed (tesl-dot/runtime p 'title))))))

(define/pow
  (updateCountPreservesProof [p : SafePost] [newCount : Integer])
  #:returns SafePost
  (thsl-src! "tests/critical-review63-tests.tesl" 670 (list (cons 'p *p) (cons 'newCount *newCount)) (lambda () (tesl-record-update *p (hash 'count *newCount)))))

(define/pow
  (safeDivFloat [a : Real] [b : Real])
  #:returns Real
  (thsl-src! "tests/critical-review63-tests.tesl" 684 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl_checked_24 (tesl_import_Float_requireNonZero b)]) (let ([nz tesl_checked_24]) (raw-value (tesl_import_Float_div *a nz)))))))

(define/pow
  (divChainFloat [a : Real] [b : Real] [c : Real])
  #:returns Real
  (thsl-src! "tests/critical-review63-tests.tesl" 688 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (let/check ([tesl_checked_25 (tesl_import_Float_requireNonZero b)]) (let ([nzB tesl_checked_25]) (let/check ([tesl_checked_26 (tesl_import_Float_requireNonZero c)]) (let ([nzC tesl_checked_26]) (let ([r1 (raw-value (tesl_import_Float_div *a nzB))]) (raw-value (tesl_import_Float_div (raw-value r1) nzC))))))))))

(module+ test
  (require rackunit)
  (test-case "R63_PP01 Int.divide works through function parameter boundary"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 140 (list) (lambda () (testDivideViaHelper 10 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 141 (list (cons 'r r)) (lambda () r))) 2)
  )

  (test-case "R63_PP02 Int.divide via helper fails correctly for zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 145 (list) (lambda ()
                          ((testDivideViaHelper 10 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testDivideViaHelper 10 0) (list)"))
  )

  (test-case "R63_PP03 chained Int.divide with two proof-annotated params"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 155 (list) (lambda () (divideChain 100 5 2))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 156 (list (cons 'r r)) (lambda () r))) 10)
  )

  (test-case "R63_PP04 Dict.get works through function parameter boundary"
  (define d (thsl-src! "tests/critical-review63-tests.tesl" 167 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 42) (Tuple2 "b" 99)))))))
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 168 (list (cons 'd d)) (lambda () (testDictViaHelper "a" d))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 169 (list (cons 'r r) (cons 'd d)) (lambda () r))) 42)
  )

  (test-case "R63_PP05 Dict.get via helper fails for missing key"
  (define d (thsl-src! "tests/critical-review63-tests.tesl" 173 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "b" 99)))))))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 174 (list (cons 'd d)) (lambda ()
                          ((testDictViaHelper "a" d) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testDictViaHelper \"a\" d) (list)"))
  )

  (test-case "R63_PP06 IsNonNegative proof through function parameter boundary"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 184 (list) (lambda () (testNonNegViaHelper 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 185 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R63_PP07 IsNonNegative proof fails for negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 189 (list) (lambda ()
                          ((testNonNegViaHelper -1) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testNonNegViaHelper -1) (list)"))
  )

  (test-case "R63_PP08 Float.div works through function parameter boundary"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 200 (list) (lambda () (testFloatDivViaHelper 10. 4.))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 201 (list (cons 'r r)) (lambda () r))) 2.5)
  )

  (test-case "R63_PP09 Float.div via helper fails for zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 205 (list) (lambda ()
                          ((testFloatDivViaHelper 10. 0.) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testFloatDivViaHelper 10. 0.) (list)"))
  )

  (test-case "R63_FA01 ForAll with ? return can be consumed by explicit-subject parameter"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 223 (list) (lambda () (testForAllParamToReturn (list 1 2 3 -1 0)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 224 (list (cons 'r r)) (lambda () r))) 3)
  )

  (test-case "R63_FA02 ForAll ? return flows to explicit-subject parameter"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 235 (list) (lambda () (testQuestionReturnToParam (list 5 10 -3 0 7)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 236 (list (cons 'r r)) (lambda () r))) 3)
  )

  (test-case "R63_FA03 allCheck result flows to explicit-subject ForAll parameter"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 246 (list) (lambda () (testAllCheckToParam (list 1 2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 247 (list (cons 'r r)) (lambda () r))) 3)
  )

  (test-case "R63_FA04 allCheck returns Nothing when any element fails"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 251 (list) (lambda () (testAllCheckToParam (list 1 -1 2)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 252 (list (cons 'r r)) (lambda () r))) 0)
  )

  (test-case "R63_FA05 List.emptyForAll produces valid ForAll list"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 260 (list) (lambda () (testEmptyForAll))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 261 (list (cons 'r r)) (lambda () r))) 0)
  )

  (test-case "R63_FA06 narrowToSmall pattern: filterCheck on ForAll param produces conjunction"
  (define positives (thsl-src! "tests/critical-review63-tests.tesl" 271 (list) (lambda () (tesl_import_List_filterCheck checkPos (list 1 50 200 -1 99 0)))))
  (define small (thsl-src! "tests/critical-review63-tests.tesl" 272 (list (cons 'positives positives)) (lambda () (narrowToSmallPositive positives))))
  (define count (thsl-src! "tests/critical-review63-tests.tesl" 273 (list (cons 'small small) (cons 'positives positives)) (lambda () (countPositiveSmall small))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 274 (list (cons 'count count) (cons 'small small) (cons 'positives positives)) (lambda () count))) 3)
  )

  (test-case "R63_FA07 sequential filterCheck accumulates ForAll predicates"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 282 (list) (lambda () (sequentialFilterAccumulates (list 1 50 200 -1 99 0)))))
  (define count (thsl-src! "tests/critical-review63-tests.tesl" 283 (list (cons 'r r)) (lambda () (countPositiveSmall r))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 284 (list (cons 'count count) (cons 'r r)) (lambda () count))) 3)
  )

  (test-case "R63_DC01 detachFact works on single-proof value"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 323 (list) (lambda () (testDetachSingle 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 324 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R63_DC02 detachFact on multi-proof value succeeds: returns combined (A && B) proof"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 328 (list) (lambda () (testDetachMulti 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 329 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R63_DC03 detachFact on multi-proof: andLeft and andRight both work on result"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 333 (list) (lambda () (testDetachMultiBothProofs 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 334 (list (cons 'r r)) (lambda () r))) 10)
  )

  (test-case "R63_SC01 combined && check produces correct ForAll conjunction"
  (define xs (thsl-src! "tests/critical-review63-tests.tesl" 369 (list) (lambda () (list "admin1234567" "admin" "user123456" "adminXXXXXX"))))
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 370 (list (cons 'xs xs)) (lambda () (filterBothCombined xs))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 371 (list (cons 'r r) (cons 'xs xs)) (lambda () r))) 2)
  )

  (test-case "R63_SC02 sequential filterCheck accumulates correctly"
  (define xs (thsl-src! "tests/critical-review63-tests.tesl" 375 (list) (lambda () (list "admin1234567" "admin" "user123456" "adminXXXXXX"))))
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 376 (list (cons 'xs xs)) (lambda () (filterBothSequential xs))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 377 (list (cons 'r r) (cons 'xs xs)) (lambda () r))) 2)
  )

  (test-case "R63_CH01 5-step proof chain accumulates and satisfies conjunction"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 423 (list) (lambda () (chain5Step 10))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 424 (list (cons 'r r)) (lambda () r))) 10)
  )

  (test-case "R63_CH02 5-step chain fails at step 1"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 428 (list) (lambda ()
                          ((chain5Step 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (chain5Step 0) (list)"))
  )

  (test-case "R63_CH03 5-step chain fails at step 3"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 432 (list) (lambda ()
                          ((chain5Step 2) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (chain5Step 2) (list)"))
  )

  (test-case "R63_CH04 5-step chain fails at step 5"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 436 (list) (lambda ()
                          ((chain5Step 4) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (chain5Step 4) (list)"))
  )

  (test-case "R63_LT01 let proof decomposition: (y ::: qa && qb) = xAB"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 452 (list) (lambda () (testLetDecompAB 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 453 (list (cons 'r r)) (lambda () r))) 10)
  )

  (test-case "R63_LT02 3-way proof decomposition with _ discards"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 467 (list) (lambda () (testLetDecomp3Way 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 468 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R63_LT03 let (_ ::: p) = check f(x) pattern works"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 477 (list) (lambda () (testLetProofFromCheck 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 478 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R63_LT04 let (_ ::: p) pattern fails when check fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 482 (list) (lambda ()
                          ((testLetProofFromCheck 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testLetProofFromCheck 0) (list)"))
  )

  (test-case "R63_NP01 nested constructor pattern: OuterWrap (InnerA v)"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 504 (list) (lambda () (extractNested (OuterWrap (InnerA 42))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 505 (list (cons 'r r)) (lambda () r))) 42)
  )

  (test-case "R63_NP02 nested constructor pattern: OuterWrap (InnerB _)"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 509 (list) (lambda () (extractNested (OuterWrap (InnerB "hello"))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 510 (list (cons 'r r)) (lambda () r))) 0)
  )

  (test-case "R63_NP03 nested constructor pattern: OuterEmpty"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 514 (list) (lambda () (extractNested OuterEmpty))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 515 (list (cons 'r r)) (lambda () r))) -1)
  )

  (test-case "R63_NP04 recursive tree sum = 1+2+3+4 = 10"
  (define t (thsl-src! "tests/critical-review63-tests.tesl" 545 (list) (lambda () (buildBalancedTree))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 546 (list (cons 't t)) (lambda () (sumTree t)))) 10)
  )

  (test-case "R63_NP05 recursive tree height = 3"
  (define t (thsl-src! "tests/critical-review63-tests.tesl" 550 (list) (lambda () (buildBalancedTree))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 551 (list (cons 't t)) (lambda () (treeHeight t)))) 3)
  )

  (test-case "R63_NP06 recursive tree proof: all-positive tree succeeds"
  (define t (thsl-src! "tests/critical-review63-tests.tesl" 575 (list) (lambda () (buildBalancedTree))))
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 576 (list (cons 't t)) (lambda () (testTreeProof t))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 577 (list (cons 'r r) (cons 't t)) (lambda () r))) 10)
  )

  (test-case "R63_NP07 recursive tree proof: negative node fails"
  (define badTree (thsl-src! "tests/critical-review63-tests.tesl" 581 (list) (lambda () (raw-value (Node Leaf -1 Leaf)))))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 582 (list (cons 'badTree badTree)) (lambda ()
                          ((testTreeProof badTree) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testTreeProof badTree) (list)"))
  )

  (test-case "R63_MP01 multi-param proof InRange through function boundary"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 596 (list) (lambda () (testMultiParamViaHelper 0 100 50))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 597 (list (cons 'r r)) (lambda () r))) 50)
  )

  (test-case "R63_MP02 multi-param proof fails for out-of-range"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 601 (list) (lambda ()
                          ((testMultiParamViaHelper 0 100 200) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testMultiParamViaHelper 0 100 200) (list)"))
  )

  (test-case "R63_MP03 multi-param proof with negative bounds"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 605 (list) (lambda () (testMultiParamViaHelper -50 50 -10))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 606 (list (cons 'r r)) (lambda () r))) -10)
  )

  (test-case "R63_OP01 * binds tighter than +"
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 623 (list) (lambda () (testArithPrec 2 3 4)))) 14)
  )

  (test-case "R63_OP02 arithmetic before comparison"
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 627 (list) (lambda () (testComparePrec 2 3 4)))) #t)
  )

  (test-case "R63_OP03 && binds tighter than ||"
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 631 (list) (lambda () (testBoolPrec 1 1 0)))) #t)
  )

  (test-case "R63_OP04 && binds tighter than || negative case"
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 635 (list) (lambda () (testBoolPrec -1 1 0)))) #f)
  )

  (test-case "R63_RC01 record field proof propagates on read"
  (define p (thsl-src! "tests/critical-review63-tests.tesl" 657 (list) (lambda () (makeSafePost "  Hello  " 5))))
  (define title (thsl-src! "tests/critical-review63-tests.tesl" 658 (list (cons 'p p)) (lambda () (readTitle p))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 659 (list (cons 'title title) (cons 'p p)) (lambda () title))) "Hello")
  )

  (test-case "R63_RC02 record update on non-proof field preserves proof fields"
  (define p (thsl-src! "tests/critical-review63-tests.tesl" 663 (list) (lambda () (makeSafePost "Hello" 1))))
  (define p2 (thsl-src! "tests/critical-review63-tests.tesl" 664 (list (cons 'p p)) (lambda () (tesl-record-update (raw-value p) (hash 'count (raw-value 99))))))
  (define t (thsl-src! "tests/critical-review63-tests.tesl" 665 (list (cons 'p2 p2) (cons 'p p)) (lambda () (readTitle p2))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 666 (list (cons 't t) (cons 'p2 p2) (cons 'p p)) (lambda () t))) "Hello")
  )

  (test-case "R63_RC03 proof field accessible after helper function update"
  (define p (thsl-src! "tests/critical-review63-tests.tesl" 673 (list) (lambda () (makeSafePost "World" 0))))
  (define p2 (thsl-src! "tests/critical-review63-tests.tesl" 674 (list (cons 'p p)) (lambda () (updateCountPreservesProof p 42))))
  (define t (thsl-src! "tests/critical-review63-tests.tesl" 675 (list (cons 'p2 p2) (cons 'p p)) (lambda () (readTitle p2))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 676 (list (cons 't t) (cons 'p2 p2) (cons 'p p)) (lambda () t))) "World")
  )

  (test-case "R63_FP01 Float.div direct"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 694 (list) (lambda () (safeDivFloat 10. 4.))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 695 (list (cons 'r r)) (lambda () r))) 2.5)
  )

  (test-case "R63_FP02 Float.div by zero fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review63-tests.tesl" 699 (list) (lambda ()
                          ((safeDivFloat 10. 0.) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivFloat 10. 0.) (list)"))
  )

  (test-case "R63_FP03 Float.div chained"
  (define r (thsl-src! "tests/critical-review63-tests.tesl" 703 (list) (lambda () (divChainFloat 100. 5. 4.))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review63-tests.tesl" 704 (list (cons 'r r)) (lambda () r))) 5.)
  )

)
