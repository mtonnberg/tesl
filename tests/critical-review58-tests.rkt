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
  (only-in tesl/tesl/prelude Bool Int String List Fact forgetFact attachFact detachFact introAnd andLeft andRight)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either Either Left Right)
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.length tesl_import_List_length] [List.allCheck tesl_import_List_allCheck] [List.emptyForAll tesl_import_List_emptyForAll])
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define F 'F)
(define G 'G)
(define InBounds 'InBounds)
(define IsEven 'IsEven)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define OwnedBy 'OwnedBy)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 60 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "fail A" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: (B n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 66 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (B n) #:value *n) (reject "fail B" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: (C n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 72 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 42)) (accept (C n) #:value *n) (reject "fail C" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: (D n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 78 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 99)) (accept (D n) #:value *n) (reject "fail D" #:http-code 400)))))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: (E n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 84 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 500)) (accept (E n) #:value *n) (reject "fail E" #:http-code 400)))))

(define-checker
  (checkF [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns [n : Integer ::: (F n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 90 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 777)) (accept (F n) #:value *n) (reject "fail F" #:http-code 400)))))

(define-checker
  (checkG [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && (F n))))))])
  #:returns [n : Integer ::: (G n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 96 (list (cons 'n *n)) (lambda () (accept (G n) #:value *n))))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 99 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 105 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))))

(define-checker
  (checkEven [n : Integer])
  #:returns [n : Integer ::: (IsEven n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 111 (list (cons 'n *n)) (lambda () (if (tesl-equal? (remainder *n 2) 0) (accept (IsEven n) #:value *n) (reject "not even" #:http-code 400)))))

(define-checker
  (checkInBounds [lo : Integer] [hi : Integer] [n : Integer])
  #:returns [n : Integer ::: (InBounds lo hi n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 117 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () (if (and (>= *n *lo) (<= *n *hi)) (accept (InBounds lo hi n) #:value *n) (reject "out of bounds" #:http-code 400)))))

(define-checker
  (checkOwned [userId : String] [taskId : Integer])
  #:returns [taskId : Integer ::: (OwnedBy userId taskId)]
  (thsl-src! "tests/critical-review58-tests.tesl" 123 (list (cons 'userId *userId) (cons 'taskId *taskId)) (lambda () (if #t (accept (OwnedBy userId taskId) #:value *taskId) (reject "not owned" #:http-code 403)))))

(define-trusted
  (makeA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review58-tests.tesl" 128 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (makeB [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review58-tests.tesl" 129 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define-trusted
  (makeG [n : Integer])
  #:returns (Fact (G n))
  (thsl-src! "tests/critical-review58-tests.tesl" 130 (list (cons 'n *n)) (lambda () (trusted-proof (G n)))))

(define/pow
  (needsAll7 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && ((E n) && ((F n) && (G n)))))))])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 134 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsAB [n : Integer ::: ((A n) && (B n))])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 135 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsBA [n : Integer ::: ((B n) && (A n))])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 136 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsCBA [n : Integer ::: ((C n) && ((B n) && (A n)))])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 137 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 138 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 139 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsEven [n : Integer ::: (IsEven n)])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 140 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsBothPS [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 141 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsForAllPos [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 142 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (needsForAllBoth [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 143 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (needsInBounds [lo : Integer] [hi : Integer] [n : Integer ::: (InBounds lo hi n)])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 144 (list (cons 'lo *lo) (cons 'hi *hi) (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsOwned [userId : String] [task : Integer ::: (OwnedBy userId task)])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 145 (list (cons 'userId *userId) (cons 'task *task)) (lambda () *task)))

(define/pow
  (testCommutativeAB [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 151 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-0 (checkA n)]) (let ([a tesl-checked-0]) (let/check ([tesl-checked-1 (checkB a)]) (let ([ab tesl-checked-1]) (raw-value (needsBA ab)))))))))

(define/pow
  (testCommutativeDeep [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 157 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-2 (checkA n)]) (let ([a tesl-checked-2]) (let/check ([tesl-checked-3 (checkB a)]) (let ([b tesl-checked-3]) (let/check ([tesl-checked-4 (checkC b)]) (let ([c tesl-checked-4]) (raw-value (needsCBA c)))))))))))

(define/pow
  (build7ProofChain [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 175 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-5 (checkA raw)]) (let ([a tesl-checked-5]) (let/check ([tesl-checked-6 (checkB a)]) (let ([b tesl-checked-6]) (let/check ([tesl-checked-7 (checkC b)]) (let ([c tesl-checked-7]) (let/check ([tesl-checked-8 (checkD c)]) (let ([d tesl-checked-8]) (let/check ([tesl-checked-9 (checkE d)]) (let ([e tesl-checked-9]) (let/check ([tesl-checked-10 (checkF e)]) (let ([f tesl-checked-10]) (let/check ([tesl-checked-11 (checkG f)]) (let ([g tesl-checked-11]) (raw-value (needsAll7 g)))))))))))))))))))

(define-checker
  (checkA4 [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 198 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "fail" #:http-code 400)))))

(define-checker
  (checkB4 [n : Integer])
  #:returns [n : Integer ::: (B n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 204 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (B n) #:value *n) (reject "fail" #:http-code 400)))))

(define-checker
  (checkC4 [n : Integer])
  #:returns [n : Integer ::: (C n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 210 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 42)) (accept (C n) #:value *n) (reject "fail" #:http-code 400)))))

(define-checker
  (checkD4 [n : Integer])
  #:returns [n : Integer ::: (D n)]
  (thsl-src! "tests/critical-review58-tests.tesl" 216 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 99)) (accept (D n) #:value *n) (reject "fail" #:http-code 400)))))

(define/pow
  (needs4 [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 221 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (check4Combined [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 224 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-12 ((check-and checkA4 (check-and checkB4 (check-and checkC4 checkD4))) n)]) (let ([validated tesl-checked-12]) (raw-value (needs4 validated)))))))

(define/pow
  (filterBoth [nums : (List Integer)])
  #:returns Integer
  (let ([filtered (thsl-src! "tests/critical-review58-tests.tesl" 239 (list (cons 'nums *nums)) (lambda () (tesl_import_List_filterCheck (check-and checkPos checkSmall) *nums)))]) (thsl-src! "tests/critical-review58-tests.tesl" 240 (list (cons 'filtered *filtered) (cons 'nums *nums)) (lambda () (raw-value (needsForAllBoth filtered))))))

(define/pow
  (allCheckCombined58 [nums : (List Integer)])
  #:returns (Maybe (List Integer))
  (thsl-src! "tests/critical-review58-tests.tesl" 253 (list (cons 'nums *nums)) (lambda () (tesl_import_List_allCheck (check-and checkPos checkSmall) *nums))))

(define/pow
  (detachAndReattach [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 275 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-13 (checkPos n)]) (let ([proven tesl-checked-13]) (let ([raw (forget-proof proven)]) (let ([pf (detach-all-proof proven)]) (let ([back (attach-proof raw pf)]) (raw-value (needsPos back))))))))))

(define/pow
  (introAndTest [n : Integer])
  #:returns Integer
  (let ([pA (thsl-src! "tests/critical-review58-tests.tesl" 291 (list (cons 'n *n)) (lambda () (makeA n)))]) (let ([pB (thsl-src! "tests/critical-review58-tests.tesl" 292 (list (cons 'pA *pA) (cons 'n *n)) (lambda () (makeB n)))]) (let ([pAB (thsl-src! "tests/critical-review58-tests.tesl" 293 (list (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (intro-and pA pB)))]) (let ([proven (thsl-src! "tests/critical-review58-tests.tesl" 294 (list (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (attach-proof n pAB)))]) (thsl-src! "tests/critical-review58-tests.tesl" 295 (list (cons 'proven *proven) (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (raw-value (needsAB proven)))))))))

(define/pow
  (andDecomposeTest [n : Integer])
  #:returns Integer
  (let ([pA (thsl-src! "tests/critical-review58-tests.tesl" 298 (list (cons 'n *n)) (lambda () (makeA n)))]) (let ([pB (thsl-src! "tests/critical-review58-tests.tesl" 299 (list (cons 'pA *pA) (cons 'n *n)) (lambda () (makeB n)))]) (let ([pAB (thsl-src! "tests/critical-review58-tests.tesl" 300 (list (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (intro-and pA pB)))]) (let ([pA2 (thsl-src! "tests/critical-review58-tests.tesl" 301 (list (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (and-left pAB)))]) (let ([pB2 (thsl-src! "tests/critical-review58-tests.tesl" 302 (list (cons 'pA2 *pA2) (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (and-right pAB)))]) (let ([pRebuilt (thsl-src! "tests/critical-review58-tests.tesl" 304 (list (cons 'pB2 *pB2) (cons 'pA2 *pA2) (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (intro-and pA2 pB2)))]) (thsl-src! "tests/critical-review58-tests.tesl" 305 (list (cons 'pRebuilt *pRebuilt) (cons 'pB2 *pB2) (cons 'pA2 *pA2) (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () *n)))))))))

(define/pow
  (testInBounds [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 320 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-14 (checkInBounds 1 10 n)]) (let ([v tesl-checked-14]) (raw-value (needsInBounds 1 10 v)))))))

(define/pow
  (testOwnership [userId : String] [taskId : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review58-tests.tesl" 324 (list (cons 'userId *userId) (cons 'taskId *taskId)) (lambda () (let/check ([tesl-checked-15 (checkOwned userId taskId)]) (let ([ownedTask tesl-checked-15]) (raw-value (needsOwned userId ownedTask)))))))

(define-trusted
  (alwaysProveA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review58-tests.tesl" 337 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define/pow
  (useEstablishFreedom [n : Integer])
  #:returns Integer
  (let ([pA (thsl-src! "tests/critical-review58-tests.tesl" 341 (list (cons 'n *n)) (lambda () (alwaysProveA n)))]) (let ([proven (thsl-src! "tests/critical-review58-tests.tesl" 342 (list (cons 'pA *pA) (cons 'n *n)) (lambda () (attach-proof n pA)))]) (let ([raw (thsl-src! "tests/critical-review58-tests.tesl" 344 (list (cons 'proven *proven) (cons 'pA *pA) (cons 'n *n)) (lambda () proven))]) (thsl-src! "tests/critical-review58-tests.tesl" 345 (list (cons 'raw *raw) (cons 'proven *proven) (cons 'pA *pA) (cons 'n *n)) (lambda () (raw-value raw)))))))

(define-adt Color
  [Red]
  [Green]
  [Blue]
)

(define/pow
  (describeColor [c : Color])
  #:returns String
  (thsl-src-control! "tests/critical-review58-tests.tesl" 363 (list (cons 'c *c)) (lambda () (let ([tesl-case-16 *c]) (cond [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Red)) (thsl-src! "tests/critical-review58-tests.tesl" 364 (list) (lambda () (raw-value "red")))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Green)) (thsl-src! "tests/critical-review58-tests.tesl" 365 (list) (lambda () (raw-value "green")))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Blue)) (thsl-src! "tests/critical-review58-tests.tesl" 366 (list) (lambda () (raw-value "blue")))])))))

(define/pow
  (describeColorSafe [c : Color])
  #:returns String
  (thsl-src-control! "tests/critical-review58-tests.tesl" 370 (list (cons 'c *c)) (lambda () (let ([tesl-case-17 *c]) (cond [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Red)) (thsl-src! "tests/critical-review58-tests.tesl" 371 (list) (lambda () (raw-value "red")))] [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Green)) (thsl-src! "tests/critical-review58-tests.tesl" 372 (list) (lambda () (raw-value "green")))] [(and (adt-value? *tesl-case-17) (eq? (adt-value-variant *tesl-case-17) 'Blue)) (thsl-src! "tests/critical-review58-tests.tesl" 373 (list) (lambda () (raw-value "blue")))])))))

(define/pow
  (seqFilterAccumulated [nums : (List Integer)])
  #:returns Integer
  (let ([pos (thsl-src! "tests/critical-review58-tests.tesl" 386 (list (cons 'nums *nums)) (lambda () (tesl_import_List_filterCheck checkPos *nums)))]) (let ([posSmall (thsl-src! "tests/critical-review58-tests.tesl" 387 (list (cons 'pos *pos) (cons 'nums *nums)) (lambda () (tesl_import_List_filterCheck checkSmall (raw-value pos))))]) (thsl-src! "tests/critical-review58-tests.tesl" 389 (list (cons 'posSmall *posSmall) (cons 'pos *pos) (cons 'nums *nums)) (lambda () (raw-value (needsForAllBoth posSmall)))))))

(module+ test
  (require rackunit)
  (test-case "R58_CJ01 proof conjunction is commutative (A&&B satisfies B&&A)"
  (define result (thsl-src! "tests/critical-review58-tests.tesl" 163 (list) (lambda () (testCommutativeAB 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 164 (list (cons 'result result)) (lambda () result))) 5)
  )

  (test-case "R58_CJ02 deep conjunction commutativity (A&&B&&C satisfies C&&B&&A)"
  (define result (thsl-src! "tests/critical-review58-tests.tesl" 168 (list) (lambda () (testCommutativeDeep 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 169 (list (cons 'result result)) (lambda () result))) 5)
  )

  (test-case "R58_CH01 7-proof sequential chain works correctly"
  (define result (thsl-src! "tests/critical-review58-tests.tesl" 185 (list) (lambda () (build7ProofChain 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 186 (list (cons 'result result)) (lambda () result))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 187 (list (cons 'result result)) (lambda ()
                          (build7ProofChain 42))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 42"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 188 (list (cons 'result result)) (lambda ()
                          (build7ProofChain 99))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 99"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 189 (list (cons 'result result)) (lambda ()
                          (build7ProofChain 500))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 500"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 190 (list (cons 'result result)) (lambda ()
                          (build7ProofChain 777))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 777"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 191 (list (cons 'result result)) (lambda ()
                          (build7ProofChain 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 192 (list (cons 'result result)) (lambda ()
                          (build7ProofChain 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: build7ProofChain 1001"))
  )

  (test-case "R58_AND01 4-check && chain proves all 4 simultaneously"
  (define result (thsl-src! "tests/critical-review58-tests.tesl" 228 (list) (lambda () (check4Combined 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 229 (list (cons 'result result)) (lambda () result))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 230 (list (cons 'result result)) (lambda ()
                          (check4Combined 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check4Combined 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 231 (list (cons 'result result)) (lambda ()
                          (check4Combined 42))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check4Combined 42"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 232 (list (cons 'result result)) (lambda ()
                          (check4Combined 99))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check4Combined 99"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 233 (list (cons 'result result)) (lambda ()
                          (check4Combined 1500))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check4Combined 1500"))
  )

  (test-case "R58_FA01 combined filterCheck produces ForAll (P && Q) proof"
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 243 (list) (lambda () (filterBoth (list 1 50 200 -3 80))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 244 (list) (lambda () (filterBoth (list))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 245 (list) (lambda () (filterBoth (list -1 -2 -3))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 246 (list) (lambda () (filterBoth (list 200 300 400))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 247 (list) (lambda () (filterBoth (list 50 99 1))))) 3)
  )

  (test-case "R58_AC01 allCheck with named return type preserves ForAll via let"
  (define m1 (thsl-src! "tests/critical-review58-tests.tesl" 256 (list) (lambda () (allCheckCombined58 (list 5 10 50)))))
  (let ([*tesl-case-18 (raw-value 
    m1)]) (cond
    [(and (adt-value? *tesl-case-18) (eq? (adt-value-variant *tesl-case-18) 'Nothing))
      (check-true (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 258 (list) (lambda () #f))))
    ]
    [(and (adt-value? *tesl-case-18) (eq? (adt-value-variant *tesl-case-18) 'Something))
      (let ([r (hash-ref (adt-value-fields *tesl-case-18) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 259 (list) (lambda () (needsForAllBoth r)))) 3)
      )
    ]
  ))
  (define m2 (thsl-src! "tests/critical-review58-tests.tesl" 261 (list (cons 'm1 m1)) (lambda () (allCheckCombined58 (list 5 200 10)))))
  (let ([*tesl-case-19 (raw-value 
    m2)]) (cond
    [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Nothing))
      (check-true (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 263 (list) (lambda () #t))))
    ]
    [(and (adt-value? *tesl-case-19) (eq? (adt-value-variant *tesl-case-19) 'Something))
      (check-true (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 264 (list) (lambda () #f))))
    ]
  ))
  (define m3 (thsl-src! "tests/critical-review58-tests.tesl" 266 (list (cons 'm2 m2) (cons 'm1 m1)) (lambda () (allCheckCombined58 (list)))))
  (let ([*tesl-case-20 (raw-value 
    m3)]) (cond
    [(and (adt-value? *tesl-case-20) (eq? (adt-value-variant *tesl-case-20) 'Nothing))
      (check-true (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 268 (list) (lambda () #f))))
    ]
    [(and (adt-value? *tesl-case-20) (eq? (adt-value-variant *tesl-case-20) 'Something))
      (let ([r (hash-ref (adt-value-fields *tesl-case-20) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 269 (list) (lambda () (needsForAllBoth r)))) 0)
      )
    ]
  ))
  )

  (test-case "R58_DA01 detach and re-attach to same subject works"
  (define result (thsl-src! "tests/critical-review58-tests.tesl" 282 (list) (lambda () (detachAndReattach 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 283 (list (cons 'result result)) (lambda () result))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 284 (list (cons 'result result)) (lambda ()
                          (detachAndReattach 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: detachAndReattach 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 285 (list (cons 'result result)) (lambda ()
                          (detachAndReattach -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: detachAndReattach -1"))
  )

  (test-case "R58_IC01 introAnd combines Facts, attachFact applies combined proof"
  (define result (thsl-src! "tests/critical-review58-tests.tesl" 308 (list) (lambda () (introAndTest 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 309 (list (cons 'result result)) (lambda () result))) 5)
  )

  (test-case "R58_IC02 andLeft/andRight decompose correctly"
  (define result (thsl-src! "tests/critical-review58-tests.tesl" 313 (list) (lambda () (andDecomposeTest 5))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 314 (list (cons 'result result)) (lambda () result))) 5)
  )

  (test-case "R58_MP01 multi-parameter proofs in correct order work"
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 328 (list) (lambda () (testInBounds 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 329 (list) (lambda ()
                          (testInBounds 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testInBounds 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review58-tests.tesl" 330 (list) (lambda ()
                          (testInBounds 11))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: testInBounds 11"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 331 (list) (lambda () (testOwnership "alice" 42)))) 42)
  )

  (test-case "R58_ES01 establish is unconditional trusted boundary"
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 349 (list) (lambda () (useEstablishFreedom -5)))) -5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 350 (list) (lambda () (useEstablishFreedom 0)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 351 (list) (lambda () (useEstablishFreedom 999)))) 999)
  )

  (test-case "R58_GC01 exhaustive case with all constructors covered"
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 376 (list) (lambda () (describeColor Red)))) "red")
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 377 (list) (lambda () (describeColor Green)))) "green")
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 378 (list) (lambda () (describeColor Blue)))) "blue")
  )

  (test-case "R58_SF01 sequential filterCheck accumulates ForAll proofs (fixed)"
  (define result (thsl-src! "tests/critical-review58-tests.tesl" 392 (list) (lambda () (seqFilterAccumulated (list -1 2 3 200 50)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 393 (list (cons 'result result)) (lambda () result))) 3)
  )

  (test-case "R58_SF02 emptyForAll produces empty list satisfying ForAll"
  (define emptyPos (thsl-src! "tests/critical-review58-tests.tesl" 397 (list) (lambda () (tesl_import_List_emptyForAll checkPos))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 398 (list (cons 'emptyPos emptyPos)) (lambda () (needsForAllPos emptyPos)))) 0)
  (define emptyBoth (thsl-src! "tests/critical-review58-tests.tesl" 399 (list (cons 'emptyPos emptyPos)) (lambda () (tesl_import_List_emptyForAll (check-and checkPos checkSmall)))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review58-tests.tesl" 400 (list (cons 'emptyBoth emptyBoth) (cons 'emptyPos emptyPos)) (lambda () (needsForAllBoth emptyBoth)))) 0)
  )

)
