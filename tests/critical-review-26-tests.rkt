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
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.contains tesl_import_String_contains] [String.isEmpty tesl_import_String_isEmpty])
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.filterCheck tesl_import_List_filterCheck] [List.allCheck tesl_import_List_allCheck] [List.length tesl_import_List_length] [List.foldl tesl_import_List_foldl] [List.filter tesl_import_List_filter] [List.head tesl_import_List_head] IsSorted)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/int IsNonZero IsNonNegative)
  (only-in tesl/tesl/float Float [Float.requireNonZero tesl_import_Float_requireNonZero] FloatNonZero [Float.div tesl_import_Float_div] [Float.isPositive tesl_import_Float_isPositive] [Float.sqrt tesl_import_Float_sqrt] [Float.abs tesl_import_Float_abs])
  (only-in tesl/tesl/result Result Ok Err)
)


(provide vacuousForAll requiresPositiveA proofFromA allNonNeg forgetDoesNotRetarget evalExpr makeMyInt myIntVal myIntGt myIntSort checkB4 checkC4 checkD4 requiresABCD mapDoesNotProve addThreePartial describeStatus3 isOdd2 checkEmail2 requiresEmail2 checkSmallN checkPosAndSmall2 aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly checkSafeRecord requiresSafeRecord treeSum checkInRange3 requiresInRange3 vacuousForAll-signature requiresPositiveA-signature proofFromA-signature allNonNeg-signature forgetDoesNotRetarget-signature evalExpr-signature makeMyInt-signature myIntVal-signature myIntGt-signature myIntSort-signature checkB4-signature checkC4-signature checkD4-signature requiresABCD-signature mapDoesNotProve-signature addThreePartial-signature describeStatus3-signature isOdd2-signature checkEmail2-signature requiresEmail2-signature checkSmallN-signature checkPosAndSmall2-signature aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly-signature checkSafeRecord-signature requiresSafeRecord-signature treeSum-signature checkInRange3-signature requiresInRange3-signature)

(define EvenFact 'EvenFact)
(define FactA 'FactA)
(define FactB 'FactB)
(define FactC 'FactC)
(define FactD 'FactD)
(define InRange3 'InRange3)
(define NonNeg 'NonNeg)
(define PosC 'PosC)
(define Positive1 'Positive1)
(define PositiveA 'PositiveA)
(define SafeTitle 'SafeTitle)
(define SmallC 'SmallC)
(define ValidEmail 'ValidEmail)
(define ValidName 'ValidName)

(define-checker
  (checkPositive1 [n : Integer])
  #:returns [n : Integer ::: (Positive1 n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 107 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (Positive1 n) #:value *n) (reject "must be positive" #:http-code 400)))))

(define/pow
  (filterAlwaysFails [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-26-tests.tesl" 114 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive1 *xs))))

(define/pow
  (vacuousForAll)
  #:returns Integer
  (let ([result (thsl-src! "tests/critical-review-26-tests.tesl" 117 (list) (lambda () (filterAlwaysFails (list -1 -2 -3))))]) (thsl-src! "tests/critical-review-26-tests.tesl" 118 (list (cons 'result *result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))))

(define-checker
  (checkPositiveA [n : Integer])
  #:returns [n : Integer ::: (PositiveA n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 149 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (PositiveA n) #:value *n) (reject "must be > 0" #:http-code 400)))))

(define/pow
  (requiresPositiveA [n : Integer ::: (PositiveA n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 154 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (proofFromA [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 158 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-0 (checkPositiveA a)]) (let ([va tesl-checked-0]) (let/check ([tesl-checked-1 (checkPositiveA b)]) (let ([vb tesl-checked-1]) (+ (raw-value (requiresPositiveA va)) (raw-value (requiresPositiveA vb))))))))))

(define-checker
  (checkNonNeg [n : Integer])
  #:returns [n : Integer ::: (NonNeg n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 190 (list (cons 'n *n)) (lambda () (if (>= *n 0) (accept (NonNeg n) #:value *n) (reject "must be >= 0" #:http-code 400)))))

(define/pow
  (allNonNeg [xs : (List Integer)])
  #:returns (Maybe (List Integer))
  (thsl-src! "tests/critical-review-26-tests.tesl" 196 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck checkNonNeg *xs))))

(define/pow
  (allNonNegPasses [xs : (List Integer)])
  #:returns Boolean
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 199 (list (cons 'xs *xs)) (lambda () (let ([tesl-case-2 (raw-value (allNonNeg xs))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (thsl-src! "tests/critical-review-26-tests.tesl" 200 (list) (lambda () (raw-value #t)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/critical-review-26-tests.tesl" 201 (list) (lambda () (raw-value #f)))])))))

(define/pow
  (allNonNegCount [xs : (List Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 204 (list (cons 'xs *xs)) (lambda () (let ([tesl-case-3 (raw-value (allNonNeg xs))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/critical-review-26-tests.tesl" 205 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([ys (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/critical-review-26-tests.tesl" 206 (list (cons 'ys ys)) (lambda () (raw-value (raw-value (tesl_import_List_length *ys))))))])))))

(define/pow
  (forgetAndCheck [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 235 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-4 (checkPositiveA n)]) (let ([validated tesl-checked-4]) (let ([raw (forget-proof validated)]) (let/check ([tesl-checked-5 (checkPositiveA raw)]) (let ([revalidated tesl-checked-5]) (raw-value (requiresPositiveA revalidated))))))))))

(define/pow
  (forgetDoesNotRetarget [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 242 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-6 (checkPositiveA n)]) (let ([validated tesl-checked-6]) (let ([raw (forget-proof validated)]) (let/check ([tesl-checked-7 (checkPositiveA raw)]) (let ([revalidated tesl-checked-7]) (raw-value (requiresPositiveA revalidated))))))))))

(define-adt Expr
  [Lit [value : Integer]]
  [Add [left : Expr] [right : Expr]]
  [Mul [left : Expr] [right : Expr]]
  [Sub [left : Expr] [right : Expr]]
  [Negate [inner : Expr]]
)

(define/pow
  (evalExpr [e : Expr])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 273 (list (cons 'e *e)) (lambda () (let ([tesl-case-8 *e]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Lit)) (let ([value (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "tests/critical-review-26-tests.tesl" 274 (list (cons 'value value)) (lambda () *value)))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Add)) (let ([left (hash-ref (adt-value-fields *tesl-case-8) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl-case-8) 'right)]) (thsl-src! "tests/critical-review-26-tests.tesl" 275 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (+ (raw-value (evalExpr *left)) (raw-value (evalExpr *right))))))))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Mul)) (let ([left (hash-ref (adt-value-fields *tesl-case-8) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl-case-8) 'right)]) (thsl-src! "tests/critical-review-26-tests.tesl" 276 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (* (raw-value (evalExpr *left)) (raw-value (evalExpr *right))))))))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Sub)) (let ([left (hash-ref (adt-value-fields *tesl-case-8) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl-case-8) 'right)]) (thsl-src! "tests/critical-review-26-tests.tesl" 277 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (- (raw-value (evalExpr *left)) (raw-value (evalExpr *right))))))))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Negate)) (let ([inner (hash-ref (adt-value-fields *tesl-case-8) 'inner)]) (thsl-src! "tests/critical-review-26-tests.tesl" 278 (list (cons 'inner inner)) (lambda () (raw-value (- 0 (raw-value (evalExpr *inner)))))))])))))

(define-adt MyInt
  [MkMyInt [inner : Integer]]
)

(define/pow
  (makeMyInt [n : Integer])
  #:returns MyInt
  (thsl-src! "tests/critical-review-26-tests.tesl" 321 (list (cons 'n *n)) (lambda () (raw-value (MkMyInt *n)))))

(define/pow
  (myIntVal [a : MyInt])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 324 (list (cons 'a *a)) (lambda () (let ([tesl-case-9 *a]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'MkMyInt)) (let ([inner (hash-ref (adt-value-fields *tesl-case-9) 'inner)]) (thsl-src! "tests/critical-review-26-tests.tesl" 325 (list (cons 'inner inner)) (lambda () *inner)))])))))

(define/pow
  (myIntGt [a : MyInt] [b : MyInt])
  #:returns Boolean
  (thsl-src! "tests/critical-review-26-tests.tesl" 328 (list (cons 'a *a) (cons 'b *b)) (lambda () (> (raw-value (myIntVal a)) (raw-value (myIntVal b))))))

(define/pow
  (myIntSort [a : MyInt] [b : MyInt] [c : MyInt])
  #:returns MyInt
  (let ([av (thsl-src! "tests/critical-review-26-tests.tesl" 331 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (myIntVal a)))]) (let ([bv (thsl-src! "tests/critical-review-26-tests.tesl" 332 (list (cons 'av *av) (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (myIntVal b)))]) (let ([cv (thsl-src! "tests/critical-review-26-tests.tesl" 333 (list (cons 'bv *bv) (cons 'av *av) (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (myIntVal c)))]) (thsl-src! "tests/critical-review-26-tests.tesl" 334 (list (cons 'cv *cv) (cons 'bv *bv) (cons 'av *av) (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (if (and (<= (raw-value av) (raw-value bv)) (<= (raw-value bv) (raw-value cv))) *b (if (and (<= (raw-value av) (raw-value cv)) (<= (raw-value cv) (raw-value bv))) *c *a))))))))

(define-checker
  (checkA4 [n : Integer])
  #:returns [n : Integer ::: (FactA n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 373 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (FactA n) #:value *n) (reject "FactA" #:http-code 400)))))

(define-checker
  (checkB4 [n : Integer])
  #:returns [n : Integer ::: (FactB n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 379 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (FactB n) #:value *n) (reject "FactB" #:http-code 400)))))

(define-checker
  (checkC4 [n : Integer])
  #:returns [n : Integer ::: (FactC n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 385 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 13)) (accept (FactC n) #:value *n) (reject "FactC: 13 is unlucky" #:http-code 400)))))

(define-checker
  (checkD4 [n : Integer])
  #:returns [n : Integer ::: (FactD n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 391 (list (cons 'n *n)) (lambda () (if (tesl-equal? (remainder *n 2) 0) (accept (FactD n) #:value *n) (reject "FactD: must be even" #:http-code 400)))))

(define/pow
  (requiresABCD [n : Integer ::: ((FactA n) && ((FactB n) && ((FactC n) && (FactD n))))])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 397 (list (cons 'n *n)) (lambda () (format "ok: ~a" (tesl-display-val *n)))))

(define-checker
  (checkAll4 [n : Integer])
  #:returns [n : Integer ::: ((FactA n) && ((FactB n) && ((FactC n) && (FactD n))))]
  (thsl-src! "tests/critical-review-26-tests.tesl" 404 (list (cons 'n *n)) (lambda () (if (> *n 0) (if (< *n 100) (if (not (tesl-equal? *n 13)) (if (tesl-equal? (remainder *n 2) 0) (accept ((FactA n) && ((FactB n) && ((FactC n) && (FactD n)))) #:value *n) (reject "FactD: must be even" #:http-code 400)) (reject "FactC: 13 is unlucky" #:http-code 400)) (reject "FactB: must be < 100" #:http-code 400)) (reject "FactA: must be > 0" #:http-code 400)))))

(define/pow
  (useAll4 [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 419 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-10 (checkAll4 n)]) (let ([v tesl-checked-10]) (raw-value (requiresABCD v)))))))

(define/pow
  (doubleList [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-26-tests.tesl" 452 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-11 [n : Integer]) #:returns Integer (* *n 2)) tesl-lambda-11) *xs)))))

(define/pow
  (mapDoesNotProve [xs : (List Integer)])
  #:returns Integer
  (let ([doubled (thsl-src! "tests/critical-review-26-tests.tesl" 455 (list (cons 'xs *xs)) (lambda () (doubleList xs)))]) (thsl-src! "tests/critical-review-26-tests.tesl" 456 (list (cons 'doubled *doubled) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled)))))))

(define/pow
  (addThree [a : Integer] [b : Integer] [c : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 481 (list (cons 'a *a) (cons 'b *b) (cons 'c *c)) (lambda () (+ (+ *a *b) *c))))

(define/pow
  (addThreePartial [a : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 487 (list (cons 'a *a)) (lambda () (raw-value (addThree a 10 1)))))

(define/pow
  (intEdge [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 506 (list (cons 'n *n)) (lambda () (if (> *n 0) (raw-value 1) (if (< *n 0) (raw-value -1) (raw-value 0))))))

(define-checker
  (checkValidName [s : String])
  #:returns [s : String ::: (ValidName s)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 546 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 2) (<= (raw-value (tesl_import_String_length *s)) 50)) (accept (ValidName s) #:value *s) (reject "name must be 2-50 chars" #:http-code 400)))))

(define/pow
  (describeProven [s : String ::: (ValidName s)])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 552 (list (cons 's *s)) (lambda () (format "Hello, ~a!" (tesl-display-val *s)))))

(define/pow
  (describeViaCheck [raw : String])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 555 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-12 (checkValidName raw)]) (let ([validated tesl-checked-12]) (raw-value (describeProven validated)))))))

(define-adt Status3
  [Active]
  [Inactive]
  [Suspended [reason : String]]
)

(define/pow
  (describeStatus3 [s : Status3])
  #:returns String
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 584 (list (cons 's *s)) (lambda () (let ([tesl-case-13 *s]) (cond [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Active)) (thsl-src! "tests/critical-review-26-tests.tesl" 585 (list) (lambda () (raw-value "active")))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Inactive)) (thsl-src! "tests/critical-review-26-tests.tesl" 586 (list) (lambda () (raw-value "inactive")))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Suspended)) (let ([reason (hash-ref (adt-value-fields *tesl-case-13) 'reason)]) (thsl-src! "tests/critical-review-26-tests.tesl" 587 (list (cons 'reason reason)) (lambda () (raw-value (format "suspended: ~a" (tesl-display-val *reason))))))])))))

(define/pow
  (strictBatch [xs : (List Integer)])
  #:returns Integer
  (let ([result (thsl-src! "tests/critical-review-26-tests.tesl" 611 (list (cons 'xs *xs)) (lambda () (tesl_import_List_allCheck checkNonNeg *xs)))]) (thsl-src-control! "tests/critical-review-26-tests.tesl" 612 (list (cons 'result *result) (cons 'xs *xs)) (lambda () (let ([tesl-case-14 (raw-value result)]) (cond [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Nothing)) (thsl-src! "tests/critical-review-26-tests.tesl" 613 (list) (lambda () (raw-value -1)))] [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Something)) (thsl-src! "tests/critical-review-26-tests.tesl" 614 (list) (lambda () (raw-value 1)))]))))))

(define/pow
  (floatEdge [f : Real])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 645 (list (cons 'f *f)) (lambda () (if (raw-value (tesl_import_Float_isPositive *f)) (raw-value "positive") (raw-value "non-positive")))))

(define/pow
  (isEven2 [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review-26-tests.tesl" 684 (list (cons 'n *n)) (lambda () (if (tesl-equal? *n 0) (raw-value #t) (raw-value (isOdd2 (- *n 1)))))))

(define/pow
  (isOdd2 [n : Integer])
  #:returns Boolean
  (thsl-src! "tests/critical-review-26-tests.tesl" 690 (list (cons 'n *n)) (lambda () (if (tesl-equal? *n 0) (raw-value #f) (raw-value (isEven2 (- *n 1)))))))

(define/pow
  (doubleAndFilter [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-26-tests.tesl" 725 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive1 *xs))))

(define/pow
  (countProven [xs : (List Integer)])
  #:returns Integer
  (let ([filtered (thsl-src! "tests/critical-review-26-tests.tesl" 728 (list (cons 'xs *xs)) (lambda () (doubleAndFilter xs)))]) (thsl-src! "tests/critical-review-26-tests.tesl" 729 (list (cons 'filtered *filtered) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length (raw-value filtered)))))))

(define/pow
  (roundTripProof [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 748 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-15 (checkPositiveA n)]) (let ([validated tesl-checked-15]) (let ([tesl-proof-binding-16 validated]) (let ([raw (forget-proof tesl-proof-binding-16)] [proof (detach-all-proof tesl-proof-binding-16)]) (let ([reattached (attach-proof raw proof)]) (raw-value (requiresPositiveA reattached))))))))))

(define-newtype Email String)

(define-checker
  (checkEmail2 [raw : String])
  #:returns [e : Email ::: (ValidEmail e)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 779 (list (cons 'raw *raw)) (lambda () (if (and (raw-value (tesl_import_String_contains *raw "@")) (>= (raw-value (tesl_import_String_length *raw)) 5)) (let ([e (raw-value (Email *raw))]) (accept (ValidEmail e) #:value *e)) (reject "invalid email" #:http-code 400)))))

(define/pow
  (requiresEmail2 [e : Email ::: (ValidEmail e)])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 786 (list (cons 'e *e)) (lambda () "email ok")))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (PosC n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 815 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (PosC n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmallN [n : Integer])
  #:returns [n : Integer ::: (SmallC n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 821 (list (cons 'n *n)) (lambda () (if (< *n 50) (accept (SmallC n) #:value *n) (reject "not small" #:http-code 400)))))

(define/pow
  (checkPosAndSmall2 [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 827 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-17 ((check-and checkPos checkSmallN) n)]) (let ([result tesl-checked-17]) (format "ok: ~a" (tesl-display-val *result)))))))

(define/pow
  (lookupWithDefault [items : (List Integer)] [target : Integer])
  #:returns Integer
  (let ([found (thsl-src! "tests/critical-review-26-tests.tesl" 860 (list (cons 'items *items) (cons 'target *target)) (lambda () (raw-value (tesl_import_List_head (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-18 [n : Integer]) #:returns Boolean (tesl-equal? *n *target)) tesl-lambda-18) *items))))))]) (thsl-src-control! "tests/critical-review-26-tests.tesl" 861 (list (cons 'found *found) (cons 'items *items) (cons 'target *target)) (lambda () (let ([tesl-case-19 (raw-value found)]) (cond [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Nothing)) (thsl-src! "tests/critical-review-26-tests.tesl" 862 (list) (lambda () (raw-value -999)))] [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Something)) (let ([val (hash-ref (adt-value-fields *tesl-case-19) 'value)]) (thsl-src! "tests/critical-review-26-tests.tesl" 863 (list (cons 'val val)) (lambda () *val)))]))))))

(define/pow
  (aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 887 (list (cons 'n *n)) (lambda () (+ *n 1))))

(define/pow
  (applyCheckToList [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-26-tests.tesl" 903 (list (cons 'xs *xs)) (lambda () (tesl_import_List_filterCheck checkPositive1 *xs))))

(define/pow
  (applyLambdaToFiltered [xs : (List Integer)])
  #:returns Integer
  (let ([filtered (thsl-src! "tests/critical-review-26-tests.tesl" 906 (list (cons 'xs *xs)) (lambda () (applyCheckToList xs)))]) (thsl-src! "tests/critical-review-26-tests.tesl" 907 (list (cons 'filtered *filtered) (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-20 [acc : Integer] [n : Integer]) #:returns Integer (+ *acc *n)) tesl-lambda-20) 0 (raw-value filtered)))))))

(define-checker
  (checkSafeTitle [s : String])
  #:returns [s : String ::: (SafeTitle s)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 929 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 3) (<= (raw-value (tesl_import_String_length *s)) 100)) (accept (SafeTitle s) #:value *s) (reject "title must be 3-100 chars" #:http-code 400)))))

(define-record SafeRecord
  [title : String ::: (SafeTitle title)]
)

(define/pow
  (checkSafeRecord [raw : String])
  #:returns SafeRecord
  (thsl-src! "tests/critical-review-26-tests.tesl" 939 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-21 (checkSafeTitle raw)]) (let ([t tesl-checked-21]) (SafeRecord #:title t))))))

(define/pow
  (requiresSafeRecord [r : SafeRecord])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 943 (list (cons 'r *r)) (lambda () (tesl-dot/runtime r 'title))))

(define/pow
  (parsePositiveInt [s : String])
  #:returns (Result Integer String)
  (thsl-src! "tests/critical-review-26-tests.tesl" 964 (list (cons 's *s)) (lambda () (if (tesl_import_String_isEmpty *s) (raw-value (raw-value (Err "empty input"))) (let ([n (tesl_import_String_length *s)]) (if (> (raw-value n) 3) (raw-value (raw-value (Err "too long to be an int"))) (raw-value (raw-value (Ok (raw-value n))))))))))

(define/pow
  (parseIntOk [s : String])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 974 (list (cons 's *s)) (lambda () (let ([tesl-case-22 (raw-value (parsePositiveInt s))]) (cond [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Ok)) (let ([n (hash-ref (adt-value-fields *tesl-case-22) 'value)]) (thsl-src! "tests/critical-review-26-tests.tesl" 975 (list (cons 'n n)) (lambda () *n)))] [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Err)) (thsl-src! "tests/critical-review-26-tests.tesl" 976 (list) (lambda () (raw-value -1)))])))))

(define/pow
  (parseIntErr [s : String])
  #:returns Boolean
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 979 (list (cons 's *s)) (lambda () (let ([tesl-case-23 (raw-value (parsePositiveInt s))]) (cond [(and (adt-value? *tesl-case-23) (eq? (adt-value-variant *tesl-case-23) 'Err)) (thsl-src! "tests/critical-review-26-tests.tesl" 980 (list) (lambda () (raw-value #t)))] [(and (adt-value? *tesl-case-23) (eq? (adt-value-variant *tesl-case-23) 'Ok)) (thsl-src! "tests/critical-review-26-tests.tesl" 981 (list) (lambda () (raw-value #f)))])))))

(define/pow
  (forgetOnlyLeft [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 1005 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-24 (checkPositiveA n)]) (let ([validated tesl-checked-24]) (let ([tesl-proof-binding-25 validated]) (let ([_ (forget-proof tesl-proof-binding-25)] [proof (detach-all-proof tesl-proof-binding-25)]) (let ([fresh n]) (let ([reattached (attach-proof fresh proof)]) (raw-value (requiresPositiveA reattached)))))))))))

(define-trusted
  (establishEven [n : Integer])
  #:returns (Maybe (Fact (EvenFact n)))
  (thsl-src! "tests/critical-review-26-tests.tesl" 1030 (list (cons 'n *n)) (lambda () (if (tesl-equal? (remainder *n 2) 0) (Something (trusted-proof (EvenFact n))) Nothing))))

(define/pow
  (requiresEven [n : Integer ::: (EvenFact n)])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 1035 (list (cons 'n *n)) (lambda () (format "even: ~a" (tesl-display-val *n)))))

(define/pow
  (checkOrEstablish [n : Integer])
  #:returns String
  (let ([mProof (thsl-src! "tests/critical-review-26-tests.tesl" 1038 (list (cons 'n *n)) (lambda () (establishEven n)))]) (thsl-src-control! "tests/critical-review-26-tests.tesl" 1039 (list (cons 'mProof *mProof) (cons 'n *n)) (lambda () (let ([tesl-case-26 (raw-value mProof)]) (cond [(and (adt-value? *tesl-case-26) (eq? (adt-value-variant *tesl-case-26) 'Nothing)) (thsl-src! "tests/critical-review-26-tests.tesl" 1040 (list) (lambda () (raw-value "not even")))] [(and (adt-value? *tesl-case-26) (eq? (adt-value-variant *tesl-case-26) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl-case-26) 'value)]) (thsl-src! "tests/critical-review-26-tests.tesl" 1041 (list (cons 'p p)) (lambda () (raw-value (requiresEven (attach-proof n p))))))]))))))

(define-adt Wrapper
  [Wrap [value : Integer]]
  [Empty]
)

(define/pow
  (guardedProof [w : Wrapper] [threshold : Integer])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 1069 (list (cons 'w *w) (cons 'threshold *threshold)) (lambda () (let ([tesl-case-27 *w]) (cond [(and (adt-value? *tesl-case-27) (eq? (adt-value-variant *tesl-case-27) 'Empty)) (thsl-src! "tests/critical-review-26-tests.tesl" 1070 (list) (lambda () (raw-value -1)))] [(and (and (adt-value? *tesl-case-27) (eq? (adt-value-variant *tesl-case-27) 'Wrap)) (let ([value (hash-ref (adt-value-fields *tesl-case-27) 'value)]) (> *value *threshold))) (let ([value (hash-ref (adt-value-fields *tesl-case-27) 'value)]) (thsl-src! "tests/critical-review-26-tests.tesl" 1071 (list (cons 'value value)) (lambda () *value)))] [(and (adt-value? *tesl-case-27) (eq? (adt-value-variant *tesl-case-27) 'Wrap)) (thsl-src! "tests/critical-review-26-tests.tesl" 1072 (list) (lambda () (raw-value 0)))])))))

(define-adt MathTree
  [Leaf [value : Integer]]
  [Branch [left : MathTree] [right : MathTree]]
)

(define/pow
  (treeSum [t : MathTree])
  #:returns Integer
  (thsl-src-control! "tests/critical-review-26-tests.tesl" 1104 (list (cons 't *t)) (lambda () (let ([tesl-case-28 *t]) (cond [(and (adt-value? *tesl-case-28) (eq? (adt-value-variant *tesl-case-28) 'Leaf)) (let ([value (hash-ref (adt-value-fields *tesl-case-28) 'value)]) (thsl-src! "tests/critical-review-26-tests.tesl" 1105 (list (cons 'value value)) (lambda () *value)))] [(and (adt-value? *tesl-case-28) (eq? (adt-value-variant *tesl-case-28) 'Branch)) (let ([left (hash-ref (adt-value-fields *tesl-case-28) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl-case-28) 'right)]) (thsl-src! "tests/critical-review-26-tests.tesl" 1106 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (+ (raw-value (treeSum *left)) (raw-value (treeSum *right))))))))])))))

(define-checker
  (checkInRange3 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange3 lo hi n)]
  (thsl-src! "tests/critical-review-26-tests.tesl" 1145 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (<= *lo *n) (<= *n *hi)) (accept (InRange3 lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define/pow
  (requiresInRange3 [lo : Integer] [hi : Integer] [n : Integer ::: (InRange3 lo hi n)])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 1151 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (format "~a in [~a, ~a]" (tesl-display-val *n) (tesl-display-val *lo) (tesl-display-val *hi)))))

(define/pow
  (useInRange3 [lo : Integer] [hi : Integer] [n : Integer])
  #:returns String
  (thsl-src! "tests/critical-review-26-tests.tesl" 1154 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (let/check ([tesl-checked-29 (checkInRange3 lo hi n)]) (let ([v tesl-checked-29]) (raw-value (requiresInRange3 lo hi v)))))))

(define/pow
  (discardBothHalves [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-26-tests.tesl" 1194 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-30 (checkPositiveA n)]) (let ([validated tesl-checked-30]) (let ([_ validated]) (+ *n 1)))))))

(module+ test
  (require rackunit)
  (test-case "T1a: filter of all-negative list yields empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 121 (list) (lambda () (vacuousForAll)))) 0)
    ))
  )

  (test-case "T1b: filter of empty input yields empty ForAll list"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-26-tests.tesl" 125 (list) (lambda () (filterAlwaysFails (list)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 126 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 0)
    ))
  )

  (test-case "T1c: filter of all-positive list yields full list"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-26-tests.tesl" 130 (list) (lambda () (filterAlwaysFails (list 1 2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 131 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "T1d: mixed list: only positives pass"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-26-tests.tesl" 135 (list) (lambda () (filterAlwaysFails (list 1 -1 2 -2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 136 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "T2a: both values positive \226\128\148 independent proofs"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 163 (list) (lambda () (proofFromA 3 5)))) 16)
    ))
  )

  (test-case "T2b: first value fails \226\128\148 check propagates failure"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 167 (list) (lambda ()
                          (proofFromA 0 5))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofFromA 0 5"))
    ))
  )

  (test-case "T2c: second value fails \226\128\148 check propagates failure"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 171 (list) (lambda ()
                          (proofFromA 3 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofFromA 3 0"))
    ))
  )

  (test-case "T2d: both fail"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 175 (list) (lambda ()
                          (proofFromA -1 -2))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofFromA -1 -2"))
    ))
  )

  (test-case "T2e: zero is not positive"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 179 (list) (lambda ()
                          (proofFromA 0 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: proofFromA 0 0"))
    ))
  )

  (test-case "T3a: all non-negative passes"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 209 (list) (lambda () (allNonNegPasses (list 0 1 2 3))))) #t)
    ))
  )

  (test-case "T3b: one negative causes whole batch to fail"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 213 (list) (lambda () (allNonNegPasses (list 1 2 -1 4))))) #f)
    ))
  )

  (test-case "T3c: empty list always passes allCheck"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 217 (list) (lambda () (allNonNegPasses (list))))) #t)
    ))
  )

  (test-case "T3d: single failing element returns Nothing"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 221 (list) (lambda () (allNonNegPasses (list -1))))) #f)
    ))
  )

  (test-case "T3e: cardinality preserved \226\128\148 allCheck on [2,4,6] returns 3 elements"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 225 (list) (lambda () (allNonNegCount (list 2 4 6))))) 3)
    ))
  )

  (test-case "T4a: forgetFact then re-validate positive number"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 249 (list) (lambda () (forgetAndCheck 5)))) 10)
    ))
  )

  (test-case "T4b: forgetFact then re-validate: fails for non-positive"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 253 (list) (lambda ()
                          (forgetAndCheck 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: forgetAndCheck 0"))
    ))
  )

  (test-case "T4c: forgetFact returns same value (not zero/default)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 257 (list) (lambda () (forgetAndCheck 7)))) 14)
    ))
  )

  (test-case "T5a: literal"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 281 (list) (lambda () (evalExpr (Lit 42))))) 42)
    ))
  )

  (test-case "T5b: add"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 285 (list) (lambda () (evalExpr (Add (Lit 3) (Lit 4)))))) 7)
    ))
  )

  (test-case "T5c: double negate"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 289 (list) (lambda () (evalExpr (Negate (Negate (Lit 5))))))) 5)
    ))
  )

  (test-case "T5d: (2 + 3) * (4 - 1)"
    (call-with-fresh-memory-db '() (lambda ()
  (define e (thsl-src! "tests/critical-review-26-tests.tesl" 293 (list) (lambda () (raw-value (Mul (Add (Lit 2) (Lit 3)) (Sub (Lit 4) (Lit 1)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 294 (list (cons 'e e)) (lambda () (evalExpr e)))) 15)
    ))
  )

  (test-case "T5e: deeply nested: ((1+2)*3 - (4-5))"
    (call-with-fresh-memory-db '() (lambda ()
  (define inner (thsl-src! "tests/critical-review-26-tests.tesl" 298 (list) (lambda () (raw-value (Sub (Mul (Add (Lit 1) (Lit 2)) (Lit 3)) (Sub (Lit 4) (Lit 5)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 299 (list (cons 'inner inner)) (lambda () (evalExpr inner)))) 10)
    ))
  )

  (test-case "T5f: negate of add"
    (call-with-fresh-memory-db '() (lambda ()
  (define e (thsl-src! "tests/critical-review-26-tests.tesl" 303 (list) (lambda () (raw-value (Negate (Add (Lit 10) (Lit 5)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 304 (list (cons 'e e)) (lambda () (evalExpr e)))) -15)
    ))
  )

  (test-case "T5g: multiply by zero short-circuits to zero"
    (call-with-fresh-memory-db '() (lambda ()
  (define e (thsl-src! "tests/critical-review-26-tests.tesl" 308 (list) (lambda () (raw-value (Mul (Lit 0) (Add (Lit 100) (Lit 200)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 309 (list (cons 'e e)) (lambda () (evalExpr e)))) 0)
    ))
  )

  (test-case "T6a: MyInt ordering: 5 > 3"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 343 (list) (lambda () (myIntGt (makeMyInt 5) (makeMyInt 3))))) #t)
    ))
  )

  (test-case "T6b: MyInt ordering: 3 not > 5"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 347 (list) (lambda () (myIntGt (makeMyInt 3) (makeMyInt 5))))) #f)
    ))
  )

  (test-case "T6c: MyInt ordering: equal"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 351 (list) (lambda () (myIntGt (makeMyInt 4) (makeMyInt 4))))) #f)
    ))
  )

  (test-case "T6d: median of three MyInt values"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 355 (list) (lambda () (myIntSort (makeMyInt 1) (makeMyInt 2) (makeMyInt 3))))) (makeMyInt 2))
    ))
  )

  (test-case "T6e: median with reverse order"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 359 (list) (lambda () (myIntSort (makeMyInt 3) (makeMyInt 2) (makeMyInt 1))))) (makeMyInt 3))
    ))
  )

  (test-case "T7a: 42 passes all four checks"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 423 (list) (lambda () (useAll4 42)))) "ok: 42")
    ))
  )

  (test-case "T7b: 0 fails FactA (not > 0)"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 427 (list) (lambda ()
                          (useAll4 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useAll4 0"))
    ))
  )

  (test-case "T7c: 100 fails FactB (not < 100)"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 431 (list) (lambda ()
                          (useAll4 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useAll4 100"))
    ))
  )

  (test-case "T7d: 13 fails FactC (unlucky)"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 435 (list) (lambda ()
                          (useAll4 13))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useAll4 13"))
    ))
  )

  (test-case "T7e: 3 fails FactD (not even)"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 439 (list) (lambda ()
                          (useAll4 3))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useAll4 3"))
    ))
  )

  (test-case "T7f: 2 passes all four checks"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 443 (list) (lambda () (useAll4 2)))) "ok: 2")
    ))
  )

  (test-case "T8a: map preserves length"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 459 (list) (lambda () (mapDoesNotProve (list 1 2 3))))) 3)
    ))
  )

  (test-case "T8b: map on empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 463 (list) (lambda () (mapDoesNotProve (list))))) 0)
    ))
  )

  (test-case "T8c: map doubles each element"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-26-tests.tesl" 467 (list) (lambda () (doubleList (list 1 2 3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 468 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "T8d: map on negative numbers"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "tests/critical-review-26-tests.tesl" 472 (list) (lambda () (doubleList (list -1 -2 -3)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 473 (list (cons 'result result)) (lambda () (raw-value (tesl_import_List_length (raw-value result)))))) 3)
    ))
  )

  (test-case "T9a: partial application: addThree 5 10 1 = 16"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 490 (list) (lambda () (addThreePartial 5)))) 16)
    ))
  )

  (test-case "T9b: partial application: addThree 0 10 1 = 11"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 494 (list) (lambda () (addThreePartial 0)))) 11)
    ))
  )

  (test-case "T9c: partial application: addThree -5 10 1 = 6"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 498 (list) (lambda () (addThreePartial -5)))) 6)
    ))
  )

  (test-case "T10a: zero is neither positive nor negative"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 515 (list) (lambda () (intEdge 0)))) 0)
    ))
  )

  (test-case "T10b: 1 is positive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 519 (list) (lambda () (intEdge 1)))) 1)
    ))
  )

  (test-case "T10c: -1 is negative"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 523 (list) (lambda () (intEdge -1)))) -1)
    ))
  )

  (test-case "T10d: very large positive number"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 527 (list) (lambda () (intEdge 999999999)))) 1)
    ))
  )

  (test-case "T10e: very large negative number"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 531 (list) (lambda () (intEdge -999999999)))) -1)
    ))
  )

  (test-case "T10f: min representable positive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 535 (list) (lambda () (intEdge 1)))) 1)
    ))
  )

  (test-case "T11a: interpolation unwraps proof-carrying string"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 559 (list) (lambda () (describeViaCheck "Alice")))) "Hello, Alice!")
    ))
  )

  (test-case "T11b: interpolation with multi-word name"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 563 (list) (lambda () (describeViaCheck "Bob Smith")))) "Hello, Bob Smith!")
    ))
  )

  (test-case "T11c: min-length name"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 567 (list) (lambda () (describeViaCheck "AB")))) "Hello, AB!")
    ))
  )

  (test-case "T11d: too-short name fails check"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 571 (list) (lambda ()
                          (describeViaCheck "X"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: describeViaCheck \"X\""))
    ))
  )

  (test-case "T12a: Active"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 590 (list) (lambda () (describeStatus3 Active)))) "active")
    ))
  )

  (test-case "T12b: Inactive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 594 (list) (lambda () (describeStatus3 Inactive)))) "inactive")
    ))
  )

  (test-case "T12c: Suspended with reason"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 598 (list) (lambda () (describeStatus3 (Suspended "policy violation"))))) "suspended: policy violation")
    ))
  )

  (test-case "T12d: Suspended with empty reason"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 602 (list) (lambda () (describeStatus3 (Suspended ""))))) "suspended: ")
    ))
  )

  (test-case "T13a: all non-negative passes"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 617 (list) (lambda () (strictBatch (list 0 1 2 100))))) 1)
    ))
  )

  (test-case "T13b: one negative fails the batch"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 621 (list) (lambda () (strictBatch (list 1 2 -1 4))))) -1)
    ))
  )

  (test-case "T13c: single -1 fails"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 625 (list) (lambda () (strictBatch (list -1))))) -1)
    ))
  )

  (test-case "T13d: single 0 passes"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 629 (list) (lambda () (strictBatch (list 0))))) 1)
    ))
  )

  (test-case "T13e: empty list passes vacuously"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 633 (list) (lambda () (strictBatch (list))))) 1)
    ))
  )

  (test-case "T13f: last element negative kills the batch"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 637 (list) (lambda () (strictBatch (list 1 2 3 4 -1))))) -1)
    ))
  )

  (test-case "T14a: positive float"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 651 (list) (lambda () (floatEdge 1.)))) "positive")
    ))
  )

  (test-case "T14b: zero is not positive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 655 (list) (lambda () (floatEdge 0.)))) "non-positive")
    ))
  )

  (test-case "T14c: negative float is not positive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 659 (list) (lambda () (floatEdge -1.)))) "non-positive")
    ))
  )

  (test-case "T14d: very small positive float"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 663 (list) (lambda () (floatEdge 0.0001)))) "positive")
    ))
  )

  (test-case "T14e: Float.sqrt of 0 is 0 (non-positive)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 667 (list) (lambda () (floatEdge (raw-value (tesl_import_Float_sqrt 0.)))))) "non-positive")
    ))
  )

  (test-case "T14f: Float.sqrt of 4 is 2 (positive)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 671 (list) (lambda () (floatEdge (raw-value (tesl_import_Float_sqrt 4.)))))) "positive")
    ))
  )

  (test-case "T14g: Float.abs of negative is positive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 675 (list) (lambda () (floatEdge (raw-value (tesl_import_Float_abs -5.)))))) "positive")
    ))
  )

  (test-case "T15a: 0 is even"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 696 (list) (lambda () (isEven2 0)))) #t)
    ))
  )

  (test-case "T15b: 1 is odd"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 700 (list) (lambda () (isOdd2 1)))) #t)
    ))
  )

  (test-case "T15c: 2 is even"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 704 (list) (lambda () (isEven2 2)))) #t)
    ))
  )

  (test-case "T15d: 7 is odd"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 708 (list) (lambda () (isOdd2 7)))) #t)
    ))
  )

  (test-case "T15e: 10 is even"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 712 (list) (lambda () (isEven2 10)))) #t)
    ))
  )

  (test-case "T15f: 0 is not odd"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 716 (list) (lambda () (isOdd2 0)))) #f)
    ))
  )

  (test-case "T16a: pipeline: filter then count"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 732 (list) (lambda () (countProven (list 1 -1 2 -2 3))))) 3)
    ))
  )

  (test-case "T16b: pipeline: all pass"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 736 (list) (lambda () (countProven (list 5 10 15))))) 3)
    ))
  )

  (test-case "T16c: pipeline: none pass"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 740 (list) (lambda () (countProven (list -1 -2 -3))))) 0)
    ))
  )

  (test-case "T17a: round-trip preserves value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 754 (list) (lambda () (roundTripProof 7)))) 14)
    ))
  )

  (test-case "T17b: round-trip preserves behaviour"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 758 (list) (lambda () (roundTripProof 1)))) 2)
    ))
  )

  (test-case "T17c: round-trip fails for non-positive"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 762 (list) (lambda ()
                          (roundTripProof 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: roundTripProof 0"))
    ))
  )

  (test-case "T17d: round-trip with large value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 766 (list) (lambda () (roundTripProof 500)))) 1000)
    ))
  )

  (test-case "T18a: valid email passes check"
    (call-with-fresh-memory-db '() (lambda ()
  (define tesl-checked-31 (checkEmail2 "a@b.com"))
  (when (check-fail? tesl-checked-31)
    (raise-user-error 'tesl-test "unexpected failure in let e: ~a" (check-fail-message tesl-checked-31)))
  (define e tesl-checked-31)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 790 (list (cons 'e e)) (lambda () (requiresEmail2 e)))) "email ok")
    ))
  )

  (test-case "T18b: email without @ fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 794 (list) (lambda ()
                          (checkEmail2 "notanemail"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail2 \"notanemail\""))
    ))
  )

  (test-case "T18c: too-short email fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 798 (list) (lambda ()
                          (checkEmail2 "a@b"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail2 \"a@b\""))
    ))
  )

  (test-case "T18d: exactly minimum length with @"
    (call-with-fresh-memory-db '() (lambda ()
  (define tesl-checked-32 (checkEmail2 "a@b.c"))
  (when (check-fail? tesl-checked-32)
    (raise-user-error 'tesl-test "unexpected failure in let e: ~a" (check-fail-message tesl-checked-32)))
  (define e tesl-checked-32)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 803 (list (cons 'e e)) (lambda () (requiresEmail2 e)))) "email ok")
    ))
  )

  (test-case "T19a: 5 is positive and small"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 831 (list) (lambda () (checkPosAndSmall2 5)))) "ok: 5")
    ))
  )

  (test-case "T19b: 0 is not positive \226\128\148 left fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 835 (list) (lambda ()
                          (checkPosAndSmall2 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall2 0"))
    ))
  )

  (test-case "T19c: 50 is not small \226\128\148 right fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 839 (list) (lambda ()
                          (checkPosAndSmall2 50))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall2 50"))
    ))
  )

  (test-case "T19d: -10 fails both"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 843 (list) (lambda ()
                          (checkPosAndSmall2 -10))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkPosAndSmall2 -10"))
    ))
  )

  (test-case "T19e: 49 is positive and small"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 847 (list) (lambda () (checkPosAndSmall2 49)))) "ok: 49")
    ))
  )

  (test-case "T19f: 1 is positive and small"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 851 (list) (lambda () (checkPosAndSmall2 1)))) "ok: 1")
    ))
  )

  (test-case "T20a: found returns value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 866 (list) (lambda () (lookupWithDefault (list 1 2 3) 2)))) 2)
    ))
  )

  (test-case "T20b: not found returns -999"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 870 (list) (lambda () (lookupWithDefault (list 1 2 3) 9)))) -999)
    ))
  )

  (test-case "T20c: empty list returns -999"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 874 (list) (lambda () (lookupWithDefault (list) 1)))) -999)
    ))
  )

  (test-case "T20d: found first element"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 878 (list) (lambda () (lookupWithDefault (list 5 6 7) 5)))) 5)
    ))
  )

  (test-case "T21a: long name function works"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 890 (list) (lambda () (aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly 41)))) 42)
    ))
  )

  (test-case "T21b: long name with zero"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 894 (list) (lambda () (aVeryLongFunctionNameThatTestsIfTheLexerHandlesLongIdentifiersCorrectly 0)))) 1)
    ))
  )

  (test-case "T22a: lambda folds filtered list"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 910 (list) (lambda () (applyLambdaToFiltered (list 1 2 3 -1 -2))))) 6)
    ))
  )

  (test-case "T22b: lambda fold on empty after filter"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 914 (list) (lambda () (applyLambdaToFiltered (list -1 -2 -3))))) 0)
    ))
  )

  (test-case "T22c: lambda fold all positive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 918 (list) (lambda () (applyLambdaToFiltered (list 10 20 30))))) 60)
    ))
  )

  (test-case "T23a: valid title creates record"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review-26-tests.tesl" 946 (list) (lambda () (checkSafeRecord "Hello World"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 947 (list (cons 'r r)) (lambda () (requiresSafeRecord r)))) "Hello World")
    ))
  )

  (test-case "T23b: too-short title fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 951 (list) (lambda ()
                          (checkSafeRecord "Hi"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: checkSafeRecord \"Hi\""))
    ))
  )

  (test-case "T23c: exact min length creates record"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review-26-tests.tesl" 955 (list) (lambda () (checkSafeRecord "ABC"))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 956 (list (cons 'r r)) (lambda () (requiresSafeRecord r)))) "ABC")
    ))
  )

  (test-case "T24a: Ok result returned for valid input"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 984 (list) (lambda () (parseIntOk "hi")))) 2)
    ))
  )

  (test-case "T24b: Err for empty input"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 988 (list) (lambda () (parseIntErr "")))) #t)
    ))
  )

  (test-case "T24c: Ok carries correct value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 992 (list) (lambda () (parseIntOk "abc")))) 3)
    ))
  )

  (test-case "T24d: Err for too-long input"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 996 (list) (lambda () (parseIntErr "toolong")))) #t)
    ))
  )

  (test-case "T25a: forget value, keep proof, reattach to same raw int"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1012 (list) (lambda () (forgetOnlyLeft 8)))) 16)
    ))
  )

  (test-case "T25b: for value 1"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1016 (list) (lambda () (forgetOnlyLeft 1)))) 2)
    ))
  )

  (test-case "T25c: non-positive fails at original check"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 1020 (list) (lambda ()
                          (forgetOnlyLeft 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: forgetOnlyLeft 0"))
    ))
  )

  (test-case "T26a: even number gets proof"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1044 (list) (lambda () (checkOrEstablish 4)))) "even: 4")
    ))
  )

  (test-case "T26b: odd number gets Nothing"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1048 (list) (lambda () (checkOrEstablish 3)))) "not even")
    ))
  )

  (test-case "T26c: zero is even"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1052 (list) (lambda () (checkOrEstablish 0)))) "even: 0")
    ))
  )

  (test-case "T26d: negative even"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1056 (list) (lambda () (checkOrEstablish -2)))) "even: -2")
    ))
  )

  (test-case "T27a: Empty returns -1"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1075 (list) (lambda () (guardedProof Empty 10)))) -1)
    ))
  )

  (test-case "T27b: Wrap 15 with threshold 10 returns 15"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1079 (list) (lambda () (guardedProof (Wrap 15) 10)))) 15)
    ))
  )

  (test-case "T27c: Wrap 5 with threshold 10 falls through to 0"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1083 (list) (lambda () (guardedProof (Wrap 5) 10)))) 0)
    ))
  )

  (test-case "T27d: Wrap 10 with threshold 10 is NOT > 10, falls to 0"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1087 (list) (lambda () (guardedProof (Wrap 10) 10)))) 0)
    ))
  )

  (test-case "T27e: Wrap 11 with threshold 10 is > 10"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1091 (list) (lambda () (guardedProof (Wrap 11) 10)))) 11)
    ))
  )

  (test-case "T28a: single leaf"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1109 (list) (lambda () (treeSum (Leaf 5))))) 5)
    ))
  )

  (test-case "T28b: two-leaf tree"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/critical-review-26-tests.tesl" 1113 (list) (lambda () (raw-value (Branch (Leaf 3) (Leaf 4))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1114 (list (cons 't t)) (lambda () (treeSum t)))) 7)
    ))
  )

  (test-case "T28c: three-level tree"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/critical-review-26-tests.tesl" 1118 (list) (lambda () (raw-value (Branch (Branch (Leaf 1) (Leaf 2)) (Branch (Leaf 3) (Leaf 4)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1119 (list (cons 't t)) (lambda () (treeSum t)))) 10)
    ))
  )

  (test-case "T28d: unbalanced tree"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/critical-review-26-tests.tesl" 1123 (list) (lambda () (raw-value (Branch (Leaf 10) (Branch (Leaf 1) (Branch (Leaf 2) (Leaf 3))))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1124 (list (cons 't t)) (lambda () (treeSum t)))) 16)
    ))
  )

  (test-case "T28e: all-zero leaves"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/critical-review-26-tests.tesl" 1128 (list) (lambda () (raw-value (Branch (Leaf 0) (Branch (Leaf 0) (Leaf 0)))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1129 (list (cons 't t)) (lambda () (treeSum t)))) 0)
    ))
  )

  (test-case "T28f: negative leaves"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/critical-review-26-tests.tesl" 1133 (list) (lambda () (raw-value (Branch (Leaf -1) (Leaf -2))))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1134 (list (cons 't t)) (lambda () (treeSum t)))) -3)
    ))
  )

  (test-case "T29a: 5 in [1, 10]"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1158 (list) (lambda () (useInRange3 1 10 5)))) "5 in [1, 10]")
    ))
  )

  (test-case "T29b: at lower bound"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1162 (list) (lambda () (useInRange3 1 10 1)))) "1 in [1, 10]")
    ))
  )

  (test-case "T29c: at upper bound"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1166 (list) (lambda () (useInRange3 1 10 10)))) "10 in [1, 10]")
    ))
  )

  (test-case "T29d: below lower bound fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 1170 (list) (lambda ()
                          (useInRange3 1 10 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useInRange3 1 10 0"))
    ))
  )

  (test-case "T29e: above upper bound fails"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 1174 (list) (lambda ()
                          (useInRange3 1 10 11))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: useInRange3 1 10 11"))
    ))
  )

  (test-case "T29f: lo == hi, exact match"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1178 (list) (lambda () (useInRange3 5 5 5)))) "5 in [5, 5]")
    ))
  )

  (test-case "T29g: negative range"
    (call-with-fresh-memory-db '() (lambda ()
  (define lo (thsl-src! "tests/critical-review-26-tests.tesl" 1182 (list) (lambda () (- 0 10))))
  (define hi (thsl-src! "tests/critical-review-26-tests.tesl" 1183 (list (cons 'lo lo)) (lambda () (- 0 1))))
  (define n (thsl-src! "tests/critical-review-26-tests.tesl" 1184 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (- 0 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1185 (list (cons 'n n) (cons 'hi hi) (cons 'lo lo)) (lambda () (useInRange3 lo hi n)))) "-5 in [-10, -1]")
    ))
  )

  (test-case "T30a: discard both halves, return original + 1"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1199 (list) (lambda () (discardBothHalves 5)))) 6)
    ))
  )

  (test-case "T30b: discard both halves, n = 1"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1203 (list) (lambda () (discardBothHalves 1)))) 2)
    ))
  )

  (test-case "T30c: check still propagates failure even with discarded binding"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-26-tests.tesl" 1207 (list) (lambda ()
                          (discardBothHalves 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: discardBothHalves 0"))
    ))
  )

  (test-case "T30d: large value"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-26-tests.tesl" 1211 (list) (lambda () (discardBothHalves 100)))) 101)
    ))
  )

)
