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
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.isEmpty tesl_import_String_isEmpty] IsTrimmed)
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.reverse tesl_import_List_reverse] [List.append tesl_import_List_append] [List.take tesl_import_List_take])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either Either Left Right)
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide] IsNonZero [Int.nonNegative tesl_import_Int_nonNegative] IsNonNegative)
  (only-in tesl/tesl/float Float [Float.abs tesl_import_Float_abs] [Float.sqrt tesl_import_Float_sqrt])
)


(provide checkPositive48 requiresPositive48 checkNonEmpty48 Positive48 NonEmpty48 maybeEstablish alwaysEstablish Meters Kilograms convertMeters convertKilograms decompose48 decomposeAndUse checkBothProofs useBothProofs Direction North South East West Speed Slow Fast Movement Moving Stopped describeMovement pipedAdd pipedCheckLen BetweenFact checkBetween48 requiresBetween48 filterSmallPositive smallPositiveAll formatComplex ExprF LitF AddF NegF evalExpr48 Status48 Active48 Inactive48 Suspended48 describeStatus48 largeMul resultFromCase48 makeAdder applyTwice Priority48 Critical48 High48 Medium48 Low48 priorityLabel httpStatus wrapAll unwrapAll attemptProve48 ValidTitle48 checkTitle48 SafeItem48 readSafeField OrderedPair OrderedFact proveOrdered makeOrderedPair checkPositive48-signature requiresPositive48-signature alwaysEstablish-signature maybeEstablish-signature convertMeters-signature convertKilograms-signature decompose48-signature decomposeAndUse-signature checkBothProofs-signature useBothProofs-signature describeMovement-signature pipedAdd-signature pipedCheckLen-signature checkBetween48-signature requiresBetween48-signature filterSmallPositive-signature smallPositiveAll-signature formatComplex-signature evalExpr48-signature describeStatus48-signature largeMul-signature resultFromCase48-signature makeAdder-signature applyTwice-signature priorityLabel-signature httpStatus-signature wrapAll-signature unwrapAll-signature attemptProve48-signature checkTitle48-signature readSafeField-signature proveOrdered-signature makeOrderedPair-signature checkNonEmpty48-signature)

(define BetweenFact 'BetweenFact)
(define NonEmpty48 'NonEmpty48)
(define OrderedFact 'OrderedFact)
(define Positive48 'Positive48)
(define ProvenFact48 'ProvenFact48)
(define Small48 'Small48)
(define ValidPort48 'ValidPort48)
(define ValidTitle48 'ValidTitle48)

(define-checker
  (checkPositive48 [n : Integer])
  #:returns [n : Integer ::: (Positive48 n)]
  (thsl-src! "tests/critical-review-48-tests.tesl" 83 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (Positive48 n) #:value *n) (reject "must be positive" #:http-code 400)))))

(define/pow
  (requiresPositive48 [n : Integer ::: (Positive48 n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 88 (list (cons 'n *n)) (lambda () (* *n 2))))

(define-trusted
  (alwaysEstablish [n : Integer])
  #:returns (Fact (ProvenFact48 n))
  (thsl-src! "tests/critical-review-48-tests.tesl" 119 (list (cons 'n *n)) (lambda () (trusted-proof (ProvenFact48 n)))))

(define-trusted
  (maybeEstablish [n : Integer])
  #:returns (Maybe (Fact (ProvenFact48 n)))
  (thsl-src! "tests/critical-review-48-tests.tesl" 122 (list (cons 'n *n)) (lambda () (if (> *n 0) (Something (trusted-proof (ProvenFact48 n))) Nothing))))

(define-newtype Meters Integer)

(define-newtype Kilograms Integer)

(define/pow
  (convertMeters [m : Meters])
  #:returns String
  (thsl-src! "tests/critical-review-48-tests.tesl" 156 (list (cons 'm *m)) (lambda () (format "~am" (tesl-display-val (raw-value m.value))))))

(define/pow
  (convertKilograms [kg : Kilograms])
  #:returns String
  (thsl-src! "tests/critical-review-48-tests.tesl" 159 (list (cons 'kg *kg)) (lambda () (format "~akg" (tesl-display-val (raw-value kg.value))))))

(define/pow
  (decompose48 [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 180 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-0 (checkPositive48 n)]) (let ([proven tesl-checked-0]) (let ([tesl-proof-binding-1 proven]) (let ([raw (forget-proof tesl-proof-binding-1)] [proof (detach-all-proof tesl-proof-binding-1)]) (let ([reattached (attach-proof raw proof)]) (raw-value (requiresPositive48 reattached))))))))))

(define/pow
  (decomposeAndUse [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-48-tests.tesl" 186 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-2 (checkPositive48 n)]) (let ([proven tesl-checked-2]) (let ([val proven]) (format "value is ~a" (tesl-display-val *val))))))))

(define-checker
  (checkSmall48 [n : Integer])
  #:returns [n : Integer ::: (Small48 n)]
  (thsl-src! "tests/critical-review-48-tests.tesl" 211 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (Small48 n) #:value *n) (reject "must be small" #:http-code 400)))))

(define-checker
  (checkBothProofs [n : Integer])
  #:returns [n : Integer ::: ((Positive48 n) && (Small48 n))]
  (thsl-src! "tests/critical-review-48-tests.tesl" 217 (list (cons 'n *n)) (lambda () ((check-and checkPositive48 checkSmall48) n))))

(define/pow
  (useBothProofs [n : Integer ::: ((Positive48 n) && (Small48 n))])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 219 (list (cons 'n *n)) (lambda () (* *n 3))))

(define-adt Direction
  [North]
  [South]
  [East]
  [West]
)

(define-adt Speed
  [Slow]
  [Fast]
)

(define-adt Movement
  [Moving [dir : Direction] [speed : Speed]]
  [Stopped]
)

(define/pow
  (describeMovement [m : Movement])
  #:returns String
  (thsl-src-control! "tests/critical-review-48-tests.tesl" 263 (list (cons 'm *m)) (lambda () (let ([tesl-case-3 *m]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Stopped)) (thsl-src! "tests/critical-review-48-tests.tesl" 264 (list) (lambda () (raw-value "stopped")))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Moving)) (let ([dir (hash-ref (adt-value-fields *tesl-case-3) 'dir)]) (let ([speed (hash-ref (adt-value-fields *tesl-case-3) 'speed)]) (thsl-src! "tests/critical-review-48-tests.tesl" 266 (list (cons 'dir dir) (cons 'speed speed)) (lambda () (let ([dirStr (let ([tesl-case-4 (raw-value dir)]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'North)) (thsl-src! "tests/critical-review-48-tests.tesl" 267 (list) (lambda () "north"))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'South)) (thsl-src! "tests/critical-review-48-tests.tesl" 268 (list) (lambda () "south"))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'East)) (thsl-src! "tests/critical-review-48-tests.tesl" 269 (list) (lambda () "east"))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'West)) (thsl-src! "tests/critical-review-48-tests.tesl" 270 (list) (lambda () "west"))]))]) (let ([speedStr (let ([tesl-case-5 (raw-value speed)]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Slow)) (thsl-src! "tests/critical-review-48-tests.tesl" 272 (list) (lambda () "slowly"))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Fast)) (thsl-src! "tests/critical-review-48-tests.tesl" 273 (list) (lambda () "quickly"))]))]) (raw-value (format "moving ~a ~a" (tesl-display-val *dirStr) (tesl-display-val *speedStr)))))))))])))))

(define/pow
  (add48 [x : Integer] [y : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 297 (list (cons 'x *x) (cons 'y *y)) (lambda () (+ *x *y))))

(define/pow
  (double48 [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 298 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (pipedAdd [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 301 (list (cons 'n *n)) (lambda () (raw-value (double48 (double48 n))))))

(define/pow
  (pipedCheckLen [s : String])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 304 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define-checker
  (checkBetween48 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (BetweenFact lo hi n)]
  (thsl-src! "tests/critical-review-48-tests.tesl" 324 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (>= *n *lo) (<= *n *hi)) (accept (BetweenFact lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define/pow
  (requiresBetween48 [lo : Integer] [hi : Integer] [n : Integer ::: (BetweenFact lo hi n)])
  #:returns String
  (thsl-src! "tests/critical-review-48-tests.tesl" 330 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (format "~a in [~a,~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))))

(define/pow
  (testBetween [lo : Integer] [hi : Integer] [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-48-tests.tesl" 333 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (let/check ([tesl-checked-6 (checkBetween48 lo hi n)]) (let ([v tesl-checked-6]) (raw-value (requiresBetween48 lo hi v)))))))

(define/pow
  (filterSmallPositive [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-48-tests.tesl" 365 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck (check-and checkPositive48 checkSmall48) *xs))))

(define/pow
  (smallPositiveAll [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (thsl-src! "tests/critical-review-48-tests.tesl" 368 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck checkPositive48 *xs))))

(define/pow
  (formatComplex [a : Integer] [b : Integer])
  #:returns String
  (let ([theSum (thsl-src! "tests/critical-review-48-tests.tesl" 400 (list (cons 'a *a) (cons 'b *b)) (lambda () (+ *a *b)))]) (let ([diff (thsl-src! "tests/critical-review-48-tests.tesl" 401 (list (cons 'theSum *theSum) (cons 'a *a) (cons 'b *b)) (lambda () (- *a *b)))]) (thsl-src! "tests/critical-review-48-tests.tesl" 402 (list (cons 'diff *diff) (cons 'theSum *theSum) (cons 'a *a) (cons 'b *b)) (lambda () (format "sum=~a, diff=~a" (tesl-display-val *theSum) (tesl-display-val *diff)))))))

(define-adt ExprF
  [LitF [n : Integer]]
  [AddF [left : ExprF] [right : ExprF]]
  [NegF [inner : ExprF]]
)

(define/pow
  (evalExpr48 [e : ExprF])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-48-tests.tesl" 420 (list (cons 'e *e)) (lambda () (let ([tesl-case-7 *e]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'LitF)) (let ([n (hash-ref (adt-value-fields *tesl-case-7) 'n)]) (thsl-src! "tests/critical-review-48-tests.tesl" 421 (list (cons 'n n)) (lambda () *n)))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'AddF)) (let ([left (hash-ref (adt-value-fields *tesl-case-7) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl-case-7) 'right)]) (thsl-src! "tests/critical-review-48-tests.tesl" 422 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (+ (raw-value (evalExpr48 *left)) (raw-value (evalExpr48 *right))))))))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'NegF)) (let ([inner (hash-ref (adt-value-fields *tesl-case-7) 'inner)]) (thsl-src! "tests/critical-review-48-tests.tesl" 423 (list (cons 'inner inner)) (lambda () (raw-value (- 0 (raw-value (evalExpr48 *inner)))))))])))))

(define-adt Status48
  [Active48]
  [Inactive48]
  [Suspended48 [reason : String]]
)

(define/pow
  (describeStatus48 [s : Status48])
  #:returns String
  (thsl-src-control! "tests/critical-review-48-tests.tesl" 452 (list (cons 's *s)) (lambda () (let ([tesl-case-8 *s]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Active48)) (thsl-src! "tests/critical-review-48-tests.tesl" 453 (list) (lambda () (raw-value "active")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Inactive48)) (thsl-src! "tests/critical-review-48-tests.tesl" 454 (list) (lambda () (raw-value "inactive")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Suspended48)) (let ([reason (hash-ref (adt-value-fields *tesl-case-8) 'reason)]) (thsl-src! "tests/critical-review-48-tests.tesl" 455 (list (cons 'reason reason)) (lambda () (raw-value (format "suspended: ~a" (tesl-display-val *reason))))))])))))

(define/pow
  (largeMul [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 470 (list (cons 'a *a) (cons 'b *b)) (lambda () (* *a *b))))

(define/pow
  (resultFromCase48 [m : (Maybe Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-48-tests.tesl" 491 (list (cons 'm *m)) (lambda () (let ([tesl-case-9 *m]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing)) (thsl-src! "tests/critical-review-48-tests.tesl" 492 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (thsl-src! "tests/critical-review-48-tests.tesl" 494 (list (cons 'v v)) (lambda () (let/check ([tesl-checked-10 (checkPositive48 *v)]) (let ([proven tesl-checked-10]) (raw-value (requiresPositive48 proven)))))))])))))

(define/pow
  (makeAdder [n : Integer])
  #:returns (-> Integer Integer)
  (thsl-src! "tests/critical-review-48-tests.tesl" 514 (list (cons 'n *n)) (lambda () (let () (define/pow (tesl-lambda-11 [x : Integer]) #:returns Integer (+ *x *n)) tesl-lambda-11))))

(define/pow
  (applyTwice [f : (-> Integer Integer)] [x : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 517 (list (cons 'f *f) (cons 'x *x)) (lambda () (raw-value (f (f x))))))

(define-adt Priority48
  [Critical48]
  [High48]
  [Medium48]
  [Low48]
)

(define/pow
  (priorityLabel [p : Priority48])
  #:returns String
  (thsl-src-control! "tests/critical-review-48-tests.tesl" 545 (list (cons 'p *p)) (lambda () (let ([tesl-case-12 *p]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Critical48)) (thsl-src! "tests/critical-review-48-tests.tesl" 548 (list) (lambda () (raw-value "urgent")))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'High48)) (thsl-src! "tests/critical-review-48-tests.tesl" 548 (list) (lambda () (raw-value "urgent")))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Medium48)) (thsl-src! "tests/critical-review-48-tests.tesl" 550 (list) (lambda () (raw-value "normal")))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Low48)) (thsl-src! "tests/critical-review-48-tests.tesl" 552 (list) (lambda () (raw-value "low")))])))))

(define/pow
  (httpStatus [code : Integer])
  #:returns String
  (thsl-src-control! "tests/critical-review-48-tests.tesl" 575 (list (cons 'code *code)) (lambda () (let ([tesl-case-13 *code]) (cond [(= *tesl-case-13 200) (thsl-src! "tests/critical-review-48-tests.tesl" 576 (list) (lambda () (raw-value "OK")))] [(= *tesl-case-13 201) (thsl-src! "tests/critical-review-48-tests.tesl" 577 (list) (lambda () (raw-value "Created")))] [(= *tesl-case-13 400) (thsl-src! "tests/critical-review-48-tests.tesl" 578 (list) (lambda () (raw-value "Bad Request")))] [(= *tesl-case-13 404) (thsl-src! "tests/critical-review-48-tests.tesl" 579 (list) (lambda () (raw-value "Not Found")))] [(= *tesl-case-13 500) (thsl-src! "tests/critical-review-48-tests.tesl" 580 (list) (lambda () (raw-value "Internal Server Error")))] [#t (thsl-src! "tests/critical-review-48-tests.tesl" 581 (list) (lambda () (raw-value "Unknown")))])))))

(define/pow
  (wrapAll [xs : (List Integer)])
  #:returns (List Meters)
  (thsl-src! "tests/critical-review-48-tests.tesl" 601 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-14 [n : Integer]) #:returns Any (raw-value (Meters *n))) tesl-lambda-14) *xs)))))

(define/pow
  (unwrapAll [xs : (List Meters)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-48-tests.tesl" 604 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-15 [m : Meters]) #:returns Integer (raw-value m.value)) tesl-lambda-15) *xs)))))

(define-trusted
  (attemptProve48 [p : Integer])
  #:returns (Maybe (Fact (ValidPort48 p)))
  (thsl-src! "tests/critical-review-48-tests.tesl" 624 (list (cons 'p *p)) (lambda () (if (and (>= *p 1) (<= *p 65535)) (Something (trusted-proof (ValidPort48 p))) Nothing))))

(define/pow
  (requiresValidPort48 [p : Integer ::: (ValidPort48 p)])
  #:returns String
  (thsl-src! "tests/critical-review-48-tests.tesl" 630 (list (cons 'p *p)) (lambda () (format "port ~a" (tesl-display-val *p)))))

(define/pow
  (tryListen [p : Integer])
  #:returns String
  (let ([maybeProof (thsl-src! "tests/critical-review-48-tests.tesl" 633 (list (cons 'p *p)) (lambda () (attemptProve48 p)))]) (thsl-src-control! "tests/critical-review-48-tests.tesl" 634 (list (cons 'maybeProof *maybeProof) (cons 'p *p)) (lambda () (let ([tesl-case-16 (raw-value maybeProof)]) (cond [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Something)) (let ([proof (hash-ref (adt-value-fields *tesl-case-16) 'value)]) (thsl-src! "tests/critical-review-48-tests.tesl" 635 (list (cons 'proof proof)) (lambda () (raw-value (requiresValidPort48 (attach-proof p proof))))))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Nothing)) (thsl-src! "tests/critical-review-48-tests.tesl" 636 (list) (lambda () (raw-value "invalid port")))]))))))

(define-checker
  (checkTitle48 [s : String])
  #:returns [s : String ::: (ValidTitle48 s)]
  (thsl-src! "tests/critical-review-48-tests.tesl" 661 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 1) (<= (raw-value (tesl_import_String_length *s)) 100)) (accept (ValidTitle48 s) #:value *s) (reject "title must be 1-100 chars" #:http-code 400)))))

(define/pow
  (requiresValidTitle48 [t : String ::: (ValidTitle48 t)])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 667 (list (cons 't *t)) (lambda () (raw-value (tesl_import_String_length *t)))))

(define-record SafeItem48
  [title : String ::: (ValidTitle48 title)]
)

(define/pow
  (readSafeField [item : SafeItem48])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 674 (list (cons 'item *item)) (lambda () (raw-value (requiresValidTitle48 (tesl-dot/runtime item 'title))))))

(define-record OrderedPair
  [lo : Integer]
  [hi : Integer]
)

(define-trusted
  (proveOrdered [lo : Integer] [hi : Integer])
  #:returns (Maybe (Fact (OrderedFact lo hi)))
  (thsl-src! "tests/critical-review-48-tests.tesl" 702 (list (cons 'lo *lo) (cons 'hi *hi)) (lambda () (if (<= *lo *hi) (Something (trusted-proof (OrderedFact lo hi))) Nothing))))

(define/pow
  (makeOrderedPair [a : Integer] [b : Integer])
  #:returns (Maybe OrderedPair)
  (let ([maybeProof (thsl-src! "tests/critical-review-48-tests.tesl" 708 (list (cons 'a *a) (cons 'b *b)) (lambda () (proveOrdered a b)))]) (thsl-src-control! "tests/critical-review-48-tests.tesl" 709 (list (cons 'maybeProof *maybeProof) (cons 'a *a) (cons 'b *b)) (lambda () (let ([tesl-case-17 (raw-value maybeProof)]) (cond [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Nothing)) (thsl-src! "tests/critical-review-48-tests.tesl" 710 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Something)) (let ([proof (hash-ref (adt-value-fields *tesl-case-17) 'value)]) (thsl-src! "tests/critical-review-48-tests.tesl" 712 (list (cons 'proof proof)) (lambda () (raw-value (raw-value (Something (OrderedPair #:lo *a #:hi *b)))))))]))))))

(define-checker
  (checkNonEmpty48 [s : String])
  #:returns [s : String ::: (NonEmpty48 s)]
  (thsl-src! "tests/critical-review-48-tests.tesl" 759 (list (cons 's *s)) (lambda () (if (tesl_import_String_isEmpty *s) (reject "empty" #:http-code 400) (accept (NonEmpty48 s) #:value *s)))))

(define/pow
  (safeTake48 [xs : (List Integer)] [n : Integer])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-48-tests.tesl" 765 (list (cons 'xs *xs) (cons 'n *n)) (lambda () (let/check ([tesl-checked-18 (tesl_import_Int_nonNegative n)]) (let ([nn tesl-checked-18]) (raw-value (tesl_import_List_take nn *xs)))))))

(define/pow
  (safeDivide48 [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 769 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-19 (tesl_import_Int_nonZero b)]) (let ([nz tesl-checked-19]) (raw-value (tesl_import_Int_divide *a nz)))))))

(define/pow
  (forgetAndRecheck [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-48-tests.tesl" 813 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-20 (checkPositive48 n)]) (let ([proven tesl-checked-20]) (let ([forgotten (forget-proof proven)]) (let/check ([tesl-checked-21 (checkPositive48 forgotten)]) (let ([reproven tesl-checked-21]) (raw-value (requiresPositive48 reproven))))))))))

(module+ test
  (require rackunit)
  (test-case "R48-01: proof round-trip via check -> requires"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review-48-tests.tesl" 91 (list) (lambda () 42)))
  (define tesl-checked-22 (checkPositive48 raw))
  (when (check-fail? tesl-checked-22)
    (raise-user-error 'tesl-test "unexpected failure in let proven: ~a" (check-fail-message tesl-checked-22)))
  (define proven tesl-checked-22)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 93 (list (cons 'proven proven) (cons 'raw raw)) (lambda () (requiresPositive48 proven)))) 84)
    ))
  )

  (test-case "R48-02: check rejects boundary 0"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 97 (list) (lambda ()
                          (checkPositive48 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositive48 0"))
    ))
  )

  (test-case "R48-03: check rejects negative"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 101 (list) (lambda ()
                          (checkPositive48 -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositive48 -1"))
    ))
  )

  (test-case "R48-04: no-shadowing rule is enforced (module compiles)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 109 (list) (lambda () 1)) 1)
    ))
  )

  (test-case "R48-05: establish always succeeds (total)"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review-48-tests.tesl" 128 (list) (lambda () 5)))
  (define proof (thsl-src! "tests/critical-review-48-tests.tesl" 129 (list (cons 'raw raw)) (lambda () (alwaysEstablish raw))))
  (check-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 130 (list (cons 'proof proof) (cons 'raw raw)) (lambda () 1)) 1)
    ))
  )

  (test-case "R48-06: maybe establish returns Something for positive"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review-48-tests.tesl" 134 (list) (lambda () 10)))
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 135 (list (cons 'raw raw)) (lambda () (maybeEstablish raw))))
  (check-not-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 136 (list (cons 'result result) (cons 'raw raw)) (lambda () result)) Nothing)
    ))
  )

  (test-case "R48-07: maybe establish returns Nothing for non-positive"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review-48-tests.tesl" 140 (list) (lambda () 0)))
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 141 (list (cons 'raw raw)) (lambda () (maybeEstablish raw))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 142 (list (cons 'result result) (cons 'raw raw)) (lambda () result))) Nothing)
  (define rawNeg (thsl-src! "tests/critical-review-48-tests.tesl" 143 (list (cons 'result result) (cons 'raw raw)) (lambda () -5)))
  (define result2 (thsl-src! "tests/critical-review-48-tests.tesl" 144 (list (cons 'rawNeg rawNeg) (cons 'result result) (cons 'raw raw)) (lambda () (maybeEstablish rawNeg))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 145 (list (cons 'result2 result2) (cons 'rawNeg rawNeg) (cons 'result result) (cons 'raw raw)) (lambda () result2))) Nothing)
    ))
  )

  (test-case "R48-08: newtypes produce correct string representation"
    (call-with-fresh-memory-db '() (lambda ()
  (define m (thsl-src! "tests/critical-review-48-tests.tesl" 162 (list) (lambda () (raw-value (Meters 42)))))
  (define kg (thsl-src! "tests/critical-review-48-tests.tesl" 163 (list (cons 'm m)) (lambda () (raw-value (Kilograms 100)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 164 (list (cons 'kg kg) (cons 'm m)) (lambda () (convertMeters m)))) "42m")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 165 (list (cons 'kg kg) (cons 'm m)) (lambda () (convertKilograms kg)))) "100kg")
    ))
  )

  (test-case "R48-09: newtype .value round-trips"
    (call-with-fresh-memory-db '() (lambda ()
  (define m (thsl-src! "tests/critical-review-48-tests.tesl" 169 (list) (lambda () (raw-value (Meters 0)))))
  (check-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 170 (list (cons 'm m)) (lambda () (raw-value (tesl-dot/runtime m 'value)))) 0)
  (define kg (thsl-src! "tests/critical-review-48-tests.tesl" 171 (list (cons 'm m)) (lambda () (raw-value (Kilograms -5)))))
  (check-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 172 (list (cons 'kg kg) (cons 'm m)) (lambda () (raw-value (tesl-dot/runtime kg 'value)))) -5)
    ))
  )

  (test-case "R48-10: decompose-reattach round-trip"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 191 (list) (lambda () (decompose48 5)))) 10)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 192 (list) (lambda () (decompose48 1)))) 2)
    ))
  )

  (test-case "R48-11: decompose fails for invalid input"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 196 (list) (lambda ()
                          (decompose48 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decompose48 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 197 (list) (lambda ()
                          (decompose48 -5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decompose48 -5"))
    ))
  )

  (test-case "R48-12: decompose-and-discard-proof"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 201 (list) (lambda () (decomposeAndUse 7)))) "value is 7")
    ))
  )

  (test-case "R48-13: conjunction passes for valid values"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "tests/critical-review-48-tests.tesl" 222 (list) (lambda () 50)))
  (define tesl-checked-23 (checkBothProofs n))
  (when (check-fail? tesl-checked-23)
    (raise-user-error 'tesl-test "unexpected failure in let proven: ~a" (check-fail-message tesl-checked-23)))
  (define proven tesl-checked-23)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 224 (list (cons 'proven proven) (cons 'n n)) (lambda () (useBothProofs proven)))) 150)
    ))
  )

  (test-case "R48-14: conjunction fails for zero (not positive)"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 228 (list) (lambda ()
                          (checkBothProofs 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBothProofs 0"))
    ))
  )

  (test-case "R48-15: conjunction fails for 100 (not small)"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 232 (list) (lambda ()
                          (checkBothProofs 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkBothProofs 100"))
    ))
  )

  (test-case "R48-16: conjunction boundary: 1 and 99"
    (call-with-fresh-memory-db '() (lambda ()
  (define n1 (thsl-src! "tests/critical-review-48-tests.tesl" 236 (list) (lambda () 1)))
  (define tesl-checked-24 (checkBothProofs n1))
  (when (check-fail? tesl-checked-24)
    (raise-user-error 'tesl-test "unexpected failure in let v1: ~a" (check-fail-message tesl-checked-24)))
  (define v1 tesl-checked-24)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 238 (list (cons 'v1 v1) (cons 'n1 n1)) (lambda () (useBothProofs v1)))) 3)
  (define n99 (thsl-src! "tests/critical-review-48-tests.tesl" 239 (list (cons 'v1 v1) (cons 'n1 n1)) (lambda () 99)))
  (define tesl-checked-25 (checkBothProofs n99))
  (when (check-fail? tesl-checked-25)
    (raise-user-error 'tesl-test "unexpected failure in let v99: ~a" (check-fail-message tesl-checked-25)))
  (define v99 tesl-checked-25)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 241 (list (cons 'v99 v99) (cons 'n99 n99) (cons 'v1 v1) (cons 'n1 n1)) (lambda () (useBothProofs v99)))) 297)
    ))
  )

  (test-case "R48-17: movement north slowly"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 277 (list) (lambda () (describeMovement (Moving North Slow))))) "moving north slowly")
    ))
  )

  (test-case "R48-18: movement east quickly"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 281 (list) (lambda () (describeMovement (Moving East Fast))))) "moving east quickly")
    ))
  )

  (test-case "R48-19: stopped"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 285 (list) (lambda () (describeMovement Stopped)))) "stopped")
    ))
  )

  (test-case "R48-20: all directions covered"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 289 (list) (lambda () (describeMovement (Moving South Fast))))) "moving south quickly")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 290 (list) (lambda () (describeMovement (Moving West Slow))))) "moving west slowly")
    ))
  )

  (test-case "R48-21: pipe chains apply left-to-right"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 307 (list) (lambda () (pipedAdd 3)))) 12)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 308 (list) (lambda () (pipedAdd 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 309 (list) (lambda () (pipedAdd 1)))) 4)
    ))
  )

  (test-case "R48-22: pipe with String.length"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 313 (list) (lambda () (pipedCheckLen "hello")))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 314 (list) (lambda () (pipedCheckLen "")))) 0)
    ))
  )

  (test-case "R48-23: multi-param fact passing"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 337 (list) (lambda () (testBetween 0 10 5)))) "5 in [0,10]")
    ))
  )

  (test-case "R48-24: multi-param fact boundary lo"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 341 (list) (lambda () (testBetween 10 20 10)))) "10 in [10,20]")
    ))
  )

  (test-case "R48-25: multi-param fact boundary hi"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 345 (list) (lambda () (testBetween 10 20 20)))) "20 in [10,20]")
    ))
  )

  (test-case "R48-26: multi-param fact below lo fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 349 (list) (lambda ()
                          ((testBetween 10 20 9) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testBetween 10 20 9) (list)"))
    ))
  )

  (test-case "R48-27: multi-param fact above hi fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 353 (list) (lambda ()
                          ((testBetween 10 20 21) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (testBetween 10 20 21) (list)"))
    ))
  )

  (test-case "R48-28: multi-param fact negative range"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 357 (list) (lambda () (testBetween -10 -1 -5)))) "-5 in [-10,-1]")
    ))
  )

  (test-case "R48-29: filterCheck combined proof on empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 371 (list) (lambda () (filterSmallPositive (list)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 372 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 0)
    ))
  )

  (test-case "R48-30: filterCheck combined proof on mixed list"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 376 (list) (lambda () (filterSmallPositive (list 1 -1 50 100 99 0)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 377 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "R48-31: allCheck returns Nothing on single failure"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 381 (list) (lambda () (smallPositiveAll (list 1 2 0 4)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 382 (list (cons 'result result)) (lambda () result))) Nothing)
    ))
  )

  (test-case "R48-32: allCheck returns Something on all pass"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 386 (list) (lambda () (smallPositiveAll (list 1 2 3 4 5)))))
  (check-not-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 387 (list (cons 'result result)) (lambda () result)) Nothing)
    ))
  )

  (test-case "R48-33: allCheck on empty list succeeds (vacuous truth)"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 391 (list) (lambda () (smallPositiveAll (list)))))
  (check-not-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 392 (list (cons 'result result)) (lambda () result)) Nothing)
    ))
  )

  (test-case "R48-34: complex interpolation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 405 (list) (lambda () (formatComplex 10 3)))) "sum=13, diff=7")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 406 (list) (lambda () (formatComplex 0 0)))) "sum=0, diff=0")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 407 (list) (lambda () (formatComplex -5 3)))) "sum=-2, diff=-8")
    ))
  )

  (test-case "R48-35: recursive ADT eval leaf"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 426 (list) (lambda () (evalExpr48 (LitF 42))))) 42)
    ))
  )

  (test-case "R48-36: recursive ADT eval add"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 430 (list) (lambda () (evalExpr48 (AddF (LitF 3) (LitF 4)))))) 7)
    ))
  )

  (test-case "R48-37: recursive ADT eval double neg"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 434 (list) (lambda () (evalExpr48 (NegF (NegF (LitF 5))))))) 5)
    ))
  )

  (test-case "R48-38: recursive ADT deeply nested"
    (call-with-fresh-memory-db '() (lambda ()
  (define e (thsl-src! "tests/critical-review-48-tests.tesl" 438 (list) (lambda () (raw-value (AddF (NegF (LitF 10)) (AddF (LitF 7) (LitF 3)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 439 (list (cons 'e e)) (lambda () (evalExpr48 e)))) 0)
    ))
  )

  (test-case "R48-39: nullary constructors pattern match"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 458 (list) (lambda () (describeStatus48 Active48)))) "active")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 459 (list) (lambda () (describeStatus48 Inactive48)))) "inactive")
    ))
  )

  (test-case "R48-40: constructor with field"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 463 (list) (lambda () (describeStatus48 (Suspended48 "policy violation"))))) "suspended: policy violation")
    ))
  )

  (test-case "R48-41: large multiplication"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 473 (list) (lambda () (largeMul 1000000 1000)))) 1000000000)
    ))
  )

  (test-case "R48-42: multiply by zero"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 477 (list) (lambda () (largeMul 999999 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 478 (list) (lambda () (largeMul 0 999999)))) 0)
    ))
  )

  (test-case "R48-43: negative multiplication"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 482 (list) (lambda () (largeMul -3 -4)))) 12)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 483 (list) (lambda () (largeMul -3 4)))) -12)
    ))
  )

  (test-case "R48-44: proof in case Something branch"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 498 (list) (lambda () (resultFromCase48 (raw-value (Something 5)))))) 10)
    ))
  )

  (test-case "R48-45: Nothing branch returns 0"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 502 (list) (lambda () (resultFromCase48 Nothing)))) 0)
    ))
  )

  (test-case "R48-46: case Something with 0 fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 506 (list) (lambda ()
                          (resultFromCase48 (raw-value (Something 0))))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: resultFromCase48 (raw-value (Something 0))"))
    ))
  )

  (test-case "R48-47: closure captures outer variable"
    (call-with-fresh-memory-db '() (lambda ()
  (define add5 (thsl-src! "tests/critical-review-48-tests.tesl" 520 (list) (lambda () (makeAdder 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 521 (list (cons 'add5 add5)) (lambda () (add5 10)))) 15)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 522 (list (cons 'add5 add5)) (lambda () (add5 0)))) 5)
    ))
  )

  (test-case "R48-48: applyTwice with closure"
    (call-with-fresh-memory-db '() (lambda ()
  (define add3 (thsl-src! "tests/critical-review-48-tests.tesl" 526 (list) (lambda () (makeAdder 3))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 527 (list (cons 'add3 add3)) (lambda () (applyTwice add3 10)))) 16)
    ))
  )

  (test-case "R48-49: applyTwice with inline lambda"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 531 (list) (lambda () (applyTwice (let () (define/pow (tesl-lambda-26 [x : Integer]) #:returns Integer (* *x 2)) tesl-lambda-26) 3)))) 12)
    ))
  )

  (test-case "R48-50: fall-through Critical48 -> urgent"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 555 (list) (lambda () (priorityLabel Critical48)))) "urgent")
    ))
  )

  (test-case "R48-51: fall-through High48 -> urgent"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 559 (list) (lambda () (priorityLabel High48)))) "urgent")
    ))
  )

  (test-case "R48-52: Medium48 -> normal"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 563 (list) (lambda () (priorityLabel Medium48)))) "normal")
    ))
  )

  (test-case "R48-53: Low48 -> low"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 567 (list) (lambda () (priorityLabel Low48)))) "low")
    ))
  )

  (test-case "R48-54: literal patterns match exactly"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 584 (list) (lambda () (httpStatus 200)))) "OK")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 585 (list) (lambda () (httpStatus 201)))) "Created")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 586 (list) (lambda () (httpStatus 404)))) "Not Found")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 587 (list) (lambda () (httpStatus 500)))) "Internal Server Error")
    ))
  )

  (test-case "R48-55: literal patterns wildcard fallback"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 591 (list) (lambda () (httpStatus 301)))) "Unknown")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 592 (list) (lambda () (httpStatus 0)))) "Unknown")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 593 (list) (lambda () (httpStatus -1)))) "Unknown")
    ))
  )

  (test-case "R48-56: wrap and unwrap list of newtypes"
    (call-with-fresh-memory-db '() (lambda ()
  (define wrapped (thsl-src! "tests/critical-review-48-tests.tesl" 607 (list) (lambda () (wrapAll (list 1 2 3)))))
  (define unwrapped (thsl-src! "tests/critical-review-48-tests.tesl" 608 (list (cons 'wrapped wrapped)) (lambda () (unwrapAll wrapped))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 609 (list (cons 'unwrapped unwrapped) (cons 'wrapped wrapped)) (lambda () (raw-value (tesl_import_List_length (raw-value unwrapped)))))) 3)
    ))
  )

  (test-case "R48-57: wrap empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (define wrapped (thsl-src! "tests/critical-review-48-tests.tesl" 613 (list) (lambda () (wrapAll (list)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 614 (list (cons 'wrapped wrapped)) (lambda () (raw-value (tesl_import_List_length (raw-value wrapped)))))) 0)
    ))
  )

  (test-case "R48-58: establish proof via attach"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 639 (list) (lambda () (tryListen 80)))) "port 80")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 640 (list) (lambda () (tryListen 443)))) "port 443")
    ))
  )

  (test-case "R48-59: establish returns Nothing for invalid"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 644 (list) (lambda () (tryListen 0)))) "invalid port")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 645 (list) (lambda () (tryListen -1)))) "invalid port")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 646 (list) (lambda () (tryListen 65536)))) "invalid port")
    ))
  )

  (test-case "R48-60: establish boundary values"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 650 (list) (lambda () (tryListen 1)))) "port 1")
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 651 (list) (lambda () (tryListen 65535)))) "port 65535")
    ))
  )

  (test-case "R48-61: record field carries proof"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawTitle (thsl-src! "tests/critical-review-48-tests.tesl" 677 (list) (lambda () "my item")))
  (define tesl-checked-27 (checkTitle48 rawTitle))
  (when (check-fail? tesl-checked-27)
    (raise-user-error 'tesl-test "unexpected failure in let validTitle: ~a" (check-fail-message tesl-checked-27)))
  (define validTitle tesl-checked-27)
  (define item (thsl-src! "tests/critical-review-48-tests.tesl" 679 (list (cons 'validTitle validTitle) (cons 'rawTitle rawTitle)) (lambda () (SafeItem48 #:title validTitle))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 680 (list (cons 'item item) (cons 'validTitle validTitle) (cons 'rawTitle rawTitle)) (lambda () (readSafeField item)))) 7)
    ))
  )

  (test-case "R48-62: record field proof on boundary length"
    (call-with-fresh-memory-db '() (lambda ()
  (define rawTitle (thsl-src! "tests/critical-review-48-tests.tesl" 684 (list) (lambda () "x")))
  (define tesl-checked-28 (checkTitle48 rawTitle))
  (when (check-fail? tesl-checked-28)
    (raise-user-error 'tesl-test "unexpected failure in let validTitle: ~a" (check-fail-message tesl-checked-28)))
  (define validTitle tesl-checked-28)
  (define item (thsl-src! "tests/critical-review-48-tests.tesl" 686 (list (cons 'validTitle validTitle) (cons 'rawTitle rawTitle)) (lambda () (SafeItem48 #:title validTitle))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 687 (list (cons 'item item) (cons 'validTitle validTitle) (cons 'rawTitle rawTitle)) (lambda () (readSafeField item)))) 1)
    ))
  )

  (test-case "R48-63: ghost witness allows construction"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 715 (list) (lambda () (makeOrderedPair 1 10))))
  (check-not-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 716 (list (cons 'result result)) (lambda () result)) Nothing)
    ))
  )

  (test-case "R48-64: ghost witness rejects wrong order"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 720 (list) (lambda () (makeOrderedPair 10 1))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 721 (list (cons 'result result)) (lambda () result))) Nothing)
    ))
  )

  (test-case "R48-65: ghost witness accepts equal values"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-48-tests.tesl" 725 (list) (lambda () (makeOrderedPair 5 5))))
  (check-not-equal? (thsl-src! "tests/critical-review-48-tests.tesl" 726 (list (cons 'result result)) (lambda () result)) Nothing)
    ))
  )

  (test-case "R48-66: property - positive check consistent"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: positive check succeeds for positive ints
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) 0) (< (raw-value n) 10000)) (check-true (let/check ([tesl-checked-29 (checkPositive48 n)]) (let ([v tesl-checked-29]) (> (raw-value (requiresPositive48 v)) 0))) "positive check succeeds for positive ints"))
    ))
    ))
  )

  (test-case "R48-67: property - string length non-negative"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: string length is never negative
  (for ([tesl-prop-i (in-range 100)])
    (let ([s (format "s~a" (random 1000000))])
      (check-true (>= (raw-value (tesl_import_String_length (raw-value s))) 0) "string length is never negative")
    ))
    ))
  )

  (test-case "R48-68: property - double neg is identity"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: negating twice returns original
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) -10000) (< (raw-value n) 10000)) (check-true (tesl-equal? (- 0 (- 0 (raw-value n))) (raw-value n)) "negating twice returns original"))
    ))
    ))
  )

  (test-case "R48-69: proof-total List.take"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 773 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (safeTake48 (list 1 2 3 4 5) 3))))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 774 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (safeTake48 (list 1 2 3) 0))))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 775 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (safeTake48 (list) 5))))))) 0)
    ))
  )

  (test-case "R48-70: proof-total List.take rejects negative"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 779 (list) (lambda ()
                          ((safeTake48 (list 1 2 3) -1) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeTake48 (list 1 2 3) -1) (list)"))
    ))
  )

  (test-case "R48-71: proof-total Int.divide"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 783 (list) (lambda () (safeDivide48 10 3)))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 784 (list) (lambda () (safeDivide48 -10 3)))) -3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 785 (list) (lambda () (safeDivide48 0 5)))) 0)
    ))
  )

  (test-case "R48-72: proof-total Int.divide rejects zero"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-48-tests.tesl" 789 (list) (lambda ()
                          ((safeDivide48 10 0) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (safeDivide48 10 0) (list)"))
    ))
  )

  (test-case "R48-73: List.reverse"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 797 (list) (lambda () (tesl_import_List_reverse (list 1 2 3))))) (list 3 2 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 798 (list) (lambda () (tesl_import_List_reverse (list))))) (list))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 799 (list) (lambda () (tesl_import_List_reverse (list 42))))) (list 42))
    ))
  )

  (test-case "R48-74: List.append"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 803 (list) (lambda () (tesl_import_List_append (list 1 2) (list 3 4))))) (list 1 2 3 4))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 804 (list) (lambda () (tesl_import_List_append (list) (list 1))))) (list 1))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 805 (list) (lambda () (tesl_import_List_append (list 1) (list))))) (list 1))
    ))
  )

  (test-case "R48-75: forgetFact then re-check"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 819 (list) (lambda () (forgetAndRecheck 5)))) 10)
    ))
  )

  (test-case "R48-76: forgetFact on boundary"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-48-tests.tesl" 823 (list) (lambda () (forgetAndRecheck 1)))) 2)
    ))
  )

)
