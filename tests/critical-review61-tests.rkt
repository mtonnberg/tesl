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
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.sort tesl_import_List_sort] [List.map tesl_import_List_map] [List.emptyForAll tesl_import_List_emptyForAll] IsSorted)
  (only-in tesl/tesl/set Set [Set.filterCheck tesl_import_Set_filterCheck] [Set.fromList tesl_import_Set_fromList] [Set.size tesl_import_Set_size] [Set.insert tesl_import_Set_insert] [Set.empty tesl_import_Set_empty])
  (only-in tesl/tesl/dict Dict [Dict.filterCheckValues tesl_import_Dict_filterCheckValues] [Dict.fromList tesl_import_Dict_fromList] [Dict.size tesl_import_Dict_size])
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.toUpper tesl_import_String_toUpper] [String.length tesl_import_String_length] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/int [Int.divide tesl_import_Int_divide] [Int.nonZero tesl_import_Int_nonZero] IsNonZero)
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define F 'F)
(define G 'G)
(define InRange 'InRange)
(define IsEven 'IsEven)
(define IsOdd 'IsOdd)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define LengthOk 'LengthOk)
(define TitleSafe 'TitleSafe)
(define X 'X)
(define Y 'Y)
(define Z 'Z)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review61-tests.tesl" 90 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (thsl-src! "tests/critical-review61-tests.tesl" 96 (list (cons 'n *n)) (lambda () (if (> *n 1) (accept ((A n) && (B n)) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: ((A n) && ((B n) && (C n)))]
  (thsl-src! "tests/critical-review61-tests.tesl" 102 (list (cons 'n *n)) (lambda () (if (> *n 2) (accept ((A n) && ((B n) && (C n))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))]
  (thsl-src! "tests/critical-review61-tests.tesl" 108 (list (cons 'n *n)) (lambda () (if (> *n 3) (accept ((A n) && ((B n) && ((C n) && (D n)))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))]
  (thsl-src! "tests/critical-review61-tests.tesl" 114 (list (cons 'n *n)) (lambda () (if (> *n 4) (accept ((A n) && ((B n) && ((C n) && ((D n) && (E n))))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkF [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n))))))]
  (thsl-src! "tests/critical-review61-tests.tesl" 120 (list (cons 'n *n)) (lambda () (if (> *n 5) (accept ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n)))))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkG [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n))))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && ((F n) && (G n)))))))]
  (thsl-src! "tests/critical-review61-tests.tesl" 126 (list (cons 'n *n)) (lambda () (if (> *n 6) (accept ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && ((F n) && (G n))))))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review61-tests.tesl" 132 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review61-tests.tesl" 138 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))))

(define-checker
  (checkTitle [s : String])
  #:returns [s : String ::: (TitleSafe s)]
  (thsl-src! "tests/critical-review61-tests.tesl" 144 (list (cons 's *s)) (lambda () (if (< (raw-value (tesl_import_String_length *s)) 100) (accept (TitleSafe s) #:value *s) (reject "too long" #:http-code 400)))))

(define-checker
  (checkLengthOk [n : Integer])
  #:returns [n : Integer ::: (LengthOk n)]
  (thsl-src! "tests/critical-review61-tests.tesl" 150 (list (cons 'n *n)) (lambda () (if (and (> *n 0) (< *n 100)) (accept (LengthOk n) #:value *n) (reject "bad length" #:http-code 400)))))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review61-tests.tesl" 157 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review61-tests.tesl" 158 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define-trusted
  (proveC [n : Integer])
  #:returns (Fact (C n))
  (thsl-src! "tests/critical-review61-tests.tesl" 159 (list (cons 'n *n)) (lambda () (trusted-proof (C n)))))

(define-trusted
  (proveD [n : Integer])
  #:returns (Fact (D n))
  (thsl-src! "tests/critical-review61-tests.tesl" 160 (list (cons 'n *n)) (lambda () (trusted-proof (D n)))))

(define-trusted
  (proveE [n : Integer])
  #:returns (Fact (E n))
  (thsl-src! "tests/critical-review61-tests.tesl" 161 (list (cons 'n *n)) (lambda () (trusted-proof (E n)))))

(define-trusted
  (provePos [n : Integer])
  #:returns (Fact (IsPositive n))
  (thsl-src! "tests/critical-review61-tests.tesl" 162 (list (cons 'n *n)) (lambda () (trusted-proof (IsPositive n)))))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 166 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 167 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAll6 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n))))))])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 168 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAll7 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && ((F n) && (G n)))))))])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 169 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 170 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsSmall [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 171 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (build6Chain [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 178 (list (cons 'x *x)) (lambda () (let/check ([tesl-checked-0 (checkA x)]) (let ([a tesl-checked-0]) (let/check ([tesl-checked-1 (checkB a)]) (let ([b tesl-checked-1]) (let/check ([tesl-checked-2 (checkC b)]) (let ([c tesl-checked-2]) (let/check ([tesl-checked-3 (checkD c)]) (let ([d tesl-checked-3]) (let/check ([tesl-checked-4 (checkE d)]) (let ([e tesl-checked-4]) (let/check ([tesl-checked-5 (checkF e)]) (let ([f tesl-checked-5]) (raw-value (needsAll6 f)))))))))))))))))

(define/pow
  (build7Chain [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 187 (list (cons 'x *x)) (lambda () (let/check ([tesl-checked-6 (checkA x)]) (let ([a tesl-checked-6]) (let/check ([tesl-checked-7 (checkB a)]) (let ([b tesl-checked-7]) (let/check ([tesl-checked-8 (checkC b)]) (let ([c tesl-checked-8]) (let/check ([tesl-checked-9 (checkD c)]) (let ([d tesl-checked-9]) (let/check ([tesl-checked-10 (checkE d)]) (let ([e tesl-checked-10]) (let/check ([tesl-checked-11 (checkF e)]) (let ([f tesl-checked-11]) (let/check ([tesl-checked-12 (checkG f)]) (let ([g tesl-checked-12]) (raw-value (needsAll7 g)))))))))))))))))))

(define/pow
  (filterPositiveSet [xs : (Set Integer)])
  #:returns (Set Integer)
  (thsl-src! "tests/critical-review61-tests.tesl" 219 (list (cons 'xs *xs)) (lambda () (tesl_import_Set_filterCheck checkPos *xs))))

(define/pow
  (filterPositiveValues [xs : (Dict String Integer)])
  #:returns (Dict String Integer)
  (thsl-src! "tests/critical-review61-tests.tesl" 222 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_Dict_filterCheckValues checkPos *xs)))))

(define/pow
  (allSmall [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (thsl-src! "tests/critical-review61-tests.tesl" 225 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck (check-and checkPos checkSmall) *xs))))

(define/pow
  (getPositives [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review61-tests.tesl" 228 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPos *xs))))

(define/pow
  (narrowToSmall [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review61-tests.tesl" 231 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkSmall *xs))))

(define/pow
  (forAllPipeline [xs : (List Integer)])
  #:returns (List Integer)
  (let ([positives (thsl-src! "tests/critical-review61-tests.tesl" 234 (list (cons 'xs *xs)) (lambda () (getPositives xs)))]) (thsl-src! "tests/critical-review61-tests.tesl" 235 (list (cons 'positives *positives) (cons 'xs *xs)) (lambda () (narrowToSmall positives)))))

(define/pow
  (countSmall [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 238 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (requiresTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  (thsl-src! "tests/critical-review61-tests.tesl" 278 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (requiresUpperCase [s : String ::: (IsUpperCase s)])
  #:returns String
  (thsl-src! "tests/critical-review61-tests.tesl" 279 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (requiresSorted [xs : (List Integer) ::: (IsSorted xs)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review61-tests.tesl" 280 (list (cons 'xs *xs)) (lambda () *xs)))

(define/pow
  (trimAndUse [raw : String])
  #:returns String
  (let ([t (thsl-src! "tests/critical-review61-tests.tesl" 283 (list (cons 'raw *raw)) (lambda () (tesl_import_String_trim *raw)))]) (thsl-src! "tests/critical-review61-tests.tesl" 284 (list (cons 't *t) (cons 'raw *raw)) (lambda () (raw-value (requiresTrimmed t))))))

(define/pow
  (upperAndUse [raw : String])
  #:returns String
  (let ([u (thsl-src! "tests/critical-review61-tests.tesl" 287 (list (cons 'raw *raw)) (lambda () (tesl_import_String_toUpper *raw)))]) (thsl-src! "tests/critical-review61-tests.tesl" 288 (list (cons 'u *u) (cons 'raw *raw)) (lambda () (raw-value (requiresUpperCase u))))))

(define/pow
  (sortAndUse [xs : (List Integer)])
  #:returns (List Integer)
  (let ([s (thsl-src! "tests/critical-review61-tests.tesl" 291 (list (cons 'xs *xs)) (lambda () (tesl_import_List_sort *xs)))]) (thsl-src! "tests/critical-review61-tests.tesl" 292 (list (cons 's *s) (cons 'xs *xs)) (lambda () (raw-value (requiresSorted s))))))

(define-record SafeTriple
  [title : String ::: (TitleSafe title)]
  [count : Integer ::: (LengthOk count)]
  [score : Integer ::: (IsPositive score)]
)

(define/pow
  (buildSafeTriple [t : String] [c : Integer] [s : Integer])
  #:returns SafeTriple
  (thsl-src! "tests/critical-review61-tests.tesl" 320 (list (cons 't *t) (cons 'c *c) (cons 's *s)) (lambda () (let/check ([tesl-checked-13 (checkTitle t)]) (let ([safeTitle tesl-checked-13]) (let/check ([tesl-checked-14 (checkLengthOk c)]) (let ([safeCount tesl-checked-14]) (let/check ([tesl-checked-15 (checkPos s)]) (let ([safeScore tesl-checked-15]) (SafeTriple #:title safeTitle #:count safeCount #:score safeScore))))))))))

(define/pow
  (combine5Proofs [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review61-tests.tesl" 339 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([pb (thsl-src! "tests/critical-review61-tests.tesl" 340 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (proveB x)))]) (let ([pc (thsl-src! "tests/critical-review61-tests.tesl" 341 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (proveC x)))]) (let ([pd (thsl-src! "tests/critical-review61-tests.tesl" 342 (list (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (proveD x)))]) (let ([pe (thsl-src! "tests/critical-review61-tests.tesl" 343 (list (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (proveE x)))]) (let ([pab (thsl-src! "tests/critical-review61-tests.tesl" 344 (list (cons 'pe *pe) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pa pb)))]) (let ([pabc (thsl-src! "tests/critical-review61-tests.tesl" 345 (list (cons 'pab *pab) (cons 'pe *pe) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pab pc)))]) (let ([pabcd (thsl-src! "tests/critical-review61-tests.tesl" 346 (list (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pe *pe) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pabc pd)))]) (let ([pabcde (thsl-src! "tests/critical-review61-tests.tesl" 347 (list (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pe *pe) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pabcd pe)))]) (let ([x2 (thsl-src! "tests/critical-review61-tests.tesl" 348 (list (cons 'pabcde *pabcde) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pe *pe) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x pabcde)))]) (let ([la (thsl-src! "tests/critical-review61-tests.tesl" 349 (list (cons 'x2 *x2) (cons 'pabcde *pabcde) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pe *pe) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-left pabcde)))]) (let ([x3 (thsl-src! "tests/critical-review61-tests.tesl" 350 (list (cons 'la *la) (cons 'x2 *x2) (cons 'pabcde *pabcde) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pe *pe) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof (forget-proof x2) la)))]) (thsl-src! "tests/critical-review61-tests.tesl" 351 (list (cons 'x3 *x3) (cons 'la *la) (cons 'x2 *x2) (cons 'pabcde *pabcde) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pe *pe) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (raw-value (needsA x3)))))))))))))))))

(define/pow
  (andLeftRightRoundTrip [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review61-tests.tesl" 354 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([pb (thsl-src! "tests/critical-review61-tests.tesl" 355 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (proveB x)))]) (let ([pab (thsl-src! "tests/critical-review61-tests.tesl" 356 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pa pb)))]) (let ([la (thsl-src! "tests/critical-review61-tests.tesl" 357 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-left pab)))]) (let ([rb (thsl-src! "tests/critical-review61-tests.tesl" 358 (list (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-right pab)))]) (let ([x2 (thsl-src! "tests/critical-review61-tests.tesl" 359 (list (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof (forget-proof x) la)))]) (let ([x3 (thsl-src! "tests/critical-review61-tests.tesl" 360 (list (cons 'x2 *x2) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof (forget-proof x) rb)))]) (thsl-src! "tests/critical-review61-tests.tesl" 361 (list (cons 'x3 *x3) (cons 'x2 *x2) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (+ (raw-value (needsA x2)) (raw-value (needsB x3)))))))))))))

(define-trusted
  (proveInRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns (Maybe (Fact (InRange lo hi n)))
  (thsl-src! "tests/critical-review61-tests.tesl" 380 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (Something (trusted-proof (InRange lo hi n))) Nothing))))

(define/pow
  (requiresInRange [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 385 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (tryUseRange [lo : Integer] [hi : Integer] [x : Integer])
  #:returns Integer
  (let ([proof (thsl-src! "tests/critical-review61-tests.tesl" 388 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'x *x)) (lambda () (proveInRange lo hi x)))]) (thsl-src-control! "tests/critical-review61-tests.tesl" 389 (list (cons 'proof *proof) (cons 'lo *lo) (cons 'hi *hi) (cons 'x *x)) (lambda () (let ([tesl-case-16 (raw-value proof)]) (cond [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Nothing)) (thsl-src! "tests/critical-review61-tests.tesl" 390 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl-case-16) 'value)]) (thsl-src! "tests/critical-review61-tests.tesl" 392 (list (cons 'p p)) (lambda () (let ([x2 (attach-proof x *p)]) (raw-value (requiresInRange lo hi x2))))))]))))))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review61-tests.tesl" 410 (list (cons 'n *n)) (lambda () (if (< *n 0) (reject "negative" #:http-code 400) (if (tesl-equal? *n 0) (accept (IsEven n) #:value *n) (let/check ([tesl-checked-17 (checkOdd (- *n 1))]) (let ([_odd tesl-checked-17]) (accept (IsEven n) #:value *n))))))))

(define-checker
  (checkOdd [n : Integer])
  #:returns [n : Integer ::: (IsOdd n)]
  (thsl-src! "tests/critical-review61-tests.tesl" 419 (list (cons 'n *n)) (lambda () (if (<= *n 0) (reject "not odd" #:http-code 400) (if (tesl-equal? *n 1) (accept (IsOdd n) #:value *n) (let/check ([tesl-checked-18 (checkEven (- *n 1))]) (let ([_even tesl-checked-18]) (accept (IsOdd n) #:value *n))))))))

(define/pow
  (requiresEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 427 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (requiresOdd [n : Integer ::: (IsOdd n)])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 428 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (testMutualRec [e : Integer] [o : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 431 (list (cons 'e *e) (cons 'o *o)) (lambda () (let/check ([tesl-checked-19 (checkEven e)]) (let ([even tesl-checked-19]) (let/check ([tesl-checked-20 (checkOdd o)]) (let ([odd tesl-checked-20]) (+ (raw-value (requiresEven even)) (raw-value (requiresOdd odd))))))))))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 453 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-21 (tesl_import_Int_nonZero b)]) (let ([nonZeroB tesl-checked-21]) (raw-value (tesl_import_Int_divide *a nonZeroB)))))))

(define/pow
  (forgetAndRe [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 470 (list (cons 'x *x)) (lambda () (let/check ([tesl-checked-22 (checkPos x)]) (let ([proven tesl-checked-22]) (let ([raw (forget-proof proven)]) (let/check ([tesl-checked-23 (checkPos raw)]) (let ([reproven tesl-checked-23]) (raw-value (needsPositive reproven))))))))))

(define-adt Shape
  [Circle [r : Integer]]
  [Rectangle [w : Integer] [h : Integer]]
  [Triangle [base : Integer] [height : Integer]]
)

(define-adt Container
  [Empty]
  [Filled [item : Shape] [count : Integer]]
)

(define/pow
  (describeShape [s : Shape])
  #:returns String
  (thsl-src-control! "tests/critical-review61-tests.tesl" 494 (list (cons 's *s)) (lambda () (let ([tesl-case-24 *s]) (cond [(and (adt-value? *tesl-case-24) (eq? (adt-value-variant *tesl-case-24) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-24) 'r)]) (thsl-src! "tests/critical-review61-tests.tesl" 495 (list (cons 'r r)) (lambda () (raw-value "circle"))))] [(and (adt-value? *tesl-case-24) (eq? (adt-value-variant *tesl-case-24) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl-case-24) 'w)]) (let ([h (hash-ref (adt-value-fields *tesl-case-24) 'h)]) (thsl-src! "tests/critical-review61-tests.tesl" 496 (list (cons 'w w) (cons 'h h)) (lambda () (raw-value "rect")))))] [(and (adt-value? *tesl-case-24) (eq? (adt-value-variant *tesl-case-24) 'Triangle)) (let ([base (hash-ref (adt-value-fields *tesl-case-24) 'base)]) (let ([height (hash-ref (adt-value-fields *tesl-case-24) 'height)]) (thsl-src! "tests/critical-review61-tests.tesl" 497 (list (cons 'base base) (cons 'height height)) (lambda () (raw-value "triangle")))))])))))

(define/pow
  (describeContainer [c : Container])
  #:returns String
  (thsl-src-control! "tests/critical-review61-tests.tesl" 500 (list (cons 'c *c)) (lambda () (let ([tesl-case-25 *c]) (cond [(and (adt-value? *tesl-case-25) (eq? (adt-value-variant *tesl-case-25) 'Empty)) (thsl-src! "tests/critical-review61-tests.tesl" 501 (list) (lambda () (raw-value "empty")))] [(and (adt-value? *tesl-case-25) (eq? (adt-value-variant *tesl-case-25) 'Filled)) (let ([item (hash-ref (adt-value-fields *tesl-case-25) 'item)]) (let ([count (hash-ref (adt-value-fields *tesl-case-25) 'count)]) (thsl-src! "tests/critical-review61-tests.tesl" 503 (list (cons 'item item) (cons 'count count)) (lambda () (let ([tesl-case-26 (raw-value item)]) (cond [(and (adt-value? *tesl-case-26) (eq? (adt-value-variant *tesl-case-26) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-26) 'r)]) (thsl-src! "tests/critical-review61-tests.tesl" 504 (list (cons 'r r)) (lambda () (raw-value "circle"))))] [(and (adt-value? *tesl-case-26) (eq? (adt-value-variant *tesl-case-26) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl-case-26) 'w)]) (let ([h (hash-ref (adt-value-fields *tesl-case-26) 'h)]) (thsl-src! "tests/critical-review61-tests.tesl" 505 (list (cons 'w w) (cons 'h h)) (lambda () (raw-value "rect")))))] [(and (adt-value? *tesl-case-26) (eq? (adt-value-variant *tesl-case-26) 'Triangle)) (let ([base (hash-ref (adt-value-fields *tesl-case-26) 'base)]) (let ([height (hash-ref (adt-value-fields *tesl-case-26) 'height)]) (thsl-src! "tests/critical-review61-tests.tesl" 506 (list (cons 'base base) (cons 'height height)) (lambda () (raw-value "triangle")))))]))))))])))))

(define/pow
  (requiresBThenA [n : Integer ::: ((B n) && (A n))])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 533 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (testConjunctionOrder [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 536 (list (cons 'x *x)) (lambda () (let/check ([tesl-checked-27 (checkA x)]) (let ([a tesl-checked-27]) (let/check ([tesl-checked-28 (checkB a)]) (let ([b tesl-checked-28]) (raw-value (requiresBThenA b)))))))))

(define/pow
  (doubleIfPositive [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 551 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (mapPositives [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review61-tests.tesl" 554 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-29 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (doubleIfPositive n))) tesl-lambda-29) *xs)))))

(define-checker
  (checkXY [n : Integer])
  #:returns [n : Integer ::: ((X n) && (Y n))]
  (thsl-src! "tests/critical-review61-tests.tesl" 577 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept ((Y n) && (X n)) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkXYZ [n : Integer])
  #:returns [n : Integer ::: ((X n) && ((Y n) && (Z n)))]
  (thsl-src! "tests/critical-review61-tests.tesl" 583 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept ((Z n) && ((X n) && (Y n))) #:value *n) (reject "bad" #:http-code 400)))))

(define/pow
  (requiresXY [n : Integer ::: ((X n) && (Y n))])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 588 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (requiresXYZ [n : Integer ::: ((X n) && ((Y n) && (Z n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review61-tests.tesl" 589 (list (cons 'n *n)) (lambda () *n)))

(module+ test
  (require rackunit)
  (test-case "R61_CH01 6-check accumulation chain works end-to-end"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 197 (list) (lambda () (build6Chain 10))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 198 (list (cons 'r r)) (lambda () r))) 10)
    ))
  )

  (test-case "R61_CH02 7-check accumulation chain works end-to-end"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 202 (list) (lambda () (build7Chain 10))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 203 (list (cons 'r r)) (lambda () r))) 10)
    ))
  )

  (test-case "R61_CH03 6-check chain fails at step 1 if first check fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review61-tests.tesl" 207 (list) (lambda ()
                          ((build6Chain 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (build6Chain 0) (list)"))
    ))
  )

  (test-case "R61_CH04 6-check chain fails at step 3 if middle check fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review61-tests.tesl" 211 (list) (lambda ()
                          ((build6Chain 2) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (build6Chain 2) (list)"))
    ))
  )

  (test-case "R61_FA01 Set.filterCheck produces ForAll (IsPositive) \226\128\148 succeeds"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "tests/critical-review61-tests.tesl" 241 (list) (lambda () (tesl_import_Set_filterCheck checkPos (raw-value (tesl_import_Set_fromList (list 1 2 3 -1 0)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 242 (list (cons 's s)) (lambda () (raw-value (tesl_import_Set_size (raw-value s)))))) 3)
    ))
  )

  (test-case "R61_FA02 Dict.filterCheckValues produces ForAllValues (IsPositive)"
    (call-with-fresh-memory-db '() (lambda ()
  (define d (thsl-src! "tests/critical-review61-tests.tesl" 246 (list) (lambda () (raw-value (tesl_import_Dict_filterCheckValues checkPos (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 1) (Tuple2 "b" -1) (Tuple2 "c" 2)))))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 247 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value d)))))) 2)
    ))
  )

  (test-case "R61_FA03 List.allCheck with conjunction returns Something if all pass"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 251 (list) (lambda () (allSmall (list 1 2 3)))))
  (let ([*tesl-case-30 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl-case-30) (eq? (adt-value-variant *tesl-case-30) 'Nothing))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review61-tests.tesl" 253 (list) (lambda ()
                              ((+ 1 1) (list)))))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
    [(and (adt-value? *tesl-case-30) (eq? (adt-value-variant *tesl-case-30) 'Something))
      (let ([xs (hash-ref (adt-value-fields *tesl-case-30) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 254 (list) (lambda () (raw-value (tesl_import_List_length (raw-value xs)))))) 3)
      )
    ]
  ))
    ))
  )

  (test-case "R61_FA04 List.allCheck with conjunction returns Nothing if any fail"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 258 (list) (lambda () (allSmall (list 1 2 200)))))
  (let ([*tesl-case-31 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl-case-31) (eq? (adt-value-variant *tesl-case-31) 'Nothing))
      (check-equal? (thsl-src! "tests/critical-review61-tests.tesl" 260 (list) (lambda () 1)) 1)
    ]
    [(and (adt-value? *tesl-case-31) (eq? (adt-value-variant *tesl-case-31) 'Something))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review61-tests.tesl" 261 (list) (lambda ()
                              ((+ 1 1) (list)))))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
  ))
    ))
  )

  (test-case "R61_FA05 ForAll propagates through fn call chain (positives -> narrowToSmall)"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review61-tests.tesl" 265 (list) (lambda () (forAllPipeline (list 1 2 50 200 -1)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 266 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "R61_FA06 List.emptyForAll produces empty ForAll list"
    (call-with-fresh-memory-db '() (lambda ()
  (define empty (thsl-src! "tests/critical-review61-tests.tesl" 270 (list) (lambda () (tesl_import_List_emptyForAll checkPos))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 271 (list (cons 'empty empty)) (lambda () (raw-value (tesl_import_List_length (raw-value empty)))))) 0)
    ))
  )

  (test-case "R61_SF01 String.trim returns IsTrimmed proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 295 (list) (lambda () (trimAndUse "  hello  "))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 296 (list (cons 'r r)) (lambda () r))) "hello")
    ))
  )

  (test-case "R61_SF02 String.toUpper returns IsUpperCase proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 300 (list) (lambda () (upperAndUse "hello"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 301 (list (cons 'r r)) (lambda () r))) "HELLO")
    ))
  )

  (test-case "R61_SF03 List.sort returns IsSorted proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 305 (list) (lambda () (sortAndUse (list 3 1 2)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 306 (list (cons 'r r)) (lambda () (raw-value (tesl_import_List_length (raw-value r)))))) 3)
    ))
  )

  (test-case "R61_RC01 record with 3 proof-annotated fields: construction succeeds"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review61-tests.tesl" 326 (list) (lambda () (buildSafeTriple "hello" 5 3))))
  (check-equal? (thsl-src! "tests/critical-review61-tests.tesl" 327 (list (cons 'item item)) (lambda () (raw-value (tesl-dot/runtime item 'score)))) 3)
    ))
  )

  (test-case "R61_RC02 record with 3 proof-annotated fields: construction fails if count out of range"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review61-tests.tesl" 331 (list) (lambda ()
                          ((buildSafeTriple "hello" -1 3) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (buildSafeTriple \"hello\" -1 3) (list)"))
    ))
  )

  (test-case "R61_IM01 introAnd with 5 proofs + andLeft extracts first proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 364 (list) (lambda () (combine5Proofs 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 365 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R61_IM02 andLeft and andRight round-trip"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 369 (list) (lambda () (andLeftRightRoundTrip 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 370 (list (cons 'r r)) (lambda () r))) 10)
    ))
  )

  (test-case "R61_EM01 establish Maybe returns Something when proof holds"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 396 (list) (lambda () (tryUseRange 1 10 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 397 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R61_EM02 establish Maybe returns Nothing when proof doesn't hold"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 401 (list) (lambda () (tryUseRange 1 10 20))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 402 (list (cons 'r r)) (lambda () r))) -1)
    ))
  )

  (test-case "R61_MR01 mutual recursion with check: even 4 + odd 3 = 7"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 436 (list) (lambda () (testMutualRec 4 3))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 437 (list (cons 'r r)) (lambda () r))) 7)
    ))
  )

  (test-case "R61_MR02 mutual recursion: odd number fails checkEven"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review61-tests.tesl" 441 (list) (lambda ()
                          ((raw-value (checkOdd 2)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkOdd 2)) (list)"))
    ))
  )

  (test-case "R61_MR03 mutual recursion: even number fails checkOdd"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review61-tests.tesl" 445 (list) (lambda ()
                          ((raw-value (checkOdd 4)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkOdd 4)) (list)"))
    ))
  )

  (test-case "R61_DI01 Int.divide with IsNonZero proof succeeds"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 457 (list) (lambda () (safeDivide 10 2))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 458 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R61_DI02 Int.nonZero fails for zero denominator"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review61-tests.tesl" 462 (list) (lambda ()
                          ((safeDivide 10 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivide 10 0) (list)"))
    ))
  )

  (test-case "R61_FG01 forgetFact followed by re-check works"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 476 (list) (lambda () (forgetAndRe 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 477 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R61_NA01 nested ADT exhaustiveness: all constructors covered"
    (call-with-fresh-memory-db '() (lambda ()
  (define c (thsl-src! "tests/critical-review61-tests.tesl" 509 (list) (lambda () (raw-value (Filled (Circle 5) 3)))))
  (define desc (thsl-src! "tests/critical-review61-tests.tesl" 510 (list (cons 'c c)) (lambda () (describeContainer c))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 511 (list (cons 'desc desc) (cons 'c c)) (lambda () desc))) "circle")
    ))
  )

  (test-case "R61_NA02 nested ADT: Rectangle"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 515 (list) (lambda () (describeContainer (Filled (Rectangle 4 3) 1)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 516 (list (cons 'r r)) (lambda () r))) "rect")
    ))
  )

  (test-case "R61_NA03 nested ADT: Triangle"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 520 (list) (lambda () (describeContainer (Filled (Triangle 3 4) 2)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 521 (list (cons 'r r)) (lambda () r))) "triangle")
    ))
  )

  (test-case "R61_NA04 nested ADT: Empty container"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 525 (list) (lambda () (describeContainer Empty))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 526 (list (cons 'r r)) (lambda () r))) "empty")
    ))
  )

  (test-case "R61_PP01 call-site proof: B && A required, A && B carried \226\128\148 works (commutative)"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 541 (list) (lambda () (testConjunctionOrder 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 542 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R61_LM01 lambda with proof-annotated param works in List.map on ForAll list"
    (call-with-fresh-memory-db '() (lambda ()
  (define positives (thsl-src! "tests/critical-review61-tests.tesl" 557 (list) (lambda () (tesl_import_List_filterCheck checkPos (list 1 2 3)))))
  (define doubled (thsl-src! "tests/critical-review61-tests.tesl" 558 (list (cons 'positives positives)) (lambda () (mapPositives positives))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 559 (list (cons 'doubled doubled) (cons 'positives positives)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled)))))) 3)
    ))
  )

  (test-case "R61_LM02 direct filterCheck (no lambda) produces ForAll list"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review61-tests.tesl" 563 (list) (lambda () (tesl_import_List_filterCheck checkPos (list 1 -1 2 -2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 564 (list (cons 'r r)) (lambda () (raw-value (tesl_import_List_length (raw-value r)))))) 3)
    ))
  )

  (test-case "R61_CO01 ok conjunction order normalised: Y && X accepted for X && Y return"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review61-tests.tesl" 592 (list) (lambda () 5)))
  (define tesl-checked-32 (checkXY n))
  (when (check-fail? tesl-checked-32)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-32)))
  (define v tesl-checked-32)
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 594 (list (cons 'v v) (cons 'n n)) (lambda () (requiresXY v)))) 5)
    ))
  )

  (test-case "R61_CO02 ok conjunction order normalised: Z && X && Y accepted for X && Y && Z"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review61-tests.tesl" 598 (list) (lambda () 5)))
  (define tesl-checked-33 (checkXYZ n))
  (when (check-fail? tesl-checked-33)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-33)))
  (define v tesl-checked-33)
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 600 (list (cons 'v v) (cons 'n n)) (lambda () (requiresXYZ v)))) 5)
    ))
  )

  (test-case "R61_CO03 reversed-order check can be used in call-site with original order"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review61-tests.tesl" 604 (list) (lambda () 5)))
  (define tesl-checked-34 (checkXY n))
  (when (check-fail? tesl-checked-34)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-34)))
  (define v tesl-checked-34)
  (define tesl-checked-35 (checkXYZ n))
  (when (check-fail? tesl-checked-35)
    (raise-user-error 'tesl-test "unexpected failure in let w: ~a" (check-fail-message tesl-checked-35)))
  (define w tesl-checked-35)
  (check-equal? (raw-value (thsl-src! "tests/critical-review61-tests.tesl" 607 (list (cons 'w w) (cons 'v v) (cons 'n n)) (lambda () (+ (raw-value (requiresXY v)) (raw-value (requiresXYZ w)))))) 10)
    ))
  )

)
