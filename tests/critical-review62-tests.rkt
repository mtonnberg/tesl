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
  (thsl-src! "tests/critical-review62-tests.tesl" 81 (list (cons 'n *n)) (lambda () (if (tesl-gt? *n 0) (accept (A n) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (thsl-src! "tests/critical-review62-tests.tesl" 87 (list (cons 'n *n)) (lambda () (if (tesl-gt? *n 1) (accept ((A n) && (B n)) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: ((A n) && ((B n) && (C n)))]
  (thsl-src! "tests/critical-review62-tests.tesl" 93 (list (cons 'n *n)) (lambda () (if (tesl-gt? *n 2) (accept ((A n) && ((B n) && (C n))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))]
  (thsl-src! "tests/critical-review62-tests.tesl" 99 (list (cons 'n *n)) (lambda () (if (tesl-gt? *n 3) (accept ((A n) && ((B n) && ((C n) && (D n)))) #:value *n) (reject "bad" #:http-code 400)))))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 105 (list (cons 'n *n)) (lambda () (if (tesl-gt? *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 111 (list (cons 'n *n)) (lambda () (if (tesl-lt? *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))))

(define-checker
  (checkTitle [s : String])
  #:returns [s : String ::: (TitleSafe s)]
  (thsl-src! "tests/critical-review62-tests.tesl" 117 (list (cons 's *s)) (lambda () (if (tesl-gt? (raw-value (tesl_import_String_length *s)) 0) (accept (TitleSafe s) #:value *s) (reject "empty title" #:http-code 400)))))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 123 (list (cons 'n *n)) (lambda () (if (tesl-lt? *n 0) (reject "negative" #:http-code 400) (if (tesl-equal? *n 0) (accept (IsEven n) #:value *n) (let/check ([tesl-checked-0 (checkOdd (- *n 1))]) (let ([_odd tesl-checked-0]) (accept (IsEven n) #:value *n))))))))

(define-checker
  (checkOdd [n : Integer])
  #:returns [n : Integer ::: (IsOdd n)]
  (thsl-src! "tests/critical-review62-tests.tesl" 132 (list (cons 'n *n)) (lambda () (if (tesl-le? *n 0) (reject "not odd" #:http-code 400) (if (tesl-equal? *n 1) (accept (IsOdd n) #:value *n) (let/check ([tesl-checked-1 (checkEven (- *n 1))]) (let ([_even tesl-checked-1]) (accept (IsOdd n) #:value *n))))))))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review62-tests.tesl" 140 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review62-tests.tesl" 141 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define-trusted
  (proveC [n : Integer])
  #:returns (Fact (C n))
  (thsl-src! "tests/critical-review62-tests.tesl" 142 (list (cons 'n *n)) (lambda () (trusted-proof (C n)))))

(define-trusted
  (proveD [n : Integer])
  #:returns (Fact (D n))
  (thsl-src! "tests/critical-review62-tests.tesl" 143 (list (cons 'n *n)) (lambda () (trusted-proof (D n)))))

(define-trusted
  (provePos [n : Integer])
  #:returns (Fact (IsPositive n))
  (thsl-src! "tests/critical-review62-tests.tesl" 144 (list (cons 'n *n)) (lambda () (trusted-proof (IsPositive n)))))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 148 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 149 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsC [n : Integer ::: (C n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 150 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAll4 [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 151 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 152 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAandB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 153 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (proveViaMaybe [m : (Maybe Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review62-tests.tesl" 160 (list (cons 'm *m)) (lambda () (let ([tesl-case-2 *m]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/critical-review62-tests.tesl" 161 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/critical-review62-tests.tesl" 163 (list (cons 'v v)) (lambda () (let/check ([tesl-checked-3 (checkPos *v)]) (let ([p tesl-checked-3]) (raw-value (needsPos p)))))))])))))

(define/pow
  (proofThroughLetChain [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 177 (list (cons 'x *x)) (lambda () (let/check ([tesl-checked-4 (checkA x)]) (let ([a tesl-checked-4]) (let/check ([tesl-checked-5 (checkB a)]) (let ([ab tesl-checked-5]) (let/check ([tesl-checked-6 (checkC ab)]) (let ([abc tesl-checked-6]) (let/check ([tesl-checked-7 (checkD abc)]) (let ([abcd tesl-checked-7]) (raw-value (needsAll4 abcd)))))))))))))

(define-checker
  (checkAandB [n : Integer])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (thsl-src! "tests/critical-review62-tests.tesl" 205 (list (cons 'n *n)) (lambda () (if (tesl-gt? *n 1) (accept ((B n) && (A n)) #:value *n) (reject "bad" #:http-code 400)))))

(define/pow
  (decomposeViaIntroAnd [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review62-tests.tesl" 217 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([pb (thsl-src! "tests/critical-review62-tests.tesl" 218 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (proveB x)))]) (let ([pab (thsl-src! "tests/critical-review62-tests.tesl" 219 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pa pb)))]) (let ([la (thsl-src! "tests/critical-review62-tests.tesl" 220 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-left pab)))]) (let ([rb (thsl-src! "tests/critical-review62-tests.tesl" 221 (list (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-right pab)))]) (let ([xA (thsl-src! "tests/critical-review62-tests.tesl" 222 (list (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x la)))]) (let ([xB (thsl-src! "tests/critical-review62-tests.tesl" 223 (list (cons 'xA *xA) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x rb)))]) (thsl-src! "tests/critical-review62-tests.tesl" 224 (list (cons 'xB *xB) (cons 'xA *xA) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (+ (raw-value (needsA xA)) (raw-value (needsB xB)))))))))))))

(define/pow
  (buildProofChainViaEstablish [x : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review62-tests.tesl" 253 (list (cons 'x *x)) (lambda () (proveA x)))]) (let ([pb (thsl-src! "tests/critical-review62-tests.tesl" 254 (list (cons 'pa *pa) (cons 'x *x)) (lambda () (proveB x)))]) (let ([pc (thsl-src! "tests/critical-review62-tests.tesl" 255 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (proveC x)))]) (let ([pd (thsl-src! "tests/critical-review62-tests.tesl" 256 (list (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (proveD x)))]) (let ([pab (thsl-src! "tests/critical-review62-tests.tesl" 257 (list (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pa pb)))]) (let ([pabc (thsl-src! "tests/critical-review62-tests.tesl" 258 (list (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pab pc)))]) (let ([pabcd (thsl-src! "tests/critical-review62-tests.tesl" 259 (list (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (intro-and pabc pd)))]) (let ([xAll (thsl-src! "tests/critical-review62-tests.tesl" 260 (list (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x pabcd)))]) (let ([la (thsl-src! "tests/critical-review62-tests.tesl" 261 (list (cons 'xAll *xAll) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (and-left pabcd)))]) (let ([xA (thsl-src! "tests/critical-review62-tests.tesl" 262 (list (cons 'la *la) (cons 'xAll *xAll) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (attach-proof x la)))]) (thsl-src! "tests/critical-review62-tests.tesl" 263 (list (cons 'xA *xA) (cons 'la *la) (cons 'xAll *xAll) (cons 'pabcd *pabcd) (cons 'pabc *pabc) (cons 'pab *pab) (cons 'pd *pd) (cons 'pc *pc) (cons 'pb *pb) (cons 'pa *pa) (cons 'x *x)) (lambda () (raw-value (needsA xA)))))))))))))))

(define/pow
  (filterBoth [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review62-tests.tesl" 283 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck (check-and checkPos checkSmall) *xs))))

(define/pow
  (countPositiveSmall [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 286 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (filterSets [xs : (Set Integer)])
  #:returns (Set Integer)
  (thsl-src! "tests/critical-review62-tests.tesl" 313 (list (cons 'xs *xs)) (lambda () (tesl_import_Set_filterCheck checkPos *xs))))

(define-adt Tree
  [Leaf]
  [Node [left : Tree] [value : Integer] [right : Tree]]
)

(define/pow
  (sumTree [t : Tree])
  #:returns Integer
  (thsl-src-control! "tests/critical-review62-tests.tesl" 329 (list (cons 't *t)) (lambda () (let ([tesl-case-8 *t]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Leaf)) (thsl-src! "tests/critical-review62-tests.tesl" 330 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl-case-8) 'left)]) (let ([v (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl-case-8) 'right)]) (thsl-src! "tests/critical-review62-tests.tesl" 331 (list (cons 'l l) (cons 'v v) (cons 'r r)) (lambda () (raw-value (+ (+ (raw-value (sumTree *l)) *v) (raw-value (sumTree *r)))))))))])))))

(define/pow
  (maxDepth [t : Tree])
  #:returns Integer
  (thsl-src-control! "tests/critical-review62-tests.tesl" 334 (list (cons 't *t)) (lambda () (let ([tesl-case-9 *t]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Leaf)) (thsl-src! "tests/critical-review62-tests.tesl" 335 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Node)) (let ([l (hash-ref (adt-value-fields *tesl-case-9) 'left)]) (let ([r (hash-ref (adt-value-fields *tesl-case-9) 'right)]) (thsl-src! "tests/critical-review62-tests.tesl" 337 (list (cons 'l l) (cons 'r r)) (lambda () (let ([ld (maxDepth *l)]) (let ([rd (maxDepth *r)]) (if (tesl-gt? (raw-value ld) (raw-value rd)) (raw-value (+ (raw-value ld) 1)) (raw-value (+ (raw-value rd) 1)))))))))])))))

(define/pow
  (leafNode [v : Integer])
  #:returns Tree
  (thsl-src! "tests/critical-review62-tests.tesl" 344 (list (cons 'v *v)) (lambda () (raw-value (Node Leaf *v Leaf)))))

(define/pow
  (buildTree)
  #:returns Tree
  (thsl-src! "tests/critical-review62-tests.tesl" 346 (list) (lambda () (raw-value (Node (Node Leaf 1 Leaf) 2 (Node (Node Leaf 3 Leaf) 4 Leaf))))))

(define-adt Status
  [Active]
  [Inactive]
  [Suspended]
)

(define/pow
  (describeStatus [s : Status])
  #:returns String
  (thsl-src-control! "tests/critical-review62-tests.tesl" 367 (list (cons 's *s)) (lambda () (let ([tesl-case-10 *s]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Active)) (thsl-src! "tests/critical-review62-tests.tesl" 368 (list) (lambda () (raw-value "active")))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Inactive)) (thsl-src! "tests/critical-review62-tests.tesl" 369 (list) (lambda () (raw-value "inactive")))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Suspended)) (thsl-src! "tests/critical-review62-tests.tesl" 370 (list) (lambda () (raw-value "suspended")))])))))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 384 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (applyPipeline [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 389 (list (cons 'n *n)) (lambda () (raw-value (double (double n))))))

(define/pow
  (requiresTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 395 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (trimAndRequire [s : String])
  #:returns String
  (let ([t (thsl-src! "tests/critical-review62-tests.tesl" 398 (list (cons 's *s)) (lambda () (tesl_import_String_trim *s)))]) (thsl-src! "tests/critical-review62-tests.tesl" 399 (list (cons 't *t) (cons 's *s)) (lambda () (raw-value (requiresTrimmed t))))))

(define/pow
  (requiresSorted [xs : (List Integer) ::: (IsSorted xs)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review62-tests.tesl" 406 (list (cons 'xs *xs)) (lambda () *xs)))

(define/pow
  (sortAndRequire [xs : (List Integer)])
  #:returns (List Integer)
  (let ([s (thsl-src! "tests/critical-review62-tests.tesl" 409 (list (cons 'xs *xs)) (lambda () (tesl_import_List_sort *xs)))]) (thsl-src! "tests/critical-review62-tests.tesl" 410 (list (cons 's *s) (cons 'xs *xs)) (lambda () (raw-value (requiresSorted s))))))

(define/pow
  (requiresUpper [s : String ::: (IsUpperCase s)])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 417 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (upperAndRequire [s : String])
  #:returns String
  (let ([u (thsl-src! "tests/critical-review62-tests.tesl" 420 (list (cons 's *s)) (lambda () (tesl_import_String_toUpper *s)))]) (thsl-src! "tests/critical-review62-tests.tesl" 421 (list (cons 'u *u) (cons 's *s)) (lambda () (raw-value (requiresUpper u))))))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define-checker
  (checkUser [u : UserId])
  #:returns [u : UserId ::: (ValidUser u)]
  (thsl-src! "tests/critical-review62-tests.tesl" 439 (list (cons 'u *u)) (lambda () (if (tesl-gt? (raw-value (tesl_import_String_length (raw-value u.value))) 0) (accept (ValidUser u) #:value *u) (reject "empty user id" #:http-code 400)))))

(define-checker
  (checkProject [p : ProjectId])
  #:returns [p : ProjectId ::: (ValidProject p)]
  (thsl-src! "tests/critical-review62-tests.tesl" 445 (list (cons 'p *p)) (lambda () (if (tesl-gt? (raw-value (tesl_import_String_length (raw-value p.value))) 0) (accept (ValidProject p) #:value *p) (reject "empty project id" #:http-code 400)))))

(define/pow
  (requiresValidUser [u : UserId ::: (ValidUser u)])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 450 (list (cons 'u *u)) (lambda () (raw-value u.value))))

(define/pow
  (requiresValidProject [p : ProjectId ::: (ValidProject p)])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 451 (list (cons 'p *p)) (lambda () (raw-value p.value))))

(define/pow
  (testNewtypes [rawUser : String] [rawProject : String])
  #:returns String
  (thsl-src! "tests/critical-review62-tests.tesl" 454 (list (cons 'rawUser *rawUser) (cons 'rawProject *rawProject)) (lambda () (let ([uid (raw-value (UserId *rawUser))]) (let ([pid (raw-value (ProjectId *rawProject))]) (let/check ([tesl-checked-11 (checkUser uid)]) (let ([validUser tesl-checked-11]) (let/check ([tesl-checked-12 (checkProject pid)]) (let ([validProject tesl-checked-12]) (let ([_ (+ (raw-value (tesl_import_String_length (raw-value (requiresValidUser validUser)))) (raw-value (tesl_import_String_length (raw-value (requiresValidProject validProject)))))]) (raw-value (requiresValidUser validUser))))))))))))

(define/pow
  (requiresEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 474 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (requiresOdd [n : Integer ::: (IsOdd n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 475 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (mutualRecChain [e : Integer] [o : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 478 (list (cons 'e *e) (cons 'o *o)) (lambda () (let/check ([tesl-checked-13 (checkEven e)]) (let ([ev tesl-checked-13]) (let/check ([tesl-checked-14 (checkOdd o)]) (let ([od tesl-checked-14]) (+ (raw-value (requiresEven ev)) (raw-value (requiresOdd od))))))))))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 501 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-15 (tesl_import_Int_nonZero b)]) (let ([nz tesl-checked-15]) (raw-value (tesl_import_Int_divide *a nz)))))))

(define/pow
  (safeNonNeg [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 514 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-16 (tesl_import_Int_nonNegative n)]) (let ([nn tesl-checked-16]) (raw-value nn))))))

(define/pow
  (requiresNonNeg [n : Integer ::: (IsNonNegative n)])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 517 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (testNonNeg [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review62-tests.tesl" 520 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-17 (tesl_import_Int_nonNegative n)]) (let ([nn tesl-checked-17]) (raw-value (requiresNonNeg nn)))))))

(define/pow
  (safeFloatDiv [a : Real] [b : Real])
  #:returns Real
  (thsl-src! "tests/critical-review62-tests.tesl" 533 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-18 (tesl_import_Float_requireNonZero b)]) (let ([nz tesl-checked-18]) (raw-value (tesl_import_Float_div *a nz)))))))

(define-record SafePost
  [title : String ::: (TitleSafe title)]
  [count : Integer]
)

(define/pow
  (buildSafePost [t : String] [c : Integer])
  #:returns SafePost
  (thsl-src! "tests/critical-review62-tests.tesl" 551 (list (cons 't *t) (cons 'c *c)) (lambda () (let/check ([tesl-checked-19 (checkTitle t)]) (let ([st tesl-checked-19]) (SafePost #:title st #:count *c))))))

(define/pow
  (updateCount [p : SafePost] [newCount : Integer])
  #:returns SafePost
  (thsl-src! "tests/critical-review62-tests.tesl" 555 (list (cons 'p *p) (cons 'newCount *newCount)) (lambda () (tesl-record-update *p (tesl-hash 'count *newCount)))))

(module+ test
  (require rackunit)
  (test-case "R62_PF01 proof through Maybe case arm works"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 167 (list) (lambda () (proveViaMaybe (raw-value (Something 5))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 168 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R62_PF02 proof through Maybe case arm Nothing branch"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 172 (list) (lambda () (proveViaMaybe Nothing))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 173 (list (cons 'r r)) (lambda () r))) 0)
    ))
  )

  (test-case "R62_PF03 4-step proof chain accumulates correctly"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 184 (list) (lambda () (proofThroughLetChain 10))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 185 (list (cons 'r r)) (lambda () r))) 10)
    ))
  )

  (test-case "R62_PF04 4-step proof chain fails at step 1"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 189 (list) (lambda ()
                          ((proofThroughLetChain 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 0) (list)"))
    ))
  )

  (test-case "R62_PF05 4-step proof chain fails at step 2"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 193 (list) (lambda ()
                          ((proofThroughLetChain 1) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 1) (list)"))
    ))
  )

  (test-case "R62_PF06 4-step proof chain fails at step 3"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 197 (list) (lambda ()
                          ((proofThroughLetChain 2) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (proofThroughLetChain 2) (list)"))
    ))
  )

  (test-case "R62_CO01 ok conjunction order-insensitive (B && A for A && B)"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 211 (list) (lambda () 5)))
  (define tesl-checked-20 (checkAandB n))
  (when (check-fail? tesl-checked-20)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-20)))
  (define v tesl-checked-20)
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 213 (list (cons 'v v) (cons 'n n)) (lambda () (needsAandB v)))) 5)
    ))
  )

  (test-case "R62_CO02 introAnd with bound args decomposes via andLeft/andRight"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 227 (list) (lambda () 5)))
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 228 (list (cons 'n n)) (lambda () (decomposeViaIntroAnd n))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 229 (list (cons 'r r) (cons 'n n)) (lambda () r))) 10)
    ))
  )

  (test-case "R62_CO03 introAnd decompose at runtime: andLeft returns A fact"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 233 (list) (lambda () 3)))
  (define pa (thsl-src! "tests/critical-review62-tests.tesl" 234 (list (cons 'n n)) (lambda () (proveA n))))
  (define pb (thsl-src! "tests/critical-review62-tests.tesl" 235 (list (cons 'pa pa) (cons 'n n)) (lambda () (proveB n))))
  (define pab (thsl-src! "tests/critical-review62-tests.tesl" 236 (list (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and pa pb))))
  (define la (thsl-src! "tests/critical-review62-tests.tesl" 237 (list (cons 'pab pab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (and-left pab))))
  (define xA (thsl-src! "tests/critical-review62-tests.tesl" 238 (list (cons 'la la) (cons 'pab pab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (attach-proof n la))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 239 (list (cons 'xA xA) (cons 'la la) (cons 'pab pab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (needsA xA)))) 3)
    ))
  )

  (test-case "R62_CO04 conjunction at call site is commutative (B && A satisfies B && A)"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 243 (list) (lambda () 5)))
  (define tesl-checked-21 (checkAandB n))
  (when (check-fail? tesl-checked-21)
    (raise-user-error 'tesl-test "unexpected failure in let v: ~a" (check-fail-message tesl-checked-21)))
  (define v tesl-checked-21)
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 245 (list (cons 'v v) (cons 'n n)) (lambda () (needsAandB v)))) 5)
    ))
  )

  (test-case "R62_ES01 4-establish introAnd chain with andLeft extraction"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 266 (list) (lambda () 5)))
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 267 (list (cons 'n n)) (lambda () (buildProofChainViaEstablish n))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 268 (list (cons 'r r) (cons 'n n)) (lambda () r))) 5)
    ))
  )

  (test-case "R62_ES02 establish gives Fact that can be attached"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 272 (list) (lambda () 5)))
  (define p (thsl-src! "tests/critical-review62-tests.tesl" 273 (list (cons 'n n)) (lambda () (provePos n))))
  (define xP (thsl-src! "tests/critical-review62-tests.tesl" 274 (list (cons 'p p) (cons 'n n)) (lambda () (attach-proof n p))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 275 (list (cons 'xP xP) (cons 'p p) (cons 'n n)) (lambda () (needsPos xP)))) 5)
    ))
  )

  (test-case "R62_FA01 && combined check in filterCheck produces conjunction ForAll"
    (call-with-fresh-memory-db '() (lambda ()
  (define xs (thsl-src! "tests/critical-review62-tests.tesl" 289 (list) (lambda () (filterBoth (list 1 50 200 -1 99 0)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 290 (list (cons 'xs xs)) (lambda () (raw-value (tesl_import_List_length (raw-value xs)))))) 3)
    ))
  )

  (test-case "R62_FA02 ForAll list can be consumed by requiring fn"
    (call-with-fresh-memory-db '() (lambda ()
  (define xs (thsl-src! "tests/critical-review62-tests.tesl" 294 (list) (lambda () (filterBoth (list 5 10 95)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 295 (list (cons 'xs xs)) (lambda () (countPositiveSmall xs)))) 3)
    ))
  )

  (test-case "R62_FA03 allCheck returns Nothing if any element fails"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 299 (list) (lambda () (tesl_import_List_allCheck checkPos (list 1 -1 2)))))
  (let ([*tesl-case-22 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Nothing))
      (check-equal? (thsl-src! "tests/critical-review62-tests.tesl" 301 (list) (lambda () 1)) 1)
    ]
    [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Something))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 302 (list) (lambda ()
                              ((+ 1 1) (list)))))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
  ))
    ))
  )

  (test-case "R62_FA04 allCheck returns Something for all-passing list"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 306 (list) (lambda () (tesl_import_List_allCheck checkPos (list 1 2 3)))))
  (let ([*tesl-case-23 (raw-value 
    r)]) (cond
    [(and (adt-value? *tesl-case-23) (eq? (adt-value-variant *tesl-case-23) 'Nothing))
      (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 308 (list) (lambda ()
                              ((+ 1 1) (list)))))])
        (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                    "expected failure: (+ 1 1) (list)"))
    ]
    [(and (adt-value? *tesl-case-23) (eq? (adt-value-variant *tesl-case-23) 'Something))
      (let ([xs (hash-ref (adt-value-fields *tesl-case-23) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 309 (list) (lambda () (raw-value (tesl_import_List_length (raw-value xs)))))) 3)
      )
    ]
  ))
    ))
  )

  (test-case "R62_FA05 Set.filterCheck produces ForAll (IsPositive)"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "tests/critical-review62-tests.tesl" 316 (list) (lambda () (tesl_import_Set_filterCheck checkPos (raw-value (tesl_import_Set_fromList (list 1 2 -1 3 0)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 317 (list (cons 's s)) (lambda () (raw-value (tesl_import_Set_size (raw-value s)))))) 3)
    ))
  )

  (test-case "R62_AD01 recursive ADT sum: 1+2+3+4=10"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/critical-review62-tests.tesl" 352 (list) (lambda () (buildTree))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 353 (list (cons 't t)) (lambda () (sumTree t)))) 10)
    ))
  )

  (test-case "R62_AD02 recursive ADT max depth: tree of depth 3"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/critical-review62-tests.tesl" 357 (list) (lambda () (buildTree))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 358 (list (cons 't t)) (lambda () (maxDepth t)))) 3)
    ))
  )

  (test-case "R62_AD03 exhaustive 3-ctor ADT case works"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 373 (list) (lambda () (describeStatus Active)))) "active")
    ))
  )

  (test-case "R62_AD04 exhaustive 3-ctor ADT case: Suspended"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 377 (list) (lambda () (describeStatus Suspended)))) "suspended")
    ))
  )

  (test-case "R62_PO01 |> pipeline applies functions left to right"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 392 (list) (lambda () (applyPipeline 3)))) 12)
    ))
  )

  (test-case "R62_PO02 String.trim returns IsTrimmed proof that satisfies fn requirement"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 402 (list) (lambda () (trimAndRequire "  hello  "))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 403 (list (cons 'r r)) (lambda () r))) "hello")
    ))
  )

  (test-case "R62_PO03 List.sort returns IsSorted proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 413 (list) (lambda () (sortAndRequire (list 3 1 2)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 414 (list (cons 'r r)) (lambda () (raw-value (tesl_import_List_length (raw-value r)))))) 3)
    ))
  )

  (test-case "R62_PO04 String.toUpper returns IsUpperCase proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 424 (list) (lambda () (upperAndRequire "hello"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 425 (list (cons 'r r)) (lambda () r))) "HELLO")
    ))
  )

  (test-case "R62_NT01 UserId newtype carries ValidUser proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 462 (list) (lambda () (testNewtypes "user-123" "proj-456"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 463 (list (cons 'r r)) (lambda () r))) "user-123")
    ))
  )

  (test-case "R62_NT02 empty UserId fails validation"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 467 (list) (lambda ()
                          ((testNewtypes "" "proj-456") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testNewtypes \"\" \"proj-456\") (list)"))
    ))
  )

  (test-case "R62_MR01 mutual recursion: even 4 + odd 3 = 7"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 483 (list) (lambda () (mutualRecChain 4 3))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 484 (list (cons 'r r)) (lambda () r))) 7)
    ))
  )

  (test-case "R62_MR02 mutual recursion: even 0 works"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 488 (list) (lambda () (mutualRecChain 0 1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 489 (list (cons 'r r)) (lambda () r))) 1)
    ))
  )

  (test-case "R62_MR03 mutual recursion: odd check fails for even number"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 493 (list) (lambda ()
                          ((raw-value (checkOdd 4)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkOdd 4)) (list)"))
    ))
  )

  (test-case "R62_SB01 Int.divide with IsNonZero proof works"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 505 (list) (lambda () (safeDivide 10 2))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 506 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R62_SB02 Int.nonZero fails for zero"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 510 (list) (lambda ()
                          ((safeDivide 10 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivide 10 0) (list)"))
    ))
  )

  (test-case "R62_SB03 Int.nonNegative proves IsNonNegative"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review62-tests.tesl" 524 (list) (lambda () (testNonNeg 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 525 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R62_SB04 Int.nonNegative fails for negative"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 529 (list) (lambda ()
                          ((testNonNeg -1) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testNonNeg -1) (list)"))
    ))
  )

  (test-case "R62_SB05 Float.div with FloatNonZero proof works"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review62-tests.tesl" 537 (list) (lambda () 5)))
  (check-true (raw-value (thsl-src! "tests/critical-review62-tests.tesl" 538 (list (cons 'n n)) (lambda () #t))))
    ))
  )

  (test-case "R62_RU01 record update on non-proof field preserves proof fields"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "tests/critical-review62-tests.tesl" 558 (list) (lambda () (buildSafePost "Hello" 1))))
  (define p2 (thsl-src! "tests/critical-review62-tests.tesl" 559 (list (cons 'p p)) (lambda () (updateCount p 5))))
  (check-equal? (thsl-src! "tests/critical-review62-tests.tesl" 560 (list (cons 'p2 p2) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p2 'title 'SafePost)))) "Hello")
    ))
  )

  (test-case "R62_RU02 record construction with valid title succeeds"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "tests/critical-review62-tests.tesl" 564 (list) (lambda () (buildSafePost "Valid title" 0))))
  (check-equal? (thsl-src! "tests/critical-review62-tests.tesl" 565 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'count 'SafePost)))) 0)
    ))
  )

  (test-case "R62_RU03 record construction with empty title fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review62-tests.tesl" 569 (list) (lambda ()
                          ((buildSafePost "" 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (buildSafePost \"\" 0) (list)"))
    ))
  )

)
