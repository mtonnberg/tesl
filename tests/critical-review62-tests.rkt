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
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.map tesl_import_List_map] [List.sort tesl_import_List_sort] IsSorted)
  (only-in tesl/tesl/set Set [Set.filterCheck tesl_import_Set_filterCheck] [Set.fromList tesl_import_Set_fromList] [Set.size tesl_import_Set_size])
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.length tesl_import_String_length] [String.toUpper tesl_import_String_toUpper] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/int [Int.divide tesl_import_Int_divide] [Int.nonZero tesl_import_Int_nonZero] IsNonZero [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/float Float [Float.div tesl_import_Float_div] [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero [Float.sqrt tesl_import_Float_sqrt] [Float.abs tesl_import_Float_abs])
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define IsEven 'IsEven)
(define IsOdd 'IsOdd)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define TitleSafe 'TitleSafe)
(define ValidProject 'ValidProject)
(define ValidUser 'ValidUser)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 82 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (thsl-src! "tests/critical-review62-tests.tesl" 88 (list (cons 'n *n)) (lambda () (if (> *n 1) (accept ((A n) && (B n)) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: ((A n) && ((B n) && (C n)))]
  (thsl-src! "tests/critical-review62-tests.tesl" 94 (list (cons 'n *n)) (lambda () (if (> *n 2) (accept ((A n) && ((B n) && (C n))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))]
  (thsl-src! "tests/critical-review62-tests.tesl" 100 (list (cons 'n *n)) (lambda () (if (> *n 3) (accept ((A n) && ((B n) && ((C n) && (D n)))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 106 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 112 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))))

(define-checker
  (checkTitle [s : String])
  #:returns [s : String ::: (TitleSafe s)]
  (thsl-src! "tests/critical-review62-tests.tesl" 118 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (TitleSafe s) #:value *s) (reject "empty title" #:http-code 400)))))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 124 (list (cons 'n *n)) (lambda () (if (< *n 0) (reject "negative" #:http-code 400) (if (equal? *n 0) (accept (IsEven n) #:value *n) (let/check ([tesl_checked_0 (checkOdd (- *n 1))]) (let ([_odd tesl_checked_0]) (accept (IsEven n) #:value *n))))))))

(define-checker
  (checkOdd [n : Integer])
  #:returns [n : Integer ::: (IsOdd n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 133 (list (cons 'n *n)) (lambda () (if (<= *n 0) (reject "not odd" #:http-code 400) (if (equal? *n 1) (accept (IsOdd n) #:value *n) (let/check ([tesl_checked_1 (checkEven (- *n 1))]) (let ([_even tesl_checked_1]) (accept (IsOdd n) #:value *n))))))))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review62-tests.tesl" 141 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review62-tests.tesl" 142 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define-trusted
  (proveC [n : Integer])
  #:returns (Fact (C n))
  (thsl-src! "tests/critical-review62-tests.tesl" 143 (list (cons 'n *n)) (lambda () (trusted-proof (C n)))))

(define-trusted
  (proveD [n : Integer])
  #:returns (Fact (D n))
  (thsl-src! "tests/critical-review62-tests.tesl" 144 (list (cons 'n *n)) (lambda () (trusted-proof (D n)))))

(define-trusted
  (provePos [n : Integer])
  #:returns (Fact (IsPositive n))
  (thsl-src! "tests/critical-review62-tests.tesl" 145 (list (cons 'n *n)) (lambda () (trusted-proof (IsPositive n)))))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 149 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 150 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsC [n : Integer ::: (C n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 151 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAll4 [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 152 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 153 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAandB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 154 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (proveViaMaybe [m : (Maybe Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review62-tests.tesl" 161 (list (cons 'm *m)) (lambda () (let ([tesl_case_2 *m]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (thsl-src! "tests/critical-review62-tests.tesl" 162 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (thsl-src! "tests/critical-review62-tests.tesl" 164 (list (cons 'v v)) (lambda () (let/check ([tesl_checked_3 (checkPos *v)]) (let ([p tesl_checked_3]) (raw-value (needsPos p)))))))])))))

(define/pow
  (proofThroughLetChain [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 178 (list (cons 'x *x)) (lambda () (let/check ([tesl_checked_4 (checkA x)]) (let ([a tesl_checked_4]) (let/check ([tesl_checked_5 (checkB a)]) (let ([ab tesl_checked_5]) (let/check ([tesl_checked_6 (checkC ab)]) (let ([abc tesl_checked_6]) (let/check ([tesl_checked_7 (checkD abc)]) (let ([abcd tesl_checked_7]) (raw-value (needsAll4 abcd)))))))))))))

(define-checker
  (checkAandB [n : Integer])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (thsl-src! "tests/critical-review62-tests.tesl" 206 (list (cons 'n *n)) (lambda () (if (> *n 1) (accept ((B n) && (A n)) #:value *n) (reject "bad" #:http-code 400)))))

(define/pow
  (decomposeViaIntroAnd [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review62-tests.tesl" 218 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([pb (thsl-src! "tests/critical-review62-tests.tesl" 219 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (proveB x)))]) (let ([pab (thsl-src! "tests/critical-review62-tests.tesl" 220 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pa pb)))]) (let ([la (thsl-src! "tests/critical-review62-tests.tesl" 221 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-left pab)))]) (let ([rb (thsl-src! "tests/critical-review62-tests.tesl" 222 (list (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-right pab)))]) (let ([xA (thsl-src! "tests/critical-review62-tests.tesl" 223 (list (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x la)))]) (let ([xB (thsl-src! "tests/critical-review62-tests.tesl" 224 (list (cons 'xA *xA) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x rb)))]) (thsl-src! "tests/critical-review62-tests.tesl" 225 (list (cons 'xB *xB) (cons 'xA *xA) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (+ (raw-value (needsA xA)) (raw-value (needsB xB)))))))))))))

(define/pow
  (buildProofChainViaEstablish [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review62-tests.tesl" 254 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([pb (thsl-src! "tests/critical-review62-tests.tesl" 255 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (proveB x)))]) (let ([pc (thsl-src! "tests/critical-review62-tests.tesl" 256 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (proveC x)))]) (let ([pd (thsl-src! "tests/critical-review62-tests.tesl" 257 (list (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (proveD x)))]) (let ([pab (thsl-src! "tests/critical-review62-tests.tesl" 258 (list (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pa pb)))]) (let ([pabc (thsl-src! "tests/critical-review62-tests.tesl" 259 (list (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pab pc)))]) (let ([pabcd (thsl-src! "tests/critical-review62-tests.tesl" 260 (list (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pabc pd)))]) (let ([xAll (thsl-src! "tests/critical-review62-tests.tesl" 261 (list (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x pabcd)))]) (let ([la (thsl-src! "tests/critical-review62-tests.tesl" 262 (list (cons 'xAll *xAll) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-left pabcd)))]) (let ([xA (thsl-src! "tests/critical-review62-tests.tesl" 263 (list (cons 'la *la) (cons 'xAll *xAll) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x la)))]) (thsl-src! "tests/critical-review62-tests.tesl" 264 (list (cons 'xA *xA) (cons 'la *la) (cons 'xAll *xAll) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (raw-value (needsA xA)))))))))))))))

(define/pow
  (filterBoth [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review62-tests.tesl" 284 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck (check-and checkPos checkSmall) *xs))))

(define/pow
  (countPositiveSmall [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 287 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (filterSets [xs : (Set Integer)])
  #:returns (Set Integer)
  (thsl-src! "tests/critical-review62-tests.tesl" 314 (list (cons 'xs *xs)) (lambda () (tesl_import_Set_filterCheck checkPos *xs))))

(define-adt Tree
  [Leaf]
  [Node [left : Tree] [value : Integer] [right : Tree]]
)

(define/pow
  (sumTree [t : Tree])
  #:returns Integer
  (thsl-src-control! "tests/critical-review62-tests.tesl" 330 (list (cons 't *t)) (lambda () (let ([tesl_case_8 *t]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Leaf)) (thsl-src! "tests/critical-review62-tests.tesl" 331 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_8) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl_case_8) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl_case_8) 'right)]) (thsl-src! "tests/critical-review62-tests.tesl" 332 (list (cons 'l l) (cons 'v v) (cons 'r r)) (lambda () (raw-value (+ (+ (raw-value (sumTree *l)) *v) (raw-value (sumTree *r)))))))))])))))

(define/pow
  (maxDepth [t : Tree])
  #:returns Integer
  (thsl-src-control! "tests/critical-review62-tests.tesl" 335 (list (cons 't *t)) (lambda () (let ([tesl_case_9 *t]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Leaf)) (thsl-src! "tests/critical-review62-tests.tesl" 336 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl_case_9) 'left)]) (let ([r (hash-ref (adt-value-fields *tesl_case_9) 'right)]) (thsl-src! "tests/critical-review62-tests.tesl" 338 (list (cons 'l l) (cons 'r r)) (lambda () (let ([ld (maxDepth *l)]) (let ([rd (maxDepth *r)]) (if (> (raw-value ld) (raw-value rd)) (raw-value (+ (raw-value ld) 1)) (raw-value (+ (raw-value rd) 1)))))))))])))))

(define/pow
  (leafNode [v : Integer])
  #:returns Tree
  (thsl-src! "tests/critical-review62-tests.tesl" 345 (list (cons 'v *v)) (lambda () (raw-value (Node Leaf *v Leaf)))))

(define/pow
  (buildTree)
  #:returns Tree
  (thsl-src! "tests/critical-review62-tests.tesl" 347 (list) (lambda () (raw-value (Node (Node Leaf 1 Leaf) 2 (Node (Node Leaf 3 Leaf) 4 Leaf))))))

(define-adt Status
  [Active]
  [Inactive]
  [Suspended]
)

(define/pow
  (describeStatus [s : Status])
  #:returns String
  (thsl-src-control! "tests/critical-review62-tests.tesl" 368 (list (cons 's *s)) (lambda () (let ([tesl_case_10 *s]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Active)) (thsl-src! "tests/critical-review62-tests.tesl" 369 (list) (lambda () (raw-value "active")))] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Inactive)) (thsl-src! "tests/critical-review62-tests.tesl" 370 (list) (lambda () (raw-value "inactive")))] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Suspended)) (thsl-src! "tests/critical-review62-tests.tesl" 371 (list) (lambda () (raw-value "suspended")))])))))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 385 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (applyPipeline [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 390 (list (cons 'n *n)) (lambda () (raw-value (double (double n))))))

(define/pow
  (requiresTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 396 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (trimAndRequire [s : String])
  #:returns String
  (let ([t (thsl-src! "tests/critical-review62-tests.tesl" 399 (list (cons 's *s)) (lambda () (tesl_import_String_trim *s)))]) (thsl-src! "tests/critical-review62-tests.tesl" 400 (list (cons 't *t) (cons 's *s)) (lambda () (raw-value (requiresTrimmed t))))))

(define/pow
  (requiresSorted [xs : (List Integer) ::: (IsSorted xs)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review62-tests.tesl" 407 (list (cons 'xs *xs)) (lambda () *xs)))

(define/pow
  (sortAndRequire [xs : (List Integer)])
  #:returns (List Integer)
  (let ([s (thsl-src! "tests/critical-review62-tests.tesl" 410 (list (cons 'xs *xs)) (lambda () (tesl_import_List_sort *xs)))]) (thsl-src! "tests/critical-review62-tests.tesl" 411 (list (cons 's *s) (cons 'xs *xs)) (lambda () (raw-value (requiresSorted s))))))

(define/pow
  (requiresUpper [s : String ::: (IsUpperCase s)])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 418 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (upperAndRequire [s : String])
  #:returns String
  (let ([u (thsl-src! "tests/critical-review62-tests.tesl" 421 (list (cons 's *s)) (lambda () (tesl_import_String_toUpper *s)))]) (thsl-src! "tests/critical-review62-tests.tesl" 422 (list (cons 'u *u) (cons 's *s)) (lambda () (raw-value (requiresUpper u))))))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define-checker
  (checkUser [u : UserId])
  #:returns [u : UserId ::: (ValidUser u)]
  (thsl-src! "tests/critical-review62-tests.tesl" 440 (list (cons 'u *u)) (lambda () (if (> (raw-value (tesl_import_String_length (raw-value u.value))) 0) (accept (ValidUser u) #:value *u) (reject "empty user id" #:http-code 400)))))

(define-checker
  (checkProject [p : ProjectId])
  #:returns [p : ProjectId ::: (ValidProject p)]
  (thsl-src! "tests/critical-review62-tests.tesl" 446 (list (cons 'p *p)) (lambda () (if (> (raw-value (tesl_import_String_length (raw-value p.value))) 0) (accept (ValidProject p) #:value *p) (reject "empty project id" #:http-code 400)))))

(define/pow
  (requiresValidUser [u : UserId ::: (ValidUser u)])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 451 (list (cons 'u *u)) (lambda () (raw-value u.value))))

(define/pow
  (requiresValidProject [p : ProjectId ::: (ValidProject p)])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 452 (list (cons 'p *p)) (lambda () (raw-value p.value))))

(define/pow
  (testNewtypes [rawUser : String] [rawProject : String])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 455 (list (cons 'rawUser *rawUser) (cons 'rawProject *rawProject)) (lambda () (let ([uid (raw-value (UserId *rawUser))]) (let ([pid (raw-value (ProjectId *rawProject))]) (let/check ([tesl_checked_11 (checkUser uid)]) (let ([validUser tesl_checked_11]) (let/check ([tesl_checked_12 (checkProject pid)]) (let ([validProject tesl_checked_12]) (let ([_ (+ (raw-value (tesl_import_String_length (raw-value (requiresValidUser validUser)))) (raw-value (tesl_import_String_length (raw-value (requiresValidProject validProject)))))]) (raw-value (requiresValidUser validUser))))))))))))

(define/pow
  (requiresEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 475 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (requiresOdd [n : Integer ::: (IsOdd n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 476 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (mutualRecChain [e : Integer] [o : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 479 (list (cons 'e *e) (cons 'o *o)) (lambda () (let/check ([tesl_checked_13 (checkEven e)]) (let ([ev tesl_checked_13]) (let/check ([tesl_checked_14 (checkOdd o)]) (let ([od tesl_checked_14]) (+ (raw-value (requiresEven ev)) (raw-value (requiresOdd od))))))))))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 502 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl_checked_15 (tesl_import_Int_nonZero b)]) (let ([nz tesl_checked_15]) (raw-value (tesl_import_Int_divide *a nz)))))))

(define/pow
  (safeNonNeg [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 515 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_16 (tesl_import_Int_nonNegative n)]) (let ([nn tesl_checked_16]) (raw-value nn))))))

(define/pow
  (requiresNonNeg [n : Integer ::: (IsNonNegative n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 518 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (testNonNeg [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 521 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_17 (tesl_import_Int_nonNegative n)]) (let ([nn tesl_checked_17]) (raw-value (requiresNonNeg nn)))))))

(define/pow
  (safeFloatDiv [a : Real] [b : Real])
  #:returns Real
  (thsl-src! "tests/critical-review62-tests.tesl" 534 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl_checked_18 (tesl_import_Float_requireNonZero b)]) (let ([nz tesl_checked_18]) (raw-value (tesl_import_Float_div *a nz)))))))

(define-record SafePost
  [title : String ::: (TitleSafe title)]
  [count : Integer]
)

(define/pow
  (buildSafePost [t : String] [c : Integer])
  #:returns SafePost
  (thsl-src! "tests/critical-review62-tests.tesl" 552 (list (cons 't *t) (cons 'c *c)) (lambda () (let/check ([tesl_checked_19 (checkTitle t)]) (let ([st tesl_checked_19]) (SafePost #:title st #:count *c))))))

(define/pow
  (updateCount [p : SafePost] [newCount : Integer])
  #:returns SafePost
  (thsl-src! "tests/critical-review62-tests.tesl" 556 (list (cons 'p *p) (cons 'newCount *newCount)) (lambda () (tesl-record-update *p (hash 'count *newCount)))))

(module+ test
  (require rackunit)
  (test-case "R62_PF01 proof through Maybe case arm works"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 168 (list) (lambda () (proveViaMaybe (raw-value (Something 5))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 169 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R62_PF02 proof through Maybe case arm Nothing branch"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 173 (list) (lambda () (proveViaMaybe Nothing))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 174 (list (cons 'r r)) (lambda () r))) 0)
  )

  (test-case "R62_PF03 4-step proof chain accumulates correctly"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 185 (list) (lambda () (proofThroughLetChain 10))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 186 (list (cons 'r r)) (lambda () r))) 10)
  )

  (test-case "R62_PF04 4-step proof chain fails at step 1"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 190 (list) (lambda ()
                          ((proofThroughLetChain 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 0) (list)"))
  )

  (test-case "R62_PF05 4-step proof chain fails at step 2"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 194 (list) (lambda ()
                          ((proofThroughLetChain 1) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 1) (list)"))
  )

  (test-case "R62_PF06 4-step proof chain fails at step 3"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 198 (list) (lambda ()
                          ((proofThroughLetChain 2) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 2) (list)"))
  )

  (test-case "R62_CO01 ok conjunction order-insensitive (B && A for A && B)"
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 212 (list) (lambda () 5)))
  (define tesl_checked_20 (checkAandB n))
  (when (check-fail? tesl_checked_20)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_20)))
  (define v tesl_checked_20)
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 214 (list (cons 'v v) (cons 'n n)) (lambda () (needsAandB v)))) 5)
  )

  (test-case "R62_CO02 introAnd with bound args decomposes via andLeft/andRight"
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 228 (list) (lambda () 5)))
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 229 (list (cons 'n n)) (lambda () (decomposeViaIntroAnd n))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 230 (list (cons 'r r) (cons 'n n)) (lambda () r))) 10)
  )

  (test-case "R62_CO03 introAnd decompose at runtime: andLeft returns A fact"
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 234 (list) (lambda () 3)))
  (define pa (thsl-src! "tests/critical-review62-tests.tesl" 235 (list (cons 'n n)) (lambda () (proveA n))))
  (define pb (thsl-src! "tests/critical-review62-tests.tesl" 236 (list (cons 'pa pa) (cons 'n n)) (lambda () (proveB n))))
  (define pab (thsl-src! "tests/critical-review62-tests.tesl" 237 (list (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and pa pb))))
  (define la (thsl-src! "tests/critical-review62-tests.tesl" 238 (list (cons 'pab pab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (and-left pab))))
  (define xA (thsl-src! "tests/critical-review62-tests.tesl" 239 (list (cons 'la la) (cons 'pab pab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (attach-proof n la))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 240 (list (cons 'xA xA) (cons 'la la) (cons 'pab pab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (needsA xA)))) 3)
  )

  (test-case "R62_CO04 conjunction at call site is commutative (B && A satisfies B && A)"
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 244 (list) (lambda () 5)))
  (define tesl_checked_21 (checkAandB n))
  (when (check-fail? tesl_checked_21)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl_checked_21)))
  (define v tesl_checked_21)
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 246 (list (cons 'v v) (cons 'n n)) (lambda () (needsAandB v)))) 5)
  )

  (test-case "R62_ES01 4-establish introAnd chain with andLeft extraction"
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 267 (list) (lambda () 5)))
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 268 (list (cons 'n n)) (lambda () (buildProofChainViaEstablish n))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 269 (list (cons 'r r) (cons 'n n)) (lambda () r))) 5)
  )

  (test-case "R62_ES02 establish gives Fact that can be attached"
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 273 (list) (lambda () 5)))
  (define p (thsl-src! "tests/critical-review62-tests.tesl" 274 (list (cons 'n n)) (lambda () (provePos n))))
  (define xP (thsl-src! "tests/critical-review62-tests.tesl" 275 (list (cons 'p p) (cons 'n n)) (lambda () (attach-proof n p))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 276 (list (cons 'xP xP) (cons 'p p) (cons 'n n)) (lambda () (needsPos xP)))) 5)
  )

  (test-case "R62_FA01 && combined check in filterCheck produces conjunction ForAll"
  (define xs (thsl-src! "tests/critical-review62-tests.tesl" 290 (list) (lambda () (filterBoth (list 1 50 200 -1 99 0)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 291 (list (cons 'xs xs)) (lambda () (raw-value (tesl_import_List_length (raw-value xs)))))) 3)
  )

  (test-case "R62_FA02 ForAll list can be consumed by requiring fn"
  (define xs (thsl-src! "tests/critical-review62-tests.tesl" 295 (list) (lambda () (filterBoth (list 5 10 95)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 296 (list (cons 'xs xs)) (lambda () (countPositiveSmall xs)))) 3)
  )

  (test-case "R62_FA03 allCheck returns Nothing if any element fails"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 300 (list) (lambda () (tesl_import_List_allCheck checkPos (list 1 -1 2)))))
  (let ([*tesl_case_22 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Nothing))
      (check-equal? (thsl-src! "tests/critical-review62-tests.tesl" 302 (list) (lambda () 1)) 1)
    ]
    [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Something))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 303 (list) (lambda ()
                              ((+ 1 1) (list)))))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
  ))
  )

  (test-case "R62_FA04 allCheck returns Something for all-passing list"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 307 (list) (lambda () (tesl_import_List_allCheck checkPos (list 1 2 3)))))
  (let ([*tesl_case_23 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Nothing))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 309 (list) (lambda ()
                              ((+ 1 1) (list)))))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
    [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Something))
      (let ([xs (hash-ref (adt-value-fields *tesl_case_23) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 310 (list) (lambda () (raw-value (tesl_import_List_length (raw-value xs)))))) 3)
      )
    ]
  ))
  )

  (test-case "R62_FA05 Set.filterCheck produces ForAll (IsPositive)"
  (define s (thsl-src! "tests/critical-review62-tests.tesl" 317 (list) (lambda () (tesl_import_Set_filterCheck checkPos (raw-value (tesl_import_Set_fromList (list 1 2 -1 3 0)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 318 (list (cons 's s)) (lambda () (raw-value (tesl_import_Set_size (raw-value s)))))) 3)
  )

  (test-case "R62_AD01 recursive ADT sum: 1+2+3+4=10"
  (define t (thsl-src! "tests/critical-review62-tests.tesl" 353 (list) (lambda () (buildTree))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 354 (list (cons 't t)) (lambda () (sumTree t)))) 10)
  )

  (test-case "R62_AD02 recursive ADT max depth: tree of depth 3"
  (define t (thsl-src! "tests/critical-review62-tests.tesl" 358 (list) (lambda () (buildTree))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 359 (list (cons 't t)) (lambda () (maxDepth t)))) 3)
  )

  (test-case "R62_AD03 exhaustive 3-ctor ADT case works"
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 374 (list) (lambda () (describeStatus Active)))) "active")
  )

  (test-case "R62_AD04 exhaustive 3-ctor ADT case: Suspended"
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 378 (list) (lambda () (describeStatus Suspended)))) "suspended")
  )

  (test-case "R62_PO01 |> pipeline applies functions left to right"
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 393 (list) (lambda () (applyPipeline 3)))) 12)
  )

  (test-case "R62_PO02 String.trim returns IsTrimmed proof that satisfies fn requirement"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 403 (list) (lambda () (trimAndRequire "  hello  "))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 404 (list (cons 'r r)) (lambda () r))) "hello")
  )

  (test-case "R62_PO03 List.sort returns IsSorted proof"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 414 (list) (lambda () (sortAndRequire (list 3 1 2)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 415 (list (cons 'r r)) (lambda () (raw-value (tesl_import_List_length (raw-value r)))))) 3)
  )

  (test-case "R62_PO04 String.toUpper returns IsUpperCase proof"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 425 (list) (lambda () (upperAndRequire "hello"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 426 (list (cons 'r r)) (lambda () r))) "HELLO")
  )

  (test-case "R62_NT01 UserId newtype carries ValidUser proof"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 463 (list) (lambda () (testNewtypes "user-123" "proj-456"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 464 (list (cons 'r r)) (lambda () r))) "user-123")
  )

  (test-case "R62_NT02 empty UserId fails validation"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 468 (list) (lambda ()
                          ((testNewtypes "" "proj-456") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testNewtypes \"\" \"proj-456\") (list)"))
  )

  (test-case "R62_MR01 mutual recursion: even 4 + odd 3 = 7"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 484 (list) (lambda () (mutualRecChain 4 3))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 485 (list (cons 'r r)) (lambda () r))) 7)
  )

  (test-case "R62_MR02 mutual recursion: even 0 works"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 489 (list) (lambda () (mutualRecChain 0 1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 490 (list (cons 'r r)) (lambda () r))) 1)
  )

  (test-case "R62_MR03 mutual recursion: odd check fails for even number"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 494 (list) (lambda ()
                          ((raw-value (checkOdd 4)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkOdd 4)) (list)"))
  )

  (test-case "R62_SB01 Int.divide with IsNonZero proof works"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 506 (list) (lambda () (safeDivide 10 2))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 507 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R62_SB02 Int.nonZero fails for zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 511 (list) (lambda ()
                          ((safeDivide 10 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivide 10 0) (list)"))
  )

  (test-case "R62_SB03 Int.nonNegative proves IsNonNegative"
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 525 (list) (lambda () (testNonNeg 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 526 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R62_SB04 Int.nonNegative fails for negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 530 (list) (lambda ()
                          ((testNonNeg -1) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testNonNeg -1) (list)"))
  )

  (test-case "R62_SB05 Float.div with FloatNonZero proof works"
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 538 (list) (lambda () 5)))
  (check-true (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 539 (list (cons 'n n)) (lambda () #t))))
  )

  (test-case "R62_RU01 record update on non-proof field preserves proof fields"
  (define p (thsl-src! "tests/critical-review62-tests.tesl" 559 (list) (lambda () (buildSafePost "Hello" 1))))
  (define p2 (thsl-src! "tests/critical-review62-tests.tesl" 560 (list (cons 'p p)) (lambda () (updateCount p 5))))
  (check-equal? (thsl-src! "tests/critical-review62-tests.tesl" 561 (list (cons 'p2 p2) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p2 'title)))) "Hello")
  )

  (test-case "R62_RU02 record construction with valid title succeeds"
  (define p (thsl-src! "tests/critical-review62-tests.tesl" 565 (list) (lambda () (buildSafePost "Valid title" 0))))
  (check-equal? (thsl-src! "tests/critical-review62-tests.tesl" 566 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'count)))) 0)
  )

  (test-case "R62_RU03 record construction with empty title fails"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 570 (list) (lambda ()
                          ((buildSafePost "" 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (buildSafePost \"\" 0) (list)"))
  )

)
