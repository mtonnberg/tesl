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
  (only-in tesl/tesl/prelude Bool Int String List Fact forgetFact detachFact introAnd andLeft andRight)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.map tesl_import_List_map] [List.length tesl_import_List_length])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first])
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define InRange 'InRange)
(define IsPositive 'IsPositive)
(define TitleSafe 'TitleSafe)
(define ValidUserId 'ValidUserId)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review60-tests.tesl" 51 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "fail A" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: (B n)]
  (thsl-src! "tests/critical-review60-tests.tesl" 57 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (B n) #:value *n) (reject "fail B" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: (C n)]
  (thsl-src! "tests/critical-review60-tests.tesl" 63 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 42)) (accept (C n) #:value *n) (reject "fail C" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: (D n)]
  (thsl-src! "tests/critical-review60-tests.tesl" 69 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 99)) (accept (D n) #:value *n) (reject "fail D" #:http-code 400)))))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review60-tests.tesl" 75 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkTitle [s : String])
  #:returns [s : String ::: (TitleSafe s)]
  (thsl-src! "tests/critical-review60-tests.tesl" 81 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (TitleSafe s) #:value *s) (reject "empty title" #:http-code 400)))))

(define-checker
  (checkInRange [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InRange lo hi n)]
  (thsl-src! "tests/critical-review60-tests.tesl" 87 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (>= *n *lo) (<= *n *hi)) (accept (InRange lo hi n) #:value *n) (reject "out of range" #:http-code 400)))))

(define-trusted
  (proveA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review60-tests.tesl" 94 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (proveB [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review60-tests.tesl" 95 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define/pow
  (needsA [n : Integer ::: (A n)])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 99 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsB [n : Integer ::: (B n)])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 100 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 101 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsABC [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 102 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAll4 [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 103 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 104 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsTitle [s : String ::: (TitleSafe s)])
  #:returns String
  (thsl-src! "tests/critical-review60-tests.tesl" 105 (list (cons 's *s)) (lambda () *s)))

(define/pow
  (needsInRange [lo : Integer] [hi : Integer] [n : Integer ::: (InRange lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 106 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (chain3 [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 111 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkA raw)]) (let ([a tesl-checked-0]) (let/check ([tesl-checked-1 (checkB a)]) (let ([b tesl-checked-1]) (let/check ([tesl-checked-2 (checkC b)]) (let ([c tesl-checked-2]) (raw-value (needsABC c)))))))))))

(define/pow
  (chain4 [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 117 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-3 (checkA raw)]) (let ([a tesl-checked-3]) (let/check ([tesl-checked-4 (checkB a)]) (let ([b tesl-checked-4]) (let/check ([tesl-checked-5 (checkC b)]) (let ([c tesl-checked-5]) (let/check ([tesl-checked-6 (checkD c)]) (let ([d tesl-checked-6]) (raw-value (needsAll4 d)))))))))))))

(define-record SafeItem
  [title : String ::: (TitleSafe title)]
  [count : Integer ::: (IsPositive count)]
)

(define/pow
  (makeItem [rawTitle : String] [rawCount : Integer])
  #:returns SafeItem
  (thsl-src! "tests/critical-review60-tests.tesl" 149 (list (cons 'rawTitle *rawTitle) (cons 'rawCount *rawCount)) (lambda () (let/check ([tesl-checked-7 (checkTitle rawTitle)]) (let ([t tesl-checked-7]) (let/check ([tesl-checked-8 (checkPos rawCount)]) (let ([c tesl-checked-8]) (SafeItem #:title t #:count c))))))))

(define/pow
  (useItemTitle [item : SafeItem])
  #:returns String
  (thsl-src! "tests/critical-review60-tests.tesl" 154 (list (cons 'item *item)) (lambda () (raw-value (needsTitle (tesl-dot/runtime item 'title 'SafeItem))))))

(define/pow
  (useItemCount [item : SafeItem])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 157 (list (cons 'item *item)) (lambda () (raw-value (needsPos (tesl-dot/runtime item 'count 'SafeItem))))))

(define/pow
  (doublePos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 181 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (doubleAllPositive [xs : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review60-tests.tesl" 185 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-9 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (doublePos n))) tesl-lambda-9) *xs)))))

(define/pow
  (inBounds [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 204 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-10 (checkInRange 0 100 raw)]) (let ([checked tesl-checked-10]) (raw-value (needsInRange 0 100 checked)))))))

(define-trusted
  (forgeA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review60-tests.tesl" 221 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define/pow
  (passThroughUnconditional [n : Integer])
  #:returns Integer
  (let ([proof (thsl-src! "tests/critical-review60-tests.tesl" 224 (list (cons 'n *n)) (lambda () (forgeA n)))]) (let ([raw (thsl-src! "tests/critical-review60-tests.tesl" 225 (list (cons 'proof *proof) (cons 'n *n)) (lambda () (forget-proof n)))]) (let ([faked (thsl-src! "tests/critical-review60-tests.tesl" 226 (list (cons 'raw *raw) (cons 'proof *proof) (cons 'n *n)) (lambda () (attach-proof raw proof)))]) (thsl-src! "tests/critical-review60-tests.tesl" 227 (list (cons 'faked *faked) (cons 'raw *raw) (cons 'proof *proof) (cons 'n *n)) (lambda () (raw-value (needsA faked))))))))

(define-checker
  (checkAndAppend [s : String])
  #:returns [result : String ::: (TitleSafe result)]
  (let ([result (thsl-src! "tests/critical-review60-tests.tesl" 242 (list (cons 's *s)) (lambda () (string-append *s "!")))]) (thsl-src! "tests/critical-review60-tests.tesl" 243 (list (cons 'result *result) (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length (raw-value result))) 0) (accept (TitleSafe result) #:value *result) (reject "empty after append" #:http-code 400))))))

(define/pow
  (callLambdaWithProof [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 257 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-11 (checkPos raw)]) (let ([pos tesl-checked-11]) (let ([f (let () (define/pow (tesl-lambda-12 [n : Integer]) #:returns Integer (let ([n (tesl-establish-param-proof n *n `(IsPositive ,n))]) (+ *n 1))) tesl-lambda-12)]) (raw-value (f pos))))))))

(define/pow
  (combine4Proofs [n : Integer])
  #:returns Integer
  (let ([pa (thsl-src! "tests/critical-review60-tests.tesl" 269 (list (cons 'n *n)) (lambda () (proveA n)))]) (let ([pb (thsl-src! "tests/critical-review60-tests.tesl" 270 (list (cons 'pa *pa) (cons 'n *n)) (lambda () (proveB n)))]) (let ([pab (thsl-src! "tests/critical-review60-tests.tesl" 271 (list (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (intro-and pa pb)))]) (let ([la (thsl-src! "tests/critical-review60-tests.tesl" 272 (list (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (and-left pab)))]) (let ([rb (thsl-src! "tests/critical-review60-tests.tesl" 273 (list (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (and-right pab)))]) (let ([base (thsl-src! "tests/critical-review60-tests.tesl" 274 (list (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (forget-proof n)))]) (let ([withA (thsl-src! "tests/critical-review60-tests.tesl" 275 (list (cons 'base *base) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (attach-proof base la)))]) (let ([withB (thsl-src! "tests/critical-review60-tests.tesl" 276 (list (cons 'withA *withA) (cons 'base *base) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (attach-proof (forget-proof n) rb)))]) (thsl-src! "tests/critical-review60-tests.tesl" 277 (list (cons 'withB *withB) (cons 'withA *withA) (cons 'base *base) (cons 'rb *rb) (cons 'la *la) (cons 'pab *pab) (cons 'pb *pb) (cons 'pa *pa) (cons 'n *n)) (lambda () (+ (raw-value (needsA withA)) (raw-value (needsB withB))))))))))))))

(define/pow
  (detachFrom4Chain [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 287 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-13 (checkA raw)]) (let ([a tesl-checked-13]) (let/check ([tesl-checked-14 (checkB a)]) (let ([b tesl-checked-14]) (let/check ([tesl-checked-15 (checkC b)]) (let ([c tesl-checked-15]) (let/check ([tesl-checked-16 (checkD c)]) (let ([d tesl-checked-16]) (let ([_p (detach-all-proof d)]) 0))))))))))))

(define/pow
  (tupleProofLoss [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 302 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-17 (checkPos raw)]) (let ([pos tesl-checked-17]) (let ([t (raw-value (Tuple2 pos "hello"))]) (let ([extracted (raw-value (tesl_import_Tuple2_first (raw-value t)))]) (let/check ([tesl-checked-18 (checkPos extracted)]) (let ([reproved tesl-checked-18]) (raw-value (needsPos reproved)))))))))))

(define-record PlainPair
  [n : Integer]
  [s : String]
)

(define/pow
  (plainFieldLoss [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 322 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-19 (checkPos raw)]) (let ([pos tesl-checked-19]) (let ([pair (PlainPair #:n *pos #:s "x")]) (let/check ([tesl-checked-20 (checkPos (tesl-dot/runtime pair 'n 'PlainPair))]) (let ([reproved tesl-checked-20]) (raw-value (needsPos reproved))))))))))

(define/pow
  (updateTitle [item : SafeItem] [newTitle : String])
  #:returns SafeItem
  (thsl-src! "tests/critical-review60-tests.tesl" 339 (list (cons 'item *item) (cons 'newTitle *newTitle)) (lambda () (let/check ([tesl-checked-21 (checkTitle newTitle)]) (let ([t tesl-checked-21]) (tesl-record-update *item (hash 'title t)))))))

(define/pow
  (updateCount [item : SafeItem] [newCount : Integer])
  #:returns SafeItem
  (thsl-src! "tests/critical-review60-tests.tesl" 343 (list (cons 'item *item) (cons 'newCount *newCount)) (lambda () (let/check ([tesl-checked-22 (checkPos newCount)]) (let ([c tesl-checked-22]) (tesl-record-update *item (hash 'count c)))))))

(define/pow
  (updateBoth [item : SafeItem] [newTitle : String] [newCount : Integer])
  #:returns SafeItem
  (thsl-src! "tests/critical-review60-tests.tesl" 347 (list (cons 'item *item) (cons 'newTitle *newTitle) (cons 'newCount *newCount)) (lambda () (let/check ([tesl-checked-23 (checkTitle newTitle)]) (let ([t tesl-checked-23]) (let/check ([tesl-checked-24 (checkPos newCount)]) (let ([c tesl-checked-24]) (tesl-record-update *item (hash 'title t 'count c)))))))))

(define/pow
  (detachConjunction [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 411 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-25 (checkA raw)]) (let ([a tesl-checked-25]) (let/check ([tesl-checked-26 (checkB a)]) (let ([b tesl-checked-26]) (let/check ([tesl-checked-27 (checkC b)]) (let ([c tesl-checked-27]) (let/check ([tesl-checked-28 (checkD c)]) (let ([d tesl-checked-28]) (let ([combined (detach-all-proof d)]) (let ([base (forget-proof d)]) (let ([withAll (attach-proof base combined)]) (raw-value (needsAll4 withAll))))))))))))))))

(define/pow
  (detachTwoProofs [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review60-tests.tesl" 426 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-29 (checkA raw)]) (let ([a tesl-checked-29]) (let/check ([tesl-checked-30 (checkB a)]) (let ([b tesl-checked-30]) (let ([combined (detach-all-proof b)]) (let ([base (forget-proof b)]) (let ([withAB (attach-proof base combined)]) (raw-value (needsAB withAB))))))))))))

(define-newtype MkUserId String)

(define-checker
  (checkAndWrapUserId [raw : String])
  #:returns [u : MkUserId ::: (ValidUserId u)]
  (thsl-src! "tests/critical-review60-tests.tesl" 457 (list (cons 'raw *raw)) (lambda () (if (>= (raw-value (tesl_import_String_length *raw)) 3) (accept/value '(ValidUserId u) (MkUserId *raw)) (reject "user id too short" #:http-code 400)))))

(define/pow
  (needsValidId [u : MkUserId ::: (ValidUserId u)])
  #:returns MkUserId
  (thsl-src! "tests/critical-review60-tests.tesl" 462 (list (cons 'u *u)) (lambda () *u)))

(define-adt Color
  [Red]
  [Green]
  [Blue]
)

(define/pow
  (colorName [c : Color])
  #:returns String
  (thsl-src-control! "tests/critical-review60-tests.tesl" 484 (list (cons 'c *c)) (lambda () (let ([tesl-case-31 *c]) (cond [(and (adt-value? *tesl-case-31) (eq? (adt-value-variant *tesl-case-31) 'Red)) (thsl-src! "tests/critical-review60-tests.tesl" 485 (list) (lambda () (raw-value "red")))] [(and (adt-value? *tesl-case-31) (eq? (adt-value-variant *tesl-case-31) 'Green)) (thsl-src! "tests/critical-review60-tests.tesl" 486 (list) (lambda () (raw-value "green")))] [(and (adt-value? *tesl-case-31) (eq? (adt-value-variant *tesl-case-31) 'Blue)) (thsl-src! "tests/critical-review60-tests.tesl" 487 (list) (lambda () (raw-value "blue")))])))))

(define-adt Suit
  [Hearts]
  [Diamonds]
  [Clubs]
  [Spades]
)

(define/pow
  (suitColor [s : Suit])
  #:returns String
  (thsl-src-control! "tests/critical-review60-tests.tesl" 502 (list (cons 's *s)) (lambda () (let ([tesl-case-32 *s]) (cond [(and (adt-value? *tesl-case-32) (eq? (adt-value-variant *tesl-case-32) 'Hearts)) (thsl-src! "tests/critical-review60-tests.tesl" 503 (list) (lambda () (raw-value "red")))] [(and (adt-value? *tesl-case-32) (eq? (adt-value-variant *tesl-case-32) 'Diamonds)) (thsl-src! "tests/critical-review60-tests.tesl" 504 (list) (lambda () (raw-value "red")))] [(and (adt-value? *tesl-case-32) (eq? (adt-value-variant *tesl-case-32) 'Clubs)) (thsl-src! "tests/critical-review60-tests.tesl" 505 (list) (lambda () (raw-value "black")))] [(and (adt-value? *tesl-case-32) (eq? (adt-value-variant *tesl-case-32) 'Spades)) (thsl-src! "tests/critical-review60-tests.tesl" 506 (list) (lambda () (raw-value "black")))])))))

(define/pow
  (suitColorWildcard [s : Suit])
  #:returns String
  (thsl-src-control! "tests/critical-review60-tests.tesl" 514 (list (cons 's *s)) (lambda () (let ([tesl-case-33 *s]) (cond [(and (adt-value? *tesl-case-33) (eq? (adt-value-variant *tesl-case-33) 'Hearts)) (thsl-src! "tests/critical-review60-tests.tesl" 515 (list) (lambda () (raw-value "red")))] [(and (adt-value? *tesl-case-33) (eq? (adt-value-variant *tesl-case-33) 'Diamonds)) (thsl-src! "tests/critical-review60-tests.tesl" 516 (list) (lambda () (raw-value "red")))] [#t (thsl-src! "tests/critical-review60-tests.tesl" 517 (list) (lambda () (raw-value "black")))])))))

(define/pow
  (maybeWithFallback [m : (Maybe Integer)])
  #:returns Integer
  (thsl-src-control! "tests/critical-review60-tests.tesl" 525 (list (cons 'm *m)) (lambda () (let ([tesl-case-34 *m]) (cond [(and (adt-value? *tesl-case-34) (eq? (adt-value-variant *tesl-case-34) 'Nothing)) (thsl-src! "tests/critical-review60-tests.tesl" 526 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-34) (eq? (adt-value-variant *tesl-case-34) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl-case-34) 'value)]) (thsl-src! "tests/critical-review60-tests.tesl" 527 (list (cons 'v v)) (lambda () *v)))])))))

(module+ test
  (require rackunit)
  (test-case "R60_CH01 three-check chain accumulation"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 124 (list) (lambda () (chain3 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 125 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R60_CH02 four-check chain accumulation"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 129 (list) (lambda () (chain4 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 130 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R60_CH03 four-check chain rejects invalid first step"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review60-tests.tesl" 134 (list) (lambda ()
                          ((let () (define/pow (tesl-lambda-35) #:returns Integer (chain4 0)) tesl-lambda-35) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-36) #:returns Integer (chain4 0)) tesl-lambda-36) (list)"))
    ))
  )

  (test-case "R60_CH04 four-check chain rejects middle step (n=42 fails C)"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review60-tests.tesl" 138 (list) (lambda ()
                          ((let () (define/pow (tesl-lambda-36) #:returns Integer (chain4 42)) tesl-lambda-36) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-37) #:returns Integer (chain4 42)) tesl-lambda-37) (list)"))
    ))
  )

  (test-case "R60_RF01 proof-annotated field construction and title access"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 160 (list) (lambda () (makeItem "hello" 5))))
  (define t (thsl-src! "tests/critical-review60-tests.tesl" 161 (list (cons 'item item)) (lambda () (useItemTitle item))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 162 (list (cons 't t) (cons 'item item)) (lambda () t))) "hello")
    ))
  )

  (test-case "R60_RF02 proof-annotated field construction and count access"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 166 (list) (lambda () (makeItem "hello" 5))))
  (define c (thsl-src! "tests/critical-review60-tests.tesl" 167 (list (cons 'item item)) (lambda () (useItemCount item))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 168 (list (cons 'c c) (cons 'item item)) (lambda () c))) 5)
    ))
  )

  (test-case "R60_RF03 proof-annotated field construction rejects bad title"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review60-tests.tesl" 172 (list) (lambda ()
                          ((let () (define/pow (tesl-lambda-37) #:returns Any (makeItem "" 5)) tesl-lambda-37) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-38) #:returns Any (makeItem \"\" 5)) tesl-lambda-38) (list)"))
    ))
  )

  (test-case "R60_RF04 proof-annotated field construction rejects bad count"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review60-tests.tesl" 176 (list) (lambda ()
                          ((let () (define/pow (tesl-lambda-38) #:returns Any (makeItem "ok" 0)) tesl-lambda-38) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-39) #:returns Any (makeItem \"ok\" 0)) tesl-lambda-39) (list)"))
    ))
  )

  (test-case "R60_FA01 ForAll list with lambda wrapper"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review60-tests.tesl" 188 (list) (lambda () (list 1 2 3 4))))
  (define pos (thsl-src! "tests/critical-review60-tests.tesl" 189 (list (cons 'raw raw)) (lambda () (tesl_import_List_filterCheck checkPos (raw-value raw)))))
  (define doubled (thsl-src! "tests/critical-review60-tests.tesl" 190 (list (cons 'pos pos) (cons 'raw raw)) (lambda () (doubleAllPositive pos))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 191 (list (cons 'doubled doubled) (cons 'pos pos) (cons 'raw raw)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled)))))) 4)
    ))
  )

  (test-case "R60_FA02 ForAll filterCheck excludes invalid elements"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review60-tests.tesl" 195 (list) (lambda () (list 1 -2 3 -4 5))))
  (define pos (thsl-src! "tests/critical-review60-tests.tesl" 196 (list (cons 'raw raw)) (lambda () (tesl_import_List_filterCheck checkPos (raw-value raw)))))
  (define doubled (thsl-src! "tests/critical-review60-tests.tesl" 197 (list (cons 'pos pos) (cons 'raw raw)) (lambda () (doubleAllPositive pos))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 198 (list (cons 'doubled doubled) (cons 'pos pos) (cons 'raw raw)) (lambda () (raw-value (tesl_import_List_length (raw-value doubled)))))) 3)
    ))
  )

  (test-case "R60_MP01 multi-param proof with correct literal args"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 208 (list) (lambda () (inBounds 50))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 209 (list (cons 'r r)) (lambda () r))) 50)
    ))
  )

  (test-case "R60_MP02 multi-param proof rejects out-of-range value"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review60-tests.tesl" 213 (list) (lambda ()
                          ((let () (define/pow (tesl-lambda-39) #:returns Integer (inBounds 150)) tesl-lambda-39) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-40) #:returns Integer (inBounds 150)) tesl-lambda-40) (list)"))
    ))
  )

  (test-case "R60_ES01 establish forges proof unconditionally (negative value)"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 230 (list) (lambda () (passThroughUnconditional -5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 231 (list (cons 'r r)) (lambda () r))) -5)
    ))
  )

  (test-case "R60_ES02 establish forges proof unconditionally (zero)"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 235 (list) (lambda () (passThroughUnconditional 0))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 236 (list (cons 'r r)) (lambda () r))) 0)
    ))
  )

  (test-case "R60_OK01 ok with let-bound transformed value"
    (call-with-fresh-memory-db '() (lambda ()
  (define tesl-checked-40 (checkAndAppend "hello"))
  (when (check-fail? tesl-checked-40)
    (raise-user-error 'tesl-test "unexpected failure in let r: ~a" (check-fail-message tesl-checked-40)))
  (define r tesl-checked-40)
  (define result (thsl-src! "tests/critical-review60-tests.tesl" 250 (list (cons 'r r)) (lambda () (needsTitle r))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 251 (list (cons 'result result) (cons 'r r)) (lambda () result))) "hello!")
    ))
  )

  (test-case "R60_LM01 lambda with proof-annotated param is callable"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 262 (list) (lambda () (callLambdaWithProof 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 263 (list (cons 'r r)) (lambda () r))) 6)
    ))
  )

  (test-case "R60_IA01 introAnd from two establish calls, andLeft gives A"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 280 (list) (lambda () (combine4Proofs 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 281 (list (cons 'r r)) (lambda () r))) 10)
    ))
  )

  (test-case "R60_DT01 detachFact with 4 accumulated proofs should not fail at runtime"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 295 (list) (lambda () (detachFrom4Chain 5)))) 0)
    ))
  )

  (test-case "R60_TU01 tuple accessor loses proof requiring re-check"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 310 (list) (lambda () (tupleProofLoss 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 311 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R60_UC01 unannotated field loses proof requiring re-check"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 329 (list) (lambda () (plainFieldLoss 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 330 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R60_RU01 record update preserves proof on annotated title field"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 352 (list) (lambda () (makeItem "hello" 5))))
  (define newTitle (thsl-src! "tests/critical-review60-tests.tesl" 353 (list (cons 'item item)) (lambda () "world")))
  (define updated (thsl-src! "tests/critical-review60-tests.tesl" 354 (list (cons 'newTitle newTitle) (cons 'item item)) (lambda () (updateTitle item newTitle))))
  (define t (thsl-src! "tests/critical-review60-tests.tesl" 355 (list (cons 'updated updated) (cons 'newTitle newTitle) (cons 'item item)) (lambda () (useItemTitle updated))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 356 (list (cons 't t) (cons 'updated updated) (cons 'newTitle newTitle) (cons 'item item)) (lambda () t))) "world")
    ))
  )

  (test-case "R60_RU02 updated item count proof is preserved after title update"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 360 (list) (lambda () (makeItem "hello" 5))))
  (define newTitle (thsl-src! "tests/critical-review60-tests.tesl" 361 (list (cons 'item item)) (lambda () "world")))
  (define updated (thsl-src! "tests/critical-review60-tests.tesl" 362 (list (cons 'newTitle newTitle) (cons 'item item)) (lambda () (updateTitle item newTitle))))
  (define c (thsl-src! "tests/critical-review60-tests.tesl" 363 (list (cons 'updated updated) (cons 'newTitle newTitle) (cons 'item item)) (lambda () (useItemCount updated))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 364 (list (cons 'c c) (cons 'updated updated) (cons 'newTitle newTitle) (cons 'item item)) (lambda () c))) 5)
    ))
  )

  (test-case "R60_RU03 record update preserves proof on annotated count field"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 368 (list) (lambda () (makeItem "hello" 5))))
  (define newCount (thsl-src! "tests/critical-review60-tests.tesl" 369 (list (cons 'item item)) (lambda () 42)))
  (define updated (thsl-src! "tests/critical-review60-tests.tesl" 370 (list (cons 'newCount newCount) (cons 'item item)) (lambda () (updateCount item newCount))))
  (define c (thsl-src! "tests/critical-review60-tests.tesl" 371 (list (cons 'updated updated) (cons 'newCount newCount) (cons 'item item)) (lambda () (useItemCount updated))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 372 (list (cons 'c c) (cons 'updated updated) (cons 'newCount newCount) (cons 'item item)) (lambda () c))) 42)
    ))
  )

  (test-case "R60_RU04 updated item title proof preserved after count update"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 376 (list) (lambda () (makeItem "hello" 5))))
  (define newCount (thsl-src! "tests/critical-review60-tests.tesl" 377 (list (cons 'item item)) (lambda () 42)))
  (define updated (thsl-src! "tests/critical-review60-tests.tesl" 378 (list (cons 'newCount newCount) (cons 'item item)) (lambda () (updateCount item newCount))))
  (define t (thsl-src! "tests/critical-review60-tests.tesl" 379 (list (cons 'updated updated) (cons 'newCount newCount) (cons 'item item)) (lambda () (useItemTitle updated))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 380 (list (cons 't t) (cons 'updated updated) (cons 'newCount newCount) (cons 'item item)) (lambda () t))) "hello")
    ))
  )

  (test-case "R60_RU05 updating both annotated fields preserves both proofs"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 384 (list) (lambda () (makeItem "hello" 5))))
  (define newTitle (thsl-src! "tests/critical-review60-tests.tesl" 385 (list (cons 'item item)) (lambda () "world")))
  (define newCount (thsl-src! "tests/critical-review60-tests.tesl" 386 (list (cons 'newTitle newTitle) (cons 'item item)) (lambda () 99)))
  (define updated (thsl-src! "tests/critical-review60-tests.tesl" 387 (list (cons 'newCount newCount) (cons 'newTitle newTitle) (cons 'item item)) (lambda () (updateBoth item newTitle newCount))))
  (define t (thsl-src! "tests/critical-review60-tests.tesl" 388 (list (cons 'updated updated) (cons 'newCount newCount) (cons 'newTitle newTitle) (cons 'item item)) (lambda () (useItemTitle updated))))
  (define c (thsl-src! "tests/critical-review60-tests.tesl" 389 (list (cons 't t) (cons 'updated updated) (cons 'newCount newCount) (cons 'newTitle newTitle) (cons 'item item)) (lambda () (useItemCount updated))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 390 (list (cons 'c c) (cons 't t) (cons 'updated updated) (cons 'newCount newCount) (cons 'newTitle newTitle) (cons 'item item)) (lambda () t))) "world")
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 391 (list (cons 'c c) (cons 't t) (cons 'updated updated) (cons 'newCount newCount) (cons 'newTitle newTitle) (cons 'item item)) (lambda () c))) 99)
    ))
  )

  (test-case "R60_RU06 updated record rejects bad title at update time"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 395 (list) (lambda () (makeItem "hello" 5))))
  (define bad (thsl-src! "tests/critical-review60-tests.tesl" 396 (list (cons 'item item)) (lambda () "")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review60-tests.tesl" 397 (list (cons 'bad bad) (cons 'item item)) (lambda ()
                          ((let () (define/pow (tesl-lambda-41) #:returns Any (updateTitle item bad)) tesl-lambda-41) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-42) #:returns Any (updateTitle item bad)) tesl-lambda-42) (list)"))
    ))
  )

  (test-case "R60_RU07 updated record rejects bad count at update time"
    (call-with-fresh-memory-db '() (lambda ()
  (define item (thsl-src! "tests/critical-review60-tests.tesl" 401 (list) (lambda () (makeItem "hello" 5))))
  (define bad (thsl-src! "tests/critical-review60-tests.tesl" 402 (list (cons 'item item)) (lambda () 0)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review60-tests.tesl" 403 (list (cons 'bad bad) (cons 'item item)) (lambda ()
                          ((let () (define/pow (tesl-lambda-42) #:returns Any (updateCount item bad)) tesl-lambda-42) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-43) #:returns Any (updateCount item bad)) tesl-lambda-43) (list)"))
    ))
  )

  (test-case "R60_DT2_01 detachFact on 4-chain returns conjunction"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 421 (list) (lambda () (detachConjunction 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 422 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R60_DT2_02 detachFact on 2-chain returns A&&B conjunction"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 434 (list) (lambda () (detachTwoProofs 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 435 (list (cons 'r r)) (lambda () r))) 5)
    ))
  )

  (test-case "R60_DT2_03 detachFact on single proof still works"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "tests/critical-review60-tests.tesl" 439 (list) (lambda () 5)))
  (define tesl-checked-43 (checkA raw))
  (when (check-fail? tesl-checked-43)
    (raise-user-error 'tesl-test "unexpected failure in let a: ~a" (check-fail-message tesl-checked-43)))
  (define a tesl-checked-43)
  (define p (thsl-src! "tests/critical-review60-tests.tesl" 441 (list (cons 'a a) (cons 'raw raw)) (lambda () (detach-all-proof a))))
  (define base (thsl-src! "tests/critical-review60-tests.tesl" 442 (list (cons 'p p) (cons 'a a) (cons 'raw raw)) (lambda () (forget-proof a))))
  (define withA (thsl-src! "tests/critical-review60-tests.tesl" 443 (list (cons 'base base) (cons 'p p) (cons 'a a) (cons 'raw raw)) (lambda () (attach-proof base p))))
  (define r (thsl-src! "tests/critical-review60-tests.tesl" 444 (list (cons 'withA withA) (cons 'base base) (cons 'p p) (cons 'a a) (cons 'raw raw)) (lambda () (needsA withA))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 445 (list (cons 'r r) (cons 'withA withA) (cons 'base base) (cons 'p p) (cons 'a a) (cons 'raw raw)) (lambda () r))) 5)
    ))
  )

  (test-case "R60_CK01 ok with constructor application compiles and runs"
    (call-with-fresh-memory-db '() (lambda ()
  (define tesl-checked-44 (checkAndWrapUserId "abc"))
  (when (check-fail? tesl-checked-44)
    (raise-user-error 'tesl-test "unexpected failure in let uid: ~a" (check-fail-message tesl-checked-44)))
  (define uid tesl-checked-44)
  (define result (thsl-src! "tests/critical-review60-tests.tesl" 466 (list (cons 'uid uid)) (lambda () (needsValidId uid))))
  (check-equal? (thsl-src! "tests/critical-review60-tests.tesl" 467 (list (cons 'result result) (cons 'uid uid)) (lambda () (raw-value (tesl-dot/runtime result 'value)))) "abc")
    ))
  )

  (test-case "R60_CK02 ok with constructor application rejects short id"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review60-tests.tesl" 471 (list) (lambda ()
                          ((let () (define/pow (tesl-lambda-45) #:returns Any (raw-value (checkAndWrapUserId "ab"))) tesl-lambda-45) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (let () (define/pow (tesl-lambda-46) #:returns Any (raw-value (checkAndWrapUserId \"ab\"))) tesl-lambda-46) (list)"))
    ))
  )

  (test-case "R60_EX01 exhaustive 3-constructor ADT case works"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 490 (list) (lambda () (colorName Red)))) "red")
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 491 (list) (lambda () (colorName Green)))) "green")
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 492 (list) (lambda () (colorName Blue)))) "blue")
    ))
  )

  (test-case "R60_EX02 exhaustive 4-constructor ADT case works"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 509 (list) (lambda () (suitColor Hearts)))) "red")
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 510 (list) (lambda () (suitColor Spades)))) "black")
    ))
  )

  (test-case "R60_EX03 wildcard covers remaining constructors"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 520 (list) (lambda () (suitColorWildcard Hearts)))) "red")
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 521 (list) (lambda () (suitColorWildcard Clubs)))) "black")
    ))
  )

  (test-case "R60_EX04 exhaustive Maybe case works"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 530 (list) (lambda () (maybeWithFallback Nothing)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review60-tests.tesl" 531 (list) (lambda () (maybeWithFallback (raw-value (Something 42)))))) 42)
    ))
  )

)
