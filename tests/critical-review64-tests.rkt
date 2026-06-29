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
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.sort tesl_import_List_sort] [List.emptyForAll tesl_import_List_emptyForAll] IsSorted)
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim] [String.toUpper tesl_import_String_toUpper] [String.length tesl_import_String_length] IsTrimmed IsUpperCase)
  (only-in tesl/tesl/int [Int.divide tesl_import_Int_divide] [Int.nonZero tesl_import_Int_nonZero] [Int.nonNegative tesl_import_Int_nonNegative] IsNonZero IsNonNegative)
  (only-in tesl/tesl/float Float [Float.div tesl_import_Float_div] [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero)
  (only-in tesl/tesl/dict Dict [Dict.fromList tesl_import_Dict_fromList] [Dict.filterCheckValues tesl_import_Dict_filterCheckValues] [Dict.size tesl_import_Dict_size] [Dict.requireKey tesl_import_Dict_requireKey] [Dict.get tesl_import_Dict_get] HasKey)
  (only-in tesl/tesl/tuple Tuple2)
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define HasMax 'HasMax)
(define HasMin 'HasMin)
(define InBounds 'InBounds)
(define IsActive 'IsActive)
(define IsPinned 'IsPinned)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define IsVerified 'IsVerified)
(define NonEmpty 'NonEmpty)
(define ValidProject 'ValidProject)
(define ValidUser 'ValidUser)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 96 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "a" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: ((A n) && (B n))]
  (thsl-src! "tests/critical-review64-tests.tesl" 102 (list (cons 'n *n)) (lambda () (if (> *n 1) (accept ((A n) && (B n)) #:value *n) (reject "b" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: ((A n) && ((B n) && (C n)))]
  (thsl-src! "tests/critical-review64-tests.tesl" 108 (list (cons 'n *n)) (lambda () (if (> *n 2) (accept ((A n) && ((B n) && (C n))) #:value *n) (reject "c" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))]
  (thsl-src! "tests/critical-review64-tests.tesl" 114 (list (cons 'n *n)) (lambda () (if (> *n 3) (accept ((A n) && ((B n) && ((C n) && (D n)))) #:value *n) (reject "d" #:http-code 400)))))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))]
  (thsl-src! "tests/critical-review64-tests.tesl" 120 (list (cons 'n *n)) (lambda () (if (> *n 4) (accept ((A n) && ((B n) && ((C n) && ((D n) && (E n))))) #:value *n) (reject "e" #:http-code 400)))))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 126 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 132 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))))

(define-checker
  (checkActive [n : Integer])
  #:returns [n : Integer ::: (IsActive n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 138 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsActive n) #:value *n) (reject "not active" #:http-code 400)))))

(define-checker
  (checkPinned [n : Integer])
  #:returns [n : Integer ::: (IsPinned n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 144 (list (cons 'n *n)) (lambda () (if (> *n 10) (accept (IsPinned n) #:value *n) (reject "not pinned" #:http-code 400)))))

(define-checker
  (checkVerified [n : Integer ::: ((IsActive n) && (IsPinned n))])
  #:returns [n : Integer ::: (IsVerified n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 150 (list (cons 'n *n)) (lambda () (if (> *n 50) (accept (IsVerified n) #:value *n) (reject "not verified" #:http-code 400)))))

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (NonEmpty s)]
  (thsl-src! "tests/critical-review64-tests.tesl" 156 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (NonEmpty s) #:value *s) (reject "empty" #:http-code 400)))))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review64-tests.tesl" 161 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review64-tests.tesl" 162 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define-trusted
  (proveC [n : Integer])
  #:returns (Fact (C n))
  (thsl-src! "tests/critical-review64-tests.tesl" 163 (list (cons 'n *n)) (lambda () (trusted-proof (C n)))))

(define-trusted
  (checkBounds [n : Integer])
  #:returns (Maybe (Fact (InBounds n)))
  (thsl-src! "tests/critical-review64-tests.tesl" 166 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 255)) (Something (trusted-proof (InBounds n))) Nothing))))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 171 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 172 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 173 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsABC [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 174 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAll5 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 175 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 176 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 177 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPosSmall [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 178 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsActive [n : Integer ::: (IsActive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 179 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsVerified [n : Integer ::: ((IsActive n) && ((IsPinned n) && (IsVerified n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 180 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsNonEmpty [s : String ::: (NonEmpty s)])
  #:returns String
  (thsl-src! "tests/critical-review64-tests.tesl" 181 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (needsSorted [xs : (List Integer) ::: (IsSorted xs)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 182 (list (cons 'xs *xs)) (lambda () *xs)))

(define/pow
  (needsTrimmed [s : String ::: (IsTrimmed s)])
  #:returns String
  (thsl-src! "tests/critical-review64-tests.tesl" 183 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (needsUpper [s : String ::: (IsUpperCase s)])
  #:returns String
  (thsl-src! "tests/critical-review64-tests.tesl" 184 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (needsInBounds [n : Integer ::: (InBounds n)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 185 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (fiveStepChain [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 192 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_0 (checkA n)]) (let ([a tesl_checked_0]) (let/check ([tesl_checked_1 (checkB a)]) (let ([b tesl_checked_1]) (let/check ([tesl_checked_2 (checkC b)]) (let ([c tesl_checked_2]) (let/check ([tesl_checked_3 (checkD c)]) (let ([d tesl_checked_3]) (let/check ([tesl_checked_4 (checkE d)]) (let ([e tesl_checked_4]) (raw-value (needsAll5 e)))))))))))))))

(define/pow
  (threeStepVerify [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 213 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_5 (checkActive n)]) (let ([a tesl_checked_5]) (let/check ([tesl_checked_6 (checkPinned a)]) (let ([p tesl_checked_6]) (let/check ([tesl_checked_7 (checkVerified p)]) (let ([v tesl_checked_7]) (raw-value (needsVerified v)))))))))))

(define/pow
  (threeWayDecomp [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 236 (list (cons 'n *n)) (lambda () (let ([tesl_proof_binding_8 n]) (let ([x (forget-proof tesl_proof_binding_8)] [pa (detach-all-proof tesl_proof_binding_8)]) (let ([tesl_proof_binding_9 n]) (let ([_ (forget-proof tesl_proof_binding_9)] [pb (detach-all-proof tesl_proof_binding_9)]) (let ([tesl_proof_binding_10 n]) (let ([_ (forget-proof tesl_proof_binding_10)] [pc (detach-all-proof tesl_proof_binding_10)]) x)))))))))

(define/pow
  (useFirstProof [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 252 (list (cons 'n *n)) (lambda () (let ([tesl_proof_binding_11 n]) (let ([x (forget-proof tesl_proof_binding_11)] [pa (detach-all-proof tesl_proof_binding_11)]) (raw-value (needsA (attach-proof x pa))))))))

(define/pow
  (keepProofOnly [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 267 (list (cons 'n *n)) (lambda () (let ([tesl_proof_binding_12 n]) (let ([_ (forget-proof tesl_proof_binding_12)] [pa (detach-all-proof tesl_proof_binding_12)]) (let ([bare (forget-proof n)]) (raw-value (needsA (attach-proof bare pa)))))))))

(define/pow
  (maybePositive [n : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 286 (list (cons 'n *n)) (lambda () (if (> *n 0) (let/check ([tesl_checked_13 (checkPos n)]) (let ([p tesl_checked_13]) (raw-value (Something p)))) Nothing))))

(define/pow
  (processIfPositive [n : Integer])
  #:returns Integer
  (let ([x (thsl-src! "tests/critical-review64-tests.tesl" 293 (list (cons 'n *n)) (lambda () (maybePositive n)))]) (thsl-src-control! "tests/critical-review64-tests.tesl" 294 (list (cons 'x *x) (cons 'n *n)) (lambda () (let ([tesl_case_14 (raw-value x)]) (cond [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Nothing)) (thsl-src! "tests/critical-review64-tests.tesl" 295 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_14) 'value)]) (thsl-src! "tests/critical-review64-tests.tesl" 296 (list (cons 'v v)) (lambda () (raw-value (needsPos v)))))]))))))

(define/pow
  (maybeSmallPos [n : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 309 (list (cons 'n *n)) (lambda () (if (and (> *n 0) (< *n 100)) (let/check ([tesl_checked_15 (checkPos n)]) (let ([p tesl_checked_15]) (let/check ([tesl_checked_16 (checkSmall p)]) (let ([s tesl_checked_16]) (raw-value (Something s)))))) Nothing))))

(define/pow
  (useSmallPos [n : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review64-tests.tesl" 317 (list (cons 'n *n)) (lambda () (let ([tesl_case_17 (raw-value (maybeSmallPos n))]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Nothing)) (thsl-src! "tests/critical-review64-tests.tesl" 318 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_17) 'value)]) (thsl-src! "tests/critical-review64-tests.tesl" 319 (list (cons 'v v)) (lambda () (raw-value (needsPosSmall v)))))])))))

(define-adt NumCategory
  [Small [value : Integer]]
  [Large [value : Integer]]
  [Zero]
)

(define/pow
  (processCategory [cat : NumCategory])
  #:returns Integer
  (thsl-src-control! "tests/critical-review64-tests.tesl" 341 (list (cons 'cat *cat)) (lambda () (let ([tesl_case_18 *cat]) (cond [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Zero)) (thsl-src! "tests/critical-review64-tests.tesl" 342 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Small)) (let ([n (hash-ref (adt-value-fields *tesl_case_18) 'value)]) (thsl-src! "tests/critical-review64-tests.tesl" 344 (list (cons 'n n)) (lambda () (let/check ([tesl_checked_19 (checkPos *n)]) (let ([p tesl_checked_19]) (raw-value (needsPos p)))))))] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Large)) (let ([n (hash-ref (adt-value-fields *tesl_case_18) 'value)]) (thsl-src! "tests/critical-review64-tests.tesl" 347 (list (cons 'n n)) (lambda () (let/check ([tesl_checked_20 (checkPos *n)]) (let ([p tesl_checked_20]) (raw-value (needsPos p)))))))])))))

(define-adt Priority
  [Critical]
  [High]
  [Medium]
  [Low]
  [None]
)

(define/pow
  (priorityScore [p : Priority])
  #:returns Integer
  (thsl-src-control! "tests/critical-review64-tests.tesl" 384 (list (cons 'p *p)) (lambda () (let ([tesl_case_21 *p]) (cond [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'Critical)) (thsl-src! "tests/critical-review64-tests.tesl" 385 (list) (lambda () (raw-value 100)))] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'High)) (thsl-src! "tests/critical-review64-tests.tesl" 387 (list) (lambda () (raw-value 50)))] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'Medium)) (thsl-src! "tests/critical-review64-tests.tesl" 387 (list) (lambda () (raw-value 50)))] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'Low)) (thsl-src! "tests/critical-review64-tests.tesl" 389 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'None)) (thsl-src! "tests/critical-review64-tests.tesl" 389 (list) (lambda () (raw-value 0)))])))))

(define/pow
  (filterPositiveValues [d : (Dict String Integer)])
  #:returns (Dict String Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 416 (list (cons 'd *d)) (lambda () (raw-value (tesl_import_Dict_filterCheckValues checkPos *d)))))

(define/pow
  (safeGet [key : String] [d : (Dict String Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 440 (list (cons 'key *key) (cons 'd *d)) (lambda () (let/check ([tesl_checked_22 (tesl_import_Dict_requireKey key d)]) (let ([checked tesl_checked_22]) (raw-value (tesl_import_Dict_get *key checked)))))))

(define/pow
  (trimThenUpper [raw : String])
  #:returns String
  (let ([trimmed (thsl-src! "tests/critical-review64-tests.tesl" 459 (list (cons 'raw *raw)) (lambda () (tesl_import_String_trim *raw)))]) (let ([upper (thsl-src! "tests/critical-review64-tests.tesl" 460 (list (cons 'trimmed *trimmed) (cons 'raw *raw)) (lambda () (tesl_import_String_toUpper (raw-value trimmed))))]) (thsl-src! "tests/critical-review64-tests.tesl" 461 (list (cons 'upper *upper) (cons 'trimmed *trimmed) (cons 'raw *raw)) (lambda () (raw-value (needsUpper upper)))))))

(define/pow
  (pipelineVersion [raw : String])
  #:returns String
  (thsl-src! "tests/critical-review64-tests.tesl" 470 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_String_toUpper (raw-value (tesl_import_String_trim *raw)))))))

(define/pow
  (sortAndGetLength [xs : (List Integer)])
  #:returns Integer
  (let ([sorted (thsl-src! "tests/critical-review64-tests.tesl" 479 (list (cons 'xs *xs)) (lambda () (tesl_import_List_sort *xs)))]) (let ([r (thsl-src! "tests/critical-review64-tests.tesl" 480 (list (cons 'sorted *sorted) (cons 'xs *xs)) (lambda () (needsSorted sorted)))]) (thsl-src! "tests/critical-review64-tests.tesl" 481 (list (cons 'r *r) (cons 'sorted *sorted) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length (raw-value r))))))))

(define/pow
  (safeProcess [n : Integer])
  #:returns Integer
  (let ([mProof (thsl-src! "tests/critical-review64-tests.tesl" 494 (list (cons 'n *n)) (lambda () (checkBounds n)))]) (thsl-src-control! "tests/critical-review64-tests.tesl" 495 (list (cons 'mProof *mProof) (cons 'n *n)) (lambda () (let ([tesl_case_23 (raw-value mProof)]) (cond [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Nothing)) (thsl-src! "tests/critical-review64-tests.tesl" 496 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl_case_23) 'value)]) (thsl-src! "tests/critical-review64-tests.tesl" 498 (list (cons 'p p)) (lambda () (let ([proven (attach-proof n *p)]) (raw-value (needsInBounds proven))))))]))))))

(define/pow
  (isEven [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review64-tests.tesl" 531 (list (cons 'n *n)) (lambda () (if (equal? *n 0) (raw-value #t) (raw-value (isOdd (- *n 1)))))))

(define/pow
  (isOdd [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review64-tests.tesl" 537 (list (cons 'n *n)) (lambda () (if (equal? *n 0) (raw-value #f) (raw-value (isEven (- *n 1)))))))

(define/pow
  (filterActive [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 567 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkActive *xs))))

(define/pow
  (filterActivePinned [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 570 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPinned *xs))))

(define/pow
  (filterActivePinnedVerified [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 574 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkVerified *xs))))

(define/pow
  (countVerified [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 577 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (threeLayerFilter [xs : (List Integer)])
  #:returns Integer
  (let ([active (thsl-src! "tests/critical-review64-tests.tesl" 580 (list (cons 'xs *xs)) (lambda () (filterActive xs)))]) (let ([pinned (thsl-src! "tests/critical-review64-tests.tesl" 581 (list (cons 'active *active) (cons 'xs *xs)) (lambda () (filterActivePinned active)))]) (let ([verified (thsl-src! "tests/critical-review64-tests.tesl" 582 (list (cons 'pinned *pinned) (cons 'active *active) (cons 'xs *xs)) (lambda () (filterActivePinnedVerified pinned)))]) (thsl-src! "tests/critical-review64-tests.tesl" 583 (list (cons 'verified *verified) (cons 'pinned *pinned) (cons 'active *active) (cons 'xs *xs)) (lambda () (raw-value (countVerified verified))))))))

(define/pow
  (processForAllList [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 602 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (buildVerifiedForAll)
  #:returns (List Integer)
  (let ([xs (thsl-src! "tests/critical-review64-tests.tesl" 605 (list) (lambda () (list 100 60 80 200 55)))]) (let ([active (thsl-src! "tests/critical-review64-tests.tesl" 606 (list (cons 'xs *xs)) (lambda () (filterActive xs)))]) (let ([pinned (thsl-src! "tests/critical-review64-tests.tesl" 607 (list (cons 'active *active) (cons 'xs *xs)) (lambda () (filterActivePinned active)))]) (thsl-src! "tests/critical-review64-tests.tesl" 608 (list (cons 'pinned *pinned) (cons 'active *active) (cons 'xs *xs)) (lambda () (filterActivePinnedVerified pinned)))))))

(define/pow
  (countPositive [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 617 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (decomposeViaAndLeft [n : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review64-tests.tesl" 706 (list (cons 'n *n)) (lambda () (proveA n)))]) (let ([pb (thsl-src! "tests/critical-review64-tests.tesl" 707 (list (cons 'pa *pa) (cons 'n *n)) (lambda () (proveB n)))]) (let ([pab (thsl-src! "tests/critical-review64-tests.tesl" 708 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (intro-and pa pb)))]) (let ([la (thsl-src! "tests/critical-review64-tests.tesl" 709 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (and-left pab)))]) (let ([xA (thsl-src! "tests/critical-review64-tests.tesl" 710 (list (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (attach-proof n la)))]) (thsl-src! "tests/critical-review64-tests.tesl" 711 (list (cons 'xA *xA) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (raw-value (needsA xA))))))))))

(define/pow
  (decomposeViaAndRight [n : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review64-tests.tesl" 719 (list (cons 'n *n)) (lambda () (proveA n)))]) (let ([pb (thsl-src! "tests/critical-review64-tests.tesl" 720 (list (cons 'pa *pa) (cons 'n *n)) (lambda () (proveB n)))]) (let ([pab (thsl-src! "tests/critical-review64-tests.tesl" 721 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (intro-and pa pb)))]) (let ([rb (thsl-src! "tests/critical-review64-tests.tesl" 722 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (and-right pab)))]) (let ([xB (thsl-src! "tests/critical-review64-tests.tesl" 723 (list (cons 'rb *rb) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (attach-proof n rb)))]) (thsl-src! "tests/critical-review64-tests.tesl" 724 (list (cons 'xB *xB) (cons 'rb *rb) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (raw-value (needsB xB))))))))))

(define/pow
  (useBothParts [n : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review64-tests.tesl" 732 (list (cons 'n *n)) (lambda () (proveA n)))]) (let ([pb (thsl-src! "tests/critical-review64-tests.tesl" 733 (list (cons 'pa *pa) (cons 'n *n)) (lambda () (proveB n)))]) (let ([pab (thsl-src! "tests/critical-review64-tests.tesl" 734 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (intro-and pa pb)))]) (let ([la (thsl-src! "tests/critical-review64-tests.tesl" 735 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (and-left pab)))]) (let ([rb (thsl-src! "tests/critical-review64-tests.tesl" 736 (list (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (and-right pab)))]) (let ([xA (thsl-src! "tests/critical-review64-tests.tesl" 737 (list (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (attach-proof n la)))]) (let ([xB (thsl-src! "tests/critical-review64-tests.tesl" 738 (list (cons 'xA *xA) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (attach-proof n rb)))]) (thsl-src! "tests/critical-review64-tests.tesl" 739 (list (cons 'xB *xB) (cons 'xA *xA) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (+ (raw-value (needsA xA)) (raw-value (needsB xB)))))))))))))

(define-record SafeDoc
  [title : String ::: (NonEmpty title)]
  [wordCount : Integer]
)

(define/pow
  (makeDoc [rawTitle : String] [wc : Integer])
  #:returns SafeDoc
  (thsl-src! "tests/critical-review64-tests.tesl" 782 (list (cons 'rawTitle *rawTitle) (cons 'wc *wc)) (lambda () (let/check ([tesl_checked_24 (checkNonEmpty rawTitle)]) (let ([t tesl_checked_24]) (SafeDoc #:title t #:wordCount *wc))))))

(define/pow
  (readTitle [doc : SafeDoc])
  #:returns String
  (thsl-src! "tests/critical-review64-tests.tesl" 786 (list (cons 'doc *doc)) (lambda () (raw-value (needsNonEmpty (tesl-dot/runtime doc 'title))))))

(define/pow
  (updateWordCount [doc : SafeDoc] [newCount : Integer])
  #:returns SafeDoc
  (thsl-src! "tests/critical-review64-tests.tesl" 801 (list (cons 'doc *doc) (cons 'newCount *newCount)) (lambda () (tesl-record-update *doc (hash 'wordCount *newCount)))))

(define/pow
  (readUpdatedTitle [rawTitle : String] [wc : Integer])
  #:returns String
  (let ([doc (thsl-src! "tests/critical-review64-tests.tesl" 804 (list (cons 'rawTitle *rawTitle) (cons 'wc *wc)) (lambda () (makeDoc rawTitle wc)))]) (let ([updated (thsl-src! "tests/critical-review64-tests.tesl" 805 (list (cons 'doc *doc) (cons 'rawTitle *rawTitle) (cons 'wc *wc)) (lambda () (updateWordCount doc 9999)))]) (thsl-src! "tests/critical-review64-tests.tesl" 806 (list (cons 'updated *updated) (cons 'doc *doc) (cons 'rawTitle *rawTitle) (cons 'wc *wc)) (lambda () (raw-value (readTitle updated)))))))

(define/pow
  (applyCombined [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 819 (list (cons 'n *n)) (lambda () (let/check ([tesl_checked_25 ((check-and checkPos checkSmall) n)]) (let ([r tesl_checked_25]) (raw-value (needsPosSmall r)))))))

(define/pow
  (filterActivePinnedDirect [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 836 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck (check-and checkActive checkPinned) *xs))))

(define-checker
  (checkMin10 [n : Integer])
  #:returns [n : Integer ::: (HasMin 10 n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 857 (list (cons 'n *n)) (lambda () (if (>= *n 10) (accept (HasMin 10 n) #:value *n) (reject "too small" #:http-code 400)))))

(define-checker
  (checkMin20 [n : Integer])
  #:returns [n : Integer ::: (HasMin 20 n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 863 (list (cons 'n *n)) (lambda () (if (>= *n 20) (accept (HasMin 20 n) #:value *n) (reject "too small" #:http-code 400)))))

(define-checker
  (checkMax100 [n : Integer])
  #:returns [n : Integer ::: (HasMax 100 n)]
  (thsl-src! "tests/critical-review64-tests.tesl" 869 (list (cons 'n *n)) (lambda () (if (<= *n 100) (accept (HasMax 100 n) #:value *n) (reject "too big" #:http-code 400)))))

(define/pow
  (needAbove10 [n : Integer ::: (HasMin 10 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 874 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needAbove20 [n : Integer ::: (HasMin 20 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 875 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needBothBounds [n : Integer ::: ((HasMin 10 n) && (HasMax 100 n))])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 876 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needForAllAbove10 [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 879 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (needForAllAbove20 [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review64-tests.tesl" 882 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (filterAbove10 [raw : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 885 (list (cons 'raw *raw)) (lambda () (tesl_import_List_filterCheck checkMin10 *raw))))

(define/pow
  (filterAbove20 [raw : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review64-tests.tesl" 888 (list (cons 'raw *raw)) (lambda () (tesl_import_List_filterCheck checkMin20 *raw))))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define-checker
  (checkUser [u : UserId])
  #:returns [u : UserId ::: (ValidUser u)]
  (thsl-src! "tests/critical-review64-tests.tesl" 961 (list (cons 'u *u)) (lambda () (if (> (raw-value (tesl_import_String_length (raw-value u.value))) 0) (accept (ValidUser u) #:value *u) (reject "empty user id" #:http-code 400)))))

(define-checker
  (checkProject [p : ProjectId])
  #:returns [p : ProjectId ::: (ValidProject p)]
  (thsl-src! "tests/critical-review64-tests.tesl" 967 (list (cons 'p *p)) (lambda () (if (> (raw-value (tesl_import_String_length (raw-value p.value))) 0) (accept (ValidProject p) #:value *p) (reject "empty project id" #:http-code 400)))))

(define/pow
  (needsValidUser [u : UserId ::: (ValidUser u)])
  #:returns String
  (thsl-src! "tests/critical-review64-tests.tesl" 972 (list (cons 'u *u)) (lambda () (raw-value u.value))))

(define/pow
  (needsValidProject [p : ProjectId ::: (ValidProject p)])
  #:returns String
  (thsl-src! "tests/critical-review64-tests.tesl" 973 (list (cons 'p *p)) (lambda () (raw-value p.value))))

(module+ test
  (require rackunit)
  (test-case "R64_DC01 5-step sequential check chain with accumulating proofs"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 200 (list) (lambda () (fiveStepChain 10))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 201 (list (cons 'r r)) (lambda () r))) 10)
  )

  (test-case "R64_DC02 5-step chain: failure at step 3 (n <= 2) propagates"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 205 (list) (lambda ()
                          ((fiveStepChain 2) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (fiveStepChain 2) (list)"))
  )

  (test-case "R64_DC03 5-step chain: failure at step 1 (n <= 0) propagates"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 209 (list) (lambda ()
                          ((fiveStepChain 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (fiveStepChain 0) (list)"))
  )

  (test-case "R64_DC04 3-step check with 3-proof conjunction requirement"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 219 (list) (lambda () (threeStepVerify 100))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 220 (list (cons 'r r)) (lambda () r))) 100)
  )

  (test-case "R64_DC05 3-step chain: fails at pinned threshold (n <= 10)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 224 (list) (lambda ()
                          ((threeStepVerify 5) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (threeStepVerify 5) (list)"))
  )

  (test-case "R64_DC06 3-step chain: fails at verified threshold (n <= 50)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 228 (list) (lambda ()
                          ((threeStepVerify 25) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (threeStepVerify 25) (list)"))
  )

  (test-case "R64_DX01 3-way conjunction decomposition preserves value"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 240 (list) (lambda () 42)))
  (define pa (thsl-src! "tests/critical-review64-tests.tesl" 241 (list (cons 'n n)) (lambda () (proveA n))))
  (define pb (thsl-src! "tests/critical-review64-tests.tesl" 242 (list (cons 'pa pa) (cons 'n n)) (lambda () (proveB n))))
  (define pc (thsl-src! "tests/critical-review64-tests.tesl" 243 (list (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (proveC n))))
  (define ab (thsl-src! "tests/critical-review64-tests.tesl" 244 (list (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and pa pb))))
  (define abc (thsl-src! "tests/critical-review64-tests.tesl" 245 (list (cons 'ab ab) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and ab pc))))
  (define withProof (thsl-src! "tests/critical-review64-tests.tesl" 246 (list (cons 'abc abc) (cons 'ab ab) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (attach-proof n abc))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 247 (list (cons 'withProof withProof) (cons 'abc abc) (cons 'ab ab) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (threeWayDecomp withProof))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 248 (list (cons 'r r) (cons 'withProof withProof) (cons 'abc abc) (cons 'ab ab) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () r))) 42)
  )

  (test-case "R64_DX02 3-way decomposition: use first proof, discard rest"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 256 (list) (lambda () 7)))
  (define pa (thsl-src! "tests/critical-review64-tests.tesl" 257 (list (cons 'n n)) (lambda () (proveA n))))
  (define pb (thsl-src! "tests/critical-review64-tests.tesl" 258 (list (cons 'pa pa) (cons 'n n)) (lambda () (proveB n))))
  (define pc (thsl-src! "tests/critical-review64-tests.tesl" 259 (list (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (proveC n))))
  (define abc (thsl-src! "tests/critical-review64-tests.tesl" 260 (list (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and (intro-and pa pb) pc))))
  (define withProof (thsl-src! "tests/critical-review64-tests.tesl" 261 (list (cons 'abc abc) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (attach-proof n abc))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 262 (list (cons 'withProof withProof) (cons 'abc abc) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (useFirstProof withProof))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 263 (list (cons 'r r) (cons 'withProof withProof) (cons 'abc abc) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () r))) 7)
  )

  (test-case "R64_DX03 decompose with _ on value slot, keep proof"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 272 (list) (lambda () 99)))
  (define pa (thsl-src! "tests/critical-review64-tests.tesl" 273 (list (cons 'n n)) (lambda () (proveA n))))
  (define pb (thsl-src! "tests/critical-review64-tests.tesl" 274 (list (cons 'pa pa) (cons 'n n)) (lambda () (proveB n))))
  (define ab (thsl-src! "tests/critical-review64-tests.tesl" 275 (list (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and pa pb))))
  (define withProof (thsl-src! "tests/critical-review64-tests.tesl" 276 (list (cons 'ab ab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (attach-proof n ab))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 277 (list (cons 'withProof withProof) (cons 'ab ab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (keepProofOnly withProof))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 278 (list (cons 'r r) (cons 'withProof withProof) (cons 'ab ab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () r))) 99)
  )

  (test-case "R64_MF01 Maybe proof return - Something arm propagates proof correctly"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 299 (list) (lambda () (processIfPositive 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 300 (list (cons 'r r)) (lambda () r))) 5)
  )

  (test-case "R64_MF02 Maybe proof return - Nothing arm works without proof"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 304 (list) (lambda () (processIfPositive -3))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 305 (list (cons 'r r)) (lambda () r))) -1)
  )

  (test-case "R64_MF03 Maybe with conjunction proof - both proofs flow through case arm"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 322 (list) (lambda () (useSmallPos 42))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 323 (list (cons 'r r)) (lambda () r))) 42)
  )

  (test-case "R64_MF04 Maybe with conjunction proof - out-of-range input returns Nothing"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 327 (list) (lambda () (useSmallPos 200))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 328 (list (cons 'r r)) (lambda () r))) 0)
  )

  (test-case "R64_CS01 proof produced in case arm - small variant"
  (define cat (thsl-src! "tests/critical-review64-tests.tesl" 351 (list) (lambda () (raw-value (Small 5)))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 352 (list (cons 'cat cat)) (lambda () (processCategory cat))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 353 (list (cons 'r r) (cons 'cat cat)) (lambda () r))) 5)
  )

  (test-case "R64_CS02 proof produced in case arm - large variant"
  (define cat (thsl-src! "tests/critical-review64-tests.tesl" 357 (list) (lambda () (raw-value (Large 500)))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 358 (list (cons 'cat cat)) (lambda () (processCategory cat))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 359 (list (cons 'r r) (cons 'cat cat)) (lambda () r))) 500)
  )

  (test-case "R64_CS03 case arm with no proof - zero returns directly"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 363 (list) (lambda () (processCategory Zero))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 364 (list (cons 'r r)) (lambda () r))) 0)
  )

  (test-case "R64_CS04 proof check failure inside case arm"
  (define cat (thsl-src! "tests/critical-review64-tests.tesl" 368 (list) (lambda () (raw-value (Small 0)))))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 369 (list (cons 'cat cat)) (lambda ()
                          ((processCategory cat) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (processCategory cat) (list)"))
  )

  (test-case "R64_AS01 fallthrough - Critical returns 100"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 392 (list) (lambda () (priorityScore Critical)))) 100)
  )

  (test-case "R64_AS02 fallthrough - High falls through to Medium result (50)"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 396 (list) (lambda () (priorityScore High)))) 50)
  )

  (test-case "R64_AS03 fallthrough - Medium returns 50 directly"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 400 (list) (lambda () (priorityScore Medium)))) 50)
  )

  (test-case "R64_AS04 fallthrough - Low falls through to None result (0)"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 404 (list) (lambda () (priorityScore Low)))) 0)
  )

  (test-case "R64_AS05 fallthrough - None returns 0 directly"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 408 (list) (lambda () (priorityScore None)))) 0)
  )

  (test-case "R64_DP01 Dict.filterCheckValues: keeps only positive values"
  (define d (thsl-src! "tests/critical-review64-tests.tesl" 419 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 5) (Tuple2 "b" -1) (Tuple2 "c" 10) (Tuple2 "d" -3)))))))
  (define filtered (thsl-src! "tests/critical-review64-tests.tesl" 420 (list (cons 'd d)) (lambda () (filterPositiveValues d))))
  (define sz (thsl-src! "tests/critical-review64-tests.tesl" 421 (list (cons 'filtered filtered) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value filtered))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 422 (list (cons 'sz sz) (cons 'filtered filtered) (cons 'd d)) (lambda () sz))) 2)
  )

  (test-case "R64_DP02 Dict.filterCheckValues: all-positive dict unchanged size"
  (define d (thsl-src! "tests/critical-review64-tests.tesl" 426 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "x" 1) (Tuple2 "y" 2) (Tuple2 "z" 3)))))))
  (define filtered (thsl-src! "tests/critical-review64-tests.tesl" 427 (list (cons 'd d)) (lambda () (filterPositiveValues d))))
  (define sz (thsl-src! "tests/critical-review64-tests.tesl" 428 (list (cons 'filtered filtered) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value filtered))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 429 (list (cons 'sz sz) (cons 'filtered filtered) (cons 'd d)) (lambda () sz))) 3)
  )

  (test-case "R64_DP03 Dict.filterCheckValues: all-negative dict gives empty"
  (define d (thsl-src! "tests/critical-review64-tests.tesl" 433 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "x" -1) (Tuple2 "y" -2)))))))
  (define filtered (thsl-src! "tests/critical-review64-tests.tesl" 434 (list (cons 'd d)) (lambda () (filterPositiveValues d))))
  (define sz (thsl-src! "tests/critical-review64-tests.tesl" 435 (list (cons 'filtered filtered) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value filtered))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 436 (list (cons 'sz sz) (cons 'filtered filtered) (cons 'd d)) (lambda () sz))) 0)
  )

  (test-case "R64_DP04 Dict.requireKey + Dict.get round-trip succeeds for present key"
  (define d (thsl-src! "tests/critical-review64-tests.tesl" 444 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "hello" 42)))))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 445 (list (cons 'd d)) (lambda () (safeGet "hello" d))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 446 (list (cons 'r r) (cons 'd d)) (lambda () r))) 42)
  )

  (test-case "R64_DP05 Dict.requireKey fails for missing key"
  (define d (thsl-src! "tests/critical-review64-tests.tesl" 450 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "other" 99)))))))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 451 (list (cons 'd d)) (lambda ()
                          ((safeGet "hello" d) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeGet \"hello\" d) (list)"))
  )

  (test-case "R64_PP01 stdlib proof chain: trim then toUpper proofs compose"
  (define raw (thsl-src! "tests/critical-review64-tests.tesl" 464 (list) (lambda () "  hello world  ")))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 465 (list (cons 'raw raw)) (lambda () (trimThenUpper raw))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 466 (list (cons 'r r) (cons 'raw raw)) (lambda () r))) "HELLO WORLD")
  )

  (test-case "R64_PP02 same stdlib chain via |> pipeline operator"
  (define raw (thsl-src! "tests/critical-review64-tests.tesl" 473 (list) (lambda () "  test  ")))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 474 (list (cons 'raw raw)) (lambda () (pipelineVersion raw))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 475 (list (cons 'r r) (cons 'raw raw)) (lambda () r))) "TEST")
  )

  (test-case "R64_PP03 List.sort produces IsSorted proof usable by consumer"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 484 (list) (lambda () (list 3 1 4 1 5 9 2 6))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 485 (list (cons 'xs xs)) (lambda () (sortAndGetLength xs))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 486 (list (cons 'r r) (cons 'xs xs)) (lambda () r))) 8)
  )

  (test-case "R64_EP01 establish returning Maybe(Fact) - value in bounds"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 502 (list) (lambda () (safeProcess 128))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 503 (list (cons 'r r)) (lambda () r))) 128)
  )

  (test-case "R64_EP02 establish returning Maybe(Fact) - value out of bounds"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 507 (list) (lambda () (safeProcess 300))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 508 (list (cons 'r r)) (lambda () r))) -1)
  )

  (test-case "R64_EP03 establish returning Maybe(Fact) - lower boundary value 0"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 512 (list) (lambda () (safeProcess 0))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 513 (list (cons 'r r)) (lambda () r))) 0)
  )

  (test-case "R64_EP04 establish returning Maybe(Fact) - upper boundary value 255"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 517 (list) (lambda () (safeProcess 255))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 518 (list (cons 'r r)) (lambda () r))) 255)
  )

  (test-case "R64_EP05 establish returning Maybe(Fact) - negative value is out of bounds"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 522 (list) (lambda () (safeProcess -1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 523 (list (cons 'r r)) (lambda () r))) -1)
  )

  (test-case "R64_MR01 mutual recursion - isEven 0 is True"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 543 (list) (lambda () (isEven 0)))) #t)
  )

  (test-case "R64_MR02 mutual recursion - isOdd 1 is True"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 547 (list) (lambda () (isOdd 1)))) #t)
  )

  (test-case "R64_MR03 mutual recursion - isEven 10 is True"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 551 (list) (lambda () (isEven 10)))) #t)
  )

  (test-case "R64_MR04 mutual recursion - isOdd 7 is True"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 555 (list) (lambda () (isOdd 7)))) #t)
  )

  (test-case "R64_MR05 mutual recursion - isEven 3 is False"
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 559 (list) (lambda () (isEven 3)))) #f)
  )

  (test-case "R64_FA01 3-level ForAll filter chain: correct count"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 587 (list) (lambda () (list 100 60 5 80 15 200 2 55))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 588 (list (cons 'xs xs)) (lambda () (threeLayerFilter xs))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 592 (list (cons 'r r) (cons 'xs xs)) (lambda () r))) 5)
  )

  (test-case "R64_FA02 3-level ForAll chain with empty input gives 0"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 596 (list) (lambda () (list))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 597 (list (cons 'xs xs)) (lambda () (threeLayerFilter xs))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 598 (list (cons 'r r) (cons 'xs xs)) (lambda () r))) 0)
  )

  (test-case "R64_FA03 ForAll list built from 3-level filter usable as proof parameter"
  (define verified (thsl-src! "tests/critical-review64-tests.tesl" 611 (list) (lambda () (buildVerifiedForAll))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 612 (list (cons 'verified verified)) (lambda () (processForAllList verified))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 613 (list (cons 'r r) (cons 'verified verified)) (lambda () r))) 5)
  )

  (test-case "R64_FA04 List.emptyForAll produces valid empty ForAll list for use as parameter"
  (define empty (thsl-src! "tests/critical-review64-tests.tesl" 620 (list) (lambda () (tesl_import_List_emptyForAll checkPos))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 621 (list (cons 'empty empty)) (lambda () (countPositive empty))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 622 (list (cons 'r r) (cons 'empty empty)) (lambda () r))) 0)
  )

  (test-case "R64_FA05 List.allCheck returns Nothing when any element fails"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 626 (list) (lambda () (list 1 2 0 4))))
  (define result (thsl-src! "tests/critical-review64-tests.tesl" 627 (list (cons 'xs xs)) (lambda () (tesl_import_List_allCheck checkPos (raw-value xs)))))
  (let ([*tesl_case_26 (raw-value 
    result)]) (cond
    [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Nothing))
      (check-equal? (thsl-src! "tests/critical-review64-tests.tesl" 629 (list) (lambda () 1)) 1)
    ]
    [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Something))
      (check-equal? (thsl-src! "tests/critical-review64-tests.tesl" 630 (list) (lambda () 0)) 1)
    ]
  ))
  )

  (test-case "R64_FA06 List.allCheck returns Something when all pass"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 634 (list) (lambda () (list 1 2 3 4))))
  (define result (thsl-src! "tests/critical-review64-tests.tesl" 635 (list (cons 'xs xs)) (lambda () (tesl_import_List_allCheck checkPos (raw-value xs)))))
  (let ([*tesl_case_27 (raw-value 
    result)]) (cond
    [(and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Nothing))
      (check-equal? (thsl-src! "tests/critical-review64-tests.tesl" 637 (list) (lambda () 0)) 1)
    ]
    [(and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Something))
      (let ([ys (hash-ref (adt-value-fields *tesl_case_27) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 638 (list) (lambda () (raw-value (tesl_import_List_length (raw-value ys)))))) 4)
      )
    ]
  ))
  )

  (test-case "R64_SC01 String.trim produces IsTrimmed proof usable by consumer"
  (define raw (thsl-src! "tests/critical-review64-tests.tesl" 646 (list) (lambda () "  hello  ")))
  (define trimmed (thsl-src! "tests/critical-review64-tests.tesl" 647 (list (cons 'raw raw)) (lambda () (tesl_import_String_trim (raw-value raw)))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 648 (list (cons 'trimmed trimmed) (cons 'raw raw)) (lambda () (needsTrimmed trimmed))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 649 (list (cons 'r r) (cons 'trimmed trimmed) (cons 'raw raw)) (lambda () r))) "hello")
  )

  (test-case "R64_SC02 String.toUpper produces IsUpperCase proof usable by consumer"
  (define raw (thsl-src! "tests/critical-review64-tests.tesl" 653 (list) (lambda () "hello")))
  (define upper (thsl-src! "tests/critical-review64-tests.tesl" 654 (list (cons 'raw raw)) (lambda () (tesl_import_String_toUpper (raw-value raw)))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 655 (list (cons 'upper upper) (cons 'raw raw)) (lambda () (needsUpper upper))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 656 (list (cons 'r r) (cons 'upper upper) (cons 'raw raw)) (lambda () r))) "HELLO")
  )

  (test-case "R64_SC03 List.sort produces IsSorted proof usable by consumer"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 660 (list) (lambda () (list 5 2 8 1 9 3))))
  (define sorted (thsl-src! "tests/critical-review64-tests.tesl" 661 (list (cons 'xs xs)) (lambda () (tesl_import_List_sort (raw-value xs)))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 662 (list (cons 'sorted sorted) (cons 'xs xs)) (lambda () (needsSorted sorted))))
  (define len (thsl-src! "tests/critical-review64-tests.tesl" 663 (list (cons 'r r) (cons 'sorted sorted) (cons 'xs xs)) (lambda () (raw-value (tesl_import_List_length (raw-value r))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 664 (list (cons 'len len) (cons 'r r) (cons 'sorted sorted) (cons 'xs xs)) (lambda () len))) 6)
  )

  (test-case "R64_SC04 Int.nonZero check enables Int.divide"
  (define a (thsl-src! "tests/critical-review64-tests.tesl" 668 (list) (lambda () 100)))
  (define b (thsl-src! "tests/critical-review64-tests.tesl" 669 (list (cons 'a a)) (lambda () 7)))
  (define tesl_checked_28 (tesl_import_Int_nonZero b))
  (when (check-fail? tesl_checked_28)
    (raise-user-error 'tesl-test "unexpected failure in let nz: ~a" (check-fail-message tesl_checked_28)))
  (define nz tesl_checked_28)
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 671 (list (cons 'nz nz) (cons 'b b) (cons 'a a)) (lambda () (tesl_import_Int_divide (raw-value a) nz))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 672 (list (cons 'r r) (cons 'nz nz) (cons 'b b) (cons 'a a)) (lambda () r))) 14)
  )

  (test-case "R64_SC05 Int.nonZero check fails for zero denominator"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 676 (list) (lambda ()
                          ((raw-value (tesl_import_Int_nonZero 0)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (tesl_import_Int_nonZero 0)) (list)"))
  )

  (test-case "R64_SC06 Float.requireNonZero enables Float.div"
  (define a (thsl-src! "tests/critical-review64-tests.tesl" 680 (list) (lambda () 10.)))
  (define b (thsl-src! "tests/critical-review64-tests.tesl" 681 (list (cons 'a a)) (lambda () 4.)))
  (define tesl_checked_29 (tesl_import_Float_requireNonZero b))
  (when (check-fail? tesl_checked_29)
    (raise-user-error 'tesl-test "unexpected failure in let nz: ~a" (check-fail-message tesl_checked_29)))
  (define nz tesl_checked_29)
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 683 (list (cons 'nz nz) (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl_import_Float_div (raw-value a) nz)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 684 (list (cons 'r r) (cons 'nz nz) (cons 'b b) (cons 'a a)) (lambda () r))) 2.5)
  )

  (test-case "R64_SC07 Int.nonNegative check works for zero"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 688 (list) (lambda () 0)))
  (define tesl_checked_30 (tesl_import_Int_nonNegative n))
  (when (check-fail? tesl_checked_30)
    (raise-user-error 'tesl-test "unexpected failure in let nn: ~a" (check-fail-message tesl_checked_30)))
  (define nn tesl_checked_30)
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 690 (list (cons 'nn nn) (cons 'n n)) (lambda () nn))) 0)
  )

  (test-case "R64_SC08 Int.nonNegative fails for negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 694 (list) (lambda ()
                          ((raw-value (tesl_import_Int_nonNegative -1)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (tesl_import_Int_nonNegative -1)) (list)"))
  )

  (test-case "R64_SC09 Float.requireNonZero fails for zero"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 698 (list) (lambda ()
                          ((raw-value (tesl_import_Float_requireNonZero 0.)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (tesl_import_Float_requireNonZero 0.)) (list)"))
  )

  (test-case "R64_AN01 andLeft extracts A proof from introAnd(A,B) result"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 714 (list) (lambda () (decomposeViaAndLeft 42))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 715 (list (cons 'r r)) (lambda () r))) 42)
  )

  (test-case "R64_AN02 andRight extracts B proof from introAnd(A,B) result"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 727 (list) (lambda () (decomposeViaAndRight 99))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 728 (list (cons 'r r)) (lambda () r))) 99)
  )

  (test-case "R64_AN03 both andLeft and andRight work on same conjunction"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 742 (list) (lambda () (useBothParts 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 743 (list (cons 'r r)) (lambda () r))) 10)
  )

  (test-case "R64_IN01 introAnd same-subject produces usable A && B conjunction"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 751 (list) (lambda () 77)))
  (define pa (thsl-src! "tests/critical-review64-tests.tesl" 752 (list (cons 'n n)) (lambda () (proveA n))))
  (define pb (thsl-src! "tests/critical-review64-tests.tesl" 753 (list (cons 'pa pa) (cons 'n n)) (lambda () (proveB n))))
  (define ab (thsl-src! "tests/critical-review64-tests.tesl" 754 (list (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and pa pb))))
  (define withProof (thsl-src! "tests/critical-review64-tests.tesl" 755 (list (cons 'ab ab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (attach-proof n ab))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 756 (list (cons 'withProof withProof) (cons 'ab ab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (needsAB withProof))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 757 (list (cons 'r r) (cons 'withProof withProof) (cons 'ab ab) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () r))) 77)
  )

  (test-case "R64_IN02 introAnd chained for 3 same-subject proofs"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 761 (list) (lambda () 11)))
  (define pa (thsl-src! "tests/critical-review64-tests.tesl" 762 (list (cons 'n n)) (lambda () (proveA n))))
  (define pb (thsl-src! "tests/critical-review64-tests.tesl" 763 (list (cons 'pa pa) (cons 'n n)) (lambda () (proveB n))))
  (define pc (thsl-src! "tests/critical-review64-tests.tesl" 764 (list (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (proveC n))))
  (define ab (thsl-src! "tests/critical-review64-tests.tesl" 765 (list (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and pa pb))))
  (define abc (thsl-src! "tests/critical-review64-tests.tesl" 766 (list (cons 'ab ab) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (intro-and ab pc))))
  (define withProof (thsl-src! "tests/critical-review64-tests.tesl" 767 (list (cons 'abc abc) (cons 'ab ab) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (attach-proof n abc))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 768 (list (cons 'withProof withProof) (cons 'abc abc) (cons 'ab ab) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () (needsABC withProof))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 769 (list (cons 'r r) (cons 'withProof withProof) (cons 'abc abc) (cons 'ab ab) (cons 'pc pc) (cons 'pb pb) (cons 'pa pa) (cons 'n n)) (lambda () r))) 11)
  )

  (test-case "R64_RR01 record field proof round-trip: construction + field access preserves proof"
  (define rawTitle (thsl-src! "tests/critical-review64-tests.tesl" 789 (list) (lambda () "My Document")))
  (define doc (thsl-src! "tests/critical-review64-tests.tesl" 790 (list (cons 'rawTitle rawTitle)) (lambda () (makeDoc rawTitle 500))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 791 (list (cons 'doc doc) (cons 'rawTitle rawTitle)) (lambda () (readTitle doc))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 792 (list (cons 'r r) (cons 'doc doc) (cons 'rawTitle rawTitle)) (lambda () r))) "My Document")
  )

  (test-case "R64_RR02 record construction fails when field check fails"
  (define rawTitle (thsl-src! "tests/critical-review64-tests.tesl" 796 (list) (lambda () "")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 797 (list (cons 'rawTitle rawTitle)) (lambda ()
                          ((makeDoc rawTitle 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (makeDoc rawTitle 0) (list)"))
  )

  (test-case "R64_RR03 record update preserves proof on non-updated proof-annotated field"
  (define rawTitle (thsl-src! "tests/critical-review64-tests.tesl" 809 (list) (lambda () "Updated Doc")))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 810 (list (cons 'rawTitle rawTitle)) (lambda () (readUpdatedTitle rawTitle 100))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 811 (list (cons 'r r) (cons 'rawTitle rawTitle)) (lambda () r))) "Updated Doc")
  )

  (test-case "R64_XP01 combined check && on single value succeeds when both pass"
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 823 (list) (lambda () (applyCombined 42))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 824 (list (cons 'r r)) (lambda () r))) 42)
  )

  (test-case "R64_XP02 combined check && fails when first check fails (negative)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 828 (list) (lambda ()
                          ((applyCombined -1) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (applyCombined -1) (list)"))
  )

  (test-case "R64_XP03 combined check && fails when second check fails (too big)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 832 (list) (lambda ()
                          ((applyCombined 999) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (applyCombined 999) (list)"))
  )

  (test-case "R64_XP04 combined check in filterCheck produces correct ForAll"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 839 (list) (lambda () (list 0 5 15 100 3))))
  (define filtered (thsl-src! "tests/critical-review64-tests.tesl" 840 (list (cons 'xs xs)) (lambda () (filterActivePinnedDirect xs))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 841 (list (cons 'filtered filtered) (cons 'xs xs)) (lambda () (raw-value (tesl_import_List_length (raw-value filtered))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 844 (list (cons 'r r) (cons 'filtered filtered) (cons 'xs xs)) (lambda () r))) 2)
  )

  (test-case "R64_LI01 literal-parametrized predicate HasMin 10 works on single value"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 891 (list) (lambda () 15)))
  (define tesl_checked_31 (checkMin10 n))
  (when (check-fail? tesl_checked_31)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl_checked_31)))
  (define p tesl_checked_31)
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 893 (list (cons 'p p) (cons 'n n)) (lambda () (needAbove10 p))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 894 (list (cons 'r r) (cons 'p p) (cons 'n n)) (lambda () r))) 15)
  )

  (test-case "R64_LI02 literal-parametrized predicate HasMin 20 is distinct from HasMin 10"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 898 (list) (lambda () 25)))
  (define tesl_checked_32 (checkMin20 n))
  (when (check-fail? tesl_checked_32)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl_checked_32)))
  (define p tesl_checked_32)
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 900 (list (cons 'p p) (cons 'n n)) (lambda () (needAbove20 p))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 901 (list (cons 'r r) (cons 'p p) (cons 'n n)) (lambda () r))) 25)
  )

  (test-case "R64_LI03 literal-parametrized conjunction HasMin 10 && HasMax 100"
  (define n (thsl-src! "tests/critical-review64-tests.tesl" 905 (list) (lambda () 50)))
  (define tesl_checked_33 (checkMin10 n))
  (when (check-fail? tesl_checked_33)
    (raise-user-error 'tesl-test "unexpected failure in let lo: ~a" (check-fail-message tesl_checked_33)))
  (define lo tesl_checked_33)
  (define tesl_checked_34 (checkMax100 lo))
  (when (check-fail? tesl_checked_34)
    (raise-user-error 'tesl-test "unexpected failure in let hi: ~a" (check-fail-message tesl_checked_34)))
  (define hi tesl_checked_34)
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 908 (list (cons 'hi hi) (cons 'lo lo) (cons 'n n)) (lambda () (needBothBounds hi))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 909 (list (cons 'r r) (cons 'hi hi) (cons 'lo lo) (cons 'n n)) (lambda () r))) 50)
  )

  (test-case "R64_LI04 HasMin 10 check fails for value below threshold"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 913 (list) (lambda ()
                          ((raw-value (checkMin10 5)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkMin10 5)) (list)"))
  )

  (test-case "R64_LI05 HasMax 100 check fails for value above threshold"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review64-tests.tesl" 917 (list) (lambda ()
                          ((raw-value (checkMax100 150)) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (raw-value (checkMax100 150)) (list)"))
  )

  (test-case "R64_LI06 ForAll (HasMin 10) from filterCheck matches parameter annotation"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 923 (list) (lambda () (list 5 10 15 20 3))))
  (define filtered (thsl-src! "tests/critical-review64-tests.tesl" 924 (list (cons 'xs xs)) (lambda () (filterAbove10 xs))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 925 (list (cons 'filtered filtered) (cons 'xs xs)) (lambda () (needForAllAbove10 filtered))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 926 (list (cons 'r r) (cons 'filtered filtered) (cons 'xs xs)) (lambda () r))) 3)
  )

  (test-case "R64_LI07 ForAll (HasMin 20) is distinct from ForAll (HasMin 10)"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 930 (list) (lambda () (list 15 25 30))))
  (define filtered (thsl-src! "tests/critical-review64-tests.tesl" 931 (list (cons 'xs xs)) (lambda () (filterAbove20 xs))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 932 (list (cons 'filtered filtered) (cons 'xs xs)) (lambda () (needForAllAbove20 filtered))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 933 (list (cons 'r r) (cons 'filtered filtered) (cons 'xs xs)) (lambda () r))) 2)
  )

  (test-case "R64_LI08 ForAll (HasMin 10) correctly keeps only values >= 10"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 937 (list) (lambda () (list 1 2 9 10 11 100))))
  (define filtered (thsl-src! "tests/critical-review64-tests.tesl" 938 (list (cons 'xs xs)) (lambda () (filterAbove10 xs))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 939 (list (cons 'filtered filtered) (cons 'xs xs)) (lambda () (needForAllAbove10 filtered))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 940 (list (cons 'r r) (cons 'filtered filtered) (cons 'xs xs)) (lambda () r))) 3)
  )

  (test-case "R64_LI09 ForAll (HasMin 20) from empty input"
  (define xs (thsl-src! "tests/critical-review64-tests.tesl" 944 (list) (lambda () (list 1 5 15))))
  (define filtered (thsl-src! "tests/critical-review64-tests.tesl" 945 (list (cons 'xs xs)) (lambda () (filterAbove20 xs))))
  (define r (thsl-src! "tests/critical-review64-tests.tesl" 946 (list (cons 'filtered filtered) (cons 'xs xs)) (lambda () (needForAllAbove20 filtered))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 947 (list (cons 'r r) (cons 'filtered filtered) (cons 'xs xs)) (lambda () r))) 0)
  )

  (test-case "R64_NT01 newtype UserId and ProjectId are distinct nominal types"
  (define rawUser (thsl-src! "tests/critical-review64-tests.tesl" 976 (list) (lambda () "user-abc")))
  (define rawProject (thsl-src! "tests/critical-review64-tests.tesl" 977 (list (cons 'rawUser rawUser)) (lambda () "proj-xyz")))
  (define uid (thsl-src! "tests/critical-review64-tests.tesl" 978 (list (cons 'rawProject rawProject) (cons 'rawUser rawUser)) (lambda () (raw-value (UserId (raw-value rawUser))))))
  (define pid (thsl-src! "tests/critical-review64-tests.tesl" 979 (list (cons 'uid uid) (cons 'rawProject rawProject) (cons 'rawUser rawUser)) (lambda () (raw-value (ProjectId (raw-value rawProject))))))
  (define tesl_checked_35 (checkUser uid))
  (when (check-fail? tesl_checked_35)
    (raise-user-error 'tesl-test "unexpected failure in let vu: ~a" (check-fail-message tesl_checked_35)))
  (define vu tesl_checked_35)
  (define tesl_checked_36 (checkProject pid))
  (when (check-fail? tesl_checked_36)
    (raise-user-error 'tesl-test "unexpected failure in let vp: ~a" (check-fail-message tesl_checked_36)))
  (define vp tesl_checked_36)
  (define r1 (thsl-src! "tests/critical-review64-tests.tesl" 982 (list (cons 'vp vp) (cons 'vu vu) (cons 'pid pid) (cons 'uid uid) (cons 'rawProject rawProject) (cons 'rawUser rawUser)) (lambda () (needsValidUser vu))))
  (define r2 (thsl-src! "tests/critical-review64-tests.tesl" 983 (list (cons 'r1 r1) (cons 'vp vp) (cons 'vu vu) (cons 'pid pid) (cons 'uid uid) (cons 'rawProject rawProject) (cons 'rawUser rawUser)) (lambda () (needsValidProject vp))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 984 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'vp vp) (cons 'vu vu) (cons 'pid pid) (cons 'uid uid) (cons 'rawProject rawProject) (cons 'rawUser rawUser)) (lambda () r1))) "user-abc")
  (check-equal? (raw-value (thsl-src! "tests/critical-review64-tests.tesl" 985 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'vp vp) (cons 'vu vu) (cons 'pid pid) (cons 'uid uid) (cons 'rawProject rawProject) (cons 'rawUser rawUser)) (lambda () r2))) "proj-xyz")
  )

  (test-case "R64_NT02 newtype .value field unwraps to base type"
  (define raw (thsl-src! "tests/critical-review64-tests.tesl" 989 (list) (lambda () "hello")))
  (define uid (thsl-src! "tests/critical-review64-tests.tesl" 990 (list (cons 'raw raw)) (lambda () (raw-value (UserId (raw-value raw))))))
  (check-equal? (thsl-src! "tests/critical-review64-tests.tesl" 991 (list (cons 'uid uid) (cons 'raw raw)) (lambda () (raw-value (tesl-dot/runtime uid 'value)))) "hello")
  )

  (test-case "R64_NT03 two newtypes over String wrapping same raw value are distinct"
  (define raw (thsl-src! "tests/critical-review64-tests.tesl" 995 (list) (lambda () "same-raw")))
  (define uid (thsl-src! "tests/critical-review64-tests.tesl" 996 (list (cons 'raw raw)) (lambda () (raw-value (UserId (raw-value raw))))))
  (define pid (thsl-src! "tests/critical-review64-tests.tesl" 997 (list (cons 'uid uid) (cons 'raw raw)) (lambda () (raw-value (ProjectId (raw-value raw))))))
  (check-equal? (thsl-src! "tests/critical-review64-tests.tesl" 998 (list (cons 'pid pid) (cons 'uid uid) (cons 'raw raw)) (lambda () (raw-value (tesl-dot/runtime uid 'value)))) (raw-value (tesl-dot/runtime pid 'value)))
  )

)
